//// Integration tests for permanent purge, trash expiry, exports, account
//// closure, spend controls, rate limits, maintenance jobs and the
//// lock-order harness. Numbers refer to DESIGN.md section 17 scenarios.

import gleam/bit_array
import gleam/bytes_tree
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import libarrie/api/router
import libarrie/database
import libarrie/domain/context
import libarrie/domain/maintenance
import libarrie/integrations/lifecycle_subscriber
import libarrie/integrations/storage
import libarrie/jobs
import mist
import support.{call, str}

fn ship(app: router.App) -> Nil {
  support.maintain(app, "journal")
}

fn processed_page(
  app: router.App,
  token: String,
  notebook: String,
  number: Int,
  text: String,
) -> String {
  let #(_, page_id) = support.upload_page(app, token, notebook, number, Some(text), "immediate")
  support.drain(app)
  page_id
}

fn object_key_for(app: router.App, page_id: String) -> String {
  let assert Ok(option.Some(key)) =
    sql_text(app, "select o.key from pages p join page_revisions r on r.id = p.active_revision_id
      join objects o on o.id = r.source_object_id where p.id = $1::uuid", [page_id])
  key
}

fn sql_text(app: router.App, statement: String, params: List(String)) {
  database.query_one(
    app.ctx.db,
    statement,
    list.map(params, database.text),
    decode.at([0], decode.string),
  )
}

// 44: permanent purge -------------------------------------------------------------------

pub fn purge_trash_requires_recent_auth_and_erases_test() {
  let app = support.app()
  let subject = "user-" <> support.random_id()
  let token = support.token_for(subject, 0)
  let notebook = support.notebook(app, token, "Purge")
  let page_id = processed_page(app, token, notebook, 1, "sensitive pomegranate")
  let key = object_key_for(app, page_id)
  let assert 202 = call(app, http.Delete, "/v1/pages/" <> page_id, token, None, []).status
  ship(app)
  let body = json.object([#("page_ids", json.array([page_id], json.string))])
  // A sign-in older than five minutes must re-authenticate.
  let stale = support.token_for(subject, 600)
  let reauth = call(app, http.Post, "/v1/trash/purge", stale, Some(body), [])
  let assert 401 = reauth.status
  let assert "reauthentication_required" = str(reauth, ["error", "code"])
  let purged = call(app, http.Post, "/v1/trash/purge", token, Some(body), [])
  let assert 202 = purged.status
  let assert "recovery_pending" = str(purged, ["status"])
  // Hidden from trash immediately; erased only after journal acknowledgement.
  let trash = call(app, http.Get, "/v1/trash", token, None, [])
  let assert [] = support.get(trash, ["pages"], decode.list(decode.dynamic))
  let assert 1 = support.sql_int(app, "select count(*)::int from pages where id = $1::uuid", [page_id])
  ship(app)
  let assert 0 = support.sql_int(app, "select count(*)::int from pages where id = $1::uuid", [page_id])
  let assert 0 =
    support.sql_int(app, "select count(*)::int from transcript_revisions t join page_revisions r on r.id = t.revision_id where r.page_id = $1::uuid", [page_id])
  // Primary storage removal happens through the deletion queue.
  let assert Ok(_) = storage.head(app.ctx.config.storage, key)
  support.maintain(app, "object_deletions")
  let assert Error(storage.NotFound) = storage.head(app.ctx.config.storage, key)
  let assert 1 =
    support.sql_int(app, "select count(*)::int from deletion_tombstones where scope_id = $1::uuid", [page_id])
}

pub fn purge_non_active_revision_test() {
  let app = support.app()
  let token = support.user(app)
  let account = support.account_id(app, token)
  let notebook = support.notebook(app, token, "Revisions")
  let page_id = processed_page(app, token, notebook, 1, "first draft quokka")
  let page = call(app, http.Get, "/v1/pages/" <> page_id, token, None, [])
  let old_revision = str(page, ["page", "revision_id"])
  let content = support.get(page, ["page", "content_version"], decode.int)
  let bytes = support.png(Some("second draft wombat"))
  let created =
    support.create_upload(app, token, support.uuid(), [#("page_id", json.string(page_id))], bytes, "immediate", [
      #("if-match", "\"c" <> int.to_string(content) <> "\""),
    ])
  support.put_staging(app, account, str(created, ["upload_session_id"]), bytes)
  let assert 200 = support.complete(app, token, str(created, ["upload_session_id"])).status
  support.drain(app)
  let page = call(app, http.Get, "/v1/pages/" <> page_id, token, None, [])
  let active = str(page, ["page", "revision_id"])
  // The active source cannot be purged directly.
  let assert 409 =
    call(app, http.Delete, "/v1/pages/" <> page_id <> "/revisions/" <> active, token, None, []).status
  let assert 202 =
    call(app, http.Delete, "/v1/pages/" <> page_id <> "/revisions/" <> old_revision, token, None, []).status
  ship(app)
  let assert 0 =
    support.sql_int(app, "select count(*)::int from page_revisions where id = $1::uuid", [old_revision])
  let assert 200 = call(app, http.Get, "/v1/pages/" <> page_id, token, None, []).status
  let found =
    call(app, http.Post, "/v1/search", token, Some(json.object([#("query", json.string("wombat"))])), [])
  let assert [_] = support.get(found, ["results"], decode.list(decode.dynamic))
}

pub fn trash_expiry_purges_after_retention_test() {
  let app = support.app()
  let token = support.user(app)
  let notebook = support.notebook(app, token, "Expiring")
  let page_id = processed_page(app, token, notebook, 1, "old receipt")
  let assert 202 = call(app, http.Delete, "/v1/pages/" <> page_id, token, None, []).status
  ship(app)
  support.sql(app, "update pages set deleted_at = now() - interval '31 days' where id = $1::uuid", [page_id])
  support.maintain(app, "trash_expiry")
  ship(app)
  let assert 0 = support.sql_int(app, "select count(*)::int from pages where id = $1::uuid", [page_id])
}

// 32/47/58: exports ----------------------------------------------------------------------

fn small_parts(config: context.Config) -> context.Config {
  context.Config(..config, exports: context.ExportSettings(..config.exports, part_bytes: 1000))
}

fn contains(haystack: BitArray, needle: BitArray) -> Bool {
  let n = bit_array.byte_size(needle)
  let h = bit_array.byte_size(haystack)
  do_contains(haystack, needle, 0, h - n)
}

fn do_contains(haystack: BitArray, needle: BitArray, i: Int, last: Int) -> Bool {
  case i > last {
    True -> False
    False ->
      case bit_array.slice(haystack, i, bit_array.byte_size(needle)) == Ok(needle) {
        True -> True
        False -> do_contains(haystack, needle, i + 1, last)
      }
  }
}

fn download(url: String) -> BitArray {
  let assert Ok(req) = request.to(url)
  let assert Ok(resp) = httpc.dispatch_bits(httpc.configure(), request.set_body(req, <<>>))
  let assert 200 = resp.status
  resp.body
}

pub fn export_snapshot_round_trip_test() {
  let app = support.app_with(small_parts)
  let token = support.user(app)
  let notebook = support.notebook(app, token, "Field Notes / 2026")
  let a = processed_page(app, token, notebook, 1, "alpha original transcript")
  let _b = processed_page(app, token, notebook, 2, "beta transcript")
  let trashed = processed_page(app, token, notebook, 3, "gamma in trash")
  let assert 202 = call(app, http.Delete, "/v1/pages/" <> trashed, token, None, []).status
  let created = call(app, http.Post, "/v1/exports", token, Some(json.object([])), [])
  let assert 202 = created.status
  let export_id = str(created, ["export", "id"])
  let assert 2 = support.get(created, ["export", "item_count"], decode.int)
  let assert 2 = support.get(created, ["export", "part_count"], decode.int)
  // A correction after the snapshot does not change the export.
  let page = call(app, http.Get, "/v1/pages/" <> a, token, None, [])
  let assert 200 =
    call(app, http.Put, "/v1/pages/" <> a <> "/transcript", token, Some(json.object([
      #("source_revision_id", json.string(str(page, ["page", "revision_id"]))),
      #("text", json.string("alpha corrected later")),
    ])), [#("if-match", "\"c" <> int.to_string(support.get(page, ["page", "content_version"], decode.int)) <> "\"")]).status
  // Not downloadable before whole-export completion.
  let assert 409 =
    call(app, http.Get, "/v1/exports/" <> export_id <> "/parts/1/download-url", token, None, []).status
  support.drain(app)
  let status = call(app, http.Get, "/v1/exports/" <> export_id, token, None, [])
  let assert "completed" = str(status, ["export", "state"])
  let assert 7 =
    support.sql_int(app, "select extract(day from expires_at - completed_at)::int from exports where id = $1::uuid", [export_id])
  // Source pins are released after verification; archives remain.
  let assert 0 =
    support.sql_int(app, "select count(*)::int from artifact_pins where owner_id = $1::uuid", [export_id])
  let checksums = support.get(status, ["parts"], decode.list(decode.at(["checksum_sha256"], decode.string)))
  let first = call(app, http.Get, "/v1/exports/" <> export_id <> "/parts/1/download-url", token, None, [])
  let bytes = download(str(first, ["url"]))
  let assert [checksum, ..] = checksums
  let assert True =
    checksum == { crypto.hash(crypto.Sha256, bytes) |> bit_array.base16_encode |> string.lowercase }
  // Self-describing: every part carries the full index; transcripts only in
  // the part holding their image; frozen text is the snapshot's.
  let assert True = contains(bytes, <<"manifest.json":utf8>>)
  let assert True = contains(bytes, <<"\"part_count\":2":utf8>>)
  let assert True = contains(bytes, <<"alpha original transcript":utf8>>)
  let assert False = contains(bytes, <<"alpha corrected later":utf8>>)
  let assert False = contains(bytes, <<"beta transcript":utf8>>)
  let assert True = contains(bytes, <<"notebooks/field-notes-2026-":utf8>>)
  let assert False = contains(bytes, <<"gamma in trash":utf8>>)
  // Reissuing URLs never changes retention.
  let before = support.sql_int(app, "select extract(epoch from expires_at)::int from exports where id = $1::uuid", [export_id])
  let _ = call(app, http.Get, "/v1/exports/" <> export_id <> "/parts/2/download-url", token, None, [])
  let assert True =
    before == support.sql_int(app, "select extract(epoch from expires_at)::int from exports where id = $1::uuid", [export_id])
  // Expiry removes the archives.
  support.sql(app, "update exports set expires_at = now() - interval '1 second' where id = $1::uuid", [export_id])
  support.maintain(app, "exports_expiry")
  let assert "expired" = str(call(app, http.Get, "/v1/exports/" <> export_id, token, None, []), ["export", "state"])
  support.maintain(app, "object_deletions")
  let assert 0 =
    support.sql_int(app, "select count(*)::int from pending_object_deletions where key like $1", ["%" <> export_id <> "%"])
}

pub fn export_with_trash_and_invalidation_by_purge_test() {
  let app = support.app()
  let token = support.user(app)
  let notebook = support.notebook(app, token, "Invalidate")
  let page_id = processed_page(app, token, notebook, 1, "to be purged")
  let assert 202 = call(app, http.Delete, "/v1/pages/" <> page_id, token, None, []).status
  ship(app)
  let created =
    call(app, http.Post, "/v1/exports", token, Some(json.object([#("include_trash", json.bool(True))])), [])
  let export_id = str(created, ["export", "id"])
  let assert 1 = support.get(created, ["export", "item_count"], decode.int)
  let assert 202 =
    call(app, http.Post, "/v1/trash/purge", token, Some(json.object([#("all", json.bool(True))])), []).status
  let status = call(app, http.Get, "/v1/exports/" <> export_id, token, None, [])
  let assert "invalidated" = str(status, ["export", "state"])
  support.drain(app)
  let assert "invalidated" = str(call(app, http.Get, "/v1/exports/" <> export_id, token, None, []), ["export", "state"])
}

pub fn missing_artifact_fails_export_explicitly_test() {
  let app = support.app()
  let token = support.user(app)
  let notebook = support.notebook(app, token, "Missing")
  let page_id = processed_page(app, token, notebook, 1, "vanishing ink")
  let key = object_key_for(app, page_id)
  let created = call(app, http.Post, "/v1/exports", token, Some(json.object([])), [])
  let export_id = str(created, ["export", "id"])
  let assert Ok(Nil) = storage.delete(app.ctx.config.storage, key)
  support.drain(app)
  let status = call(app, http.Get, "/v1/exports/" <> export_id, token, None, [])
  let assert "failed" = str(status, ["export", "state"])
  let assert "missing_artifact" = str(status, ["export", "error_code"])
}

// 45/59/66/67/68/53: account closure ---------------------------------------------------

pub fn account_closure_lifecycle_test() {
  let app = support.app()
  let subject = "user-" <> support.random_id()
  let token = support.token_for(subject, 0)
  let account = support.account_id(app, token)
  let notebook = support.notebook(app, token, "Closing")
  let _ = processed_page(app, token, notebook, 1, "last words")
  let stale = support.token_for(subject, 900)
  let assert 401 = call(app, http.Post, "/v1/account-deletion", stale, Some(json.object([])), []).status
  let scheduled = call(app, http.Post, "/v1/account-deletion", token, Some(json.object([])), [])
  let assert 202 = scheduled.status
  let assert "closure_scheduled" = str(scheduled, ["status"])
  let revision = support.get(scheduled, ["lifecycle_revision"], decode.int)
  // Grace: reads, search and exports continue; additions are blocked.
  let assert 200 = call(app, http.Get, "/v1/notebooks", token, None, []).status
  let assert 200 =
    call(app, http.Post, "/v1/search", token, Some(json.object([#("query", json.string("last words"))])), []).status
  let blocked =
    call(app, http.Post, "/v1/notebooks", token, Some(json.object([#("name", json.string("new"))])), [])
  let assert 409 = blocked.status
  // Cancellation with a stale revision fails; the correct one succeeds but
  // restrictions remain until the journal confirms it.
  let assert 412 =
    call(app, http.Delete, "/v1/account-deletion", token, None, [#("if-match", int.to_string(revision - 1))]).status
  let cancelled =
    call(app, http.Delete, "/v1/account-deletion", token, None, [#("if-match", int.to_string(revision))])
  let assert 202 = cancelled.status
  let assert "cancellation_recorded_awaiting_confirmation" = str(cancelled, ["milestone"])
  let pending =
    call(app, http.Post, "/v1/notebooks", token, Some(json.object([#("name", json.string("new"))])), [])
  let assert 409 = pending.status
  ship(app)
  // The old deadline job is now stale and must not close the account.
  support.sql(app, "update jobs set run_after = now() where stage = 'account_closure_deadline' and payload->>'account_id' = $1", [account])
  support.drain(app)
  let assert "active" = str(call(app, http.Get, "/v1/account-deletion", token, None, []), ["status"])
  let assert 409 =
    call(app, http.Post, "/v1/notebooks", token, Some(json.object([#("name", json.string("second"))])), []).status
  // Schedule again and let the deadline pass.
  let again = call(app, http.Post, "/v1/account-deletion", token, Some(json.object([])), [])
  let assert 202 = again.status
  support.sql(app, "update accounts set closure_effective_at = now() - interval '1 second' where id = $1::uuid", [account])
  support.sql(app, "update jobs set run_after = now() where stage = 'account_closure_deadline' and payload->>'account_id' = $1 and state = 'pending'", [account])
  support.drain(app)
  // Closing: access ends; a status-only session can read deletion status.
  let assert 409 = call(app, http.Get, "/v1/notebooks", token, None, []).status
  let closing = call(app, http.Get, "/v1/account-deletion", token, None, [])
  let assert "closing" = str(closing, ["status"])
  let assert 409 =
    call(app, http.Delete, "/v1/account-deletion", token, None, [#("if-match", int.to_string(support.get(closing, ["lifecycle_revision"], decode.int)))]).status
  // Purge waits for the closing command to be durable.
  ship(app)
  support.sql(app, "update jobs set run_after = now() where stage = 'account_purge' and payload->>'account_id' = $1 and state in ('pending', 'retryable')", [account])
  support.drain(app)
  let assert 0 = support.sql_int(app, "select count(*)::int from notebooks where account_id = $1::uuid", [account])
  let assert 0 =
    support.sql_int(app, "select count(*)::int from identities i join accounts a on a.owner_user_id = i.user_id where a.id = $1::uuid", [account])
  let assert True =
    support.sql_int(app, "select count(*)::int from identity_usage_ledger where lifetime_units_consumed = 1 and account_status = 'closed'", []) >= 1
  // The same sign-in now sees only that the account is closed and purged.
  let status = call(app, http.Get, "/v1/account-deletion", token, None, [])
  let assert "closed" = str(status, ["status"])
  let assert "completed" = str(status, ["purge_status"])
  let assert 403 = call(app, http.Get, "/v1/notebooks", token, None, []).status
  // Explicitly creating a new account inherits prior lifetime usage.
  let assert 201 = call(app, http.Post, "/v1/accounts", token, None, []).status
  let usage = call(app, http.Get, "/v1/usage", token, None, [])
  let assert 1 = support.get(usage, ["lifetime_allowance", "used"], decode.int)
}

pub fn closure_extends_for_exports_within_cap_test() {
  let app =
    support.app_with(fn(config) { context.Config(..config, closure_grace_seconds: 3600) })
  let token = support.user(app)
  let account = support.account_id(app, token)
  let assert 202 = call(app, http.Post, "/v1/account-deletion", token, Some(json.object([])), []).status
  let before = support.sql_int(app, "select lifecycle_revision::int from accounts where id = $1::uuid", [account])
  let export = call(app, http.Post, "/v1/exports", token, Some(json.object([])), [])
  let assert 202 = export.status
  // Export execution (24h) plus the 72h window outruns a one-hour grace.
  let after = support.sql_int(app, "select lifecycle_revision::int from accounts where id = $1::uuid", [account])
  let assert True = after == before + 1
  let assert True =
    support.sql_int(app, "select (closure_effective_at > now() + interval '95 hours')::int from accounts where id = $1::uuid", [account]) == 1
  // An export that cannot finish inside the 30-day cap is refused.
  support.sql(app, "update accounts set closure_cap_at = now() + interval '2 hours' where id = $1::uuid", [account])
  support.sql(app, "update exports set state = 'completed', expires_at = now() + interval '7 days' where account_id = $1::uuid", [account])
  let refused = call(app, http.Post, "/v1/exports", token, Some(json.object([])), [])
  let assert 409 = refused.status
  let assert "export_exceeds_closure_window" = str(refused, ["error", "code"])
}

pub fn closure_requires_acknowledging_coverage_end_test() {
  let app = support.app()
  let token = support.user(app)
  let account = support.account_id(app, token)
  let coverage =
    json.object([
      #("coverage_id", json.string(support.uuid())),
      #("kind", json.string("base")),
      #("starts_at", json.string("2020-01-01T00:00:00Z")),
      #("ends_at", json.string("2099-01-01T00:00:00Z")),
      #("authorized_units", json.int(100)),
    ])
  let assert 200 =
    support.internal(app, http.Put, "/internal/v1/accounts/" <> account <> "/entitlements",
      support.entitlement(1, 100, 5, 100, "calendar_months_from_anchor", [coverage], [])).status
  support.sql(app, "update processing_coverage set admission_end_at = now() + interval '1 day', ends_at = now() + interval '1 day' where account_id = $1::uuid", [account])
  let refused = call(app, http.Post, "/v1/account-deletion", token, Some(json.object([])), [])
  let assert 409 = refused.status
  let assert "acknowledgement_required" = str(refused, ["error", "code"])
  let assert 202 =
    call(app, http.Post, "/v1/account-deletion", token,
      Some(json.object([#("acknowledge_coverage_end", json.bool(True))])), []).status
}

pub fn lifecycle_subscriber_delivery_test() {
  let app = support.app_with(fn(config) { context.Config(..config, lifecycle_subscriber: True) })
  let token = support.user(app)
  let account = support.account_id(app, token)
  let received = process.new_subject()
  let port = 18_000 + int.random(1000)
  let assert Ok(_) =
    mist.new(fn(req) {
      let assert Ok(req) = mist.read_body(req, 1_000_000)
      process.send(received, #(req.path, request.get_header(req, "authorization"), req.body))
      response.new(200)
      |> response.set_body(mist.Bytes(bytes_tree.from_string("{\"applied\":true}")))
    })
    |> mist.port(port)
    |> mist.start
  let assert 202 = call(app, http.Post, "/v1/account-deletion", token, Some(json.object([])), []).status
  let services =
    maintenance.Services(
      ..support.services(),
      subscriber: Some(lifecycle_subscriber.Client("http://localhost:" <> int.to_string(port) <> "/hooks", "subscriber-token")),
    )
  let assert Ok(_) = maintenance.run(app.ctx, services, "lifecycle_subscriber")
  let assert Ok(#(path, auth, body)) = process.receive(received, 2000)
  let assert True = path == "/hooks/accounts/" <> account <> "/lifecycle"
  let assert Ok("Bearer subscriber-token") = auth
  let assert Ok(text) = bit_array.to_string(body)
  let assert Ok(#("closure_scheduled", [_])) =
    json.parse(text, {
      use status <- decode.field("status", decode.string)
      use intents <- decode.field("closure_intents", decode.list(decode.dynamic))
      decode.success(#(status, intents))
    })
  let status = call(app, http.Get, "/v1/account-deletion", token, None, [])
  let assert "{\"applied\":true}" = str(status, ["delivery", "subscriber"])
}

// 30: spend controls ---------------------------------------------------------------------

pub fn spend_budget_pauses_then_fails_into_hold_test() {
  let app =
    support.app_with(fn(config) {
      context.Config(..config, spend: context.SpendSettings(..config.spend, account_daily_micros: 0))
    })
  let token = support.user(app)
  let account = support.account_id(app, token)
  let notebook = support.notebook(app, token, "Budget")
  let #(_, page_id) = support.upload_page(app, token, notebook, 1, Some("expensive words"), "immediate")
  support.drain(app)
  let page = call(app, http.Get, "/v1/pages/" <> page_id, token, None, [])
  let assert "operational_limit_reached" = str(page, ["latest_operation", "error_code"])
  // Postponed without spending an attempt; the reservation stays attached.
  let assert 0 =
    support.sql_int(app, "select attempts from jobs where account_id = $1::uuid and stage = 'recognize'", [account])
  let usage = call(app, http.Get, "/v1/usage", token, None, [])
  let assert 1 = support.get(usage, ["lifetime_allowance", "reserved"], decode.int)
  // Lexical search still works when query embedding is budget-blocked.
  let search =
    call(app, http.Post, "/v1/search", token, Some(json.object([#("query", json.string("anything"))])), [])
  let assert "lexical_only" = str(search, ["search_mode"])
  // After the bounded pause the operation fails as a system fault and the
  // allocation moves into a recovery hold.
  support.sql(app, "update operations set paused_since = now() - interval '37 hours' where account_id = $1::uuid", [account])
  support.sql(app, "update jobs set run_after = now() where account_id = $1::uuid", [account])
  support.drain(app)
  let page = call(app, http.Get, "/v1/pages/" <> page_id, token, None, [])
  let assert "failed" = str(page, ["latest_operation", "status"])
  let assert "system" = str(page, ["latest_operation", "failure_fault"])
  let usage = call(app, http.Get, "/v1/usage", token, None, [])
  let assert [_] = support.get(usage, ["recovery_holds"], decode.list(decode.dynamic))
}

pub fn provider_permits_bound_concurrency_test() {
  let app =
    support.app_with(fn(config) {
      context.Config(..config, spend: context.SpendSettings(..config.spend, provider_concurrency: 0))
    })
  let token = support.user(app)
  let account = support.account_id(app, token)
  let notebook = support.notebook(app, token, "Permits")
  let _ = support.upload_page(app, token, notebook, 1, Some("waiting for a permit"), "immediate")
  support.drain(app)
  let assert "provider_permit_wait" =
    case sql_text(app, "select last_error from jobs where account_id = $1::uuid and stage = 'recognize'", [account]) {
      Ok(Some(e)) -> e
      _ -> ""
    }
  let assert 0 =
    support.sql_int(app, "select attempts from jobs where account_id = $1::uuid and stage = 'recognize'", [account])
  // Restore the permit table for other tests.
  let normal = support.app()
  support.sql(normal, "delete from provider_permits", [])
}

// Rate limits -------------------------------------------------------------------------------

pub fn rate_limits_return_429_with_retry_after_test() {
  let app =
    support.app_with(fn(config) {
      context.Config(..config, rate_limits: context.RateLimits(..config.rate_limits, searches_per_minute: 2))
    })
  let token = support.user(app)
  let search = fn() {
    call(app, http.Post, "/v1/search", token, Some(json.object([#("query", json.string("x"))])), [])
  }
  let codes = list.map([1, 2, 3], fn(_) { search() })
  let assert [200, 200, 429] = list.map(codes, fn(r) { r.status })
  let assert [_, _, limited] = codes
  let assert "rate_limited" = str(limited, ["error", "code"])
  // Three rescans per page per day.
  let notebook = support.notebook(app, token, "Rescans")
  let page_id = processed_page(app, token, notebook, 1, "rescan me")
  let rescan = fn() {
    let page = call(app, http.Get, "/v1/pages/" <> page_id, token, None, [])
    let reply =
      call(app, http.Post, "/v1/pages/" <> page_id <> "/reprocess", token, Some(json.object([
        #("operation_id", json.string(support.uuid())),
        #("source_revision_id", json.string(str(page, ["page", "revision_id"]))),
      ])), [#("if-match", "\"c" <> int.to_string(support.get(page, ["page", "content_version"], decode.int)) <> "\"")])
    support.drain(app)
    reply.status
  }
  let assert [202, 202, 202, 429] = list.map([1, 2, 3, 4], fn(_) { rescan() })
}

// Search highlights ---------------------------------------------------------------------------

pub fn search_returns_snippet_highlights_test() {
  let app = support.app()
  let token = support.user(app)
  let notebook = support.notebook(app, token, "Highlights")
  let _ = processed_page(app, token, notebook, 1, "Meeting with Grace Hopper about compilers")
  let found =
    call(app, http.Post, "/v1/search", token, Some(json.object([#("query", json.string("hopper compilers"))])), [])
  let assert [snippet] = support.get(found, ["results"], decode.list(decode.at(["snippet"], decode.string)))
  let assert [ranges] =
    support.get(found, ["results"], decode.list(decode.at(["highlights"], decode.list({
      use start <- decode.field("start", decode.int)
      use end <- decode.field("end", decode.int)
      decode.success(#(start, end))
    }))))
  let marked = list.map(ranges, fn(r) { string.lowercase(string.slice(snippet, r.0, r.1 - r.0)) })
  let assert ["hopper", "compilers"] = marked
}

// Maintenance jobs ------------------------------------------------------------------------------

pub fn periodic_jobs_deduplicate_and_archive_test() {
  let app = support.app()
  let bucket = "test-" <> support.random_id()
  let assert Ok(Some(_)) = jobs.enqueue_periodic(app.ctx.db, "maint:test_noop", bucket, None)
  let assert Ok(None) = jobs.enqueue_periodic(app.ctx.db, "maint:test_noop", bucket, None)
  support.sql(app, "update jobs set state = 'succeeded', updated_at = now() - interval '2 hours' where stage = 'maint:test_noop'", [])
  // Even after completion the same bucket never runs twice.
  let assert Ok(None) = jobs.enqueue_periodic(app.ctx.db, "maint:test_noop", bucket, None)
  support.maintain(app, "archive")
  let assert 0 = support.sql_int(app, "select count(*)::int from jobs where stage = 'maint:test_noop'", [])
  let assert 1 = support.sql_int(app, "select count(*)::int from jobs_archive where stage = 'maint:test_noop'", [])
  let assert Ok(None) = jobs.enqueue_periodic(app.ctx.db, "maint:test_noop", bucket, None)
}

// 49: lock-order harness ------------------------------------------------------------------------

pub fn concurrent_paths_do_not_deadlock_test() {
  let app = support.app()
  let token = support.user(app)
  let account = support.account_id(app, token)
  let notebook = support.notebook(app, token, "Contention")
  let pages =
    list.map([1, 2, 3, 4], fn(n) { processed_page(app, token, notebook, n, "contended " <> int.to_string(n)) })
  let deadlocks = fn() {
    support.sql_int(app, "select deadlocks::int from pg_stat_database where datname = current_database()", [])
  }
  let before = deadlocks()
  let done = process.new_subject()
  let paths = [
    fn() {
      call(app, http.Post, "/v1/notebooks/" <> notebook <> "/renumber", token, Some(json.object([
        #("shift", json.object([#("from", json.int(1)), #("to", json.int(100)), #("by", json.int(10))])),
      ])), []).status
    },
    fn() {
      let bytes = support.png(Some("racing upload"))
      support.create_upload(
        app,
        token,
        support.uuid(),
        [
          #("notebook_id", json.string(notebook)),
          #("page_number", json.int(200 + int.random(10_000))),
        ],
        bytes,
        "immediate",
        [],
      ).status
    },
    fn() {
      let assert [p, ..] = pages
      call(app, http.Delete, "/v1/pages/" <> p, token, None, []).status
    },
    fn() {
      let assert [_, p, ..] = pages
      let page = call(app, http.Get, "/v1/pages/" <> p, token, None, [])
      call(app, http.Put, "/v1/pages/" <> p <> "/transcript", token, Some(json.object([
        #("source_revision_id", json.string(str(page, ["page", "revision_id"]))),
        #("text", json.string("edited under contention")),
      ])), [#("if-match", "\"c" <> int.to_string(support.get(page, ["page", "content_version"], decode.int)) <> "\"")]).status
    },
    fn() {
      support.drain(app)
      200
    },
    fn() { call(app, http.Post, "/v1/exports", token, Some(json.object([])), []).status },
    fn() {
      support.maintain(app, "journal")
      support.maintain(app, "uploads")
      support.maintain(app, "slots")
      200
    },
    fn() {
      support.internal(app, http.Put, "/internal/v1/accounts/" <> account <> "/entitlements",
        support.entitlement(1, 100, 5, 100, "lifetime", [], [])).status
    },
  ]
  list.each(list.flatten([paths, paths, paths]), fn(path) {
    process.spawn(fn() { process.send(done, path()) })
  })
  let statuses =
    list.map(list.flatten([paths, paths, paths]), fn(_) {
      let assert Ok(status) = process.receive(done, 30_000)
      status
    })
  // No unexpected server errors and no deadlocks detected by Postgres.
  let assert False = list.any(statuses, fn(s) { s >= 500 && s != 503 })
  let assert True = deadlocks() == before
}
