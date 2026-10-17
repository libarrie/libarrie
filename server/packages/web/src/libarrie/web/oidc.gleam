//// OIDC Authorization Code flow with PKCE for the browser (section 6).
////
//// `/auth/login` stores state, nonce, the PKCE verifier and a validated
//// return path in a short-lived, signed, host-only cookie and redirects to
//// the issuer. `/auth/callback` checks state, exchanges the code (with the
//// verifier), validates the ID token (issuer, audience, expiry, signature,
//// nonce) and creates a backend session. Refresh tokens never reach the
//// browser. `?reauth=1` forces a fresh sign-in (`prompt=login`,
//// `max_age=0`) for account deletion and permanent purge.

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import gleam/uri
import libarrie/domain/accounts
import libarrie/domain/admin
import libarrie/integrations/identity
import libarrie/web/config.{type Web}
import libarrie/web/cookies
import libarrie/web/session
import libarrie/web/ui
import lustre/attribute
import lustre/element/html
import wisp

const state_cookie = "libarrie_oidc"

/// How the authorization code is exchanged: over HTTPS for a real issuer,
/// or in-process for the built-in development issuer.
pub type Exchange =
  fn(String, String) -> Result(String, String)

pub fn now() -> Int {
  let #(seconds, _) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  seconds
}

fn b64url(bits: BitArray) -> String {
  bit_array.base64_url_encode(bits, False)
}

pub fn login(web: Web, req: wisp.Request) -> wisp.Response {
  let query = wisp.get_query(req)
  let return_to =
    list.key_find(query, "return_to") |> result.unwrap("/notebooks") |> session.safe_return_path
  let reauth = list.key_find(query, "reauth") == Ok("1")
  let state = session.random_token(24)
  let nonce = session.random_token(24)
  let verifier = session.random_token(48)
  let challenge = crypto.hash(crypto.Sha256, bit_array.from_string(verifier)) |> b64url
  let stored =
    json.object([
      #("state", json.string(state)),
      #("nonce", json.string(nonce)),
      #("verifier", json.string(verifier)),
      #("return_to", json.string(return_to)),
    ])
    |> json.to_string
  let signed =
    wisp.sign_message(
      wisp.set_secret_key_base(req, web.secret_key_base),
      bit_array.from_string(stored),
      crypto.Sha256,
    )
  let params = [
    #("response_type", "code"),
    #("client_id", web.oidc.client_id),
    #("redirect_uri", web.oidc.redirect_uri),
    #("scope", "openid profile email"),
    #("state", state),
    #("nonce", nonce),
    #("code_challenge", challenge),
    #("code_challenge_method", "S256"),
    ..case reauth {
      True -> [#("prompt", "login"), #("max_age", "0")]
      False -> []
    }
  ]
  let location = web.oidc.authorization_endpoint <> "?" <> uri.query_to_string(params)
  wisp.response(303)
  |> wisp.set_header("location", location)
  |> response.prepend_header(
    "set-cookie",
    cookies.name(web.origin, state_cookie) <> "=" <> signed <> cookies.scope(web.origin)
      <> "; HttpOnly; SameSite=Lax; Max-Age=600",
  )
  |> ui.security_headers(web)
}

type Pending {
  Pending(state: String, nonce: String, verifier: String, return_to: String)
}

pub fn callback(web: Web, req: wisp.Request, exchange: Exchange) -> wisp.Response {
  let query = wisp.get_query(req)
  let pending = {
    use signed <- result.try(
      cookies.read(req, web.origin, state_cookie) |> option.to_result("missing state"),
    )
    use bits <- result.try(
      wisp.verify_signed_message(wisp.set_secret_key_base(req, web.secret_key_base), signed)
      |> result.replace_error("invalid state"),
    )
    use text <- result.try(bit_array.to_string(bits) |> result.replace_error("invalid state"))
    json.parse(text, {
      use state <- decode.field("state", decode.string)
      use nonce <- decode.field("nonce", decode.string)
      use verifier <- decode.field("verifier", decode.string)
      use return_to <- decode.field("return_to", decode.string)
      decode.success(Pending(state, nonce, verifier, return_to))
    })
    |> result.replace_error("invalid state")
  }
  let outcome = {
    use pending <- result.try(pending)
    use code <- result.try(case list.key_find(query, "error"), list.key_find(query, "code") {
      Ok(error), _ -> Error("sign-in was not completed (" <> error <> ")")
      _, Ok(code) -> Ok(code)
      _, _ -> Error("missing authorization code")
    })
    use _ <- result.try(case list.key_find(query, "state") {
      Ok(state) if state == pending.state -> Ok(Nil)
      _ -> Error("state mismatch")
    })
    use id_token <- result.try(exchange(code, pending.verifier))
    use claims <- result.try(
      identity.verify(web.verifier, id_token, now())
      |> result.map_error(fn(e) { "invalid ID token: " <> string.inspect(e) }),
    )
    use _ <- result.try(case claims.nonce {
      Some(n) if n == pending.nonce -> Ok(Nil)
      _ -> Error("nonce mismatch")
    })
    Ok(#(pending, claims))
  }
  case outcome {
    Error(reason) -> failed(web, req, reason)
    Ok(#(pending, claims)) -> {
      let auth_time = option.unwrap(claims.auth_time, now())
      case
        accounts.resolve(web.ctx, claims.issuer, claims.subject, claims.name, Some(auth_time))
      {
        // After purge only the keyed identity hash survives: show status.
        Error(e) if e.code == "account_closed" ->
          wisp.response(303)
          |> wisp.set_header("location", "/account-closed")
          |> clear_state(web)
          |> ui.security_headers(web)
        Error(_) -> failed(web, req, "account lookup failed")
        Ok(principal) -> {
          // Profile and configured ownership never block sign-in.
          let _ =
            admin.record_email(web.ctx.db, principal.user_id, claims.email)
          let _ =
            admin.apply_configured_owner(
              web.ctx,
              principal.user_id,
              claims.subject,
            )
          // Closing and closed accounts get a status-only session. A blocked
          // account gets a normal one that every request restricts, so
          // unblocking takes effect at once.
          let status_only =
            principal.account_status == "closing"
            || principal.account_status == "closed"
          case session.create(web.ctx, principal, auth_time, status_only) {
            Error(_) -> failed(web, req, "could not start a session")
            Ok(#(token, _csrf)) -> {
              let destination = case status_only {
                True -> "/account"
                False -> session.safe_return_path(pending.return_to)
              }
              // Replace any previous session in this browser.
              let _ = case session.token_from(req, web.origin) {
                Some(old) -> session.revoke(web.ctx, old)
                None -> Ok(Nil)
              }
              wisp.response(303)
              |> wisp.set_header("location", destination)
              |> session.set_cookie(web.origin, token)
              |> clear_state(web)
              |> ui.security_headers(web)
            }
          }
        }
      }
    }
  }
}

fn clear_state(resp: wisp.Response, web: Web) -> wisp.Response {
  response.prepend_header(
    resp,
    "set-cookie",
    cookies.name(web.origin, state_cookie) <> "=" <> cookies.scope(web.origin)
      <> "; HttpOnly; SameSite=Lax; Max-Age=0",
  )
}

fn failed(web: Web, req: wisp.Request, reason: String) -> wisp.Response {
  wisp.log_warning("sign-in failed: " <> reason)
  ui.page(
    web,
    req,
    ui.Shell("Sign-in failed", ui.theme(req), None, None, "", False),
    [
      ui.alert("danger", "Sign-in could not be completed. Please try again."),
      wisp_link("/auth/login", "Sign in again"),
    ],
    400,
  )
  |> clear_state(web)
}

fn wisp_link(href: String, label: String) {
  html.p([], [html.a([attribute.href(href), attribute.class("button")], [html.text(label)])])
}

/// Exchange a code at a real issuer's token endpoint.
pub fn http_exchange(web: Web) -> Exchange {
  fn(code: String, verifier: String) {
    let form =
      uri.query_to_string([
        #("grant_type", "authorization_code"),
        #("code", code),
        #("redirect_uri", web.oidc.redirect_uri),
        #("client_id", web.oidc.client_id),
        #("code_verifier", verifier),
        ..case web.oidc.client_secret {
          Some(secret) -> [#("client_secret", secret)]
          None -> []
        }
      ])
    use req <- result.try(
      request.to(web.oidc.token_endpoint) |> result.replace_error("invalid token endpoint"),
    )
    let req =
      req
      |> request.set_method(http.Post)
      |> request.set_header("content-type", "application/x-www-form-urlencoded")
      |> request.set_header("accept", "application/json")
      |> request.set_body(form)
    use resp <- result.try(
      httpc.configure()
      |> httpc.timeout(15_000)
      |> httpc.dispatch(req)
      |> result.replace_error("token endpoint unreachable"),
    )
    case resp.status {
      200 ->
        json.parse(resp.body, decode.at(["id_token"], decode.string))
        |> result.replace_error("token response without id_token")
      status -> Error("token endpoint returned " <> string.inspect(status))
    }
  }
}
