//// HTML routes for the htmx web UI (section 13). Handlers call the same
//// domain operations as the `/v1` JSON API, preserving authorization,
//// quotas, idempotency and concurrency rules without HTTP calls back into
//// this process. HTML routes are separate from the stable `/v1` contract.

import gleam/dynamic/decode
import gleam/http.{Get, Post}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import libarrie/database
import libarrie/domain/accounts
import libarrie/domain/admin
import libarrie/domain/api_keys
import libarrie/domain/closure
import libarrie/domain/context
import libarrie/domain/deferred
import libarrie/domain/error.{type AppError}
import libarrie/domain/exports
import libarrie/domain/moderation
import libarrie/domain/notebooks
import libarrie/domain/pages
import libarrie/domain/purge
import libarrie/domain/quota
import libarrie/domain/ratelimit
import libarrie/domain/search
import libarrie/domain/settings
import libarrie/domain/transcripts
import libarrie/domain/uploads
import libarrie/integrations/storage
import libarrie/web/config.{type Web}
import libarrie/web/cookies
import libarrie/web/dev_issuer
import libarrie/web/oidc
import libarrie/web/session.{type Session}
import libarrie/web/ui
import libarrie/web/views
import lustre/attribute
import lustre/element.{type Element}
import wisp
import youid/uuid as youid

pub fn handle(web: Web, req: wisp.Request) -> wisp.Response {
  case wisp.path_segments(req), req.method {
    ["static", ..], Get -> static(web, req)
    [], Get -> home(web, req)
    ["auth", "login"], Get -> oidc.login(web, req)
    ["auth", "callback"], Get -> oidc.callback(web, req, exchange(web))
    ["auth", "logout"], Post -> logout(web, req)
    ["dev-issuer", "authorize"], Get -> dev_only(web, req, fn(_) { dev_issuer.authorize_form(web, req) })
    ["dev-issuer", "authorize"], Post ->
      dev_only(web, req, fn(secret) { dev_issuer.authorize_submit(web, secret, req) })
    ["dev-issuer", "token"], Post ->
      dev_only(web, req, fn(secret) { dev_issuer.token_endpoint(web, secret, req) })
    ["account-closed"], Get ->
      ui.page(web, req, shell(req, "Account closed", None, ""), views.closed_account(None), 200)
    _, _ -> authenticated(web, req)
  }
}

fn exchange(web: Web) -> oidc.Exchange {
  case web.dev_issuer_secret {
    Some(secret) -> dev_issuer.exchange(web, secret)
    None -> oidc.http_exchange(web)
  }
}

fn dev_only(web: Web, req: wisp.Request, next: fn(String) -> wisp.Response) -> wisp.Response {
  case web.dev_issuer_secret, web.hosted {
    Some(secret), False -> next(secret)
    _, _ -> not_found(web, req)
  }
}

fn static(web: Web, req: wisp.Request) -> wisp.Response {
  use <- wisp.serve_static(req, under: "/static", from: web.static_dir)
  not_found(web, req)
}

fn shell(req: wisp.Request, title: String, session: Option(Session), active: String) -> ui.Shell {
  case session {
    Some(s) ->
      ui.Shell(
        title,
        ui.theme(req),
        Some(display_name(s)),
        Some(s.csrf_token),
        active,
        admin.can(s.role, admin.ViewAdmin),
      )
    None -> ui.Shell(title, ui.theme(req), None, None, active, False)
  }
}

fn display_name(s: Session) -> String {
  case s.principal.display_name {
    "" -> "Signed in"
    name -> name
  }
}

fn not_found(web: Web, req: wisp.Request) -> wisp.Response {
  ui.page(web, req, shell(req, "Not found", None, ""), [
    views.heading("Not found", []),
    ui.alert("info", "That page does not exist or you do not have access to it."),
  ], 404)
}

fn home(web: Web, req: wisp.Request) -> wisp.Response {
  case current_session(web, req) {
    Some(_) -> ui.redirect(web, req, "/notebooks")
    None -> ui.page(web, req, shell(req, "Find what you wrote", None, ""), views.landing(), 200)
  }
}

fn current_session(web: Web, req: wisp.Request) -> Option(Session) {
  case session.token_from(req, web.origin) {
    None -> None
    Some(token) -> session.lookup(web.ctx, token) |> result.unwrap(None)
  }
}

fn logout(web: Web, req: wisp.Request) -> wisp.Response {
  use form <- wisp.require_form(req)
  case current_session(web, req) {
    None -> ui.redirect(web, req, "/")
    Some(s) ->
      case session.check_csrf(req, s, web.origin, form_field(form, "csrf_token")) {
        Error(_) -> forbidden(web, req)
        Ok(_) -> {
          let _ = session.revoke(web.ctx, s.token)
          ui.redirect(web, req, "/") |> session.clear_cookie(web.origin)
        }
      }
  }
}

fn form_field(form: wisp.FormData, name: String) -> Option(String) {
  list.key_find(form.values, name) |> option.from_result
}

fn forbidden(web: Web, req: wisp.Request) -> wisp.Response {
  ui.page(web, req, shell(req, "Forbidden", None, ""), [
    ui.alert("danger", "This request could not be verified. Reload the page and try again."),
  ], 403)
}

// Authenticated routes ------------------------------------------------------------------

fn authenticated(web: Web, req: wisp.Request) -> wisp.Response {
  case current_session(web, req) {
    None -> ui.require_login(web, req)
    Some(s) ->
      case s.status_only || !accounts.can_read(s.principal) {
        True ->
          case
            wisp.path_segments(req),
            accounts.is_suspended(s.principal) && !s.status_only
          {
            ["account"], _ -> account_status(web, req, s)
            // A blocked account can still take its notes with it.
            ["exports"], True | ["exports", _, "parts", _], True ->
              route(web, req, s)
            _, _ -> ui.redirect(web, req, "/account")
          }
        False ->
          case
            ratelimit.hit(
              web.ctx.db,
              "requests:" <> s.principal.account_id,
              "requests",
              web.ctx.config.rate_limits.requests_per_minute,
              60,
            )
          {
            Error(e) -> app_error(web, req, s, e)
            Ok(_) -> route(web, req, s)
          }
      }
  }
}

fn route(web: Web, req: wisp.Request, s: Session) -> wisp.Response {
  let account = s.principal.account_id
  case wisp.path_segments(req), req.method {
    ["notebooks"], Get -> notebooks_index(web, req, s, None, 200)
    ["notebooks"], Post -> {
      use form <- with_form(web, req, s)
      let input =
        notebooks.NotebookInput(
          name: form_field(form, "name"),
          description: form_field(form, "description"),
          color: form_field(form, "color"),
        )
      case
        context.transaction(web.ctx, fn(tx) {
          notebooks.create(tx, web.ctx.config, account, input)
        })
      {
        Ok(_) -> notebooks_index(web, req, s, None, 200)
        Error(e) -> notebooks_index(web, req, s, Some(e.message), e.status)
      }
    }
    ["notebooks", id], Get -> {
      use id <- uuid(web, req, s, id)
      notebook_show(web, req, s, id, flash(web, req), 200)
    }
    ["notebooks", id, "pages"], Get -> {
      use id <- uuid(web, req, s, id)
      let cursor = query_int(req, "cursor", 0)
      case pages.list_for_notebook(web.ctx.db, account, id, cursor, 48) {
        Ok(items) -> ui.fragment(web, views.page_tiles(id, items, next_cursor(items, 48)), 200)
        Error(e) -> app_error(web, req, s, e)
      }
    }
    ["notebooks", id, "upload"], Get -> {
      use id <- uuid(web, req, s, id)
      case
        notebooks.get(web.ctx.db, account, id),
        pages.next_page_number(web.ctx.db, account, id)
      {
        Ok(nb), Ok(start) ->
          ui.page(web, req, shell(req, "Add pages", Some(s), "notebooks"), views.upload_page(nb, start, integrity(web), account), 200)
        Error(e), _ | _, Error(e) -> app_error(web, req, s, e)
      }
    }
    ["notebooks", id, "edit"], Post -> {
      use id <- uuid(web, req, s, id)
      use form <- with_form(web, req, s)
      let input =
        notebooks.NotebookInput(
          name: form_field(form, "name"),
          description: form_field(form, "description"),
          color: form_field(form, "color"),
        )
      case notebooks.update(web.ctx, account, id, form_int(form, "version"), input) {
        Ok(_) -> ui.redirect(web, req, "/notebooks/" <> id <> "?done=notebook_saved")
        Error(e) -> notebook_show(web, req, s, id, Some(#("danger", conflict_message(e))), e.status)
      }
    }
    ["notebooks", id, "trash"], Post -> {
      use id <- uuid(web, req, s, id)
      use form <- with_form(web, req, s)
      case notebooks.trash(web.ctx, account, id, form_int(form, "version")) {
        Ok(_) -> ui.redirect(web, req, "/notebooks?done=notebook_trashed")
        Error(e) -> notebook_show(web, req, s, id, Some(#("danger", conflict_message(e))), e.status)
      }
    }
    ["notebooks", id, "renumber"], Get -> {
      use id <- uuid(web, req, s, id)
      renumber_page(web, req, s, id, None, views.ShiftForm("", "", "1"), 200)
    }
    ["notebooks", id, "renumber"], Post -> {
      use id <- uuid(web, req, s, id)
      use form <- with_form(web, req, s)
      let values =
        views.ShiftForm(
          from: form_field(form, "from") |> option.unwrap(""),
          to: form_field(form, "to") |> option.unwrap(""),
          by: form_field(form, "by") |> option.unwrap(""),
        )
      case form_int(form, "from"), form_int(form, "to"), form_int(form, "by") {
        Some(from), Some(to), Some(by) if from >= 1 && to >= from && by != 0 ->
          case
            pages.renumber(
              web.ctx,
              account,
              id,
              pages.Shift(from:, to:, by:),
              form_int(form, "numbering_revision"),
            )
          {
            Ok(_) -> ui.redirect(web, req, "/notebooks/" <> id <> "?done=renumbered")
            Error(e) -> renumber_page(web, req, s, id, Some(renumber_message(e)), values, e.status)
          }
        _, _, _ ->
          renumber_page(
            web,
            req,
            s,
            id,
            Some("Enter a first page of at least 1, a last page no lower than the first, and a move other than 0."),
            values,
            422,
          )
      }
    }
    ["notebooks", id, "restore"], Post -> {
      use id <- uuid(web, req, s, id)
      use _form <- with_form(web, req, s)
      case notebooks.restore(web.ctx, account, id, notebooks.RestoreRequest(None, [])) {
        Ok(_) -> ui.fragment(web, [ui.alert("ok", "Restoring. It will appear in your notebooks shortly.")], 200)
        Error(e) -> ui.fragment(web, [ui.alert("danger", e.message)], e.status)
      }
    }
    ["pages", id], Get -> {
      use id <- uuid(web, req, s, id)
      page_show(web, req, s, id, flash(web, req), 200)
    }
    ["pages", id, "status"], Get -> {
      use id <- uuid(web, req, s, id)
      case load_detail(web, account, id) {
        Error(e) -> app_error(web, req, s, e)
        Ok(#(page, detail)) -> {
          let status = pages.processing_status(page)
          let response =
            ui.fragment(web, [views.processing_status(page, detail, True)], 200)
          // When processing finishes, reload so the transcript and preview
          // appear.
          case views.is_processing(status), query_int(req, "watching", 0) {
            False, 1 -> wisp.set_header(response, "hx-refresh", "true")
            _, _ -> response
          }
        }
      }
    }
    ["pages", id, "original"], Get -> {
      use id <- uuid(web, req, s, id)
      original(web, req, s, id)
    }
    ["pages", id, "transcript"], Post -> {
      use id <- uuid(web, req, s, id)
      use form <- with_form(web, req, s)
      save_transcript(web, req, s, id, form)
    }
    ["pages", id, "trash"], Post -> {
      use id <- uuid(web, req, s, id)
      use form <- with_form(web, req, s)
      let version = form_field(form, "version") |> option.then(fn(v) { int.parse(v) |> option.from_result })
      case pages.trash(web.ctx, account, id, version) {
        Ok(#(page, _)) -> ui.redirect(web, req, "/notebooks/" <> page.notebook_id)
        Error(e) -> app_error(web, req, s, e)
      }
    }
    ["pages", id, "move"], Post -> {
      use id <- uuid(web, req, s, id)
      use form <- with_form(web, req, s)
      let changed = fn(field, current) {
        case form_field(form, field), form_field(form, current) {
          Some(value), Some(was) if value != was -> Some(value)
          _, _ -> None
        }
      }
      let change =
        pages.PageChange(
          page_number: changed("page_number", "current_page_number")
            |> option.then(fn(v) { int.parse(v) |> option.from_result }),
          notebook_id: changed("notebook_id", "current_notebook_id"),
        )
      case change {
        pages.PageChange(None, None) -> ui.redirect(web, req, "/pages/" <> id)
        _ ->
          case pages.update(web.ctx, account, id, form_int(form, "version"), change) {
            Ok(_) -> ui.redirect(web, req, "/pages/" <> id <> "?done=page_moved")
            Error(e) -> page_show(web, req, s, id, Some(#("danger", renumber_message(e))), e.status)
          }
      }
    }
    ["pages", id, "rescan"], Post -> {
      use id <- uuid(web, req, s, id)
      use form <- with_form(web, req, s)
      let request =
        uploads.ReprocessRequest(
          operation_id: form_field(form, "operation_id") |> option.unwrap("") |> string.lowercase,
          source_revision_id: form_field(form, "source_revision_id") |> option.unwrap("") |> string.lowercase,
        )
      case uploads.reprocess(web.ctx, account, id, form_int(form, "content_version"), request) {
        Ok(_) -> ui.redirect(web, req, "/pages/" <> id <> "?done=rescan_started")
        Error(e) -> page_show(web, req, s, id, Some(#("danger", conflict_message(e))), e.status)
      }
    }
    ["pages", "process-deferred"], Post -> {
      use _form <- with_form(web, req, s)
      process_deferred(web, req, s)
    }
    ["pages", id, "restore"], Post -> {
      use id <- uuid(web, req, s, id)
      use _form <- with_form(web, req, s)
      case pages.restore(web.ctx, account, id, pages.RestoreTarget(None, None)) {
        Ok(_) -> ui.fragment(web, [ui.alert("ok", "Restoring. It will reappear shortly.")], 200)
        Error(e) -> ui.fragment(web, [ui.alert("danger", e.message)], e.status)
      }
    }
    ["search"], Get -> {
      let nbs = notebooks.list(web.ctx.db, account, None, 100) |> result.unwrap([])
      ui.page(web, req, shell(req, "Search", Some(s), "search"), views.search_page(nbs, s.csrf_token), 200)
    }
    ["search"], Post -> {
      use form <- with_form(web, req, s)
      run_search(web, req, s, form)
    }
    ["trash"], Get -> {
      let #(trashed, trashed_notebooks) = load_trash(web, account)
      ui.page(
        web,
        req,
        shell(req, "Trash", Some(s), "trash"),
        views.trash_page(trashed, trashed_notebooks, s.csrf_token, flash(web, req)),
        200,
      )
    }
    ["trash", "purge"], Get -> purge_confirm(web, req, s, purge_selection(wisp.get_query(req)), None, 200)
    ["trash", "purge"], Post -> {
      use form <- with_form(web, req, s)
      let selection = purge_selection(form.values)
      case is_recent(s), form_field(form, "confirm") {
        False, _ -> purge_confirm(web, req, s, selection, None, 403)
        True, Some("yes") -> {
          let request = case selection {
            PurgePage(id) -> purge.Request([id], [], False)
            PurgeNotebook(id) -> purge.Request([], [id], False)
            PurgeAll | PurgeNothing -> purge.Request([], [], True)
          }
          case selection {
            PurgeNothing -> ui.redirect(web, req, "/trash")
            _ ->
              case purge.purge_trash(web.ctx, account, request) {
                Ok(_) -> ui.redirect(web, req, "/trash?done=purged")
                Error(e) -> purge_confirm(web, req, s, selection, Some(conflict_message(e)), e.status)
              }
          }
        }
        True, _ ->
          purge_confirm(web, req, s, selection, Some("Confirm that you understand this cannot be undone."), 422)
      }
    }
    ["exports"], Get -> exports_page(web, req, s, flash(web, req), 200)
    ["exports"], Post -> {
      use form <- with_form(web, req, s)
      let selected =
        form.values
        |> list.filter(fn(pair) { pair.0 == "notebook_id" })
        |> list.map(fn(pair) { string.lowercase(pair.1) })
      let request =
        exports.Request(
          notebook_ids: case selected {
            [] -> None
            ids -> Some(ids)
          },
          include_trash: form_field(form, "include_trash") == Some("true"),
        )
      case exports.create(web.ctx, account, request) {
        Ok(_) -> ui.redirect(web, req, "/exports?done=export_started")
        Error(e) -> exports_page(web, req, s, Some(#("danger", e.message)), e.status)
      }
    }
    ["exports", id, "parts", n], Get -> {
      use id <- uuid(web, req, s, id)
      case int.parse(n) {
        Error(_) -> not_found(web, req)
        Ok(n) ->
          case exports.download_url(web.ctx, account, id, n) {
            Error(e) -> app_error(web, req, s, e)
            Ok(body) ->
              case json.parse(json.to_string(body), decode.at(["url"], decode.string)) {
                Ok(url) ->
                  wisp.response(303) |> wisp.set_header("location", url) |> ui.security_headers(web)
                Error(_) -> app_error(web, req, s, error.internal("export download response"))
              }
          }
      }
    }
    ["usage"], Get -> usage(web, req, s)
    ["settings"], Get -> {
      let automatic = deferred.get(web.ctx, account) |> result.map(fn(d) { d.auto_process_deferred }) |> result.unwrap(False)
      ui.page(web, req, shell(req, "Settings", Some(s), "settings"), views.settings_page(ui.theme(req), automatic, s.csrf_token, flash(web, req)), 200)
    }
    ["settings", "api-keys"], Get -> api_keys_page(web, req, s, None, None, 200)
    ["settings", "api-keys"], Post -> {
      use form <- with_form(web, req, s)
      case is_recent(s) {
        False -> api_keys_page(web, req, s, None, None, 403)
        True ->
          case api_keys.create(web.ctx, s.principal, form_field(form, "name") |> option.unwrap("")) {
            // Shown on this response only; a redirect would lose it.
            Ok(created) -> api_keys_page(web, req, s, Some(created), None, 200)
            Error(e) -> api_keys_page(web, req, s, None, Some(e.message), e.status)
          }
      }
    }
    ["settings", "api-keys", id, "revoke"], Post -> {
      use _ <- with_form(web, req, s)
      case api_keys.revoke(web.ctx, s.principal.user_id, id) {
        Ok(_) -> ui.redirect(web, req, "/settings/api-keys?done=api_key_revoked")
        Error(e) -> api_keys_page(web, req, s, None, Some(e.message), e.status)
      }
    }
    ["settings", "processing"], Post -> {
      use form <- with_form(web, req, s)
      let enabled = form_field(form, "auto_process_deferred") == Some("true")
      case deferred.update(web.ctx, account, Some(enabled)) {
        Ok(_) -> ui.redirect(web, req, "/settings?done=settings_saved")
        Error(e) -> app_error(web, req, s, e)
      }
    }
    ["settings", "theme"], Post -> {
      use form <- with_form(web, req, s)
      let theme = case form_field(form, "theme") {
        Some("light") -> "light"
        Some("dark") -> "dark"
        _ -> "system"
      }
      ui.redirect(web, req, "/settings")
      |> wisp.set_header(
        "set-cookie",
        ui.theme_cookie <> "=" <> theme <> cookies.scope(web.origin) <> "; SameSite=Lax; Max-Age=31536000",
      )
    }
    ["setup"], Get -> setup(web, req, s, None, 200)
    ["setup"], Post -> {
      use form <- with_form(web, req, s)
      case is_recent(s) {
        False -> setup(web, req, s, None, 403)
        True ->
          case
            admin.claim(
              web.ctx,
              s.principal.user_id,
              form_field(form, "code") |> option.unwrap(""),
            )
          {
            Ok(_) -> ui.redirect(web, req, "/admin?done=owner_claimed")
            Error(e) -> setup(web, req, s, Some(e.message), e.status)
          }
      }
    }
    ["admin"], Get -> {
      use <- require(web, req, s, admin.ViewAdmin)
      let query = wisp.get_query(req) |> list.key_find("q") |> result.unwrap("")
      case
        admin.search_users(web.ctx.db, query, 100),
        admin.audit_log(web.ctx.db, 25)
      {
        Ok(users), Ok(audit) ->
          ui.page(
            web,
            req,
            shell(req, "Admin", Some(s), "admin"),
            views.admin_page(
              users,
              query,
              audit,
              s.role,
              s.principal.user_id,
              flash(web, req),
            ),
            200,
          )
        Error(e), _ | _, Error(e) -> app_error(web, req, s, e)
      }
    }
    ["admin", "users", id, "role"], Get -> {
      use <- require(web, req, s, admin.ManageAdmins)
      use id <- uuid(web, req, s, id)
      let to = wisp.get_query(req) |> list.key_find("to") |> result.unwrap("")
      role_confirm(web, req, s, id, to, None, 200)
    }
    ["admin", "users", id, "role"], Post -> {
      use <- require(web, req, s, admin.ManageAdmins)
      use id <- uuid(web, req, s, id)
      use form <- with_form(web, req, s)
      let to = form_field(form, "to") |> option.unwrap("")
      case is_recent(s), parse_target_role(to) {
        False, _ -> role_confirm(web, req, s, id, to, None, 403)
        _, Error(_) -> not_found(web, req)
        True, Ok(role) ->
          case admin.set_role(web.ctx, s.principal.user_id, id, role) {
            Ok(_) -> ui.redirect(web, req, "/admin?done=role_changed")
            Error(e) ->
              role_confirm(web, req, s, id, to, Some(e.message), e.status)
          }
      }
    }
    ["admin", "users", id, action], Get
      if action == "block"
      || action == "unblock"
      || action == "delete"
      || action == "cancel-deletion"
    -> {
      use <- require(web, req, s, moderation_permission(action))
      use id <- uuid(web, req, s, id)
      moderation_confirm(web, req, s, id, action, None, 200)
    }
    ["admin", "users", id, action], Post
      if action == "block"
      || action == "unblock"
      || action == "delete"
      || action == "cancel-deletion"
    -> {
      use <- require(web, req, s, moderation_permission(action))
      use id <- uuid(web, req, s, id)
      use form <- with_form(web, req, s)
      case is_recent(s) {
        False -> moderation_confirm(web, req, s, id, action, None, 403)
        True -> {
          let actor = s.principal.user_id
          let outcome = case action {
            "block" ->
              moderation.block(
                web.ctx,
                actor,
                id,
                form_field(form, "reason") |> option.unwrap(""),
              )
            "unblock" -> moderation.unblock(web.ctx, actor, id)
            "delete" ->
              moderation.delete(web.ctx, actor, id) |> result.replace(Nil)
            _ -> moderation.cancel_deletion(web.ctx, actor, id)
          }
          case outcome {
            Ok(_) ->
              ui.redirect(
                web,
                req,
                "/admin?done=" <> string.replace(action, "-", "_"),
              )
            Error(e) ->
              moderation_confirm(
                web,
                req,
                s,
                id,
                action,
                Some(conflict_message(e)),
                e.status,
              )
          }
        }
      }
    }
    ["account"], Get -> account_page(web, req, s, flash(web, req), 200)
    ["account", "delete"], Get -> delete_account_page(web, req, s, None, None, 200)
    ["account", "delete"], Post -> {
      use form <- with_form(web, req, s)
      case is_recent(s), form_field(form, "confirm") {
        False, _ -> delete_account_page(web, req, s, None, None, 403)
        True, Some("yes") -> {
          let request =
            closure.ScheduleRequest(
              acknowledge_coverage_end: form_field(form, "acknowledge_coverage_end") == Some("true"),
            )
          case closure.schedule(web.ctx, account, request) {
            Ok(_) -> ui.redirect(web, req, "/account?done=deletion_scheduled")
            Error(e) if e.code == "acknowledgement_required" ->
              delete_account_page(web, req, s, Some(e.message), None, e.status)
            Error(e) if e.code == "closure_already_scheduled" -> ui.redirect(web, req, "/account")
            Error(e) -> delete_account_page(web, req, s, None, Some(conflict_message(e)), e.status)
          }
        }
        True, _ ->
          delete_account_page(web, req, s, None, Some("Confirm that you want to delete your account."), 422)
      }
    }
    ["account", "delete", "cancel"], Post -> {
      use form <- with_form(web, req, s)
      case is_recent(s) {
        False -> account_page(web, req, s, None, 403)
        True ->
          case closure.cancel(web.ctx, account, form_int(form, "lifecycle_revision")) {
            Ok(_) -> ui.redirect(web, req, "/account?done=deletion_cancelled")
            Error(e) -> account_page(web, req, s, Some(#("danger", conflict_message(e))), e.status)
          }
      }
    }
    segments, _ ->
      case list.find_map(web.extensions, fn(e) { e.route(viewer(web, req, s), req, segments) |> option.to_result(Nil) }) {
        Ok(response) -> response
        Error(_) -> not_found(web, req)
      }
  }
}

// Setup and admin ----------------------------------------------------------------------------

/// Admin pages exist only for people with the permission; everyone else
/// gets an ordinary "not found".
fn require(
  web: Web,
  req: wisp.Request,
  s: Session,
  permission: admin.Permission,
  next: fn() -> wisp.Response,
) -> wisp.Response {
  case admin.can(s.role, permission) {
    True -> next()
    False -> not_found(web, req)
  }
}

fn setup(
  web: Web,
  req: wisp.Request,
  s: Session,
  error: Option(String),
  status: Int,
) -> wisp.Response {
  case admin.setup_available(web.ctx.db) {
    Ok(True) ->
      ui.page(
        web,
        req,
        shell(req, "Claim ownership", Some(s), ""),
        views.setup_page(s.csrf_token, is_recent(s), error),
        status,
      )
    _ -> not_found(web, req)
  }
}

fn api_keys_page(
  web: Web,
  req: wisp.Request,
  s: Session,
  created: Option(#(api_keys.ApiKey, String)),
  error: Option(String),
  status: Int,
) -> wisp.Response {
  case api_keys.list(web.ctx.db, s.principal.user_id) {
    Ok(keys) ->
      ui.page(
        web,
        req,
        shell(req, "API keys", Some(s), "settings"),
        views.api_keys_page(
          keys,
          created,
          web.origin <> settings.mcp_path,
          s.csrf_token,
          is_recent(s),
          error,
          flash(web, req),
        ),
        status,
      )
      |> wisp.set_header("cache-control", "no-store")
    Error(e) -> app_error(web, req, s, e)
  }
}

fn moderation_permission(action: String) -> admin.Permission {
  case action {
    "block" | "unblock" -> admin.BlockUsers
    _ -> admin.DeleteUsers
  }
}

fn moderation_confirm(
  web: Web,
  req: wisp.Request,
  s: Session,
  user_id: String,
  action: String,
  error: Option(String),
  status: Int,
) -> wisp.Response {
  case admin.find_user(web.ctx.db, user_id) {
    Ok(Some(user)) ->
      ui.page(
        web,
        req,
        shell(req, "Admin", Some(s), "admin"),
        views.moderation_confirm_page(
          user,
          action,
          web.ctx.config.closure_grace_seconds / 86_400,
          s.csrf_token,
          is_recent(s),
          error,
        ),
        status,
      )
    Ok(None) -> not_found(web, req)
    Error(e) -> app_error(web, req, s, e)
  }
}

fn parse_target_role(value: String) -> Result(Option(admin.Role), Nil) {
  case value {
    "owner" -> Ok(Some(admin.Owner))
    "admin" -> Ok(Some(admin.Admin))
    "none" -> Ok(None)
    _ -> Error(Nil)
  }
}

fn role_confirm(
  web: Web,
  req: wisp.Request,
  s: Session,
  user_id: String,
  to: String,
  error: Option(String),
  status: Int,
) -> wisp.Response {
  case parse_target_role(to), admin.find_user(web.ctx.db, user_id) {
    Ok(_), Ok(Some(user)) ->
      ui.page(
        web,
        req,
        shell(req, "Change role", Some(s), "admin"),
        views.role_confirm_page(user, to, s.csrf_token, is_recent(s), error),
        status,
      )
    _, Error(e) -> app_error(web, req, s, e)
    _, _ -> not_found(web, req)
  }
}

// Extensions ------------------------------------------------------------------------------

/// What an extension may use: the signed-in account and core's page helpers.
fn viewer(web: Web, req: wisp.Request, s: Session) -> config.Viewer {
  config.Viewer(
    account_id: s.principal.account_id,
    csrf_token: s.csrf_token,
    page: fn(title, content, status) { ui.page(web, req, shell(req, title, Some(s), "usage"), content, status) },
    fragment: fn(content) { ui.fragment(web, content, 200) },
    redirect: fn(to) { ui.redirect(web, req, to) },
    form: fn(next) {
      use form <- with_form(web, req, s)
      next(form.values)
    },
  )
}

fn extension_sections(web: Web, req: wisp.Request, s: Session) -> List(Element(Nil)) {
  list.flat_map(web.extensions, fn(e) { e.usage_sections(viewer(web, req, s)) })
}

fn uuid(
  web: Web,
  req: wisp.Request,
  _s: Session,
  id: String,
  next: fn(String) -> wisp.Response,
) -> wisp.Response {
  case context.is_uuid(id) {
    True -> next(string.lowercase(id))
    False -> not_found(web, req)
  }
}

/// Parse a form body and enforce CSRF + same-origin checks.
fn with_form(
  web: Web,
  req: wisp.Request,
  s: Session,
  next: fn(wisp.FormData) -> wisp.Response,
) -> wisp.Response {
  use form <- wisp.require_form(req)
  case session.check_csrf(req, s, web.origin, form_field(form, "csrf_token")) {
    Ok(_) -> next(form)
    Error(_) -> forbidden(web, req)
  }
}

fn query_int(req: wisp.Request, name: String, default: Int) -> Int {
  wisp.get_query(req) |> list.key_find(name) |> result.try(int.parse) |> result.unwrap(default)
}

fn next_cursor(items: List(pages.Page), limit: Int) -> Option(Int) {
  case list.length(items) == limit, list.last(items) {
    True, Ok(last) -> Some(last.page_number)
    _, _ -> None
  }
}

fn app_error(web: Web, req: wisp.Request, s: Session, e: AppError) -> wisp.Response {
  case e.status {
    404 -> not_found(web, req)
    401 -> ui.require_login(web, req)
    _ ->
      ui.page(web, req, shell(req, "Something went wrong", Some(s), ""), [
        ui.alert(case e.status >= 500 {
          True -> "danger"
          False -> "warning"
        }, case e.code {
          "internal_error" -> "Something went wrong. Please try again."
          _ -> e.message
        }),
      ], e.status)
  }
}

// Notebooks -------------------------------------------------------------------------------

fn notebooks_index(
  web: Web,
  req: wisp.Request,
  s: Session,
  error_message: Option(String),
  status: Int,
) -> wisp.Response {
  case notebooks.list(web.ctx.db, s.principal.account_id, None, 100) {
    Error(e) -> app_error(web, req, s, e)
    Ok(items) ->
      ui.page(
        web,
        req,
        shell(req, "Notebooks", Some(s), "notebooks"),
        [
          views.notice(flash(web, req)),
          region("notebooks-region", views.notebooks_page(items, s.csrf_token, error_message)),
        ],
        status,
      )
  }
}

fn region(id: String, children: List(Element(a))) -> Element(a) {
  element.element("div", [attribute.id(id)], children)
}

fn notebook_show(
  web: Web,
  req: wisp.Request,
  s: Session,
  id: String,
  message: Option(#(String, String)),
  status: Int,
) -> wisp.Response {
  let account = s.principal.account_id
  case notebooks.get(web.ctx.db, account, id), pages.list_for_notebook(web.ctx.db, account, id, 0, 48) {
    Ok(nb), Ok(items) ->
      ui.page(
        web,
        req,
        shell(req, nb.name, Some(s), "notebooks"),
        views.notebook_page(nb, items, next_cursor(items, 48), s.csrf_token, message),
        status,
      )
    Error(e), _ | _, Error(e) -> app_error(web, req, s, e)
  }
}

// Pages ----------------------------------------------------------------------------------

fn load_detail(web: Web, account: String, id: String) -> Result(#(pages.Page, views.Detail), AppError) {
  use page <- result.try(pages.get(web.ctx.db, account, id))
  use detail <- result.try(pages.detail_json(web.ctx.db, account, page))
  let text = json.to_string(detail)
  let transcript =
    json.parse(text, decode.at(["transcript"], decode.optional({
      use id <- decode.field("transcript_revision_id", decode.optional(decode.string))
      use body <- decode.field("text", decode.string)
      use origin <- decode.field("origin", decode.string)
      use blank <- decode.field("blank", decode.bool)
      decode.success(views.Transcript(option.unwrap(id, ""), body, origin, blank))
    })))
    |> result.unwrap(None)
  let candidate =
    json.parse(text, decode.at(["ocr_candidate"], decode.optional({
      use id <- decode.field("ocr_result_id", decode.string)
      use body <- decode.field("text", decode.string)
      decode.success(#(id, body))
    })))
    |> result.unwrap(None)
  let #(op_status, op_error) =
    json.parse(text, decode.at(["latest_operation"], decode.optional({
      use status <- decode.field("status", decode.string)
      use code <- decode.field("error_code", decode.optional(decode.string))
      decode.success(#(status, code))
    })))
    |> result.unwrap(None)
    |> option.map(fn(pair) { #(Some(pair.0), pair.1) })
    |> option.unwrap(#(None, None))
  Ok(#(page, views.Detail(transcript, candidate, op_status, op_error)))
}

fn page_show(
  web: Web,
  req: wisp.Request,
  s: Session,
  id: String,
  message: Option(#(String, String)),
  status: Int,
) -> wisp.Response {
  let account = s.principal.account_id
  case load_detail(web, account, id) {
    Error(e) -> app_error(web, req, s, e)
    Ok(#(page, detail)) -> {
      let nbs = notebooks.list(web.ctx.db, account, None, 100) |> result.unwrap([])
      ui.page(
        web,
        req,
        shell(req, "Page " <> int.to_string(page.page_number), Some(s), "notebooks"),
        views.page_detail(page, detail, s.csrf_token, nbs, integrity(web), youid.v7_string(), account, message),
        status,
      )
    }
  }
}

fn save_transcript(
  web: Web,
  req: wisp.Request,
  s: Session,
  id: String,
  form: wisp.FormData,
) -> wisp.Response {
  let account = s.principal.account_id
  let text = form_field(form, "text") |> option.unwrap("")
  let action = case form_field(form, "action") {
    Some("confirm_blank") -> transcripts.ConfirmBlank
    _ -> transcripts.Save(text)
  }
  let request =
    transcripts.Request(
      source_revision_id: form_field(form, "source_revision_id") |> option.unwrap(""),
      base_transcript_revision_id: case form_field(form, "base_transcript_revision_id") {
        Some("") | None -> None
        other -> other
      },
      action:,
    )
  let version = form_field(form, "content_version") |> option.then(fn(v) { int.parse(v) |> option.from_result })
  let outcome = transcripts.save(web.ctx, account, id, version, request)
  case outcome, load_detail(web, account, id) {
    _, Error(e) -> app_error(web, req, s, e)
    Ok(_), Ok(#(page, detail)) -> {
      let panel = views.transcript_panel(page, detail, s.csrf_token, None, None)
      case ui.is_htmx(req) {
        True ->
          ui.fragment(web, [panel], 200)
          |> wisp.set_header("hx-trigger", "{\"libarrie:announce\":\"Transcript saved\"}")
        False -> ui.redirect(web, req, "/pages/" <> id)
      }
    }
    Error(e), Ok(#(page, detail)) -> {
      // Stale edit or a pending source operation: explain, keep the user's
      // text, and show the current version.
      let message = case e.code {
        "version_conflict" ->
          "This page changed since you opened it (perhaps on another device). The current text is shown below; your unsaved text is kept above."
        "processing_conflict" ->
          "The page is being processed right now. Wait for processing to finish, then save again; your text is kept above."
        "rate_limited" -> "Too many edits in a short time. Wait a moment and try again; your text is kept above."
        _ -> e.message
      }
      let panel =
        views.transcript_panel(page, detail, s.csrf_token, Some(message), Some(text))
      case ui.is_htmx(req) {
        True -> ui.fragment(web, [panel], e.status)
        False -> app_error(web, req, s, e)
      }
    }
  }
}

fn original(web: Web, req: wisp.Request, s: Session, id: String) -> wisp.Response {
  let account = s.principal.account_id
  case pages.get(web.ctx.db, account, id) {
    Error(e) -> app_error(web, req, s, e)
    Ok(page) ->
      case
        database.query_one(
          web.ctx.db,
          "select o.key from page_revisions r join objects o on o.id = r.source_object_id
           where r.account_id = $1::uuid and r.id = $2::uuid and o.state = 'stored'",
          [database.text(account), database.nullable_text(page.revision_id)],
          decode.at([0], decode.string),
        )
      {
        Ok(Some(key)) -> {
          // Originals use direct five-minute signed URLs (never thumbnails).
          let signed =
            storage.presign_get(
              web.ctx.config.storage,
              key,
              web.ctx.config.download_url_seconds,
              "private, no-store",
            )
          wisp.response(303) |> wisp.set_header("location", signed.url) |> ui.security_headers(web)
        }
        _ -> not_found(web, req)
      }
  }
}

// Search -------------------------------------------------------------------------------

fn run_search(web: Web, req: wisp.Request, s: Session, form: wisp.FormData) -> wisp.Response {
  let account = s.principal.account_id
  let request =
    search.Request(
      query: form_field(form, "query") |> option.unwrap(""),
      notebook_id: case form_field(form, "notebook_id") {
        Some("") | None -> None
        other -> other
      },
      limit: 20,
    )
  let limited =
    ratelimit.hit(web.ctx.db, "search:" <> account, "search", web.ctx.config.rate_limits.searches_per_minute, 60)
  let outcome = result.try(limited, fn(_) { search.search(web.ctx, account, request) })
  let content = case outcome {
    Error(e) -> [ui.alert("warning", e.message)]
    Ok(body) -> {
      let text = json.to_string(body)
      let mode = json.parse(text, decode.at(["search_mode"], decode.string)) |> result.unwrap("hybrid")
      let migrating = json.parse(text, decode.at(["index_migration_pending"], decode.bool)) |> result.unwrap(False)
      let hits =
        json.parse(text, decode.at(["results"], decode.list({
          use page_id <- decode.field("page_id", decode.string)
          use name <- decode.subfield(["notebook", "name"], decode.string)
          use number <- decode.field("page_number", decode.int)
          use snippet <- decode.field("snippet", decode.string)
          use highlights <- decode.field("highlights", decode.list({
            use start <- decode.field("start", decode.int)
            use end <- decode.field("end", decode.int)
            decode.success(#(start, end))
          }))
          use kind <- decode.field("match_kind", decode.string)
          use pending <- decode.field("indexing_pending", decode.bool)
          decode.success(views.Hit(page_id, name, number, snippet, highlights, kind, pending))
        })))
        |> result.unwrap([])
      views.search_results(mode, migrating, hits)
    }
  }
  case ui.is_htmx(req) {
    True -> ui.fragment(web, content, 200)
    False -> {
      let nbs = notebooks.list(web.ctx.db, account, None, 100) |> result.unwrap([])
      ui.page(web, req, shell(req, "Search", Some(s), "search"), list.append(views.search_page(nbs, s.csrf_token), content), 200)
    }
  }
}

// Usage and account -------------------------------------------------------------------------

fn usage(web: Web, req: wisp.Request, s: Session) -> wisp.Response {
  let waiting = pages.count_awaiting_processing(web.ctx.db, s.principal.account_id) |> result.unwrap(0)
  case quota.usage_json(web.ctx.db, web.ctx.config, s.principal.account_id) {
    Error(e) -> app_error(web, req, s, e)
    Ok(body) -> {
      let text = json.to_string(body)
      let limit = fn(path) {
        json.parse(text, decode.at(path, {
          use kind <- decode.field("kind", decode.string)
          case kind {
            "limited" -> decode.at(["value"], decode.int) |> decode.map(Some)
            _ -> decode.success(None)
          }
        }))
        |> result.unwrap(None)
      }
      let number = fn(path) { json.parse(text, decode.at(path, decode.int)) |> result.unwrap(0) }
      let summary =
        views.Usage(
          stored: number(["stored_pages"]),
          stored_limit: limit(["limits", "stored_pages"]),
          reserved: number(["reserved_page_slots"]),
          notebooks: number(["notebooks"]),
          notebook_limit: limit(["limits", "notebooks"]),
          processing_used: number(["lifetime_allowance", "used"]),
          processing_reserved: number(["lifetime_allowance", "reserved"]),
          processing_limit: limit(["lifetime_allowance", "limit"]),
          warning: json.parse(text, decode.at(["capacity_warning"], decode.string)) |> result.unwrap("none"),
        )
      ui.page(
        web,
        req,
        shell(req, "Usage", Some(s), "usage"),
        views.usage_page(summary, waiting, extension_sections(web, req, s), s.csrf_token, flash(web, req)),
        200,
      )
    }
  }
}

fn account_status(web: Web, req: wisp.Request, s: Session) -> wisp.Response {
  let field = fn(path) {
    closure.status(web.ctx, s.principal.account_id)
    |> result.map(fn(body) {
      json.parse(
        json.to_string(body),
        decode.at(path, decode.optional(decode.string)),
      )
      |> option.from_result
      |> option.flatten
    })
    |> result.unwrap(None)
  }
  case accounts.is_suspended(s.principal) && !s.status_only {
    True ->
      ui.page(
        web,
        req,
        shell(req, "Account blocked", Some(s), ""),
        views.blocked_account(field(["effective_at"])),
        200,
      )
    False ->
      ui.page(
        web,
        req,
        shell(req, "Account", Some(s), ""),
        views.closed_account(field(["milestone"])),
        200,
      )
  }
}

// Shared helpers for management screens -------------------------------------------------

fn integrity(web: Web) -> String {
  case web.ctx.config.storage.upload_integrity {
    storage.ContentMd5 -> "md5"
    storage.Sha256Header -> "sha256"
  }
}

fn form_int(form: wisp.FormData, name: String) -> Option(Int) {
  form_field(form, name) |> option.then(fn(v) { int.parse(string.trim(v)) |> option.from_result })
}

/// Sensitive actions (permanent deletion, account deletion and its
/// cancellation) need a sign-in within the last five minutes; the server
/// enforces this on every submission, not only when rendering the form.
fn is_recent(s: Session) -> Bool {
  accounts.require_recent_auth(s.principal, oidc.now()) |> result.is_ok
}

/// One-shot confirmations after a redirect. Only fixed codes are accepted,
/// so no request text is ever echoed into the page.
fn flash(web: Web, req: wisp.Request) -> Option(#(String, String)) {
  let query = wisp.get_query(req)
  let count = fn(name) { list.key_find(query, name) |> result.try(int.parse) |> result.unwrap(0) }
  case list.key_find(query, "done") {
    Ok("notebook_saved") -> Some(#("ok", "Notebook saved."))
    Ok("settings_saved") -> Some(#("ok", "Settings saved."))
    Ok("api_key_revoked") -> Some(#("ok", "API key revoked. Agents using it lose access right away."))
    Ok("owner_claimed") -> Some(#("ok", "You are now an owner of this server."))
    Ok("role_changed") -> Some(#("ok", "Role updated."))
    Ok("block") -> Some(#("ok", "Account blocked."))
    Ok("unblock") -> Some(#("ok", "Account unblocked."))
    Ok("delete") ->
      Some(#("warning", "Account blocked and scheduled for deletion."))
    Ok("cancel_deletion") ->
      Some(#("ok", "Deletion cancelled. The account is still blocked."))
    Ok("notebook_trashed") ->
      Some(#("ok", "Notebook moved to trash. You can restore it from Trash for 30 days."))
    Ok("renumbered") -> Some(#("ok", "Pages renumbered."))
    Ok("page_moved") -> Some(#("ok", "Page updated."))
    Ok("rescan_started") ->
      Some(#("ok", "Rescanning. The transcript updates when it finishes."))
    Ok("export_started") ->
      Some(#("ok", "Export started. This page updates when your files are ready."))
    Ok("purged") ->
      Some(#("ok", "Deleting permanently. This can take a few minutes to finish."))
    Ok("deletion_scheduled") -> Some(#("warning", "Account deletion scheduled."))
    Ok("deletion_cancelled") ->
      Some(#("ok", "Account deletion cancelled. Your account is fully active again."))
    Ok("processing") -> {
      let started = count("started")
      let limited = count("limited")
      Some(case started, limited {
        0, 0 -> #("info", "No pages were waiting for processing.")
        0, _ -> #("warning", "Your processing allowance is used up, so no pages could start.")
        n, 0 -> #("ok", int.to_string(n) <> " " <> pages_word(n) <> " started processing.")
        n, m ->
          #(
            "warning",
            int.to_string(n) <> " " <> pages_word(n) <> " started processing. "
              <> int.to_string(m) <> " " <> pages_word(m)
              <> " still wait because your processing allowance is used up.",
          )
      })
    }
    Ok(code) -> list.find_map(web.extensions, fn(e) { e.notice(code) |> option.to_result(Nil) }) |> option.from_result
    Error(_) -> None
  }
}

fn pages_word(n: Int) -> String {
  case n {
    1 -> "page"
    _ -> "pages"
  }
}

/// User-facing explanations for the common 409/412 outcomes.
fn conflict_message(e: AppError) -> String {
  case e.code {
    "version_conflict" ->
      "This changed since you opened the page (perhaps on another device). Reload and try again."
    "recovery_pending" ->
      "Your previous change to this item is still being recorded safely. Try again in a minute."
    "internal_error" -> "Something went wrong. Please try again."
    _ -> e.message
  }
}

fn renumber_message(e: AppError) -> String {
  case e.code {
    "page_number_conflict" ->
      "That would give two pages the same number. Choose numbers that are free, or move a wider range."
    _ -> conflict_message(e)
  }
}

// Renumbering ---------------------------------------------------------------------------

fn renumber_page(
  web: Web,
  req: wisp.Request,
  s: Session,
  id: String,
  error_message: Option(String),
  values: views.ShiftForm,
  status: Int,
) -> wisp.Response {
  let account = s.principal.account_id
  case notebooks.get(web.ctx.db, account, id), pages.numbering(web.ctx.db, account, id) {
    Ok(nb), Ok(numbering) ->
      ui.page(
        web,
        req,
        shell(req, "Renumber pages", Some(s), "notebooks"),
        views.renumber_page(
          nb,
          numbering.numbering_revision,
          list.map(numbering.pages, fn(p) { p.1 }),
          s.csrf_token,
          error_message,
          values,
        ),
        status,
      )
    Error(e), _ | _, Error(e) -> app_error(web, req, s, e)
  }
}

// Deferred processing -----------------------------------------------------------------------

fn process_deferred(web: Web, req: wisp.Request, s: Session) -> wisp.Response {
  let account = s.principal.account_id
  case pages.list_awaiting_processing(web.ctx.db, account, 100) {
    Error(e) -> app_error(web, req, s, e)
    Ok([]) -> ui.redirect(web, req, "/usage?done=processing")
    Ok(waiting) -> {
      let items =
        list.filter_map(waiting, fn(page) {
          case page.revision_id {
            Some(revision) -> Ok(uploads.DeferredItem(page.id, revision, youid.v7_string()))
            None -> Error(Nil)
          }
        })
      case uploads.process_deferred(web.ctx, account, items) {
        Error(e) -> app_error(web, req, s, e)
        Ok(body) -> {
          let results =
            json.parse(json.to_string(body), decode.at(["results"], decode.list(decode.at(["result"], decode.string))))
            |> result.unwrap([])
          let started = list.count(results, fn(r) { r == "admitted" || r == "already_admitted" })
          let limited = list.count(results, fn(r) { r == "limit" })
          ui.redirect(
            web,
            req,
            "/usage?done=processing&started=" <> int.to_string(started) <> "&limited=" <> int.to_string(limited),
          )
        }
      }
    }
  }
}

// Trash: permanent deletion ------------------------------------------------------------

type PurgeSelection {
  PurgePage(String)
  PurgeNotebook(String)
  PurgeAll
  PurgeNothing
}

fn purge_selection(values: List(#(String, String))) -> PurgeSelection {
  case list.key_find(values, "page"), list.key_find(values, "notebook"), list.key_find(values, "all") {
    Ok(id), _, _ ->
      case context.is_uuid(id) {
        True -> PurgePage(string.lowercase(id))
        False -> PurgeNothing
      }
    _, Ok(id), _ ->
      case context.is_uuid(id) {
        True -> PurgeNotebook(string.lowercase(id))
        False -> PurgeNothing
      }
    _, _, Ok("1") -> PurgeAll
    _, _, _ -> PurgeNothing
  }
}

fn load_trash(web: Web, account: String) -> #(List(pages.Page), List(notebooks.Notebook)) {
  #(
    pages.list_trashed(web.ctx.db, account, "00000000-0000-0000-0000-000000000000", 100)
      |> result.unwrap([]),
    notebooks.list_trashed(web.ctx.db, account, 100) |> result.unwrap([]),
  )
}

fn purge_confirm(
  web: Web,
  req: wisp.Request,
  s: Session,
  selection: PurgeSelection,
  error_message: Option(String),
  status: Int,
) -> wisp.Response {
  let #(trashed, trashed_notebooks) = load_trash(web, s.principal.account_id)
  let target = case selection {
    PurgePage(id) ->
      list.find(trashed, fn(p) { p.id == id })
      |> result.map(fn(p) {
        #(
          "Page " <> int.to_string(p.page_number) <> " of " <> p.notebook_name <> " will be deleted permanently.",
          [#("page", id)],
          "/trash/purge?page=" <> id,
        )
      })
    PurgeNotebook(id) ->
      list.find(trashed_notebooks, fn(nb) { nb.id == id })
      |> result.map(fn(nb) {
        #(
          "The notebook " <> nb.name <> " and its pages in trash will be deleted permanently.",
          [#("notebook", id)],
          "/trash/purge?notebook=" <> id,
        )
      })
    PurgeAll ->
      case trashed, trashed_notebooks {
        [], [] -> Error(Nil)
        _, _ -> Ok(#("Everything in trash will be deleted permanently.", [#("all", "1")], "/trash/purge?all=1"))
      }
    PurgeNothing -> Error(Nil)
  }
  case target {
    Error(_) -> ui.redirect(web, req, "/trash")
    Ok(#(description, fields, return_to)) ->
      ui.page(
        web,
        req,
        shell(req, "Delete permanently", Some(s), "trash"),
        views.purge_confirm_page(description, fields, s.csrf_token, is_recent(s), return_to, error_message),
        status,
      )
  }
}

// Exports ---------------------------------------------------------------------------------

fn exports_page(
  web: Web,
  req: wisp.Request,
  s: Session,
  message: Option(#(String, String)),
  status: Int,
) -> wisp.Response {
  let account = s.principal.account_id
  case exports.list(web.ctx, account) {
    Error(e) -> app_error(web, req, s, e)
    Ok(body) -> {
      let summaries =
        json.parse(json.to_string(body), decode.at(["exports"], decode.list(export_decoder([]))))
        |> result.unwrap([])
      // Completed exports list their downloadable parts.
      let items =
        list.map(summaries, fn(summary) {
          case summary.state {
            "completed" ->
              exports.get(web.ctx, account, summary.id)
              |> result.try(fn(detail) {
                json.parse(json.to_string(detail), decode.at(["parts"], decode.list({
                  use number <- decode.field("part_number", decode.int)
                  use items <- decode.field("item_count", decode.int)
                  use bytes <- decode.field("bytes", decode.optional(decode.int))
                  decode.success(views.ExportPart(number, items, bytes))
                })))
                |> result.replace_error(error.internal("export detail response"))
              })
              |> result.map(fn(parts) { views.Export(..summary, parts:) })
              |> result.unwrap(summary)
            _ -> summary
          }
        })
      let nbs = notebooks.list(web.ctx.db, account, None, 100) |> result.unwrap([])
      ui.page(
        web,
        req,
        shell(req, "Exports", Some(s), "exports"),
        views.exports_page(nbs, items, s.csrf_token, message),
        status,
      )
    }
  }
}

fn export_decoder(parts: List(views.ExportPart)) -> decode.Decoder(views.Export) {
  use id <- decode.field("id", decode.string)
  use state <- decode.field("state", decode.string)
  use include_trash <- decode.field("include_trash", decode.bool)
  use item_count <- decode.field("item_count", decode.int)
  use total_bytes <- decode.field("total_bytes", decode.int)
  use created_at <- decode.field("created_at", decode.string)
  use expires_at <- decode.field("expires_at", decode.optional(decode.string))
  use error_code <- decode.field("error_code", decode.optional(decode.string))
  decode.success(views.Export(
    id:,
    state:,
    include_trash:,
    item_count:,
    total_bytes:,
    created_at:,
    expires_at:,
    error_code:,
    parts:,
  ))
}

// Account ---------------------------------------------------------------------------------

fn load_account(web: Web, account: String) -> Result(views.AccountStatus, AppError) {
  use body <- result.try(closure.status(web.ctx, account))
  json.parse(json.to_string(body), {
    use status <- decode.field("status", decode.string)
    use milestone <- decode.field("milestone", decode.string)
    use revision <- decode.field("lifecycle_revision", decode.int)
    use effective_at <- decode.field("effective_at", decode.optional(decode.string))
    decode.success(views.AccountStatus(status, milestone, revision, effective_at))
  })
  |> result.replace_error(error.internal("closure status response"))
}

fn grace_days(web: Web) -> Int {
  int.max(1, web.ctx.config.closure_grace_seconds / 86_400)
}

fn account_page(
  web: Web,
  req: wisp.Request,
  s: Session,
  message: Option(#(String, String)),
  status: Int,
) -> wisp.Response {
  case load_account(web, s.principal.account_id) {
    Error(e) -> app_error(web, req, s, e)
    Ok(account) ->
      case account.status {
        "active" | "closure_scheduled" ->
          ui.page(
            web,
            req,
            shell(req, "Account", Some(s), "account"),
            views.account_page(display_name(s), account, s.csrf_token, is_recent(s), grace_days(web), message),
            status,
          )
        _ -> account_status(web, req, s)
      }
  }
}

fn delete_account_page(
  web: Web,
  req: wisp.Request,
  s: Session,
  acknowledgement: Option(String),
  error_message: Option(String),
  status: Int,
) -> wisp.Response {
  case load_account(web, s.principal.account_id) {
    Error(e) -> app_error(web, req, s, e)
    Ok(account) if account.status != "active" -> ui.redirect(web, req, "/account")
    Ok(_) ->
      ui.page(
        web,
        req,
        shell(req, "Delete account", Some(s), "account"),
        views.delete_account_page(s.csrf_token, is_recent(s), grace_days(web), acknowledgement, error_message),
        status,
      )
  }
}
