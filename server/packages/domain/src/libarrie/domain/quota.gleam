//// Quota ledger and processing allocations (section 10).
////
//// Core accepts numeric limits and feature flags, never plan names. Every
//// processing reservation pins exactly one funding source: a coverage
//// record, the lifetime period or a credit grant. Each reservation component
//// transitions once; reservation state guards make consume/release
//// idempotent so replays never double charge or double release.
////
//// Callers must already hold the account row lock (level 1). Functions here
//// take level 2 locks (usage row, then coverage, periods and grants in a
//// fixed table and ID order).

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import libarrie/database.{type Connection}
import libarrie/domain/context.{type Config, type Limit, Limited, Unlimited}
import libarrie/domain/error.{type AppError, db}
import libarrie/domain/renewal
import youid/uuid

pub type ProcessingPolicy {
  CalendarMonths
  LifetimePolicy
  UnlimitedProcessing
}

pub type Entitlement {
  Entitlement(
    authority: String,
    revision: Int,
    stored_pages: Limit,
    notebooks: Limit,
    processing: Limit,
    policy: ProcessingPolicy,
  )
}

/// The effective entitlement: the latest assignment whose effective time has
/// passed, or the configured defaults.
pub fn entitlement(
  conn: Connection,
  config: Config,
  account_id: String,
) -> Result(Entitlement, AppError) {
  use row <- db(database.query_one(
    conn,
    "select authority, revision, limits::text, processing_policy->>'kind'
     from entitlement_assignments
     where account_id = $1::uuid and effective_at <= now()
     order by effective_at desc, revision desc limit 1",
    [database.text(account_id)],
    {
      use authority <- decode.field(0, decode.string)
      use revision <- decode.field(1, decode.int)
      use limits <- decode.field(2, decode.string)
      use policy <- decode.field(3, decode.string)
      decode.success(#(authority, revision, limits, policy))
    },
  ))
  case row {
    None ->
      Ok(Entitlement(
        authority: "default",
        revision: 0,
        stored_pages: config.default_stored_pages,
        notebooks: config.default_notebooks,
        processing: config.default_lifetime_processing,
        policy: LifetimePolicy,
      ))
    Some(#(authority, revision, limits, policy)) -> {
      use #(stored_pages, notebooks, processing) <- result.try(
        parse_limits(limits)
        |> result.replace_error(error.internal("stored limits invalid")),
      )
      Ok(Entitlement(
        authority:,
        revision:,
        stored_pages:,
        notebooks:,
        processing:,
        policy: case policy {
          "calendar_months_from_anchor" -> CalendarMonths
          "unlimited" -> UnlimitedProcessing
          _ -> LifetimePolicy
        },
      ))
    }
  }
}

pub fn limits_decoder() -> decode.Decoder(#(Limit, Limit, Limit)) {
  use stored <- decode.field("stored_pages", context.limit_decoder())
  use notebooks <- decode.field("notebooks", context.limit_decoder())
  use processing <- decode.field(
    "processing_pages_per_period",
    context.limit_decoder(),
  )
  decode.success(#(stored, notebooks, processing))
}

fn parse_limits(text: String) -> Result(#(Limit, Limit, Limit), Nil) {
  json.parse(text, limits_decoder()) |> result.replace_error(Nil)
}

// Usage row ----------------------------------------------------------------

pub type Usage {
  Usage(stored_pages: Int, reserved_page_slots: Int, notebooks: Int)
}

/// Lock the account usage row (first level-2 lock).
pub fn lock_usage(conn: Connection, account_id: String) -> Result(Usage, AppError) {
  use usage <- error.found(database.query_one(
    conn,
    "select stored_pages, reserved_page_slots, notebooks from account_usage
     where account_id = $1::uuid for update",
    [database.text(account_id)],
    {
      use stored <- decode.field(0, decode.int)
      use reserved <- decode.field(1, decode.int)
      use notebooks <- decode.field(2, decode.int)
      decode.success(Usage(stored, reserved, notebooks))
    },
  ))
  Ok(usage)
}

pub fn adjust_usage(
  conn: Connection,
  account_id: String,
  stored_delta: Int,
  reserved_delta: Int,
  notebooks_delta: Int,
) -> Result(Nil, AppError) {
  use _ <- db(database.execute(
    conn,
    "update account_usage set stored_pages = stored_pages + $2,
       reserved_page_slots = reserved_page_slots + $3,
       notebooks = notebooks + $4
     where account_id = $1::uuid",
    [
      database.text(account_id),
      database.int(stored_delta),
      database.int(reserved_delta),
      database.int(notebooks_delta),
    ],
  ))
  Ok(Nil)
}

pub fn require_page_capacity(
  usage: Usage,
  entitlement: Entitlement,
  requested: Int,
) -> Result(Nil, AppError) {
  case
    context.fits(
      entitlement.stored_pages,
      usage.stored_pages + usage.reserved_page_slots,
      requested,
    )
  {
    True -> Ok(Nil)
    False ->
      Error(
        error.new(
          409,
          "storage_limit_reached",
          "The stored-page limit has been reached.",
        )
        |> error.with_details([
          #("stored_pages", json.int(usage.stored_pages)),
          #("reserved_page_slots", json.int(usage.reserved_page_slots)),
          #("limit", context.limit_json(entitlement.stored_pages)),
        ]),
      )
  }
}

// Processing funding -------------------------------------------------------

pub type Funding {
  Coverage(id: String)
  LifetimePeriod(id: String)
  CreditGrant(id: String)
}

type CoverageRow {
  CoverageRow(
    id: String,
    kind: String,
    admission_end_at: String,
    available: Int,
  )
}

type GrantRow {
  GrantRow(id: String, expires_at: Option(String), available: Int)
}

/// Reserve one processing unit using the default spend order: admissible
/// coverage (earliest admission_end_at, upgrade adjustments before their
/// base, then ID), then the lifetime allowance, then unexpired credits
/// (earliest expiry first). Returns `processing_limit_reached` when nothing
/// can fund the unit.
pub fn reserve_processing(
  conn: Connection,
  entitlement: Entitlement,
  account_id: String,
) -> Result(Funding, AppError) {
  let account = database.text(account_id)
  // While the entitlement authority is unreachable, a bounded renewal policy may supply the next
  // service month as provisional coverage before funding is chosen.
  use _ <- result.try(renewal.provision(conn, account_id))
  // Coverage rows locked in ID order, then chosen by spend order.
  use coverage <- db(database.query(
    conn,
    "select id::text, kind, rfc3339(admission_end_at),
       authorized_units - revoked_unreserved - used - reserved
     from processing_coverage
     where account_id = $1::uuid and starts_at <= now() and admission_end_at > now()
     order by id for update",
    [account],
    {
      use id <- decode.field(0, decode.string)
      use kind <- decode.field(1, decode.string)
      use end <- decode.field(2, decode.string)
      use available <- decode.field(3, decode.int)
      decode.success(CoverageRow(id, kind, end, available))
    },
  ))
  use lifetime <- error.found(database.query_one(
    conn,
    "select id::text, allowance, unlimited, used + reserved from usage_periods
     where account_id = $1::uuid and kind = 'lifetime' for update",
    [account],
    {
      use id <- decode.field(0, decode.string)
      use allowance <- decode.field(1, decode.optional(decode.int))
      use unlimited <- decode.field(2, decode.bool)
      use committed <- decode.field(3, decode.int)
      decode.success(#(id, allowance, unlimited, committed))
    },
  ))
  use grants <- db(database.query(
    conn,
    "select id::text, rfc3339(expires_at), granted - reserved - consumed - revoked
     from credit_grants
     where account_id = $1::uuid and (expires_at is null or expires_at > now())
     order by id for update",
    [account],
    {
      use id <- decode.field(0, decode.string)
      use expires_at <- decode.field(1, decode.optional(decode.string))
      use available <- decode.field(2, decode.int)
      decode.success(GrantRow(id, expires_at, available))
    },
  ))

  let coverage_choice =
    coverage
    |> list.filter(fn(c) { c.available > 0 })
    |> list.sort(fn(a, b) {
      string.compare(a.admission_end_at, b.admission_end_at)
      |> order.lazy_break_tie(fn() {
        int.compare(kind_rank(a.kind), kind_rank(b.kind))
      })
      |> order.lazy_break_tie(fn() { string.compare(a.id, b.id) })
    })
    |> list.first
    |> result.map(fn(c) { Coverage(c.id) })

  let #(period_id, period_allowance, period_unlimited, period_committed) =
    lifetime
  let lifetime_limit = lifetime_allowance(entitlement, period_allowance, period_unlimited)
  let lifetime_choice = case context.fits(lifetime_limit, period_committed, 1) {
    True -> Ok(LifetimePeriod(period_id))
    False -> Error(Nil)
  }

  let grant_choice =
    grants
    |> list.filter(fn(g) { g.available > 0 })
    |> list.sort(fn(a, b) {
      case a.expires_at, b.expires_at {
        Some(x), Some(y) -> string.compare(x, y)
        Some(_), None -> order.Lt
        None, Some(_) -> order.Gt
        None, None -> order.Eq
      }
      |> order.lazy_break_tie(fn() { string.compare(a.id, b.id) })
    })
    |> list.first
    |> result.map(fn(g) { CreditGrant(g.id) })

  let choice =
    coverage_choice
    |> result.lazy_or(fn() { lifetime_choice })
    |> result.lazy_or(fn() { grant_choice })

  case choice {
    Error(Nil) ->
      Error(
        error.new(
          409,
          "processing_limit_reached",
          "No processing allowance is available right now.",
        )
        |> error.with_details([#("deferred_upload_available", json.bool(True))]),
      )
    Ok(funding) -> {
      use _ <- result.try(adjust_funding(conn, funding, 1, 0))
      Ok(funding)
    }
  }
}

fn kind_rank(kind: String) -> Int {
  case kind {
    "upgrade" -> 0
    _ -> 1
  }
}

/// The lifetime allowance. A `lifetime` policy assignment sets it from the
/// assigned processing limit; an `unlimited` policy bypasses conservation
/// arithmetic explicitly. Calendar (coverage-funded) assignments keep the original
/// lifetime allowance for when coverage is absent.
pub fn lifetime_allowance(
  entitlement: Entitlement,
  stored_allowance: Option(Int),
  stored_unlimited: Bool,
) -> Limit {
  case entitlement.policy, entitlement.processing {
    UnlimitedProcessing, _ -> Unlimited
    LifetimePolicy, limit if entitlement.revision > 0 -> limit
    _, _ ->
      case stored_unlimited, stored_allowance {
        True, _ -> Unlimited
        False, Some(n) -> Limited(n)
        False, None -> Limited(0)
      }
  }
}

fn adjust_funding(
  conn: Connection,
  funding: Funding,
  reserved_delta: Int,
  used_delta: Int,
) -> Result(Nil, AppError) {
  let #(sql, id) = case funding {
    Coverage(id) -> #(
      "update processing_coverage set reserved = reserved + $2, used = used + $3
       where id = $1::uuid",
      id,
    )
    LifetimePeriod(id) -> #(
      "update usage_periods set reserved = reserved + $2, used = used + $3
       where id = $1::uuid",
      id,
    )
    CreditGrant(id) -> #(
      "update credit_grants set reserved = reserved + $2, consumed = consumed + $3
       where id = $1::uuid",
      id,
    )
  }
  use _ <- db(database.execute(conn, sql, [
    database.text(id),
    database.int(reserved_delta),
    database.int(used_delta),
  ]))
  Ok(Nil)
}

// Reservations -------------------------------------------------------------

pub fn insert_reservation(
  conn: Connection,
  account_id: String,
  operation_id: String,
  page_slot: Bool,
  funding: Option(Funding),
  expires_at_seconds: Option(Int),
) -> Result(String, AppError) {
  let id = uuid.v7_string()
  let #(coverage, period, grant) = case funding {
    Some(Coverage(f)) -> #(Some(f), None, None)
    Some(LifetimePeriod(f)) -> #(None, Some(f), None)
    Some(CreditGrant(f)) -> #(None, None, Some(f))
    None -> #(None, None, None)
  }
  use _ <- db(database.execute(
    conn,
    "insert into quota_reservations (id, account_id, operation_id, page_slots,
       processing_units, coverage_id, period_id, credit_grant_id,
       page_slot_state, processing_state, expires_at)
     values ($1::uuid, $2::uuid, $3::uuid, $4, $5, $6::uuid, $7::uuid, $8::uuid,
       $9, $10, now() + make_interval(secs => $11))",
    [
      database.text(id),
      database.text(account_id),
      database.text(operation_id),
      database.int(bool_int(page_slot)),
      database.int(bool_int(option.is_some(funding))),
      database.nullable_text(coverage),
      database.nullable_text(period),
      database.nullable_text(grant),
      database.text(case page_slot {
        True -> "reserved"
        False -> "none"
      }),
      database.text(case funding {
        Some(_) -> "reserved"
        None -> "none"
      }),
      database.int(option.unwrap(expires_at_seconds, 0)),
    ],
  ))
  case expires_at_seconds {
    None ->
      database.execute(
        conn,
        "update quota_reservations set expires_at = null where id = $1::uuid",
        [database.text(id)],
      )
      |> result.map_error(error.from_query)
      |> result.replace(id)
    Some(_) -> Ok(id)
  }
}

fn bool_int(b: Bool) -> Int {
  case b {
    True -> 1
    False -> 0
  }
}

type ReservationFunding {
  ReservationFunding(id: String, funding: Funding)
}

fn funding_decoder() -> decode.Decoder(ReservationFunding) {
  use id <- decode.field(0, decode.string)
  use coverage <- decode.field(1, decode.optional(decode.string))
  use period <- decode.field(2, decode.optional(decode.string))
  use grant <- decode.field(3, decode.optional(decode.string))
  case coverage, period, grant {
    Some(c), _, _ -> decode.success(ReservationFunding(id, Coverage(c)))
    _, Some(p), _ -> decode.success(ReservationFunding(id, LifetimePeriod(p)))
    _, _, Some(g) -> decode.success(ReservationFunding(id, CreditGrant(g)))
    _, _, _ -> decode.failure(ReservationFunding(id, Coverage("")), "funding")
  }
}

/// Consume an operation's reserved processing unit exactly once and record
/// the charge under its charge-root key. Returns True if a charge happened.
pub fn consume_processing(
  conn: Connection,
  account_id: String,
  operation_id: String,
  charge_root_operation_id: String,
) -> Result(Bool, AppError) {
  use rows <- db(database.query(
    conn,
    "update quota_reservations set processing_state = 'consumed'
     where account_id = $1::uuid and operation_id = $2::uuid
       and processing_state = 'reserved'
     returning id::text, coverage_id::text, period_id::text, credit_grant_id::text",
    [database.text(account_id), database.text(operation_id)],
    funding_decoder(),
  ))
  case rows {
    [] -> Ok(False)
    [row, ..] -> {
      use _ <- result.try(adjust_funding(conn, row.funding, -1, 1))
      use _ <- db(database.execute(
        conn,
        "insert into usage_events (id, account_id, operation_id,
           charge_root_operation_id, meter, amount, reason)
         values ($1::uuid, $2::uuid, $3::uuid, $4::uuid, 'processing_pages', 1, 'charge')
         on conflict do nothing",
        [
          database.text(uuid.v7_string()),
          database.text(account_id),
          database.text(operation_id),
          database.text(charge_root_operation_id),
        ],
      ))
      Ok(True)
    }
  }
}

/// Release an operation's unconsumed processing unit exactly once. If its
/// source was revoked (coverage past a revocation cutoff, or a revoked credit
/// grant) the unit becomes revoked, never spendable again. A provisional
/// record that only reached its outage-grace end is not revoked: its units
/// return to it and are spendable again if the authority confirms it.
pub fn release_processing(
  conn: Connection,
  account_id: String,
  operation_id: String,
) -> Result(Nil, AppError) {
  use rows <- db(database.query(
    conn,
    "update quota_reservations set processing_state = 'released'
     where account_id = $1::uuid and operation_id = $2::uuid
       and processing_state in ('reserved', 'held')
     returning id::text, coverage_id::text, period_id::text, credit_grant_id::text",
    [database.text(account_id), database.text(operation_id)],
    funding_decoder(),
  ))
  list.try_each(rows, fn(row) {
    use _ <- result.try(adjust_funding(conn, row.funding, -1, 0))
    case row.funding {
      Coverage(id) -> {
        use _ <- db(database.execute(
          conn,
          "update processing_coverage set revoked_unreserved = revoked_unreserved + 1
           where id = $1::uuid and revoked_at is not null
             and admission_end_at < ends_at and admission_end_at <= now()",
          [database.text(id)],
        ))
        Ok(Nil)
      }
      // Revoke-on-release: the reserved unit stayed usable by the admitted
      // operation; released, it never becomes spendable again.
      CreditGrant(id) -> {
        use _ <- db(database.execute(
          conn,
          "update credit_grants set revoked = revoked + 1
           where id = $1::uuid and revoked_at is not null",
          [database.text(id)],
        ))
        Ok(Nil)
      }
      LifetimePeriod(_) -> Ok(Nil)
    }
  })
}

/// Release the page-slot component of a not-yet-accepted upload.
pub fn release_page_slot(
  conn: Connection,
  account_id: String,
  operation_id: String,
) -> Result(Nil, AppError) {
  use released <- db(database.execute(
    conn,
    "update quota_reservations set page_slot_state = 'released'
     where account_id = $1::uuid and operation_id = $2::uuid
       and page_slot_state = 'reserved'",
    [database.text(account_id), database.text(operation_id)],
  ))
  case released {
    0 -> Ok(Nil)
    n -> adjust_usage(conn, account_id, 0, 0 - n, 0)
  }
}

/// Convert a reserved new-page slot into one stored page.
pub fn store_page_slot(
  conn: Connection,
  account_id: String,
  operation_id: String,
) -> Result(Nil, AppError) {
  use converted <- db(database.execute(
    conn,
    "update quota_reservations set page_slot_state = 'stored'
     where account_id = $1::uuid and operation_id = $2::uuid
       and page_slot_state = 'reserved'",
    [database.text(account_id), database.text(operation_id)],
  ))
  case converted {
    0 -> Ok(Nil)
    n -> adjust_usage(conn, account_id, n, 0 - n, 0)
  }
}

/// Terminal system-fault failure after source acceptance: keep the pinned
/// allocation in one recovery hold per charge root instead of releasing it.
pub fn hold_processing(
  conn: Connection,
  config: Config,
  account_id: String,
  operation_id: String,
  charge_root_operation_id: String,
  source_revision_id: String,
  request_hash: String,
) -> Result(Option(String), AppError) {
  use rows <- db(database.query(
    conn,
    "update quota_reservations set processing_state = 'held'
     where account_id = $1::uuid and operation_id = $2::uuid
       and processing_state = 'reserved'
     returning id::text",
    [database.text(account_id), database.text(operation_id)],
    decode.at([0], decode.string),
  ))
  case rows {
    [] -> Ok(None)
    [reservation_id, ..] -> {
      let hold_id = uuid.v7_string()
      use held <- db(database.query_one(
        conn,
        "insert into recovery_holds (id, account_id, charge_root_operation_id,
           reservation_id, source_revision_id, request_hash, state,
           first_failure_at, claim_deadline)
         values ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6, 'held',
           now(), now() + make_interval(days => $7))
         on conflict (account_id, charge_root_operation_id) do update
           set state = 'held', reservation_id = excluded.reservation_id,
               active_retry_operation_id = null
         returning id::text",
        [
          database.text(hold_id),
          database.text(account_id),
          database.text(charge_root_operation_id),
          database.text(reservation_id),
          database.text(source_revision_id),
          database.text(request_hash),
          database.int(config.recovery_hold_days),
        ],
        decode.at([0], decode.string),
      ))
      Ok(held)
    }
  }
}

// Usage report -------------------------------------------------------------

pub fn usage_json(
  conn: Connection,
  config: Config,
  account_id: String,
) -> Result(json.Json, AppError) {
  use ent <- result.try(entitlement(conn, config, account_id))
  let account = database.text(account_id)
  use usage <- error.found(database.query_one(
    conn,
    "select stored_pages, reserved_page_slots, notebooks from account_usage
     where account_id = $1::uuid",
    [account],
    {
      use stored <- decode.field(0, decode.int)
      use reserved <- decode.field(1, decode.int)
      use notebooks <- decode.field(2, decode.int)
      decode.success(Usage(stored, reserved, notebooks))
    },
  ))
  use lifetime <- error.found(database.query_one(
    conn,
    "select allowance, unlimited, used, reserved from usage_periods
     where account_id = $1::uuid and kind = 'lifetime'",
    [account],
    {
      use allowance <- decode.field(0, decode.optional(decode.int))
      use unlimited <- decode.field(1, decode.bool)
      use used <- decode.field(2, decode.int)
      use reserved <- decode.field(3, decode.int)
      decode.success(#(allowance, unlimited, used, reserved))
    },
  ))
  use coverage <- db(database.query(
    conn,
    "select id::text, kind, rfc3339(starts_at), rfc3339(ends_at),
       rfc3339(admission_end_at), authorized_units, used, reserved,
       revoked_unreserved, confirmation_state,
       case when now() < starts_at then 'upcoming'
            when now() < admission_end_at then 'active'
            else 'ended' end
     from processing_coverage where account_id = $1::uuid
       and (ends_at > now() - interval '31 days' or reserved > 0)
     order by starts_at, id",
    [account],
    {
      use id <- decode.field(0, decode.string)
      use kind <- decode.field(1, decode.string)
      use starts_at <- decode.field(2, decode.string)
      use ends_at <- decode.field(3, decode.string)
      use admission_end_at <- decode.field(4, decode.string)
      use authorized <- decode.field(5, decode.int)
      use used <- decode.field(6, decode.int)
      use reserved <- decode.field(7, decode.int)
      use revoked <- decode.field(8, decode.int)
      use confirmation <- decode.field(9, decode.string)
      use state <- decode.field(10, decode.string)
      let unallocated = case state {
        "active" -> authorized - used - reserved - revoked
        _ -> 0
      }
      decode.success(
        json.object([
          #("coverage_id", json.string(id)),
          #("kind", json.string(kind)),
          #("state", json.string(state)),
          #("starts_at", json.string(starts_at)),
          #("ends_at", json.string(ends_at)),
          #("admission_end_at", json.string(admission_end_at)),
          #("authorized_units", json.int(authorized)),
          #("used", json.int(used)),
          #("reserved", json.int(reserved)),
          #("revoked", json.int(revoked)),
          #("available", json.int(unallocated)),
          #("confirmation_state", json.string(confirmation)),
        ]),
      )
    },
  ))
  use credits <- db(database.query(
    conn,
    "select id::text, granted, reserved, consumed, revoked, rfc3339(expires_at)
     from credit_grants where account_id = $1::uuid
       and (expires_at is null or expires_at > now() or reserved > 0)
     order by expires_at nulls last, id",
    [account],
    {
      use id <- decode.field(0, decode.string)
      use granted <- decode.field(1, decode.int)
      use reserved <- decode.field(2, decode.int)
      use consumed <- decode.field(3, decode.int)
      use revoked <- decode.field(4, decode.int)
      use expires_at <- decode.field(5, decode.optional(decode.string))
      decode.success(
        json.object([
          #("credit_grant_id", json.string(id)),
          #("granted", json.int(granted)),
          #("reserved", json.int(reserved)),
          #("consumed", json.int(consumed)),
          #("revoked", json.int(revoked)),
          #("available", json.int(granted - reserved - consumed - revoked)),
          #("expires_at", context.optional_string(expires_at)),
        ]),
      )
    },
  ))
  use holds <- db(database.query(
    conn,
    "select h.id::text, h.charge_root_operation_id::text, h.state,
       rfc3339(h.claim_deadline)
     from recovery_holds h where h.account_id = $1::uuid and h.state in ('held', 'claimed')
     order by h.claim_deadline",
    [account],
    {
      use id <- decode.field(0, decode.string)
      use root <- decode.field(1, decode.string)
      use state <- decode.field(2, decode.string)
      use deadline <- decode.field(3, decode.string)
      decode.success(
        json.object([
          #("recovery_hold_id", json.string(id)),
          #("charge_root_operation_id", json.string(root)),
          #("state", json.string(state)),
          #("claim_deadline", json.string(deadline)),
        ]),
      )
    },
  ))
  let #(allowance, unlimited, lifetime_used, lifetime_reserved) = lifetime
  let lifetime_limit = lifetime_allowance(ent, allowance, unlimited)
  let warning = case ent.stored_pages {
    Limited(n) if n > 0 -> {
      let pct = { usage.stored_pages + usage.reserved_page_slots } * 100 / n
      case pct {
        p if p >= 100 -> "at_capacity"
        p if p >= 90 -> "above_90_percent"
        p if p >= 80 -> "above_80_percent"
        _ -> "none"
      }
    }
    Limited(_) -> "at_capacity"
    Unlimited -> "none"
  }
  Ok(
    json.object([
      #(
        "limits",
        json.object([
          #("stored_pages", context.limit_json(ent.stored_pages)),
          #("notebooks", context.limit_json(ent.notebooks)),
          #("processing_pages_per_period", context.limit_json(ent.processing)),
        ]),
      ),
      #("entitlement_revision", json.int(ent.revision)),
      #("stored_pages", json.int(usage.stored_pages)),
      #("reserved_page_slots", json.int(usage.reserved_page_slots)),
      #("notebooks", json.int(usage.notebooks)),
      #("capacity_warning", json.string(warning)),
      #(
        "lifetime_allowance",
        json.object([
          #("limit", context.limit_json(lifetime_limit)),
          #("used", json.int(lifetime_used)),
          #("reserved", json.int(lifetime_reserved)),
        ]),
      ),
      #("processing_coverage", json.preprocessed_array(coverage)),
      #("credits", json.preprocessed_array(credits)),
      #("recovery_holds", json.preprocessed_array(holds)),
    ]),
  )
}
