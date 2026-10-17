//// Built-in development OIDC issuer (section 6: "local development issuer
//// for self-hosting/tests"). Enabled only with DEV_ISSUER_SECRET and never
//// in hosted mode.
////
//// `/dev-issuer/authorize` shows a sign-in form for any subject. Codes are
//// HS256-signed, expire after 60 seconds and bind the client, redirect URI,
//// nonce and PKCE challenge. `/dev-issuer/token` (and the in-process
//// `exchange`) verify all of them and return an HS256 ID token.
////
//// Two clients are registered: the web client (server-side code exchange)
//// and, when configured, the native apps' public client. Native clients
//// receive an access token for the API audience and a rotating refresh
//// token (30 days). Refreshing keeps the original `auth_time`, so a refresh
//// never satisfies the recent-sign-in rule for sensitive actions.

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import libarrie/integrations/identity
import libarrie/web/config.{type Web}
import libarrie/web/oidc
import libarrie/web/session
import libarrie/web/ui
import lustre/attribute.{attribute, class}
import lustre/element/html
import wisp

pub fn authorize_form(web: Web, req: wisp.Request) -> wisp.Response {
  let query = wisp.get_query(req)
  let field = fn(name) { list.key_find(query, name) |> result.unwrap("") }
  let hidden = fn(name) {
    html.input([attribute.type_("hidden"), attribute.name(name), attribute.value(field(name))])
  }
  ui.page(
    web,
    req,
    ui.Shell("Development sign-in", ui.theme(req), None, None, "", False),
    [
      html.section([class("card narrow")], [
        html.h1([], [html.text("Development sign-in")]),
        html.p([class("muted")], [
          html.text(
            "This local issuer exists only for development and tests. Any subject signs in.",
          ),
        ]),
        html.form([attribute.method("post"), attribute.action("/dev-issuer/authorize")], [
          hidden("client_id"),
          hidden("redirect_uri"),
          hidden("state"),
          hidden("nonce"),
          hidden("code_challenge"),
          html.label([attribute.for("subject")], [html.text("Subject")]),
          html.input([
            attribute.id("subject"),
            attribute.name("subject"),
            attribute.value("dev-user"),
            attribute("required", ""),
            attribute("autocomplete", "username"),
          ]),
          html.label([attribute.for("display-name")], [html.text("Display name")]),
          html.input([
            attribute.id("display-name"),
            attribute.name("name"),
            attribute.value("Dev User"),
          ]),
          html.button([attribute.type_("submit"), class("button")], [html.text("Sign in")]),
        ]),
      ]),
    ],
    200,
  )
}

pub fn authorize_submit(web: Web, secret: String, req: wisp.Request) -> wisp.Response {
  use form <- wisp.require_form(req)
  let value = fn(name) { list.key_find(form.values, name) |> result.unwrap("") }
  case registered(web, value("client_id"), value("redirect_uri")) {
    False -> wisp.bad_request("unknown client or redirect URI")
    True -> {
      let code =
        identity.sign_hs256(secret, [
          #("typ", json.string("dev-code")),
          #("sub", json.string(value("subject"))),
          #("name", json.string(value("name"))),
          #("nonce", json.string(value("nonce"))),
          #("challenge", json.string(value("code_challenge"))),
          #("redirect_uri", json.string(value("redirect_uri"))),
          #("client_id", json.string(value("client_id"))),
          #("auth_time", json.int(oidc.now())),
          #("exp", json.int(oidc.now() + 60)),
        ])
      let location =
        value("redirect_uri")
        <> "?"
        <> uri.query_to_string([#("code", code), #("state", value("state"))])
      wisp.response(303) |> wisp.set_header("location", location) |> ui.security_headers(web)
    }
  }
}

/// The web client or the native client, with its exact redirect URI.
fn registered(web: Web, client_id: String, redirect_uri: String) -> Bool {
  { client_id == web.oidc.client_id && redirect_uri == web.oidc.redirect_uri }
  || case web.native {
    Some(native) -> client_id == native.client_id && redirect_uri == native.redirect_uri
    None -> False
  }
}

fn is_native(web: Web, client_id: String) -> Bool {
  case web.native {
    Some(native) -> client_id == native.client_id
    None -> False
  }
}

type Code {
  Code(
    sub: String,
    name: String,
    nonce: String,
    challenge: String,
    redirect_uri: String,
    client_id: String,
    auth_time: Int,
    exp: Int,
  )
}

/// Verify a code and its PKCE verifier for any registered client.
fn redeem(web: Web, secret: String, code: String, verifier: String) -> Result(Code, String) {
  use payload <- result.try(
    identity.verify_hs256_payload(secret, code) |> result.replace_error("invalid code"),
  )
  use code <- result.try(
    json.parse(payload, {
      use typ <- decode.field("typ", decode.string)
      use sub <- decode.field("sub", decode.string)
      use name <- decode.field("name", decode.string)
      use nonce <- decode.field("nonce", decode.string)
      use challenge <- decode.field("challenge", decode.string)
      use redirect_uri <- decode.field("redirect_uri", decode.string)
      use client_id <- decode.field("client_id", decode.string)
      use auth_time <- decode.field("auth_time", decode.int)
      use exp <- decode.field("exp", decode.int)
      case typ {
        "dev-code" ->
          decode.success(Code(sub, name, nonce, challenge, redirect_uri, client_id, auth_time, exp))
        _ -> decode.failure(Code("", "", "", "", "", "", 0, 0), "dev-code")
      }
    })
    |> result.replace_error("invalid code"),
  )
  let computed =
    crypto.hash(crypto.Sha256, bit_array.from_string(verifier))
    |> bit_array.base64_url_encode(False)
  case
    code.exp > oidc.now(),
    computed == code.challenge,
    registered(web, code.client_id, code.redirect_uri)
  {
    False, _, _ -> Error("code expired")
    _, False, _ -> Error("PKCE verification failed")
    _, _, False -> Error("code issued to an unknown client")
    True, True, True -> Ok(code)
  }
}

fn id_token(
  web: Web,
  secret: String,
  client_id: String,
  sub: String,
  name: String,
  nonce: String,
  auth_time: Int,
) -> String {
  // An email-shaped subject doubles as the email claim, for trying the
  // admin area locally.
  let email = case string.contains(sub, "@") {
    True -> [#("email", json.string(sub))]
    False -> []
  }
  identity.sign_hs256(
    secret,
    list.append(
      [
        #("iss", json.string(web.oidc.issuer)),
        #("aud", json.string(client_id)),
        #("sub", json.string(sub)),
        #("name", json.string(name)),
        #("nonce", json.string(nonce)),
        #("auth_time", json.int(auth_time)),
        #("iat", json.int(oidc.now())),
        #("exp", json.int(oidc.now() + token_seconds)),
      ],
      email,
    ),
  )
}

const token_seconds = 600

const refresh_seconds = 2_592_000

/// Verify a code for the web client; return a signed ID token.
pub fn exchange(web: Web, secret: String) -> oidc.Exchange {
  fn(code: String, verifier: String) {
    use code <- result.try(redeem(web, secret, code, verifier))
    case code.client_id == web.oidc.client_id {
      False -> Error("code issued to another client")
      True -> Ok(id_token(web, secret, code.client_id, code.sub, code.name, code.nonce, code.auth_time))
    }
  }
}

/// Tokens for the native client: an ID token, an access token for the API
/// audience and a rotating refresh token.
fn native_tokens(web: Web, secret: String, client_id: String, sub: String, name: String, nonce: String, auth_time: Int) -> json.Json {
  let access =
    identity.sign_hs256(secret, [
      #("iss", json.string(web.oidc.issuer)),
      #("aud", json.string(web.audience)),
      #("sub", json.string(sub)),
      #("name", json.string(name)),
      #("auth_time", json.int(auth_time)),
      #("iat", json.int(oidc.now())),
      #("exp", json.int(oidc.now() + token_seconds)),
    ])
  let refresh =
    identity.sign_hs256(secret, [
      #("typ", json.string("dev-refresh")),
      #("sub", json.string(sub)),
      #("name", json.string(name)),
      #("client_id", json.string(client_id)),
      #("auth_time", json.int(auth_time)),
      #("jti", json.string(session.random_token(16))),
      #("exp", json.int(oidc.now() + refresh_seconds)),
    ])
  json.object([
    #("id_token", json.string(id_token(web, secret, client_id, sub, name, nonce, auth_time))),
    #("access_token", json.string(access)),
    #("refresh_token", json.string(refresh)),
    #("token_type", json.string("Bearer")),
    #("expires_in", json.int(token_seconds)),
  ])
}

fn refresh(web: Web, secret: String, token: String, client_id: String) -> Result(json.Json, String) {
  use payload <- result.try(
    identity.verify_hs256_payload(secret, token) |> result.replace_error("invalid refresh token"),
  )
  use #(sub, name, issued_to, auth_time, exp) <- result.try(
    json.parse(payload, {
      use typ <- decode.field("typ", decode.string)
      use sub <- decode.field("sub", decode.string)
      use name <- decode.field("name", decode.string)
      use issued_to <- decode.field("client_id", decode.string)
      use auth_time <- decode.field("auth_time", decode.int)
      use exp <- decode.field("exp", decode.int)
      case typ {
        "dev-refresh" -> decode.success(#(sub, name, issued_to, auth_time, exp))
        _ -> decode.failure(#("", "", "", 0, 0), "dev-refresh")
      }
    })
    |> result.replace_error("invalid refresh token"),
  )
  case exp > oidc.now(), issued_to == client_id && is_native(web, client_id) {
    False, _ -> Error("refresh token expired")
    _, False -> Error("refresh token issued to another client")
    True, True -> Ok(native_tokens(web, secret, client_id, sub, name, "", auth_time))
  }
}

/// `POST /dev-issuer/token`: `authorization_code` for both clients and
/// `refresh_token` for the native client.
pub fn token_endpoint(web: Web, secret: String, req: wisp.Request) -> wisp.Response {
  use form <- wisp.require_form(req)
  let value = fn(name) { list.key_find(form.values, name) |> result.unwrap("") }
  let outcome = case value("grant_type") {
    "authorization_code" | "" -> {
      use code <- result.try(redeem(web, secret, value("code"), value("code_verifier")))
      use <- bool_guard(
        value("client_id") == "" || value("client_id") == code.client_id,
        "code issued to another client",
      )
      use <- bool_guard(
        value("redirect_uri") == "" || value("redirect_uri") == code.redirect_uri,
        "redirect_uri does not match the authorization request",
      )
      case is_native(web, code.client_id) {
        True ->
          Ok(native_tokens(web, secret, code.client_id, code.sub, code.name, code.nonce, code.auth_time))
        False -> {
          let token = id_token(web, secret, code.client_id, code.sub, code.name, code.nonce, code.auth_time)
          Ok(json.object([
            #("id_token", json.string(token)),
            #("access_token", json.string(token)),
            #("token_type", json.string("Bearer")),
            #("expires_in", json.int(token_seconds)),
          ]))
        }
      }
    }
    "refresh_token" -> refresh(web, secret, value("refresh_token"), value("client_id"))
    _ -> Error("unsupported grant_type")
  }
  case outcome {
    Ok(body) ->
      wisp.json_response(json.to_string(body), 200)
      |> wisp.set_header("cache-control", "no-store")
    Error(reason) ->
      wisp.json_response(
        json.to_string(json.object([
          #("error", json.string("invalid_grant")),
          #("error_description", json.string(reason)),
        ])),
        400,
      )
  }
}

fn bool_guard(condition: Bool, reason: String, next: fn() -> Result(a, String)) -> Result(a, String) {
  case condition {
    True -> next()
    False -> Error(reason)
  }
}
