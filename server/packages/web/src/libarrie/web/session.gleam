//// Browser sessions (sections 6 and 13).
////
//// The session cookie is `__Host-libarrie_session` on HTTPS: Secure,
//// HttpOnly, SameSite=Lax, host-only, path `/` (plain `libarrie_session`
//// without Secure on a local HTTP origin; see `cookies`). Only a SHA-256 hash of its value is
//// stored. Every non-GET request (HTML forms, htmx and `/v1` calls from the
//// upload module) must carry the session's CSRF token (header or form field)
//// and a same-origin `Origin` (or `Sec-Fetch-Site: same-origin`).

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/option.{type Option, None, Some}
import gleam/string
import libarrie/database
import libarrie/domain/accounts.{type Principal}
import libarrie/domain/admin
import libarrie/domain/context.{type Context}
import libarrie/domain/error.{type AppError, db}
import libarrie/web/cookies
import wisp

/// The cookie name without its `__Host-` prefix (`cookies.name` adds it).
pub const cookie_base = "libarrie_session"

const lifetime_seconds = 604_800

pub type Session {
  Session(
    principal: Principal,
    csrf_token: String,
    status_only: Bool,
    token: String,
    /// The deployment role, read with the session on every request, so a
    /// removed role takes effect at once.
    role: Option(admin.Role),
  )
}

fn hash(token: String) -> BitArray {
  crypto.hash(crypto.Sha256, bit_array.from_string(token))
}

pub fn random_token(bytes: Int) -> String {
  crypto.strong_random_bytes(bytes) |> bit_array.base64_url_encode(False)
}

/// Create a session for a freshly authenticated principal. `auth_time` is
/// the identity provider's authentication time (Unix seconds).
pub fn create(
  ctx: Context,
  principal: Principal,
  auth_time: Int,
  status_only: Bool,
) -> Result(#(String, String), AppError) {
  let token = random_token(32)
  let csrf = random_token(24)
  use _ <- db(database.execute(
    ctx.db,
    "insert into web_sessions (token_hash, user_id, account_id, csrf_token, status_only,
       auth_time, expires_at)
     values ($1, $2::uuid, $3::uuid, $4, $5, to_timestamp($6), now() + make_interval(secs => $7))",
    [
      database.bytea(hash(token)),
      database.text(principal.user_id),
      database.text(principal.account_id),
      database.text(csrf),
      database.bool(status_only),
      database.int(auth_time),
      database.int(lifetime_seconds),
    ],
  ))
  Ok(#(token, csrf))
}

/// The session for a cookie value, if valid and unrevoked.
pub fn lookup(
  ctx: Context,
  token: String,
) -> Result(Option(Session), AppError) {
  use row <- db(
    database.query_one(
      ctx.db,
      "select s.user_id::text, s.account_id::text, u.display_name,
       case when a.suspended_at is not null and a.status in ('active', 'closure_scheduled') then 'suspended' else a.status end,
       s.csrf_token, s.status_only, extract(epoch from s.auth_time)::bigint, u.role
     from web_sessions s
     join users u on u.id = s.user_id
     join accounts a on a.id = s.account_id
     where s.token_hash = $1 and s.revoked_at is null and s.expires_at > now()",
      [database.bytea(hash(token))],
      {
        use user_id <- decode.field(0, decode.string)
        use account_id <- decode.field(1, decode.string)
        use name <- decode.field(2, decode.string)
        use status <- decode.field(3, decode.string)
        use csrf <- decode.field(4, decode.string)
        use status_only <- decode.field(5, decode.bool)
        use auth_time <- decode.field(6, decode.int)
        use role <- decode.field(7, decode.optional(decode.string))
        decode.success(Session(
          accounts.Principal(user_id, account_id, name, status, Some(auth_time)),
          csrf,
          status_only,
          "",
          admin.parse_role(role),
        ))
      },
    ),
  )
  Ok(option.map(row, fn(s) { Session(..s, token:) }))
}

pub fn revoke(ctx: Context, token: String) -> Result(Nil, AppError) {
  use _ <- db(database.execute(
    ctx.db,
    "update web_sessions set revoked_at = now() where token_hash = $1 and revoked_at is null",
    [database.bytea(hash(token))],
  ))
  Ok(Nil)
}

pub fn token_from(req: wisp.Request, origin: String) -> Option(String) {
  cookies.read(req, origin, cookie_base)
}

pub fn set_cookie(resp: wisp.Response, origin: String, token: String) -> wisp.Response {
  response.prepend_header(
    resp,
    "set-cookie",
    cookies.name(origin, cookie_base) <> "=" <> token
      <> cookies.scope(origin) <> "; HttpOnly; SameSite=Lax; Max-Age=604800",
  )
}

pub fn clear_cookie(resp: wisp.Response, origin: String) -> wisp.Response {
  response.prepend_header(
    resp,
    "set-cookie",
    cookies.name(origin, cookie_base) <> "=" <> cookies.scope(origin) <> "; HttpOnly; SameSite=Lax; Max-Age=0",
  )
}

/// Same-origin and CSRF checks for state-changing requests. `form_token`
/// is the `csrf_token` field of a form submission, if any.
pub fn check_csrf(
  req: wisp.Request,
  session: Session,
  origin: String,
  form_token: Option(String),
) -> Result(Nil, AppError) {
  case req.method {
    http.Get | http.Head -> Ok(Nil)
    _ -> {
      let sent = case request.get_header(req, "x-csrf-token"), form_token {
        Ok(token), _ -> Some(token)
        Error(_), token -> token
      }
      let token_ok = case sent {
        Some(token) ->
          crypto.secure_compare(
            bit_array.from_string(token),
            bit_array.from_string(session.csrf_token),
          )
        None -> False
      }
      let origin_ok = case request.get_header(req, "origin") {
        Ok(sent_origin) -> sent_origin == origin
        Error(_) -> request.get_header(req, "sec-fetch-site") == Ok("same-origin")
      }
      case token_ok && origin_ok {
        True -> Ok(Nil)
        False -> Error(error.forbidden("The request failed CSRF or origin checks."))
      }
    }
  }
}

/// A validated same-origin path to return to after sign-in.
pub fn safe_return_path(candidate: String) -> String {
  case
    string.starts_with(candidate, "/")
    && !string.starts_with(candidate, "//")
    && !string.starts_with(candidate, "/\\")
    && !string.contains(candidate, "\\")
    && !string.starts_with(candidate, "/auth/")
  {
    True -> candidate
    False -> "/notebooks"
  }
}
