//// The MCP server (ADR 0012), end to end: the real HTTP handler on a local
//// port, driven by the gleam_mcp client and by plain HTTP.

import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam_mcp/actions
import gleam_mcp/client
import gleam_mcp/client/capabilities
import gleam_mcp/client/transport
import gleam_mcp/codec_value
import gleam_mcp/jsonrpc.{type Value, VInt, VString}
import libarrie/api/auth
import libarrie/api/router
import libarrie/domain/accounts
import libarrie/domain/api_keys
import libarrie/domain/moderation
import libarrie/domain/notebooks
import libarrie/domain/pages
import libarrie/domain/settings
import libarrie/integrations/identity
import libarrie/mcp
import libarrie_api
import mist
import support
import web_test
import wisp/simulate

const resource = "https://notes.example/mcp"

fn oauth_config(app: router.App) -> mcp.Config {
  let assert Ok(config) = settings.load()
  mcp.Config(
    ctx: app.ctx,
    resource:,
    oauth: Some(mcp.OAuth(
      verifier: identity.Verifier(
        issuer: config.oidc_issuer,
        audience: resource,
        keys: identity.Hs256Secret("test-dev-secret"),
        leeway_seconds: 0,
      ),
      scopes: [],
    )),
    allowed_origins: [],
    secret_key_base: "test-secret-key-base-0123456789abcdef-0123456789abcdef",
  )
}

/// Serve the API and MCP handler on a free port; returns the `/mcp` URL.
fn serve(app: router.App, config: mcp.Config) -> String {
  let started = process.new_subject()
  process.spawn_unlinked(fn() {
    let assert Ok(_) =
      libarrie_api.http_handler(
        app,
        config,
        "test-secret-key-base-0123456789abcdef-0123456789abcdef",
        internal_elsewhere: False,
      )
      |> mist.new
      |> mist.bind("127.0.0.1")
      |> mist.port(0)
      |> mist.after_start(fn(port, _, _) { process.send(started, port) })
      |> mist.start
    process.sleep_forever()
  })
  let assert Ok(port) = process.receive(started, 5000)
  "http://127.0.0.1:" <> int.to_string(port) <> "/mcp"
}

fn post(url: String, authorization: option.Option(String)) -> response.Response(String) {
  let assert Ok(req) = request.to(url)
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("accept", "application/json, text/event-stream")
    |> request.set_body(
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}",
    )
  let req = case authorization {
    Some(value) -> request.set_header(req, "authorization", value)
    None -> req
  }
  let assert Ok(resp) = httpc.send(req)
  resp
}

fn get(url: String) -> response.Response(String) {
  let assert Ok(req) = request.to(url)
  let assert Ok(resp) = httpc.send(req)
  resp
}

fn challenge(resp: response.Response(String)) -> String {
  let assert Ok(value) = response.get_header(resp, "www-authenticate")
  value
}

fn connect(url: String, token: String, version: option.Option(String)) -> client.Client {
  connect_with_info(url, token, version).0
}

/// Connect, keeping what the server said about itself.
fn connect_with_info(
  url: String,
  token: String,
  version: option.Option(String),
) -> #(client.Client, client.ConnectionInfo) {
  let created =
    client.new(
      transport.Http(transport.HttpConfig(
        url,
        [#("authorization", "Bearer " <> token)],
        Some(10_000),
      )),
      capabilities.none(),
    )
  let created = case version {
    Some(v) -> client.with_protocol_version(created, v)
    None -> created
  }
  let info =
    actions.Implementation(
      name: "libarrie-test",
      version: "0.1.0",
      title: None,
      description: None,
      website_url: None,
      icons: [],
    )
  let assert Ok(connection) = client.connect(created, info)
  connection
}

fn call(
  c: client.Client,
  name: String,
  arguments: List(#(String, Value)),
) -> #(String, Bool) {
  let #(text, _, is_error) = call_full(c, name, arguments)
  #(text, is_error)
}

/// A tool's text, its structured content and whether it's an error.
fn call_full(
  c: client.Client,
  name: String,
  arguments: List(#(String, Value)),
) -> #(String, Option(Value), Bool) {
  let #(_, outcome) =
    client.call_tool(
      c,
      actions.CallToolRequestParams(
        name:,
        arguments: Some(dict.from_list(arguments)),
        task: None,
        meta: None,
      ),
    )
  let assert Ok(actions.CallTool(result)) = outcome
  let text =
    list.map(result.content, fn(block) {
      case block {
        actions.TextBlock(actions.TextContent(text, _, _)) -> text
        _ -> ""
      }
    })
    |> string.concat
  #(text, result.structured_content, result.is_error == Some(True))
}

type Person {
  Person(subject: String, token: String, user_id: String, key: String, page_id: String)
}

/// Someone with a notebook "Field Notes" holding one transcribed page.
fn person_with_notes(app: router.App) -> Person {
  let subject = "mcp-" <> support.random_id()
  let token = support.token_for(subject, 0)
  let notebook = support.notebook(app, token, "Field Notes")
  let #(_, page_id) =
    support.upload_page(
      app,
      token,
      notebook,
      1,
      Some("Met Grace Hopper about the compiler budget"),
      "immediate",
    )
  support.drain(app)
  let user_id =
    support.sql_str(app, "select user_id::text from identities where subject = $1", [subject])
  let assert Ok(Some(principal)) = accounts.by_user(app.ctx.db, user_id)
  let assert Ok(#(_, key)) = api_keys.create(app.ctx, principal, "Test agent")
  Person(subject:, token:, user_id:, key:, page_id:)
}

pub fn failed_authentication_gets_a_bearer_challenge_test() {
  let app = support.app()
  let url = serve(app, oauth_config(app))
  let metadata = "https://notes.example/.well-known/oauth-protected-resource/mcp"
  let missing = post(url, None)
  let assert 401 = missing.status
  let assert True = challenge(missing) == "Bearer resource_metadata=\"" <> metadata <> "\""
  let wrong = post(url, Some("Bearer lbk_not-a-real-key"))
  let assert 401 = wrong.status
  let assert True =
    challenge(wrong)
    == "Bearer resource_metadata=\"" <> metadata <> "\", error=\"invalid_token\""
  let assert 401 = post(url, Some("Bearer not.a.jwt")).status
  let assert 401 = post(url, Some("Basic dXNlcjpwYXNz")).status
  // Protected-resource metadata names the identity provider.
  let base = string.drop_end(url, string.length("/mcp"))
  let assert Ok(config) = settings.load()
  list.each(
    ["/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-protected-resource"],
    fn(path) {
      let doc = get(base <> path)
      let assert 200 = doc.status
      let assert True = string.contains(doc.body, "\"resource\":\"" <> resource <> "\"")
      let assert True =
        string.contains(doc.body, "\"authorization_servers\":[\"" <> config.oidc_issuer <> "\"]")
    },
  )
}

pub fn api_key_only_servers_challenge_without_metadata_test() {
  let app = support.app()
  let url = serve(app, mcp.Config(..oauth_config(app), oauth: None))
  let missing = post(url, None)
  let assert 401 = missing.status
  let assert "Bearer realm=\"libarrie\"" = challenge(missing)
  let assert True =
    string.contains(challenge(post(url, Some("Bearer lbk_nope"))), "error=\"invalid_token\"")
  let base = string.drop_end(url, string.length("/mcp"))
  let assert 404 = get(base <> "/.well-known/oauth-protected-resource/mcp").status
}

pub fn an_agent_searches_and_reads_pages_with_an_api_key_test() {
  let app = support.app()
  let url = serve(app, oauth_config(app))
  let ada = person_with_notes(app)
  let c = connect(url, ada.key, None)
  let #(_, listed) = client.list_tools(c, None)
  let assert Ok(tools) = listed
  // A new tool or resource that returns note content (text, snippets or page
  // images, including thumbnails and image URLs) must honor `private` and
  // needs a privacy test (ADR 0017).
  let assert ["get_me", "get_text", "search"] =
    list.map(tools.tools, fn(t) { t.name }) |> list.sort(string.compare)
  let assert #(me, False) = call(c, "get_me", [])
  let assert True = string.contains(me, ada.user_id)
  let assert True = string.contains(me, "\"status\":\"active\"")
  // Search everything, then one notebook by name.
  let assert #(found, False) = call(c, "search", [#("query", VString("Grace Hopper"))])
  let assert True = string.contains(found, "\"name\":\"Field Notes\"")
  let assert True = string.contains(found, "\"page\":1")
  let assert #(found, False) =
    call(c, "search", [#("query", VString("compiler")), #("notebook", VString("field notes"))])
  let assert True = string.contains(found, "Hopper")
  // Read the page by notebook name and number.
  let assert #(text, False) =
    call(c, "get_text", [#("notebook", VString("Field Notes")), #("page", VInt(1))])
  let assert True = string.contains(text, "Met Grace Hopper about the compiler budget")
  // Mistakes come back as tool errors the agent can act on.
  let assert #(missing, True) =
    call(c, "get_text", [#("notebook", VString("Diary")), #("page", VInt(1))])
  let assert True = string.contains(missing, "\"Field Notes\"")
  let assert #(no_page, True) =
    call(c, "get_text", [#("notebook", VString("Field Notes")), #("page", VInt(9))])
  let assert True = string.contains(no_page, "has no page 9")
  let assert #(_, True) = call(c, "get_text", [#("notebook", VString("Field Notes"))])
  let assert #(_, True) = call(c, "search", [])
  // Another person's key never sees these notes.
  let bea = person_with_notes(app)
  support.sql(app, "update notebooks set name = 'Other' where account_id = (select id from accounts where owner_user_id = $1::uuid)", [bea.user_id])
  let b = connect(url, bea.key, None)
  let assert #(_, True) = call(b, "get_text", [#("notebook", VString("Field Notes")), #("page", VInt(1))])
}

pub fn the_2025_protocol_binds_sessions_to_the_user_test() {
  let app = support.app()
  let url = serve(app, oauth_config(app))
  let ada = person_with_notes(app)
  let c = connect(url, ada.key, Some(jsonrpc.legacy_protocol_version))
  let assert #(me, False) = call(c, "get_me", [])
  let assert True = string.contains(me, ada.user_id)
  let assert #(text, False) =
    call(c, "get_text", [#("notebook", VString("Field Notes")), #("page", VInt(1))])
  let assert True = string.contains(text, "Grace Hopper")
}

fn rpc(
  url: String,
  key: String,
  session: option.Option(String),
  body: String,
) -> response.Response(String) {
  let assert Ok(req) = request.to(url)
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("accept", "application/json, text/event-stream")
    |> request.set_header("authorization", "Bearer " <> key)
    |> request.set_body(body)
  let req = case session {
    Some(id) ->
      req
      |> request.set_header("mcp-session-id", id)
      |> request.set_header("mcp-protocol-version", jsonrpc.legacy_protocol_version)
    None -> req
  }
  let assert Ok(resp) = httpc.send(req)
  resp
}

/// Two API replicas share the database: a 2025-11-25 session started on one
/// is served by the other, with no sticky routing.
pub fn sessions_work_across_replicas_test() {
  let app = support.app()
  let first = serve(app, oauth_config(app))
  let second = serve(app, oauth_config(app))
  let ada = person_with_notes(app)
  let initialized =
    rpc(
      first,
      ada.key,
      None,
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\""
        <> jsonrpc.legacy_protocol_version
        <> "\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1\"}}}",
    )
  let assert 200 = initialized.status
  let assert Ok(session) = response.get_header(initialized, "mcp-session-id")
  let assert 202 =
    rpc(first, ada.key, Some(session), "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}").status
  let call =
    rpc(
      second,
      ada.key,
      Some(session),
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"get_me\",\"arguments\":{}}}",
    )
  let assert 200 = call.status
  let assert True = string.contains(call.body, ada.user_id)
  // The session stays bound to its user on every replica.
  let bea = person_with_notes(app)
  let assert 404 =
    rpc(
      second,
      bea.key,
      Some(session),
      "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"get_me\",\"arguments\":{}}}",
    ).status
}

pub fn oauth_access_tokens_need_the_mcp_audience_test() {
  let app = support.app()
  let url = serve(app, oauth_config(app))
  let ada = person_with_notes(app)
  // A token for the API (audience `libarrie`) is refused.
  let assert 401 = post(url, Some("Bearer " <> ada.token)).status
  let assert Ok(config) = settings.load()
  let token =
    identity.mint_development_token(
      "test-dev-secret",
      config.oidc_issuer,
      resource,
      ada.subject,
      "Ada",
      support.now_seconds(),
      3600,
    )
  let c = connect(url, token, None)
  let assert #(me, False) = call(c, "get_me", [])
  let assert True = string.contains(me, ada.user_id)
}

pub fn revoked_keys_and_blocked_accounts_lose_access_test() {
  let app = support.app()
  let url = serve(app, oauth_config(app))
  let ada = person_with_notes(app)
  let c = connect(url, ada.key, None)
  let owner = person_with_notes(app)
  support.sql(app, "update users set role = 'owner' where id = $1::uuid", [owner.user_id])
  let assert Ok(_) = moderation.block(app.ctx, owner.user_id, ada.user_id, "")
  let assert #(blocked, True) = call(c, "search", [#("query", VString("Hopper"))])
  let assert True = string.contains(blocked, "blocked")
  let assert #(_, False) = call(c, "get_me", [])
  let assert Ok(_) = moderation.unblock(app.ctx, owner.user_id, ada.user_id)
  let assert #(_, False) = call(c, "search", [#("query", VString("Hopper"))])
  let assert Ok([key]) = api_keys.list(app.ctx.db, ada.user_id)
  let assert Ok(_) = api_keys.revoke(app.ctx, ada.user_id, key.id)
  let assert 401 = post(url, Some("Bearer " <> ada.key)).status
}

pub fn api_keys_do_not_work_on_the_api_test() {
  let app = support.app()
  let ada = person_with_notes(app)
  let assert 401 = support.call(app, http.Get, "/v1/me", ada.key, None, []).status
  let assert 401 = support.call(app, http.Get, "/v1/notebooks", ada.key, None, []).status
}

/// `/v1` returns the text of private pages, so a token for the MCP audience
/// must not work there (ADR 0017).
pub fn mcp_tokens_do_not_work_on_the_api_test() {
  let app = support.app()
  let ada = person_with_notes(app)
  let assert Ok(config) = settings.load()
  let mint = fn(audience) {
    identity.mint_development_token(
      support.dev_secret,
      config.oidc_issuer,
      audience,
      ada.subject,
      "Test User",
      support.now_seconds(),
      3600,
    )
  }
  let reads = fn(token) {
    [
      support.call(app, http.Get, "/v1/notebooks", token, None, []).status,
      support.call(app, http.Get, "/v1/pages/" <> ada.page_id, token, None, []).status,
    ]
  }
  let assert [200, 200] = reads(mint(config.oidc_audience))
  let assert [401, 401] = reads(mint(settings.mcp_audience(config)))
}

/// A development-issuer token whose `aud` is a list.
fn mint_token(
  secret: String,
  issuer: String,
  audiences: List(String),
  subject: String,
  expires_at: Int,
) -> String {
  identity.sign_hs256(secret, [
    #("iss", json.string(issuer)),
    #("sub", json.string(subject)),
    #("aud", json.array(audiences, json.string)),
    #("exp", json.int(expires_at)),
  ])
}

/// A token whose audience lists both would work on `/mcp` too, so every
/// `/v1` bearer path refuses it, naming both audiences (ADR 0017).
pub fn tokens_with_both_audiences_do_not_work_on_the_api_test() {
  let app = support.app()
  let ada = person_with_notes(app)
  let assert Ok(config) = settings.load()
  let oidc = config.oidc_audience
  let mcp = settings.mcp_audience(config)
  let token_for = fn(subject, audiences) {
    mint_token(
      support.dev_secret,
      config.oidc_issuer,
      audiences,
      subject,
      support.now_seconds() + 3600,
    )
  }
  let fetch = fn(path, token) {
    support.call(app, http.Get, path, token, None, [])
  }
  let paths = [
    "/v1/notebooks",
    "/v1/pages/" <> ada.page_id,
    "/v1/me",
    "/img/" <> support.uuid() <> "/thumb",
  ]
  let names_both = fn(message) {
    string.contains(message, "\"" <> oidc <> "\"")
    && string.contains(message, "\"" <> mcp <> "\"")
  }
  // Either order, and with a third audience, as providers often add one.
  list.each(
    [[oidc, mcp], [mcp, oidc], [oidc, mcp, "https://other.example"]],
    fn(audiences) {
      let token = token_for(ada.subject, audiences)
      list.each(paths, fn(path) {
        let reply = fetch(path, token)
        let assert 401 = reply.status
        let assert "authentication_required" =
          support.str(reply, ["error", "code"])
        let message = support.str(reply, ["error", "message"])
        let assert True = names_both(message)
        // Only configured values, never strings from the token.
        let assert False = string.contains(message, "other.example")
      })
    },
  )
  // Ada's API token still works, so the image's 401 came from
  // authentication and not from the lookup.
  let api = token_for(ada.subject, [oidc])
  let assert [200, 200, 200, 404] =
    list.map(paths, fn(path) { fetch(path, api).status })
  // Account creation after a purge refuses it too. The router can't get
  // there with such a token, because `principal` refuses it first.
  let claims = fn(token) {
    simulate.request(http.Post, "/v1/accounts")
    |> simulate.header("authorization", "Bearer " <> token)
    |> auth.bearer_claims(app.auth, _)
  }
  let assert Error(refused) = claims(token_for(ada.subject, [oidc, mcp]))
  let assert 401 = refused.status
  let assert "authentication_required" = refused.code
  let assert True = names_both(refused.message)
  let assert Ok(accepted) = claims(api)
  let assert True = accepted.subject == ada.subject
  // A refused token provisions nothing.
  let subject = "mcp-" <> support.random_id()
  let assert 401 = fetch("/v1/me", token_for(subject, [oidc, mcp])).status
  let assert 0 =
    support.sql_int(
      app,
      "select count(*)::int from identities where subject = $1",
      [subject],
    )
}

/// `/mcp` still accepts such a token. It is served with the `/v1` verifier
/// that `serve` hands to `mcp_config`, so a refusal carried by that verifier
/// would fail here.
pub fn tokens_with_both_audiences_still_work_on_mcp_test() {
  let app = support.app()
  let ada = person_with_notes(app)
  let assert Ok(config) = settings.load()
  // With the development issuer's secret set, this is the HS256 verifier.
  let assert Ok(verifier) = libarrie_api.verifier(config)
  // MCP OAuth is on only without the development issuer.
  let cfg = settings.Settings(..config, development_issuer_secret: None)
  let url =
    serve(
      app,
      libarrie_api.mcp_config(
        cfg,
        app.ctx,
        verifier,
        "test-secret-key-base-0123456789abcdef-0123456789abcdef",
      ),
    )
  let token =
    mint_token(
      support.dev_secret,
      config.oidc_issuer,
      [config.oidc_audience, settings.mcp_audience(cfg)],
      ada.subject,
      support.now_seconds() + 3600,
    )
  let c = connect(url, token, None)
  let assert #(me, False) = call(c, "get_me", [])
  let assert True = string.contains(me, ada.user_id)
  // One token, two outcomes.
  let assert 401 =
    support.call(app, http.Get, "/v1/notebooks", token, None, []).status
}

/// Only the MCP audience itself, compared exactly, makes `/v1` refuse a
/// token.
pub fn api_tokens_with_other_audiences_still_work_test() {
  let app = support.app()
  let ada = person_with_notes(app)
  let assert Ok(config) = settings.load()
  let oidc = config.oidc_audience
  let mcp = settings.mcp_audience(config)
  list.each(
    [
      [oidc],
      [oidc, "https://other.example"],
      // No normalization: a trailing slash or a change of case is another
      // audience.
      [oidc, mcp <> "/"],
      [oidc, string.uppercase(mcp)],
    ],
    fn(audiences) {
      let token =
        mint_token(
          support.dev_secret,
          config.oidc_issuer,
          audiences,
          ada.subject,
          support.now_seconds() + 3600,
        )
      let read = fn(path) {
        support.call(app, http.Get, path, token, None, []).status
      }
      let assert [200, 200] =
        list.map(["/v1/notebooks", "/v1/pages/" <> ada.page_id], read)
    },
  )
}

/// A token that fails verification gets the generic error, which names no
/// audience, whatever its `aud` lists.
pub fn failed_tokens_with_both_audiences_get_the_generic_error_test() {
  let app = support.app()
  let ada = person_with_notes(app)
  let assert Ok(config) = settings.load()
  let oidc = config.oidc_audience
  let mcp = settings.mcp_audience(config)
  let secret = support.dev_secret
  let issuer = config.oidc_issuer
  let now = support.now_seconds()
  let sign = fn(secret, issuer, audiences, expires_at) {
    mint_token(secret, issuer, audiences, ada.subject, expires_at)
  }
  list.each(
    [
      sign("wrong-secret", issuer, [oidc, mcp], now + 3600),
      // Expired: the test verifier allows no leeway.
      sign(secret, issuer, [oidc, mcp], now - 60),
      sign(secret, "https://other-issuer.example", [oidc, mcp], now + 3600),
      sign(secret, issuer, [mcp], now + 3600),
      sign(secret, issuer, [mcp, "https://other.example"], now + 3600),
    ],
    fn(token) {
      let reply = support.call(app, http.Get, "/v1/notebooks", token, None, [])
      let assert 401 = reply.status
      let assert "authentication_required" =
        support.str(reply, ["error", "code"])
      let assert "Sign in to continue." =
        support.str(reply, ["error", "message"])
      let assert False = string.contains(reply.body, mcp)
    },
  )
}

/// The startup check compares the audience the MCP verifier really uses.
pub fn mcp_config_takes_its_audience_from_settings_test() {
  let app = support.app()
  let assert Ok(config) = settings.load()
  let verifier =
    identity.Verifier(
      issuer: config.oidc_issuer,
      audience: config.oidc_audience,
      keys: identity.Hs256Secret(support.dev_secret),
      leeway_seconds: 0,
    )
  list.each([None, Some("https://mcp.example")], fn(audience) {
    let cfg =
      settings.Settings(
        ..config,
        development_issuer_secret: None,
        mcp_oauth_audience: audience,
      )
    let built =
      libarrie_api.mcp_config(
        cfg,
        app.ctx,
        verifier,
        "test-secret-key-base-0123456789abcdef-0123456789abcdef",
      )
    let assert True = built.resource == settings.mcp_resource(cfg)
    let assert Some(oauth) = built.oauth
    let assert True = oauth.verifier.audience == settings.mcp_audience(cfg)
  })
}

/// And the audience the `/v1` verifier really uses. The client ID and the
/// MCP audience differ from it, so taking either would fail.
pub fn api_verifier_checks_the_oidc_audience_test() {
  let assert Ok(config) = settings.load()
  let cfg =
    settings.Settings(
      ..config,
      oidc_client_id: config.oidc_audience <> "-web",
      mcp_oauth_audience: Some(config.oidc_audience <> "-mcp"),
    )
  let assert Ok(verifier) = libarrie_api.verifier(cfg)
  let assert True = verifier.audience == cfg.oidc_audience
}

/// And `/v1` refuses the audience the MCP verifier uses, with either
/// identity provider. Taking the MCP resource URL, or setting the audience
/// only for a real provider, would fail.
pub fn api_auth_takes_the_mcp_audience_from_settings_test() {
  let assert Ok(config) = settings.load()
  let verifier =
    identity.Verifier(
      issuer: config.oidc_issuer,
      audience: config.oidc_audience,
      keys: identity.Hs256Secret(support.dev_secret),
      leeway_seconds: 0,
    )
  list.each([None, Some("https://mcp.example")], fn(audience) {
    list.each([None, Some(support.dev_secret)], fn(secret) {
      let cfg =
        settings.Settings(
          ..config,
          development_issuer_secret: secret,
          mcp_oauth_audience: audience,
          web_origin: "https://notes.example",
          internal_api_token: Some(support.internal_token),
        )
      let built = libarrie_api.api_auth(cfg, verifier)
      let assert True = built.mcp_audience == settings.mcp_audience(cfg)
      let assert True = built.verifier.audience == cfg.oidc_audience
      let assert True = built.web_origin == cfg.web_origin
      let assert True = built.internal_token == cfg.internal_api_token
    })
  })
}

/// Each search result's notebook ID, notebook name, page, snippet and keys.
fn search_results(
  structured: Option(Value),
) -> List(#(String, String, Int, Option(String), List(String))) {
  let assert Some(value) = structured
  let assert Ok(results) =
    json.parse(
      codec_value.to_json(value) |> json.to_string,
      decode.at(
        ["results"],
        decode.list({
          use id <- decode.subfield(["notebook", "id"], decode.string)
          use name <- decode.subfield(["notebook", "name"], decode.string)
          use page <- decode.field("page", decode.int)
          // Absent, never null: null fails this decoder.
          use snippet <- decode.optional_field("snippet", None, decode.map(decode.string, Some))
          use all <- decode.then(decode.dict(decode.string, decode.dynamic))
          decode.success(#(id, name, page, snippet, dict.keys(all) |> list.sort(string.compare)))
        }),
      ),
    )
  results
}

fn instructions(info: client.ConnectionInfo) -> String {
  case info {
    client.Modern(result) -> result.instructions
    client.Legacy(result) -> result.instructions
  }
  |> option.unwrap("")
}

pub fn private_notebooks_hide_text_from_agents_test() {
  let app = support.app()
  let url = serve(app, oauth_config(app))
  let ada = person_with_notes(app)
  support.raise_limits(app, ada.token)
  let journal = support.notebook(app, ada.token, "Journal")
  let #(_, _) =
    support.upload_page(app, ada.token, journal, 2, Some("Grace Hopper secret recipe"), "immediate")
  support.drain(app)
  support.set_private(app, ada.token, journal, True)
  let #(c, info) = connect_with_info(url, ada.key, None)
  let private_entry = fn(results) {
    list.find(results, fn(r: #(String, String, Int, Option(String), List(String))) {
      r.0 == journal
    })
  }

  // Search says where a private page matched, in the structured content and
  // the text block alike, whether or not the notebook argument names it.
  list.each(
    [
      [#("query", VString("Hopper"))],
      [#("query", VString("Hopper")), #("notebook", VString("Journal"))],
      [#("query", VString("Hopper")), #("notebook", VString(journal))],
    ],
    fn(arguments) {
      let assert #(text, structured, False) = call_full(c, "search", arguments)
      let results = search_results(structured)
      let assert Ok(#(_, "Journal", 2, None, ["notebook", "page"])) = private_entry(results)
      let assert False = string.contains(text, "recipe")
      let assert True = string.contains(text, journal)
      let assert True = string.contains(text, "\"name\":\"Journal\"")
      let assert True = string.contains(text, "\"page\":2")
    },
  )
  // The other notebook keeps its snippets.
  let assert #(_, structured, False) = call_full(c, "search", [#("query", VString("Hopper"))])
  let assert Ok(#(_, "Field Notes", 1, Some(snippet), _)) =
    list.find(search_results(structured), fn(r) { r.1 == "Field Notes" })
  let assert True = string.contains(snippet, "Hopper")

  // get_text refuses, by name or ID, whether or not the page exists.
  list.each(
    [
      [#("notebook", VString("Journal")), #("page", VInt(2))],
      [#("notebook", VString(journal)), #("page", VInt(2))],
      [#("notebook", VString("Journal")), #("page", VInt(9))],
    ],
    fn(arguments) {
      let assert #(text, True) = call(c, "get_text", arguments)
      let assert True = string.contains(text, "private")
      let assert False = string.contains(text, "recipe")
      let assert False = string.contains(text, "has no page")
    },
  )

  // Toggling applies to the next call, both ways.
  support.set_private(app, ada.token, journal, False)
  let assert #(_, structured, False) = call_full(c, "search", [#("query", VString("Hopper"))])
  let assert Ok(#(_, _, 2, Some(snippet), _)) = private_entry(search_results(structured))
  let assert True = string.contains(snippet, "recipe")
  let assert #(text, False) =
    call(c, "get_text", [#("notebook", VString("Journal")), #("page", VInt(2))])
  let assert "Grace Hopper secret recipe" = text
  support.set_private(app, ada.token, journal, True)
  let assert #(text, structured, False) = call_full(c, "search", [#("query", VString("Hopper"))])
  let assert Ok(#(_, _, 2, None, _)) = private_entry(search_results(structured))
  let assert False = string.contains(text, "recipe")
  let assert #(text, True) =
    call(c, "get_text", [#("notebook", VString("Journal")), #("page", VInt(2))])
  let assert False = string.contains(text, "recipe")

  // The tools and the server instructions tell agents.
  let #(_, listed) = client.list_tools(c, None)
  let assert Ok(tools) = listed
  list.each(["search", "get_text"], fn(name) {
    let assert Ok(tool) = list.find(tools.tools, fn(t) { t.name == name })
    let assert Some(description) = tool.description
    let assert True = string.contains(description, "private notebooks")
  })
  let assert True = string.contains(instructions(info), "private notebooks")
}

/// `get_text` reads the text and the page's current notebook in one
/// statement, so a change between its page lookup and its read is refused.
/// The page here is looked up before each change.
pub fn transcript_text_rechecks_privacy_test() {
  let app = support.app()
  let ada = person_with_notes(app)
  let db = app.ctx.db
  let account = support.account_id(app, ada.token)
  let assert Ok([field_notes]) = notebooks.named(db, account, "Field Notes")
  let assert Ok(page) = pages.by_number(db, account, field_notes.id, 1)
  let assert Ok(pages.Transcribed("Met Grace Hopper about the compiler budget")) =
    pages.transcript_text(db, account, page)
  support.raise_limits(app, ada.token)
  let journal = support.notebook(app, ada.token, "Journal")
  support.set_private(app, ada.token, journal, True)
  // Made private after the lookup.
  support.set_private(app, ada.token, field_notes.id, True)
  let assert Ok(pages.InPrivateNotebook("Field Notes")) = pages.transcript_text(db, account, page)
  support.set_private(app, ada.token, field_notes.id, False)
  // Moved into a private notebook after the lookup.
  let detail = support.call(app, http.Get, "/v1/pages/" <> ada.page_id, ada.token, None, [])
  let version = support.get(detail, ["page", "version"], decode.int)
  let assert 200 =
    support.call(
      app,
      http.Patch,
      "/v1/pages/" <> ada.page_id,
      ada.token,
      Some(json.object([#("notebook_id", json.string(journal))])),
      [#("if-match", "\"v" <> int.to_string(version) <> "\"")],
    ).status
  let assert Ok(pages.InPrivateNotebook("Journal")) = pages.transcript_text(db, account, page)
  // A page without a transcript yet, in a public notebook.
  let #(_, _) = support.upload_page(app, ada.token, field_notes.id, 2, Some("Not read yet"), "immediate")
  let assert Ok(fresh) = pages.by_number(db, account, field_notes.id, 2)
  let assert Ok(pages.NotTranscribed) = pages.transcript_text(db, account, fresh)
}

pub fn people_manage_api_keys_in_settings_test() {
  let app = support.app()
  let subject = "keys-" <> support.random_id()
  let #(session, csrf) = web_test.sign_in(app, subject)
  let user_id =
    support.sql_str(app, "select user_id::text from identities where subject = $1", [subject])
  let page = web_get(app, "/settings/api-keys", session)
  let assert 200 = page.status
  let assert True = string.contains(simulate.read_body(page), "/mcp")
  let created = web_post(app, "/settings/api-keys", session, csrf, [#("name", "Laptop")])
  let assert 200 = created.status
  let body = simulate.read_body(created)
  let assert Ok(#(_, rest)) = string.split_once(body, "value=\"lbk_")
  let assert Ok(#(secret, _)) = string.split_once(rest, "\"")
  let key = "lbk_" <> secret
  let assert Ok(Some(owner)) = api_keys.authenticate(app.ctx.db, key)
  let assert True = owner == user_id
  // The key is never shown again.
  let assert False =
    string.contains(simulate.read_body(web_get(app, "/settings/api-keys", session)), secret)
  let assert Ok([listed]) = api_keys.list(app.ctx.db, user_id)
  let assert "Laptop" = listed.name
  let revoked =
    web_post(app, "/settings/api-keys/" <> listed.id <> "/revoke", session, csrf, [])
  let assert 303 = revoked.status
  let assert Ok(None) = api_keys.authenticate(app.ctx.db, key)
  // Creating a key needs a recent sign-in.
  support.sql(
    app,
    "update web_sessions set auth_time = now() - interval '10 minutes' where user_id = $1::uuid",
    [user_id],
  )
  let assert 403 = web_post(app, "/settings/api-keys", session, csrf, [#("name", "Late")]).status
  let assert Ok([]) = api_keys.list(app.ctx.db, user_id)
}

fn web_get(app: router.App, path: String, session: String) {
  simulate.request(http.Get, path)
  |> simulate.header("cookie", session)
  |> router.handle(app, _)
}

fn web_post(
  app: router.App,
  path: String,
  session: String,
  csrf: String,
  fields: List(#(String, String)),
) {
  simulate.request(http.Post, path)
  |> simulate.header("cookie", session)
  |> simulate.header("origin", "http://localhost:8080")
  |> simulate.form_body([#("csrf_token", csrf), ..fields])
  |> router.handle(app, _)
}
