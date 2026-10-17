//// Journal replay after a database restore (section 14).
////
//// Before a recovered deployment serves traffic, processes jobs or sends
//// lifecycle subscriber commands, operators run `libarrie_api journal-replay`. It:
////
//// 1. lists the independent journal (write-once objects keyed by sequence);
////    if the journal cannot be listed, recovery stays closed;
//// 2. checks coverage: every lifecycle event the restored database already
////    recorded as delivered must exist in the journal, otherwise there is a
////    gap and recovery stays closed;
//// 3. re-applies, in sequence order, every journal event the restored
////    snapshot does not know about (deletions, restores, purges and account
////    lifecycle revisions made after the recovery point), idempotently and
////    without writing new journal intents;
//// 4. reconciles usage counters from effective visibility.
////
//// Events already reflected in the snapshot are skipped: an outbox row and
//// its local state change commit in the same transaction.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import libarrie/database.{type Connection}
import libarrie/domain/accounts
import libarrie/domain/context.{type Context}
import libarrie/domain/error.{type AppError, db}
import libarrie/domain/purge
import libarrie/integrations/storage
import libarrie/jobs

pub const prefix = "journal/v1/"

pub type Report {
  Report(
    journal_events: Int,
    already_applied: Int,
    replayed: Int,
    conflicts: List(String),
  )
}

pub type Refusal {
  JournalUnavailable(detail: String)
  CoverageGap(missing_keys: List(String))
  ReplayFailed(detail: String)
}

pub fn refusal_message(refusal: Refusal) -> String {
  case refusal {
    JournalUnavailable(detail) -> "journal unavailable: " <> detail
    CoverageGap(keys) ->
      "journal coverage gap: "
      <> int.to_string(list.length(keys))
      <> " delivered event(s) missing, e.g. "
      <> string.join(list.take(keys, 3), ", ")
    ReplayFailed(detail) -> "replay failed: " <> detail
  }
}

/// Every journal key, in replay order.
pub fn list_journal(store: storage.Config) -> Result(List(String), Refusal) {
  do_list(store, None, [])
}

fn do_list(
  store: storage.Config,
  token: Option(String),
  acc: List(List(String)),
) -> Result(List(String), Refusal) {
  case storage.list_objects(store, prefix, token) {
    Error(e) -> Error(JournalUnavailable(string.inspect(e)))
    Ok(listing) -> {
      let acc = [listing.keys, ..acc]
      case listing.next_token {
        Some(next) -> do_list(store, Some(next), acc)
        None -> Ok(acc |> list.reverse |> list.flatten |> list.sort(string.compare))
      }
    }
  }
}

pub fn replay(ctx: Context) -> Result(Report, Refusal) {
  let store = ctx.config.journal_store
  // Coverage: delivered events recorded by the snapshot must be in the journal.
  use delivered <- result.try(
    database.query(
      ctx.db,
      "select acknowledgement from lifecycle_outbox
       where destination = 'journal' and state = 'acknowledged'
         and acknowledgement like 'journal/v1/%'",
      [],
      decode.at([0], decode.string),
    )
    |> result.map_error(fn(e) { ReplayFailed(database.describe(e)) }),
  )
  // Listed after reading the delivered set: an event's object is written
  // before its acknowledgement, so anything acknowledged above is already
  // in this listing unless the journal really lost it.
  use keys <- result.try(list_journal(store))
  let present = set.from_list(keys)
  let missing = list.filter(delivered, fn(key) { !set.contains(present, key) })
  use <- bool_guard(missing == [], Error(CoverageGap(missing)))
  use known <- result.try(
    database.query(
      ctx.db,
      "select command_id::text from lifecycle_outbox where destination = 'journal'",
      [],
      decode.at([0], decode.string),
    )
    |> result.map_error(fn(e) { ReplayFailed(database.describe(e)) }),
  )
  let known = set.from_list(known)
  list.try_fold(keys, Report(list.length(keys), 0, 0, []), fn(report, key) {
    let command_id = command_id_from_key(key)
    case set.contains(known, command_id) {
      True -> Ok(Report(..report, already_applied: report.already_applied + 1))
      False -> {
        use body <- result.try(
          storage.get(store, key)
          |> result.map_error(fn(e) { JournalUnavailable(string.inspect(e)) }),
        )
        use outcome <- result.try(
          apply_event(ctx, key, body)
          |> result.map_error(fn(e) { ReplayFailed(key <> ": " <> e.code) }),
        )
        Ok(Report(
          ..report,
          replayed: report.replayed + 1,
          conflicts: list.append(report.conflicts, outcome),
        ))
      }
    }
  })
}

fn bool_guard(condition: Bool, otherwise: a, next: fn() -> a) -> a {
  case condition {
    True -> next()
    False -> otherwise
  }
}

/// `journal/v1/<sequence>-<command_id>.json`
fn command_id_from_key(key: String) -> String {
  key
  |> string.drop_start(string.length(prefix) + 21)
  |> string.drop_end(5)
}

fn sequence_from_key(key: String) -> Int {
  key
  |> string.drop_start(string.length(prefix))
  |> string.slice(0, 20)
  |> int.parse
  |> result.unwrap(0)
}

type Event {
  Event(
    command_id: String,
    account_id: String,
    scope_kind: String,
    scope_id: String,
    action: String,
  )
}

fn ids(body: String, field: String) -> List(String) {
  json.parse(body, decode.at([field], decode.list(decode.string))) |> result.unwrap([])
}

/// Apply one event idempotently and record it as delivered. Returns
/// human-readable conflicts (for example a restore whose page number is now
/// taken: the page stays hidden rather than exposing the wrong state).
fn apply_event(ctx: Context, key: String, raw: BitArray) -> Result(List(String), AppError) {
  use text <- result.try(
    bit_array.to_string(raw) |> result.replace_error(error.internal("journal object not UTF-8")),
  )
  use event <- result.try(
    json.parse(text, {
      use command_id <- decode.field("command_id", decode.string)
      use account_id <- decode.field("account_id", decode.string)
      use scope_kind <- decode.field("scope_kind", decode.string)
      use scope_id <- decode.field("scope_id", decode.string)
      use action <- decode.field("action", decode.string)
      decode.success(Event(command_id, account_id, scope_kind, scope_id, action))
    })
    |> result.replace_error(error.internal("journal object is not an event")),
  )
  use exists <- db(database.query_one(
    ctx.db,
    "select 1 from accounts where id = $1::uuid",
    [database.text(event.account_id)],
    decode.at([0], decode.int),
  ))
  case exists {
    // The account itself predates the snapshot; nothing to apply to.
    None -> record(ctx, key, event, text) |> result.replace(["account missing: " <> event.account_id])
    Some(_) -> {
      use conflicts <- result.try(context.transaction(ctx, fn(tx) {
        use _ <- result.try(accounts.lock(tx, event.account_id))
        use conflicts <- result.try(case event.scope_kind, event.action {
          "page", "trash" -> trash_pages(tx, event.account_id, [event.scope_id])
          "notebook", "trash" -> {
            use _ <- db(database.execute(
              tx,
              "update notebooks set deleted_at = coalesce(deleted_at, now()),
                 deletion_batch_id = coalesce(deletion_batch_id, $3::uuid)
               where account_id = $1::uuid and id = $2::uuid",
              [
                database.text(event.account_id),
                database.text(event.scope_id),
                database.text(json_string(text, "deletion_batch_id") |> option.unwrap(event.command_id)),
              ],
            ))
            trash_pages(tx, event.account_id, ids(text, "page_ids"))
          }
          _, "restore" -> restore_pages(tx, event, text)
          "trash_set", "purge" | "source_revision", "purge" -> mark_purge(tx, event, text)
          "account", _ -> apply_account(tx, event, text)
          _, _ -> Ok([])
        })
        use _ <- result.try(reconcile_usage(tx, event.account_id))
        Ok(conflicts)
      }))
      use _ <- result.try(record(ctx, key, event, text))
      // Physical erasure runs after the purge intent is recorded as delivered.
      use _ <- result.try(case event.action {
        "purge" -> purge.finalize(ctx, event.account_id, text) |> result.replace(Nil)
        _ -> Ok(Nil)
      })
      Ok(conflicts)
    }
  }
}

fn json_string(text: String, field: String) -> Option(String) {
  json.parse(text, decode.at([field], decode.string)) |> option.from_result
}

fn trash_pages(tx: Connection, account_id: String, page_ids: List(String)) -> Result(List(String), AppError) {
  use _ <- db(database.execute(
    tx,
    "update pages set visibility = 'trashed', deleted_at = coalesce(deleted_at, now()),
       awaiting_processing = false, version = version + 1, updated_at = now()
     where account_id = $1::uuid and id = any($2::uuid[]) and visibility <> 'trashed'",
    [database.text(account_id), database.text_array(page_ids)],
  ))
  // Pending work on hidden pages cannot publish.
  use _ <- db(database.execute(
    tx,
    "update operations set status = 'deleted', updated_at = now()
     where account_id = $1::uuid and page_id = any($2::uuid[])
       and status in ('awaiting_upload', 'validating', 'queued', 'recognizing', 'indexing')",
    [database.text(account_id), database.text_array(page_ids)],
  ))
  Ok([])
}

fn restore_pages(tx: Connection, event: Event, text: String) -> Result(List(String), AppError) {
  let targets =
    json.parse(
      text,
      decode.at(
        ["pages"],
        decode.list({
          use page_id <- decode.field("page_id", decode.string)
          use notebook_id <- decode.field("notebook_id", decode.string)
          use number <- decode.field("page_number", decode.int)
          decode.success(#(page_id, notebook_id, number))
        }),
      ),
    )
    |> result.unwrap([])
  use _ <- db(database.execute(
    tx,
    "update notebooks set deleted_at = null, deletion_batch_id = null
     where account_id = $1::uuid and id = $2::uuid and $3 = 'notebook'",
    [
      database.text(event.account_id),
      database.text(event.scope_id),
      database.text(event.scope_kind),
    ],
  ))
  list.try_fold(targets, [], fn(conflicts, target) {
    let #(page_id, notebook_id, number) = target
    use holder <- db(database.query_one(
      tx,
      "select id::text from pages where notebook_id = $1::uuid and page_number = $2
         and visibility <> 'trashed' and id <> $3::uuid",
      [database.text(notebook_id), database.int(number), database.text(page_id)],
      decode.at([0], decode.string),
    ))
    case holder {
      Some(other) ->
        Ok([
          "restore of page " <> page_id <> " conflicts with " <> other <> "; left hidden",
          ..conflicts
        ])
      None -> {
        use _ <- db(database.execute(
          tx,
          "update pages set visibility = 'active', deleted_at = null, deletion_batch_id = null,
             notebook_id = $3::uuid, page_number = $4, version = version + 1, updated_at = now()
           where account_id = $1::uuid and id = $2::uuid and purge_requested_at is null",
          [
            database.text(event.account_id),
            database.text(page_id),
            database.text(notebook_id),
            database.int(number),
          ],
        ))
        Ok(conflicts)
      }
    }
  })
}

fn mark_purge(tx: Connection, event: Event, text: String) -> Result(List(String), AppError) {
  let account = database.text(event.account_id)
  use _ <- db(database.execute(
    tx,
    "update pages set purge_requested_at = coalesce(purge_requested_at, now()),
       visibility = 'trashed', deleted_at = coalesce(deleted_at, now())
     where account_id = $1::uuid and id = any($2::uuid[])",
    [account, database.text_array(ids(text, "page_ids"))],
  ))
  use _ <- db(database.execute(
    tx,
    "update notebooks set purge_requested_at = coalesce(purge_requested_at, now()),
       deleted_at = coalesce(deleted_at, now())
     where account_id = $1::uuid and id = any($2::uuid[])",
    [account, database.text_array(ids(text, "notebook_ids"))],
  ))
  use _ <- db(database.execute(
    tx,
    "update page_revisions set purge_requested_at = coalesce(purge_requested_at, now())
     where account_id = $1::uuid and id = any($2::uuid[])",
    [account, database.text_array(ids(text, "revision_ids"))],
  ))
  Ok([])
}

/// Account lifecycle: the journal's newer revision wins over the restored
/// snapshot (for example a closure cancellation after the recovery point
/// defeats the restored old deadline). Closing/closed are irreversible.
fn apply_account(tx: Connection, event: Event, text: String) -> Result(List(String), AppError) {
  let revision =
    json.parse(text, decode.at(["lifecycle_revision"], decode.int)) |> result.unwrap(0)
  let status = json_string(text, "status") |> option.unwrap("active")
  use current <- error.found(database.query_one(
    tx,
    "select lifecycle_revision, status from accounts where id = $1::uuid",
    [database.text(event.account_id)],
    {
      use r <- decode.field(0, decode.int)
      use s <- decode.field(1, decode.string)
      decode.success(#(r, s))
    },
  ))
  let #(local_revision, local_status) = current
  let irreversible = local_status == "closing" || local_status == "closed"
  case revision > local_revision && !{ irreversible && status == "active" } {
    False -> Ok([])
    True -> {
      use _ <- db(database.execute(
        tx,
        "update accounts set status = $2, lifecycle_revision = $3,
           closure_requested_at = $4::text::timestamptz,
           closure_effective_at = $5::text::timestamptz
         where id = $1::uuid",
        [
          database.text(event.account_id),
          database.text(status),
          database.int(revision),
          database.nullable_text(json_string(text, "requested_at")),
          database.nullable_text(json_string(text, "effective_at")),
        ],
      ))
      use _ <- result.try(case status {
        "closure_scheduled" ->
          jobs.enqueue(
            tx,
            jobs.NewJob(
              ..jobs.new_job(
                "account_closure_deadline",
                "closure_deadline:" <> event.account_id <> ":" <> int.to_string(revision) <> ":g0",
              ),
              payload: json.object([
                #("account_id", json.string(event.account_id)),
                #("lifecycle_revision", json.int(revision)),
              ]),
            ),
          )
          |> result.map_error(error.from_query)
          |> result.replace(Nil)
        "closing" | "closed" -> {
          use _ <- db(database.execute(
            tx,
            "update web_sessions set revoked_at = now()
             where account_id = $1::uuid and revoked_at is null and not status_only",
            [database.text(event.account_id)],
          ))
          use _ <- db(database.execute(
            tx,
            "update accounts set status = 'closing' where id = $1::uuid and status = 'closed'
               and purged_at is null",
            [database.text(event.account_id)],
          ))
          jobs.enqueue(
            tx,
            jobs.NewJob(
              ..jobs.new_job("account_purge", "account_purge:" <> event.account_id <> ":g0"),
              payload: json.object([#("account_id", json.string(event.account_id))]),
              deadline_seconds: Some(3600),
            ),
          )
          |> result.map_error(error.from_query)
          |> result.replace(Nil)
        }
        _ -> Ok(Nil)
      })
      Ok([])
    }
  }
}

/// Recompute usage counters from effective visibility.
fn reconcile_usage(tx: Connection, account_id: String) -> Result(Nil, AppError) {
  use _ <- db(database.execute(
    tx,
    "update account_usage u set
       stored_pages = (select count(*) from pages where account_id = $1::uuid and visibility = 'active'),
       reserved_page_slots = (select count(*) from pages where account_id = $1::uuid
                              and visibility in ('placeholder', 'restore_pending')),
       notebooks = (select count(*) from notebooks where account_id = $1::uuid and deleted_at is null)
     where u.account_id = $1::uuid",
    [database.text(account_id)],
  ))
  Ok(Nil)
}

/// Record the replayed event as delivered so coverage stays consistent and
/// a second replay is a no-op.
fn record(ctx: Context, key: String, event: Event, text: String) -> Result(Nil, AppError) {
  use _ <- db(database.execute(
    ctx.db,
    "insert into lifecycle_outbox (command_id, account_id, scope_kind, scope_id,
       generation, action, destination, payload, payload_hash, state, acknowledgement,
       journal_sequence)
     select $1::uuid, $2::uuid, $3, $4::uuid, 0, $5, 'journal', $6::jsonb, $7,
       'acknowledged', $8, $9
     where exists (select 1 from accounts where id = $2::uuid)
     on conflict do nothing",
    [
      database.text(event.command_id),
      database.text(event.account_id),
      database.text(event.scope_kind),
      database.text(event.scope_id),
      database.text(event.action),
      database.text(text),
      database.text(context.sha256_hex(text)),
      database.text(key),
      database.int(sequence_from_key(key)),
    ],
  ))
  // New intents must continue after the replayed sequence.
  use _ <- db(database.execute(
    ctx.db,
    "select setval('lifecycle_journal_sequence',
       greatest((select last_value from lifecycle_journal_sequence), $1))",
    [database.int(sequence_from_key(key))],
  ))
  Ok(Nil)
}
