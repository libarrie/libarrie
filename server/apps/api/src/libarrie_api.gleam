//// Libarrie core API entrypoint.
////
////   libarrie_api serve            Start the HTTP API (default)
////   libarrie_api migrate          Apply database migrations, then exit
////   libarrie_api dev-token SUB    Mint a development-issuer token
////
//// Migrations are a separate entrypoint run once per deployment, never
//// concurrently from every replica (section 15).

import argv
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import libarrie/api/auth
import libarrie/api/checks
import libarrie/api/router
import libarrie/database
import libarrie/database/migrate
import libarrie/domain/admin
import libarrie/domain/context
import libarrie/domain/recovery
import libarrie/domain/search_migration
import libarrie/domain/settings.{type Settings}
import libarrie/integrations/identity
import libarrie/integrations/storage
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/json
import gleam/uri
import libarrie/web/config as web_config
import mist
import wisp
import wisp/wisp_mist
import libarrie/mcp

pub fn main() -> Nil {
  main_with([])
}

/// The command-line entry point with web UI extensions compiled in by a
/// particular deployment's build. The default build passes none.
pub fn main_with(extensions: List(web_config.Extension)) -> Nil {
  wisp.configure_logger()
  case settings.load() {
    Error(message) -> halt_with("configuration error: " <> message)
    Ok(config) ->
      case argv.load().arguments {
        [] | ["serve"] -> serve(config, extensions)
        ["migrate"] -> run_migrations(config)
        ["reindex"] -> reindex(config)
        ["reindex-status"] -> reindex_status(config)
        ["reindex-rollback", account_id] -> reindex_rollback(config, account_id)
        ["storage-check"] -> storage_check(config)
        ["journal-replay"] -> journal_replay(config)
        ["setup-code"] -> setup_code(config)
        ["dev-token", subject] -> dev_token(config, subject, subject)
        ["dev-token", subject, name] -> dev_token(config, subject, name)
        _ -> halt_with("usage: libarrie_api [serve | migrate | reindex | reindex-status | reindex-rollback ACCOUNT_ID | storage-check | journal-replay | setup-code | dev-token SUBJECT [NAME]]")
      }
  }
}

fn halt_with(message: String) -> Nil {
  io.println_error(message)
  halt(1)
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

fn connect(config: Settings) -> database.Connection {
  case database.connect(config.database_url, config.database_pool_size) {
    Ok(conn) -> conn
    Error(message) -> {
      halt_with(message)
      panic as "unreachable"
    }
  }
}

fn run_migrations(config: Settings) -> Nil {
  let conn = connect(config)
  // The pool connects asynchronously; wait briefly for it.
  process.sleep(500)
  case migrate.run(conn, config.migrations_dir) {
    Ok(applied) -> {
      io.println(
        "applied " <> int.to_string(list.length(applied)) <> " migration(s)",
      )
      list.each(applied, fn(file) { io.println("  " <> file) })
    }
    Error(migrate.ReadFailed(path)) -> halt_with("cannot read " <> path)
    Error(migrate.StatementFailed(file, detail)) ->
      halt_with("migration " <> file <> " failed: " <> detail)
  }
  // The MCP server's session and task tables, owned by gleam_mcp_postgres.
  case mcp.migrate(conn) {
    Ok(Nil) -> Nil
    Error(message) -> halt_with(message)
  }
}

/// Verify the primary and journal object stores (run before launch with the
/// real credentials).
fn storage_check(config: Settings) -> Nil {
  let checks = checks.run(config.domain.storage, config.domain.journal_store)
  case checks.report(checks) {
    True -> io.println("storage check passed")
    False -> halt_with("storage check failed")
  }
}

/// Replay the independent journal over a restored database. Run before the
/// recovered deployment serves traffic or processes jobs; exits non-zero
/// (recovery stays closed) on journal unavailability or coverage gaps.
fn journal_replay(config: Settings) -> Nil {
  let conn = connect(config)
  process.sleep(500)
  let ctx = context.Context(db: conn, config: config.domain)
  case recovery.replay(ctx) {
    Ok(report) -> {
      io.println(
        "journal events: " <> int.to_string(report.journal_events)
        <> "; already in snapshot: " <> int.to_string(report.already_applied)
        <> "; replayed: " <> int.to_string(report.replayed),
      )
      list.each(report.conflicts, fn(c) { io.println("CONFLICT  " <> c) })
    }
    Error(refusal) -> halt_with("RECOVERY CLOSED: " <> recovery.refusal_message(refusal))
  }
}

/// Start a per-account search migration to the deployment's current search
/// configuration for every account not on it (and clear rollback holds).
/// Workers build each shadow release; the maintenance task cuts accounts
/// over as they complete. Keep the old model in EMBEDDING_PREVIOUS until
/// `reindex-status` shows no shadow releases, and for the rollback window.
fn reindex(config: Settings) -> Nil {
  let ctx = command_context(config)
  reindex_loop(ctx, 0)
}

fn reindex_loop(ctx: context.Context, started: Int) -> Nil {
  case search_migration.start_all(ctx, 100) {
    Ok(0) -> io.println("started search migrations for " <> int.to_string(started) <> " account(s)")
    Ok(n) -> reindex_loop(ctx, started + n)
    Error(e) -> halt_with("reindex failed: " <> e.code)
  }
}

fn reindex_status(config: Settings) -> Nil {
  case search_migration.summary(command_context(config)) {
    Ok(rows) ->
      list.each(rows, fn(row) { io.println(row.0 <> ": " <> int.to_string(row.1)) })
    Error(e) -> halt_with("reindex-status failed: " <> e.code)
  }
}

/// Roll one account back to its previous search release (replayed, then
/// cut over by the maintenance task). The account stays on it until the
/// next `reindex`.
fn reindex_rollback(config: Settings, account_id: String) -> Nil {
  case search_migration.rollback(command_context(config), account_id) {
    Ok(_) -> io.println("rollback started for " <> account_id)
    Error(e) -> halt_with("rollback refused: " <> e.message)
  }
}

/// While nobody has claimed ownership, print a fresh setup code. The pool
/// connects asynchronously, so this retries briefly.
fn announce_setup(ctx: context.Context, origin: String, attempts: Int) -> Nil {
  case admin.issue_setup_code_if_needed(ctx), attempts {
    Ok(Some(code)), _ -> {
      io.println(
        "\n  This server has no owner yet. Sign in, open " <> origin <> "/setup and enter:\n\n      "
        <> code <> "\n\n  The code works once and expires in 24 hours (restarting prints a new one).\n",
      )
    }
    Ok(None), _ -> Nil
    Error(_), 0 -> io.println_error("could not check for a server owner; restart to get a setup code")
    Error(_), _ -> {
      process.sleep(500)
      announce_setup(ctx, origin, attempts - 1)
    }
  }
}

/// `setup-code`: a one-time recovery code for claiming ownership, even when
/// owners exist (for example when the only owner lost access).
fn setup_code(config: Settings) -> Nil {
  let ctx = command_context(config)
  case admin.issue_code(ctx, "recovery") {
    Ok(code) ->
      io.println(
        "Recovery code (one use, expires in 24 hours). Sign in, open "
        <> config.web_origin <> "/setup and enter:\n\n    " <> code,
      )
    Error(e) -> halt_with("could not create a recovery code: " <> e.message)
  }
}

fn command_context(config: Settings) -> context.Context {
  let conn = connect(config)
  process.sleep(500)
  context.Context(db: conn, config: config.domain)
}

fn dev_token(config: Settings, subject: String, name: String) -> Nil {
  case config.development_issuer_secret {
    None -> halt_with("DEV_ISSUER_SECRET is not configured")
    Some(secret) -> {
      let now = timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
      io.println(identity.mint_development_token(
        secret,
        config.oidc_issuer,
        config.oidc_audience,
        subject,
        name,
        now.0,
        12 * 3600,
      ))
    }
  }
}

/// The `/v1` verifier: identity-provider tokens for `OIDC_AUDIENCE`.
pub fn verifier(config: Settings) -> Result(identity.Verifier, String) {
  use keys <- result.try(case config.development_issuer_secret, config.oidc_jwks_url {
    Some(secret), _ -> Ok(identity.Hs256Secret(secret))
    // Re-fetched when a token names an unknown key ID (key rotation).
    None, Some(url) -> identity.remote_keys(url)
    None, None -> Error("configure OIDC_JWKS_URL (or DEV_ISSUER_SECRET for development)")
  })
  Ok(identity.Verifier(
    issuer: config.oidc_issuer,
    audience: config.oidc_audience,
    keys:,
    leeway_seconds: 30,
  ))
}

/// `/v1` request authentication. Bearer tokens must carry `OIDC_AUDIENCE`
/// and must not also carry the MCP audience, with any identity provider
/// (ADR 0017).
pub fn api_auth(config: Settings, verifier: identity.Verifier) -> auth.Auth {
  auth.Auth(
    verifier:,
    mcp_audience: settings.mcp_audience(config),
    web_origin: config.web_origin,
    internal_token: config.internal_api_token,
  )
}

/// Web UI configuration. With the development issuer the endpoints are the
/// built-in `/dev-issuer` routes; otherwise they come from configuration or
/// OIDC discovery (`<issuer>/.well-known/openid-configuration`).
pub fn web_settings(
  config: Settings,
  ctx: context.Context,
  verifier: identity.Verifier,
  secret_key_base: String,
) -> Result(web_config.Web, String) {
  use #(authorize, token) <- result.try(case
    config.development_issuer_secret,
    config.oidc_authorization_endpoint,
    config.oidc_token_endpoint
  {
    Some(_), _, _ ->
      Ok(#(config.web_origin <> "/dev-issuer/authorize", config.web_origin <> "/dev-issuer/token"))
    None, Some(a), Some(t) -> Ok(#(a, t))
    None, _, _ -> discover(config.oidc_issuer)
  })
  let object_origin = origin_of(config.domain.storage.public_endpoint)
  Ok(web_config.Web(
    ctx:,
    origin: config.web_origin,
    oidc: web_config.Oidc(
      issuer: config.oidc_issuer,
      client_id: config.oidc_client_id,
      client_secret: config.oidc_client_secret,
      authorization_endpoint: authorize,
      token_endpoint: token,
      redirect_uri: config.web_origin <> "/auth/callback",
    ),
    audience: config.oidc_audience,
    native: option.map(config.oidc_native_client_id, fn(id) {
      web_config.NativeClient(id, config.oidc_native_redirect_uri)
    }),
    verifier: identity.Verifier(..verifier, audience: config.oidc_client_id),
    dev_issuer_secret: config.development_issuer_secret,
    secret_key_base:,
    static_dir: config.web_static_dir,
    upload_origin: object_origin,
    download_origin: object_origin,
    extensions: [],
    hosted: config.mode == "hosted",
  ))
}

/// The public listener: the web app, `/v1`, and the MCP server (ADR 0012)
/// at `/mcp`. With `internal_elsewhere`, `/internal` is served only by
/// `internal_handler` on `INTERNAL_PORT`, and is not found here.
pub fn http_handler(
  app: router.App,
  mcp_config: mcp.Config,
  secret_key_base: String,
  internal_elsewhere internal_elsewhere: Bool,
) -> fn(request.Request(mist.Connection)) -> response.Response(mist.ResponseData) {
  let web = wisp_mist.handler(router.handle(app, _), secret_key_base)
  let agents = mcp.handler(mcp_config)
  fn(req: request.Request(mist.Connection)) {
    case mcp.handles(req.path), internal_elsewhere && is_internal(req.path) {
      True, _ -> agents(req)
      _, True -> not_found()
      _, _ -> web(req)
    }
  }
}

/// The `INTERNAL_PORT` listener: `/internal` and the health checks only.
pub fn internal_handler(
  app: router.App,
  secret_key_base: String,
) -> fn(request.Request(mist.Connection)) -> response.Response(mist.ResponseData) {
  let web = wisp_mist.handler(router.handle(app, _), secret_key_base)
  fn(req: request.Request(mist.Connection)) {
    case is_internal(req.path) || req.path == "/healthz" || req.path == "/readyz" {
      True -> web(req)
      False -> not_found()
    }
  }
}

fn is_internal(path: String) -> Bool {
  path == "/internal" || string.starts_with(path, "/internal/")
}

fn not_found() -> response.Response(mist.ResponseData) {
  response.new(404)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string(
      "{\"error\":{\"code\":\"not_found\",\"message\":\"The resource does not exist.\"}}",
    )),
  )
}

/// API keys always work. Identity-provider access tokens work with a real
/// provider (not the development issuer) when their audience is the MCP
/// server.
pub fn mcp_config(
  config: Settings,
  ctx: context.Context,
  verifier: identity.Verifier,
  secret_key_base: String,
) -> mcp.Config {
  mcp.Config(
    ctx:,
    resource: settings.mcp_resource(config),
    oauth: case config.development_issuer_secret {
      Some(_) -> None
      None ->
        Some(mcp.OAuth(
          // `settings.load` refuses to start when this equals the `/v1`
          // audience (ADR 0017).
          verifier: identity.Verifier(
            ..verifier,
            audience: settings.mcp_audience(config),
          ),
          scopes: config.mcp_oauth_scopes,
        ))
    },
    allowed_origins: [config.web_origin],
    secret_key_base:,
  )
}

fn origin_of(url: String) -> String {
  case uri.parse(url) {
    Ok(uri.Uri(scheme: Some(scheme), host: Some(host), port: port, ..)) ->
      scheme <> "://" <> host <> case port {
        Some(p) -> ":" <> int.to_string(p)
        None -> ""
      }
    _ -> url
  }
}

fn discover(issuer: String) -> Result(#(String, String), String) {
  let url = issuer <> "/.well-known/openid-configuration"
  use req <- result.try(request.to(url) |> result.replace_error("invalid OIDC_ISSUER"))
  use resp <- result.try(
    httpc.configure()
    |> httpc.timeout(10_000)
    |> httpc.dispatch(req)
    |> result.replace_error("OIDC discovery failed for " <> url),
  )
  json.parse(resp.body, {
    use authorize <- decode.field("authorization_endpoint", decode.string)
    use token <- decode.field("token_endpoint", decode.string)
    decode.success(#(authorize, token))
  })
  |> result.replace_error("OIDC discovery document is missing endpoints")
}

fn serve(config: Settings, extensions: List(web_config.Extension)) -> Nil {
  case verifier(config) {
    Error(message) -> halt_with(message)
    Ok(verifier) -> {
      let conn = connect(config)
      let ctx = context.Context(db: conn, config: config.domain)
      process.spawn(fn() { announce_setup(ctx, config.web_origin, 20) })
      case config.mode {
        "selfhost" -> {
          // Development convenience: create the bucket on local stores.
          let _ = storage.ensure_bucket(config.domain.storage)
          let _ = storage.ensure_bucket(config.domain.journal_store)
          Nil
        }
        _ -> Nil
      }
      let secret_key_base = case config.secret_key_base {
        Some(key) -> key
        // Development only: hosted mode requires SECRET_KEY_BASE.
        None -> wisp.random_string(64)
      }
      let web_config = case web_settings(config, ctx, verifier, secret_key_base) {
        Ok(w) -> web_config.Web(..w, extensions:)
        Error(message) -> {
          halt_with(message)
          panic as "unreachable"
        }
      }
      let app =
        router.App(ctx:, auth: api_auth(config, verifier), web: web_config)
      let assert Ok(_) =
        http_handler(
          app,
          mcp_config(config, ctx, verifier, secret_key_base),
          secret_key_base,
          internal_elsewhere: option.is_some(config.internal_port),
        )
        |> mist.new
        |> mist.bind("0.0.0.0")
        |> mist.port(config.port)
        |> mist.start
      case config.internal_port {
        Some(port) -> {
          let assert Ok(_) =
            internal_handler(app, secret_key_base)
            |> mist.new
            |> mist.bind("0.0.0.0")
            |> mist.port(port)
            |> mist.start
          io.println("libarrie internal API listening on port " <> int.to_string(port))
        }
        None -> Nil
      }
      io.println(
        "libarrie api listening on port "
        <> int.to_string(config.port)
        <> " ("
        <> config.mode
        <> string.concat(case config.development_issuer_secret {
          Some(_) -> [", development issuer enabled"]
          None -> []
        })
        <> ")",
      )
      process.sleep_forever()
    }
  }
}
