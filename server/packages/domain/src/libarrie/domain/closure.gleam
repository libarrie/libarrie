//// Durable account closure (sections 12 and 14).
////
//// `active -> closure_scheduled -> closing -> closed`; only
//// `closure_scheduled -> active` is cancellable, and only before the
//// effective time. Every transition increments `lifecycle_revision` under the
//// account lock and writes one immutable full desired-state command,
//// delivered to the independent journal and to any lifecycle subscriber under the same
//// command identity. The deadline job closes only if its expected revision is
//// still current, so a stale job after cancellation or rescheduling is a
//// no-op. Exports always keep a 72-hour download window, which can extend
//// the deadline up to 30 days after the deletion request.

import gleam/bool
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import libarrie/database.{type Connection}
import libarrie/domain/admin
import libarrie/domain/context.{type Context}
import libarrie/domain/error.{type AppError, db}
import libarrie/domain/journal
import libarrie/domain/operations
import libarrie/domain/pages
import libarrie/domain/pins
import libarrie/domain/quota
import libarrie/integrations/identity
import libarrie/jobs.{type Job}
import youid/uuid

pub type Account {
  Account(
    status: String,
    lifecycle_revision: Int,
    requested_at: Option(String),
    effective_at: Option(String),
    cap_at: Option(String),
    purged_at: Option(String),
  )
}

fn load(conn: Connection, account_id: String, lock: Bool) -> Result(Account, AppError) {
  let suffix = case lock {
    True -> " for update"
    False -> ""
  }
  use account <- error.found(database.query_one(
    conn,
    "select status, lifecycle_revision, rfc3339(closure_requested_at),
       rfc3339(closure_effective_at), rfc3339(closure_cap_at), rfc3339(purged_at)
     from accounts where id = $1::uuid" <> suffix,
    [database.text(account_id)],
    {
      use status <- decode.field(0, decode.string)
      use revision <- decode.field(1, decode.int)
      use requested <- decode.field(2, decode.optional(decode.string))
      use effective <- decode.field(3, decode.optional(decode.string))
      use cap <- decode.field(4, decode.optional(decode.string))
      use purged <- decode.field(5, decode.optional(decode.string))
      decode.success(Account(status, revision, requested, effective, cap, purged))
    },
  ))
  Ok(account)
}

// Scheduling -------------------------------------------------------------------------

pub type ScheduleRequest {
  ScheduleRequest(acknowledge_coverage_end: Bool)
}

pub fn schedule_decoder() -> decode.Decoder(ScheduleRequest) {
  use ack <- decode.optional_field("acknowledge_coverage_end", False, decode.bool)
  decode.success(ScheduleRequest(ack))
}

/// `POST /v1/account-deletion`. Requires recent authentication (checked by
/// the caller). Restrictions apply immediately; reads and exports continue
/// through the grace period.
pub fn schedule(
  ctx: Context,
  account_id: String,
  request: ScheduleRequest,
) -> Result(#(Int, json.Json), AppError) {
  use _ <- result.try(context.transaction(ctx, fn(tx) {
    use account <- result.try(load(tx, account_id, True))
    use <- error.guard(
      account.status == "active",
      case account.status {
        "closure_scheduled" ->
          error.new(409, "closure_already_scheduled", "Account closure is already scheduled.")
        _ -> error.account_closing()
      },
    )
    use unconfirmed <- result.try(journal.account_change_unconfirmed(tx, account_id))
    use <- error.guard(!unconfirmed, pages.recovery_pending())
    use _ <- result.try(admin.check_not_last_owner(tx, account_id))
    use _ <- result.try(quota.lock_usage(tx, account_id))
    use _ <- db(jobs.lock_account_slots(tx, account_id))
    // Deadline: grace, extended for export download windows, capped.
    use #(effective_at, cap_at) <- error.found(database.query_one(
      tx,
      "with bounds as (
         select now() + make_interval(secs => $2) as base,
                now() + make_interval(secs => $3) as cap),
       safe as (
         select max(case when state = 'assembling' then execution_deadline
                         else completed_at end + make_interval(secs => $4)) as at
         from exports where account_id = $1::uuid
           and (state = 'assembling' or (state = 'completed' and expires_at > now())))
       select rfc3339(least(greatest(base, coalesce(safe.at, base)), cap)), rfc3339(cap)
       from bounds, safe",
      [
        database.text(account_id),
        database.int(ctx.config.closure_grace_seconds),
        database.int(ctx.config.closure_max_seconds),
        database.int(ctx.config.exports.download_window_seconds),
      ],
      {
        use effective <- decode.field(0, decode.string)
        use cap <- decode.field(1, decode.string)
        decode.success(#(effective, cap))
      },
    ))
    // If processing coverage ends before the deadline, require acknowledgement
    // that withdrawing deletion later may return the account to its default
    // limits.
    use covered_through <- db(database.query_one(
      tx,
      "select rfc3339(max(admission_end_at)) from processing_coverage
       where account_id = $1::uuid and admission_end_at > now()
       having max(admission_end_at) < $2::text::timestamptz",
      [database.text(account_id), database.text(effective_at)],
      decode.at([0], decode.string),
    ))
    use _ <- result.try(case covered_through, request.acknowledge_coverage_end {
      Some(through), False ->
        Error(
          error.new(
            409,
            "acknowledgement_required",
            "Your current processing coverage ends before the closure date. If you cancel deletion after that, the account may return to its default limits.",
          )
          |> error.with_details([
            #("covered_through", json.string(through)),
            #("effective_at", json.string(effective_at)),
          ]),
        )
      _, _ -> Ok(Nil)
    })
    use _ <- result.try(cancel_live_work(tx, account_id))
    use _ <- db(database.execute(
      tx,
      "insert into closure_intents (id, account_id) values ($1::uuid, $2::uuid)",
      [database.text(uuid.v7_string()), database.text(account_id)],
    ))
    use _ <- db(database.execute(
      tx,
      "update accounts set status = 'closure_scheduled', closure_requested_at = now(),
         closure_effective_at = $2::text::timestamptz, closure_cap_at = $3::text::timestamptz,
         lifecycle_revision = lifecycle_revision + 1
       where id = $1::uuid",
      [database.text(account_id), database.text(effective_at), database.text(cap_at)],
    ))
    emit(ctx, tx, account_id, "closure_scheduled")
  }))
  use body <- result.try(status(ctx, account_id))
  Ok(#(202, body))
}

/// Cancel pending source-changing and processing work through the normal
/// reservation rules; accepted images are retained.
fn cancel_live_work(tx: Connection, account_id: String) -> Result(Nil, AppError) {
  use live <- db(database.query(
    tx,
    "select id::text, page_id::text, notebook_id::text from operations
     where account_id = $1::uuid and status = any($2::text[])
     order by id",
    [database.text(account_id), database.text_array(operations.live_states)],
    {
      use id <- decode.field(0, decode.string)
      use page <- decode.field(1, decode.optional(decode.string))
      use notebook <- decode.field(2, decode.optional(decode.string))
      decode.success(#(id, page, notebook))
    },
  ))
  use _ <- result.try(pages.lock_notebooks(
    tx,
    account_id,
    list.filter_map(live, fn(r) { option.to_result(r.2, Nil) }),
  ))
  use _ <- result.try(pages.lock_pages(
    tx,
    account_id,
    list.filter_map(live, fn(r) { option.to_result(r.1, Nil) }),
  ))
  list.try_each(live, fn(row) {
    use op <- result.try(operations.require(tx, account_id, row.0, True))
    case op.status, op.upload_accepted_at {
      "awaiting_upload", _ ->
        operations.end_unaccepted(tx, account_id, op, "cancelled", None, Some("account_closing"))
      _, _ ->
        operations.end_accepted(tx, account_id, op, "cancelled", None, Some("account_closing"))
    }
  })
}

/// Write the full desired-state command for the current revision to the
/// journal and any lifecycle subscriber, and (for scheduled closure) the
/// deadline job.
fn emit(ctx: Context, tx: Connection, account_id: String, action: String) -> Result(Nil, AppError) {
  use account <- result.try(load(tx, account_id, False))
  use intents <- db(database.query(
    tx,
    "select id::text, rfc3339(requested_at), rfc3339(withdrawn_at)
     from closure_intents where account_id = $1::uuid order by requested_at",
    [database.text(account_id)],
    {
      use id <- decode.field(0, decode.string)
      use requested <- decode.field(1, decode.string)
      use withdrawn <- decode.field(2, decode.optional(decode.string))
      decode.success(json.object([
        #("intent_id", json.string(id)),
        #("requested_at", json.string(requested)),
        #("withdrawn_at", context.optional_string(withdrawn)),
      ]))
    },
  ))
  let destinations = case ctx.config.lifecycle_subscriber {
    True -> [#("journal", "pending"), #(journal.subscriber, "pending")]
    False -> [#("journal", "pending")]
  }
  use _ <- result.try(journal.record_to(
    tx,
    account_id,
    "account",
    account_id,
    account.lifecycle_revision,
    action,
    [
      #("lifecycle_revision", json.int(account.lifecycle_revision)),
      #("status", json.string(account.status)),
      #("requested_at", context.optional_string(account.requested_at)),
      #("effective_at", context.optional_string(account.effective_at)),
      #("closure_intents", json.preprocessed_array(intents)),
    ],
    destinations,
  ))
  case account.status {
    "closure_scheduled" -> {
      use _ <- db(jobs.enqueue(
        tx,
        jobs.NewJob(
          ..jobs.new_job(
            "account_closure_deadline",
            "closure_deadline:"
              <> account_id
              <> ":"
              <> int.to_string(account.lifecycle_revision)
              <> ":g0",
          ),
          payload: json.object([
            #("account_id", json.string(account_id)),
            #("lifecycle_revision", json.int(account.lifecycle_revision)),
          ]),
          run_after_seconds: 0,
        ),
      ))
      // Run the deadline job at the effective time (database time).
      use _ <- db(database.execute(
        tx,
        "update jobs set run_after = (select closure_effective_at from accounts where id = $1::uuid)
         where dedupe_key = $2 and state = 'pending'",
        [
          database.text(account_id),
          database.text(
            "closure_deadline:"
            <> account_id
            <> ":"
            <> int.to_string(account.lifecycle_revision)
            <> ":g0",
          ),
        ],
      ))
      Ok(Nil)
    }
    "closing" -> {
      use _ <- db(jobs.enqueue(
        tx,
        jobs.NewJob(
          ..jobs.new_job("account_purge", "account_purge:" <> account_id <> ":g0"),
          payload: json.object([#("account_id", json.string(account_id))]),
          deadline_seconds: Some(3600),
        ),
      ))
      Ok(Nil)
    }
    _ -> Ok(Nil)
  }
}

// Cancellation ----------------------------------------------------------------------

/// `DELETE /v1/account-deletion` with If-Match on the scheduled lifecycle
/// revision. Cancellation must win before the effective time; afterwards it
/// fails even if the deadline job has not run.
pub fn cancel(
  ctx: Context,
  account_id: String,
  expected_revision: Option(Int),
) -> Result(json.Json, AppError) {
  use expected <- result.try(option.to_result(expected_revision, error.precondition_required()))
  use _ <- result.try(context.transaction(ctx, fn(tx) {
    use account <- result.try(load(tx, account_id, True))
    use <- error.guard(
      account.status == "closure_scheduled",
      case account.status {
        "active" -> error.new(409, "closure_not_scheduled", "No account closure is scheduled.")
        _ -> error.account_closing()
      },
    )
    use <- error.guard(account.lifecycle_revision == expected, error.version_conflict())
    use before_deadline <- error.found(database.query_one(
      tx,
      "select now() < closure_effective_at from accounts where id = $1::uuid",
      [database.text(account_id)],
      decode.at([0], decode.bool),
    ))
    use <- error.guard(before_deadline, error.account_closing())
    use _ <- db(database.execute(
      tx,
      "update closure_intents set withdrawn_at = now()
       where account_id = $1::uuid and withdrawn_at is null",
      [database.text(account_id)],
    ))
    use _ <- db(database.execute(
      tx,
      "update accounts set status = 'active', closure_requested_at = null,
         closure_effective_at = null, closure_cap_at = null,
         lifecycle_revision = lifecycle_revision + 1
       where id = $1::uuid",
      [database.text(account_id)],
    ))
    emit(ctx, tx, account_id, "closure_cancelled")
  }))
  status(ctx, account_id)
}

// Export extension ----------------------------------------------------------------------

/// Called in export admission: ensure an export requested during grace
/// keeps a full download window, extending the deadline within the cap, or
/// refuse it. Requires the account row lock.
pub fn extend_for_export(
  ctx: Context,
  tx: Connection,
  account_id: String,
  execution_deadline_seconds: Int,
) -> Result(Nil, AppError) {
  use account <- result.try(load(tx, account_id, False))
  case account.status {
    "closure_scheduled" -> {
      use decision <- error.found(database.query_one(
        tx,
        "select now() + make_interval(secs => $2::int + $3::int) <= closure_cap_at,
           now() + make_interval(secs => $2::int + $3::int) > closure_effective_at,
           rfc3339(closure_cap_at)
         from accounts where id = $1::uuid",
        [
          database.text(account_id),
          database.int(execution_deadline_seconds),
          database.int(ctx.config.exports.download_window_seconds),
        ],
        {
          use fits <- decode.field(0, decode.bool)
          use extends <- decode.field(1, decode.bool)
          use cap <- decode.field(2, decode.string)
          decode.success(#(fits, extends, cap))
        },
      ))
      case decision {
        #(False, _, cap) ->
          Error(
            error.new(
              409,
              "export_exceeds_closure_window",
              "This export could not finish with a 72-hour download window before the account closes.",
            )
            |> error.with_details([#("closure_cap_at", json.string(cap))]),
          )
        #(True, False, _) -> Ok(Nil)
        #(True, True, _) -> {
          use _ <- db(database.execute(
            tx,
            "update accounts set closure_effective_at =
               now() + make_interval(secs => $2::int + $3::int),
               lifecycle_revision = lifecycle_revision + 1
             where id = $1::uuid",
            [
              database.text(account_id),
              database.int(execution_deadline_seconds),
              database.int(ctx.config.exports.download_window_seconds),
            ],
          ))
          emit(ctx, tx, account_id, "closure_rescheduled")
        }
      }
    }
    _ -> Ok(Nil)
  }
}

// Deadline and closing ------------------------------------------------------------------

pub type StageResult {
  Done(summary: String)
  NotYet
  LeaseLost
  /// Progress was committed; run again right away (bounded batches).
  Continue(summary: String)
}

/// Rows deleted per purge transaction from each large table.
pub const purge_batch_size = 2000

fn owned(tx: Connection, job: Job) -> Result(Nil, AppError) {
  use ok <- db(jobs.lock_owned(tx, job))
  case ok {
    True -> Ok(Nil)
    False -> Error(error.new(409, "lease_lost", "job ownership lost"))
  }
}

fn payload_account(job: Job) -> Result(#(String, Int), AppError) {
  json.parse(job.payload, {
    use account <- decode.field("account_id", decode.string)
    use revision <- decode.optional_field("lifecycle_revision", 0, decode.int)
    decode.success(#(account, revision))
  })
  |> result.replace_error(error.internal("invalid closure job payload"))
}

/// The deadline job: enter irreversible `closing` only if the expected
/// scheduled revision is still current and database time reached
/// `effective_at`. Exports still assembling extend the deadline within the
/// cap instead of being cancelled.
pub fn run_deadline(ctx: Context, job: Job) -> Result(StageResult, AppError) {
  use #(account_id, expected) <- result.try(payload_account(job))
  let outcome =
    context.transaction(ctx, fn(tx) {
      use account <- result.try(load(tx, account_id, True))
      use _ <- result.try(quota.lock_usage(tx, account_id))
      use _ <- db(jobs.lock_account_slots(tx, account_id))
      use due <- error.found(database.query_one(
        tx,
        "select coalesce(now() >= closure_effective_at, false) from accounts where id = $1::uuid",
        [database.text(account_id)],
        decode.at([0], decode.bool),
      ))
      use _ <- result.try(owned(tx, job))
      case account.status == "closure_scheduled" && account.lifecycle_revision == expected, due {
        False, _ -> {
          use _ <- db(jobs.complete(tx, job))
          Ok(Done("stale deadline; no-op"))
        }
        True, False -> Ok(NotYet)
        True, True -> {
          use assembling <- db(database.query_one(
            tx,
            "select rfc3339(least(max(e.execution_deadline) + make_interval(secs => $2), a.closure_cap_at)),
               max(e.execution_deadline) + make_interval(secs => $2) > now()
                 and now() < a.closure_cap_at
             from exports e join accounts a on a.id = e.account_id
             where e.account_id = $1::uuid and e.state = 'assembling'
             group by a.closure_cap_at",
            [
              database.text(account_id),
              database.int(ctx.config.exports.download_window_seconds),
            ],
            {
              use at <- decode.field(0, decode.string)
              use extendable <- decode.field(1, decode.bool)
              decode.success(#(at, extendable))
            },
          ))
          case assembling {
            Some(#(at, True)) -> {
              use _ <- db(database.execute(
                tx,
                "update accounts set closure_effective_at = $2::text::timestamptz,
                   lifecycle_revision = lifecycle_revision + 1
                 where id = $1::uuid",
                [database.text(account_id), database.text(at)],
              ))
              use _ <- result.try(emit(ctx, tx, account_id, "closure_rescheduled"))
              use _ <- db(jobs.complete(tx, job))
              Ok(Done("rescheduled for assembling export"))
            }
            _ -> {
              use _ <- result.try(enter_closing(ctx, tx, account_id))
              use _ <- db(jobs.complete(tx, job))
              Ok(Done("closing"))
            }
          }
        }
      }
    })
  case outcome {
    Error(e) if e.code == "lease_lost" -> Ok(LeaseLost)
    other -> other
  }
}

fn enter_closing(ctx: Context, tx: Connection, account_id: String) -> Result(Nil, AppError) {
  use _ <- db(database.execute(
    tx,
    "update accounts set status = 'closing', lifecycle_revision = lifecycle_revision + 1
     where id = $1::uuid",
    [database.text(account_id)],
  ))
  // Revoke application sessions; new URL issuance stops with the status.
  use _ <- db(database.execute(
    tx,
    "update web_sessions set revoked_at = now()
     where account_id = $1::uuid and revoked_at is null and not status_only",
    [database.text(account_id)],
  ))
  // The extension rules make this exceptional; it is logged by the worker.
  use cancelled <- db(database.query(
    tx,
    "update exports set state = 'cancelled', error_code = 'account_closing'
     where account_id = $1::uuid and state in ('assembling', 'completed')
     returning id::text",
    [database.text(account_id)],
    decode.at([0], decode.string),
  ))
  use _ <- result.try(pins.release_export_artifacts(tx, account_id, cancelled, "account_closing"))
  use _ <- result.try(cancel_live_work(tx, account_id))
  // Settle recovery holds: closure releases them, creating no new balance.
  use holds <- db(database.query(
    tx,
    "update recovery_holds h set state = 'released'
     where account_id = $1::uuid and state in ('held', 'claimed')
     returning (select operation_id::text from quota_reservations q where q.id = h.reservation_id)",
    [database.text(account_id)],
    decode.at([0], decode.string),
  ))
  use _ <- result.try(list.try_each(holds, fn(op) {
    quota.release_processing(tx, account_id, op)
  }))
  emit(ctx, tx, account_id, "closing")
}

/// Final purge after the `closing` command is durable in the journal:
/// move lifetime-allowance usage into the keyed identity ledger, erase tenant
/// content, delete identity mappings and record `closed`.
pub fn run_purge(ctx: Context, job: Job) -> Result(StageResult, AppError) {
  use #(account_id, _) <- result.try(payload_account(job))
  use durable <- db(database.query_one(
    ctx.db,
    "select bool_and(state = 'acknowledged') from lifecycle_outbox
     where account_id = $1::uuid and scope_kind = 'account' and destination = 'journal'
       and action = 'closing'",
    [database.text(account_id)],
    decode.at([0], decode.optional(decode.bool)),
  ))
  case option.flatten(durable) {
    Some(True) -> {
      let outcome =
        context.transaction(ctx, fn(tx) {
          use account <- result.try(load(tx, account_id, True))
          use _ <- result.try(owned(tx, job))
          case account.status {
            "closing" -> {
              // Large tables first, in bounded batches across transactions,
              // so a 30,000-page account never needs one huge transaction.
              // The account is already closed to all access, so partial
              // erasure is never visible; a crash resumes where it stopped.
              use batched <- result.try(purge_batch(tx, account_id))
              use <- bool.guard(batched.1 > 0, Ok(Continue("purged " <> int.to_string(batched.1) <> " " <> batched.0 <> " rows")))
              use _ <- result.try(record_identity_ledger(ctx, tx, account_id))
              use _ <- result.try(erase_account(ctx, tx, account_id))
              use _ <- db(database.execute(
                tx,
                "update accounts set status = 'closed', purged_at = now(),
                   lifecycle_revision = lifecycle_revision + 1
                 where id = $1::uuid",
                [database.text(account_id)],
              ))
              use _ <- result.try(emit(ctx, tx, account_id, "closed"))
              use _ <- db(jobs.complete(tx, job))
              Ok(Done("closed and purged"))
            }
            _ -> {
              use _ <- db(jobs.complete(tx, job))
              Ok(Done("not closing; no-op"))
            }
          }
        })
      case outcome {
        Error(e) if e.code == "lease_lost" -> Ok(LeaseLost)
        other -> other
      }
    }
    _ -> Ok(NotYet)
  }
}

/// Delete one batch from the first large table that still has rows for the
/// account. Returns the table and the number of rows removed (0 when done).
fn purge_batch(tx: Connection, account_id: String) -> Result(#(String, Int), AppError) {
  let steps = [
    // Embeddings cascade from their passages.
    #("passages", "delete from passages where account_id = $1::uuid and id in
       (select id from passages where account_id = $1::uuid limit $2)"),
    #("search_release_pages", "delete from search_release_pages where (release_id, page_id) in
       (select release_id, page_id from search_release_pages where account_id = $1::uuid limit $2)"),
    #("usage_events", "delete from usage_events where id in
       (select id from usage_events where account_id = $1::uuid limit $2)"),
    #("content_changes", "delete from content_changes where account_id = $1::uuid and sequence in
       (select sequence from content_changes where account_id = $1::uuid limit $2)"),
    #("idempotency_records", "delete from idempotency_records where account_id = $1::uuid
       and (endpoint, key) in (select endpoint, key from idempotency_records
         where account_id = $1::uuid limit $2)"),
    // Queue storage objects for deletion before their rows go.
    #("object_deletion_queue", "insert into pending_object_deletions (id, bucket, key, reason)
       select gen_random_uuid(), o.bucket, o.key, 'account_purge' from objects o
       where o.account_id = $1::uuid and not exists
         (select 1 from pending_object_deletions p where p.bucket = o.bucket and p.key = o.key)
       limit $2 on conflict (bucket, key) do nothing"),
  ]
  list.fold_until(steps, Ok(#("", 0)), fn(_, step) {
    case database.execute(tx, step.1, [database.text(account_id), database.int(purge_batch_size)]) {
      Error(e) -> list.Stop(Error(error.from_query(e)))
      Ok(0) -> list.Continue(Ok(#("", 0)))
      Ok(n) -> list.Stop(Ok(#(step.0, n)))
    }
  })
}

fn record_identity_ledger(
  ctx: Context,
  tx: Connection,
  account_id: String,
) -> Result(Nil, AppError) {
  use consumed <- error.found(database.query_one(
    tx,
    "select coalesce(sum(used), 0)::int from usage_periods
     where account_id = $1::uuid and kind = 'lifetime'",
    [database.text(account_id)],
    decode.at([0], decode.int),
  ))
  use identities <- db(database.query(
    tx,
    "select i.issuer, i.subject from identities i
     join accounts a on a.owner_user_id = i.user_id where a.id = $1::uuid",
    [database.text(account_id)],
    {
      use issuer <- decode.field(0, decode.string)
      use subject <- decode.field(1, decode.string)
      decode.success(#(issuer, subject))
    },
  ))
  // Reconcile every linked identity to the same consumed total; linking can
  // never reduce it.
  list.try_each(identities, fn(identity_pair) {
    list.try_each(ctx.config.identity_hash_keys, fn(key) {
      let #(key_id, secret) = key
      let hash = identity.identity_key(secret, identity_pair.0, identity_pair.1)
      use _ <- db(database.execute(
        tx,
        "insert into identity_usage_ledger (key_id, identity_key,
           lifetime_units_consumed, account_status, purged_at, delete_after)
         values ($1, $2, $3, 'closed', now(), now() + interval '2 years')
         on conflict (key_id, identity_key) do update set
           lifetime_units_consumed = greatest(
             identity_usage_ledger.lifetime_units_consumed,
             excluded.lifetime_units_consumed),
           account_status = 'closed', purged_at = now(),
           delete_after = now() + interval '2 years', updated_at = now()",
        [database.text(key_id), database.bytea(hash), database.int(consumed)],
      ))
      Ok(Nil)
    })
  })
}

/// Erase all tenant content. Storage objects are queued for deletion in the
/// same transaction. Lifecycle commands, closure intents, tombstones and the
/// account row (status only) are retained for lifecycle subscriber reconciliation.
fn erase_account(ctx: Context, tx: Connection, account_id: String) -> Result(Nil, AppError) {
  let _ = ctx
  let account = [database.text(account_id)]
  use _ <- db(database.execute(
    tx,
    "insert into pending_object_deletions (id, bucket, key, reason)
     select gen_random_uuid(), bucket, key, 'account_purge' from objects
     where account_id = $1::uuid
     on conflict (bucket, key) do nothing",
    account,
  ))
  use exports <- db(database.query(
    tx,
    "select id::text from exports where account_id = $1::uuid",
    account,
    decode.at([0], decode.string),
  ))
  use _ <- result.try(pins.release_export_artifacts(tx, account_id, exports, "account_purge"))
  let statements = [
    "update accounts set active_search_release_id = null where id = $1::uuid",
    "delete from passages where account_id = $1::uuid",
    "delete from search_release_pages where account_id = $1::uuid",
    "delete from index_generations where account_id = $1::uuid",
    "delete from search_releases where account_id = $1::uuid",
    "update page_revisions set selected_transcript_revision_id = null where account_id = $1::uuid",
    "delete from transcript_revisions where account_id = $1::uuid",
    "delete from ocr_results where account_id = $1::uuid",
    "update pages set active_revision_id = null, pending_revision_id = null where account_id = $1::uuid",
    "delete from page_revisions where account_id = $1::uuid",
    "delete from upload_sessions where account_id = $1::uuid",
    "delete from pages where account_id = $1::uuid",
    "delete from notebooks where account_id = $1::uuid",
    "delete from objects where account_id = $1::uuid",
    "delete from exports where account_id = $1::uuid",
    "delete from recovery_holds where account_id = $1::uuid",
    "delete from quota_reservations where account_id = $1::uuid",
    "delete from usage_events where account_id = $1::uuid",
    "delete from operations where account_id = $1::uuid",
    "delete from content_changes where account_id = $1::uuid",
    "delete from idempotency_records where account_id = $1::uuid",
    "delete from job_attempts where job_id in (select id from jobs where account_id = $1::uuid)",
    "delete from job_slot_leases where account_id = $1::uuid",
    "delete from jobs where account_id = $1::uuid",
    "delete from account_job_slots where account_id = $1::uuid",
    "delete from web_sessions where account_id = $1::uuid and not status_only",
    "delete from api_keys where account_id = $1::uuid",
    "delete from coverage_revocations where account_id = $1::uuid",
    "delete from processing_coverage where account_id = $1::uuid",
    "delete from credit_grants where account_id = $1::uuid",
    "delete from usage_periods where account_id = $1::uuid",
    "delete from entitlement_assignments where account_id = $1::uuid",
    "delete from account_usage where account_id = $1::uuid",
    "delete from provider_spend where account_id = $1::uuid",
    "delete from identities where user_id = (select owner_user_id from accounts where id = $1::uuid)",
    "update users set display_name = '', email = null, role = null where id = (select owner_user_id from accounts where id = $1::uuid)",
  ]
  list.try_each(statements, fn(sql) {
    database.execute(tx, sql, account) |> result.map_error(error.from_query) |> result.replace(Nil)
  })
}

// Status --------------------------------------------------------------------------------

/// `GET /v1/account-deletion`: minimal lifecycle and delivery status. Never
/// includes note data.
pub fn status(ctx: Context, account_id: String) -> Result(json.Json, AppError) {
  use account <- result.try(load(ctx.db, account_id, False))
  use latest <- result.try(journal.latest_account_command(ctx.db, account_id))
  let deliveries = case latest {
    Some(#(command_id, revision, states)) ->
      json.object([
        #("command_id", json.string(command_id)),
        #("lifecycle_revision", json.int(revision)),
        #("journal", json.string(list.key_find(states, "journal") |> result.unwrap("none"))),
        ..case list.key_find(states, journal.subscriber) {
          Ok(state) -> [#(journal.subscriber, json.string(state))]
          Error(_) -> []
        }
      ])
    None -> json.null()
  }
  use unconfirmed <- result.try(journal.account_change_unconfirmed(ctx.db, account_id))
  let milestone = case account.status, unconfirmed {
    "closure_scheduled", True -> "closure_scheduled_awaiting_confirmation"
    "closure_scheduled", False -> "closure_scheduled"
    "active", True -> "cancellation_recorded_awaiting_confirmation"
    "active", False -> "active"
    "closing", _ -> "closing_access_revoked"
    "closed", _ -> "closed"
    other, _ -> other
  }
  Ok(json.object([
    #("status", json.string(account.status)),
    #("milestone", json.string(milestone)),
    #("lifecycle_revision", json.int(account.lifecycle_revision)),
    #("requested_at", context.optional_string(account.requested_at)),
    #("effective_at", context.optional_string(account.effective_at)),
    #("closure_cap_at", context.optional_string(account.cap_at)),
    #(
      "purge_status",
      json.string(case account.purged_at {
        Some(_) -> "completed"
        None ->
          case account.status {
            "closing" -> "pending"
            _ -> "not_started"
          }
      }),
    ),
    #("delivery", deliveries),
    #(
      "notice",
      json.string(
        "Reads, searches and exports stay available until the effective time. Download links issued earlier remain usable for up to five minutes after access ends, and copies already downloaded cannot be recalled.",
      ),
    ),
  ]))
}
