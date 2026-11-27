//// Renders the web UI's screens, in light and dark themes, as HTML files
//// for the automated accessibility audit (clients/web/scripts/a11y.sh).
//// Runs only when LIBARRIE_A11Y_SNAPSHOTS names an output directory.

import envoy
import gleam/dynamic/decode
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import libarrie/api/router
import libarrie/domain/admin
import libarrie/domain/moderation
import simplifile
import support
import web_test
import wisp/simulate

fn render(app: router.App, method: http.Method, path: String, cookie: String, csrf: String, form: List(#(String, String))) -> String {
  let req =
    simulate.request(method, path)
    |> simulate.header("cookie", cookie)
    |> simulate.header("origin", "http://localhost:8080")
  let req = case method {
    http.Post -> simulate.form_body(req, [#("csrf_token", csrf), ..form])
    _ -> req
  }
  let resp = router.handle(app, req)
  simulate.read_body(resp)
}

/// The notebook screen with its settings open, so the audit covers the
/// notebook form's fieldsets.
fn open_settings(html: String) -> String {
  let opened =
    string.replace(html, "id=\"notebook-settings\"", "id=\"notebook-settings\" open")
  // A markup change must not silently skip the audit.
  let assert True = opened != html
  opened
}

/// The search screen, checked to show the private hit's note next to the
/// other hit's snippet, so the audit covers both.
fn shows_both_hits(html: String) -> String {
  // A setup or markup change must not silently drop either from the audit.
  let assert True = string.contains(html, "Private notebook. The matching text")
  let assert True = string.contains(html, "class=\"snippet\"")
  html
}

pub fn accessibility_snapshots_test() {
  case envoy.get("LIBARRIE_A11Y_SNAPSHOTS") {
    Error(_) -> Nil
    Ok(directory) -> {
      let app = support.app()
      let subject = "a11y-" <> support.random_id()
      let #(session, csrf) = web_test.sign_in(app, subject)
      let token = support.token_for(subject, 0)
      let notebook =
        support.str(
          support.call(app, http.Post, "/v1/notebooks", token,
            Some(json.object([
              #("name", json.string("Field notes")),
              #("description", json.string("Green cover, 2026")),
              #("color", json.string("#0d3f2e")),
            ])), []),
          ["id"],
        )
      let #(_, page) = support.upload_page(app, token, notebook, 1, Some("Met Grace Hopper about the compiler budget"), "immediate")
      let #(_, _) = support.upload_page(app, token, notebook, 2, Some("Process me later"), "deferred")
      let #(_, trashed) = support.upload_page(app, token, notebook, 3, Some("Old draft"), "immediate")
      // A private notebook, so the search screen shows a hit without its
      // text next to one with it.
      support.raise_limits(app, token)
      let diary = support.notebook(app, token, "Diary")
      support.set_private(app, token, diary, True)
      let #(_, _) = support.upload_page(app, token, diary, 1, Some("Grace Hopper birthday surprise"), "immediate")
      support.drain(app)
      let version =
        support.get(support.call(app, http.Get, "/v1/pages/" <> trashed, token, None, []), ["page", "version"], decode.int)
      let assert 202 =
        support.call(app, http.Delete, "/v1/pages/" <> trashed, token, None, [#("if-match", "\"v" <> int.to_string(version) <> "\"")]).status
      let _ = support.call(app, http.Post, "/v1/exports", token, Some(json.object([])), [])
      support.drain(app)
      // The snapshot user is an owner, so the admin screens render; a
      // recovery code keeps the setup screen available.
      let user_id =
        support.sql_str(
          app,
          "select user_id::text from identities where subject = $1",
          [subject],
        )
      support.sql(app, "update users set role = 'owner' where id = $1::uuid", [
        user_id,
      ])
      let assert Ok(_) = admin.issue_code(app.ctx, "recovery")
      // A blocked person, so the admin table shows moderation states.
      let other = "a11y-other-" <> support.random_id()
      let assert 200 =
        support.call(
          app,
          http.Get,
          "/v1/me",
          support.token_for(other, 0),
          None,
          [],
        ).status
      let other_id =
        support.sql_str(
          app,
          "select user_id::text from identities where subject = $1",
          [other],
        )
      let assert Ok(_) = moderation.block(app.ctx, user_id, other_id, "")
      let screens = [
        #("landing", http.Get, "/", False, []),
        #("dev-sign-in", http.Get, "/dev-issuer/authorize?client_id=libarrie&redirect_uri=x&state=s&nonce=n&code_challenge=c", False, []),
        #("notebooks", http.Get, "/notebooks", True, []),
        #("notebook", http.Get, "/notebooks/" <> notebook, True, []),
        #("notebook-settings", http.Get, "/notebooks/" <> notebook, True, []),
        #("renumber", http.Get, "/notebooks/" <> notebook <> "/renumber", True, []),
        #("upload", http.Get, "/notebooks/" <> notebook <> "/upload", True, []),
        #("page", http.Get, "/pages/" <> page, True, []),
        #("search", http.Post, "/search", True, [#("query", "Hopper")]),
        #("trash", http.Get, "/trash", True, []),
        #("purge", http.Get, "/trash/purge?page=" <> trashed, True, []),
        #("exports", http.Get, "/exports", True, []),
        #("usage", http.Get, "/usage", True, []),
        #("settings", http.Get, "/settings", True, []),
        #("api-keys", http.Get, "/settings/api-keys", True, []),
        #("account", http.Get, "/account", True, []),
        #("delete-account", http.Get, "/account/delete", True, []),
        #("not-found", http.Get, "/no-such-page", True, []),
        #("setup", http.Get, "/setup", True, []),
        #("admin", http.Get, "/admin", True, []),
        #(
          "admin-role",
          http.Get,
          "/admin/users/" <> user_id <> "/role?to=admin",
          True,
          [],
        ),
        #(
          "admin-block",
          http.Get,
          "/admin/users/" <> other_id <> "/block",
          True,
          [],
        ),
        #(
          "admin-delete",
          http.Get,
          "/admin/users/" <> other_id <> "/delete",
          True,
          [],
        ),
      ]
      let assert Ok(_) = simplifile.create_directory_all(directory)
      list.each(["light", "dark"], fn(theme) {
        list.each(screens, fn(screen) {
          let #(name, method, path, signed_in, form) = screen
          let cookie =
            "libarrie_theme=" <> theme <> case signed_in {
              True -> "; " <> session
              False -> ""
            }
          let html = case name {
            "notebook-settings" -> open_settings(render(app, method, path, cookie, csrf, form))
            "search" -> shows_both_hits(render(app, method, path, cookie, csrf, form))
            _ -> render(app, method, path, cookie, csrf, form)
          }
          let assert True = string.starts_with(html, "<!doctype html>")
          let assert Ok(_) = simplifile.write(directory <> "/" <> name <> "-" <> theme <> ".html", html)
          Nil
        })
      })
    }
  }
}
