//// Identity-to-account mapping and account provisioning (sections 5 and 6).
////
//// Tenant identifiers always come from trusted authentication. MVP has one
//// personal account per user. Users are identified by (issuer, subject),
//// never solely by email.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import libarrie/database.{type Connection}
import libarrie/domain/context.{type Context}
import libarrie/domain/error.{type AppError, db}
import libarrie/domain/journal
import libarrie/integrations/identity
import youid/uuid

pub type Principal {
  Principal(
    user_id: String,
    account_id: String,
    display_name: String,
    account_status: String,
    auth_time: Option(Int),
  )
}

/// Blocked by an admin: sign-in allows exports and the account notice only.
pub fn is_suspended(principal: Principal) -> Bool {
  principal.account_status == "suspended"
}

pub fn can_read(principal: Principal) -> Bool {
  principal.account_status == "active"
  || principal.account_status == "closure_scheduled"
}

/// Resolve the account for a verified identity, provisioning a new user and
/// account on first sign-in.
pub fn resolve(
  ctx: Context,
  issuer: String,
  subject: String,
  display_name: Option(String),
  auth_time: Option(Int),
) -> Result(Principal, AppError) {
  use existing <- db(lookup(ctx.db, issuer, subject))
  case existing {
    Some(#(user_id, account_id, name, status)) ->
      Ok(Principal(user_id, account_id, name, status, auth_time))
    None -> {
      use _ <- result.try(reject_purged_identity(ctx, issuer, subject))
      case provision(ctx, issuer, subject, option.unwrap(display_name, "")) {
        Ok(_) -> Nil
        // A concurrent first sign-in won the identity insert.
        Error(_) -> Nil
      }
      use found <- db(lookup(ctx.db, issuer, subject))
      case found {
        Some(#(user_id, account_id, name, status)) ->
          Ok(Principal(user_id, account_id, name, status, auth_time))
        None -> Error(error.internal("account provisioning failed"))
      }
    }
  }
}

fn lookup(
  conn: Connection,
  issuer: String,
  subject: String,
) -> Result(Option(#(String, String, String, String)), database.QueryError) {
  database.query_one(
    conn,
    // A blocked account reads as `suspended`: not `can_read`, so every
    // entry point restricts it (ADR 0011).
    "select u.id::text, a.id::text, u.display_name,
       case when a.suspended_at is not null and a.status in ('active', 'closure_scheduled') then 'suspended' else a.status end
     from identities i
     join users u on u.id = i.user_id
     join accounts a on a.owner_user_id = u.id
     where i.issuer = $1 and i.subject = $2",
    [database.text(issuer), database.text(subject)],
    {
      use user_id <- decode.field(0, decode.string)
      use account_id <- decode.field(1, decode.string)
      use name <- decode.field(2, decode.string)
      use status <- decode.field(3, decode.string)
      decode.success(#(user_id, account_id, name, status))
    },
  )
}

/// The principal for a user ID (an API key's owner), without provisioning.
pub fn by_user(conn: Connection, user_id: String) -> Result(Option(Principal), AppError) {
  use row <- db(database.query_one(
    conn,
    "select u.id::text, a.id::text, u.display_name,
       case when a.suspended_at is not null and a.status in ('active', 'closure_scheduled') then 'suspended' else a.status end
     from users u join accounts a on a.owner_user_id = u.id
     where u.id = $1::uuid",
    [database.text(user_id)],
    {
      use user_id <- decode.field(0, decode.string)
      use account_id <- decode.field(1, decode.string)
      use name <- decode.field(2, decode.string)
      use status <- decode.field(3, decode.string)
      decode.success(Principal(user_id, account_id, name, status, None))
    },
  ))
  Ok(row)
}

/// After purge only the keyed identity hash survives. A later sign-in with
/// the same identity reports the account as closed; creating a new account
/// is an explicit choice (not automatic) and inherits prior lifetime usage.
fn reject_purged_identity(
  ctx: Context,
  issuer: String,
  subject: String,
) -> Result(Nil, AppError) {
  use hits <- result.try(ledger_usage(ctx, issuer, subject))
  case hits {
    None -> Ok(Nil)
    Some(_) ->
      Error(
        error.new(
          403,
          "account_closed",
          "The account for this sign-in was closed and purged.",
        ),
      )
  }
}

/// Prior lifetime-allowance usage for an identity, checked under every retained
/// HMAC key (at most three).
pub fn ledger_usage(
  ctx: Context,
  issuer: String,
  subject: String,
) -> Result(Option(Int), AppError) {
  ctx.config.identity_hash_keys
  |> list.try_fold(None, fn(found, key) {
    case found {
      Some(_) -> Ok(found)
      None -> {
        let #(key_id, secret) = key
        let hash = identity.identity_key(secret, issuer, subject)
        database.query_one(
          ctx.db,
          "select lifetime_units_consumed from identity_usage_ledger
           where key_id = $1 and identity_key = $2",
          [database.text(key_id), database.bytea(hash)],
          decode.at([0], decode.int),
        )
        |> result.map_error(error.from_query)
      }
    }
  })
}

/// Explicitly create a new account for an identity whose previous account
/// was closed and purged. The new account inherits the identity's prior
/// lifetime-allowance usage, so only the remaining allowance is available.
pub fn create_after_purge(
  ctx: Context,
  issuer: String,
  subject: String,
  display_name: Option(String),
  auth_time: Option(Int),
) -> Result(Principal, AppError) {
  use inherited <- result.try(ledger_usage(ctx, issuer, subject))
  case inherited {
    None -> Error(error.new(409, "account_exists", "This sign-in already has an account."))
    Some(used) -> {
      use _ <- result.try(provision_with_usage(
        ctx,
        issuer,
        subject,
        option.unwrap(display_name, ""),
        used,
      ))
      use found <- db(lookup(ctx.db, issuer, subject))
      case found {
        Some(#(user_id, account_id, name, status)) ->
          Ok(Principal(user_id, account_id, name, status, auth_time))
        None -> Error(error.internal("account provisioning failed"))
      }
    }
  }
}

fn provision(
  ctx: Context,
  issuer: String,
  subject: String,
  display_name: String,
) -> Result(Nil, AppError) {
  provision_with_usage(ctx, issuer, subject, display_name, 0)
}

fn provision_with_usage(
  ctx: Context,
  issuer: String,
  subject: String,
  display_name: String,
  inherited_usage: Int,
) -> Result(Nil, AppError) {
  let user_id = uuid.v7_string()
  let account_id = uuid.v7_string()
  let release_id = uuid.v7_string()
  let schedule_id = uuid.v7_string()
  use configuration_id <- result.try(search_configuration(ctx))
  let lifetime_allowance = case ctx.config.default_lifetime_processing {
    context.Limited(n) -> Some(n)
    context.Unlimited -> None
  }
  context.transaction(ctx, fn(tx) {
    let run = fn(sql, params) {
      database.execute(tx, sql, params) |> result.map_error(error.from_query)
    }
    use _ <- result.try(run(
      "insert into users (id, display_name) values ($1::uuid, $2)",
      [database.text(user_id), database.text(display_name)],
    ))
    use _ <- result.try(run(
      "insert into accounts (id, owner_user_id, allowance_schedule_id)
       values ($1::uuid, $2::uuid, $3::uuid)",
      [
        database.text(account_id),
        database.text(user_id),
        database.text(schedule_id),
      ],
    ))
    use _ <- result.try(run(
      "insert into identities (user_id, issuer, subject) values ($1::uuid, $2, $3)",
      [database.text(user_id), database.text(issuer), database.text(subject)],
    ))
    use _ <- result.try(run(
      "insert into account_usage (account_id) values ($1::uuid)",
      [database.text(account_id)],
    ))
    use _ <- result.try(run(
      "insert into usage_periods (id, account_id, kind, starts_at, allowance,
         unlimited, used)
       values ($1::uuid, $2::uuid, 'lifetime', now(), $3, $4, $5)",
      [
        database.text(uuid.v7_string()),
        database.text(account_id),
        database.nullable_int(lifetime_allowance),
        database.bool(lifetime_allowance == None),
        database.int(inherited_usage),
      ],
    ))
    use _ <- result.try(run(
      "insert into account_job_slots (account_id, occupied, slot_limit)
       values ($1::uuid, 0, $2)",
      [
        database.text(account_id),
        database.int(ctx.config.jobs.default_account_slots),
      ],
    ))
    use _ <- result.try(run(
      "insert into search_releases (id, account_id, configuration_id, state)
       values ($1::uuid, $2::uuid, $3::uuid, 'active')",
      [
        database.text(release_id),
        database.text(account_id),
        database.text(configuration_id),
      ],
    ))
    use _ <- result.try(run(
      "update accounts set active_search_release_id = $2::uuid where id = $1::uuid",
      [database.text(account_id), database.text(release_id)],
    ))
    run(
      "insert into audit_events (id, actor, account_id, action, target)
       values ($1::uuid, 'system', $2::uuid, 'account.provisioned', null)",
      [database.text(uuid.v7_string()), database.text(account_id)],
    )
    |> result.replace(Nil)
  })
}

/// The deployment-wide search configuration (section 19 interim rule: one
/// configuration per deployment until per-account cutover is implemented).
pub fn search_configuration(ctx: Context) -> Result(String, AppError) {
  let embedding = ctx.config.embedding
  let params = [
    database.text(embedding.name),
    database.text(embedding.model_id),
    database.int(embedding.dimensions),
    database.text(ctx.config.chunking_version),
    database.text(ctx.config.normalization_version),
  ]
  use _ <- db(database.execute(
    ctx.db,
    "insert into search_configurations (id, embedding_provider, embedding_model,
       dimensions, chunking_version, normalization_version)
     values ($6::uuid, $1, $2, $3, $4, $5) on conflict do nothing",
    list.append(params, [database.text(uuid.v7_string())]),
  ))
  use found <- error.found(database.query_one(
    ctx.db,
    "select id::text from search_configurations
     where embedding_provider = $1 and embedding_model = $2 and dimensions = $3
       and chunking_version = $4 and normalization_version = $5",
    params,
    decode.at([0], decode.string),
  ))
  Ok(found)
}

/// Lock the account row (lock level 1) and return its status.
pub fn lock(conn: Connection, account_id: String) -> Result(String, AppError) {
  use status <- error.found(database.query_one(
    conn,
    "select status from accounts where id = $1::uuid for update",
    [database.text(account_id)],
    decode.at([0], decode.string),
  ))
  Ok(status)
}

/// Lock the account and require `active` (additions and edits). A
/// cancelled closure keeps its restrictions until the higher active
/// revision is durable in the journal.
pub fn lock_active(conn: Connection, account_id: String) -> Result(Nil, AppError) {
  use status <- result.try(lock(conn, account_id))
  case status {
    "active" -> {
      use unconfirmed <- result.try(journal.account_change_unconfirmed(conn, account_id))
      case unconfirmed {
        False -> Ok(Nil)
        True ->
          Error(
            error.account_closing()
            |> error.with_details([
              #("reason", json.string("closure_cancellation_unconfirmed")),
            ]),
          )
      }
    }
    _ -> Error(error.account_closing())
  }
}

/// Account deletion, closure cancellation and permanent purge require a
/// fresh sign-in no older than five minutes.
pub fn require_recent_auth(
  principal: Principal,
  now_seconds: Int,
) -> Result(Nil, AppError) {
  case principal.auth_time {
    Some(t) if now_seconds - t <= 300 -> Ok(Nil)
    _ ->
      Error(error.new(
        401,
        "reauthentication_required",
        "Sign in again to confirm this action.",
      ))
  }
}

/// Lock the account and allow `active` or `closure_scheduled` (reads,
/// deletions, exports and closure cancellation).
pub fn lock_readable(
  conn: Connection,
  account_id: String,
) -> Result(Nil, AppError) {
  use status <- result.try(lock(conn, account_id))
  case status {
    "active" | "closure_scheduled" -> Ok(Nil)
    _ -> Error(error.account_closing())
  }
}

/// Advance the account content sequence and append a content-change record
/// in the caller's transaction (migration catch-up log, section 9).
pub fn record_content_change(
  conn: Connection,
  account_id: String,
  page_id: String,
  action: String,
) -> Result(Nil, AppError) {
  use _ <- db(database.execute(
    conn,
    "with seq as (
       update accounts set content_sequence = content_sequence + 1
       where id = $1::uuid returning content_sequence)
     insert into content_changes (account_id, sequence, page_id, content_version, action)
     select $1::uuid, seq.content_sequence, p.id, p.content_version, $3
     from seq, pages p where p.id = $2::uuid",
    [database.text(account_id), database.text(page_id), database.text(action)],
  ))
  Ok(Nil)
}

pub fn me_json(principal: Principal) -> json.Json {
  json.object([
    #(
      "user",
      json.object([
        #("id", json.string(principal.user_id)),
        #("display_name", json.string(principal.display_name)),
      ]),
    ),
    #(
      "account",
      json.object([
        #("id", json.string(principal.account_id)),
        #("status", json.string(principal.account_status)),
      ]),
    ),
    #(
      "capabilities",
      json.object([
        #("deferred_processing", json.bool(True)),
        #("background_upload_urls", json.bool(True)),
      ]),
    ),
  ])
}
