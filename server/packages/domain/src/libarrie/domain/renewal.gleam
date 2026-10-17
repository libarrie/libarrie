//// Provisional renewal coverage while the entitlement authority is unreachable (section 10).
////
//// A `bounded_outage` renewal policy lets core provision the next
//// service-month coverage record itself when the authority has not delivered it:
////
//// - only after the authorized coverage ends (`authorized_through`) and before
////   `authorized_through + max_grace_days` (at most seven days);
//// - never for an account with a closure intent, and never once the authority
////   sends `{"kind":"disabled"}` (a known cancellation);
//// - with a deterministic coverage ID, so the authority confirms or rejects the
////   same record and can never add a second budget for that interval;
//// - with admission ending at the grace end; already admitted work stays
////   valid after that.
////
//// On recovery, the authority confirms the record (same ID, interval and budget,
//// `confirmation_state: confirmed`), which reopens admission to the end of
//// the service month, or revokes it with reason `provisional_rejected`.
//// Units consumed or pinned while provisional are reported as outage
//// exposure.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import libarrie/database.{type Connection}
import libarrie/domain/context
import libarrie/domain/error.{type AppError, db}
import youid/uuid

/// The longest outage grace any policy may request.
pub const max_grace_days = 7

pub type Policy {
  Disabled
  BoundedOutage(
    policy_id: String,
    schedule_id: String,
    /// The original service anchor; anniversaries keep its day and time.
    service_anchor: Timestamp,
    nominal_budget: Int,
    /// End of the last service month the authority authorized.
    authorized_through: Timestamp,
    grace_days: Int,
  )
}

/// Parse the stored or delivered `renewal_policy` JSON.
pub fn parse(text: String) -> Result(Policy, String) {
  let policy = {
    use kind <- decode.field("kind", decode.string)
    case kind {
      "disabled" -> decode.success(Ok(Disabled))
      "bounded_outage" -> {
        use policy_id <- decode.field("policy_id", decode.string)
        use schedule_id <- decode.field("schedule_id", decode.string)
        use anchor <- decode.field("service_anchor", decode.string)
        use budget <- decode.field("nominal_budget", decode.int)
        use through <- decode.field("authorized_through", decode.string)
        use grace <- decode.optional_field("max_grace_days", max_grace_days, decode.int)
        decode.success({
          use anchor <- result.try(timestamp.parse_rfc3339(anchor) |> result.replace_error("service_anchor must be RFC 3339"))
          use through <- result.try(timestamp.parse_rfc3339(through) |> result.replace_error("authorized_through must be RFC 3339"))
          case
            context.is_uuid(policy_id), context.is_uuid(schedule_id),
            budget >= 0, grace >= 1 && grace <= max_grace_days
          {
            True, True, True, True ->
              Ok(BoundedOutage(policy_id, schedule_id, anchor, budget, through, grace))
            False, _, _, _ | _, False, _, _ -> Error("policy_id and schedule_id must be UUIDs")
            _, _, False, _ -> Error("nominal_budget must be non-negative")
            _, _, _, False -> Error("max_grace_days must be between 1 and 7")
          }
        })
      }
      _ -> decode.success(Error("renewal_policy.kind must be disabled or bounded_outage"))
    }
  }
  json.parse(text, policy) |> result.replace_error("renewal_policy is malformed") |> result.flatten
}

// Calendar arithmetic -----------------------------------------------------------------

fn days_in_month(year: Int, month: Int) -> Int {
  case month {
    2 ->
      case calendar.is_leap_year(year) {
        True -> 29
        False -> 28
      }
    4 | 6 | 9 | 11 -> 30
    _ -> 31
  }
}

/// The `k`-th monthly anniversary of `anchor`: the anchor's day clamped to the
/// month's last day, at the anchor's UTC time. Computed from the original
/// anchor every time, so February clamping never drifts later months.
pub fn anniversary(anchor: Timestamp, k: Int) -> Timestamp {
  let #(date, time) = timestamp.to_calendar(anchor, calendar.utc_offset)
  let months = date.year * 12 + calendar.month_to_int(date.month) - 1 + k
  let year = months / 12
  let month = months % 12 + 1
  let assert Ok(month_value) = calendar.month_from_int(month)
  let day = int.min(date.day, days_in_month(year, month))
  timestamp.from_calendar(
    date: calendar.Date(year:, month: month_value, day:),
    time:,
    offset: calendar.utc_offset,
  )
}

/// The first anniversary strictly after `after`.
pub fn next_anniversary(anchor: Timestamp, after: Timestamp) -> Timestamp {
  let #(a, _) = timestamp.to_calendar(anchor, calendar.utc_offset)
  let #(b, _) = timestamp.to_calendar(after, calendar.utc_offset)
  let estimate =
    { b.year * 12 + calendar.month_to_int(b.month) }
    - { a.year * 12 + calendar.month_to_int(a.month) }
  find_after(anchor, after, int.max(1, estimate - 1))
}

fn find_after(anchor: Timestamp, after: Timestamp, k: Int) -> Timestamp {
  let candidate = anniversary(anchor, k)
  case timestamp.compare(candidate, after) {
    order.Gt -> candidate
    _ -> find_after(anchor, after, k + 1)
  }
}

/// Namespace for deterministic provisional coverage IDs.
fn namespace() -> uuid.Uuid {
  let assert Ok(ns) = uuid.from_string("4c1b0a6e-2f5d-5a3e-9c7b-8d1e6f0a2b34")
  ns
}

/// The stable coverage ID for one provisional interval of one policy.
pub fn provisional_id(authority: String, policy: Policy, starts_at: Timestamp) -> Option(String) {
  case policy {
    Disabled -> None
    BoundedOutage(policy_id:, schedule_id:, ..) -> {
      let name =
        "provisional-renewal:" <> authority <> ":" <> policy_id <> ":" <> schedule_id <> ":"
        <> timestamp.to_rfc3339(starts_at, calendar.utc_offset)
      uuid.v5(namespace(), <<name:utf8>>) |> result.map(uuid.to_string) |> option.from_result
    }
  }
}

// Provisioning ----------------------------------------------------------------------------

/// Issue the provisional record for the current outage window, if one is
/// due. Called under the account and usage locks (lock order level 2), from
/// processing admission, so a boundary is honored the moment it passes.
pub fn provision(conn: Connection, account_id: String) -> Result(Option(String), AppError) {
  let account = database.text(account_id)
  use row <- db(database.query_one(
    conn,
    "select e.authority, e.revision, e.renewal_policy::text, a.status,
       rfc3339(now())
     from entitlement_assignments e join accounts a on a.id = e.account_id
     where e.account_id = $1::uuid and e.effective_at <= now()
     order by e.effective_at desc, e.revision desc limit 1",
    [account],
    {
      use authority <- decode.field(0, decode.string)
      use revision <- decode.field(1, decode.int)
      use policy <- decode.field(2, decode.string)
      use status <- decode.field(3, decode.string)
      use now <- decode.field(4, decode.string)
      decode.success(#(authority, revision, policy, status, now))
    },
  ))
  case row {
    None -> Ok(None)
    Some(#(authority, revision, policy_text, status, now_text)) ->
      case parse(policy_text), timestamp.parse_rfc3339(now_text) {
        Ok(BoundedOutage(..) as policy), Ok(now) if status == "active" ->
          provision_window(conn, account_id, authority, revision, policy, now)
        _, _ -> Ok(None)
      }
  }
}

fn provision_window(
  conn: Connection,
  account_id: String,
  authority: String,
  revision: Int,
  policy: Policy,
  now: Timestamp,
) -> Result(Option(String), AppError) {
  let assert BoundedOutage(policy_id:, service_anchor:, nominal_budget:, authorized_through:, grace_days:, ..) = policy
  let grace_end = timestamp.add(authorized_through, duration.hours(24 * grace_days))
  let in_window =
    timestamp.compare(now, authorized_through) != order.Lt
    && timestamp.compare(now, grace_end) == order.Lt
  case in_window, provisional_id(authority, policy, authorized_through) {
    True, Some(id) -> {
      let ends_at = next_anniversary(service_anchor, authorized_through)
      let admission_end = case timestamp.compare(grace_end, ends_at) {
        order.Lt -> grace_end
        _ -> ends_at
      }
      let rfc = fn(t) { timestamp.to_rfc3339(t, calendar.utc_offset) }
      // Skip if it exists, or if the authority already covers the interval.
      use inserted <- db(database.execute(
        conn,
        "insert into processing_coverage (id, account_id, authority, kind, starts_at,
           ends_at, admission_end_at, authorized_units, authority_revision,
           confirmation_state, renewal_policy_id, provisioned_at)
         select $1::uuid, $2::uuid, $3, 'base', $4::text::timestamptz, $5::text::timestamptz,
           $6::text::timestamptz, $7, $8, 'provisional', $9::uuid, now()
         where not exists (select 1 from processing_coverage where id = $1::uuid)
           and not exists (
             select 1 from processing_coverage
             where account_id = $2::uuid and kind = 'base'
               and starts_at < admission_end_at
               and starts_at < $5::text::timestamptz
               and admission_end_at > $4::text::timestamptz)",
        [
          database.text(id),
          database.text(account_id),
          database.text(authority),
          database.text(rfc(authorized_through)),
          database.text(rfc(ends_at)),
          database.text(rfc(admission_end)),
          database.int(nominal_budget),
          database.int(revision),
          database.text(policy_id),
        ],
      ))
      Ok(case inserted {
        0 -> None
        _ -> Some(id)
      })
    }
    _, _ -> Ok(None)
  }
}
