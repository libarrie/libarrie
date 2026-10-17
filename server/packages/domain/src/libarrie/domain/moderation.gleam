//// Blocking and deleting people's accounts from the admin area (ADR 0011).
////
//// - Admins may block or delete regular users; owners may also block or
////   delete admins and other owners. Nobody acts on themselves, and the last
////   owner can never be blocked or deleted.
//// - A blocked account keeps all its data. Its owner can still sign in, see
////   a notice and download an export, but nothing else; processing pauses.
////   Unblocking restores everything.
//// - Deleting blocks the account and schedules the normal closure, with its
////   grace period and export window. During the grace period an admin can
////   cancel the deletion (the account stays blocked until unblocked).
//// - Every action is in the audit log.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import libarrie/database.{type Connection}
import libarrie/domain/admin.{type Role, Owner}
import libarrie/domain/closure
import libarrie/domain/context.{type Context}
import libarrie/domain/error.{type AppError, db}

type Target {
  Target(account_id: String, role: Option(Role), status: String, suspended: Bool, lifecycle_revision: Int)
}

fn load_target(conn: Connection, user_id: String, lock: Bool) -> Result(Target, AppError) {
  use target <- error.found(database.query_one(
    conn,
    "select a.id::text, u.role, a.status, a.suspended_at is not null, a.lifecycle_revision
     from users u join accounts a on a.owner_user_id = u.id where u.id = $1::uuid"
      <> case lock {
      True -> " for update of a"
      False -> ""
    },
    [database.text(user_id)],
    {
      use account <- decode.field(0, decode.string)
      use role <- decode.field(1, decode.optional(decode.string))
      use status <- decode.field(2, decode.string)
      use suspended <- decode.field(3, decode.bool)
      use revision <- decode.field(4, decode.int)
      decode.success(Target(account, admin.parse_role(role), status, suspended, revision))
    },
  ))
  Ok(target)
}

/// Checks shared by every action: permission, never yourself, and only
/// owners act on people who hold a role.
fn authorize(
  conn: Connection,
  actor_id: String,
  target_id: String,
  permission: admin.Permission,
) -> Result(Option(Role), AppError) {
  use actor <- result.try(admin.role_of(conn, actor_id))
  use <- error.guard(admin.can(actor, permission), error.forbidden("Only admins and owners can do this."))
  use <- error.guard(
    actor_id != target_id,
    error.new(409, "cannot_moderate_self", "You can't block or delete your own account here."),
  )
  Ok(actor)
}

fn check_target(actor: Option(Role), target: Target) -> Result(Nil, AppError) {
  case target.role, actor {
    None, _ -> Ok(Nil)
    Some(_), Some(Owner) -> Ok(Nil)
    Some(_), _ ->
      Error(error.new(403, "owner_required", "Only owners can block or delete admins and owners."))
  }
}

fn serialize(tx: Connection) -> Result(Nil, AppError) {
  db(
    database.execute(
      tx,
      "select count(*) from (select pg_advisory_xact_lock(hashtext('libarrie:owner-setup'))) l",
      [],
    ),
    fn(_) { Ok(Nil) },
  )
}

fn not_last_owner(tx: Connection, target_id: String, target: Target) -> Result(Nil, AppError) {
  case target.role {
    Some(Owner) -> {
      use others <- db(database.query_one(
        tx,
        "select count(*)::int from users u join accounts a on a.owner_user_id = u.id
         where u.role = 'owner' and a.status = 'active' and a.suspended_at is null
           and u.id <> $1::uuid",
        [database.text(target_id)],
        decode.at([0], decode.int),
      ))
      case option.unwrap(others, 0) {
        0 -> Error(error.new(409, "last_owner", "This is the only owner. Make someone else an owner first."))
        _ -> Ok(Nil)
      }
    }
    _ -> Ok(Nil)
  }
}

/// Block `target_id`'s account. Blocking an already blocked account is a
/// no-op.
pub fn block(ctx: Context, actor_id: String, target_id: String, reason: String) -> Result(Nil, AppError) {
  context.transaction(ctx, fn(tx) {
    use _ <- result.try(serialize(tx))
    use actor <- result.try(authorize(tx, actor_id, target_id, admin.BlockUsers))
    use target <- result.try(load_target(tx, target_id, True))
    use _ <- result.try(check_target(actor, target))
    use _ <- result.try(not_last_owner(tx, target_id, target))
    case target.suspended {
      True -> Ok(Nil)
      False -> suspend(tx, actor_id, target_id, target, reason)
    }
  })
}

fn suspend(tx: Connection, actor_id: String, target_id: String, target: Target, reason: String) -> Result(Nil, AppError) {
  let reason = string.slice(string.trim(reason), 0, 500)
  use _ <- db(database.execute(
    tx,
    "update accounts set suspended_at = now(), suspended_by = $2::uuid, suspension_reason = nullif($3, '')
     where id = $1::uuid",
    [database.text(target.account_id), database.text(actor_id), database.text(reason)],
  ))
  admin.record(tx, Some(actor_id), "user.blocked", Some(target_id), [#("reason", json.string(reason))])
}

/// Unblock `target_id`'s account. An account scheduled for deletion must
/// have the deletion cancelled first.
pub fn unblock(ctx: Context, actor_id: String, target_id: String) -> Result(Nil, AppError) {
  context.transaction(ctx, fn(tx) {
    use _ <- result.try(serialize(tx))
    use actor <- result.try(authorize(tx, actor_id, target_id, admin.BlockUsers))
    use target <- result.try(load_target(tx, target_id, True))
    use _ <- result.try(check_target(actor, target))
    use <- error.guard(
      target.status == "active",
      error.new(409, "deletion_scheduled", "Cancel the scheduled deletion before unblocking this account."),
    )
    case target.suspended {
      False -> Ok(Nil)
      True -> {
        use _ <- db(database.execute(
          tx,
          "update accounts set suspended_at = null, suspended_by = null, suspension_reason = null
           where id = $1::uuid",
          [database.text(target.account_id)],
        ))
        // Work postponed while blocked resumes now rather than at its next
        // scheduled try.
        use _ <- db(database.execute(
          tx,
          "update jobs set run_after = now()
           where account_id = $1::uuid and state in ('pending', 'retryable')
             and last_error = 'account_suspended'",
          [database.text(target.account_id)],
        ))
        admin.record(tx, Some(actor_id), "user.unblocked", Some(target_id), [])
      }
    }
  })
}

/// Block the account and schedule its deletion with the normal grace
/// period. Returns when the account will be deleted (RFC 3339).
pub fn delete(ctx: Context, actor_id: String, target_id: String) -> Result(String, AppError) {
  use target <- result.try(
    context.transaction(ctx, fn(tx) {
      use _ <- result.try(serialize(tx))
      use actor <- result.try(authorize(tx, actor_id, target_id, admin.DeleteUsers))
      use target <- result.try(load_target(tx, target_id, True))
      use _ <- result.try(check_target(actor, target))
      use _ <- result.try(not_last_owner(tx, target_id, target))
      use <- error.guard(
        target.status == "active",
        error.new(409, "closure_already_scheduled", "This account is already being deleted."),
      )
      use _ <- result.try(case target.suspended {
        True -> Ok(Nil)
        False -> suspend(tx, actor_id, target_id, target, "Account deletion")
      })
      Ok(target)
    }),
  )
  // The person cannot confirm anything, so any coverage-end notice is
  // acknowledged on their behalf; the export window still applies.
  use #(_, body) <- result.try(closure.schedule(ctx, target.account_id, closure.ScheduleRequest(True)))
  let effective_at =
    json.parse(json.to_string(body), decode.at(["effective_at"], decode.string)) |> result.unwrap("")
  use _ <- result.try(
    admin.record(ctx.db, Some(actor_id), "user.deletion_scheduled", Some(target_id), [
      #("effective_at", json.string(effective_at)),
    ]),
  )
  Ok(effective_at)
}

/// Cancel a deletion an admin scheduled (the account stays blocked).
pub fn cancel_deletion(ctx: Context, actor_id: String, target_id: String) -> Result(Nil, AppError) {
  use target <- result.try(
    context.transaction(ctx, fn(tx) {
      use actor <- result.try(authorize(tx, actor_id, target_id, admin.DeleteUsers))
      use target <- result.try(load_target(tx, target_id, False))
      use _ <- result.try(check_target(actor, target))
      use <- error.guard(
        target.status == "closure_scheduled" && target.suspended,
        error.new(409, "no_admin_deletion", "This account has no deletion scheduled by an admin."),
      )
      Ok(target)
    }),
  )
  use _ <- result.try(closure.cancel(ctx, target.account_id, Some(target.lifecycle_revision)))
  admin.record(ctx.db, Some(actor_id), "user.deletion_cancelled", Some(target_id), [])
}

/// Whether processing for an account should wait (it is blocked).
pub fn suspended(conn: Connection, account_id: String) -> Result(Bool, AppError) {
  use row <- db(database.query_one(
    conn,
    "select suspended_at is not null from accounts where id = $1::uuid",
    [database.text(account_id)],
    decode.at([0], decode.bool),
  ))
  Ok(row == Some(True))
}
