//// Internal entitlement and credit-grant endpoints (sections 10 and 12).
////
//// An entitlement authority (an external service, or a self-host admin)
//// delivers full desired-state
//// projections. Core applies only a newer revision per authority; an exact
//// replay returns the recorded acknowledgement and a conflicting payload at
//// the same revision returns 409. Issued coverage intervals and budgets are
//// immutable; revocations only shorten admission and never reopen it.

import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/time/timestamp
import libarrie/database.{type Connection}
import libarrie/domain/accounts
import libarrie/domain/context.{type Context}
import libarrie/domain/error.{type AppError, db}
import libarrie/domain/quota
import libarrie/domain/renewal
import youid/uuid

/// Baseline rights no entitlement may name or disable.
const baseline_rights = [
  "view", "viewing", "read", "search", "searching", "export", "exporting",
  "correct", "correction", "corrections", "delete", "deletion",
]

pub type CoverageRecord {
  CoverageRecord(
    coverage_id: String,
    kind: String,
    parent_coverage_id: Option(String),
    funding_change_id: Option(String),
    starts_at: String,
    ends_at: String,
    authorized_units: Int,
    confirmation_state: String,
  )
}

pub type Revocation {
  Revocation(
    revocation_id: String,
    coverage_ids: List(String),
    effective_at: String,
    reason: String,
  )
}

pub type Assignment {
  Assignment(
    command_id: String,
    authority: String,
    revision: Int,
    effective_at: String,
    limits_json: String,
    features: List(String),
    features_json: String,
    policy_kind: String,
    policy_json: String,
    renewal_json: String,
    coverage: List(CoverageRecord),
    revocations: List(Revocation),
  )
}

fn coverage_decoder() -> decode.Decoder(CoverageRecord) {
  use coverage_id <- decode.field("coverage_id", decode.string)
  use kind <- decode.optional_field("kind", "base", decode.string)
  use parent <- decode.optional_field(
    "parent_coverage_id",
    None,
    decode.optional(decode.string),
  )
  use funding <- decode.optional_field(
    "funding_change_id",
    None,
    decode.optional(decode.string),
  )
  use starts_at <- decode.field("starts_at", decode.string)
  use ends_at <- decode.field("ends_at", decode.string)
  use units <- decode.field("authorized_units", decode.int)
  use confirmation <- decode.optional_field(
    "confirmation_state",
    "confirmed",
    decode.string,
  )
  decode.success(CoverageRecord(
    string.lowercase(coverage_id),
    kind,
    option.map(parent, string.lowercase),
    option.map(funding, string.lowercase),
    starts_at,
    ends_at,
    units,
    confirmation,
  ))
}

fn revocation_decoder() -> decode.Decoder(Revocation) {
  use id <- decode.field("revocation_id", decode.string)
  use ids <- decode.field("coverage_ids", decode.list(decode.string))
  use effective_at <- decode.field("effective_at", decode.string)
  use reason <- decode.field("reason", decode.string)
  decode.success(Revocation(
    string.lowercase(id),
    list.map(ids, string.lowercase),
    effective_at,
    reason,
  ))
}

/// Parse and validate a payload. Missing/null limits, unknown policies and
/// features naming baseline rights are contract violations (422).
pub fn parse(body: String) -> Result(Assignment, AppError) {
  let invalid = fn(message) { error.new(422, "invalid_entitlement", message) }
  let raw = {
    use command_id <- decode.field("command_id", decode.string)
    use authority <- decode.field("authority", decode.string)
    use revision <- decode.field("revision", decode.int)
    use effective_at <- decode.field("effective_at", decode.string)
    use limits <- decode.field("limits", decode.dynamic)
    use features <- decode.field("features", decode.dict(decode.string, decode.dynamic))
    use policy_kind <- decode.subfield(["processing_policy", "kind"], decode.string)
    use coverage <- decode.field("processing_coverage", decode.list(coverage_decoder()))
    use revocations <- decode.field("coverage_revocations", decode.list(revocation_decoder()))
    use renewal_kind <- decode.subfield(["renewal_policy", "kind"], decode.string)
    decode.success(#(
      command_id,
      authority,
      revision,
      effective_at,
      limits,
      dict.keys(features),
      policy_kind,
      coverage,
      revocations,
      renewal_kind,
    ))
  }
  use parsed <- result.try(
    json.parse(body, raw)
    |> result.replace_error(invalid("The entitlement payload is malformed.")),
  )
  let #(command_id, authority, revision, effective_at, limits, features, policy_kind, coverage, revocations, _) =
    parsed
  use _ <- result.try(
    decode.run(limits, quota.limits_decoder())
    |> result.replace_error(invalid(
      "Every limit must be a tagged value; missing or null limits are rejected.",
    )),
  )
  use <- error.guard(context.is_uuid(command_id), invalid("command_id must be a UUID"))
  use <- error.guard(revision > 0, invalid("revision must be positive"))
  use <- error.guard(authority != "", invalid("authority is required"))
  use <- error.guard(valid_time(effective_at), invalid("effective_at must be RFC 3339"))
  use <- error.guard(
    list.contains(["calendar_months_from_anchor", "lifetime", "unlimited"], policy_kind),
    invalid("unknown processing_policy kind"),
  )
  use <- error.guard(
    !list.any(features, fn(f) { list.contains(baseline_rights, string.lowercase(f)) }),
    invalid("features cannot name baseline rights such as viewing, search, export, correction or deletion"),
  )
  use <- error.guard(
    list.all(coverage, fn(c) {
      context.is_uuid(c.coverage_id)
      && { c.kind == "base" || c.kind == "upgrade" }
      && { c.kind == "base" || option.is_some(c.parent_coverage_id) }
      && valid_time(c.starts_at)
      && valid_time(c.ends_at)
      && before(c.starts_at, c.ends_at)
      && c.authorized_units >= 0
      && { c.confirmation_state == "confirmed" || c.confirmation_state == "provisional" }
    }),
    invalid("processing_coverage contains an invalid record"),
  )
  use <- error.guard(
    list.all(revocations, fn(r) {
      context.is_uuid(r.revocation_id)
      && r.coverage_ids != []
      && valid_time(r.effective_at)
      && list.contains(
        ["refund", "grace_expired", "account_closure", "provisional_rejected", "admin"],
        r.reason,
      )
    }),
    invalid("coverage_revocations contains an invalid record"),
  )
  use sections <- result.try(
    json.parse(body, sections_decoder())
    |> result.replace_error(invalid("The entitlement payload is malformed.")),
  )
  let #(limits_json, features_json, policy_json, renewal_json) = sections
  use _ <- result.try(renewal.parse(renewal_json) |> result.map_error(invalid))
  Ok(Assignment(
    command_id: string.lowercase(command_id),
    authority:,
    revision:,
    effective_at:,
    limits_json:,
    features:,
    features_json:,
    policy_kind:,
    policy_json:,
    renewal_json:,
    coverage:,
    revocations:,
  ))
}

/// Re-serialize the stored JSON sections from the dynamic payload.
fn sections_decoder() -> decode.Decoder(#(String, String, String, String)) {
  use limits <- decode.field("limits", json_text())
  use features <- decode.field("features", json_text())
  use policy <- decode.field("processing_policy", json_text())
  use renewal <- decode.field("renewal_policy", json_text())
  decode.success(#(limits, features, policy, renewal))
}

/// Decode an arbitrary JSON value back into compact JSON text.
fn json_text() -> decode.Decoder(String) {
  decode.recursive(fn() { json_value() })
  |> decode.map(json.to_string)
}

fn json_value() -> decode.Decoder(json.Json) {
  decode.one_of(decode.string |> decode.map(json.string), [
    decode.int |> decode.map(json.int),
    decode.float |> decode.map(json.float),
    decode.bool |> decode.map(json.bool),
    decode.list(decode.recursive(json_value)) |> decode.map(json.preprocessed_array),
    decode.dict(decode.string, decode.recursive(json_value))
      |> decode.map(fn(d) { json.object(dict.to_list(d)) }),
    decode.optional(decode.string) |> decode.map(fn(_) { json.null() }),
  ])
}

fn valid_time(value: String) -> Bool {
  result.is_ok(timestamp.parse_rfc3339(value))
}

fn before(a: String, b: String) -> Bool {
  case timestamp.parse_rfc3339(a), timestamp.parse_rfc3339(b) {
    Ok(x), Ok(y) -> timestamp.compare(x, y) == order.Lt
    _, _ -> False
  }
}

/// `PUT /internal/v1/accounts/{id}/entitlements`
pub fn apply(
  ctx: Context,
  account_id: String,
  body: String,
) -> Result(#(Int, json.Json), AppError) {
  use assignment <- result.try(parse(body))
  let payload_hash = context.sha256_hex(body)
  context.transaction(ctx, fn(tx) {
    use status <- result.try(accounts.lock(tx, account_id))
    use purged <- error.found(database.query_one(
      tx,
      "select purged_at is not null from accounts where id = $1::uuid",
      [database.text(account_id)],
      decode.at([0], decode.bool),
    ))
    use <- bool_guard(!purged, Ok(#(200, json.object([
      #("command_id", json.string(assignment.command_id)),
      #("account_purged", json.bool(True)),
      #("applied", json.bool(False)),
    ]))))
    use _ <- result.try(quota.lock_usage(tx, account_id))
    use existing <- db(database.query_one(
      tx,
      "select payload_hash from entitlement_assignments
       where account_id = $1::uuid and authority = $2 and revision = $3",
      [
        database.text(account_id),
        database.text(assignment.authority),
        database.int(assignment.revision),
      ],
      decode.at([0], decode.string),
    ))
    use latest <- db(database.query_one(
      tx,
      "select max(revision) from entitlement_assignments
       where account_id = $1::uuid and authority = $2",
      [database.text(account_id), database.text(assignment.authority)],
      decode.at([0], decode.optional(decode.int)),
    ))
    let latest = option.flatten(latest) |> option.unwrap(0)
    case existing {
      Some(hash) if hash == payload_hash -> Ok(#(200, ack(assignment, latest, False)))
      Some(_) ->
        Error(error.new(
          409,
          "revision_conflict",
          "A different payload was already applied at this revision.",
        ))
      None if assignment.revision < latest ->
        Ok(#(200, ack(assignment, latest, False)))
      None -> {
        use _ <- result.try(store(tx, account_id, assignment, payload_hash, status))
        Ok(#(200, ack(assignment, assignment.revision, True)))
      }
    }
  })
}

fn ack(assignment: Assignment, applied_revision: Int, applied: Bool) -> json.Json {
  json.object([
    #("command_id", json.string(assignment.command_id)),
    #("authority", json.string(assignment.authority)),
    #("revision", json.int(assignment.revision)),
    #("applied_revision", json.int(applied_revision)),
    #("applied", json.bool(applied)),
  ])
}

fn store(
  tx: Connection,
  account_id: String,
  assignment: Assignment,
  payload_hash: String,
  status: String,
) -> Result(Nil, AppError) {
  let account = database.text(account_id)
  use existing_ids <- db(database.query(
    tx,
    "select id::text, kind, parent_coverage_id::text, rfc3339(starts_at),
       rfc3339(ends_at), authorized_units, confirmation_state
     from processing_coverage where account_id = $1::uuid order by id for update",
    [account],
    {
      use id <- decode.field(0, decode.string)
      use kind <- decode.field(1, decode.string)
      use parent <- decode.field(2, decode.optional(decode.string))
      use starts <- decode.field(3, decode.string)
      use ends <- decode.field(4, decode.string)
      use units <- decode.field(5, decode.int)
      use confirmation <- decode.field(6, decode.string)
      decode.success(#(id, kind, parent, starts, ends, units, confirmation))
    },
  ))
  let new_coverage =
    list.filter(assignment.coverage, fn(c) {
      !list.any(existing_ids, fn(e) { e.0 == c.coverage_id })
    })
  // Issued records are immutable: a changed interval/budget conflicts.
  use _ <- result.try(list.try_each(assignment.coverage, fn(c) {
    case list.find(existing_ids, fn(e) { e.0 == c.coverage_id }) {
      Error(_) -> Ok(Nil)
      // Confirming a provisional record is allowed, but never with a
      // different interval or budget (no second budget for the interval).
      Ok(#(_, kind, parent, starts, ends, units, _)) ->
        case
          kind == c.kind
          && parent == c.parent_coverage_id
          && same_time(starts, c.starts_at)
          && same_time(ends, c.ends_at)
          && units == c.authorized_units
        {
          True -> Ok(Nil)
          False ->
            Error(error.new(
              409,
              "coverage_conflict",
              "An issued coverage record cannot change its interval or budget.",
            )
            |> error.with_details([#("coverage_id", json.string(c.coverage_id))]))
        }
    }
  }))
  use <- error.guard(
    new_coverage == [] || status == "active" || status == "closure_scheduled",
    error.account_closing(),
  )
  use _ <- db(database.execute(
    tx,
    "insert into entitlement_assignments (account_id, authority, revision, command_id,
       payload_hash, effective_at, limits, features, processing_policy, renewal_policy)
     values ($1::uuid, $2, $3, $4::uuid, $5, $6::text::timestamptz, $7::jsonb, $8::jsonb,
       $9::jsonb, $10::jsonb)",
    [
      account,
      database.text(assignment.authority),
      database.int(assignment.revision),
      database.text(assignment.command_id),
      database.text(payload_hash),
      database.text(assignment.effective_at),
      database.text(assignment.limits_json),
      database.text(assignment.features_json),
      database.text(assignment.policy_json),
      database.text(assignment.renewal_json),
    ],
  ))
  // Insert new base records before adjustments so parents exist.
  let ordered =
    list.append(
      list.filter(new_coverage, fn(c) { c.kind == "base" }),
      list.filter(new_coverage, fn(c) { c.kind == "upgrade" }),
    )
  use _ <- result.try(list.try_each(ordered, fn(c) {
    use _ <- result.try(case c.parent_coverage_id {
      None -> Ok(Nil)
      Some(parent) -> {
        use inside <- db(database.query_one(
          tx,
          "select $2::text::timestamptz >= starts_at and $3::text::timestamptz <= ends_at
             and kind = 'base'
           from processing_coverage where account_id = $1::uuid and id = $4::uuid",
          [account, database.text(c.starts_at), database.text(c.ends_at), database.text(parent)],
          decode.at([0], decode.bool),
        ))
        case inside {
          Some(True) -> Ok(Nil)
          _ ->
            Error(error.new(422, "invalid_entitlement", "An upgrade adjustment must lie within its base record."))
        }
      }
    })
    use _ <- db(database.execute(
      tx,
      "insert into processing_coverage (id, account_id, authority, kind,
         parent_coverage_id, funding_change_id, starts_at, ends_at, admission_end_at,
         authorized_units, authority_revision, confirmation_state)
       select $1::uuid, $2::uuid, $3, $4, $5::uuid, $6::uuid, $7::text::timestamptz,
         $8::text::timestamptz,
         -- An adjustment inherits any earlier admission cutoff of its base.
         least($8::text::timestamptz, coalesce(
           (select greatest($7::text::timestamptz, admission_end_at)
            from processing_coverage where id = $5::uuid), $8::text::timestamptz)),
         $9, $10, $11",
      [
        database.text(c.coverage_id),
        account,
        database.text(assignment.authority),
        database.text(c.kind),
        database.nullable_text(c.parent_coverage_id),
        database.nullable_text(c.funding_change_id),
        database.text(c.starts_at),
        database.text(c.ends_at),
        database.int(c.authorized_units),
        database.int(assignment.revision),
        database.text(c.confirmation_state),
      ],
    ))
    Ok(Nil)
  }))
  // The authority confirms provisional records it now funds. A record
  // never returns from confirmed to provisional.
  let confirmations =
    assignment.coverage
    |> list.filter(fn(c) {
      c.confirmation_state == "confirmed"
      && list.any(existing_ids, fn(e) { e.0 == c.coverage_id && e.6 == "provisional" })
    })
    |> list.map(fn(c) { c.coverage_id })
  use _ <- db(database.execute(
    tx,
    "update processing_coverage set confirmation_state = 'confirmed', confirmed_at = now(),
       admission_end_at = case when revoked_at is null then ends_at else admission_end_at end
     where account_id = $1::uuid and id = any($2::uuid[]) and confirmation_state = 'provisional'",
    [account, database.text_array(confirmations)],
  ))
  use _ <- result.try(list.try_each(assignment.revocations, fn(r) {
    apply_revocation(tx, account_id, assignment, r)
  }))
  // Non-empty base admission intervals may not overlap.
  use overlaps <- db(database.query_one(
    tx,
    "select a.id::text from processing_coverage a join processing_coverage b
       on a.account_id = b.account_id and a.id < b.id
     where a.account_id = $1::uuid and a.kind = 'base' and b.kind = 'base'
       and a.starts_at < a.admission_end_at and b.starts_at < b.admission_end_at
       and a.starts_at < b.admission_end_at and b.starts_at < a.admission_end_at
     limit 1",
    [account],
    decode.at([0], decode.string),
  ))
  case overlaps {
    Some(id) ->
      Error(error.new(
        409,
        "coverage_conflict",
        "Base coverage admission intervals overlap.",
      )
      |> error.with_details([#("coverage_id", json.string(id))]))
    None -> Ok(Nil)
  }
}

/// Equal at Postgres precision (microseconds): a delivered timestamp with
/// nanoseconds matches the value core stored for it.
fn same_time(a: String, b: String) -> Bool {
  case timestamp.parse_rfc3339(a), timestamp.parse_rfc3339(b) {
    Ok(x), Ok(y) -> micros(x) == micros(y)
    _, _ -> False
  }
}

fn micros(t: timestamp.Timestamp) -> Int {
  let #(seconds, nanoseconds) = timestamp.to_unix_seconds_and_nanoseconds(t)
  // Postgres rounds to the nearest microsecond, and exact halves to even
  // (`.8848545` is stored as `.884854`).
  let whole = nanoseconds / 1000
  let rounded = case nanoseconds % 1000 {
    r if r > 500 -> whole + 1
    500 if whole % 2 == 1 -> whole + 1
    _ -> whole
  }
  seconds * 1_000_000 + rounded
}

fn apply_revocation(
  tx: Connection,
  account_id: String,
  assignment: Assignment,
  revocation: Revocation,
) -> Result(Nil, AppError) {
  let account = database.text(account_id)
  let ids = list.sort(revocation.coverage_ids, string.compare)
  let hash =
    context.request_hash([
      #("coverage_ids", json.array(ids, json.string)),
      #("effective_at", json.string(revocation.effective_at)),
      #("reason", json.string(revocation.reason)),
    ])
  use stored <- db(database.query_one(
    tx,
    "select payload_hash from coverage_revocations
     where account_id = $1::uuid and revocation_id = $2::uuid",
    [account, database.text(revocation.revocation_id)],
    decode.at([0], decode.string),
  ))
  case stored {
    Some(h) if h == hash -> Ok(Nil)
    Some(_) ->
      Error(error.new(409, "revocation_conflict", "This revocation ID was used with a different payload."))
    None -> {
      use known <- db(database.query(
        tx,
        "select id::text from processing_coverage
         where account_id = $1::uuid and id = any($2::uuid[])",
        [account, database.text_array(ids)],
        decode.at([0], decode.string),
      ))
      use <- error.guard(
        list.length(known) == list.length(list.unique(ids)),
        error.new(422, "invalid_entitlement", "A revocation names unknown coverage."),
      )
      use _ <- db(database.execute(
        tx,
        "insert into coverage_revocations (account_id, authority, revocation_id,
           coverage_ids, effective_at, reason, authority_revision, payload_hash)
         values ($1::uuid, $2, $3::uuid, $4::uuid[], $5::text::timestamptz, $6, $7, $8)",
        [
          account,
          database.text(assignment.authority),
          database.text(revocation.revocation_id),
          database.text_array(ids),
          database.text(revocation.effective_at),
          database.text(revocation.reason),
          database.int(assignment.revision),
          database.text(hash),
        ],
      ))
      // Shorten (never reopen) admission for the records and their
      // adjustments. Unallocated units are revoked at the cutoff; pinned
      // reservations stay valid and release later as revoked.
      use _ <- db(database.execute(
        tx,
        "update processing_coverage set admission_end_at =
           greatest(starts_at, least(admission_end_at, $3::text::timestamptz)),
           revoked_at = coalesce(revoked_at, now())
         where account_id = $1::uuid
           and (id = any($2::uuid[]) or parent_coverage_id = any($2::uuid[]))",
        [account, database.text_array(ids), database.text(revocation.effective_at)],
      ))
      use _ <- db(database.execute(
        tx,
        "update processing_coverage
         set revoked_unreserved = authorized_units - used - reserved
         where account_id = $1::uuid
           and (id = any($2::uuid[]) or parent_coverage_id = any($2::uuid[]))
           and admission_end_at <= now() and admission_end_at < ends_at",
        [account, database.text_array(ids)],
      ))
      Ok(Nil)
    }
  }
}

/// `GET /internal/v1/accounts/{id}/entitlement-status`
pub fn status(ctx: Context, account_id: String) -> Result(json.Json, AppError) {
  use rows <- db(database.query(
    ctx.db,
    "select authority, max(revision), rfc3339(max(received_at))
     from entitlement_assignments where account_id = $1::uuid group by authority
     order by authority",
    [database.text(account_id)],
    {
      use authority <- decode.field(0, decode.string)
      use revision <- decode.field(1, decode.int)
      use received <- decode.field(2, decode.string)
      decode.success(json.object([
        #("authority", json.string(authority)),
        #("applied_revision", json.int(revision)),
        #("received_at", json.string(received)),
      ]))
    },
  ))
  use account <- error.found(database.query_one(
    ctx.db,
    "select status from accounts where id = $1::uuid",
    [database.text(account_id)],
    decode.at([0], decode.string),
  ))
  // Coverage core issued itself while the authority was unreachable, and the
  // units used or pinned on it before the authority confirmed it (outage
  // exposure).
  use provisional <- db(database.query(
    ctx.db,
    "select id::text, rfc3339(starts_at), rfc3339(ends_at), authorized_units, used, reserved,
       confirmation_state, revoked_at is not null
     from processing_coverage
     where account_id = $1::uuid and provisioned_at is not null order by starts_at",
    [database.text(account_id)],
    {
      use id <- decode.field(0, decode.string)
      use starts <- decode.field(1, decode.string)
      use ends <- decode.field(2, decode.string)
      use units <- decode.field(3, decode.int)
      use used <- decode.field(4, decode.int)
      use reserved <- decode.field(5, decode.int)
      use confirmation <- decode.field(6, decode.string)
      use revoked <- decode.field(7, decode.bool)
      let state = case confirmation, revoked {
        "confirmed", _ -> "confirmed"
        _, True -> "rejected"
        _, False -> "provisional"
      }
      let exposure = case state {
        "confirmed" -> 0
        _ -> used + reserved
      }
      decode.success(#(exposure, json.object([
        #("coverage_id", json.string(id)),
        #("starts_at", json.string(starts)),
        #("ends_at", json.string(ends)),
        #("authorized_units", json.int(units)),
        #("used", json.int(used)),
        #("reserved", json.int(reserved)),
        #("state", json.string(state)),
      ])))
    },
  ))
  Ok(json.object([
    #("account_id", json.string(account_id)),
    #("account_status", json.string(account)),
    #("authorities", json.preprocessed_array(rows)),
    #("provisional_coverage", json.preprocessed_array(list.map(provisional, fn(p) { p.1 }))),
    #("outage_exposure_units", json.int(list.fold(provisional, 0, fn(sum, p) { sum + p.0 }))),
  ]))
}

// Credit grants ------------------------------------------------------------------

pub type CreditCommand {
  CreditCommand(
    external_grant_id: String,
    action: String,
    units: Int,
    expires_at: Option(String),
  )
}

pub fn credit_decoder() -> decode.Decoder(CreditCommand) {
  use external <- decode.field("external_grant_id", decode.string)
  use action <- decode.optional_field("action", "grant", decode.string)
  use units <- decode.optional_field("units", 0, decode.int)
  use expires_at <- decode.optional_field(
    "expires_at",
    None,
    decode.optional(decode.string),
  )
  decode.success(CreditCommand(external, action, units, expires_at))
}

/// `POST /internal/v1/accounts/{id}/credit-grants`: idempotent by external
/// grant ID. Revocation removes only unreserved, unconsumed units; reserved
/// units stay usable by already admitted work.
pub fn credit(
  ctx: Context,
  account_id: String,
  command: CreditCommand,
) -> Result(json.Json, AppError) {
  use <- error.guard(
    command.external_grant_id != "" && string.length(command.external_grant_id) <= 200,
    error.new(422, "invalid_request", "external_grant_id is required"),
  )
  use <- error.guard(
    case command.expires_at {
      Some(t) -> valid_time(t)
      None -> True
    },
    error.new(422, "invalid_request", "expires_at must be RFC 3339"),
  )
  context.transaction(ctx, fn(tx) {
    use status <- result.try(accounts.lock(tx, account_id))
    use _ <- result.try(quota.lock_usage(tx, account_id))
    use existing <- db(database.query_one(
      tx,
      "select id::text, account_id::text, granted, rfc3339(expires_at)
       from credit_grants where external_grant_id = $1 for update",
      [database.text(command.external_grant_id)],
      {
        use id <- decode.field(0, decode.string)
        use owner <- decode.field(1, decode.string)
        use granted <- decode.field(2, decode.int)
        use expires <- decode.field(3, decode.optional(decode.string))
        decode.success(#(id, owner, granted, expires))
      },
    ))
    case command.action, existing {
      "grant", Some(#(id, owner, granted, _)) ->
        case owner == account_id && granted == command.units {
          True -> grant_json(tx, id)
          False ->
            Error(error.new(409, "grant_conflict", "This grant ID was already used differently."))
        }
      "grant", None -> {
        use <- error.guard(status == "active", error.account_closing())
        use <- error.guard(
          command.units > 0,
          error.new(422, "invalid_request", "units must be positive"),
        )
        let id = uuid.v7_string()
        use _ <- db(database.execute(
          tx,
          "insert into credit_grants (id, account_id, external_grant_id, granted, expires_at)
           values ($1::uuid, $2::uuid, $3, $4, $5::text::timestamptz)",
          [
            database.text(id),
            database.text(account_id),
            database.text(command.external_grant_id),
            database.int(command.units),
            database.nullable_text(command.expires_at),
          ],
        ))
        grant_json(tx, id)
      }
      "revoke", Some(#(id, owner, _, _)) if owner == account_id -> {
        use _ <- db(database.execute(
          tx,
          "update credit_grants set revoked = granted - reserved - consumed,
             revoked_at = coalesce(revoked_at, now())
           where id = $1::uuid",
          [database.text(id)],
        ))
        grant_json(tx, id)
      }
      "revoke", _ -> Error(error.not_found())
      _, _ -> Error(error.new(422, "invalid_request", "action must be grant or revoke"))
    }
  })
}

fn grant_json(tx: Connection, id: String) -> Result(json.Json, AppError) {
  use row <- error.found(database.query_one(
    tx,
    "select id::text, external_grant_id, granted, reserved, consumed, revoked,
       rfc3339(expires_at) from credit_grants where id = $1::uuid",
    [database.text(id)],
    {
      use id <- decode.field(0, decode.string)
      use external <- decode.field(1, decode.string)
      use granted <- decode.field(2, decode.int)
      use reserved <- decode.field(3, decode.int)
      use consumed <- decode.field(4, decode.int)
      use revoked <- decode.field(5, decode.int)
      use expires <- decode.field(6, decode.optional(decode.string))
      decode.success(json.object([
        #("credit_grant_id", json.string(id)),
        #("external_grant_id", json.string(external)),
        #("granted", json.int(granted)),
        #("reserved", json.int(reserved)),
        #("consumed", json.int(consumed)),
        #("revoked", json.int(revoked)),
        #("expires_at", context.optional_string(expires)),
      ]))
    },
  ))
  Ok(row)
}

fn bool_guard(condition: Bool, otherwise: a, next: fn() -> a) -> a {
  case condition {
    True -> next()
    False -> otherwise
  }
}
