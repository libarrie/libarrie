//// Internal provider spending controls, global provider permits and
//// provider circuits (section 16).
////
//// Successful-page usage and internal provider cost are separate ledgers.
//// Before every outbound model request, a conservative estimated cost is
//// reserved against both the account's and the deployment's daily budget in
//// a short transaction. A timeout or lost response stays charged at its
//// estimate. Concurrency permits bound provider traffic across replicas, and
//// a circuit pauses calls after sustained errors. None of this creates
//// customer charges.

import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import gleam/result
import libarrie/database.{type Connection}
import libarrie/domain/context.{type Context}
import libarrie/domain/error.{type AppError, db}
import libarrie/integrations/providers
import youid/uuid

pub type Purpose {
  Recognition
  DocumentEmbedding
  QueryEmbedding
  /// Search-model migration (and rollback) work, separate from user processing.
  MigrationEmbedding
}

fn purpose_name(purpose: Purpose) -> String {
  case purpose {
    Recognition -> "ocr"
    DocumentEmbedding -> "embed_document"
    QueryEmbedding -> "embed_query"
    MigrationEmbedding -> "embed_migration"
  }
}

pub type Blocked {
  /// A budget is exhausted: pause until the window resets.
  BudgetExhausted
  /// The provider circuit is open.
  CircuitOpen
  /// No global concurrency permit is free.
  NoPermit
  ProviderFailed(providers.ProviderError)
}

pub type Call {
  Call(
    account_id: Option(String),
    operation_id: Option(String),
    job_id: Option(String),
    provider: String,
    purpose: Purpose,
    estimate_micros: Int,
  )
}

/// Run one guarded provider request.
pub fn guarded(
  ctx: Context,
  call: Call,
  request: fn() -> Result(a, providers.ProviderError),
) -> Result(a, Blocked) {
  case circuit_open(ctx.db, call.provider) {
    True -> Error(CircuitOpen)
    False ->
      case reserve(ctx, call) {
        Error(_) -> Error(BudgetExhausted)
        Ok(spend_id) ->
          case acquire_permit(ctx, call.provider) {
            None -> {
              settle(ctx.db, spend_id, "failed", Some(0), call)
              Error(NoPermit)
            }
            Some(token) -> {
              let outcome = request()
              release_permit(ctx.db, call.provider, token)
              case outcome {
                Ok(value) -> {
                  settle(ctx.db, spend_id, "succeeded", Some(call.estimate_micros), call)
                  record_circuit(ctx, call.provider, Ok(Nil))
                  Ok(value)
                }
                Error(e) -> {
                  // Unknown outcomes stay charged at the reserved estimate.
                  settle(ctx.db, spend_id, "unknown", None, call)
                  record_circuit(ctx, call.provider, Error(e))
                  Error(ProviderFailed(e))
                }
              }
            }
          }
      }
  }
}

fn window_scopes(call: Call) -> List(String) {
  case call.account_id {
    Some(account) -> ["deployment", "account:" <> account]
    None -> ["deployment"]
  }
}

/// Reserve the estimate against every scope's daily window, all or nothing.
fn reserve(ctx: Context, call: Call) -> Result(String, AppError) {
  let id = uuid.v7_string()
  context.transaction(ctx, fn(tx) {
    use _ <- result.try(
      window_scopes(call)
      |> try_each(fn(scope) {
        let limit = case scope {
          "deployment" -> ctx.config.spend.deployment_daily_micros
          _ -> ctx.config.spend.account_daily_micros
        }
        use _ <- db(database.execute(
          tx,
          "insert into spend_windows (scope, budget_window)
           values ($1, (now() at time zone 'utc')::date) on conflict do nothing",
          [database.text(scope)],
        ))
        use updated <- db(database.execute(
          tx,
          "update spend_windows set reserved_micros = reserved_micros + $2,
             attempts = attempts + 1
           where scope = $1 and budget_window = (now() at time zone 'utc')::date
             and reserved_micros + $2 <= $3",
          [database.text(scope), database.int(call.estimate_micros), database.int(limit)],
        ))
        case updated {
          1 -> Ok(Nil)
          _ ->
            Error(error.new(
              503,
              "operational_limit_reached",
              "Processing is paused by an operational spending limit.",
            ))
        }
      }),
    )
    use _ <- db(database.execute(
      tx,
      "insert into provider_spend (id, account_id, operation_id, job_id, provider,
         purpose, budget_window, estimated_cost_micros)
       values ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5, $6,
         (now() at time zone 'utc')::date, $7)",
      [
        database.text(id),
        database.nullable_text(call.account_id),
        database.nullable_text(call.operation_id),
        database.nullable_text(call.job_id),
        database.text(call.provider),
        database.text(purpose_name(call.purpose)),
        database.int(call.estimate_micros),
      ],
    ))
    Ok(id)
  })
}

fn try_each(items: List(a), f: fn(a) -> Result(Nil, e)) -> Result(Nil, e) {
  case items {
    [] -> Ok(Nil)
    [x, ..rest] -> {
      use _ <- result.try(f(x))
      try_each(rest, f)
    }
  }
}

/// Reconcile a reservation. When the actual cost is known the windows are
/// adjusted by the difference; otherwise the estimate stays charged.
fn settle(
  conn: Connection,
  spend_id: String,
  outcome: String,
  actual: Option(Int),
  call: Call,
) -> Nil {
  let _ =
    database.execute(
      conn,
      "update provider_spend set outcome = $2, actual_cost_micros = $3 where id = $1::uuid",
      [database.text(spend_id), database.text(outcome), database.nullable_int(actual)],
    )
  case actual {
    Some(cost) if cost != call.estimate_micros -> {
      let delta = cost - call.estimate_micros
      let _ =
        database.execute(
          conn,
          "update spend_windows set reserved_micros = greatest(0, reserved_micros + $2)
           where scope = any($1::text[]) and budget_window = (
             select budget_window from provider_spend where id = $3::uuid)",
          [
            database.text_array(window_scopes(call)),
            database.int(delta),
            database.text(spend_id),
          ],
        )
      Nil
    }
    _ -> Nil
  }
}

// Permits --------------------------------------------------------------------------------

/// Make sure the configured number of permit slots exists for a provider.
pub fn ensure_permits(ctx: Context, provider: String) -> Result(Nil, AppError) {
  use _ <- db(database.execute(
    ctx.db,
    "insert into provider_permits (provider, slot)
     select $1, generate_series(1, $2) on conflict do nothing",
    [database.text(provider), database.int(ctx.config.spend.provider_concurrency)],
  ))
  use _ <- db(database.execute(
    ctx.db,
    "delete from provider_permits where provider = $1 and slot > $2",
    [database.text(provider), database.int(ctx.config.spend.provider_concurrency)],
  ))
  Ok(Nil)
}

/// Take a free (or expired) permit. Expiring permits mean a crashed holder
/// cannot leak capacity forever.
fn acquire_permit(ctx: Context, provider: String) -> Option(String) {
  let token = uuid.v4_string()
  let _ = ensure_permits(ctx, provider)
  case
    database.query_one(
      ctx.db,
      "update provider_permits set holder = $2::uuid,
         expires_at = now() + make_interval(secs => $3)
       where (provider, slot) = (
         select provider, slot from provider_permits
         where provider = $1 and (holder is null or expires_at <= now())
         order by slot limit 1 for update skip locked)
       returning slot",
      [
        database.text(provider),
        database.text(token),
        database.int(ctx.config.spend.permit_lease_seconds),
      ],
      decode.at([0], decode.int),
    )
  {
    Ok(Some(_)) -> Some(token)
    _ -> None
  }
}

fn release_permit(conn: Connection, provider: String, token: String) -> Nil {
  let _ =
    database.execute(
      conn,
      "update provider_permits set holder = null, expires_at = null
       where provider = $1 and holder = $2::uuid",
      [database.text(provider), database.text(token)],
    )
  Nil
}

// Circuits -------------------------------------------------------------------------------

fn circuit_open(conn: Connection, provider: String) -> Bool {
  case
    database.query_one(
      conn,
      "select open_until > now() from provider_circuits where provider = $1",
      [database.text(provider)],
      decode.at([0], decode.optional(decode.bool)),
    )
  {
    Ok(Some(Some(True))) -> True
    _ -> False
  }
}

/// Sustained transient errors open the circuit briefly; invalid credentials
/// open it for longer and alert operators instead of exhausting every
/// user job's attempts.
fn record_circuit(
  ctx: Context,
  provider: String,
  outcome: Result(Nil, providers.ProviderError),
) -> Nil {
  let settings = ctx.config.spend
  let _ = case outcome {
    Ok(_) ->
      database.execute(
        ctx.db,
        "insert into provider_circuits (provider) values ($1)
         on conflict (provider) do update set consecutive_failures = 0, open_until = null,
           reason = null",
        [database.text(provider)],
      )
    Error(providers.Misconfigured(_)) ->
      database.execute(
        ctx.db,
        "insert into provider_circuits (provider, consecutive_failures, open_until, reason)
         values ($1, 1, now() + make_interval(secs => $2), 'misconfigured')
         on conflict (provider) do update set
           consecutive_failures = provider_circuits.consecutive_failures + 1,
           open_until = now() + make_interval(secs => $2), reason = 'misconfigured'",
        [database.text(provider), database.int(settings.circuit_open_seconds * 10)],
      )
    Error(_) ->
      database.execute(
        ctx.db,
        "insert into provider_circuits (provider, consecutive_failures) values ($1, 1)
         on conflict (provider) do update set
           consecutive_failures = provider_circuits.consecutive_failures + 1,
           open_until = case when provider_circuits.consecutive_failures + 1 >= $2
             then now() + make_interval(secs => $3) else provider_circuits.open_until end,
           reason = 'sustained_errors'",
        [
          database.text(provider),
          database.int(settings.circuit_threshold),
          database.int(settings.circuit_open_seconds),
        ],
      )
  }
  Nil
}
