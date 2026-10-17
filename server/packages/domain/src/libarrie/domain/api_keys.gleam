//// API keys for the MCP server (ADR 0012). A key stands in for its owner's
//// sign-in on `/mcp` only; it can't reach `/v1` or the web app. Only a
//// SHA-256 hash is stored, so a key is shown once, at creation. Revoking
//// deletes it, and account purge deletes every key of the account.

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import gleam/string
import libarrie/database.{type Connection}
import libarrie/domain/accounts.{type Principal}
import libarrie/domain/context.{type Context}
import libarrie/domain/error.{type AppError, db}
import youid/uuid

/// Every key starts with this, so people (and secret scanners) can
/// recognize one.
pub const key_prefix = "lbk_"

const max_keys_per_user = 25

const max_name_length = 100

pub type ApiKey {
  ApiKey(
    id: String,
    name: String,
    /// The first characters of the key, to tell keys apart.
    prefix: String,
    created_at: String,
    last_used_at: Option(String),
  )
}

pub fn list(conn: Connection, user_id: String) -> Result(List(ApiKey), AppError) {
  use rows <- db(database.query(
    conn,
    "select id::text, name, prefix, rfc3339(created_at), rfc3339(last_used_at)
     from api_keys where user_id = $1::uuid order by created_at, id",
    [database.text(user_id)],
    {
      use id <- decode.field(0, decode.string)
      use name <- decode.field(1, decode.string)
      use prefix <- decode.field(2, decode.string)
      use created_at <- decode.field(3, decode.string)
      use last_used_at <- decode.field(4, decode.optional(decode.string))
      decode.success(ApiKey(id:, name:, prefix:, created_at:, last_used_at:))
    },
  ))
  Ok(rows)
}

/// Create a key for the signed-in person. Returns the key itself, which is
/// never retrievable again.
pub fn create(
  ctx: Context,
  principal: Principal,
  name: String,
) -> Result(#(ApiKey, String), AppError) {
  let name = string.trim(name)
  use <- error.guard(
    name != "" && string.length(name) <= max_name_length,
    error.unprocessable("Give the key a name of 1 to 100 characters."),
  )
  use <- error.guard(
    accounts.can_read(principal),
    error.new(403, "account_inactive", "This account can't create API keys."),
  )
  context.transaction(ctx, fn(tx) {
    // Serialize per user so the limit holds under concurrent requests.
    use _ <- db(database.execute(
      tx,
      "select 1 from users where id = $1::uuid for update",
      [database.text(principal.user_id)],
    ))
    use count <- db(database.query_one(
      tx,
      "select count(*)::int from api_keys where user_id = $1::uuid",
      [database.text(principal.user_id)],
      decode.at([0], decode.int),
    ))
    use <- error.guard(
      option.unwrap(count, 0) < max_keys_per_user,
      error.new(
        409,
        "too_many_api_keys",
        "You have the maximum of 25 API keys. Revoke one you no longer use.",
      ),
    )
    let key = new_key()
    let id = uuid.v7_string()
    let prefix = string.slice(key, 0, string.length(key_prefix) + 6)
    use created_at <- error.found(database.query_one(
      tx,
      "insert into api_keys (id, user_id, account_id, name, prefix, key_hash)
       values ($1::uuid, $2::uuid, $3::uuid, $4, $5, $6)
       returning rfc3339(created_at)",
      [
        database.text(id),
        database.text(principal.user_id),
        database.text(principal.account_id),
        database.text(name),
        database.text(prefix),
        database.bytea(hash(key)),
      ],
      decode.at([0], decode.string),
    ))
    Ok(#(ApiKey(id:, name:, prefix:, created_at:, last_used_at: None), key))
  })
}

pub fn revoke(ctx: Context, user_id: String, key_id: String) -> Result(Nil, AppError) {
  use key_id <- context.require_uuid(key_id)
  use deleted <- db(database.query_one(
    ctx.db,
    "delete from api_keys where user_id = $1::uuid and id = $2::uuid returning 1",
    [database.text(user_id), database.text(key_id)],
    decode.at([0], decode.int),
  ))
  case deleted {
    Some(_) -> Ok(Nil)
    None -> Error(error.not_found())
  }
}

/// The user a key belongs to, or `None` for an unknown or revoked key.
/// Records when the key was last used (at most once a minute).
pub fn authenticate(conn: Connection, key: String) -> Result(Option(String), AppError) {
  case string.starts_with(key, key_prefix) {
    False -> Ok(None)
    True -> {
      use user_id <- db(database.query_one(
        conn,
        "select user_id::text from api_keys where key_hash = $1",
        [database.bytea(hash(key))],
        decode.at([0], decode.string),
      ))
      case user_id {
        None -> Ok(None)
        Some(_) -> {
          use _ <- db(database.execute(
            conn,
            "update api_keys set last_used_at = now()
             where key_hash = $1
               and (last_used_at is null or last_used_at < now() - interval '1 minute')",
            [database.bytea(hash(key))],
          ))
          Ok(user_id)
        }
      }
    }
  }
}

fn new_key() -> String {
  key_prefix
  <> {
    crypto.strong_random_bytes(32)
    |> bit_array.base64_url_encode(False)
  }
}

fn hash(key: String) -> BitArray {
  crypto.hash(crypto.Sha256, bit_array.from_string(key))
}

/// Whether a bearer token looks like an API key rather than an access token.
pub fn is_api_key(token: String) -> Bool {
  string.starts_with(token, key_prefix)
}
