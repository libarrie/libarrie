//// Credit revoke-on-release, provisional renewal coverage during authority
//// outages, batched account purge and job-archive pruning.

import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/option.{None, Some}
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import support

fn rfc(offset_hours: Int) -> String {
  timestamp.system_time()
  |> timestamp.add(duration.hours(offset_hours))
  |> timestamp.to_rfc3339(calendar.utc_offset)
}

fn assignment(revision: Int, policy: String, coverage: List(json.Json), revocations: List(json.Json), renewal: json.Json) -> json.Json {
  json.object([
    #("command_id", json.string(support.uuid())),
    #("authority", json.string("test-authority")),
    #("revision", json.int(revision)),
    #("effective_at", json.string("2020-01-01T00:00:00Z")),
    #("limits", json.object([
      #("stored_pages", support.limited(100)),
      #("notebooks", support.limited(5)),
      #("processing_pages_per_period", support.limited(0)),
    ])),
    #("processing_policy", json.object([#("kind", json.string(policy))])),
    #("processing_coverage", json.preprocessed_array(coverage)),
    #("coverage_revocations", json.preprocessed_array(revocations)),
    #("renewal_policy", renewal),
    #("features", json.object([])),
    #("scheduled_change", json.null()),
  ])
}

fn put(app, account: String, body: json.Json) -> support.Reply {
  support.internal(app, http.Put, "/internal/v1/accounts/" <> account <> "/entitlements", body)
}

fn status(app, account: String) -> support.Reply {
  support.internal(app, http.Get, "/internal/v1/accounts/" <> account <> "/entitlement-status", json.null())
}

fn reserve(app, token: String, notebook: String, number: Int) -> support.Reply {
  support.create_upload(app, token, support.uuid(),
    [#("notebook_id", json.string(notebook)), #("page_number", json.int(number))],
    support.png(Some("page " <> json.to_string(json.int(number)))), "immediate", [])
}

// Credit grants ---------------------------------------------------------------------------

pub fn revoked_credit_units_released_later_stay_revoked_test() {
  let app = support.app()
  let token = support.user(app)
  let account = support.account_id(app, token)
  // No lifetime allowance, so processing is funded by credits.
  let assert 200 = put(app, account, assignment(1, "lifetime", [], [], json.object([#("kind", json.string("disabled"))]))).status
  let path = "/internal/v1/accounts/" <> account <> "/credit-grants"
  let grant_id = "grant-" <> support.random_id()
  let grant = support.internal(app, http.Post, path, json.object([
    #("external_grant_id", json.string(grant_id)), #("units", json.int(3)),
  ]))
  let id = support.str(grant, ["credit_grant_id"])
  let notebook = support.notebook(app, token, "Credits")
  let pending = reserve(app, token, notebook, 1)
  let assert 201 = pending.status
  let operation = support.str(pending, ["operation", "operation_id"])
  let counters = fn() {
    #(
      support.sql_int(app, "select reserved from credit_grants where id = $1::uuid", [id]),
      support.sql_int(app, "select revoked from credit_grants where id = $1::uuid", [id]),
    )
  }
  let assert #(1, 0) = counters()
  // Revocation removes the two unreserved units at once; the reserved one
  // stays usable by the admitted operation.
  let revoked = support.internal(app, http.Post, path, json.object([
    #("external_grant_id", json.string(grant_id)), #("action", json.string("revoke")),
  ]))
  let assert 2 = support.get(revoked, ["revoked"], decode.int)
  let assert #(1, 2) = counters()
  // New work cannot use the revoked units.
  let assert 409 = reserve(app, token, notebook, 2).status
  // Released later, the reserved unit becomes revoked, not spendable.
  let assert 200 = support.call(app, http.Post, "/v1/operations/" <> operation <> "/cancel", token, None, []).status
  let assert #(0, 3) = counters()
  let assert 409 = reserve(app, token, notebook, 3).status
  // Revoking again is idempotent.
  let again = support.internal(app, http.Post, path, json.object([
    #("external_grant_id", json.string(grant_id)), #("action", json.string("revoke")),
  ]))
  let assert 3 = support.get(again, ["revoked"], decode.int)
}

// Provisional renewal --------------------------------------------------------------------------

fn renewal(through: String, grace: Int) -> json.Json {
  json.object([
    #("kind", json.string("bounded_outage")),
    #("policy_id", json.string("6f1d2c3b-4a59-4e1f-8a2b-3c4d5e6f7a8b")),
    #("schedule_id", json.string("7a2e3d4c-5b6a-4f20-9b3c-4d5e6f7a8b9c")),
    #("service_anchor", json.string(through)),
    #("nominal_budget", json.int(50)),
    #("authorized_through", json.string(through)),
    #("max_grace_days", json.int(grace)),
  ])
}

fn funded_month(id: String, starts: String, ends: String) -> json.Json {
  json.object([
    #("coverage_id", json.string(id)),
    #("kind", json.string("base")),
    #("starts_at", json.string(starts)),
    #("ends_at", json.string(ends)),
    #("authorized_units", json.int(50)),
  ])
}

fn provisional(app, account: String) -> List(#(String, String, Int)) {
  support.get(status(app, account), ["provisional_coverage"], decode.list({
    use id <- decode.field("coverage_id", decode.string)
    use state <- decode.field("state", decode.string)
    use units <- decode.field("authorized_units", decode.int)
    decode.success(#(id, state, units))
  }))
}

pub fn outage_provisions_then_authority_confirms_test() {
  let app = support.app()
  let token = support.user(app)
  let account = support.account_id(app, token)
  // Paid through an hour ago; the authority has not delivered the renewal.
  let through = rfc(-1)
  let paid_from = rfc(-24 * 30)
  let paid = support.uuid()
  let assert 200 =
    put(app, account, assignment(1, "calendar_months_from_anchor", [funded_month(paid, paid_from, through)], [], renewal(through, 7))).status
  let assert [] = provisional(app, account)
  // Admission provisions the next service month and funds from it.
  let notebook = support.notebook(app, token, "Renewal")
  let assert 201 = reserve(app, token, notebook, 1).status
  let assert [#(record, "provisional", 50)] = provisional(app, account)
  let assert 1 = support.get(status(app, account), ["outage_exposure_units"], decode.int)
  let assert 1 =
    support.sql_int(app, "select reserved from processing_coverage where id = $1::uuid", [record])
  // Admission ends at the grace end, not the month end.
  let assert True =
    support.sql_int(app, "select (admission_end_at < ends_at)::int from processing_coverage where id = $1::uuid", [record]) == 1
  // A second reservation reuses the same record (deterministic ID).
  let assert 201 = reserve(app, token, notebook, 2).status
  let assert [_] = provisional(app, account)
  let starts = support.sql_str(app, "select rfc3339(starts_at) from processing_coverage where id = $1::uuid", [record])
  let ends = support.sql_str(app, "select rfc3339(ends_at) from processing_coverage where id = $1::uuid", [record])
  // The authority cannot confirm the interval with a different budget.
  let inflated =
    json.object([
      #("coverage_id", json.string(record)), #("kind", json.string("base")),
      #("starts_at", json.string(starts)), #("ends_at", json.string(ends)),
      #("authorized_units", json.int(80)), #("confirmation_state", json.string("confirmed")),
    ])
  let assert 409 =
    put(app, account, assignment(2, "calendar_months_from_anchor", [funded_month(paid, paid_from, through), inflated], [], renewal(through, 7))).status
  // Confirming the same record reopens admission to the end of the month.
  let confirmed =
    json.object([
      #("coverage_id", json.string(record)), #("kind", json.string("base")),
      #("starts_at", json.string(starts)), #("ends_at", json.string(ends)),
      #("authorized_units", json.int(50)), #("confirmation_state", json.string("confirmed")),
    ])
  let r = put(app, account, assignment(2, "calendar_months_from_anchor", [funded_month(paid, paid_from, through), confirmed], [], renewal(ends, 7)))
  case r.status {
    200 -> Nil
    _ -> panic as { "confirm failed: " <> r.body <> " paid_from=" <> paid_from <> " through=" <> through <> " starts=" <> starts <> " ends=" <> ends }
  }
  let assert [#(_, "confirmed", 50)] = provisional(app, account)
  let assert 0 = support.get(status(app, account), ["outage_exposure_units"], decode.int)
  let assert 1 =
    support.sql_int(app, "select (admission_end_at = ends_at)::int from processing_coverage where id = $1::uuid", [record])
}

pub fn rejected_provisional_coverage_is_exposure_and_grace_is_bounded_test() {
  let app = support.app()
  let token = support.user(app)
  let account = support.account_id(app, token)
  let through = rfc(-2)
  let paid_from = rfc(-24 * 30)
  let paid = support.uuid()
  let assert 200 =
    put(app, account, assignment(1, "calendar_months_from_anchor", [funded_month(paid, paid_from, through)], [], renewal(through, 7))).status
  let notebook = support.notebook(app, token, "Rejected")
  let assert 201 = reserve(app, token, notebook, 1).status
  let assert [#(record, "provisional", _)] = provisional(app, account)
  // The authority recovers, finds no funding, and rejects the record.
  let rejection =
    json.object([
      #("revocation_id", json.string(support.uuid())),
      #("coverage_ids", json.array([record], json.string)),
      #("effective_at", json.string(rfc(0))),
      #("reason", json.string("provisional_rejected")),
    ])
  let r = put(app, account, assignment(2, "calendar_months_from_anchor", [funded_month(paid, paid_from, through)], [rejection],
      json.object([#("kind", json.string("disabled"))])))
  let assert 200 = r.status
  let assert [#(_, "rejected", _)] = provisional(app, account)
  // The pinned unit stays honored and counts as outage exposure.
  let assert 1 = support.get(status(app, account), ["outage_exposure_units"], decode.int)

  // Past the grace window nothing is provisioned.
  let late = support.user(app)
  let late_account = support.account_id(app, late)
  let long_ago = rfc(-24 * 8)
  let assert 200 =
    put(app, late_account, assignment(1, "calendar_months_from_anchor", [funded_month(support.uuid(), rfc(-24 * 40), long_ago)], [], renewal(long_ago, 7))).status
  let late_notebook = support.notebook(app, late, "Late")
  let _ = reserve(app, late, late_notebook, 1)
  let assert [] = provisional(app, late_account)

  // An account with a closure intent gets no provisional coverage.
  let closing = support.user(app)
  let closing_account = support.account_id(app, closing)
  let recent = rfc(-1)
  let assert 200 =
    put(app, closing_account, assignment(1, "calendar_months_from_anchor", [funded_month(support.uuid(), rfc(-24 * 30), recent)], [], renewal(recent, 7))).status
  let assert 202 = support.call(app, http.Post, "/v1/account-deletion", closing, Some(json.object([])), []).status
  let assert [] = provisional(app, closing_account)
}

pub fn invalid_renewal_policies_are_rejected_test() {
  let app = support.app()
  let token = support.user(app)
  let account = support.account_id(app, token)
  let too_long =
    json.object([
      #("kind", json.string("bounded_outage")),
      #("policy_id", json.string(support.uuid())),
      #("schedule_id", json.string(support.uuid())),
      #("service_anchor", json.string(rfc(0))),
      #("nominal_budget", json.int(10)),
      #("authorized_through", json.string(rfc(0))),
      #("max_grace_days", json.int(30)),
    ])
  let assert 422 = put(app, account, assignment(1, "lifetime", [], [], too_long)).status
  let assert 422 = put(app, account, assignment(1, "lifetime", [], [], json.object([#("kind", json.string("forever"))]))).status
}

// Archive pruning --------------------------------------------------------------------------------

pub fn old_archived_jobs_are_pruned_test() {
  let app = support.app()
  let token = support.user(app)
  let notebook = support.notebook(app, token, "Archive")
  let _ = support.upload_page(app, token, notebook, 1, Some("archived"), "immediate")
  support.drain(app)
  support.sql(app, "update jobs set updated_at = now() - interval '2 hours' where state in ('succeeded', 'failed', 'cancelled')", [])
  support.maintain(app, "archive")
  let archived = support.sql_int(app, "select count(*)::int from jobs_archive", [])
  let assert True = archived > 0
  // Past the retention period they are deleted with their attempts.
  support.sql(app, "update jobs_archive set updated_at = now() - interval '31 days'", [])
  support.maintain(app, "prune")
  let assert 0 = support.sql_int(app, "select count(*)::int from jobs_archive where updated_at < now() - interval '30 days'", [])
  let assert 0 =
    support.sql_int(app, "select count(*)::int from job_attempts_archive a where not exists (select 1 from jobs_archive j where j.id = a.job_id)", [])
}

// Automatic deferred admission ----------------------------------------------------------------

pub fn opted_in_accounts_process_deferred_pages_automatically_test() {
  let app = support.app()
  let token = support.user(app)
  let notebook = support.notebook(app, token, "Later")
  let #(_, first) = support.upload_page(app, token, notebook, 1, Some("waiting one"), "deferred")
  let #(_, second) = support.upload_page(app, token, notebook, 2, Some("waiting two"), "deferred")
  let waiting = fn() {
    support.sql_int(app, "select count(*)::int from pages where id = any(array[$1::uuid, $2::uuid]) and awaiting_processing", [first, second])
  }
  // Off by default: nothing happens.
  let assert False = support.get(support.call(app, http.Get, "/v1/settings", token, None, []), ["auto_process_deferred"], decode.bool)
  support.maintain(app, "deferred")
  let assert 2 = waiting()
  let enabled =
    support.call(app, http.Put, "/v1/settings", token, Some(json.object([#("auto_process_deferred", json.bool(True))])), [])
  let assert True = support.get(enabled, ["auto_process_deferred"], decode.bool)
  support.maintain(app, "deferred")
  let assert 0 = waiting()
  // Running again never starts a second operation for the same source.
  support.maintain(app, "deferred")
  let assert 2 =
    support.sql_int(app, "select count(*)::int from operations where kind = 'deferred_processing' and page_id = any(array[$1::uuid, $2::uuid])", [first, second])
  support.drain(app)
  let assert "ready" = support.str(support.call(app, http.Get, "/v1/pages/" <> first, token, None, []), ["page", "processing_status"])
}

/// Postgres stores microseconds and rounds exact halves to even, so a
/// redelivered record with half-microsecond times must still match what
/// core stored (this used to fail intermittently with coverage_conflict).
pub fn half_microsecond_times_match_stored_coverage_test() {
  let app = support.app()
  let token = support.user(app)
  let account = support.account_id(app, token)
  let paid = support.uuid()
  // .8848545 is stored as .884854 (to even); .8848555 as .884856.
  let month =
    funded_month(
      paid,
      "2026-01-18T12:00:54.8848545Z",
      "2026-02-18T12:00:54.8848555Z",
    )
  let assert 200 =
    put(
      app,
      account,
      assignment(
        1,
        "calendar_months_from_anchor",
        [month],
        [],
        json.object([#("kind", json.string("disabled"))]),
      ),
    ).status
  let assert 200 =
    put(
      app,
      account,
      assignment(
        2,
        "calendar_months_from_anchor",
        [month],
        [],
        json.object([#("kind", json.string("disabled"))]),
      ),
    ).status
}
