//// Lazy expiry of abandoned upload reservations (section 5).
////
//// Time passing alone does not execute a database transition. Before testing
//// quota or page-number conflicts, admission, restore and renumber paths
//// expire the account's abandoned reservations using database time, under
//// the account lock. Cleanup is bounded per request; when more remain the
//// caller returns a retryable `cleanup_pending` instead of a false conflict.
//// The background sweeper calls the same function.

import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import libarrie/database.{type Connection}
import libarrie/domain/error.{type AppError, db}
import libarrie/domain/operations

pub type Outcome {
  Done(expired: Int)
  MoreRemain(expired: Int)
}

/// Requires the account row lock. Expires at most `limit` reservations.
pub fn expire_abandoned(
  conn: Connection,
  account_id: String,
  limit: Int,
) -> Result(Outcome, AppError) {
  use candidates <- db(database.query(
    conn,
    "select operation_id::text from upload_sessions
     where account_id = $1::uuid and status = 'awaiting_upload'
       and expires_at <= now()
     order by expires_at, id limit $2",
    [database.text(account_id), database.int(limit + 1)],
    decode.at([0], decode.string),
  ))
  let batch = list.take(candidates, limit)
  use expired <- result.try(
    list.try_fold(batch, 0, fn(count, operation_id) {
      use op <- result.try(operations.load(conn, account_id, operation_id, True))
      case op {
        // Revalidate under lock: completion may already have won acceptance.
        Some(op) if op.status == "awaiting_upload" -> {
          use _ <- result.try(operations.end_unaccepted(
            conn,
            account_id,
            op,
            "expired",
            None,
            Some("upload_expired"),
          ))
          Ok(count + 1)
        }
        _ -> Ok(count)
      }
    }),
  )
  case list.length(candidates) > limit {
    True -> Ok(MoreRemain(expired))
    False -> Ok(Done(expired))
  }
}

/// Run lazy expiry and convert remaining backlog into `cleanup_pending`.
pub fn require_clean(
  conn: Connection,
  account_id: String,
  limit: Int,
) -> Result(Nil, AppError) {
  use outcome <- result.try(expire_abandoned(conn, account_id, limit))
  case outcome {
    Done(_) -> Ok(Nil)
    MoreRemain(_) -> Error(error.cleanup_pending())
  }
}

/// Accounts with expired, unaccepted reservations (for the sweeper).
pub fn accounts_needing_sweep(
  conn: Connection,
  limit: Int,
) -> Result(List(String), AppError) {
  use rows <- db(database.query(
    conn,
    "select distinct account_id::text from upload_sessions
     where status = 'awaiting_upload' and expires_at <= now() limit $1",
    [database.int(limit)],
    decode.at([0], decode.string),
  ))
  Ok(rows)
}
