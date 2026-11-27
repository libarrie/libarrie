//// Integration-test helpers. Tests run against real Postgres and an
//// S3-compatible store (see server/scripts/test.sh). Each test provisions
//// its own identity, so tests are isolated by tenant.

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/timestamp
import libarrie/api/auth
import libarrie/api/router
import libarrie/database
import libarrie/domain/context
import libarrie/domain/maintenance
import libarrie/domain/settings
import libarrie/integrations/identity
import libarrie/integrations/image
import libarrie/integrations/providers
import libarrie/integrations/storage
import libarrie_api
import libarrie_worker
import wisp
import wisp/simulate

pub const dev_secret = "test-dev-secret"

pub const internal_token = "test-internal-token"

pub fn app() -> router.App {
  let assert Ok(config) = settings.load()
  let conn = shared_connection(config.database_url)
  let ctx = context.Context(db: conn, config: config.domain)
  let _ = storage.ensure_bucket(config.domain.storage)
  let verifier =
    identity.Verifier(
      issuer: config.oidc_issuer,
      audience: config.oidc_audience,
      keys: identity.Hs256Secret(dev_secret),
      leeway_seconds: 0,
    )
  let assert Ok(web) =
    libarrie_api.web_settings(config, ctx, verifier, "test-secret-key-base-0123456789abcdef-0123456789abcdef-0123456789abcdef")
  router.App(
    ctx:,
    auth: auth.Auth(
      ..libarrie_api.api_auth(config, verifier),
      internal_token: Some(internal_token),
    ),
    web:,
  )
}

@external(erlang, "support_ffi", "cached")
fn cached(make: fn() -> a) -> a

/// One long-lived pool for the whole run, owned by an unlinked process so it
/// outlives individual tests.
fn shared_connection(url: String) -> database.Connection {
  cached(fn() {
    let reply = process.new_subject()
    process.spawn_unlinked(fn() {
      let assert Ok(conn) = database.connect(url, 20)
      process.send(reply, conn)
      process.sleep_forever()
    })
    let assert Ok(conn) = process.receive(reply, 5000)
    wait_for_pool(conn, 100)
    conn
  })
}

fn wait_for_pool(conn: database.Connection, tries: Int) -> Nil {
  case database.execute(conn, "select 1", []), tries {
    Ok(_), _ -> Nil
    Error(_), 0 -> panic as "database unavailable"
    Error(_), _ -> {
      process.sleep(50)
      wait_for_pool(conn, tries - 1)
    }
  }
}

pub fn random_id() -> String {
  crypto.strong_random_bytes(8) |> bit_array.base16_encode |> string.lowercase
}

pub fn uuid() -> String {
  let assert <<a:32, b:16, _:4, c:12, _:2, d:14, e:48>> =
    crypto.strong_random_bytes(16)
  let hex = fn(n: Int, width: Int) {
    string.pad_start(string.lowercase(int.to_base16(n)), width, "0")
  }
  hex(a, 8)
  <> "-"
  <> hex(b, 4)
  <> "-4"
  <> hex(c, 3)
  <> "-"
  <> hex(0x8000 + d, 4)
  <> "-"
  <> hex(e, 12)
}

/// A fresh user's bearer token.
pub fn user(_app: router.App) -> String {
  token_for("user-" <> random_id(), 0)
}

/// A token for a specific subject whose authentication happened
/// `age_seconds` ago (for recent-authentication checks).
pub fn token_for(subject: String, age_seconds: Int) -> String {
  let assert Ok(config) = settings.load()
  identity.mint_development_token(
    dev_secret,
    config.oidc_issuer,
    config.oidc_audience,
    subject,
    "Test User",
    now_seconds() - age_seconds,
    3600 + age_seconds,
  )
}

/// The test app with a modified domain configuration.
pub fn app_with(update: fn(context.Config) -> context.Config) -> router.App {
  let app = app()
  router.App(..app, ctx: context.Context(..app.ctx, config: update(app.ctx.config)))
}

pub fn services() -> maintenance.Services {
  let assert Ok(config) = settings.load()
  let _ = storage.ensure_bucket(config.domain.journal_store)
  maintenance.Services(journal_store: config.domain.journal_store, subscriber: None)
}

/// Run one maintenance task directly (bypassing time-bucket scheduling).
pub fn maintain(app: router.App, task: String) -> Nil {
  let assert Ok(_) = maintenance.run(app.ctx, services(), task)
  Nil
}

pub fn now_seconds() -> Int {
  let #(s, _) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  s
}

pub type Reply {
  Reply(status: Int, body: String, etag: Option(String))
}

pub fn call(
  app: router.App,
  method: http.Method,
  path: String,
  token: String,
  body: Option(json.Json),
  headers: List(#(String, String)),
) -> Reply {
  let req =
    simulate.request(method, path)
    |> simulate.header("authorization", "Bearer " <> token)
  let req = case body {
    Some(b) -> simulate.json_body(req, b)
    None -> req
  }
  let req =
    headers
    |> list.fold(req, fn(r, h) { simulate.header(r, h.0, h.1) })
  send(app, req)
}

pub fn send(app: router.App, req: wisp.Request) -> Reply {
  let resp = router.handle(app, req)
  let etag = case list.key_find(resp.headers, "etag") {
    Ok(v) -> Some(v)
    Error(_) -> None
  }
  Reply(resp.status, simulate.read_body(resp), etag)
}

pub fn get(reply: Reply, path: List(String), decoder: decode.Decoder(a)) -> a {
  case json.parse(reply.body, decode.at(path, decoder)) {
    Ok(v) -> v
    Error(_) ->
      panic as {
        "missing " <> string.join(path, ".") <> " in " <> string.inspect(reply.status) <> " " <> reply.body
      }
  }
}

pub fn str(reply: Reply, path: List(String)) -> String {
  get(reply, path, decode.string)
}

pub fn account_id(app: router.App, token: String) -> String {
  str(call(app, http.Get, "/v1/me", token, None, []), ["account", "id"])
}

pub fn notebook(app: router.App, token: String, name: String) -> String {
  let r =
    call(
      app,
      http.Post,
      "/v1/notebooks",
      token,
      Some(json.object([#("name", json.string(name))])),
      [],
    )
  str(r, ["id"])
}

/// The default limits allow one notebook per account. Call this before an
/// account's second notebook.
pub fn raise_limits(app: router.App, token: String) -> Nil {
  let account = account_id(app, token)
  let assert 200 =
    internal(
      app,
      http.Put,
      "/internal/v1/accounts/" <> account <> "/entitlements",
      entitlement(1, 100, 5, 100, "lifetime", [], []),
    ).status
  Nil
}

/// Mark a notebook private, or not, through the API at its current version.
pub fn set_private(
  app: router.App,
  token: String,
  notebook_id: String,
  private: Bool,
) -> Nil {
  let current = call(app, http.Get, "/v1/notebooks/" <> notebook_id, token, None, [])
  let version = get(current, ["version"], decode.int)
  let updated =
    call(
      app,
      http.Patch,
      "/v1/notebooks/" <> notebook_id,
      token,
      Some(json.object([#("private", json.bool(private))])),
      [#("if-match", "\"v" <> int.to_string(version) <> "\"")],
    )
  let assert True = get(updated, ["private"], decode.bool) == private
  Nil
}

pub fn png(text: Option(String)) -> BitArray {
  image.mock_png(640, 480, text)
}

pub fn sha(bytes: BitArray) -> String {
  crypto.hash(crypto.Sha256, bytes) |> bit_array.base16_encode |> string.lowercase
}

pub fn create_upload(
  app: router.App,
  token: String,
  operation_id: String,
  target: List(#(String, json.Json)),
  bytes: BitArray,
  mode: String,
  headers: List(#(String, String)),
) -> Reply {
  call(
    app,
    http.Post,
    "/v1/upload-sessions",
    token,
    Some(json.object(list.flatten([
      [#("operation_id", json.string(operation_id))],
      target,
      [
        #("bytes", json.int(bit_array.byte_size(bytes))),
        #("content_type", json.string("image/png")),
        #("checksum_sha256", json.string(sha(bytes))),
        #("processing_mode", json.string(mode)),
        #("client_label", json.string("test")),
      ],
    ]))),
    headers,
  )
}

/// Simulate the client's direct upload by writing the staging object.
pub fn put_staging(
  app: router.App,
  account: String,
  session_id: String,
  bytes: BitArray,
) -> Nil {
  let key = "staging/" <> account <> "/" <> session_id
  let assert Ok(Nil) =
    storage.put(app.ctx.config.storage, key, bytes, "image/png")
  Nil
}

pub fn complete(app: router.App, token: String, session_id: String) -> Reply {
  call(app, http.Post, "/v1/upload-sessions/" <> session_id <> "/complete", token, None, [])
}

/// Upload a new page end to end (without processing). Returns the reply of
/// completion and the page ID.
pub fn upload_page(
  app: router.App,
  token: String,
  notebook_id: String,
  number: Int,
  text: Option(String),
  mode: String,
) -> #(Reply, String) {
  let account = account_id(app, token)
  let bytes = png(text)
  let created =
    create_upload(
      app,
      token,
      uuid(),
      [
        #("notebook_id", json.string(notebook_id)),
        #("page_number", json.int(number)),
      ],
      bytes,
      mode,
      [],
    )
  let assert 201 = created.status
  let session = str(created, ["upload_session_id"])
  put_staging(app, account, session, bytes)
  let done = complete(app, token, session)
  #(done, str(created, ["operation", "page_id"]))
}

pub fn drain_with(app: router.App, ocr: providers.OcrProvider) -> Nil {
  libarrie_worker.drain(app.ctx, services(), ocr, "test-" <> random_id())
}

pub fn drain(app: router.App) -> Nil {
  libarrie_worker.drain(app.ctx, services(), providers.mock_ocr(), "test-" <> random_id())
}

pub fn sql(app: router.App, statement: String, params: List(String)) -> Nil {
  let assert Ok(_) =
    database.execute(app.ctx.db, statement, list.map(params, database.text))
  Nil
}

pub fn sql_int(app: router.App, statement: String, params: List(String)) -> Int {
  let assert Ok(Some(n)) =
    database.query_one(
      app.ctx.db,
      statement,
      list.map(params, database.text),
      decode.at([0], decode.int),
    )
  n
}

pub fn internal(
  app: router.App,
  method: http.Method,
  path: String,
  body: json.Json,
) -> Reply {
  simulate.request(method, path)
  |> simulate.header("authorization", "Bearer " <> internal_token)
  |> simulate.json_body(body)
  |> send(app, _)
}

pub fn limited(n: Int) -> json.Json {
  json.object([#("kind", json.string("limited")), #("value", json.int(n))])
}

pub fn entitlement(
  revision: Int,
  stored: Int,
  notebooks: Int,
  processing: Int,
  policy: String,
  coverage: List(json.Json),
  revocations: List(json.Json),
) -> json.Json {
  json.object([
    #("command_id", json.string(uuid())),
    #("authority", json.string("test-authority")),
    #("revision", json.int(revision)),
    #("effective_at", json.string("2020-01-01T00:00:00Z")),
    #("limits", json.object([
      #("stored_pages", limited(stored)),
      #("notebooks", limited(notebooks)),
      #("processing_pages_per_period", limited(processing)),
    ])),
    #("processing_policy", json.object([#("kind", json.string(policy))])),
    #("processing_coverage", json.preprocessed_array(coverage)),
    #("coverage_revocations", json.preprocessed_array(revocations)),
    #("renewal_policy", json.object([#("kind", json.string("disabled"))])),
    #("features", json.object([])),
    #("scheduled_change", json.null()),
  ])
}

pub fn sql_str(app: router.App, statement: String, params: List(String)) -> String {
  let assert Ok(Some(text)) =
    database.query_one(
      app.ctx.db,
      statement,
      list.map(params, database.text),
      decode.at([0], decode.string),
    )
  text
}
