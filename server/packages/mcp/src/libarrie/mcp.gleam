//// The MCP server (ADR 0012): lets an agent search a person's notes and read
//// page text. Served by the API at `/mcp` with Streamable HTTP, through the
//// gleam_mcp SDK.
////
//// Every request is authenticated with `Authorization: Bearer`, carrying
//// either an API key (`lbk_…`, created in Settings) or, when OAuth is
//// configured, an access token from the identity provider whose audience is
//// this server. A request that fails authentication gets 401 with a
//// `WWW-Authenticate: Bearer` challenge; with OAuth the challenge points to
//// the protected-resource metadata (RFC 9728), which names the identity
//// provider as the authorization server.
////
//// Tools are read-only and see only the authenticated person's notes.
////
//// Sessions (2025-11-25 protocol) and tasks live in Postgres
//// (gleam_mcp_postgres), so every API replica can serve every client and
//// sessions survive restarts. All replicas sign request state with the
//// same secret, derived from SECRET_KEY_BASE.

import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/float
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import gleam_mcp/actions
import gleam_mcp/codec_value
import gleam_mcp/jsonrpc.{type Value, VArray, VInt, VObject, VString}
import gleam_mcp/server.{type RequestContext, type Server}
import gleam_mcp/server/streamable_http
import gleam_mcp_postgres
import libarrie/database.{type Connection}
import libarrie/domain/accounts.{type Principal}
import libarrie/domain/admin
import libarrie/domain/api_keys
import libarrie/domain/context.{type Context}
import libarrie/domain/error.{type AppError}
import libarrie/domain/notebooks.{type Notebook}
import libarrie/domain/pages
import libarrie/domain/ratelimit
import libarrie/domain/search
import libarrie/domain/settings
import libarrie/integrations/identity
import mist
import youid/uuid

pub const path = settings.mcp_path

const metadata_path = "/.well-known/oauth-protected-resource"

const search_limit = 10

pub type Config {
  Config(
    ctx: Context,
    /// The public URL of this endpoint (`WEB_ORIGIN` + `/mcp`). It is the
    /// OAuth resource identifier.
    resource: String,
    /// Access tokens from the identity provider; `None` accepts API keys
    /// only.
    oauth: Option(OAuth),
    /// Browser origins allowed to call the endpoint, beyond loopback.
    allowed_origins: List(String),
    /// SECRET_KEY_BASE: the same on every replica.
    secret_key_base: String,
  )
}

/// Create or update the session and task tables (run by `migrate`).
pub fn migrate(db: Connection) -> Result(Nil, String) {
  gleam_mcp_postgres.migrate(db)
  |> result.map_error(fn(e) { "MCP session tables: " <> string.inspect(e) })
}

pub type OAuth {
  OAuth(
    /// Verifies access tokens: the provider's issuer and keys, with this
    /// server's resource identifier as the audience.
    verifier: identity.Verifier,
    /// Scopes clients should request, if the provider needs any.
    scopes: List(String),
  )
}

/// Whether the API should hand a request to `handler`.
pub fn handles(request_path: String) -> Bool {
  request_path == path
  || request_path == metadata_path
  || request_path == metadata_path <> path
}

pub fn handler(
  config: Config,
) -> fn(Request(mist.Connection)) -> Response(mist.ResponseData) {
  let mcp = streamable_http.handler(new_server(config))
  fn(req: Request(mist.Connection)) {
    case req.path == path {
      True ->
        case mcp(req) {
          resp if resp.status == 401 -> challenge(config, req)
          resp -> resp
        }
      False -> metadata(config, req)
    }
  }
}

// Authentication ------------------------------------------------------------------------

/// The user ID for a valid `Authorization` header value.
fn authenticate(config: Config, header: String) -> Option(String) {
  case string.split_once(string.trim(header), " ") {
    Ok(#(scheme, token)) ->
      case string.lowercase(scheme) {
        "bearer" -> authenticate_token(config, string.trim(token))
        _ -> None
      }
    Error(_) -> None
  }
}

fn authenticate_token(config: Config, token: String) -> Option(String) {
  case api_keys.is_api_key(token), config.oauth {
    True, _ ->
      api_keys.authenticate(config.ctx.db, token)
      |> result.unwrap(None)
    False, Some(oauth) -> {
      let now =
        timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
      case identity.verify(oauth.verifier, token, now.0) {
        Error(_) -> None
        Ok(claims) ->
          // Like a native app's first sign-in, a first MCP sign-in creates
          // the account.
          accounts.resolve(
            config.ctx,
            claims.issuer,
            claims.subject,
            claims.name,
            claims.auth_time,
          )
          |> result.map(fn(principal) { principal.user_id })
          |> option.from_result
      }
    }
    False, None -> None
  }
}

fn challenge(
  config: Config,
  req: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  let error = case request.get_header(req, "authorization") {
    Ok(_) -> ", error=\"invalid_token\""
    Error(_) -> ""
  }
  let value = case config.oauth {
    Some(oauth) ->
      "Bearer resource_metadata=\""
      <> metadata_url(config)
      <> "\""
      <> error
      <> case oauth.scopes {
        [] -> ""
        scopes -> ", scope=\"" <> string.join(scopes, " ") <> "\""
      }
    None -> "Bearer realm=\"libarrie\"" <> error
  }
  plain(401, "Sign in or use an API key to continue.")
  |> response.set_header("www-authenticate", value)
}

fn metadata_url(config: Config) -> String {
  origin(config.resource) <> metadata_path <> path
}

fn origin(url: String) -> String {
  case string.split_once(url, "://") {
    Ok(#(scheme, rest)) ->
      scheme
      <> "://"
      <> case string.split_once(rest, "/") {
        Ok(#(host, _)) -> host
        Error(_) -> rest
      }
    Error(_) -> url
  }
}

/// Protected-resource metadata (RFC 9728), at the path-suffixed location and
/// at the root for clients that only look there.
fn metadata(
  config: Config,
  req: Request(mist.Connection),
) -> Response(mist.ResponseData) {
  case config.oauth, req.method {
    None, _ -> plain(404, "Not found")
    Some(oauth), http.Get ->
      response.new(200)
      |> response.set_header("content-type", "application/json")
      |> response.set_header("cache-control", "max-age=3600")
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string(
          json.to_string(
            json.object([
              #("resource", json.string(config.resource)),
              #(
                "authorization_servers",
                json.array([oauth.verifier.issuer], json.string),
              ),
              #("bearer_methods_supported", json.array(["header"], json.string)),
              #("scopes_supported", json.array(oauth.scopes, json.string)),
              #("resource_name", json.string("Libarrie")),
            ]),
          ),
        )),
      )
    Some(_), _ -> plain(405, "Method not allowed")
  }
}

fn plain(status: Int, body: String) -> Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

// Server and tools ----------------------------------------------------------------------

fn new_server(config: Config) -> Server {
  let stores = gleam_mcp_postgres.stores(config.ctx.db)
  // 32 bytes, so with_request_state_secret always accepts it.
  let secret =
    crypto.hash(
      crypto.Sha256,
      bit_array.from_string("libarrie-mcp-request-state:" <> config.secret_key_base),
    )
  let implementation =
    actions.Implementation(
      name: "libarrie",
      version: "0.1.0",
      title: Some("Libarrie"),
      description: Some("Search and read your handwritten notebooks."),
      website_url: None,
      icons: [],
    )
  let assert Ok(base) =
    server.new(implementation)
    |> server.with_session_store(stores.sessions)
    |> server.with_task_store(stores.tasks)
    |> server.with_request_state_secret(secret)
  base
  |> server.with_instructions(
    "Libarrie holds the user's handwritten notebooks as transcribed text. "
    <> "Use `search` to find pages, then `get_text` with the notebook and "
    <> "page number from a result to read the whole page.",
  )
  |> server.with_identity_authorization("authorization", authenticate(config, _))
  |> server.with_allowed_origins(config.allowed_origins)
  |> tool(
    "get_me",
    "Get Me",
    "Get the signed-in user's name, email and account status.",
    object_schema([], []),
    fn(user_id, arguments) { get_me(config, user_id, arguments) },
  )
  |> tool(
    "search",
    "Search Notes",
    "Search the user's notebooks for text, by words and by meaning. "
      <> "Returns up to 10 matching pages with a snippet each.",
    object_schema(
      [
        #("query", string_schema("What to look for.")),
        #(
          "notebook",
          string_schema(
            "Only search this notebook: its name or ID. Leave out to search all notebooks.",
          ),
        ),
      ],
      ["query"],
    ),
    fn(user_id, arguments) { search_tool(config, user_id, arguments) },
  )
  |> tool(
    "get_text",
    "Get Page Text",
    "Get the transcribed text of one page in a notebook.",
    object_schema(
      [
        #("notebook", string_schema("The notebook's name or ID.")),
        #(
          "page",
          VObject([
            #("type", VString("integer")),
            #("minimum", VInt(1)),
            #("description", VString("The page number in the notebook.")),
          ]),
        ),
      ],
      ["notebook", "page"],
    ),
    fn(user_id, arguments) { get_text(config, user_id, arguments) },
  )
}

type Arguments =
  Option(Dict(String, Value))

type ToolResult =
  Result(actions.CallToolResult, jsonrpc.RpcError)

fn tool(
  server: Server,
  name: String,
  title: String,
  description: String,
  input_schema: Value,
  run: fn(String, Arguments) -> ToolResult,
) -> Server {
  server.register_context_tool_descriptor(
    server,
    actions.Tool(
      name:,
      title: Some(title),
      description: Some(description),
      input_schema:,
      execution: Some(actions.ToolExecution(Some(actions.TaskForbidden))),
      output_schema: None,
      annotations: Some(actions.ToolAnnotations(
        title: Some(title),
        read_only_hint: Some(True),
        destructive_hint: Some(False),
        idempotent_hint: Some(True),
        open_world_hint: Some(False),
      )),
      icons: [],
      meta: None,
    ),
    fn(server, context, arguments) {
      case principal(server, context) {
        Some(user_id) -> run(user_id, arguments)
        None -> Error(jsonrpc.invalid_params_error("authentication required"))
      }
    },
  )
}

/// The authenticated user ID: per request in the 2026 protocol, bound to the
/// session in the 2025 one.
fn principal(server: Server, context: RequestContext) -> Option(String) {
  case context {
    server.ModernRequestContext(principal:, ..) -> principal
    _ ->
      context.session_id
      |> option.then(server.session_metadata(server, _))
      |> option.then(fn(metadata) { metadata.principal })
  }
}

fn load(config: Config, user_id: String) -> Result(Principal, String) {
  case accounts.by_user(config.ctx.db, user_id) {
    Ok(Some(principal)) -> Ok(principal)
    Ok(None) -> Error("This account no longer exists.")
    Error(e) -> Error(message(e))
  }
}

/// Notes are readable while the account is active or awaiting deletion.
fn readable(config: Config, user_id: String) -> Result(Principal, String) {
  use principal <- result.try(load(config, user_id))
  case accounts.can_read(principal), accounts.is_suspended(principal) {
    True, _ -> Ok(principal)
    _, True ->
      Error(
        "This account is blocked by an administrator, so its notes can't be read here.",
      )
    _, False -> Error("This account is closed.")
  }
}

fn get_me(config: Config, user_id: String, _arguments: Arguments) -> ToolResult {
  respond({
    use principal <- result.try(load(config, user_id))
    use found <- result.try(
      admin.find_user(config.ctx.db, principal.user_id)
      |> result.map_error(message),
    )
    let email = option.then(found, fn(u) { u.email })
    let value =
      VObject([
        #(
          "user",
          VObject([
            #("id", VString(principal.user_id)),
            #("name", VString(principal.display_name)),
            #("email", optional_string(email)),
          ]),
        ),
        #(
          "account",
          VObject([
            #("id", VString(principal.account_id)),
            #("status", VString(principal.account_status)),
          ]),
        ),
      ])
    Ok(#(jsonrpc_text(value), value))
  })
}

fn search_tool(config: Config, user_id: String, arguments: Arguments) -> ToolResult {
  respond({
    use query <- result.try(required_string(arguments, "query"))
    use notebook <- result.try(optional_argument(arguments, "notebook"))
    use principal <- result.try(readable(config, user_id))
    let account = principal.account_id
    use notebook <- result.try(case notebook {
      None -> Ok(None)
      Some(value) -> resolve_notebook(config, account, value) |> result.map(Some)
    })
    use _ <- result.try(
      ratelimit.hit(
        config.ctx.db,
        "search:" <> account,
        "search",
        config.ctx.config.rate_limits.searches_per_minute,
        60,
      )
      |> result.map_error(message),
    )
    use results <- result.try(
      search.run(
        config.ctx,
        account,
        search.Request(
          query:,
          notebook_id: option.map(notebook, fn(n: Notebook) { n.id }),
          limit: search_limit,
        ),
      )
      |> result.map_error(message),
    )
    let value =
      VObject([
        #(
          "results",
          VArray(
            list.map(results.hits, fn(hit) {
              VObject([
                #(
                  "notebook",
                  VObject([
                    #("id", VString(hit.notebook_id)),
                    #("name", VString(hit.notebook_name)),
                  ]),
                ),
                #("page", VInt(hit.page_number)),
                #("snippet", VString(hit.snippet)),
              ])
            }),
          ),
        ),
      ])
    Ok(#(jsonrpc_text(value), value))
  })
}

fn get_text(config: Config, user_id: String, arguments: Arguments) -> ToolResult {
  respond({
    use notebook <- result.try(required_string(arguments, "notebook"))
    use number <- result.try(page_number(arguments))
    use principal <- result.try(readable(config, user_id))
    let account = principal.account_id
    use notebook <- result.try(resolve_notebook(config, account, notebook))
    use page <- result.try(
      pages.by_number(config.ctx.db, account, notebook.id, number)
      |> result.map_error(fn(e) {
        case e.status {
          404 ->
            "\""
            <> notebook.name
            <> "\" has no page "
            <> int.to_string(number)
            <> ". It has "
            <> pages_phrase(notebook.page_count)
            <> "."
          _ -> message(e)
        }
      }),
    )
    use text <- result.try(
      pages.transcript_text(config.ctx.db, account, page)
      |> result.map_error(message),
    )
    case text {
      None ->
        Error(
          "Page "
          <> int.to_string(number)
          <> " of \""
          <> notebook.name
          <> "\" hasn't been transcribed yet. Try again later.",
        )
      Some(text) ->
        Ok(#(
          text,
          VObject([
            #(
              "notebook",
              VObject([
                #("id", VString(notebook.id)),
                #("name", VString(notebook.name)),
              ]),
            ),
            #("page", VInt(number)),
            #("text", VString(text)),
          ]),
        ))
    }
  })
}

fn pages_phrase(count: Int) -> String {
  case count {
    1 -> "1 page"
    n -> int.to_string(n) <> " pages"
  }
}

/// A notebook by ID, or by name when the name is unique.
fn resolve_notebook(
  config: Config,
  account: String,
  value: String,
) -> Result(Notebook, String) {
  let value = string.trim(value)
  let by_id = case uuid.from_string(value) {
    Ok(_) -> notebooks.get(config.ctx.db, account, value) |> option.from_result
    Error(_) -> None
  }
  case by_id {
    Some(notebook) -> Ok(notebook)
    None -> {
      use matches <- result.try(
        notebooks.named(config.ctx.db, account, value)
        |> result.map_error(message),
      )
      case matches {
        [notebook] -> Ok(notebook)
        [] -> {
          let names =
            notebooks.list(config.ctx.db, account, None, 50)
            |> result.unwrap([])
            |> list.map(fn(n) { "\"" <> n.name <> "\"" })
          Error(
            "There is no notebook named \""
            <> value
            <> "\". "
            <> case names {
              [] -> "This account has no notebooks yet."
              names -> "The notebooks are: " <> string.join(names, ", ") <> "."
            },
          )
        }
        several ->
          Error(
            "Several notebooks are named \""
            <> value
            <> "\". Use one of these IDs instead: "
            <> string.join(list.map(several, fn(n) { n.id }), ", ")
            <> ".",
          )
      }
    }
  }
}

// Arguments and results -----------------------------------------------------------------

fn required_string(arguments: Arguments, name: String) -> Result(String, String) {
  case optional_argument(arguments, name) {
    Ok(Some(value)) -> Ok(value)
    Ok(None) -> Error("`" <> name <> "` is required.")
    Error(e) -> Error(e)
  }
}

fn optional_argument(
  arguments: Arguments,
  name: String,
) -> Result(Option(String), String) {
  case option.map(arguments, dict.get(_, name)) {
    Some(Ok(VString(value))) ->
      case string.trim(value) {
        "" -> Ok(None)
        _ -> Ok(Some(value))
      }
    Some(Ok(jsonrpc.VNull)) | Some(Error(_)) | None -> Ok(None)
    Some(Ok(_)) -> Error("`" <> name <> "` must be a string.")
  }
}

fn page_number(arguments: Arguments) -> Result(Int, String) {
  let number = case option.map(arguments, dict.get(_, "page")) {
    Some(Ok(VInt(n))) -> Ok(n)
    // Some clients send whole numbers as floats or strings.
    Some(Ok(jsonrpc.VFloat(f))) ->
      case int.to_float(float.truncate(f)) == f {
        True -> Ok(float.truncate(f))
        False -> Error(Nil)
      }
    Some(Ok(VString(s))) -> int.parse(string.trim(s))
    _ -> Error(Nil)
  }
  case number {
    Ok(n) if n >= 1 -> Ok(n)
    _ -> Error("`page` is required and must be a page number (1 or more).")
  }
}

fn optional_string(value: Option(String)) -> Value {
  case value {
    Some(s) -> VString(s)
    None -> jsonrpc.VNull
  }
}

fn object_schema(
  properties: List(#(String, Value)),
  required: List(String),
) -> Value {
  VObject([
    #("type", VString("object")),
    #("properties", VObject(properties)),
    #("required", VArray(list.map(required, VString))),
    #("additionalProperties", jsonrpc.VBool(False)),
  ])
}

fn string_schema(description: String) -> Value {
  VObject([#("type", VString("string")), #("description", VString(description))])
}

/// Tool failures go back to the agent as tool errors it can read and act
/// on, rather than protocol errors.
fn respond(outcome: Result(#(String, Value), String)) -> ToolResult {
  case outcome {
    Ok(#(text, value)) ->
      Ok(actions.CallToolResult(
        content: [actions.TextBlock(actions.TextContent(text, None, None))],
        structured_content: Some(value),
        is_error: Some(False),
        meta: None,
      ))
    Error(text) ->
      Ok(actions.CallToolResult(
        content: [actions.TextBlock(actions.TextContent(text, None, None))],
        structured_content: None,
        is_error: Some(True),
        meta: None,
      ))
  }
}

fn message(e: AppError) -> String {
  case e.status {
    500 -> {
      io.println("mcp: " <> string.inspect(e.details))
      e.message
    }
    _ -> e.message
  }
}

fn jsonrpc_text(value: Value) -> String {
  codec_value.to_json(value) |> json.to_string
}
