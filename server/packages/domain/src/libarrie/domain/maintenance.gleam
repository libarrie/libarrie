//// Periodic maintenance tasks (sections 8, 12, 14 and 16).
////
//// Each task is idempotent and takes the shared lock order. Workers run
//// them as deduplicated, leased `maint:<task>` jobs, one per time bucket, so
//// any number of replicas can schedule them safely (section 8).

import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import libarrie/database
import libarrie/domain/context.{type Context}
import libarrie/domain/deferred
import libarrie/domain/error.{type AppError, db}
import libarrie/domain/expiry
import libarrie/domain/exports
import libarrie/domain/journal
import libarrie/domain/pages
import libarrie/domain/pins
import libarrie/domain/purge
import libarrie/domain/search_migration
import libarrie/domain/ratelimit
import libarrie/domain/uploads
import libarrie/integrations/lifecycle_subscriber
import libarrie/integrations/storage
import libarrie/jobs

pub type Services {
  Services(journal_store: storage.Config, subscriber: Option(lifecycle_subscriber.Client))
}

pub fn services(ctx: Context, subscriber: Option(lifecycle_subscriber.Client)) -> Services {
  Services(journal_store: ctx.config.journal_store, subscriber:)
}

/// Task name and scheduling interval in seconds.
pub const tasks = [
  #("journal", 5), #("lifecycle_subscriber", 10), #("object_deletions", 15), #("uploads", 60),
  #("holds", 60), #("slots", 60), #("exports_expiry", 60), #("trash_expiry", 300),
  #("archive", 600), #("prune", 3600), #("search_migration", 30), #("deferred", 60),
]

pub fn stage(task: String) -> String {
  "maint:" <> task
}

pub fn run(ctx: Context, services: Services, task: String) -> Result(String, AppError) {
  case task {
    "journal" -> ship_journal(ctx, services.journal_store) |> summary("journal events")
    "lifecycle_subscriber" ->
      deliver_lifecycle(ctx, services.subscriber) |> summary("lifecycle commands")
    "object_deletions" -> delete_objects(ctx) |> summary("objects deleted")
    "uploads" -> sweep_uploads(ctx) |> summary("upload accounts swept")
    "holds" -> sweep_holds(ctx) |> summary("recovery holds expired")
    "slots" ->
      jobs.reconcile_slots(ctx.db)
      |> result.map_error(error.from_query)
      |> summary("slot counters repaired")
    "exports_expiry" -> exports.expire(ctx) |> summary("exports expired")
    "trash_expiry" -> purge.expire_trash(ctx, 50) |> summary("trash items expired")
    "archive" ->
      jobs.archive(ctx.db, 3600, 1000)
      |> result.map_error(error.from_query)
      |> summary("jobs archived")
    "prune" -> prune(ctx) |> summary("rows pruned")
    "deferred" -> deferred.run(ctx) |> summary("deferred pages admitted")
    "search_migration" ->
      search_migration.advance(ctx)
      |> result.map(fn(p) { p.caught_up + p.cut_over + p.retired })
      |> summary("search migration steps")
    other -> Error(error.internal("unknown maintenance task " <> other))
  }
}

fn summary(result: Result(Int, AppError), label: String) -> Result(String, AppError) {
  result.map(result, fn(n) { int.to_string(n) <> " " <> label })
}

// Journal shipping (interim journal, section 19) ---------------------------------------

/// Copy each pending lifecycle event as an immutable object to the
/// independent journal store, then acknowledge it. Follow-up actions run
/// only for the delivery that acknowledged the event.
pub fn ship_journal(ctx: Context, store: storage.Config) -> Result(Int, AppError) {
  use events <- result.try(journal.pending_events(ctx.db, "journal", 100))
  list.try_fold(events, 0, fn(count, event) {
    let key = journal.object_key(event)
    let body = bit_array.from_string(event.payload)
    // Write-once: an existing object is never overwritten. A matching copy
    // (for example after a crash between write and acknowledgement) counts
    // as delivered; a different one is an integrity alert.
    let delivered = case storage.put_if_absent(store, key, body, "application/json") {
      Ok(storage.Created) -> Ok(True)
      Ok(storage.AlreadyExists) ->
        case storage.get(store, key) {
          Ok(existing) if existing == body -> Ok(True)
          Ok(_) -> Error("journal object exists with different content: " <> key)
          Error(_) -> Error("journal store unavailable")
        }
      Error(_) -> Error("journal store unavailable")
    }
    case delivered {
      Error(reason) -> {
        use _ <- result.try(journal.defer(ctx.db, event, reason))
        Ok(count)
      }
      Ok(_) -> {
        use first <- result.try(journal.acknowledge(ctx.db, event, key))
        use _ <- result.try(case first {
          True -> after_acknowledgement(ctx, event)
          False -> Ok(Nil)
        })
        Ok(count + 1)
      }
    }
  })
}

fn after_acknowledgement(ctx: Context, event: journal.Event) -> Result(Nil, AppError) {
  case event.action {
    "restore" -> {
      let page_ids =
        json_ids(event.payload, ["pages"], decode.at(["page_id"], decode.string))
      pages.activate_restore(ctx, event.account_id, page_ids) |> result.replace(Nil)
    }
    "purge" -> purge.finalize(ctx, event.account_id, event.payload) |> result.replace(Nil)
    _ -> Ok(Nil)
  }
}

fn json_ids(payload: String, path: List(String), item: decode.Decoder(String)) -> List(String) {
  json.parse(payload, decode.at(path, decode.list(item))) |> result.unwrap([])
}

// Lifecycle subscriber delivery ---------------------------------------------------------

pub fn deliver_lifecycle(ctx: Context, client: Option(lifecycle_subscriber.Client)) -> Result(Int, AppError) {
  use events <- result.try(journal.pending_events(ctx.db, journal.subscriber, 50))
  case client {
    // Subscriber removed at runtime: commands written while it was enabled
    // stay pending and visible rather than being silently dropped.
    None -> Ok(0)
    Some(client) ->
      list.try_fold(events, 0, fn(count, event) {
        case lifecycle_subscriber.deliver(client, event.account_id, event.payload) {
          lifecycle_subscriber.Acknowledged(body) -> {
            use _ <- result.try(journal.acknowledge(ctx.db, event, body))
            Ok(count + 1)
          }
          lifecycle_subscriber.Retryable(detail) -> {
            use _ <- result.try(journal.defer(ctx.db, event, detail))
            Ok(count)
          }
          lifecycle_subscriber.Rejected(status, body) -> {
            // Kept pending with backoff and surfaced for operators.
            use _ <- result.try(journal.defer(
              ctx.db,
              event,
              "rejected " <> int.to_string(status) <> ": " <> body,
            ))
            Ok(count)
          }
        }
      })
  }
}

// Object deletion queue -------------------------------------------------------------------

pub fn delete_objects(ctx: Context) -> Result(Int, AppError) {
  use rows <- db(database.query(
    ctx.db,
    "select id::text, bucket, key from pending_object_deletions
     order by created_at limit 200",
    [],
    {
      use id <- decode.field(0, decode.string)
      use bucket <- decode.field(1, decode.string)
      use key <- decode.field(2, decode.string)
      decode.success(#(id, bucket, key))
    },
  ))
  list.try_fold(rows, 0, fn(count, row) {
    let #(id, bucket, key) = row
    let config = case bucket == pins.export_bucket_marker {
      True -> ctx.config.storage
      False -> storage.Config(..ctx.config.storage, bucket:)
    }
    case storage.delete(config, key) {
      Ok(Nil) -> {
        use _ <- db(database.execute(
          ctx.db,
          "delete from pending_object_deletions where id = $1::uuid",
          [database.text(id)],
        ))
        Ok(count + 1)
      }
      Error(_) -> {
        use _ <- db(database.execute(
          ctx.db,
          "update pending_object_deletions set attempts = attempts + 1 where id = $1::uuid",
          [database.text(id)],
        ))
        Ok(count)
      }
    }
  })
}

// Sweepers --------------------------------------------------------------------------------

fn sweep_uploads(ctx: Context) -> Result(Int, AppError) {
  use accounts <- result.try(expiry.accounts_needing_sweep(ctx.db, 50))
  list.try_each(accounts, fn(account) {
    context.transaction(ctx, fn(tx) {
      use _ <- db(database.execute(
        tx,
        "select 1 from accounts where id = $1::uuid for update",
        [database.text(account)],
      ))
      expiry.expire_abandoned(tx, account, 100)
    })
    |> result.replace(Nil)
  })
  |> result.replace(list.length(accounts))
}

fn sweep_holds(ctx: Context) -> Result(Int, AppError) {
  use accounts <- db(database.query(
    ctx.db,
    "select distinct account_id::text from recovery_holds
     where state = 'held' and claim_deadline <= now() limit 50",
    [],
    decode.at([0], decode.string),
  ))
  list.try_fold(accounts, 0, fn(count, account) {
    use n <- result.try(uploads.expire_holds(ctx, account))
    Ok(count + n)
  })
}

/// Rate-limit windows, identity ledger entries past their two-year
/// retention and tombstones past their retention deadline.
/// Archived jobs past retention, in bounded batches (at most 20 per run).
fn prune_archive(ctx: Context, deleted: Int) -> Result(Int, AppError) {
  let batch = 2000
  use n <- db(jobs.prune_archive(ctx.db, ctx.config.job_archive_retention_days * 86_400, batch))
  case n == batch && deleted < batch * 19 {
    True -> prune_archive(ctx, deleted + n)
    False -> Ok(deleted + n)
  }
}

fn prune(ctx: Context) -> Result(Int, AppError) {
  use counters <- result.try(ratelimit.prune(ctx.db))
  use ledger <- db(database.execute(
    ctx.db,
    "delete from identity_usage_ledger where delete_after <= now()",
    [],
  ))
  use tombstones <- db(database.execute(
    ctx.db,
    "delete from deletion_tombstones where retention_deadline <= now()",
    [],
  ))
  use archived <- result.try(prune_archive(ctx, 0))
  // The content-change log is kept while a shadow release still has to
  // replay it, or a retained release might be rolled back over it.
  use changes <- db(database.execute(
    ctx.db,
    "delete from content_changes c where c.created_at < now() - interval '7 days'
       and not exists (select 1 from search_releases r where r.account_id = c.account_id
         and r.state in ('shadow', 'retired') and r.applied_sequence < c.sequence)",
    [],
  ))
  Ok(counters + ledger + tombstones + archived + changes)
}
