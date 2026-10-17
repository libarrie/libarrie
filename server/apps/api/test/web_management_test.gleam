//// Web management screens: notebook settings, renumbering, page moves,
//// rescans, deferred processing, exports, permanent deletion and account
//// deletion with the recent sign-in requirement.

import gleam/dynamic/decode
import gleam/http
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import libarrie/api/router
import support
import web_test
import wisp/simulate

type Res {
  Res(status: Int, location: String, body: String)
}

fn send(app: router.App, req) -> Res {
  let resp = router.handle(app, req)
  let location = list.key_find(resp.headers, "location") |> unwrap("")
  Res(resp.status, location, simulate.read_body(resp))
}

fn unwrap(r: Result(a, b), default: a) -> a {
  case r {
    Ok(v) -> v
    Error(_) -> default
  }
}

fn get(app: router.App, path: String, session: String) -> Res {
  simulate.request(http.Get, path) |> simulate.header("cookie", session) |> send(app, _)
}

fn post(app: router.App, path: String, session: String, csrf: String, fields: List(#(String, String))) -> Res {
  simulate.request(http.Post, path)
  |> simulate.header("cookie", session)
  |> simulate.header("origin", "http://localhost:8080")
  |> simulate.form_body([#("csrf_token", csrf), ..fields])
  |> send(app, _)
}

/// Pretend the browser signed in `seconds` ago.
fn age_sign_in(app: router.App, account_id: String, seconds: Int) -> Nil {
  support.sql(
    app,
    "update web_sessions set auth_time = now() - make_interval(secs => $2::text::int)
     where account_id = $1::uuid",
    [account_id, int.to_string(seconds)],
  )
}

/// The value of a hidden input on a rendered page.
fn hidden_value(body: String, name: String) -> String {
  let assert Ok(#(_, after)) = string.split_once(body, "name=\"" <> name <> "\"")
  let assert Ok(#(before_close, _)) = string.split_once(after, ">")
  let assert Ok(#(_, value)) = string.split_once(before_close, "value=\"")
  let assert Ok(#(value, _)) = string.split_once(value, "\"")
  value
}

fn setup(name: String) {
  let app = support.app()
  let subject = "web-manage-" <> support.random_id()
  let #(session, csrf) = web_test.sign_in(app, subject)
  let token = support.token_for(subject, 0)
  let notebook = support.notebook(app, token, name)
  #(app, session, csrf, token, notebook)
}

pub fn notebook_settings_and_colors_test() {
  let #(app, session, csrf, token, notebook) = setup("Field notes")
  let page = get(app, "/notebooks/" <> notebook, session)
  let assert 200 = page.status
  let assert True = string.contains(page.body, "Notebook settings")
  let version = hidden_value(page.body, "version")
  let saved =
    post(app, "/notebooks/" <> notebook <> "/edit", session, csrf, [
      #("version", version),
      #("name", "Field notes 2026"),
      #("description", "Green cover"),
      #("color", "#0d3f2e"),
    ])
  let assert 303 = saved.status
  let assert True = string.ends_with(saved.location, "?done=notebook_saved")
  let shown = get(app, saved.location, session)
  let assert True = string.contains(shown.body, "Notebook saved.")
  let assert True = string.contains(shown.body, "Field notes 2026")
  let assert True = string.contains(shown.body, "data-color=\"#0d3f2e\"")
  // A stale version is an explained conflict, not a silent overwrite.
  let stale =
    post(app, "/notebooks/" <> notebook <> "/edit", session, csrf, [
      #("version", version),
      #("name", "Overwritten"),
    ])
  let assert 412 = stale.status
  let assert True = string.contains(stale.body, "changed since you opened the page")
  // An empty color clears it.
  let current = hidden_value(get(app, "/notebooks/" <> notebook, session).body, "version")
  let cleared =
    post(app, "/notebooks/" <> notebook <> "/edit", session, csrf, [#("version", current), #("color", "")])
  let assert 303 = cleared.status
  let reply = support.call(app, http.Get, "/v1/notebooks/" <> notebook, token, None, [])
  let assert None = support.get(reply, ["color"], decode.optional(decode.string))
  // Moving the notebook to trash.
  let current = hidden_value(get(app, "/notebooks/" <> notebook, session).body, "version")
  let trashed = post(app, "/notebooks/" <> notebook <> "/trash", session, csrf, [#("version", current)])
  let assert 303 = trashed.status
  let assert "/notebooks?done=notebook_trashed" = trashed.location
  let trash = get(app, "/trash", session)
  let assert True = string.contains(trash.body, "Field notes 2026")
}

pub fn renumber_and_move_pages_test() {
  let #(app, session, csrf, token, notebook) = setup("Numbers")
  // The default limits allow one notebook; this test needs two.
  let account = support.account_id(app, token)
  let assert 200 =
    support.internal(app, http.Put, "/internal/v1/accounts/" <> account <> "/entitlements",
      support.entitlement(1, 100, 5, 100, "lifetime", [], [])).status
  let other = support.notebook(app, token, "Other")
  let #(_, first) = support.upload_page(app, token, notebook, 1, Some("one"), "immediate")
  let #(_, _) = support.upload_page(app, token, notebook, 2, Some("two"), "immediate")
  let #(_, _) = support.upload_page(app, token, notebook, 3, Some("three"), "immediate")
  support.drain(app)
  let form = get(app, "/notebooks/" <> notebook <> "/renumber", session)
  let assert 200 = form.status
  let assert True = string.contains(form.body, "1–3")
  let revision = hidden_value(form.body, "numbering_revision")
  // Shift pages 2-3 later by one, making room for a skipped page 2.
  let shifted =
    post(app, "/notebooks/" <> notebook <> "/renumber", session, csrf, [
      #("numbering_revision", revision),
      #("from", "2"),
      #("to", "3"),
      #("by", "1"),
    ])
  let assert 303 = shifted.status
  let again = get(app, "/notebooks/" <> notebook <> "/renumber", session)
  let assert True = string.contains(again.body, "1, 3–4")
  // The old numbering revision is stale now.
  let stale =
    post(app, "/notebooks/" <> notebook <> "/renumber", session, csrf, [
      #("numbering_revision", revision),
      #("from", "3"),
      #("to", "4"),
      #("by", "-1"),
    ])
  let assert 412 = stale.status
  // A collision explains itself and keeps the entered values.
  let current = hidden_value(again.body, "numbering_revision")
  let collide =
    post(app, "/notebooks/" <> notebook <> "/renumber", session, csrf, [
      #("numbering_revision", current),
      #("from", "3"),
      #("to", "4"),
      #("by", "-2"),
    ])
  let assert 409 = collide.status
  let assert True = string.contains(collide.body, "two pages the same number")
  let invalid =
    post(app, "/notebooks/" <> notebook <> "/renumber", session, csrf, [
      #("numbering_revision", current),
      #("from", "4"),
      #("to", "3"),
      #("by", "1"),
    ])
  let assert 422 = invalid.status
  // Move page 1 to the other notebook as page 7.
  let detail = get(app, "/pages/" <> first, session)
  let assert True = string.contains(detail.body, "Page number and notebook")
  let moved =
    post(app, "/pages/" <> first <> "/move", session, csrf, [
      #("version", hidden_value(detail.body, "version")),
      #("current_page_number", "1"),
      #("current_notebook_id", notebook),
      #("page_number", "7"),
      #("notebook_id", other),
    ])
  let assert 303 = moved.status
  let page = support.call(app, http.Get, "/v1/pages/" <> first, token, None, [])
  let assert 7 = support.get(page, ["page", "page_number"], decode.int)
  let assert True = support.str(page, ["page", "notebook", "id"]) == other
}

pub fn rescan_and_replacement_controls_test() {
  let #(app, session, csrf, token, notebook) = setup("Rescans")
  let #(_, page_id) = support.upload_page(app, token, notebook, 1, Some("faint text"), "immediate")
  support.drain(app)
  let detail = get(app, "/pages/" <> page_id, session)
  let assert True = string.contains(detail.body, "Rescan this photo")
  let assert True = string.contains(detail.body, "id=\"replacer\"")
  let assert True = string.contains(detail.body, "data-page-id=\"" <> page_id <> "\"")
  let fields = [
    #("operation_id", hidden_value(detail.body, "operation_id")),
    #("source_revision_id", hidden_value(detail.body, "source_revision_id")),
    #("content_version", hidden_value(detail.body, "content_version")),
  ]
  let rescanned = post(app, "/pages/" <> page_id <> "/rescan", session, csrf, fields)
  let assert 303 = rescanned.status
  let assert True = string.ends_with(rescanned.location, "?done=rescan_started")
  // A double submission is the same operation, not a second rescan.
  let repeated = post(app, "/pages/" <> page_id <> "/rescan", session, csrf, fields)
  let assert 303 = repeated.status
  let busy = get(app, "/pages/" <> page_id, session)
  let assert True = string.contains(busy.body, "Rescanning and replacing are available when it finishes")
  support.drain(app)
  let assert 2 =
    support.sql_int(
      app,
      "select count(*)::int from operations where page_id = $1::uuid",
      [page_id],
    )
}

pub fn process_deferred_pages_test() {
  let #(app, session, csrf, token, notebook) = setup("Later")
  let #(_, _) = support.upload_page(app, token, notebook, 1, Some("later one"), "deferred")
  let #(_, _) = support.upload_page(app, token, notebook, 2, Some("later two"), "deferred")
  let usage = get(app, "/usage", session)
  let assert True = string.contains(usage.body, "Waiting for processing")
  let assert True = string.contains(usage.body, "2 pages uploaded to be processed later")
  let started = post(app, "/pages/process-deferred", session, csrf, [])
  let assert 303 = started.status
  let assert "/usage?done=processing&started=2&limited=0" = started.location
  let after = get(app, started.location, session)
  let assert True = string.contains(after.body, "2 pages started processing.")
  let assert False = string.contains(after.body, "Process now")
  support.drain(app)
}

pub fn exports_screen_test() {
  let #(app, session, csrf, token, notebook) = setup("Exported")
  let #(_, _) = support.upload_page(app, token, notebook, 1, Some("keep me"), "immediate")
  support.drain(app)
  let empty = get(app, "/exports", session)
  let assert 200 = empty.status
  let assert True = string.contains(empty.body, "No exports yet.")
  let created = post(app, "/exports", session, csrf, [#("notebook_id", notebook)])
  let assert 303 = created.status
  let preparing = get(app, "/exports", session)
  let assert True = string.contains(preparing.body, "Preparing")
  // Polls only while something is preparing.
  let assert True = string.contains(preparing.body, "hx-trigger=\"every 5s\"")
  support.drain(app)
  let ready = get(app, "/exports", session)
  let assert True = string.contains(ready.body, "Ready")
  let assert False = string.contains(ready.body, "hx-trigger=\"every 5s\"")
  let assert Ok(#(_, after)) = string.split_once(ready.body, "href=\"/exports/")
  let assert Ok(#(path, _)) = string.split_once(after, "\"")
  let download = get(app, "/exports/" <> path, session)
  let assert 303 = download.status
  let assert True = string.contains(download.location, "X-Amz-Signature=")
  let assert True = string.contains(download.location, "response-content-disposition=")
}

pub fn permanent_deletion_requires_recent_sign_in_test() {
  let #(app, session, csrf, token, notebook) = setup("Purge")
  let account = support.account_id(app, token)
  let #(_, page_id) = support.upload_page(app, token, notebook, 1, Some("secret"), "immediate")
  support.drain(app)
  let detail = get(app, "/pages/" <> page_id, session)
  let trashed =
    post(app, "/pages/" <> page_id <> "/trash", session, csrf, [#("version", hidden_value(detail.body, "version"))])
  let assert 303 = trashed.status
  let trash = get(app, "/trash", session)
  let assert True = string.contains(trash.body, "/trash/purge?page=" <> page_id)
  let assert True = string.contains(trash.body, "Empty trash")
  // An old sign-in must be refreshed first, both on the form and on submit.
  age_sign_in(app, account, 3600)
  let confirm = get(app, "/trash/purge?page=" <> page_id, session)
  let assert 200 = confirm.status
  let assert True = string.contains(confirm.body, "Confirm it&#39;s you")
  let assert True =
    string.contains(confirm.body, "/auth/login?reauth=1&amp;return_to=/trash/purge%3Fpage%3D" <> page_id)
  let refused = post(app, "/trash/purge", session, csrf, [#("page", page_id), #("confirm", "yes")])
  let assert 403 = refused.status
  // After signing in again it goes through, with explicit confirmation.
  age_sign_in(app, account, 0)
  let confirm = get(app, "/trash/purge?page=" <> page_id, session)
  let assert True = string.contains(confirm.body, "I understand this cannot be undone")
  let unconfirmed = post(app, "/trash/purge", session, csrf, [#("page", page_id)])
  let assert 422 = unconfirmed.status
  // Until the trash event is durably journaled, purge waits and says why.
  let early = post(app, "/trash/purge", session, csrf, [#("page", page_id), #("confirm", "yes")])
  let assert 409 = early.status
  let assert True = string.contains(early.body, "still being recorded safely")
  support.maintain(app, "journal")
  let purged = post(app, "/trash/purge", session, csrf, [#("page", page_id), #("confirm", "yes")])
  let assert 303 = purged.status
  let assert "/trash?done=purged" = purged.location
  let assert False = string.contains(get(app, "/trash", session).body, "/trash/purge?page=" <> page_id)
  // Unknown selections go back to the trash.
  let assert 303 = get(app, "/trash/purge?page=not-a-uuid", session).status
}

pub fn account_deletion_and_cancellation_test() {
  let #(app, session, csrf, token, _) = setup("Leaving")
  let account = support.account_id(app, token)
  let page = get(app, "/account", session)
  let assert 200 = page.status
  let assert True = string.contains(page.body, "Delete account")
  let assert True = string.contains(page.body, "Export your notes")
  age_sign_in(app, account, 3600)
  let stale = get(app, "/account/delete", session)
  let assert True = string.contains(stale.body, "Confirm it&#39;s you")
  let assert 403 = post(app, "/account/delete", session, csrf, [#("confirm", "yes")]).status
  age_sign_in(app, account, 0)
  let assert 422 = post(app, "/account/delete", session, csrf, []).status
  let scheduled = post(app, "/account/delete", session, csrf, [#("confirm", "yes")])
  let assert 303 = scheduled.status
  let assert "/account?done=deletion_scheduled" = scheduled.location
  let status = get(app, scheduled.location, session)
  let assert True = string.contains(status.body, "Account deletion scheduled")
  let assert True = string.contains(status.body, "Keep my account")
  // Reads continue during the grace period; changes are refused.
  let assert 200 = get(app, "/notebooks", session).status
  let refused = post(app, "/notebooks", session, csrf, [#("name", "New")])
  let assert True = refused.status >= 400
  let cancelled =
    post(app, "/account/delete/cancel", session, csrf, [
      #("lifecycle_revision", hidden_value(status.body, "lifecycle_revision")),
    ])
  let assert 303 = cancelled.status
  let active = get(app, cancelled.location, session)
  let assert True = string.contains(active.body, "Account deletion cancelled")
  let assert True = string.contains(active.body, "Delete account")
}

pub fn navigation_links_new_screens_test() {
  let #(app, session, _, _, _) = setup("Nav")
  let page = get(app, "/notebooks", session)
  let assert True = string.contains(page.body, "href=\"/exports\"")
  let assert True = string.contains(page.body, "href=\"/account\"")
  let assert False = string.contains(page.body, " style=")
}
