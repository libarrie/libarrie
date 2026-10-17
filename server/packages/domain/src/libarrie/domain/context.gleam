//// Shared runtime context for domain operations, plus transaction and
//// encoding helpers used across modules.

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option}
import gleam/result
import gleam/string
import libarrie/database.{type Connection}
import libarrie/domain/error.{type AppError}
import libarrie/integrations/decoder
import libarrie/integrations/image
import libarrie/integrations/providers
import libarrie/integrations/storage
import libarrie/jobs

pub type Limit {
  Limited(Int)
  Unlimited
}

pub type Config {
  Config(
    storage: storage.Config,
    /// Independent deletion/lifecycle journal store (section 14).
    journal_store: storage.Config,
    image_limits: image.Limits,
    /// Foreground staging URL lifetime (~15 minutes).
    foreground_upload_url_seconds: Int,
    /// Native background-transfer URL lifetime (up to 6 hours).
    background_upload_url_seconds: Int,
    /// Upload reservation lifetime (~24 hours).
    reservation_seconds: Int,
    /// Direct download URL lifetime (hosted maximum five minutes).
    download_url_seconds: Int,
    /// Defaults applied when no entitlement assignment exists.
    default_stored_pages: Limit,
    default_notebooks: Limit,
    default_lifetime_processing: Limit,
    lazy_expiry_batch: Int,
    recovery_hold_days: Int,
    trash_retention_days: Int,
    /// Finished jobs stay in the archive this long, then are deleted.
    job_archive_retention_days: Int,
    identity_hash_keys: List(#(String, String)),
    embedding: providers.EmbeddingProvider,
    /// Earlier embedding models still callable: they keep a not-yet-migrated
    /// account's release current and make rollback possible (section 9).
    previous_embeddings: List(providers.EmbeddingProvider),
    chunking_version: String,
    normalization_version: String,
    jobs: jobs.Settings,
    /// Account closure grace (default 7 days) and hosted maximum (30).
    closure_grace_seconds: Int,
    closure_max_seconds: Int,
    /// Account lifecycle commands are also delivered to a subscriber.
    lifecycle_subscriber: Bool,
    /// `LIBARRIE_OWNER`: a sign-in subject made an owner when it signs in.
    configured_owner: Option(String),
    exports: ExportSettings,
    /// Sandboxed decoder; `None` only in development without Linux.
    decoder: Option(decoder.Config),
    spend: SpendSettings,
    rate_limits: RateLimits,
  )
}

pub type ExportSettings {
  ExportSettings(
    part_bytes: Int,
    upload_chunk_bytes: Int,
    max_concurrent: Int,
    retention_seconds: Int,
    download_window_seconds: Int,
  )
}

pub type SpendSettings {
  SpendSettings(
    ocr_cost_micros: Int,
    account_daily_micros: Int,
    deployment_daily_micros: Int,
    max_pause_seconds: Int,
    provider_concurrency: Int,
    permit_lease_seconds: Int,
    circuit_threshold: Int,
    circuit_open_seconds: Int,
  )
}

pub type RateLimits {
  RateLimits(
    requests_per_minute: Int,
    searches_per_minute: Int,
    corrections_per_page_hour: Int,
    rescans_per_page_day: Int,
  )
}

pub type Context {
  Context(db: Connection, config: Config)
}

/// Run `body` in a transaction, retrying whole-transaction serialization
/// failures and deadlocks a bounded number of times.
pub fn transaction(
  ctx: Context,
  body: fn(Connection) -> Result(a, AppError),
) -> Result(a, AppError) {
  transaction_with_retries(ctx.db, body, 3)
}

fn transaction_with_retries(
  conn: Connection,
  body: fn(Connection) -> Result(a, AppError),
  remaining: Int,
) -> Result(a, AppError) {
  case database.transaction(conn, body) {
    Ok(value) -> Ok(value)
    Error(database.Aborted(e)) ->
      case e.code == "unavailable" && remaining > 0 {
        True -> transaction_with_retries(conn, body, remaining - 1)
        False -> Error(e)
      }
    Error(database.QueryFailed(e)) ->
      case database.is_transient(e) && remaining > 0 {
        True -> transaction_with_retries(conn, body, remaining - 1)
        False -> Error(error.from_query(e))
      }
  }
}

pub fn sha256_hex(value: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(value))
  |> bit_array.base16_encode
  |> string.lowercase
}

/// Canonical request hash: callers pass fields in a fixed order.
pub fn request_hash(fields: List(#(String, json.Json))) -> String {
  json.object(fields) |> json.to_string |> sha256_hex
}

pub fn optional_string(value: Option(String)) -> json.Json {
  json.nullable(value, json.string)
}

pub fn optional_int(value: Option(Int)) -> json.Json {
  json.nullable(value, json.int)
}

pub fn limit_json(limit: Limit) -> json.Json {
  case limit {
    Limited(n) -> json.object([#("kind", json.string("limited")), #("value", json.int(n))])
    Unlimited -> json.object([#("kind", json.string("unlimited"))])
  }
}

pub fn limit_decoder() -> decode.Decoder(Limit) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "unlimited" -> decode.success(Unlimited)
    "limited" -> {
      use value <- decode.field("value", decode.int)
      case value >= 0 {
        True -> decode.success(Limited(value))
        False -> decode.failure(Limited(0), "non-negative limit")
      }
    }
    _ -> decode.failure(Unlimited, "limit kind")
  }
}

/// `used + reserved + requested <= limit`
pub fn fits(limit: Limit, used: Int, requested: Int) -> Bool {
  case limit {
    Unlimited -> True
    Limited(n) -> used + requested <= n
  }
}

pub fn is_uuid(value: String) -> Bool {
  case string.length(value) == 36 {
    False -> False
    True ->
      string.to_graphemes(value)
      |> list_index_all(fn(c, i) {
        case i {
          8 | 13 | 18 | 23 -> c == "-"
          _ -> string.contains("0123456789abcdefABCDEF", c)
        }
      })
  }
}

fn list_index_all(items: List(String), check: fn(String, Int) -> Bool) -> Bool {
  do_index_all(items, check, 0)
}

fn do_index_all(
  items: List(String),
  check: fn(String, Int) -> Bool,
  i: Int,
) -> Bool {
  case items {
    [] -> True
    [c, ..rest] ->
      case check(c, i) {
        True -> do_index_all(rest, check, i + 1)
        False -> False
      }
  }
}

/// Validate a client-supplied UUID path or body value.
pub fn require_uuid(
  value: String,
  next: fn(String) -> Result(a, AppError),
) -> Result(a, AppError) {
  case is_uuid(value) {
    True -> next(string.lowercase(value))
    False -> Error(error.not_found())
  }
}

pub fn decode_body(
  body: String,
  decoder: decode.Decoder(a),
  next: fn(a) -> Result(b, AppError),
) -> Result(b, AppError) {
  json.parse(body, decoder)
  |> result.map_error(fn(_) { error.bad_request("The request body is invalid.") })
  |> result.try(next)
}
