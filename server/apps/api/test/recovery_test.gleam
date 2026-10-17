//// Journal replay after restoring an older database snapshot (scenarios
//// 16, 21 and 53). The "restore" is simulated by reverting rows to their
//// pre-event state and removing the local outbox records, exactly what a
//// snapshot taken before those events would contain.

import gleam/dynamic/decode
import gleam/http
import gleam/int
import gleam/json
import gleam/option.{None, Some}
import libarrie/domain/recovery
import support.{call, str}

pub fn replay_reapplies_deletions_and_cancellations_test() {
  let app = support.app()
  let token = support.user(app)
  let account = support.account_id(app, token)
  let notebook = support.notebook(app, token, "Recovery")
  let #(_, page_id) = support.upload_page(app, token, notebook, 1, Some("restore me not"), "immediate")
  support.drain(app)
  // A page deletion after the recovery point, durable in the journal.
  let assert 202 = call(app, http.Delete, "/v1/pages/" <> page_id, token, None, []).status
  // A closure scheduled and then cancelled after the recovery point.
  let scheduled = call(app, http.Post, "/v1/account-deletion", token, Some(json.object([])), [])
  let revision = support.get(scheduled, ["lifecycle_revision"], decode.int)
  let assert 202 =
    call(app, http.Delete, "/v1/account-deletion", token, None, [#("if-match", int.to_string(revision))]).status
  support.maintain(app, "journal")
  // Restore an older snapshot: the page is active again, the account has
  // the old scheduled revision with a past deadline, and the snapshot has no
  // record of those journal events.
  support.sql(app, "update pages set visibility = 'active', deleted_at = null where id = $1::uuid", [page_id])
  support.sql(app, "update accounts set status = 'closure_scheduled', lifecycle_revision = $2::text::bigint,
      closure_effective_at = now() - interval '1 minute' where id = $1::uuid", [account, int.to_string(revision)])
  support.sql(app, "delete from lifecycle_outbox where account_id = $1::uuid", [account])
  let assert Ok(report) = recovery.replay(app.ctx)
  let assert True = report.replayed >= 3
  // The deletion is re-applied and the cancellation defeats the old deadline.
  let assert 404 = call(app, http.Get, "/v1/pages/" <> page_id, token, None, []).status
  let assert 1 =
    support.sql_int(app, "select count(*)::int from accounts where id = $1::uuid and status = 'active'
      and lifecycle_revision = $2::text::bigint", [account, int.to_string(revision + 1)])
  support.sql(app, "update jobs set run_after = now() where stage = 'account_closure_deadline'
      and payload->>'account_id' = $1", [account])
  support.drain(app)
  let assert "active" = str(call(app, http.Get, "/v1/account-deletion", token, None, []), ["status"])
  let assert 0 = support.get(call(app, http.Get, "/v1/usage", token, None, []), ["stored_pages"], decode.int)
  // Replay is idempotent.
  let assert Ok(again) = recovery.replay(app.ctx)
  let assert 0 = again.replayed
  // A delivered event missing from the journal is a coverage gap: recovery
  // stays closed.
  support.sql(app, "insert into lifecycle_outbox (command_id, account_id, scope_kind, scope_id,
      generation, action, destination, payload, payload_hash, state, acknowledgement)
    values (gen_random_uuid(), $1::uuid, 'page', $2::uuid, 1, 'trash', 'journal', '{}', 'x',
      'acknowledged', 'journal/v1/99999999999999999999-missing.json')", [account, page_id])
  let assert Error(recovery.CoverageGap(_)) = recovery.replay(app.ctx)
  support.sql(app, "delete from lifecycle_outbox where acknowledgement = 'journal/v1/99999999999999999999-missing.json'", [])
}
