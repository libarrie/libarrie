//// Web UI tests (section 17 scenarios 63-65 and the web verification list):
//// OIDC sign-in through the development issuer, sessions, CSRF, htmx
//// fragment vs full-page behavior, expired-session handling, CSP and inert
//// user text.

import gleam/dynamic/decode
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/uri
import libarrie/api/auth
import libarrie/api/router
import libarrie/web/config
import support
import wisp/simulate

pub type Res {
  Res(status: Int, headers: List(#(String, String)), body: String)
}

fn send(app: router.App, req) -> Res {
  let resp = router.handle(app, req)
  Res(resp.status, resp.headers, simulate.read_body(resp))
}

fn header(res: Res, name: String) -> String {
  list.key_find(res.headers, name) |> result_unwrap("")
}

fn result_unwrap(r: Result(a, b), default: a) -> a {
  case r {
    Ok(v) -> v
    Error(_) -> default
  }
}

/// `name=value` pairs from every Set-Cookie header.
fn cookies(res: Res) -> List(#(String, String)) {
  res.headers
  |> list.filter(fn(h) { h.0 == "set-cookie" })
  |> list.filter_map(fn(h) {
    let assert [pair, ..] = string.split(h.1, ";")
    string.split_once(pair, "=")
  })
}

fn cookie_header(pairs: List(#(String, String))) -> String {
  pairs |> list.map(fn(p) { p.0 <> "=" <> p.1 }) |> string.join("; ")
}

fn get(app: router.App, path: String, cookie: String) -> Res {
  simulate.request(http.Get, path)
  |> simulate.header("cookie", cookie)
  |> send(app, _)
}

fn path_and_query(location: String) -> String {
  case string.split_once(location, "localhost:8080") {
    Ok(#(_, rest)) -> rest
    Error(_) -> location
  }
}

/// Sign in through the built-in development issuer, returning the session
/// cookie header and the page's CSRF token.
pub fn sign_in(app: router.App, subject: String) -> #(String, String) {
  let start = get(app, "/auth/login?return_to=%2Fnotebooks", "")
  let assert 303 = start.status
  let state_cookie = cookie_header(cookies(start))
  let authorize = path_and_query(header(start, "location"))
  let assert True = string.starts_with(authorize, "/dev-issuer/authorize?")
  let assert Ok(#(_, query)) = string.split_once(authorize, "?")
  let assert Ok(params) = uri.parse_query(query)
  let assert Ok("S256") = list.key_find(params, "code_challenge_method")
  let form = get(app, authorize, "")
  let assert 200 = form.status
  let field = fn(name) { list.key_find(params, name) |> result_unwrap("") }
  let submitted =
    simulate.request(http.Post, "/dev-issuer/authorize")
    |> simulate.form_body([
      #("client_id", field("client_id")),
      #("redirect_uri", field("redirect_uri")),
      #("state", field("state")),
      #("nonce", field("nonce")),
      #("code_challenge", field("code_challenge")),
      #("subject", subject),
      #("name", "Web Tester"),
    ])
    |> send(app, _)
  let assert 303 = submitted.status
  let callback = get(app, path_and_query(header(submitted, "location")), state_cookie)
  let assert 303 = callback.status
  let assert "/notebooks" = header(callback, "location")
  let session_pair =
    cookies(callback) |> list.find(fn(c) { c.0 == "libarrie_session" && c.1 != "" })
  let assert Ok(session_pair) = session_pair
  let session = cookie_header([session_pair])
  let page = get(app, "/notebooks", session)
  let assert 200 = page.status
  let assert Ok(#(_, after)) = string.split_once(page.body, "X-CSRF-Token&quot;:&quot;")
  let assert Ok(#(csrf, _)) = string.split_once(after, "&quot;")
  #(session, csrf)
}

pub fn oidc_sign_in_and_page_shell_test() {
  let app = support.app()
  let #(session, csrf) = sign_in(app, "web-" <> support.random_id())
  let assert True = string.length(csrf) > 20
  let page = get(app, "/notebooks", session)
  let assert True = string.starts_with(page.body, "<!doctype html>")
  let assert True = string.contains(page.body, "hx-history=\"false\"")
  let assert True = string.contains(page.body, "/static/js/htmx-2.0.11.min.js")
  let assert True = string.contains(page.body, "&quot;allowEval&quot;:false")
  let csp = header(page, "content-security-policy")
  let assert True = string.contains(csp, "default-src 'none'; script-src 'self'; style-src 'self';")
  let assert True = string.contains(csp, "frame-ancestors 'none'")
  let assert "nosniff" = header(page, "x-content-type-options")
  let assert "private, no-store" = header(page, "cache-control")
  // No inline scripts or style attributes anywhere in the document.
  let assert False = string.contains(page.body, " style=")
  let assert False = string.contains(page.body, "<script>")
  // The same route returns a fragment for htmx requests.
  let fragment =
    simulate.request(http.Get, "/notebooks")
    |> simulate.header("cookie", session)
    |> simulate.header("hx-request", "true")
    |> send(app, _)
  let assert False = string.contains(fragment.body, "<html")
  let assert True = string.contains(fragment.body, "notebooks-region")
  let assert "HX-Request" = header(fragment, "vary")
}

pub fn sign_in_rejects_bad_state_test() {
  let app = support.app()
  let start = get(app, "/auth/login", "")
  let state_cookie = cookie_header(cookies(start))
  let bad = get(app, "/auth/callback?code=forged&state=wrong", state_cookie)
  let assert 400 = bad.status
  let no_cookie = get(app, "/auth/callback?code=forged&state=wrong", "")
  let assert 400 = no_cookie.status
}

pub fn unauthenticated_navigation_and_htmx_test() {
  let app = support.app()
  let nav = get(app, "/notebooks", "")
  let assert 303 = nav.status
  let assert "/auth/login?return_to=/notebooks" = header(nav, "location")
  // htmx requests get 401 + HX-Redirect, never a login page in a fragment.
  let htmx =
    simulate.request(http.Get, "/pages/00000000-0000-0000-0000-000000000000/status")
    |> simulate.header("hx-request", "true")
    |> simulate.header("hx-current-url", "http://localhost:8080/pages/abc")
    |> send(app, _)
  let assert 401 = htmx.status
  let assert "/auth/login?return_to=/pages/abc" = header(htmx, "hx-redirect")
  let assert "" = htmx.body
  // Open redirects are refused.
  let evil = get(app, "/auth/login?return_to=%2F%2Fevil.example", "")
  let assert 303 = evil.status
}

pub fn csrf_and_inert_user_text_test() {
  let app = support.app()
  let #(session, csrf) = sign_in(app, "web-" <> support.random_id())
  let name = "<script>alert(1)</script> hx-get=\"/evil\""
  let without =
    simulate.request(http.Post, "/notebooks")
    |> simulate.header("cookie", session)
    |> simulate.header("origin", "http://localhost:8080")
    |> simulate.form_body([#("name", name)])
    |> send(app, _)
  let assert 403 = without.status
  let foreign =
    simulate.request(http.Post, "/notebooks")
    |> simulate.header("cookie", session)
    |> simulate.header("origin", "https://evil.example")
    |> simulate.form_body([#("name", name), #("csrf_token", csrf)])
    |> send(app, _)
  let assert 403 = foreign.status
  let created =
    simulate.request(http.Post, "/notebooks")
    |> simulate.header("cookie", session)
    |> simulate.header("origin", "http://localhost:8080")
    |> simulate.header("hx-request", "true")
    |> simulate.form_body([#("name", name), #("csrf_token", csrf)])
    |> send(app, _)
  let assert 200 = created.status
  let assert False = string.contains(created.body, "<script>alert")
  let assert True = string.contains(created.body, "&lt;script&gt;alert(1)&lt;/script&gt;")
  let assert True =
    string.contains(created.body, "<h2 class=\"notebook-name\" hx-disable>&lt;script&gt;")
}

pub fn transcript_editing_and_conflicts_test() {
  let app = support.app()
  let subject = "web-" <> support.random_id()
  let #(session, csrf) = sign_in(app, subject)
  let token = support.token_for(subject, 0)
  let notebook = support.notebook(app, token, "Edits")
  let #(_, page_id) = support.upload_page(app, token, notebook, 1, Some("original text"), "immediate")
  support.drain(app)
  let detail = get(app, "/pages/" <> page_id, session)
  let assert 200 = detail.status
  let assert True = string.contains(detail.body, "original text")
  let page = support.call(app, http.Get, "/v1/pages/" <> page_id, token, None, [])
  let revision = support.str(page, ["page", "revision_id"])
  let version = support.get(page, ["page", "content_version"], decode.int)
  let save = fn(text, content_version) {
    simulate.request(http.Post, "/pages/" <> page_id <> "/transcript")
    |> simulate.header("cookie", session)
    |> simulate.header("origin", "http://localhost:8080")
    |> simulate.header("hx-request", "true")
    |> simulate.form_body([
      #("csrf_token", csrf),
      #("source_revision_id", revision),
      #("content_version", int.to_string(content_version)),
      #("text", text),
      #("action", "save"),
    ])
    |> send(app, _)
  }
  let evil = "<script>steal()</script><div hx-get=\"/v1/me\" hx-trigger=\"load\">x</div>"
  let saved = save(evil, version)
  let assert 200 = saved.status
  let assert True = string.contains(saved.body, "&lt;script&gt;steal()&lt;/script&gt;")
  let assert False = string.contains(saved.body, "<div hx-get=\"/v1/me\"")
  // The transcript textarea sits inside an hx-disable container.
  let assert True = string.contains(saved.body, "<div hx-disable><textarea class=\"transcript\" id=\"transcript-text\"")
  // A stale save is a conflict that keeps the user's unsaved text.
  let stale = save("my offline edit", version)
  let assert 412 = stale.status
  let assert True = string.contains(stale.body, "changed since you opened it")
  let assert True = string.contains(stale.body, "my offline edit")
  let page = get(app, "/pages/" <> page_id, session)
  let assert True = string.contains(page.body, "Edited by you.")
}

pub fn theme_preference_is_rendered_before_paint_test() {
  let app = support.app()
  let #(session, _) = sign_in(app, "web-" <> support.random_id())
  let assert True = string.contains(get(app, "/notebooks", session).body, "data-theme=\"system\"")
  let dark = get(app, "/notebooks", session <> "; libarrie_theme=dark")
  let assert True = string.contains(dark.body, "<html data-theme=\"dark\" lang=\"en\">")
  let bogus = get(app, "/notebooks", session <> "; libarrie_theme=%22%3E%3Cscript")
  let assert True = string.contains(bogus.body, "data-theme=\"system\"")
}

pub fn search_page_highlights_matches_test() {
  let app = support.app()
  let subject = "web-" <> support.random_id()
  let #(session, csrf) = sign_in(app, subject)
  let token = support.token_for(subject, 0)
  let notebook = support.notebook(app, token, "Searchable")
  let _ = support.upload_page(app, token, notebook, 3, Some("Lunch with Margaret Hamilton about Apollo"), "immediate")
  support.drain(app)
  let results =
    simulate.request(http.Post, "/search")
    |> simulate.header("cookie", session)
    |> simulate.header("origin", "http://localhost:8080")
    |> simulate.header("hx-request", "true")
    |> simulate.form_body([#("csrf_token", csrf), #("query", "hamilton"), #("notebook_id", "")])
    |> send(app, _)
  let assert 200 = results.status
  let assert True = string.contains(results.body, "<mark>Hamilton</mark>")
  let assert True = string.contains(results.body, "Searchable · Page 3")
}

pub fn search_page_hides_private_snippets_test() {
  let app = support.app()
  let subject = "web-" <> support.random_id()
  let #(session, csrf) = sign_in(app, subject)
  let token = support.token_for(subject, 0)
  let open = support.notebook(app, token, "Searchable")
  support.raise_limits(app, token)
  let secret = support.notebook(app, token, "Secret")
  let _ = support.upload_page(app, token, open, 3, Some("Lunch with Margaret Hamilton about Apollo"), "immediate")
  let _ = support.upload_page(app, token, secret, 5, Some("Margaret Hamilton surprise party plans"), "immediate")
  support.drain(app)
  support.set_private(app, token, secret, True)
  let results =
    simulate.request(http.Post, "/search")
    |> simulate.header("cookie", session)
    |> simulate.header("origin", "http://localhost:8080")
    |> simulate.header("hx-request", "true")
    |> simulate.form_body([#("csrf_token", csrf), #("query", "hamilton"), #("notebook_id", "")])
    |> send(app, _)
  let assert 200 = results.status
  // Both hits link to their pages; only the open one shows its text.
  let assert True = string.contains(results.body, "Searchable · Page 3")
  let assert True = string.contains(results.body, "Secret · Page 5")
  let assert True = string.contains(results.body, "<mark>Hamilton</mark>")
  let assert True =
    string.contains(results.body, "Private notebook. The matching text isn&#39;t shown.")
  let assert False = string.contains(results.body, "surprise")
  let assert False = string.contains(results.body, "party")
}

pub fn v1_accepts_the_browser_session_with_csrf_test() {
  let app = support.app()
  let #(session, csrf) = sign_in(app, "web-" <> support.random_id())
  let ok =
    simulate.request(http.Post, "/v1/notebooks")
    |> simulate.header("cookie", session)
    |> simulate.header("origin", "http://localhost:8080")
    |> simulate.header("x-csrf-token", csrf)
    |> simulate.json_body(json.object([#("name", json.string("From the upload module"))]))
    |> send(app, _)
  let assert 201 = ok.status
  let missing =
    simulate.request(http.Post, "/v1/notebooks")
    |> simulate.header("cookie", session)
    |> simulate.header("origin", "http://localhost:8080")
    |> simulate.json_body(json.object([#("name", json.string("No CSRF"))]))
    |> send(app, _)
  let assert 403 = missing.status
}

pub fn logout_revokes_the_session_test() {
  let app = support.app()
  let #(session, csrf) = sign_in(app, "web-" <> support.random_id())
  let out =
    simulate.request(http.Post, "/auth/logout")
    |> simulate.header("cookie", session)
    |> simulate.header("origin", "http://localhost:8080")
    |> simulate.form_body([#("csrf_token", csrf)])
    |> send(app, _)
  let assert 303 = out.status
  let assert 303 = get(app, "/notebooks", session).status
}

pub fn static_assets_are_served_test() {
  let app = support.app()
  let css = get(app, "/static/css/app.css", "")
  let assert 200 = css.status
  let assert True = string.contains(header(css, "content-type"), "text/css")
  let assert True = string.contains(css.body, "--highlight: #F5BC2F")
  let assert 200 = get(app, "/static/js/htmx-2.0.11.min.js", "").status
}

/// Secure, `__Host-` cookies on HTTPS; plain cookies on a local HTTP origin,
/// which Safari would otherwise reject (sign-in failed with "missing state").
pub fn cookies_follow_the_origin_scheme_test() {
  let app = support.app()
  let set_cookie = fn(res: Res) {
    res.headers |> list.filter(fn(h) { h.0 == "set-cookie" }) |> list.map(fn(h) { h.1 })
  }
  // Local HTTP origin (the test default): no prefix, no Secure.
  let assert [state] = set_cookie(get(app, "/auth/login", ""))
  let assert True = string.starts_with(state, "libarrie_oidc=")
  let assert False = string.contains(state, "Secure")
  let #(session, _) = sign_in(app, "web-cookie-" <> support.random_id())
  let assert Ok(#("libarrie_session", token)) = string.split_once(session, "=")

  // HTTPS origin: __Host- and Secure, and only that name is trusted.
  let https =
    router.App(
      ..app,
      auth: auth.Auth(..app.auth, web_origin: "https://libarrie.example"),
      web: config.Web(..app.web, origin: "https://libarrie.example"),
    )
  let assert [state] = set_cookie(get(https, "/auth/login", ""))
  let assert True = string.starts_with(state, "__Host-libarrie_oidc=")
  let assert True = string.contains(state, "; Secure")
  let assert 200 = get(https, "/notebooks", "__Host-libarrie_session=" <> token).status
  let assert 303 = get(https, "/notebooks", "libarrie_session=" <> token).status
  let assert 200 = get(https, "/v1/me", "__Host-libarrie_session=" <> token).status
  let assert 401 = get(https, "/v1/me", "libarrie_session=" <> token).status
}
