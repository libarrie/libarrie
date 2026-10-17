//// Lifecycle intents for the deletion/lifecycle journal (section 14) and
//// optional lifecycle subscriber delivery.
////
//// Interim rule (section 19): lifecycle events go to an append-only outbox
//// table in the same transaction as the local state change; a leased shipper
//// copies each event as an immutable object to the independent journal
//// store. Operations report `recovery_pending` until that copy is confirmed.
//// Account lifecycle commands are additionally delivered to a configured
//// subscriber under the same command identity and revision.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import libarrie/database.{type Connection}
import libarrie/domain/context
import libarrie/domain/error.{type AppError, db}
import youid/uuid

/// The delivery destination for an optional lifecycle subscriber.
pub const subscriber = "subscriber"

pub type Intent {
  Intent(command_id: String, state: String)
}

/// Append a journal-only intent. `generation` is the scope's monotonic
/// generation (for pages and notebooks, their resource version after the
/// change; for accounts, the lifecycle revision).
pub fn record(
  conn: Connection,
  account_id: String,
  scope_kind: String,
  scope_id: String,
  generation: Int,
  action: String,
  payload: List(#(String, json.Json)),
) -> Result(Intent, AppError) {
  record_to(conn, account_id, scope_kind, scope_id, generation, action, payload, [
    #("journal", "pending"),
  ])
}

/// Append one command to several destinations. Each destination starts in
/// the given state (`pending`, or `acknowledged` for not-applicable ones).
pub fn record_to(
  conn: Connection,
  account_id: String,
  scope_kind: String,
  scope_id: String,
  generation: Int,
  action: String,
  payload: List(#(String, json.Json)),
  destinations: List(#(String, String)),
) -> Result(Intent, AppError) {
  let command_id = uuid.v7_string()
  let body =
    json.object([
      #("command_id", json.string(command_id)),
      #("account_id", json.string(account_id)),
      #("scope_kind", json.string(scope_kind)),
      #("scope_id", json.string(scope_id)),
      #("generation", json.int(generation)),
      #("action", json.string(action)),
      ..payload
    ])
    |> json.to_string
  use _ <- result.try(list.try_each(destinations, fn(destination) {
    let #(name, state) = destination
    use _ <- db(database.execute(
      conn,
      "insert into lifecycle_outbox (command_id, account_id, scope_kind, scope_id,
         generation, action, destination, payload, payload_hash, state, acknowledgement,
         journal_sequence)
       values ($1::uuid, $2::uuid, $3, $4::uuid, $5, $6, $7, $8::jsonb, $9, $10,
         case when $10 = 'acknowledged' then 'not_applicable' end,
         case when $7 = 'journal' then nextval('lifecycle_journal_sequence') end)",
      [
        database.text(command_id),
        database.text(account_id),
        database.text(scope_kind),
        database.text(scope_id),
        database.int(generation),
        database.text(action),
        database.text(name),
        database.text(body),
        database.text(context.sha256_hex(body)),
        database.text(state),
      ],
    ))
    Ok(Nil)
  }))
  Ok(Intent(command_id, "recovery_pending"))
}

/// True while any journal intent for the scope awaits acknowledgement. New
/// conflicting lifecycle operations for that scope are rejected meanwhile.
pub fn pending_for_scope(
  conn: Connection,
  account_id: String,
  scope_id: String,
) -> Result(Bool, AppError) {
  use row <- db(database.query_one(
    conn,
    "select 1 from lifecycle_outbox where account_id = $1::uuid
       and scope_id = $2::uuid and destination = 'journal' and state = 'pending'
     limit 1",
    [database.text(account_id), database.text(scope_id)],
    decode.at([0], decode.int),
  ))
  Ok(option.is_some(row))
}

pub fn status(
  conn: Connection,
  command_id: String,
  destination: String,
) -> Result(Option(String), AppError) {
  use row <- db(database.query_one(
    conn,
    "select coalesce(acknowledgement, state) from lifecycle_outbox
     where command_id = $1::uuid and destination = $2",
    [database.text(command_id), database.text(destination)],
    decode.at([0], decode.string),
  ))
  Ok(row)
}

pub fn intent_json(intent: Intent) -> json.Json {
  json.object([
    #("command_id", json.string(intent.command_id)),
    #("journal_status", json.string(intent.state)),
  ])
}

pub type Event {
  Event(
    sequence: Int,
    command_id: String,
    account_id: String,
    scope_kind: String,
    scope_id: String,
    action: String,
    destination: String,
    payload: String,
  )
}

/// Pending events for a destination, oldest first.
pub fn pending_events(
  conn: Connection,
  destination: String,
  limit: Int,
) -> Result(List(Event), AppError) {
  use rows <- db(database.query(
    conn,
    "select coalesce(journal_sequence, 0), command_id::text, account_id::text,
       scope_kind, scope_id::text, action, destination, payload::text
     from lifecycle_outbox where destination = $1 and state = 'pending'
       and retry_at <= now()
     order by journal_sequence nulls last, created_at, command_id limit $2",
    [database.text(destination), database.int(limit)],
    {
      use sequence <- decode.field(0, decode.int)
      use command_id <- decode.field(1, decode.string)
      use account_id <- decode.field(2, decode.string)
      use scope_kind <- decode.field(3, decode.string)
      use scope_id <- decode.field(4, decode.string)
      use action <- decode.field(5, decode.string)
      use destination <- decode.field(6, decode.string)
      use payload <- decode.field(7, decode.string)
      decode.success(Event(
        sequence,
        command_id,
        account_id,
        scope_kind,
        scope_id,
        action,
        destination,
        payload,
      ))
    },
  ))
  Ok(rows)
}

/// Mark delivered. Returns True only for the delivery that made the change,
/// so follow-up actions (restore activation, purge) run once per command.
pub fn acknowledge(
  conn: Connection,
  event: Event,
  acknowledgement: String,
) -> Result(Bool, AppError) {
  use n <- db(database.execute(
    conn,
    "update lifecycle_outbox set state = 'acknowledged', acknowledgement = $3
     where command_id = $1::uuid and destination = $2 and state = 'pending'",
    [
      database.text(event.command_id),
      database.text(event.destination),
      database.text(acknowledgement),
    ],
  ))
  Ok(n == 1)
}

/// Record a failed delivery with capped exponential backoff.
pub fn defer(conn: Connection, event: Event, reason: String) -> Result(Nil, AppError) {
  use _ <- db(database.execute(
    conn,
    "update lifecycle_outbox set attempts = attempts + 1, last_error = $3,
       retry_at = now() + make_interval(secs => least(900, 5 * power(2, least(attempts, 8))::int))
     where command_id = $1::uuid and destination = $2 and state = 'pending'",
    [
      database.text(event.command_id),
      database.text(event.destination),
      database.text(reason),
    ],
  ))
  Ok(Nil)
}

/// The account's newest lifecycle command and its delivery state per
/// destination.
pub fn latest_account_command(
  conn: Connection,
  account_id: String,
) -> Result(Option(#(String, Int, List(#(String, String)))), AppError) {
  use rows <- db(database.query(
    conn,
    "select command_id::text, generation, destination, coalesce(acknowledgement, state)
     from lifecycle_outbox
     where account_id = $1::uuid and scope_kind = 'account'
       and generation = (select max(generation) from lifecycle_outbox
                         where account_id = $1::uuid and scope_kind = 'account')
     order by destination",
    [database.text(account_id)],
    {
      use id <- decode.field(0, decode.string)
      use generation <- decode.field(1, decode.int)
      use destination <- decode.field(2, decode.string)
      use state <- decode.field(3, decode.string)
      decode.success(#(id, generation, destination, state))
    },
  ))
  case rows {
    [] -> Ok(None)
    [#(id, generation, _, _), ..] ->
      Ok(Some(#(id, generation, list.map(rows, fn(r) { #(r.2, r.3) }))))
  }
}

/// A closure cancellation keeps grace-period restrictions until its higher
/// active revision is durable in the journal.
pub fn account_change_unconfirmed(
  conn: Connection,
  account_id: String,
) -> Result(Bool, AppError) {
  use row <- db(database.query_one(
    conn,
    "select 1 from lifecycle_outbox where account_id = $1::uuid
       and scope_kind = 'account' and destination = 'journal' and state = 'pending'
     limit 1",
    [database.text(account_id)],
    decode.at([0], decode.int),
  ))
  Ok(option.is_some(row))
}

/// Object key for a journal event: zero-padded sequence first, so a
/// lexicographic listing is replay order.
pub fn object_key(event: Event) -> String {
  "journal/v1/" <> string.pad_start(int.to_string(event.sequence), 20, "0")
  <> "-" <> event.command_id <> ".json"
}
