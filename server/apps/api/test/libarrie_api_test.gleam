//// Integration tests for the core API, quotas, queue fencing and search.
//// Numbers in test names refer to DESIGN.md section 17 scenarios.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import libarrie/api/router
import libarrie/domain/processing
import libarrie/integrations/providers
import libarrie/jobs
import support.{call, str}
import wisp/simulate

pub fn main() -> Nil {
  gleeunit.main()
}

fn status_of(reply: support.Reply) -> Int {
  reply.status
}

fn set_limits(app: router.App, token: String, revision: Int, stored: Int, notebooks: Int, processing: Int) -> String {
  let account = support.account_id(app, token)
  let reply =
    support.internal(
      app,
      http.Put,
      "/internal/v1/accounts/" <> account <> "/entitlements",
      support.entitlement(revision, stored, notebooks, processing, "lifetime", [], []),
    )
  let assert 200 = reply.status
  account
}

// Vertical slice --------------------------------------------------------------------

pub fn upload_process_and_search_test() {
  let app = support.app()
  let token = support.user(app)
  let notebook = support.notebook(app, token, "Lab notes")
  let #(done, page_id) =
    support.upload_page(
      app,
      token,
      notebook,
      7,
      Some("Calibrated the spectrometer with sample ZX-81 before lunch."),
      "immediate",
    )
  let assert 200 = done.status
  let assert "queued" = str(done, ["operation", "status"])
  support.drain(app)
  let page = call(app, http.Get, "/v1/pages/" <> page_id, token, None, [])
  let assert "ready" = str(page, ["page", "processing_status"])
  let assert "Calibrated the spectrometer with sample ZX-81 before lunch." =
    str(page, ["transcript", "text"])
  let found =
    call(
      app,
      http.Post,
      "/v1/search",
      token,
      Some(json.object([#("query", json.string("ZX-81"))])),
      [],
    )
  let assert [hit, ..] = support.get(found, ["results"], decode.list(decode.at(["page_id"], decode.string)))
  let assert True = hit == page_id
  let assert 7 = support.get(found, ["results"], decode.list(decode.at(["page_number"], decode.int))) |> first
  // Charged exactly once.
  let usage = call(app, http.Get, "/v1/usage", token, None, [])
  let assert 1 = support.get(usage, ["lifetime_allowance", "used"], decode.int)
  let assert 0 = support.get(usage, ["lifetime_allowance", "reserved"], decode.int)
}

fn first(items: List(a)) -> a {
  let assert [x, ..] = items
  x
}

// 14: tenant isolation ------------------------------------------------------------

pub fn cross_account_access_is_not_found_test() {
  let app = support.app()
  let alice = support.user(app)
  let bob = support.user(app)
  let notebook = support.notebook(app, alice, "Private")
  let #(_, page_id) =
    support.upload_page(app, alice, notebook, 1, Some("secret plans"), "immediate")
  support.drain(app)
  let assert 404 = status_of(call(app, http.Get, "/v1/pages/" <> page_id, bob, None, []))
  let assert 404 =
    status_of(call(app, http.Get, "/v1/notebooks/" <> notebook <> "/pages", bob, None, []))
  let results =
    call(app, http.Post, "/v1/search", bob, Some(json.object([#("query", json.string("secret plans"))])), [])
  let assert [] = support.get(results, ["results"], decode.list(decode.dynamic))
}

// 1: two replicas race for the last page slot ----------------------------------------

pub fn last_page_slot_race_test() {
  let app = support.app()
  let token = support.user(app)
  let _ = set_limits(app, token, 1, 1, 5, 10)
  let notebook = support.notebook(app, token, "Tight")
  let replies = process.new_subject()
  list.each([1, 2, 3, 4], fn(n) {
    process.spawn(fn() {
      let bytes = support.png(Some("page " <> int.to_string(n)))
      let reply =
        support.create_upload(
          app,
          token,
          support.uuid(),
          [#("notebook_id", json.string(notebook)), #("page_number", json.int(n))],
          bytes,
          "immediate",
          [],
        )
      process.send(replies, reply.status)
    })
  })
  let statuses =
    list.map([1, 2, 3, 4], fn(_) {
      let assert Ok(s) = process.receive(replies, 4000)
      s
    })
  let assert 1 = list.count(statuses, fn(s) { s == 201 })
  let assert 3 = list.count(statuses, fn(s) { s == 409 })
}

// 2/22: operation replay and changed bodies --------------------------------------------

pub fn upload_operation_replay_test() {
  let app = support.app()
  let token = support.user(app)
  let notebook = support.notebook(app, token, "Replay")
  let op = support.uuid()
  let bytes = support.png(Some("hello"))
  let target = [#("notebook_id", json.string(notebook)), #("page_number", json.int(3))]
  let first = support.create_upload(app, token, op, target, bytes, "immediate", [])
  let assert 201 = first.status
  let again = support.create_upload(app, token, op, target, bytes, "immediate", [])
  let assert 200 = again.status
  let assert True = str(first, ["upload_session_id"]) == str(again, ["upload_session_id"])
  let changed =
    support.create_upload(
      app,
      token,
      op,
      [#("notebook_id", json.string(notebook)), #("page_number", json.int(4))],
      bytes,
      "immediate",
      [],
    )
  let assert 409 = changed.status
  let assert "idempotency_conflict" = str(changed, ["error", "code"])
  // Mismatched Idempotency-Key header is a 400.
  let mismatched =
    support.create_upload(app, token, support.uuid(), target, bytes, "immediate", [
      #("idempotency-key", support.uuid()),
    ])
  let assert 400 = mismatched.status
  // Only one reservation exists.
  let usage = call(app, http.Get, "/v1/usage", token, None, [])
  let assert 1 = support.get(usage, ["reserved_page_slots"], decode.int)
  // Operation lookup without a session ID.
  let lookup = call(app, http.Get, "/v1/operations/" <> op, token, None, [])
  let assert "awaiting_upload" = str(lookup, ["status"])
}

// 3: lost confirmation response ----------------------------------------------------------

pub fn completion_is_idempotent_test() {
  let app = support.app()
  let token = support.user(app)
  let account = support.account_id(app, token)
  let notebook = support.notebook(app, token, "Idempotent")
  let bytes = support.png(Some("once"))
  let created =
    support.create_upload(
      app,
      token,
      support.uuid(),
      [#("notebook_id", json.string(notebook)), #("page_number", json.int(1))],
      bytes,
      "immediate",
      [],
    )
  let session = str(created, ["upload_session_id"])
  support.put_staging(app, account, session, bytes)
  let a = support.complete(app, token, session)
  let b = support.complete(app, token, session)
  let assert 200 = a.status
  let assert 200 = b.status
  let assert 1 =
    support.sql_int(app, "select count(*)::int from jobs where account_id = $1::uuid and stage = 'recognize'", [account])
  let assert 1 =
    support.sql_int(app, "select stored_pages from account_usage where account_id = $1::uuid", [account])
}

// 4: staging overwrite after acceptance cannot alter the frozen source ---------------

pub fn staging_overwrite_does_not_change_source_test() {
  let app = support.app()
  let token = support.user(app)
  let account = support.account_id(app, token)
  let notebook = support.notebook(app, token, "Frozen")
  let bytes = support.png(Some("original words"))
  let created =
    support.create_upload(
      app,
      token,
      support.uuid(),
      [#("notebook_id", json.string(notebook)), #("page_number", json.int(1))],
      bytes,
      "immediate",
      [],
    )
  let session = str(created, ["upload_session_id"])
  support.put_staging(app, account, session, bytes)
  let assert 200 = support.complete(app, token, session).status
  support.put_staging(app, account, session, support.png(Some("tampered words")))
  support.drain(app)
  let page = call(app, http.Get, "/v1/pages/" <> str(created, ["operation", "page_id"]), token, None, [])
  let assert "original words" = str(page, ["transcript", "text"])
}

pub fn invalid_bytes_fail_as_unsupported_image_test() {
  let app = support.app()
  let token = support.user(app)
  let account = support.account_id(app, token)
  let notebook = support.notebook(app, token, "Bad bytes")
  let bytes = <<"definitely not an image at all":utf8>>
  let created =
    support.create_upload(
      app,
      token,
      support.uuid(),
      [#("notebook_id", json.string(notebook)), #("page_number", json.int(1))],
      bytes,
      "immediate",
      [],
    )
  let session = str(created, ["upload_session_id"])
  support.put_staging(app, account, session, bytes)
  let reply = support.complete(app, token, session)
  let assert 422 = reply.status
  let assert "unsupported_image" = str(reply, ["error", "code"])
  let usage = call(app, http.Get, "/v1/usage", token, None, [])
  let assert 0 = support.get(usage, ["reserved_page_slots"], decode.int)
  let assert 0 = support.get(usage, ["lifetime_allowance", "reserved"], decode.int)
}

// 6/37/55: lease fencing and slot transfer ----------------------------------------------

pub fn stale_worker_results_are_discarded_test() {
  let app = support.app()
  let token = support.user(app)
  let account = support.account_id(app, token)
  let notebook = support.notebook(app, token, "Fencing")
  let #(_, page_id) =
    support.upload_page(app, token, notebook, 1, Some("fenced text"), "immediate")
  let settings = app.ctx.config.jobs
  let assert Ok([job_a]) = jobs.claim(app.ctx.db, "worker-a", ["recognize"], settings, 1)
  // Worker A's lease expires; worker B reclaims with a new token.
  support.sql(app, "update jobs set lease_expires_at = now() - interval '1 second' where id = $1::uuid", [job_a.id])
  let assert Ok([job_b]) = jobs.claim(app.ctx.db, "worker-b", ["recognize"], settings, 1)
  let assert True = job_b.attempt_token != job_a.attempt_token
  // Reclaim transferred the slot lease without changing occupancy.
  let assert 1 =
    support.sql_int(app, "select occupied from account_job_slots where account_id = $1::uuid", [account])
  // A's late result is rejected atomically; its heartbeat cannot revive it.
  let assert Ok(processing.Discarded) =
    processing.recognize(app.ctx, providers.mock_ocr(), job_a)
  let assert Ok(False) = jobs.heartbeat(app.ctx.db, job_a, settings)
  // B completes normally.
  let assert Ok(processing.Completed(_)) =
    processing.recognize(app.ctx, providers.mock_ocr(), job_b)
  let assert 0 =
    support.sql_int(app, "select occupied from account_job_slots where account_id = $1::uuid", [account])
  support.drain(app)
  let page = call(app, http.Get, "/v1/pages/" <> page_id, token, None, [])
  let assert "ready" = str(page, ["page", "processing_status"])
  let usage = call(app, http.Get, "/v1/usage", token, None, [])
  let assert 1 = support.get(usage, ["lifetime_allowance", "used"], decode.int)
}

pub fn account_slot_limit_bounds_fresh_claims_test() {
  let app = support.app()
  let token = support.user(app)
  let account = support.account_id(app, token)
  let notebook = support.notebook(app, token, "Slots")
  list.each([1, 2, 3], fn(n) {
    let _ = support.upload_page(app, token, notebook, n, Some("slot " <> int.to_string(n)), "immediate")
    Nil
  })
  support.sql(app, "update account_job_slots set slot_limit = 1 where account_id = $1::uuid", [account])
  let settings = app.ctx.config.jobs
  let assert Ok(claimed) = jobs.claim(app.ctx.db, "w", ["recognize"], settings, 3)
  let mine = list.filter(claimed, fn(j) { j.account_id == Some(account) })
  let assert 1 = list.length(mine)
  let assert [job] = mine
  // Expired attempt at full capacity: reclaim transfers without spare slots.
  support.sql(app, "update jobs set lease_expires_at = now() - interval '1 second' where id = $1::uuid", [job.id])
  let assert Ok(reclaimed) = jobs.claim(app.ctx.db, "w2", ["recognize"], settings, 3)
  let assert True = list.any(reclaimed, fn(j) { j.id == job.id })
  let assert 1 =
    support.sql_int(app, "select occupied from account_job_slots where account_id = $1::uuid", [account])
  support.sql(app, "update account_job_slots set slot_limit = 4 where account_id = $1::uuid", [account])
  support.drain(app)
}

// 34: classified recognition outcomes ---------------------------------------------------

pub fn blank_and_unreadable_outcomes_test() {
  let app = support.app()
  let token = support.user(app)
  let notebook = support.notebook(app, token, "Outcomes")
  let #(_, blank) = support.upload_page(app, token, notebook, 1, Some("[[blank]]"), "immediate")
  let #(_, unreadable) =
    support.upload_page(app, token, notebook, 2, Some("[[unreadable]]"), "immediate")
  let #(_, empty) = support.upload_page(app, token, notebook, 3, None, "immediate")
  support.drain(app)
  let assert "ready_empty" =
    str(call(app, http.Get, "/v1/pages/" <> blank, token, None, []), ["page", "processing_status"])
  let un = call(app, http.Get, "/v1/pages/" <> unreadable, token, None, [])
  let assert "needs_user_action" = str(un, ["latest_operation", "status"])
  let assert "unreadable" = str(un, ["latest_operation", "error_code"])
  let assert "no_text_detected" =
    str(call(app, http.Get, "/v1/pages/" <> empty, token, None, []), ["latest_operation", "error_code"])
  // Only the confirmed blank consumed a unit; the others released theirs.
  let usage = call(app, http.Get, "/v1/usage", token, None, [])
  let assert 1 = support.get(usage, ["lifetime_allowance", "used"], decode.int)
  let assert 0 = support.get(usage, ["lifetime_allowance", "reserved"], decode.int)
  let assert 3 = support.get(usage, ["stored_pages"], decode.int)
}

pub fn exhausted_transient_failure_creates_recovery_hold_test() {
  let app = support.app()
  let token = support.user(app)
  let account = support.account_id(app, token)
  let notebook = support.notebook(app, token, "Flaky")
  let #(_, page_id) =
    support.upload_page(app, token, notebook, 1, Some("[[transient]]"), "immediate")
  // Burn every attempt immediately.
  support.sql(app, "update jobs set max_attempts = 1 where account_id = $1::uuid", [account])
  support.drain(app)
  support.sql(app, "update jobs set run_after = now() where account_id = $1::uuid and state = 'retryable'", [account])
  support.drain(app)
  let page = call(app, http.Get, "/v1/pages/" <> page_id, token, None, [])
  let assert "failed" = str(page, ["latest_operation", "status"])
  let assert "system" = str(page, ["latest_operation", "failure_fault"])
  let usage = call(app, http.Get, "/v1/usage", token, None, [])
  // The unit stays held for recovery, not released to unrelated work.
  let assert 1 = support.get(usage, ["lifetime_allowance", "reserved"], decode.int)
  let assert [_] = support.get(usage, ["recovery_holds"], decode.list(decode.dynamic))
}

// 23: corrections ---------------------------------------------------------------------

pub fn correction_versioning_and_processing_conflict_test() {
  let app = support.app()
  let token = support.user(app)
  let notebook = support.notebook(app, token, "Corrections")
  let #(_, page_id) =
    support.upload_page(app, token, notebook, 1, Some("teh quick brown fox"), "immediate")
  let page = call(app, http.Get, "/v1/pages/" <> page_id, token, None, [])
  let revision = str(page, ["page", "revision_id"])
  let content = support.get(page, ["page", "content_version"], decode.int)
  let body =
    json.object([
      #("source_revision_id", json.string(revision)),
      #("text", json.string("the quick brown fox")),
    ])
  // OCR still pending: edits are blocked with the blocking operation named.
  let blocked =
    call(app, http.Put, "/v1/pages/" <> page_id <> "/transcript", token, Some(body), [
      #("if-match", "\"c" <> int.to_string(content) <> "\""),
    ])
  let assert 409 = blocked.status
  let assert "processing_conflict" = str(blocked, ["error", "code"])
  let assert "upload" = str(blocked, ["error", "details", "kind"])
  support.drain(app)
  let missing = call(app, http.Put, "/v1/pages/" <> page_id <> "/transcript", token, Some(body), [])
  let assert 428 = missing.status
  let saved =
    call(app, http.Put, "/v1/pages/" <> page_id <> "/transcript", token, Some(body), [
      #("if-match", "\"c" <> int.to_string(content) <> "\""),
    ])
  let assert 200 = saved.status
  let stale =
    call(app, http.Put, "/v1/pages/" <> page_id <> "/transcript", token, Some(body), [
      #("if-match", "\"c" <> int.to_string(content) <> "\""),
    ])
  let assert 412 = stale.status
  // Saved text is visible immediately; search catches up after indexing.
  let detail = call(app, http.Get, "/v1/pages/" <> page_id, token, None, [])
  let assert "the quick brown fox" = str(detail, ["transcript", "text"])
  let assert True = support.get(detail, ["page", "indexing_pending"], decode.bool)
  support.drain(app)
  let detail = call(app, http.Get, "/v1/pages/" <> page_id, token, None, [])
  let assert False = support.get(detail, ["page", "indexing_pending"], decode.bool)
  // Corrections never consume processing units.
  let usage = call(app, http.Get, "/v1/usage", token, None, [])
  let assert 1 = support.get(usage, ["lifetime_allowance", "used"], decode.int)
}

// 15: failed replacement keeps the previous searchable revision ---------------------

pub fn replacement_switches_source_on_publication_test() {
  let app = support.app()
  let token = support.user(app)
  let account = support.account_id(app, token)
  let notebook = support.notebook(app, token, "Replace")
  let #(_, page_id) =
    support.upload_page(app, token, notebook, 1, Some("first scan aurora"), "immediate")
  support.drain(app)
  let page = call(app, http.Get, "/v1/pages/" <> page_id, token, None, [])
  let content = support.get(page, ["page", "content_version"], decode.int)
  let old_revision = str(page, ["page", "revision_id"])
  // Deferred replacement is rejected before any mutation.
  let bytes = support.png(Some("[[unreadable]]"))
  let deferred =
    support.create_upload(app, token, support.uuid(), [#("page_id", json.string(page_id))], bytes, "deferred", [
      #("if-match", "\"c" <> int.to_string(content) <> "\""),
    ])
  let assert 422 = deferred.status
  let assert "deferred_replacement_unsupported" = str(deferred, ["error", "code"])
  // An unreadable replacement leaves the old source active and searchable.
  let created =
    support.create_upload(app, token, support.uuid(), [#("page_id", json.string(page_id))], bytes, "immediate", [
      #("if-match", "\"c" <> int.to_string(content) <> "\""),
    ])
  let assert 201 = created.status
  let session = str(created, ["upload_session_id"])
  support.put_staging(app, account, session, bytes)
  let assert 200 = support.complete(app, token, session).status
  support.drain(app)
  let page = call(app, http.Get, "/v1/pages/" <> page_id, token, None, [])
  let assert True = str(page, ["page", "revision_id"]) == old_revision
  let found =
    call(app, http.Post, "/v1/search", token, Some(json.object([#("query", json.string("aurora"))])), [])
  let assert [_] = support.get(found, ["results"], decode.list(decode.dynamic))
  // A readable replacement switches the source atomically at publication.
  let good = support.png(Some("second scan borealis"))
  let created =
    support.create_upload(app, token, support.uuid(), [#("page_id", json.string(page_id))], good, "immediate", [
      #("if-match", "\"c" <> int.to_string(content) <> "\""),
    ])
  let session = str(created, ["upload_session_id"])
  support.put_staging(app, account, session, good)
  let assert 200 = support.complete(app, token, session).status
  support.drain(app)
  let page = call(app, http.Get, "/v1/pages/" <> page_id, token, None, [])
  let assert False = str(page, ["page", "revision_id"]) == old_revision
  let old =
    call(app, http.Post, "/v1/search", token, Some(json.object([#("query", json.string("aurora"))])), [])
  let assert [] = support.get(old, ["results"], decode.list(decode.dynamic))
  let assert 1 = support.get(call(app, http.Get, "/v1/usage", token, None, []), ["stored_pages"], decode.int)
}

// 38/77: bulk renumbering ------------------------------------------------------------

pub fn renumber_shift_and_mapping_test() {
  let app = support.app()
  let token = support.user(app)
  let notebook = support.notebook(app, token, "Numbers")
  let pages =
    list.map([1, 2, 3], fn(n) {
      let #(_, id) = support.upload_page(app, token, notebook, n, Some("p" <> int.to_string(n)), "deferred")
      id
    })
  let path = "/v1/notebooks/" <> notebook <> "/renumber"
  let shift =
    call(app, http.Post, path, token, Some(json.object([
      #("shift", json.object([#("from", json.int(1)), #("to", json.int(3)), #("by", json.int(1))])),
    ])), [])
  let assert 200 = shift.status
  let numbering = call(app, http.Get, path, token, None, [])
  let numbers = support.get(numbering, ["pages"], decode.list(decode.at(["page_number"], decode.int)))
  let assert [2, 3, 4] = numbers
  // Swap two pages via an explicit mapping with their versions.
  let entries =
    support.get(numbering, ["pages"], decode.list({
      use id <- decode.field("page_id", decode.string)
      use number <- decode.field("page_number", decode.int)
      use version <- decode.field("version", decode.int)
      decode.success(#(id, number, version))
    }))
  let assert [a, b, ..] = entries
  let mapping =
    json.object([#("mapping", json.array([#(a.0, b.1, a.2), #(b.0, a.1, b.2)], fn(e) {
      json.object([
        #("page_id", json.string(e.0)),
        #("page_number", json.int(e.1)),
        #("version", json.int(e.2)),
      ])
    }))])
  let assert 200 = call(app, http.Post, path, token, Some(mapping), []).status
  // The same mapping again is stale: versions changed.
  let assert 412 = call(app, http.Post, path, token, Some(mapping), []).status
  // A shift colliding with a page outside the range conflicts.
  let collide =
    call(app, http.Post, path, token, Some(json.object([
      #("shift", json.object([#("from", json.int(2)), #("to", json.int(2)), #("by", json.int(1))])),
    ])), [])
  let assert 409 = collide.status
  let assert "page_number_conflict" = str(collide, ["error", "code"])
  // Stale numbering ETag on a whole-notebook plan.
  let assert 412 =
    call(app, http.Post, path, token, Some(json.object([
      #("shift", json.object([#("from", json.int(1)), #("to", json.int(9)), #("by", json.int(10))])),
    ])), [#("if-match", "\"n1\"")]).status
  let _ = pages
  Nil
}

// 39/57: lazy expiry without a sweeper ----------------------------------------------------

pub fn lazy_expiry_frees_number_and_capacity_test() {
  let app = support.app()
  let token = support.user(app)
  let account = set_limits(app, token, 1, 1, 5, 10)
  let notebook = support.notebook(app, token, "Expiry")
  let bytes = support.png(Some("abandoned"))
  let target = [#("notebook_id", json.string(notebook)), #("page_number", json.int(5))]
  let first = support.create_upload(app, token, support.uuid(), target, bytes, "immediate", [])
  let assert 201 = first.status
  let blocked = support.create_upload(app, token, support.uuid(), target, bytes, "immediate", [])
  let assert 409 = blocked.status
  support.sql(app, "update upload_sessions set expires_at = now() - interval '1 second' where account_id = $1::uuid", [account])
  let second = support.create_upload(app, token, support.uuid(), target, bytes, "immediate", [])
  let assert 201 = second.status
  // Late completion of the expired session is rejected.
  let session = str(first, ["upload_session_id"])
  support.put_staging(app, account, session, bytes)
  let late = support.complete(app, token, session)
  let assert 409 = late.status
  let assert "upload_expired" = str(late, ["error", "code"])
  let usage = call(app, http.Get, "/v1/usage", token, None, [])
  let assert 1 = support.get(usage, ["reserved_page_slots"], decode.int)
  let assert 1 = support.get(usage, ["lifetime_allowance", "reserved"], decode.int)
}

// 43: deferred processing ------------------------------------------------------------------

pub fn deferred_upload_and_process_deferred_test() {
  let app = support.app()
  let token = support.user(app)
  let _ = set_limits(app, token, 1, 10, 5, 0)
  let notebook = support.notebook(app, token, "Deferred")
  let bytes = support.png(Some("later please"))
  let refused =
    support.create_upload(
      app,
      token,
      support.uuid(),
      [#("notebook_id", json.string(notebook)), #("page_number", json.int(1))],
      bytes,
      "immediate",
      [],
    )
  let assert 409 = refused.status
  let assert "processing_limit_reached" = str(refused, ["error", "code"])
  let assert True = support.get(refused, ["error", "details", "deferred_upload_available"], decode.bool)
  let #(done, page_id) = support.upload_page(app, token, notebook, 1, Some("later please"), "deferred")
  let assert "accepted" = str(done, ["operation", "status"])
  let page = call(app, http.Get, "/v1/pages/" <> page_id, token, None, [])
  let assert "awaiting_processing" = str(page, ["page", "processing_status"])
  let revision = str(page, ["page", "revision_id"])
  let item = fn(op) {
    json.object([#("items", json.array([op], fn(op) {
      json.object([
        #("page_id", json.string(page_id)),
        #("source_revision_id", json.string(revision)),
        #("operation_id", json.string(op)),
      ])
    }))])
  }
  let op = support.uuid()
  let limited = call(app, http.Post, "/v1/pages/process-deferred", token, Some(item(op)), [])
  let assert ["limit"] = support.get(limited, ["results"], decode.list(decode.at(["result"], decode.string)))
  let _ = set_limits(app, token, 2, 10, 5, 5)
  let admitted = call(app, http.Post, "/v1/pages/process-deferred", token, Some(item(op)), [])
  let assert ["admitted"] = support.get(admitted, ["results"], decode.list(decode.at(["result"], decode.string)))
  let again = call(app, http.Post, "/v1/pages/process-deferred", token, Some(item(op)), [])
  let assert ["already_admitted"] = support.get(again, ["results"], decode.list(decode.at(["result"], decode.string)))
  let other = call(app, http.Post, "/v1/pages/process-deferred", token, Some(item(support.uuid())), [])
  let assert ["conflict"] = support.get(other, ["results"], decode.list(decode.at(["result"], decode.string)))
  support.drain(app)
  let page = call(app, http.Get, "/v1/pages/" <> page_id, token, None, [])
  let assert "ready" = str(page, ["page", "processing_status"])
}

// 46/41/74/75: entitlement contract ---------------------------------------------------

pub fn entitlement_contract_validation_test() {
  let app = support.app()
  let token = support.user(app)
  let account = support.account_id(app, token)
  let path = "/internal/v1/accounts/" <> account <> "/entitlements"
  let null_limit =
    json.object([
      #("command_id", json.string(support.uuid())),
      #("authority", json.string("test-authority")),
      #("revision", json.int(1)),
      #("effective_at", json.string("2020-01-01T00:00:00Z")),
      #("limits", json.object([
        #("stored_pages", json.null()),
        #("notebooks", support.limited(1)),
        #("processing_pages_per_period", support.limited(1)),
      ])),
      #("processing_policy", json.object([#("kind", json.string("lifetime"))])),
      #("processing_coverage", json.array([], json.string)),
      #("coverage_revocations", json.array([], json.string)),
      #("renewal_policy", json.object([#("kind", json.string("disabled"))])),
      #("features", json.object([])),
    ])
  let assert 422 = support.internal(app, http.Put, path, null_limit).status
  let baseline =
    json.object([
      #("command_id", json.string(support.uuid())),
      #("authority", json.string("test-authority")),
      #("revision", json.int(1)),
      #("effective_at", json.string("2020-01-01T00:00:00Z")),
      #("limits", json.object([
        #("stored_pages", json.object([#("kind", json.string("unlimited"))])),
        #("notebooks", support.limited(1)),
        #("processing_pages_per_period", support.limited(1)),
      ])),
      #("processing_policy", json.object([#("kind", json.string("lifetime"))])),
      #("processing_coverage", json.array([], json.string)),
      #("coverage_revocations", json.array([], json.string)),
      #("renewal_policy", json.object([#("kind", json.string("disabled"))])),
      #("features", json.object([#("export", json.bool(False))])),
    ])
  let assert 422 = support.internal(app, http.Put, path, baseline).status
  // Unauthenticated internal calls are rejected.
  let assert 401 =
    support.send(app, simulate.request(http.Get, "/internal/v1/accounts/" <> account <> "/entitlement-status")).status
  // Coverage funds admission before the lifetime allowance; a
  // revocation stops new admissions from that record.
  let coverage = support.uuid()
  let record =
    json.object([
      #("coverage_id", json.string(coverage)),
      #("kind", json.string("base")),
      #("starts_at", json.string("2020-01-01T00:00:00Z")),
      #("ends_at", json.string("2099-01-01T00:00:00Z")),
      #("authorized_units", json.int(2)),
      #("confirmation_state", json.string("confirmed")),
    ])
  let payload =
    support.entitlement(2, 100, 5, 2, "calendar_months_from_anchor", [record], [])
  let assert 200 = support.internal(app, http.Put, path, payload).status
  let replay = support.internal(app, http.Put, path, payload)
  let assert False = support.get(replay, ["applied"], decode.bool)
  let notebook = support.notebook(app, token, "Funded")
  let _ = support.upload_page(app, token, notebook, 1, Some("funded unit"), "immediate")
  support.drain(app)
  let usage = call(app, http.Get, "/v1/usage", token, None, [])
  let assert [1] = support.get(usage, ["processing_coverage"], decode.list(decode.at(["used"], decode.int)))
  let assert 0 = support.get(usage, ["lifetime_allowance", "used"], decode.int)
  // Changing an issued budget conflicts.
  let changed =
    support.entitlement(3, 100, 5, 2, "calendar_months_from_anchor", [
      json.object([
        #("coverage_id", json.string(coverage)),
        #("kind", json.string("base")),
        #("starts_at", json.string("2020-01-01T00:00:00Z")),
        #("ends_at", json.string("2099-01-01T00:00:00Z")),
        #("authorized_units", json.int(50)),
      ]),
    ], [])
  let assert 409 = support.internal(app, http.Put, path, changed).status
  let revoke =
    support.entitlement(3, 100, 5, 2, "calendar_months_from_anchor", [record], [
      json.object([
        #("revocation_id", json.string(support.uuid())),
        #("coverage_ids", json.array([coverage], json.string)),
        #("effective_at", json.string("2021-01-01T00:00:00Z")),
        #("reason", json.string("refund")),
      ]),
    ])
  let assert 200 = support.internal(app, http.Put, path, revoke).status
  let _ = support.upload_page(app, token, notebook, 2, Some("after refund"), "immediate")
  support.drain(app)
  let usage = call(app, http.Get, "/v1/usage", token, None, [])
  let assert [1] = support.get(usage, ["processing_coverage"], decode.list(decode.at(["used"], decode.int)))
  let assert 1 = support.get(usage, ["lifetime_allowance", "used"], decode.int)
}

pub fn credit_grants_are_idempotent_test() {
  let app = support.app()
  let token = support.user(app)
  let account = support.account_id(app, token)
  let path = "/internal/v1/accounts/" <> account <> "/credit-grants"
  let grant =
    json.object([
      #("external_grant_id", json.string("grant-" <> support.random_id())),
      #("units", json.int(15)),
    ])
  let a = support.internal(app, http.Post, path, grant)
  let b = support.internal(app, http.Post, path, grant)
  let assert True = str(a, ["credit_grant_id"]) == str(b, ["credit_grant_id"])
  let assert 1 =
    support.sql_int(app, "select count(*)::int from credit_grants where account_id = $1::uuid", [account])
}

// 31: trash and restore through the journal ------------------------------------------

pub fn trash_and_restore_page_test() {
  let app = support.app()
  let token = support.user(app)
  let notebook = support.notebook(app, token, "Trash")
  let #(_, page_id) = support.upload_page(app, token, notebook, 1, Some("ephemeral kumquat"), "immediate")
  support.drain(app)
  let trashed = call(app, http.Delete, "/v1/pages/" <> page_id, token, None, [])
  let assert 202 = trashed.status
  let assert "recovery_pending" = str(trashed, ["status"])
  let assert 404 = call(app, http.Get, "/v1/pages/" <> page_id, token, None, []).status
  let found =
    call(app, http.Post, "/v1/search", token, Some(json.object([#("query", json.string("kumquat"))])), [])
  let assert [] = support.get(found, ["results"], decode.list(decode.dynamic))
  // Further lifecycle changes wait for journal acknowledgement.
  let pending = call(app, http.Post, "/v1/pages/" <> page_id <> "/restore", token, Some(json.object([])), [])
  let assert 409 = pending.status
  ship(app)
  // Another page now holds number 1, so restore needs a new number.
  let _ = support.upload_page(app, token, notebook, 1, Some("newcomer"), "deferred")
  let conflict = call(app, http.Post, "/v1/pages/" <> page_id <> "/restore", token, Some(json.object([])), [])
  let assert 409 = conflict.status
  let assert "restore_conflict" = str(conflict, ["error", "code"])
  let restore =
    call(app, http.Post, "/v1/pages/" <> page_id <> "/restore", token, Some(json.object([#("page_number", json.int(9))])), [])
  let assert 202 = restore.status
  let assert 404 = call(app, http.Get, "/v1/pages/" <> page_id, token, None, []).status
  ship(app)
  let page = call(app, http.Get, "/v1/pages/" <> page_id, token, None, [])
  let assert 9 = support.get(page, ["page", "page_number"], decode.int)
  let found =
    call(app, http.Post, "/v1/search", token, Some(json.object([#("query", json.string("kumquat"))])), [])
  let assert [_] = support.get(found, ["results"], decode.list(decode.dynamic))
  let assert 2 = support.get(call(app, http.Get, "/v1/usage", token, None, []), ["stored_pages"], decode.int)
}

fn ship(app: router.App) -> Nil {
  support.maintain(app, "journal")
}

// 63: browser authentication to /v1 ----------------------------------------------------

pub fn cookie_and_bearer_modes_are_exclusive_test() {
  let app = support.app()
  let token = support.user(app)
  let account = support.account_id(app, token)
  let cookie = "cookie-" <> support.random_id()
  let csrf = "csrf-" <> support.random_id()
  support.sql(
    app,
    "insert into web_sessions (token_hash, user_id, account_id, csrf_token, auth_time, expires_at)
     select sha256(convert_to($1, 'UTF8')), owner_user_id, id, $3, now(), now() + interval '1 hour'
     from accounts where id = $2::uuid",
    [cookie, account, csrf],
  )
  let both =
    simulate.request(http.Get, "/v1/me")
    |> simulate.header("authorization", "Bearer " <> token)
    |> simulate.header("cookie", "libarrie_session=" <> cookie)
    |> support.send(app, _)
  let assert 400 = both.status
  let get =
    simulate.request(http.Get, "/v1/me")
    |> simulate.header("cookie", "libarrie_session=" <> cookie)
    |> support.send(app, _)
  let assert 200 = get.status
  let body = json.object([#("name", json.string("From browser"))])
  let no_csrf =
    simulate.request(http.Post, "/v1/notebooks")
    |> simulate.header("cookie", "libarrie_session=" <> cookie)
    |> simulate.header("origin", "http://localhost:8080")
    |> simulate.json_body(body)
    |> support.send(app, _)
  let assert 403 = no_csrf.status
  let foreign =
    simulate.request(http.Post, "/v1/notebooks")
    |> simulate.header("cookie", "libarrie_session=" <> cookie)
    |> simulate.header("x-csrf-token", csrf)
    |> simulate.header("origin", "https://evil.example")
    |> simulate.json_body(body)
    |> support.send(app, _)
  let assert 403 = foreign.status
  let ok =
    simulate.request(http.Post, "/v1/notebooks")
    |> simulate.header("cookie", "libarrie_session=" <> cookie)
    |> simulate.header("x-csrf-token", csrf)
    |> simulate.header("origin", "http://localhost:8080")
    |> simulate.json_body(body)
    |> support.send(app, _)
  let assert 201 = ok.status
  let unauthenticated = support.send(app, simulate.request(http.Get, "/v1/me"))
  let assert 401 = unauthenticated.status
  let assert True = string.contains(unauthenticated.body, "authentication_required")
}
