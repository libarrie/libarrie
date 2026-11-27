//// Request authentication for `/v1` and `/internal` (sections 6 and 13).
////
//// `/v1` accepts two mutually exclusive modes:
//// - Bearer (native clients): `Authorization: Bearer` and no session cookie.
////   A token whose audience also lists the MCP audience is refused (ADR 0017).
//// - Session cookie (same-origin browser): non-GET requests must carry a
////   matching `X-CSRF-Token` and an `Origin` equal to the web origin (or, if
////   absent, `Sec-Fetch-Site: same-origin`).
//// A request carrying both is rejected with 400. Internal endpoints use a
//// separate service credential that can never read notes.

import gleam/bit_array
import gleam/crypto
import gleam/http/request
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import libarrie/domain/accounts.{type Principal}
import libarrie/domain/context.{type Context}
import libarrie/domain/error.{type AppError}
import libarrie/integrations/identity
import libarrie/web/session
import wisp


pub type Auth {
  Auth(
    verifier: identity.Verifier,
    /// The effective MCP audience (`settings.mcp_audience`). `/v1` refuses a
    /// bearer token whose `aud` also lists it (ADR 0017).
    mcp_audience: String,
    web_origin: String,
    internal_token: Option(String),
  )
}

fn authentication_required() -> AppError {
  error.new(401, "authentication_required", "Sign in to continue.")
}

/// The identity provider put both audiences in one token. The message names
/// the configured values, never strings from the token.
fn both_audiences(oidc_audience: String, mcp_audience: String) -> AppError {
  error.new(
    401,
    "authentication_required",
    "This token's audience lists both OIDC_AUDIENCE (\""
      <> oidc_audience
      <> "\") and the MCP audience (\""
      <> mcp_audience
      <> "\"). /v1 doesn't accept tokens that MCP accepts, so the identity "
      <> "provider must not put both audiences in one token.",
  )
}

pub fn principal(
  ctx: Context,
  auth: Auth,
  req: wisp.Request,
) -> Result(Principal, AppError) {
  let bearer = case request.get_header(req, "authorization") {
    Ok(value) ->
      case string.split_once(value, " ") {
        Ok(#(scheme, token)) ->
          case string.lowercase(scheme) {
            "bearer" -> Some(string.trim(token))
            _ -> None
          }
        Error(_) -> None
      }
    Error(_) -> None
  }
  let cookie = session.token_from(req, auth.web_origin)
  case bearer, cookie {
    Some(_), Some(_) ->
      Error(error.bad_request(
        "Send either a bearer token or a session cookie, not both.",
      ))
    Some(token), None -> bearer_principal(ctx, auth, token)
    None, Some(token) -> cookie_principal(ctx, auth, req, token)
    None, None -> Error(authentication_required())
  }
}

/// Verified bearer claims (used for explicit account creation after purge),
/// under the same rules as `principal`'s bearer mode.
pub fn bearer_claims(auth: Auth, req: wisp.Request) -> Result(identity.Claims, AppError) {
  let token = case request.get_header(req, "authorization") {
    Ok(value) ->
      case string.split_once(value, " ") {
        Ok(#(scheme, token)) ->
          case string.lowercase(scheme) {
            "bearer" -> Ok(string.trim(token))
            _ -> Error(Nil)
          }
        Error(_) -> Error(Nil)
      }
    Error(_) -> Error(Nil)
  }
  case token {
    Error(_) -> Error(authentication_required())
    Ok(token) -> verify_bearer(auth, token)
  }
}

fn bearer_principal(
  ctx: Context,
  auth: Auth,
  token: String,
) -> Result(Principal, AppError) {
  use claims <- result.try(verify_bearer(auth, token))
  accounts.resolve(
    ctx,
    claims.issuer,
    claims.subject,
    claims.name,
    claims.auth_time,
  )
}

/// A token that fails verification gets the generic error. A verified token
/// whose audience also lists the MCP audience would work on `/mcp` too, and
/// `/v1` returns the text of private notebooks, so it is refused (ADR 0017).
fn verify_bearer(
  auth: Auth,
  token: String,
) -> Result(identity.Claims, AppError) {
  let now = timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  use claims <- result.try(
    identity.verify(auth.verifier, token, now.0)
    |> result.replace_error(authentication_required()),
  )
  case list.contains(claims.audience, auth.mcp_audience) {
    True -> Error(both_audiences(auth.verifier.audience, auth.mcp_audience))
    False -> Ok(claims)
  }
}

fn cookie_principal(
  ctx: Context,
  auth: Auth,
  req: wisp.Request,
  token: String,
) -> Result(Principal, AppError) {
  use found <- result.try(session.lookup(ctx, token))
  case found {
    None -> Error(authentication_required())
    // Status-only sessions never reach /v1 note data.
    Some(s) if s.status_only -> Error(error.account_closing())
    Some(s) -> {
      use _ <- result.try(session.check_csrf(req, s, auth.web_origin, None))
      Ok(s.principal)
    }
  }
}

/// Internal entitlement-authority credential (constant-time comparison).
pub fn require_internal(auth: Auth, req: wisp.Request) -> Result(Nil, AppError) {
  case auth.internal_token, request.get_header(req, "authorization") {
    Some(expected), Ok(header) ->
      case
        crypto.secure_compare(
          bit_array.from_string(header),
          bit_array.from_string("Bearer " <> expected),
        )
      {
        True -> Ok(Nil)
        False -> Error(error.forbidden("Internal credential rejected."))
      }
    None, _ -> Error(error.not_found())
    _, Error(_) -> Error(authentication_required())
  }
}
