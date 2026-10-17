//// Native app sign-in through the development issuer: client
//// configuration, authorization code with PKCE for the native client,
//// bearer access tokens, refresh rotation and the recent-sign-in rule.

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/http
import gleam/json
import gleam/list
import gleam/string
import gleam/uri
import libarrie/api/router
import support
import wisp/simulate

const redirect = "libarrie://oauth/callback"

fn body(app: router.App, req) -> #(Int, String, List(#(String, String))) {
  let resp = router.handle(app, req)
  #(resp.status, simulate.read_body(resp), resp.headers)
}

fn field(text: String, path: List(String)) -> String {
  let assert Ok(value) = json.parse(text, decode.at(path, decode.string))
  value
}

fn authorize(app: router.App, client_id: String, redirect_uri: String, challenge: String) {
  simulate.request(http.Post, "/dev-issuer/authorize")
  |> simulate.form_body([
    #("client_id", client_id),
    #("redirect_uri", redirect_uri),
    #("state", "s1"),
    #("nonce", "n1"),
    #("code_challenge", challenge),
    #("subject", "native-" <> support.random_id()),
    #("name", "Phone User"),
  ])
  |> body(app, _)
}

fn token(app: router.App, form: List(#(String, String))) {
  simulate.request(http.Post, "/dev-issuer/token") |> simulate.form_body(form) |> body(app, _)
}

fn me(app: router.App, access: String) -> Int {
  let #(status, _, _) =
    simulate.request(http.Get, "/v1/me")
    |> simulate.header("authorization", "Bearer " <> access)
    |> body(app, _)
  status
}

pub fn client_configuration_test() {
  let app = support.app()
  let #(status, text, headers) =
    simulate.request(http.Get, "/v1/client-configuration") |> body(app, _)
  let assert 200 = status
  let assert "libarrie-native" = field(text, ["oidc", "client_id"])
  let assert "libarrie://oauth/callback" = field(text, ["oidc", "redirect_uri"])
  let assert True = string.ends_with(field(text, ["oidc", "token_endpoint"]), "/dev-issuer/token")
  let assert "sha256" = field(text, ["uploads", "integrity"])
  let assert Ok("public, max-age=300") = list.key_find(headers, "cache-control")
}

pub fn native_code_flow_and_refresh_test() {
  let app = support.app()
  let verifier = "native-verifier-" <> support.random_id() <> support.random_id()
  let challenge =
    crypto.hash(crypto.Sha256, bit_array.from_string(verifier)) |> bit_array.base64_url_encode(False)
  // An unregistered redirect is refused.
  let assert #(400, _, _) = authorize(app, "libarrie-native", "evilapp://callback", challenge)
  let assert #(303, _, headers) = authorize(app, "libarrie-native", redirect, challenge)
  let assert Ok(location) = list.key_find(headers, "location")
  let assert True = string.starts_with(location, redirect <> "?")
  let assert Ok(#(_, query)) = string.split_once(location, "?")
  let assert Ok(params) = uri.parse_query(query)
  let assert Ok(code) = list.key_find(params, "code")
  let assert Ok("s1") = list.key_find(params, "state")
  // A wrong verifier fails PKCE.
  let assert #(400, _, _) =
    token(app, [#("grant_type", "authorization_code"), #("code", code), #("code_verifier", "wrong")])
  let #(status, text, headers) =
    token(app, [
      #("grant_type", "authorization_code"),
      #("code", code),
      #("code_verifier", verifier),
      #("client_id", "libarrie-native"),
      #("redirect_uri", redirect),
    ])
  let assert 200 = status
  let assert Ok("no-store") = list.key_find(headers, "cache-control")
  let access = field(text, ["access_token"])
  let refresh = field(text, ["refresh_token"])
  let id_token = field(text, ["id_token"])
  // The access token works as a bearer; the ID token (native audience) does not.
  let assert 200 = me(app, access)
  let assert 401 = me(app, id_token)
  // Refresh rotates both tokens and keeps the original sign-in time.
  let assert #(200, refreshed, _) =
    token(app, [#("grant_type", "refresh_token"), #("refresh_token", refresh), #("client_id", "libarrie-native")])
  let new_access = field(refreshed, ["access_token"])
  let assert True = field(refreshed, ["refresh_token"]) != refresh
  let assert 200 = me(app, new_access)
  let auth_time = fn(jwt: String) {
    let assert [_, payload, _] = string.split(jwt, ".")
    let assert Ok(bits) = bit_array.base64_url_decode(payload)
    let assert Ok(text) = bit_array.to_string(bits)
    let assert Ok(t) = json.parse(text, decode.at(["auth_time"], decode.int))
    t
  }
  let assert True = auth_time(new_access) == auth_time(access)
  // Refresh tokens are bound to the native client.
  let assert #(400, _, _) =
    token(app, [#("grant_type", "refresh_token"), #("refresh_token", refresh), #("client_id", "libarrie")])
  let assert #(400, _, _) = token(app, [#("grant_type", "password")])
}
