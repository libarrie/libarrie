//// Web UI extensions: a deployment's own build can add Usage page
//// sections, signed-in routes, notices and form-action origins. The
//// default build has none, and adds nothing to the page.

import gleam/http
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import libarrie/api/router
import libarrie/web/config
import lustre/element/html
import support
import web_test
import wisp
import wisp/simulate

fn example() -> config.Extension {
  config.Extension(
    form_action_origins: ["https://forms.example"],
    usage_sections: fn(viewer) {
      [html.section([], [html.text("Example section for " <> viewer.account_id)])]
    },
    route: fn(viewer, req, segments) {
      case segments, req.method {
        ["example"], http.Get -> Some(viewer.page("Example", [html.p([], [html.text("Example page")])], 200))
        ["example"], http.Post ->
          Some({
            use fields <- viewer.form
            case list.key_find(fields, "go") {
              Ok("away") -> wisp.response(303) |> wisp.set_header("location", "https://forms.example/next")
              _ -> viewer.redirect("/usage?done=example_done")
            }
          })
        _, _ -> None
      }
    },
    notice: fn(code) {
      case code {
        "example_done" -> Some(#("ok", "Example finished."))
        _ -> None
      }
    },
  )
}

fn with_example(app: router.App) -> router.App {
  router.App(..app, web: config.Web(..app.web, extensions: [example()]))
}

fn get(app: router.App, path: String, session: String) {
  router.handle(app, simulate.request(http.Get, path) |> simulate.header("cookie", session))
}

fn post(app: router.App, path: String, session: String, csrf: String, fields) {
  router.handle(app,
    simulate.request(http.Post, path)
    |> simulate.header("cookie", session)
    |> simulate.header("origin", "http://localhost:8080")
    |> simulate.form_body(fields |> list.append([#("csrf_token", csrf)])))
}

pub fn default_build_has_no_extensions_test() {
  let app = support.app()
  let #(session, _) = web_test.sign_in(app, "ext-none-" <> support.random_id())
  let resp = get(app, "/usage", session)
  let assert 200 = resp.status
  let assert False = string.contains(simulate.read_body(resp), "Example section")
  let assert Ok(csp) = list.key_find(resp.headers, "content-security-policy")
  let assert True = string.contains(csp, "form-action 'self';")
  let assert 404 = get(app, "/example", session).status
}

pub fn extension_adds_sections_routes_and_notices_test() {
  let app = with_example(support.app())
  let subject = "ext-on-" <> support.random_id()
  let #(session, csrf) = web_test.sign_in(app, subject)
  let account = support.account_id(app, support.token_for(subject, 0))
  let usage = get(app, "/usage", session)
  let assert True = string.contains(simulate.read_body(usage), "Example section for " <> account)
  let assert Ok(csp) = list.key_find(usage.headers, "content-security-policy")
  let assert True = string.contains(csp, "form-action 'self' https://forms.example;")
  let page = get(app, "/example", session)
  let assert 200 = page.status
  let assert True = string.contains(simulate.read_body(page), "Example page")
  // Extension forms get core's CSRF check.
  let assert 403 = post(app, "/example", session, "wrong", []).status
  let done = post(app, "/example", session, csrf, [])
  let assert 303 = done.status
  let assert Ok("/usage?done=example_done") = list.key_find(done.headers, "location")
  let notice = simulate.read_body(get(app, "/usage?done=example_done", session))
  let assert True = string.contains(notice, "Example finished.")
}
