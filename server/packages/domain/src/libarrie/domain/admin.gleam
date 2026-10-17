//// Deployment roles (ADR 0011): owners and admins administer the deployment
//// from the web UI. Roles belong to people (users), are read from the
//// database on every request, and never grant access to anyone's notes.
////
//// Rules that always hold:
//// - at least one owner with an active account exists once ownership has
////   been claimed (the last one cannot be demoted or schedule closure);
//// - only owners can make or remove owners, and admins can never change an
////   owner's role;
//// - admins can grant and remove the admin role;
//// - every role change is written to the audit log.
////
//// Admin actions check a named permission, never a role, so deciding later
//// that something is owner-only changes `can` alone.

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import libarrie/database.{type Connection}
import libarrie/domain/context.{type Context}
import libarrie/domain/error.{type AppError, db}
import youid/uuid

pub type Role {
  Owner
  Admin
}

pub type Permission {
  /// See the admin area: users, roles, the audit log.
  ViewAdmin
  /// Grant and remove the admin role.
  ManageAdmins
  /// Grant and remove the owner role.
  ManageOwners
  /// Block and unblock accounts (`moderation`; owners only for people who
  /// hold a role).
  BlockUsers
  /// Schedule and cancel account deletion (same rule as blocking).
  DeleteUsers
}

pub fn can(role: Option(Role), permission: Permission) -> Bool {
  case role, permission {
    Some(Owner), _ -> True
    Some(Admin), ViewAdmin
    | Some(Admin), ManageAdmins
    | Some(Admin), BlockUsers
    | Some(Admin), DeleteUsers
    -> True
    _, _ -> False
  }
}

pub fn parse_role(value: Option(String)) -> Option(Role) {
  case value {
    Some("owner") -> Some(Owner)
    Some("admin") -> Some(Admin)
    _ -> None
  }
}

pub fn role_name(role: Option(Role)) -> String {
  case role {
    Some(Owner) -> "owner"
    Some(Admin) -> "admin"
    None -> "none"
  }
}

fn role_value(role: Option(Role)) {
  case role {
    Some(r) -> database.text(role_name(Some(r)))
    None -> database.null()
  }
}

pub fn role_of(conn: Connection, user_id: String) -> Result(Option(Role), AppError) {
  use row <- db(database.query_one(
    conn,
    "select role from users where id = $1::uuid",
    [database.text(user_id)],
    decode.at([0], decode.optional(decode.string)),
  ))
  Ok(parse_role(option.flatten(row)))
}

// Owners ---------------------------------------------------------------------------------

/// Owners whose accounts are active, optionally excluding one user.
fn active_owners(conn: Connection, excluding: Option(String)) -> Result(Int, AppError) {
  use row <- db(database.query_one(
    conn,
    "select count(*)::int from users u join accounts a on a.owner_user_id = u.id
     where u.role = 'owner' and a.status = 'active' and a.suspended_at is null
       and ($1::uuid is null or u.id <> $1::uuid)",
    [database.nullable_text(excluding)],
    decode.at([0], decode.int),
  ))
  Ok(option.unwrap(row, 0))
}

pub fn owner_exists(conn: Connection) -> Result(Bool, AppError) {
  active_owners(conn, None) |> result.map(fn(n) { n > 0 })
}

/// Account closure must not remove the last owner: transfer first.
pub fn check_not_last_owner(conn: Connection, account_id: String) -> Result(Nil, AppError) {
  use row <- db(database.query_one(
    conn,
    "select u.id::text, u.role from accounts a join users u on u.id = a.owner_user_id
     where a.id = $1::uuid",
    [database.text(account_id)],
    {
      use id <- decode.field(0, decode.string)
      use role <- decode.field(1, decode.optional(decode.string))
      decode.success(#(id, role))
    },
  ))
  case row {
    Some(#(user_id, Some("owner"))) -> {
      use others <- result.try(active_owners(conn, Some(user_id)))
      case others {
        0 ->
          Error(error.new(
            409,
            "last_owner",
            "You are the only owner of this server. Make someone else an owner before deleting your account.",
          ))
        _ -> Ok(Nil)
      }
    }
    _ -> Ok(Nil)
  }
}

// Setup and recovery codes -------------------------------------------------------------------

const code_lifetime_seconds = 86_400

/// Crockford base32 without I, L, O and U: unambiguous when read from a log.
const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

fn new_code() -> String {
  let symbols = string.to_graphemes(alphabet)
  crypto.strong_random_bytes(16)
  |> bit_array_to_list
  |> list.map(fn(byte) {
    let assert Ok(symbol) = list_at(symbols, byte % 32)
    symbol
  })
  |> list.sized_chunk(4)
  |> list.map(string.concat)
  |> string.join("-")
}

fn bit_array_to_list(bits: BitArray) -> List(Int) {
  case bits {
    <<byte, rest:bytes>> -> [byte, ..bit_array_to_list(rest)]
    _ -> []
  }
}

fn list_at(items: List(a), index: Int) -> Result(a, Nil) {
  items |> list.drop(index) |> list.first
}

/// Codes are compared without case, spaces or dashes.
fn normalize(code: String) -> String {
  code
  |> string.uppercase
  |> string.replace(" ", "")
  |> string.replace("-", "")
}

fn code_hash(code: String) -> BitArray {
  crypto.hash(crypto.Sha256, bit_array.from_string(normalize(code)))
}

/// Create a code and return it (only its hash is stored). `kind` is
/// `setup` (claimable while no owner exists) or `recovery` (claimable even
/// when owners exist; issued only by the operator command).
pub fn issue_code(ctx: Context, kind: String) -> Result(String, AppError) {
  let code = new_code()
  use _ <- db(database.execute(
    ctx.db,
    "insert into owner_setup_codes (id, code_hash, kind, expires_at)
     values ($1::uuid, $2, $3, now() + make_interval(secs => $4))",
    [
      database.text(uuid.v7_string()),
      database.bytea(code_hash(code)),
      database.text(kind),
      database.int(code_lifetime_seconds),
    ],
  ))
  Ok(code)
}

/// At startup: a fresh setup code while nobody has claimed ownership.
pub fn issue_setup_code_if_needed(ctx: Context) -> Result(Option(String), AppError) {
  use exists <- result.try(owner_exists(ctx.db))
  case exists {
    True -> Ok(None)
    False -> issue_code(ctx, "setup") |> result.map(Some)
  }
}

/// `/setup` is offered while no owner exists, or while a recovery code is
/// outstanding.
pub fn setup_available(conn: Connection) -> Result(Bool, AppError) {
  use exists <- result.try(owner_exists(conn))
  use recovery <- db(database.query_one(
    conn,
    "select count(*)::int from owner_setup_codes
     where kind = 'recovery' and claimed_at is null and expires_at > now()",
    [],
    decode.at([0], decode.int),
  ))
  Ok(!exists || option.unwrap(recovery, 0) > 0)
}

fn invalid_code() -> AppError {
  error.new(403, "invalid_setup_code", "That code is not valid. Check the server log for the current code.")
}

/// Claim ownership with a code. Codes are single-use; claims are serialized
/// so two people cannot both claim with one setup code.
pub fn claim(ctx: Context, user_id: String, code: String) -> Result(Nil, AppError) {
  context.transaction(ctx, fn(tx) {
    use _ <- db(database.execute(
      tx,
      // The lock function returns `void`, which the driver cannot decode.
      "select count(*) from (select pg_advisory_xact_lock(hashtext('libarrie:owner-setup'))) l",
      [],
    ))
    use found <- db(database.query_one(
      tx,
      "select id::text, kind from owner_setup_codes
       where code_hash = $1 and claimed_at is null and expires_at > now()",
      [database.bytea(code_hash(code))],
      {
        use id <- decode.field(0, decode.string)
        use kind <- decode.field(1, decode.string)
        decode.success(#(id, kind))
      },
    ))
    use #(code_id, kind) <- result.try(option.to_result(found, invalid_code()))
    use exists <- result.try(owner_exists(tx))
    use <- error.guard(
      kind == "recovery" || !exists,
      error.new(409, "setup_complete", "This server already has an owner. Ask an owner for access."),
    )
    use active <- db(database.query_one(
      tx,
      "select a.status = 'active' from accounts a where a.owner_user_id = $1::uuid",
      [database.text(user_id)],
      decode.at([0], decode.bool),
    ))
    use <- error.guard(active == Some(True), error.account_closing())
    use _ <- db(database.execute(
      tx,
      "update owner_setup_codes set claimed_at = now(), claimed_by = $2::uuid where id = $1::uuid",
      [database.text(code_id), database.text(user_id)],
    ))
    use previous <- result.try(role_of(tx, user_id))
    use _ <- db(database.execute(
      tx,
      "update users set role = 'owner' where id = $1::uuid",
      [database.text(user_id)],
    ))
    record(tx, Some(user_id), "owner.claimed", Some(user_id), [
      #("code_kind", json.string(kind)),
      #("from", json.string(role_name(previous))),
    ])
  })
}

/// `LIBARRIE_OWNER`: the configured identity is made an owner when it signs
/// in. While the setting names it, it stays an owner.
pub fn apply_configured_owner(ctx: Context, user_id: String, subject: String) -> Result(Nil, AppError) {
  case ctx.config.configured_owner {
    Some(owner) if owner == subject -> {
      use current <- result.try(role_of(ctx.db, user_id))
      case current {
        Some(Owner) -> Ok(Nil)
        _ ->
          context.transaction(ctx, fn(tx) {
            use _ <- db(database.execute(
              tx,
              "update users set role = 'owner' where id = $1::uuid",
              [database.text(user_id)],
            ))
            record(tx, None, "owner.configured", Some(user_id), [
              #("from", json.string(role_name(current))),
            ])
          })
      }
    }
    _ -> Ok(Nil)
  }
}

// Role changes --------------------------------------------------------------------------------

/// Change `target`'s role on behalf of `actor`, enforcing the rules in the
/// module documentation. Recent authentication is checked by the caller.
pub fn set_role(
  ctx: Context,
  actor_id: String,
  target_id: String,
  role: Option(Role),
) -> Result(Nil, AppError) {
  context.transaction(ctx, fn(tx) {
    // Serialize owner changes, so two demotions cannot both pass the
    // last-owner check.
    use _ <- db(database.execute(
      tx,
      // The lock function returns `void`, which the driver cannot decode.
      "select count(*) from (select pg_advisory_xact_lock(hashtext('libarrie:owner-setup'))) l",
      [],
    ))
    use actor <- result.try(role_of(tx, actor_id))
    use <- error.guard(can(actor, ManageAdmins), error.forbidden("Only admins and owners can change roles."))
    use target <- error.found(database.query_one(
      tx,
      "select u.role, case when a.suspended_at is null then a.status else 'suspended' end
       from users u join accounts a on a.owner_user_id = u.id
       where u.id = $1::uuid for update of u",
      [database.text(target_id)],
      {
        use role <- decode.field(0, decode.optional(decode.string))
        use status <- decode.field(1, decode.string)
        decode.success(#(parse_role(role), status))
      },
    ))
    let #(current, status) = target
    case current == role {
      True -> Ok(Nil)
      False -> {
        let touches_owner = current == Some(Owner) || role == Some(Owner)
        use <- error.guard(
          !touches_owner || can(actor, ManageOwners),
          error.new(403, "owner_required", "Only owners can make or remove owners."),
        )
        use <- error.guard(
          role == None || status == "active",
          error.new(409, "account_not_active", "Only people with active accounts can be given a role."),
        )
        use _ <- result.try(case current == Some(Owner) {
          False -> Ok(Nil)
          True -> {
            use others <- result.try(active_owners(tx, Some(target_id)))
            case others {
              0 ->
                Error(error.new(
                  409,
                  "last_owner",
                  "This is the only owner. Make someone else an owner first.",
                ))
              _ -> Ok(Nil)
            }
          }
        })
        use _ <- db(database.execute(
          tx,
          "update users set role = $2 where id = $1::uuid",
          [database.text(target_id), role_value(role)],
        ))
        record(tx, Some(actor_id), "role.changed", Some(target_id), [
          #("from", json.string(role_name(current))),
          #("to", json.string(role_name(role))),
        ])
      }
    }
  })
}

// Users ------------------------------------------------------------------------------------

pub type User {
  User(
    user_id: String,
    display_name: String,
    email: Option(String),
    subject: Option(String),
    role: Option(Role),
    account_status: String,
    created_at: String,
    blocked: Bool,
    /// When a scheduled deletion takes effect.
    deletion_at: Option(String),
  )
}

fn user_decoder() -> decode.Decoder(User) {
  use id <- decode.field(0, decode.string)
  use name <- decode.field(1, decode.string)
  use email <- decode.field(2, decode.optional(decode.string))
  use subject <- decode.field(3, decode.optional(decode.string))
  use role <- decode.field(4, decode.optional(decode.string))
  use status <- decode.field(5, decode.string)
  use created <- decode.field(6, decode.string)
  use blocked <- decode.field(7, decode.bool)
  use deletion_at <- decode.field(8, decode.optional(decode.string))
  decode.success(User(id, name, email, subject, parse_role(role), status, created, blocked, deletion_at))
}

const user_columns = "u.id::text, u.display_name, u.email,
  (select subject from identities i where i.user_id = u.id order by i.subject limit 1),
  u.role, a.status, rfc3339(u.created_at), a.suspended_at is not null,
  case when a.status = 'closure_scheduled' then rfc3339(a.closure_effective_at) end
  from users u join accounts a on a.owner_user_id = u.id"

/// Users matching `query` (name, email or sign-in subject), owners and
/// admins first. An empty query lists everyone.
pub fn search_users(conn: Connection, query: String, limit: Int) -> Result(List(User), AppError) {
  let pattern = "%" <> escape_like(string.trim(query)) <> "%"
  db(
    database.query(
      conn,
      "select " <> user_columns <> "
       where a.status <> 'closed'
         and ($1 = '%%' or u.display_name ilike $1 or u.email ilike $1
              or exists (select 1 from identities i where i.user_id = u.id and i.subject ilike $1))
       order by case u.role when 'owner' then 0 when 'admin' then 1 else 2 end,
         lower(u.display_name), u.created_at
       limit $2",
      [database.text(pattern), database.int(limit)],
      user_decoder(),
    ),
    Ok,
  )
}

fn escape_like(value: String) -> String {
  value
  |> string.replace("\\", "\\\\")
  |> string.replace("%", "\\%")
  |> string.replace("_", "\\_")
}

pub fn find_user(conn: Connection, user_id: String) -> Result(Option(User), AppError) {
  db(
    database.query_one(conn, "select " <> user_columns <> " where u.id = $1::uuid", [database.text(user_id)], user_decoder()),
    Ok,
  )
}

/// The latest email the identity provider sent at sign-in, if any.
pub fn record_email(conn: Connection, user_id: String, email: Option(String)) -> Result(Nil, AppError) {
  case email {
    None -> Ok(Nil)
    Some(address) ->
      db(
        database.execute(
          conn,
          "update users set email = $2 where id = $1::uuid and email is distinct from $2",
          [database.text(user_id), database.text(string.slice(address, 0, 320))],
        ),
        fn(_) { Ok(Nil) },
      )
  }
}

// Audit log ----------------------------------------------------------------------------------

/// Add an audit-log entry (also used by `moderation`).
pub fn record(
  conn: Connection,
  actor: Option(String),
  action: String,
  target: Option(String),
  detail: List(#(String, json.Json)),
) -> Result(Nil, AppError) {
  db(
    database.execute(
      conn,
      "insert into admin_audit_log (id, actor_user_id, action, target_user_id, detail)
       values ($1::uuid, $2::uuid, $3, $4::uuid, $5::jsonb)",
      [
        database.text(uuid.v7_string()),
        database.nullable_text(actor),
        database.text(action),
        database.nullable_text(target),
        database.text(json.to_string(json.object(detail))),
      ],
    ),
    fn(_) { Ok(Nil) },
  )
}

pub type AuditEntry {
  AuditEntry(
    actor: Option(String),
    action: String,
    target: Option(String),
    from: Option(String),
    to: Option(String),
    created_at: String,
  )
}

pub fn audit_log(conn: Connection, limit: Int) -> Result(List(AuditEntry), AppError) {
  db(
    database.query(
      conn,
      "select actor.display_name, l.action, target.display_name,
         l.detail ->> 'from', l.detail ->> 'to', rfc3339(l.created_at)
       from admin_audit_log l
       left join users actor on actor.id = l.actor_user_id
       left join users target on target.id = l.target_user_id
       order by l.created_at desc limit $1",
      [database.int(limit)],
      {
        use actor <- decode.field(0, decode.optional(decode.string))
        use action <- decode.field(1, decode.string)
        use target <- decode.field(2, decode.optional(decode.string))
        use from <- decode.field(3, decode.optional(decode.string))
        use to <- decode.field(4, decode.optional(decode.string))
        use created <- decode.field(5, decode.string)
        decode.success(AuditEntry(actor, action, target, from, to, created))
      },
    ),
    Ok,
  )
}
