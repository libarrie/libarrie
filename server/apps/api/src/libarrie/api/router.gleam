//// `/v1` JSON routes and internal entitlement routes (section 11).

import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/http.{Delete, Get, Patch, Post, Put}
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import libarrie/api/auth.{type Auth}
import libarrie/web
import libarrie/web/config.{type Web}
import libarrie/database
import libarrie/domain/accounts.{type Principal}
import libarrie/domain/closure
import libarrie/domain/context.{type Context}
import libarrie/domain/derived
import libarrie/domain/deferred
import libarrie/domain/entitlements
import libarrie/domain/exports
import libarrie/domain/error.{type AppError}
import libarrie/domain/idempotency
import libarrie/domain/journal
import libarrie/domain/notebooks
import libarrie/domain/pages
import libarrie/domain/purge
import libarrie/domain/quota
import libarrie/domain/ratelimit
import libarrie/domain/search
import libarrie/domain/transcripts
import libarrie/domain/uploads
import libarrie/integrations/storage
import wisp

pub type App {
  App(ctx: Context, auth: Auth, web: Web)
}

pub fn handle(app: App, req: wisp.Request) -> wisp.Response {
  case wisp.path_segments(req) {
    ["v1", ..] | ["internal", ..] | ["img", ..] | ["healthz"] | ["readyz"] -> handle_api(app, req)
    _ -> {
      use <- wisp.rescue_crashes
      web.handle(app.web, wisp.set_max_body_size(req, 1_000_000))
    }
  }
}

fn handle_api(app: App, req: wisp.Request) -> wisp.Response {
  let request_id = wisp.random_string(16)
  use <- wisp.rescue_crashes
  let req = wisp.set_max_body_size(req, 1_000_000)
  let response = case route(app, req) {
    Ok(response) -> response
    Error(e) -> error_response(e, request_id)
  }
  response
  |> wisp.set_header("x-request-id", request_id)
  |> wisp.set_header("x-content-type-options", "nosniff")
  |> wisp.set_header("referrer-policy", "same-origin")
  |> fn(r) {
    case list.key_find(r.headers, "cache-control") {
      Ok(_) -> r
      Error(_) -> wisp.set_header(r, "cache-control", "private, no-store")
    }
  }
}

fn error_response(e: AppError, request_id: String) -> wisp.Response {
  case e.code {
    "internal_error" ->
      wisp.log_error(
        "request " <> request_id <> " failed: " <> string.inspect(e.details),
      )
    _ -> Nil
  }
  let response =
    wisp.json_response(json.to_string(error.to_json(e, request_id)), e.status)
  case e.retry_after {
    Some(seconds) ->
      wisp.set_header(response, "retry-after", int.to_string(seconds))
    None -> response
  }
}

fn route(app: App, req: wisp.Request) -> Result(wisp.Response, AppError) {
  case wisp.path_segments(req) {
    ["healthz"] -> Ok(wisp.json_response("{\"status\":\"ok\"}", 200))
    ["readyz"] -> ready(app)
    ["internal", "v1", "accounts", account_id, ..rest] -> {
      use _ <- result.try(auth.require_internal(app.auth, req))
      use account_id <- context.require_uuid(account_id)
      internal(app, req, account_id, rest)
    }
    // Public: what a native app needs to sign in and upload (no account data).
    ["v1", "client-configuration"] -> client_configuration(app, req)
    // Same-origin thumbnails and previews (section 6): authorize every
    // request, stream bytes, cache privately; never redirect to a signed URL.
    ["img", object_id, variant] if variant == "thumb" || variant == "preview" -> {
      use principal <- result.try(auth.principal(app.ctx, app.auth, req))
      use <- error.guard(accounts.can_read(principal), error.account_closing())
      use object_id <- context.require_uuid(object_id)
      use bytes <- result.try(derived.fetch(app.ctx, principal.account_id, object_id, variant))
      Ok(
        wisp.response(200)
        |> wisp.set_header("content-type", "image/jpeg")
        |> wisp.set_header("cache-control", "private, max-age=86400")
        |> wisp.set_body(wisp.Bytes(bytes_tree.from_bit_array(bytes))),
      )
    }
    ["v1", ..rest] ->
      case auth.principal(app.ctx, app.auth, req) {
        // After purge only the keyed identity hash survives.
        Error(e) if e.code == "account_closed" -> purged_identity(app, req, rest)
        Error(e) -> Error(e)
        Ok(principal) ->
          case accounts.can_read(principal) {
            True -> {
              use _ <- result.try(ratelimit.hit(
                app.ctx.db,
                "requests:" <> principal.account_id,
                "requests",
                app.ctx.config.rate_limits.requests_per_minute,
                60,
              ))
              v1(app, req, principal, rest)
            }
            // Closing/closed accounts get a status-only session.
            False -> status_only(app, req, principal, rest)
          }
      }
    _ -> Error(error.not_found())
  }
}

fn ready(app: App) -> Result(wisp.Response, AppError) {
  case
    database.query_one(
      app.ctx.db,
      "select count(*)::int from schema_migrations",
      [],
      decode.at([0], decode.int),
    )
  {
    Ok(Some(n)) if n > 0 -> Ok(wisp.json_response("{\"status\":\"ready\"}", 200))
    _ -> Error(error.unavailable())
  }
}

// Helpers --------------------------------------------------------------------------

fn body_text(req: wisp.Request) -> Result(String, AppError) {
  use bits <- result.try(
    wisp.read_body_bits(req)
    |> result.replace_error(error.new(413, "invalid_request", "The request body is too large.")),
  )
  bit_array.to_string(bits)
  |> result.replace_error(error.bad_request("The request body must be UTF-8 JSON."))
}

fn json_body(
  req: wisp.Request,
  decoder: decode.Decoder(a),
  next: fn(a) -> Result(wisp.Response, AppError),
) -> Result(wisp.Response, AppError) {
  use text <- result.try(body_text(req))
  context.decode_body(text, decoder, next)
}

fn ok(body: json.Json) -> Result(wisp.Response, AppError) {
  Ok(wisp.json_response(json.to_string(body), 200))
}

fn respond(status: Int, body: json.Json) -> Result(wisp.Response, AppError) {
  Ok(wisp.json_response(json.to_string(body), status))
}

fn with_etag(response: wisp.Response, etag: String) -> wisp.Response {
  wisp.set_header(response, "etag", etag)
}

/// Parse `If-Match` values such as `"v3"`, `"c7"`, `W/"n2"` or `3`.
fn if_match(req: wisp.Request) -> Option(Int) {
  case request.get_header(req, "if-match") {
    Error(_) -> None
    Ok(raw) -> {
      let value =
        raw
        |> string.trim
        |> string.replace("W/", "")
        |> string.replace("\"", "")
      let digits = case string.pop_grapheme(value) {
        Ok(#(first, rest)) ->
          case int.parse(first) {
            Ok(_) -> value
            Error(_) -> rest
          }
        Error(_) -> value
      }
      int.parse(digits) |> option.from_result
    }
  }
}

fn query_int(req: wisp.Request, name: String, default: Int) -> Int {
  wisp.get_query(req)
  |> list.key_find(name)
  |> result.try(int.parse)
  |> result.unwrap(default)
}

fn page_size(req: wisp.Request) -> Int {
  int.clamp(query_int(req, "limit", 50), 1, 100)
}

fn idempotency_key(req: wisp.Request) -> Option(String) {
  request.get_header(req, "idempotency-key") |> option.from_result
}

fn accepted_lifecycle(
  resource: #(String, json.Json),
  intent: journal.Intent,
) -> Result(wisp.Response, AppError) {
  // 202 with recovery_pending until the independent journal acknowledges.
  respond(
    202,
    json.object([
      resource,
      #("status", json.string(intent.state)),
      #("journal", journal.intent_json(intent)),
    ]),
  )
}

// Status-only access -------------------------------------------------------------------

fn status_only(
  app: App,
  req: wisp.Request,
  principal: Principal,
  segments: List(String),
) -> Result(wisp.Response, AppError) {
  case segments, req.method {
    ["account-deletion"], Get -> closure.status(app.ctx, principal.account_id) |> result.try(ok)
    // A blocked account (ADR 0011) can still see itself and take its notes
    // with it: exports only.
    ["me"], Get | ["exports"], Get | ["exports"], Post | ["exports", _], Get
    | ["exports", _, "parts", _, "download-url"], Get
      if principal.account_status == "suspended"
    -> v1(app, req, principal, segments)
    _, _ ->
      case accounts.is_suspended(principal) {
        True -> Error(account_suspended())
        False -> Error(error.account_closing())
      }
  }
}

fn account_suspended() -> AppError {
  error.new(
    403,
    "account_suspended",
    "This account is blocked. You can still download an export of your notes. Contact the server's administrator.",
  )
}

fn purged_identity(
  app: App,
  req: wisp.Request,
  segments: List(String),
) -> Result(wisp.Response, AppError) {
  case segments, req.method {
    ["account-deletion"], Get ->
      ok(json.object([
        #("status", json.string("closed")),
        #("milestone", json.string("closed")),
        #("purge_status", json.string("completed")),
      ]))
    // Creating a new account is an explicit choice; it inherits the
    // identity's prior lifetime-allowance usage.
    ["accounts"], Post -> {
      use claims <- result.try(auth.bearer_claims(app.auth, req))
      use principal <- result.try(accounts.create_after_purge(
        app.ctx,
        claims.issuer,
        claims.subject,
        claims.name,
        claims.auth_time,
      ))
      respond(201, accounts.me_json(principal))
    }
    _, _ ->
      Error(error.new(403, "account_closed", "The account for this sign-in was closed and purged."))
  }
}

fn now_seconds() -> Int {
  let #(seconds, _) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  seconds
}

fn recent(principal: Principal, next: fn() -> Result(a, AppError)) -> Result(a, AppError) {
  use _ <- result.try(accounts.require_recent_auth(principal, now_seconds()))
  next()
}

// /v1 ------------------------------------------------------------------------------

fn v1(
  app: App,
  req: wisp.Request,
  principal: Principal,
  segments: List(String),
) -> Result(wisp.Response, AppError) {
  let ctx = app.ctx
  let account = principal.account_id
  case segments, req.method {
    ["me"], Get -> ok(accounts.me_json(principal))
    ["settings"], Get -> deferred.get(ctx, account) |> result.map(deferred.settings_json) |> result.try(ok)
    ["settings"], Put -> {
      use enabled <- json_body(req, deferred.decoder())
      deferred.update(ctx, account, enabled) |> result.map(deferred.settings_json) |> result.try(ok)
    }
    ["usage"], Get -> quota.usage_json(ctx.db, ctx.config, account) |> result.try(ok)

    ["notebooks"], Get -> {
      let after = wisp.get_query(req) |> list.key_find("cursor") |> option.from_result
      use after <- result.try(case after {
        Some(id) -> context.require_uuid(id, fn(id) { Ok(Some(id)) })
        None -> Ok(None)
      })
      let limit = page_size(req)
      use rows <- result.try(notebooks.list(ctx.db, account, after, limit))
      let next = case list.length(rows) == limit, list.last(rows) {
        True, Ok(last) -> json.string(last.id)
        _, _ -> json.null()
      }
      ok(json.object([
        #("notebooks", json.array(rows, notebooks.to_json)),
        #("next_cursor", next),
      ]))
    }
    ["notebooks"], Post -> {
      use text <- result.try(body_text(req))
      use input <- context.decode_body(text, notebooks.input_decoder())
      use response <- result.try(context.transaction(ctx, fn(tx) {
        idempotency.run(
          tx,
          account,
          "POST /v1/notebooks",
          idempotency_key(req),
          context.sha256_hex(text),
          fn() {
            use notebook <- result.try(notebooks.create(tx, ctx.config, account, input))
            Ok(#(201, notebooks.to_json(notebook)))
          },
        )
      }))
      Ok(wisp.json_response(response.body, response.status))
    }
    ["notebooks", id], Get -> {
      use id <- context.require_uuid(id)
      use notebook <- result.try(notebooks.get(ctx.db, account, id))
      ok(notebooks.to_json(notebook)) |> result.map(with_etag(_, notebooks.etag(notebook)))
    }
    ["notebooks", id], Patch -> {
      use id <- context.require_uuid(id)
      use input <- json_body(req, notebooks.input_decoder())
      use notebook <- result.try(notebooks.update(ctx, account, id, if_match(req), input))
      ok(notebooks.to_json(notebook)) |> result.map(with_etag(_, notebooks.etag(notebook)))
    }
    ["notebooks", id], Delete -> {
      use id <- context.require_uuid(id)
      use #(notebook, intent) <- result.try(notebooks.trash(ctx, account, id, if_match(req)))
      accepted_lifecycle(#("notebook", notebooks.to_json(notebook)), intent)
    }
    ["notebooks", id, "restore"], Post -> {
      use id <- context.require_uuid(id)
      use request <- json_body(req, notebooks.restore_decoder())
      use #(notebook, intent) <- result.try(notebooks.restore(ctx, account, id, request))
      accepted_lifecycle(#("notebook", notebooks.to_json(notebook)), intent)
    }
    ["notebooks", id, "pages"], Get -> {
      use id <- context.require_uuid(id)
      use notebook <- result.try(notebooks.get(ctx.db, account, id))
      let limit = page_size(req)
      let after = query_int(req, "cursor", 0)
      use rows <- result.try(pages.list_for_notebook(ctx.db, account, id, after, limit))
      let next = case list.length(rows) == limit, list.last(rows) {
        True, Ok(last) -> json.string(int.to_string(last.page_number))
        _, _ -> json.null()
      }
      ok(json.object([
        #("notebook_id", json.string(id)),
        #("numbering_revision", json.int(notebook.numbering_revision)),
        #("pages", json.array(rows, pages.to_json)),
        #("next_cursor", next),
      ]))
    }
    ["notebooks", id, "renumber"], Get -> {
      use id <- context.require_uuid(id)
      use numbering <- result.try(pages.numbering(ctx.db, account, id))
      ok(pages.numbering_json(numbering))
      |> result.map(with_etag(_, pages.numbering_etag(numbering.numbering_revision)))
    }
    ["notebooks", id, "renumber"], Post -> {
      use id <- context.require_uuid(id)
      use plan <- json_body(req, pages.renumber_decoder())
      use #(moved, revision) <- result.try(pages.renumber(ctx, account, id, plan, if_match(req)))
      ok(json.object([
        #("notebook_id", json.string(id)),
        #("numbering_revision", json.int(revision)),
        #("moved", json.preprocessed_array(moved)),
      ]))
      |> result.map(with_etag(_, pages.numbering_etag(revision)))
    }

    ["trash"], Get -> {
      let limit = page_size(req)
      let after =
        wisp.get_query(req)
        |> list.key_find("cursor")
        |> result.unwrap("00000000-0000-0000-0000-000000000000")
      use after <- context.require_uuid(after)
      use trashed_pages <- result.try(pages.list_trashed(ctx.db, account, after, limit))
      use trashed_notebooks <- result.try(notebooks.list_trashed(ctx.db, account, 100))
      let next = case list.length(trashed_pages) == limit, list.last(trashed_pages) {
        True, Ok(last) -> json.string(last.id)
        _, _ -> json.null()
      }
      ok(json.object([
        #("retention_days", json.int(ctx.config.trash_retention_days)),
        #("notebooks", json.array(trashed_notebooks, notebooks.to_json)),
        #("pages", json.array(trashed_pages, pages.to_json)),
        #("next_cursor", next),
      ]))
    }
    ["trash", "purge"], Post -> {
      use <- recent(principal)
      use request <- json_body(req, purge.decoder())
      use #(body, intent) <- result.try(purge.purge_trash(ctx, account, request))
      accepted_lifecycle(#("purge", body), intent)
    }

    ["pages", "awaiting-processing"], Get -> {
      use rows <- result.try(pages.list_awaiting_processing(ctx.db, account, 100))
      ok(json.object([#("pages", json.array(rows, pages.to_json))]))
    }
    ["pages", "process-deferred"], Post -> {
      use items <- json_body(req, uploads.deferred_decoder())
      uploads.process_deferred(ctx, account, items) |> result.try(ok)
    }
    ["pages", id], Get -> {
      use id <- context.require_uuid(id)
      use page <- result.try(pages.get(ctx.db, account, id))
      use detail <- result.try(pages.detail_json(ctx.db, account, page))
      ok(detail) |> result.map(with_etag(_, pages.etag(page)))
    }
    ["pages", id], Patch -> {
      use id <- context.require_uuid(id)
      use change <- json_body(req, pages.change_decoder())
      use page <- result.try(pages.update(ctx, account, id, if_match(req), change))
      ok(json.object([#("page", pages.to_json(page))]))
      |> result.map(with_etag(_, pages.etag(page)))
    }
    ["pages", id], Delete -> {
      use id <- context.require_uuid(id)
      use #(page, intent) <- result.try(pages.trash(ctx, account, id, if_match(req)))
      accepted_lifecycle(#("page", pages.to_json(page)), intent)
    }
    ["pages", id, "restore"], Post -> {
      use id <- context.require_uuid(id)
      use target <- json_body(req, pages.restore_decoder())
      use #(page, intent) <- result.try(pages.restore(ctx, account, id, target))
      accepted_lifecycle(#("page", pages.to_json(page)), intent)
    }
    ["pages", id, "transcript"], Put -> {
      use id <- context.require_uuid(id)
      use request <- json_body(req, transcripts.decoder())
      use page <- result.try(transcripts.save(ctx, account, id, if_match(req), request))
      ok(transcripts.response_json(page))
      |> result.map(with_etag(_, pages.content_etag(page)))
    }
    ["pages", id, "reprocess"], Post -> {
      use id <- context.require_uuid(id)
      use request <- json_body(req, uploads.reprocess_decoder())
      uploads.reprocess(ctx, account, id, if_match(req), request) |> result.try(respond(202, _))
    }
    ["pages", id, "image-url"], Get -> {
      use id <- context.require_uuid(id)
      image_url(app, req, account, id)
    }
    ["pages", id, "revisions", revision], Delete -> {
      use <- recent(principal)
      use id <- context.require_uuid(id)
      use revision <- context.require_uuid(revision)
      use intent <- result.try(purge.purge_revision(ctx, account, id, revision))
      accepted_lifecycle(#("revision_id", json.string(revision)), intent)
    }

    ["upload-sessions"], Post -> {
      use text <- result.try(body_text(req))
      use request <- context.decode_body(text, uploads.create_decoder())
      use <- error.guard(
        case idempotency_key(req) {
          Some(key) -> string.lowercase(key) == request.operation_id
          None -> True
        },
        error.bad_request("Idempotency-Key must equal operation_id."),
      )
      use #(status, body) <- result.try(uploads.create(ctx, account, request, if_match(req)))
      respond(status, body)
    }
    ["upload-sessions", id], Get -> {
      use id <- context.require_uuid(id)
      uploads.get(ctx, account, id) |> result.try(ok)
    }
    ["upload-sessions", id, "refresh"], Post -> {
      use id <- context.require_uuid(id)
      use text <- result.try(body_text(req))
      let background =
        json.parse(text, decode.at(["transfer"], decode.string)) == Ok("background")
      uploads.refresh(ctx, account, id, background) |> result.try(ok)
    }
    ["upload-sessions", id, "complete"], Post -> {
      use id <- context.require_uuid(id)
      uploads.complete(ctx, account, id) |> result.try(ok)
    }
    ["operations", id], Get -> {
      use id <- context.require_uuid(id)
      uploads.operation_status(ctx, account, id) |> result.try(ok)
    }
    ["operations", id, "cancel"], Post -> {
      use id <- context.require_uuid(id)
      uploads.cancel(ctx, account, id) |> result.try(ok)
    }

    ["search"], Post -> {
      use _ <- result.try(ratelimit.hit(
        ctx.db,
        "search:" <> account,
        "search",
        ctx.config.rate_limits.searches_per_minute,
        60,
      ))
      use request <- json_body(req, search.decoder())
      search.search(ctx, account, request) |> result.try(ok)
    }

    ["exports"], Post -> {
      use request <- json_body(req, exports.decoder())
      exports.create(ctx, account, request) |> result.try(respond(202, _))
    }
    ["exports"], Get -> exports.list(ctx, account) |> result.try(ok)
    ["exports", id], Get -> {
      use id <- context.require_uuid(id)
      exports.get(ctx, account, id) |> result.try(ok)
    }
    ["exports", id, "parts", n, "download-url"], Get -> {
      use id <- context.require_uuid(id)
      use n <- result.try(int.parse(n) |> result.replace_error(error.not_found()))
      exports.download_url(ctx, account, id, n) |> result.try(ok)
    }

    ["account-deletion"], Get -> closure.status(ctx, account) |> result.try(ok)
    ["account-deletion"], Post -> {
      use <- recent(principal)
      use request <- json_body(req, closure.schedule_decoder())
      use #(status, body) <- result.try(closure.schedule(ctx, account, request))
      respond(status, body)
    }
    ["account-deletion"], Delete -> {
      use <- recent(principal)
      closure.cancel(ctx, account, if_match(req)) |> result.try(respond(202, _))
    }
    ["accounts"], Post ->
      Error(error.new(409, "account_exists", "This sign-in already has an account."))

    _, _ -> Error(error.not_found())
  }
}

fn image_url(
  app: App,
  req: wisp.Request,
  account: String,
  page_id: String,
) -> Result(wisp.Response, AppError) {
  let ctx = app.ctx
  use <- error.guard(
    accounts_issue_allowed(ctx, account),
    error.account_closing(),
  )
  use page <- result.try(pages.get(ctx.db, account, page_id))
  let requested =
    wisp.get_query(req) |> list.key_find("revision_id") |> option.from_result
  let revision = case requested {
    Some(r) -> Some(string.lowercase(r))
    None -> page.revision_id
  }
  use <- error.guard(
    revision != None
      && { revision == page.revision_id || revision == page.pending_revision_id },
    error.not_found(),
  )
  use object <- error.found(database.query_one(
    ctx.db,
    "select o.key, o.content_type from page_revisions r
     join objects o on o.id = r.source_object_id
     where r.account_id = $1::uuid and r.id = $2::uuid and o.state = 'stored'",
    [database.text(account), database.nullable_text(revision)],
    {
      use key <- decode.field(0, decode.string)
      use content_type <- decode.field(1, decode.string)
      decode.success(#(key, content_type))
    },
  ))
  let signed =
    storage.presign_get(
      ctx.config.storage,
      object.0,
      ctx.config.download_url_seconds,
      "private, no-store",
    )
  ok(json.object([
    #("url", json.string(signed.url)),
    #("expires_in_seconds", json.int(signed.expires_in_seconds)),
    #("revision_id", context.optional_string(revision)),
    #("content_type", json.string(object.1)),
    #("variant", json.string("original")),
    #(
      "notice",
      json.string(
        "This link is a bearer URL valid until it expires; downloads already started cannot be recalled.",
      ),
    ),
  ]))
}

/// New URL issuance stops as soon as an account enters closing.
fn accounts_issue_allowed(ctx: Context, account: String) -> Bool {
  case
    database.query_one(
      ctx.db,
      "select status in ('active', 'closure_scheduled') from accounts where id = $1::uuid",
      [database.text(account)],
      decode.at([0], decode.bool),
    )
  {
    Ok(Some(True)) -> True
    _ -> False
  }
}

// /internal ------------------------------------------------------------------------

fn internal(
  app: App,
  req: wisp.Request,
  account_id: String,
  segments: List(String),
) -> Result(wisp.Response, AppError) {
  let ctx = app.ctx
  case segments, req.method {
    ["entitlements"], Put -> {
      use text <- result.try(body_text(req))
      use #(status, body) <- result.try(entitlements.apply(ctx, account_id, text))
      respond(status, body)
    }
    ["credit-grants"], Post -> {
      use command <- json_body(req, entitlements.credit_decoder())
      entitlements.credit(ctx, account_id, command) |> result.try(ok)
    }
    ["entitlement-status"], Get -> entitlements.status(ctx, account_id) |> result.try(ok)
    ["lifecycle-status"], Get -> {
      use row <- error.found(database.query_one(
        ctx.db,
        "select status, lifecycle_revision, rfc3339(closure_effective_at)
         from accounts where id = $1::uuid",
        [database.text(account_id)],
        {
          use status <- decode.field(0, decode.string)
          use revision <- decode.field(1, decode.int)
          use effective <- decode.field(2, decode.optional(decode.string))
          decode.success(#(status, revision, effective))
        },
      ))
      ok(json.object([
        #("account_id", json.string(account_id)),
        #("status", json.string(row.0)),
        #("lifecycle_revision", json.int(row.1)),
        #("effective_at", context.optional_string(row.2)),
      ]))
    }
    _, _ -> Error(error.not_found())
  }
}

/// `GET /v1/client-configuration`: lets a native app start from only the
/// server URL. `oidc` is null until a native client is configured.
fn client_configuration(app: App, req: wisp.Request) -> Result(wisp.Response, AppError) {
  use <- error.guard(req.method == http.Get, error.new(405, "method_not_allowed", "Use GET."))
  let web = app.web
  let oidc = case web.native {
    Some(native) ->
      json.object([
        #("issuer", json.string(web.oidc.issuer)),
        #("authorization_endpoint", json.string(web.oidc.authorization_endpoint)),
        #("token_endpoint", json.string(web.oidc.token_endpoint)),
        #("client_id", json.string(native.client_id)),
        #("redirect_uri", json.string(native.redirect_uri)),
        #("scopes", json.array(["openid", "profile", "offline_access"], json.string)),
      ])
    None -> json.null()
  }
  let config = app.ctx.config
  Ok(
    wisp.json_response(
      json.to_string(json.object([
        #("oidc", oidc),
        #("uploads", json.object([
          #("integrity", json.string(case config.storage.upload_integrity {
            storage.ContentMd5 -> "md5"
            storage.Sha256Header -> "sha256"
          })),
          #("max_bytes", json.int(config.image_limits.max_bytes)),
          #("content_types", json.array(["image/jpeg", "image/png"], json.string)),
        ])),
      ])),
      200,
    )
    |> wisp.set_header("cache-control", "public, max-age=300"),
  )
}
