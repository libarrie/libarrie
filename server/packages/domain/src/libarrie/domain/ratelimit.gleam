//// Abuse rate limits (sections 9 and 16). These are operational controls
//// with documented defaults, not metered query counters. Counters live in
//// Postgres so limits hold across API replicas.

import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option.{Some}
import libarrie/database.{type Connection}
import libarrie/domain/error.{type AppError, db}

fn limited(retry_after: Int, scope: String) -> AppError {
  error.AppError(
    ..error.new(429, "rate_limited", "Too many requests; slow down and retry.")
    |> error.with_details([#("scope", json.string(scope))]),
    retry_after: Some(int.max(1, retry_after)),
  )
}

/// Fixed-window counter: at most `limit` hits per `window_seconds` for `key`.
pub fn hit(
  conn: Connection,
  key: String,
  scope: String,
  limit: Int,
  window_seconds: Int,
) -> Result(Nil, AppError) {
  use row <- db(database.query_one(
    conn,
    "insert into rate_limit_counters (key, window_start, count)
     values ($1, to_timestamp(floor(extract(epoch from now()) / $2) * $2), 1)
     on conflict (key, window_start) do update set count = rate_limit_counters.count + 1
     returning count,
       ceil(extract(epoch from window_start + make_interval(secs => $2) - now()))::int",
    [database.text(key), database.int(window_seconds)],
    {
      use count <- decode.field(0, decode.int)
      use remaining <- decode.field(1, decode.int)
      decode.success(#(count, remaining))
    },
  ))
  case row {
    Some(#(count, remaining)) if count > limit -> Error(limited(remaining, scope))
    _ -> Ok(Nil)
  }
}

/// Sixty saved corrections per page per rolling hour.
pub fn corrections(
  conn: Connection,
  account_id: String,
  page_id: String,
  limit: Int,
) -> Result(Nil, AppError) {
  use count <- error.found(database.query_one(
    conn,
    "select count(*)::int from transcript_revisions t
     join page_revisions r on r.id = t.revision_id
     where t.account_id = $1::uuid and r.page_id = $2::uuid and t.origin = 'user'
       and t.created_at > now() - interval '1 hour'",
    [database.text(account_id), database.text(page_id)],
    decode.at([0], decode.int),
  ))
  case count >= limit {
    True -> Error(limited(60, "corrections_per_page"))
    False -> Ok(Nil)
  }
}

/// Three user-requested rescans per page per rolling 24 hours.
pub fn rescans(
  conn: Connection,
  account_id: String,
  page_id: String,
  limit: Int,
) -> Result(Nil, AppError) {
  use count <- error.found(database.query_one(
    conn,
    "select count(*)::int from operations
     where account_id = $1::uuid and page_id = $2::uuid and kind = 'reprocess'
       and created_at > now() - interval '24 hours'",
    [database.text(account_id), database.text(page_id)],
    decode.at([0], decode.int),
  ))
  case count >= limit {
    True -> Error(limited(3600, "rescans_per_page"))
    False -> Ok(Nil)
  }
}

/// Remove expired counter windows (maintenance).
pub fn prune(conn: Connection) -> Result(Int, AppError) {
  use n <- db(database.execute(
    conn,
    "delete from rate_limit_counters where window_start < now() - interval '2 days'",
    [],
  ))
  Ok(n)
}
