//// Page shell, security headers and response helpers (section 13).
////
//// - A navigable route returns a complete document on ordinary navigation
////   and history restore, and only the main fragment for htmx requests
////   (`Vary: HX-Request`).
//// - Every response carries the strict Content Security Policy. No inline
////   scripts or style attributes are rendered; htmx is configured through
////   its meta tag with eval and script tags disabled.
//// - Authenticated pages disable htmx history snapshots (`hx-history`), so
////   private note HTML never lands in localStorage.
//// - The theme (System / Light / Dark) comes from a non-sensitive cookie and
////   is rendered on `<html>` before first paint; System uses
////   `prefers-color-scheme` in CSS.

import gleam/bit_array
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import libarrie/web/config.{type Web}
import lustre/attribute.{attribute, class}
import lustre/element.{type Element}
import lustre/element/html
import wisp

pub const theme_cookie = "libarrie_theme"

pub const htmx_file = "htmx-2.0.11.min.js"

pub type Shell {
  Shell(
    title: String,
    theme: String,
    /// Signed-in display name; `None` renders the signed-out shell.
    user: Option(String),
    csrf_token: Option(String),
    active: String,
    /// Shows the Admin link.
    admin: Bool,
  )
}

pub fn theme(req: wisp.Request) -> String {
  case request.get_cookies(req) |> list.key_find(theme_cookie) {
    Ok("light") -> "light"
    Ok("dark") -> "dark"
    _ -> "system"
  }
}

pub fn is_htmx(req: wisp.Request) -> Bool {
  request.get_header(req, "hx-request") == Ok("true")
  && request.get_header(req, "hx-history-restore-request") != Ok("true")
}

pub fn csp(web: Web) -> String {
  let form_action =
    ["'self'", ..list.flat_map(web.extensions, fn(e) { e.form_action_origins })]
    |> string.join(" ")
  "default-src 'none'; script-src 'self'; style-src 'self'; "
  <> "img-src 'self' blob: data: " <> web.download_origin <> "; "
  <> "connect-src 'self' " <> web.upload_origin <> "; "
  <> "font-src 'self'; form-action " <> form_action <> "; frame-ancestors 'none'; "
  <> "base-uri 'none'; object-src 'none'"
}

pub fn security_headers(response: wisp.Response, web: Web) -> wisp.Response {
  let response =
    response
    |> wisp.set_header("content-security-policy", csp(web))
    |> wisp.set_header("x-content-type-options", "nosniff")
    |> wisp.set_header("referrer-policy", "same-origin")
  case web.hosted {
    True ->
      wisp.set_header(response, "strict-transport-security", "max-age=63072000; includeSubDomains")
    False -> response
  }
}

const htmx_config = "{\"allowEval\":false,\"allowScriptTags\":false,\"includeIndicatorStyles\":false,\"historyCacheSize\":0,\"refreshOnHistoryMiss\":true,\"selfRequestsOnly\":true,\"responseHandling\":[{\"code\":\"204\",\"swap\":false},{\"code\":\"[23]..\",\"swap\":true},{\"code\":\"401\",\"swap\":false,\"error\":true},{\"code\":\"4..\",\"swap\":true},{\"code\":\"5..\",\"swap\":true,\"error\":true}]}"

/// The complete document around `content`.
pub fn document(shell: Shell, content: List(Element(a))) -> String {
  let body_attributes = case shell.csrf_token {
    Some(token) -> [
      attribute(
        "hx-headers",
        json.to_string(json.object([#("X-CSRF-Token", json.string(token))])),
      ),
      attribute("hx-history", "false"),
    ]
    None -> []
  }
  html.html([attribute("lang", "en"), attribute("data-theme", shell.theme)], [
    html.head([], [
      html.meta([attribute("charset", "utf-8")]),
      html.meta([
        attribute.name("viewport"),
        attribute("content", "width=device-width, initial-scale=1"),
      ]),
      html.meta([attribute.name("htmx-config"), attribute("content", htmx_config)]),
      html.title([], shell.title <> " · Libarrie"),
      html.link([attribute.rel("stylesheet"), attribute.href("/static/css/app.css")]),
      html.link([attribute.rel("icon"), attribute.href("/static/img/icon.png")]),
      html.script([attribute.src("/static/js/" <> htmx_file), attribute("defer", "")], ""),
      html.script([attribute.src("/static/js/app.js"), attribute("defer", "")], ""),
      html.script([attribute.src("/static/js/md5.js"), attribute("defer", "")], ""),
      html.script([attribute.src("/static/js/upload.js"), attribute("defer", "")], ""),
    ]),
    html.body(body_attributes, [
      html.a([class("skip-link"), attribute.href("#main")], [html.text("Skip to content")]),
      header(shell),
      html.main([attribute.id("main"), attribute("tabindex", "-1")], content),
      html.div(
        [
          attribute.id("announcer"),
          class("visually-hidden"),
          attribute("aria-live", "polite"),
          attribute("role", "status"),
        ],
        [],
      ),
    ]),
  ])
  |> element.to_document_string
}

fn header(shell: Shell) -> Element(a) {
  let link = fn(id: String, href: String, label: String) {
    html.li([], [
      html.a(
        [
          attribute.href(href),
          case shell.active == id {
            True -> attribute("aria-current", "page")
            False -> attribute.none()
          },
        ],
        [html.text(label)],
      ),
    ])
  }
  html.header([class("site-header")], [
    html.a([class("brand"), attribute.href("/")], [
      html.img([
        attribute.src("/static/img/icon.png"),
        attribute.alt(""),
        class("brand-mark"),
        attribute("width", "32"),
        attribute("height", "32"),
      ]),
      html.span([], [html.text("Libarrie")]),
    ]),
    case shell.user, shell.csrf_token {
      Some(name), Some(token) ->
        html.nav([attribute("aria-label", "Main")], [
          html.ul([], [
            link("notebooks", "/notebooks", "Notebooks"),
            link("search", "/search", "Search"),
            link("trash", "/trash", "Trash"),
            link("exports", "/exports", "Exports"),
            link("usage", "/usage", "Usage"),
            link("settings", "/settings", "Settings"),
            case shell.admin {
              True -> link("admin", "/admin", "Admin")
              False -> element.none()
            },
          ]),
          html.form([attribute.method("post"), attribute.action("/auth/logout"), class("inline")], [
            csrf_field(token),
            html.a(
              [
                attribute.href("/account"),
                class("account-link"),
                attribute("hx-disable", ""),
                case shell.active == "account" {
                  True -> attribute("aria-current", "page")
                  False -> attribute.none()
                },
              ],
              [html.text(name)],
            ),
            html.button([attribute.type_("submit"), class("button secondary small")], [
              html.text("Sign out"),
            ]),
          ]),
        ])
      _, _ -> element.none()
    },
  ])
}

pub fn csrf_field(token: String) -> Element(a) {
  html.input([attribute.type_("hidden"), attribute.name("csrf_token"), attribute.value(token)])
}

/// Render a page: full document, or the fragment for htmx requests.
pub fn page(
  web: Web,
  req: wisp.Request,
  shell: Shell,
  content: List(Element(a)),
  status: Int,
) -> wisp.Response {
  let body = case is_htmx(req) {
    True -> content |> element.fragment |> element.to_string
    False -> document(shell, content)
  }
  wisp.html_response(body, status)
  |> wisp.set_header("vary", "HX-Request")
  |> wisp.set_header("cache-control", "private, no-store")
  |> security_headers(web)
}

/// Render only a fragment (htmx partial updates).
pub fn fragment(web: Web, content: List(Element(a)), status: Int) -> wisp.Response {
  wisp.html_response(content |> element.fragment |> element.to_string, status)
  |> wisp.set_header("cache-control", "private, no-store")
  |> security_headers(web)
}

/// A redirect that works for both ordinary navigation and htmx requests.
pub fn redirect(web: Web, req: wisp.Request, to: String) -> wisp.Response {
  case is_htmx(req) {
    True -> wisp.response(204) |> wisp.set_header("hx-redirect", to)
    False -> wisp.response(303) |> wisp.set_header("location", to)
  }
  |> security_headers(web)
}

/// Unauthenticated: htmx requests get 401 with `HX-Redirect` to the login
/// route (never a login page swapped into a fragment); ordinary navigation
/// gets a redirect. The return path is validated as same-origin.
pub fn require_login(web: Web, req: wisp.Request) -> wisp.Response {
  let return_to = case is_htmx(req) {
    True ->
      case request.get_header(req, "hx-current-url") {
        Ok(url) -> path_of(url, web.origin)
        Error(_) -> "/notebooks"
      }
    False -> req.path <> query_suffix(req)
  }
  let login = "/auth/login?return_to=" <> uri_encode(return_to)
  case is_htmx(req) {
    True -> wisp.response(401) |> wisp.set_header("hx-redirect", login)
    False -> wisp.response(303) |> wisp.set_header("location", login)
  }
  |> security_headers(web)
}

fn query_suffix(req: wisp.Request) -> String {
  case req.query {
    Some(q) if q != "" -> "?" <> q
    _ -> ""
  }
}

fn path_of(url: String, origin: String) -> String {
  case string.starts_with(url, origin) {
    True ->
      case string.drop_start(url, string.length(origin)) {
        "" -> "/"
        path -> path
      }
    False -> "/notebooks"
  }
}

pub fn uri_encode(value: String) -> String {
  value
  |> string.to_graphemes
  |> list.map(fn(c) {
    case string.contains("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~/", c) {
      True -> c
      False ->
        c
        |> bit_array.from_string
        |> percent_bytes
    }
  })
  |> string.concat
}

fn percent_bytes(bits: BitArray) -> String {
  case bits {
    <<b, rest:bits>> ->
      "%" <> string.pad_start(string.uppercase(int.to_base16(b)), 2, "0") <> percent_bytes(rest)
    _ -> ""
  }
}

/// A status message for errors rendered inline.
pub fn alert(kind: String, message: String) -> Element(a) {
  html.div([class("alert " <> kind), attribute("role", "alert")], [html.p([], [html.text(message)])])
}
