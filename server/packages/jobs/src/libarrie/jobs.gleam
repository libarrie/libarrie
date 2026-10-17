//// Durable Postgres job queue (DESIGN.md section 8).
////
//// Postgres is the queue authority. Claims use short transactions with
//// `FOR UPDATE SKIP LOCKED`; every claim (fresh or reclaim) mints a new random
//// attempt token, increments the attempt count and sets a lease plus a fixed
//// stage deadline. Per-account fairness uses `account_job_slots` plus one
//// token-owned `job_slot_leases` row per claimed job, so concurrent claimers
//// cannot overrun the account's limit.
////
//// Lock order (section 10): account job slots are level 3 and jobs are level
//// 10. Any transaction that finishes a job while holding domain locks must
//// call `lock_account_slots` before locking notebooks/pages, then
//// `lock_owned` last.

import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import libarrie/database.{type Connection, type QueryError}
import youid/uuid

pub type Settings {
  Settings(
    lease_seconds: Int,
    stage_deadline_seconds: Int,
    backoff_base_seconds: Int,
    backoff_cap_seconds: Int,
    default_account_slots: Int,
  )
}

pub fn default_settings() -> Settings {
  Settings(
    lease_seconds: 120,
    stage_deadline_seconds: 300,
    backoff_base_seconds: 5,
    backoff_cap_seconds: 900,
    default_account_slots: 4,
  )
}

pub type NewJob {
  NewJob(
    account_id: Option(String),
    operation_id: Option(String),
    page_id: Option(String),
    revision_id: Option(String),
    transcript_revision_id: Option(String),
    configuration_id: Option(String),
    stage: String,
    payload: json.Json,
    dedupe_key: String,
    max_attempts: Int,
    run_after_seconds: Int,
    /// Overrides the default fixed stage deadline (for example exports).
    deadline_seconds: Option(Int),
  )
}

pub fn new_job(stage: String, dedupe_key: String) -> NewJob {
  NewJob(
    account_id: None,
    operation_id: None,
    page_id: None,
    revision_id: None,
    transcript_revision_id: None,
    configuration_id: None,
    stage:,
    payload: json.object([]),
    dedupe_key:,
    max_attempts: 5,
    run_after_seconds: 0,
    deadline_seconds: None,
  )
}

pub type Job {
  Job(
    id: String,
    account_id: Option(String),
    operation_id: Option(String),
    page_id: Option(String),
    revision_id: Option(String),
    transcript_revision_id: Option(String),
    configuration_id: Option(String),
    stage: String,
    payload: String,
    attempts: Int,
    max_attempts: Int,
    attempt_token: String,
    replay_generation: Int,
  )
}

/// True when this claim exceeded the attempt budget. The handler must run its
/// terminal failure path instead of doing the stage's work.
pub fn exhausted(job: Job) -> Bool {
  job.attempts > job.max_attempts
}

const job_columns = "id::text, account_id::text, operation_id::text, page_id::text,
  revision_id::text, transcript_revision_id::text, configuration_id::text, stage,
  payload::text, attempts, max_attempts, attempt_token::text, replay_generation"

fn job_decoder() -> decode.Decoder(Job) {
  use id <- decode.field(0, decode.string)
  use account_id <- decode.field(1, decode.optional(decode.string))
  use operation_id <- decode.field(2, decode.optional(decode.string))
  use page_id <- decode.field(3, decode.optional(decode.string))
  use revision_id <- decode.field(4, decode.optional(decode.string))
  use transcript_revision_id <- decode.field(5, decode.optional(decode.string))
  use configuration_id <- decode.field(6, decode.optional(decode.string))
  use stage <- decode.field(7, decode.string)
  use payload <- decode.field(8, decode.string)
  use attempts <- decode.field(9, decode.int)
  use max_attempts <- decode.field(10, decode.int)
  use attempt_token <- decode.field(11, decode.optional(decode.string))
  use replay_generation <- decode.field(12, decode.int)
  decode.success(Job(
    id:,
    account_id:,
    operation_id:,
    page_id:,
    revision_id:,
    transcript_revision_id:,
    configuration_id:,
    stage:,
    payload:,
    attempts:,
    max_attempts:,
    attempt_token: option.unwrap(attempt_token, ""),
    replay_generation:,
  ))
}

/// Enqueue a job unless a non-terminal job with the same dedupe key exists.
/// Returns the new job ID, or `None` when deduplicated. Call inside the same
/// transaction as the state change that requires the work.
pub fn enqueue(conn: Connection, job: NewJob) -> Result(Option(String), QueryError) {
  let id = uuid.v7_string()
  database.query_one(
    conn,
    "insert into jobs (id, account_id, operation_id, page_id, revision_id,
       transcript_revision_id, configuration_id, stage, payload, dedupe_key,
       state, max_attempts, run_after, deadline_seconds)
     values ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6::uuid,
       $7::uuid, $8, $9::jsonb, $10, 'pending', $11,
       now() + make_interval(secs => $12), $13)
     on conflict (dedupe_key) where state in ('pending', 'running', 'retryable')
     do nothing
     returning id::text",
    [
      database.text(id),
      database.nullable_text(job.account_id),
      database.nullable_text(job.operation_id),
      database.nullable_text(job.page_id),
      database.nullable_text(job.revision_id),
      database.nullable_text(job.transcript_revision_id),
      database.nullable_text(job.configuration_id),
      database.text(job.stage),
      database.text(json.to_string(job.payload)),
      database.text(job.dedupe_key),
      database.int(job.max_attempts),
      database.int(job.run_after_seconds),
      database.nullable_int(job.deadline_seconds),
    ],
    decode.at([0], decode.string),
  )
}

/// Enqueue a periodic job for a time bucket at most once, across every job
/// state (including archived and terminal jobs still in the table), so many
/// replicas can schedule maintenance without running it twice per bucket.
pub fn enqueue_periodic(
  conn: Connection,
  stage: String,
  bucket: String,
  deadline_seconds: Option(Int),
) -> Result(Option(String), QueryError) {
  let key = "periodic:" <> stage <> ":" <> bucket <> ":g0"
  database.query_one(
    conn,
    "insert into jobs (id, stage, dedupe_key, state, max_attempts, deadline_seconds)
     select $1::uuid, $2, $3, 'pending', 3, $4
     where not exists (select 1 from jobs where dedupe_key = $3)
       and not exists (select 1 from jobs_archive where dedupe_key = $3)
     on conflict (dedupe_key) where state in ('pending', 'running', 'retryable')
     do nothing
     returning id::text",
    [
      database.text(uuid.v7_string()),
      database.text(stage),
      database.text(key),
      database.nullable_int(deadline_seconds),
    ],
    decode.at([0], decode.string),
  )
}

/// Move terminal jobs older than `age_seconds` (and their attempts) into the
/// archive tables so claim scans stay small. Returns the number archived.
/// Delete archived jobs (and their attempts) last updated more than
/// `age_seconds` ago, at most `limit` per call. Returns the jobs deleted.
pub fn prune_archive(conn: Connection, age_seconds: Int, limit: Int) -> Result(Int, QueryError) {
  let deleted = database.transaction(conn, fn(tx) {
    use ids <- result.try(database.query(
      tx,
      "select id::text from jobs_archive
       where updated_at < now() - make_interval(secs => $1)
       order by updated_at limit $2",
      [database.int(age_seconds), database.int(limit)],
      decode.at([0], decode.string),
    ))
    let params = [database.text_array(ids)]
    use _ <- result.try(database.execute(
      tx,
      "delete from job_attempts_archive where job_id = any($1::uuid[])",
      params,
    ))
    database.execute(tx, "delete from jobs_archive where id = any($1::uuid[])", params)
  })
  case deleted {
    Ok(n) -> Ok(n)
    Error(database.QueryFailed(e)) -> Error(e)
    Error(database.Aborted(e)) -> Error(e)
  }
}

pub fn archive(
  conn: Connection,
  age_seconds: Int,
  limit: Int,
) -> Result(Int, QueryError) {
  let moved =
    database.transaction(conn, fn(tx) {
      use ids <- result.try(database.query(
        tx,
        "select id::text from jobs
         where state in ('succeeded', 'failed', 'cancelled')
           and updated_at < now() - make_interval(secs => $1)
         order by updated_at limit $2 for update skip locked",
        [database.int(age_seconds), database.int(limit)],
        decode.at([0], decode.string),
      ))
      let params = [database.text_array(ids)]
      use _ <- result.try(database.execute(
        tx,
        "insert into job_attempts_archive select * from job_attempts
         where job_id = any($1::uuid[])",
        params,
      ))
      use _ <- result.try(database.execute(
        tx,
        "delete from job_attempts where job_id = any($1::uuid[])",
        params,
      ))
      use _ <- result.try(database.execute(
        tx,
        "delete from job_slot_leases where job_id = any($1::uuid[]) and state = 'released'",
        params,
      ))
      use _ <- result.try(database.execute(
        tx,
        "insert into jobs_archive select * from jobs where id = any($1::uuid[])",
        params,
      ))
      database.execute(tx, "delete from jobs where id = any($1::uuid[])
        and not exists (select 1 from job_slot_leases l where l.job_id = jobs.id)", params)
    })
  case moved {
    Ok(n) -> Ok(n)
    Error(database.QueryFailed(e)) -> Error(e)
    Error(database.Aborted(e)) -> Error(e)
  }
}

/// Claim up to `limit` jobs for `owner_id`. Candidates are read without locks;
/// each is then claimed in its own short transaction that locks the account
/// slot row before the job row and rechecks eligibility.
pub fn claim(
  conn: Connection,
  owner_id: String,
  stages: List(String),
  settings: Settings,
  limit: Int,
) -> Result(List(Job), QueryError) {
  use candidates <- result.try(database.query(
    conn,
    "select id::text, account_id::text from jobs
     where stage = any($1::text[])
       and ((state in ('pending', 'retryable') and run_after <= now())
         or (state = 'running' and lease_expires_at <= now()))
     order by run_after, id
     limit $2",
    [database.text_array(stages), database.int(limit * 4)],
    {
      use id <- decode.field(0, decode.string)
      use account_id <- decode.field(1, decode.optional(decode.string))
      decode.success(#(id, account_id))
    },
  ))
  candidates
  |> list.try_fold([], fn(claimed, candidate) {
    case list.length(claimed) >= limit {
      True -> Ok(claimed)
      False -> {
        let #(job_id, account_id) = candidate
        case claim_one(conn, owner_id, job_id, account_id, settings) {
          Ok(Some(job)) -> Ok([job, ..claimed])
          Ok(None) -> Ok(claimed)
          Error(e) ->
            case database.is_transient(e) {
              True -> Ok(claimed)
              False -> Error(e)
            }
        }
      }
    }
  })
  |> result.map(list.reverse)
}

type Candidate {
  Fresh
  Reclaim(old_token: Option(String))
}

fn claim_one(
  conn: Connection,
  owner_id: String,
  job_id: String,
  account_id: Option(String),
  settings: Settings,
) -> Result(Option(Job), QueryError) {
  let outcome =
    database.transaction(conn, fn(tx) {
      // Level 3: the account slot row, created on demand.
      use slots <- result.try(case account_id {
        None -> Ok(None)
        Some(account) -> {
          use _ <- result.try(database.execute(
            tx,
            "insert into account_job_slots (account_id, occupied, slot_limit)
             values ($1::uuid, 0, $2) on conflict do nothing",
            [database.text(account), database.int(settings.default_account_slots)],
          ))
          database.query_one(
            tx,
            "select occupied, slot_limit from account_job_slots
             where account_id = $1::uuid for update",
            [database.text(account)],
            {
              use occupied <- decode.field(0, decode.int)
              use slot_limit <- decode.field(1, decode.int)
              decode.success(#(occupied, slot_limit))
            },
          )
        }
      })
      // Level 10: the job itself, rechecking eligibility under lock.
      use found <- result.try(database.query_one(
        tx,
        "select case
           when state in ('pending', 'retryable') and run_after <= now() then 'fresh'
           when state = 'running' and lease_expires_at <= now() then 'reclaim'
           else 'ineligible' end,
           attempt_token::text
         from jobs where id = $1::uuid for update skip locked",
        [database.text(job_id)],
        {
          use kind <- decode.field(0, decode.string)
          use token <- decode.field(1, decode.optional(decode.string))
          decode.success(#(kind, token))
        },
      ))
      let candidate = case found {
        Some(#("fresh", _)) -> Some(Fresh)
        Some(#("reclaim", token)) -> Some(Reclaim(token))
        _ -> None
      }
      case candidate, slots, account_id {
        None, _, _ -> Ok(None)
        // Fresh claims need spare capacity; reclaims transfer the existing
        // lease and never need spare capacity.
        Some(Fresh), Some(#(occupied, slot_limit)), Some(_)
          if occupied >= slot_limit
        -> Ok(None)
        Some(kind), _, _ -> {
          let token = uuid.v4_string()
          use _ <- result.try(case kind, account_id {
            Fresh, Some(account) -> {
              use _ <- result.try(database.execute(
                tx,
                "update account_job_slots set occupied = occupied + 1
                 where account_id = $1::uuid",
                [database.text(account)],
              ))
              database.execute(
                tx,
                "insert into job_slot_leases (job_id, account_id, attempt_token, state)
                 values ($1::uuid, $2::uuid, $3::uuid, 'live')
                 on conflict (job_id) do update
                   set attempt_token = excluded.attempt_token, state = 'live'",
                [database.text(job_id), database.text(account), database.text(token)],
              )
            }
            Reclaim(old), Some(account) -> transfer_lease(tx, job_id, account, old, token)
            _, None -> Ok(0)
          })
          use job <- result.try(database.query_one(
            tx,
            "update jobs set state = 'running', attempts = attempts + 1,
               owner_id = $2, attempt_token = $3::uuid, heartbeat_at = now(),
               lease_expires_at = now() + make_interval(secs => $4),
               stage_deadline = now() + make_interval(secs => coalesce(deadline_seconds, $5)),
               updated_at = now()
             where id = $1::uuid
             returning " <> job_columns,
            [
              database.text(job_id),
              database.text(owner_id),
              database.text(token),
              database.int(settings.lease_seconds),
              database.int(settings.stage_deadline_seconds),
            ],
            job_decoder(),
          ))
          use _ <- result.try(case job {
            Some(job) ->
              database.execute(
                tx,
                "update job_attempts set finished_at = now(), outcome = 'lease_expired'
                 where job_id = $1::uuid and finished_at is null",
                [database.text(job_id)],
              )
              |> result.try(fn(_) {
                database.execute(
                  tx,
                  "insert into job_attempts (job_id, attempt_number, token, owner_id)
                   values ($1::uuid, $2, $3::uuid, $4)
                   on conflict do nothing",
                  [
                    database.text(job_id),
                    database.int(job.attempts),
                    database.text(token),
                    database.text(owner_id),
                  ],
                )
              })
            None -> Ok(0)
          })
          Ok(job)
        }
      }
    })
  case outcome {
    Ok(job) -> Ok(job)
    Error(database.QueryFailed(e)) -> Error(e)
    Error(database.Aborted(e)) -> Error(e)
  }
}

/// Move a live slot lease to a new attempt token, leaving `occupied`
/// unchanged. A missing lease (for example after manual repair) is recreated
/// and counted so the counter matches the lease rows.
fn transfer_lease(
  tx: Connection,
  job_id: String,
  account: String,
  old_token: Option(String),
  token: String,
) -> Result(Int, QueryError) {
  use moved <- result.try(database.execute(
    tx,
    "update job_slot_leases set attempt_token = $2::uuid
     where job_id = $1::uuid and state = 'live'
       and attempt_token is not distinct from $3::uuid",
    [database.text(job_id), database.text(token), database.nullable_text(old_token)],
  ))
  case moved {
    0 -> {
      use _ <- result.try(database.execute(
        tx,
        "update account_job_slots set occupied = occupied + 1
         where account_id = $1::uuid",
        [database.text(account)],
      ))
      database.execute(
        tx,
        "insert into job_slot_leases (job_id, account_id, attempt_token, state)
         values ($1::uuid, $2::uuid, $3::uuid, 'live')
         on conflict (job_id) do update
           set attempt_token = excluded.attempt_token, state = 'live'",
        [database.text(job_id), database.text(account), database.text(token)],
      )
    }
    n -> Ok(n)
  }
}

/// Renew the lease. Returns False when ownership is lost: the token changed,
/// the job left `running`, the lease already expired or the fixed stage
/// deadline passed. An expired owner can never revive itself.
pub fn heartbeat(
  conn: Connection,
  job: Job,
  settings: Settings,
) -> Result(Bool, QueryError) {
  database.execute(
    conn,
    "update jobs set heartbeat_at = now(),
       lease_expires_at = least(now() + make_interval(secs => $3), stage_deadline)
     where id = $1::uuid and attempt_token = $2::uuid and state = 'running'
       and lease_expires_at > now() and stage_deadline > now()",
    [
      database.text(job.id),
      database.text(job.attempt_token),
      database.int(settings.lease_seconds),
    ],
  )
  |> result.map(fn(count) { count == 1 })
}

/// Lock the account slot row (lock level 3). Call before notebook/page locks
/// in any transaction that will finish, retry or cancel jobs.
pub fn lock_account_slots(
  conn: Connection,
  account_id: String,
) -> Result(Nil, QueryError) {
  database.execute(
    conn,
    "select 1 from account_job_slots where account_id = $1::uuid for update",
    [database.text(account_id)],
  )
  |> result.replace(Nil)
}

/// Lock the job row (lock level 10) and verify the caller still owns a live,
/// unexpired attempt. Results must be discarded when this returns False.
pub fn lock_owned(conn: Connection, job: Job) -> Result(Bool, QueryError) {
  database.query_one(
    conn,
    "select attempt_token = $2::uuid and state = 'running'
        and lease_expires_at > now() and stage_deadline > now()
     from jobs where id = $1::uuid for update",
    [database.text(job.id), database.text(job.attempt_token)],
    decode.at([0], decode.bool),
  )
  |> result.map(option.unwrap(_, False))
}

/// Release the slot lease held by `token`, once. A stale token cannot release
/// its successor's slot.
fn release_slot(
  conn: Connection,
  job_id: String,
  token: String,
) -> Result(Nil, QueryError) {
  use released <- result.try(database.query(
    conn,
    "update job_slot_leases set state = 'released'
     where job_id = $1::uuid and attempt_token = $2::uuid and state = 'live'
     returning account_id::text",
    [database.text(job_id), database.text(token)],
    decode.at([0], decode.string),
  ))
  list.try_each(released, fn(account) {
    database.execute(
      conn,
      "update account_job_slots set occupied = occupied - 1
       where account_id = $1::uuid and occupied > 0",
      [database.text(account)],
    )
  })
}

fn finish_attempt(
  conn: Connection,
  job: Job,
  outcome: String,
  error: Option(String),
) -> Result(Nil, QueryError) {
  database.execute(
    conn,
    "update job_attempts set finished_at = now(), outcome = $3, sanitized_error = $4
     where job_id = $1::uuid and token = $2::uuid and finished_at is null",
    [
      database.text(job.id),
      database.text(job.attempt_token),
      database.text(outcome),
      database.nullable_text(error),
    ],
  )
  |> result.replace(Nil)
}

/// Mark an owned job succeeded. Requires `lock_owned` in the same transaction.
pub fn complete(conn: Connection, job: Job) -> Result(Nil, QueryError) {
  use _ <- result.try(database.execute(
    conn,
    "update jobs set state = 'succeeded', lease_expires_at = null, updated_at = now()
     where id = $1::uuid and attempt_token = $2::uuid",
    [database.text(job.id), database.text(job.attempt_token)],
  ))
  use _ <- result.try(finish_attempt(conn, job, "succeeded", None))
  release_slot(conn, job.id, job.attempt_token)
}

/// Mark an owned job terminally failed.
pub fn fail(conn: Connection, job: Job, error: String) -> Result(Nil, QueryError) {
  use _ <- result.try(database.execute(
    conn,
    "update jobs set state = 'failed', last_error = $3, lease_expires_at = null,
       updated_at = now()
     where id = $1::uuid and attempt_token = $2::uuid",
    [database.text(job.id), database.text(job.attempt_token), database.text(error)],
  ))
  use _ <- result.try(finish_attempt(conn, job, "failed", Some(error)))
  release_slot(conn, job.id, job.attempt_token)
}

/// Schedule another attempt with exponential backoff and jitter.
pub fn retry(
  conn: Connection,
  job: Job,
  error: String,
  settings: Settings,
) -> Result(Nil, QueryError) {
  let delay = backoff_seconds(job.attempts, settings)
  use _ <- result.try(database.execute(
    conn,
    "update jobs set state = 'retryable', last_error = $3, lease_expires_at = null,
       run_after = now() + make_interval(secs => $4), updated_at = now()
     where id = $1::uuid and attempt_token = $2::uuid",
    [
      database.text(job.id),
      database.text(job.attempt_token),
      database.text(error),
      database.int(delay),
    ],
  ))
  use _ <- result.try(finish_attempt(conn, job, "retry", Some(error)))
  release_slot(conn, job.id, job.attempt_token)
}

/// Postpone an owned job without spending an attempt (budget pauses,
/// provider circuits or permit waits are not failures of the job).
pub fn postpone(
  conn: Connection,
  job: Job,
  reason: String,
  seconds: Int,
) -> Result(Nil, QueryError) {
  use _ <- result.try(database.execute(
    conn,
    "update jobs set state = 'retryable', last_error = $3, lease_expires_at = null,
       attempts = greatest(attempts - 1, 0),
       run_after = now() + make_interval(secs => $4), updated_at = now()
     where id = $1::uuid and attempt_token = $2::uuid",
    [
      database.text(job.id),
      database.text(job.attempt_token),
      database.text(reason),
      database.int(seconds),
    ],
  ))
  use _ <- result.try(finish_attempt(conn, job, "postponed", Some(reason)))
  release_slot(conn, job.id, job.attempt_token)
}

/// Exponential backoff with full jitter, capped.
pub fn backoff_seconds(attempts: Int, settings: Settings) -> Int {
  let exponent = int.min(attempts, 16)
  let ceiling =
    int.min(
      settings.backoff_cap_seconds,
      settings.backoff_base_seconds * int.bitwise_shift_left(1, exponent),
    )
  int.max(1, float.round(int.to_float(ceiling) *. { 0.5 +. float.random() /. 2.0 }))
}

/// Cancel every non-terminal job for an operation, releasing live slots held
/// by their current tokens. Call with the account slot row already locked.
pub fn cancel_for_operation(
  conn: Connection,
  account_id: String,
  operation_id: String,
) -> Result(Nil, QueryError) {
  use cancelled <- result.try(database.query(
    conn,
    "update jobs set state = 'cancelled', lease_expires_at = null, updated_at = now()
     where account_id = $1::uuid and operation_id = $2::uuid
       and state in ('pending', 'running', 'retryable')
     returning id::text, attempt_token::text",
    [database.text(account_id), database.text(operation_id)],
    {
      use id <- decode.field(0, decode.string)
      use token <- decode.field(1, decode.optional(decode.string))
      decode.success(#(id, token))
    },
  ))
  list.try_each(cancelled, fn(row) {
    case row {
      #(id, Some(token)) -> release_slot(conn, id, token)
      #(_, None) -> Ok(Nil)
    }
  })
}

/// Cancel non-terminal jobs matching a page and stage (for example obsolete
/// correction indexing superseded by a newer transcript).
pub fn cancel_for_page_stage(
  conn: Connection,
  account_id: String,
  page_id: String,
  stage: String,
) -> Result(Nil, QueryError) {
  use cancelled <- result.try(database.query(
    conn,
    "update jobs set state = 'cancelled', lease_expires_at = null, updated_at = now()
     where account_id = $1::uuid and page_id = $2::uuid and stage = $3
       and operation_id is null
       and state in ('pending', 'running', 'retryable')
     returning id::text, attempt_token::text",
    [database.text(account_id), database.text(page_id), database.text(stage)],
    {
      use id <- decode.field(0, decode.string)
      use token <- decode.field(1, decode.optional(decode.string))
      decode.success(#(id, token))
    },
  ))
  list.try_each(cancelled, fn(row) {
    case row {
      #(id, Some(token)) -> release_slot(conn, id, token)
      #(_, None) -> Ok(Nil)
    }
  })
}

/// Administrator replay of a terminal job: enqueue the same logical work
/// under the next replay generation. A live duplicate stays impossible
/// because the dedupe key includes the generation and is unique only among
/// non-terminal jobs.
pub fn replay(conn: Connection, job_id: String) -> Result(Option(String), QueryError) {
  database.query_one(
    conn,
    "insert into jobs (id, account_id, operation_id, page_id, revision_id,
       transcript_revision_id, configuration_id, stage, payload, dedupe_key,
       replay_generation, state, max_attempts)
     select $2::uuid, account_id, operation_id, page_id, revision_id,
       transcript_revision_id, configuration_id, stage, payload,
       regexp_replace(dedupe_key, ':g[0-9]+$', '') || ':g' || (replay_generation + 1),
       replay_generation + 1, 'pending', max_attempts
     from jobs where id = $1::uuid and state in ('failed', 'cancelled')
     on conflict (dedupe_key) where state in ('pending', 'running', 'retryable')
     do nothing
     returning id::text",
    [database.text(job_id), database.text(uuid.v7_string())],
    decode.at([0], decode.string),
  )
}

/// Repair `account_job_slots.occupied` from live lease rows. Uses the same lock
/// order as claims: slot rows first. Reports how many rows drifted.
pub fn reconcile_slots(conn: Connection) -> Result(Int, QueryError) {
  database.execute(
    conn,
    "with live as (
       select account_id, count(*)::int as n from job_slot_leases
       where state = 'live' group by account_id)
     update account_job_slots s set occupied = coalesce(live.n, 0)
     from account_job_slots s2 left join live on live.account_id = s2.account_id
     where s.account_id = s2.account_id and s.occupied <> coalesce(live.n, 0)",
    [],
  )
}
