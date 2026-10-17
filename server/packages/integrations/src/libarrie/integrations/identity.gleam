//// OIDC bearer token validation (section 6).
////
//// A replaceable identity adapter: production verifies RS256 tokens against
//// the issuer's JWKS; the local development/test issuer uses HS256 with a
//// shared secret. Issuer, audience, expiry and signature are always checked.

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/time/timestamp

pub type Keys {
  /// Local development issuer only.
  Hs256Secret(secret: String)
  RsaKeys(keys: List(Jwk))
  /// The issuer's JWKS, re-fetched when a token names a key ID that isn't
  /// cached (the issuer rotated its signing keys). See `remote_keys`.
  RemoteKeys(cache: JwksCache)
}

pub type Jwk {
  Jwk(kid: String, modulus: BitArray, exponent: BitArray)
}

pub type Verifier {
  Verifier(issuer: String, audience: String, keys: Keys, leeway_seconds: Int)
}

pub type Claims {
  Claims(
    issuer: String,
    subject: String,
    audience: List(String),
    expires_at: Int,
    auth_time: Option(Int),
    name: Option(String),
    /// As the issuer sent it; shown to admins, never used to match people.
    email: Option(String),
    nonce: Option(String),
  )
}

pub type TokenError {
  Malformed
  UnsupportedAlgorithm
  UnknownKey
  BadSignature
  Expired
  WrongIssuer
  WrongAudience
}

pub fn verify(
  verifier: Verifier,
  token: String,
  now_seconds: Int,
) -> Result(Claims, TokenError) {
  use #(header_b64, payload_b64, signature_b64) <- result.try(
    case string.split(token, ".") {
      [h, p, s] -> Ok(#(h, p, s))
      _ -> Error(Malformed)
    },
  )
  use header <- result.try(decode_segment(header_b64, header_decoder()))
  use signature <- result.try(
    bit_array.base64_url_decode(signature_b64) |> result.replace_error(Malformed),
  )
  let message = bit_array.from_string(header_b64 <> "." <> payload_b64)
  use _ <- result.try(check_signature(verifier.keys, header, message, signature))
  use claims <- result.try(decode_segment(payload_b64, claims_decoder()))
  use _ <- result.try(case claims.issuer == verifier.issuer {
    True -> Ok(Nil)
    False -> Error(WrongIssuer)
  })
  use _ <- result.try(case list.contains(claims.audience, verifier.audience) {
    True -> Ok(Nil)
    False -> Error(WrongAudience)
  })
  case claims.expires_at + verifier.leeway_seconds > now_seconds {
    True -> Ok(claims)
    False -> Error(Expired)
  }
}

type Header {
  Header(alg: String, kid: Option(String))
}

fn header_decoder() -> decode.Decoder(Header) {
  use alg <- decode.field("alg", decode.string)
  use kid <- decode.optional_field("kid", None, decode.optional(decode.string))
  decode.success(Header(alg:, kid:))
}

fn claims_decoder() -> decode.Decoder(Claims) {
  use issuer <- decode.field("iss", decode.string)
  use subject <- decode.field("sub", decode.string)
  use audience <- decode.field(
    "aud",
    decode.one_of(decode.list(decode.string), [
      decode.string |> decode.map(fn(a) { [a] }),
    ]),
  )
  use expires_at <- decode.field("exp", decode.int)
  use auth_time <- decode.optional_field(
    "auth_time",
    None,
    decode.optional(decode.int),
  )
  use name <- decode.optional_field("name", None, decode.optional(decode.string))
  use email <- decode.optional_field("email", None, decode.optional(decode.string))
  use nonce <- decode.optional_field("nonce", None, decode.optional(decode.string))
  decode.success(Claims(issuer:, subject:, audience:, expires_at:, auth_time:, name:, email:, nonce:))
}

fn decode_segment(
  segment: String,
  decoder: decode.Decoder(a),
) -> Result(a, TokenError) {
  use bits <- result.try(
    bit_array.base64_url_decode(segment) |> result.replace_error(Malformed),
  )
  use text <- result.try(
    bit_array.to_string(bits) |> result.replace_error(Malformed),
  )
  json.parse(text, decoder) |> result.replace_error(Malformed)
}

fn check_signature(
  keys: Keys,
  header: Header,
  message: BitArray,
  signature: BitArray,
) -> Result(Nil, TokenError) {
  case keys, header.alg {
    Hs256Secret(secret), "HS256" -> {
      let expected =
        crypto.hmac(message, crypto.Sha256, bit_array.from_string(secret))
      case crypto.secure_compare(expected, signature) {
        True -> Ok(Nil)
        False -> Error(BadSignature)
      }
    }
    RsaKeys(jwks), "RS256" -> {
      use key <- result.try(select_key(jwks, header.kid))
      rsa_check(message, signature, key)
    }
    RemoteKeys(cache), "RS256" -> {
      use key <- result.try(case select_key(cached_keys(cache), header.kid), header.kid {
        Error(UnknownKey), Some(kid) -> select_key(keys_for(cache, kid), header.kid)
        found, _ -> found
      })
      rsa_check(message, signature, key)
    }
    _, _ -> Error(UnsupportedAlgorithm)
  }
}

fn rsa_check(message: BitArray, signature: BitArray, key: Jwk) -> Result(Nil, TokenError) {
  case rsa_sha256_verify(message, signature, key.modulus, key.exponent) {
    True -> Ok(Nil)
    False -> Error(BadSignature)
  }
}

fn select_key(jwks: List(Jwk), kid: Option(String)) -> Result(Jwk, TokenError) {
  case kid, jwks {
    Some(kid), _ ->
      list.find(jwks, fn(k) { k.kid == kid }) |> result.replace_error(UnknownKey)
    None, [only] -> Ok(only)
    None, _ -> Error(UnknownKey)
  }
}

@external(erlang, "libarrie_identity_ffi", "rsa_sha256_verify")
fn rsa_sha256_verify(
  message: BitArray,
  signature: BitArray,
  modulus: BitArray,
  exponent: BitArray,
) -> Bool

/// Parse a JWKS document, keeping RSA signing keys.
pub fn parse_jwks(document: String) -> Result(List(Jwk), Nil) {
  let key = {
    use kty <- decode.field("kty", decode.string)
    use kid <- decode.optional_field("kid", "", decode.string)
    use n <- decode.optional_field("n", "", decode.string)
    use e <- decode.optional_field("e", "", decode.string)
    decode.success(#(kty, kid, n, e))
  }
  use keys <- result.try(
    json.parse(document, decode.at(["keys"], decode.list(key)))
    |> result.replace_error(Nil),
  )
  keys
  |> list.filter_map(fn(k) {
    case k {
      #("RSA", kid, n, e) -> {
        use modulus <- result.try(bit_array.base64_url_decode(n))
        use exponent <- result.try(bit_array.base64_url_decode(e))
        Ok(Jwk(kid:, modulus:, exponent:))
      }
      _ -> Error(Nil)
    }
  })
  |> Ok
}

/// Fetch and parse a JWKS document over HTTPS.
pub fn fetch_jwks(url: String) -> Result(List(Jwk), String) {
  use req <- result.try(
    request.to(url) |> result.replace_error("invalid JWKS URL"),
  )
  use resp <- result.try(
    httpc.configure()
    |> httpc.timeout(10_000)
    |> httpc.dispatch(req)
    |> result.map_error(fn(e) { "JWKS fetch failed: " <> string.inspect(e) }),
  )
  case resp.status {
    200 -> parse_jwks(resp.body) |> result.replace_error("invalid JWKS document")
    status -> Error("JWKS fetch returned " <> int.to_string(status))
  }
}

/// Sign arbitrary claims with HS256 (development issuer only).
pub fn sign_hs256(secret: String, claims: List(#(String, json.Json))) -> String {
  let encode = fn(value: json.Json) {
    value
    |> json.to_string
    |> bit_array.from_string
    |> bit_array.base64_url_encode(False)
  }
  let header =
    encode(json.object([#("alg", json.string("HS256")), #("typ", json.string("JWT"))]))
  let payload = encode(json.object(claims))
  let signature =
    crypto.hmac(
      bit_array.from_string(header <> "." <> payload),
      crypto.Sha256,
      bit_array.from_string(secret),
    )
    |> bit_array.base64_url_encode(False)
  header <> "." <> payload <> "." <> signature
}

/// Verify an HS256 token and return its raw JSON payload (development
/// issuer authorization codes).
pub fn verify_hs256_payload(secret: String, token: String) -> Result(String, TokenError) {
  use #(header_b64, payload_b64, signature_b64) <- result.try(
    case string.split(token, ".") {
      [h, p, s] -> Ok(#(h, p, s))
      _ -> Error(Malformed)
    },
  )
  use signature <- result.try(
    bit_array.base64_url_decode(signature_b64) |> result.replace_error(Malformed),
  )
  let expected =
    crypto.hmac(
      bit_array.from_string(header_b64 <> "." <> payload_b64),
      crypto.Sha256,
      bit_array.from_string(secret),
    )
  use <- bool_guard(crypto.secure_compare(expected, signature), Error(BadSignature))
  use bits <- result.try(
    bit_array.base64_url_decode(payload_b64) |> result.replace_error(Malformed),
  )
  bit_array.to_string(bits) |> result.replace_error(Malformed)
}

fn bool_guard(condition: Bool, otherwise: a, next: fn() -> a) -> a {
  case condition {
    True -> next()
    False -> otherwise
  }
}

/// Mint an HS256 token from the local development issuer.
pub fn mint_development_token(
  secret: String,
  issuer: String,
  audience: String,
  subject: String,
  name: String,
  issued_at: Int,
  ttl_seconds: Int,
) -> String {
  let encode = fn(value: json.Json) {
    value
    |> json.to_string
    |> bit_array.from_string
    |> bit_array.base64_url_encode(False)
  }
  let header = encode(json.object([#("alg", json.string("HS256")), #("typ", json.string("JWT"))]))
  let payload =
    encode(
      json.object([
        #("iss", json.string(issuer)),
        #("aud", json.string(audience)),
        #("sub", json.string(subject)),
        #("name", json.string(name)),
        #("iat", json.int(issued_at)),
        #("auth_time", json.int(issued_at)),
        #("exp", json.int(issued_at + ttl_seconds)),
      ]),
    )
  let signature =
    crypto.hmac(
      bit_array.from_string(header <> "." <> payload),
      crypto.Sha256,
      bit_array.from_string(secret),
    )
    |> bit_array.base64_url_encode(False)
  header <> "." <> payload <> "." <> signature
}

/// Keyed identity hash for the usage ledger (section 10): HMAC-SHA-256 over a
/// length-prefixed issuer and subject so no raw identifier is stored.
pub fn identity_key(secret: String, issuer: String, subject: String) -> BitArray {
  let field = fn(value: String) {
    let bits = bit_array.from_string(value)
    <<bit_array.byte_size(bits):size(32), bits:bits>>
  }
  crypto.hmac(
    bit_array.concat([field(issuer), field(subject)]),
    crypto.Sha256,
    bit_array.from_string(secret),
  )
}

// JWKS cache ------------------------------------------------------------------------------

/// The issuer's signing keys, held by a small actor. Verification reads the
/// current keys without waiting. A token naming an unknown key ID asks for a
/// re-fetch, which runs in its own process (so verification never waits on
/// the issuer) and at most once per `min_interval_seconds` (so forged key IDs
/// cannot make the server hammer the issuer).
pub opaque type JwksCache {
  JwksCache(subject: Subject(CacheMessage))
}

type CacheMessage {
  Current(reply: Subject(List(Jwk)))
  Refresh(kid: String, reply: Subject(List(Jwk)))
  Fetched(result: Result(List(Jwk), String))
}

type CacheState {
  CacheState(
    self: Subject(CacheMessage),
    keys: List(Jwk),
    fetch: fn() -> Result(List(Jwk), String),
    now: fn() -> Int,
    min_interval_seconds: Int,
    last_attempt: Int,
    refreshing: Bool,
    waiters: List(Subject(List(Jwk))),
  )
}

const cache_wait_ms = 15_000

/// Fetch the issuer's JWKS now and keep it current: re-fetched when a token
/// names an unknown key ID, at most once a minute.
pub fn remote_keys(url: String) -> Result(Keys, String) {
  use keys <- result.try(fetch_jwks(url))
  start_cache(keys, fn() { fetch_jwks(url) }, 60, wall_clock)
  |> result.map(RemoteKeys)
}

fn wall_clock() -> Int {
  timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds |> fn(t) { t.0 }
}

/// Start a cache from initial keys. `fetch` and `now` are injectable for
/// tests; `remote_keys` is the production constructor.
pub fn start_cache(
  initial: List(Jwk),
  fetch: fn() -> Result(List(Jwk), String),
  min_interval_seconds: Int,
  now: fn() -> Int,
) -> Result(JwksCache, String) {
  actor.new_with_initialiser(1000, fn(self) {
    CacheState(
      self:,
      keys: initial,
      fetch:,
      now:,
      min_interval_seconds:,
      // The startup load does not count: the first unknown key ID may
      // re-fetch at once (a rotation right after boot).
      last_attempt: now() - min_interval_seconds,
      refreshing: False,
      waiters: [],
    )
    |> actor.initialised
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle_cache)
  |> actor.start
  |> result.map(fn(started) { JwksCache(started.data) })
  |> result.replace_error("could not start the JWKS cache")
}

fn handle_cache(state: CacheState, message: CacheMessage) -> actor.Next(CacheState, CacheMessage) {
  case message {
    Current(reply) -> {
      process.send(reply, state.keys)
      actor.continue(state)
    }
    Refresh(kid, reply) -> {
      let known = list.any(state.keys, fn(k) { k.kid == kid })
      let now = state.now()
      case known, state.refreshing, now - state.last_attempt < state.min_interval_seconds {
        // Another request already brought the key in.
        True, _, _ -> {
          process.send(reply, state.keys)
          actor.continue(state)
        }
        False, True, _ -> actor.continue(CacheState(..state, waiters: [reply, ..state.waiters]))
        // Re-fetched recently: the key ID is unknown to the issuer too.
        False, False, True -> {
          process.send(reply, state.keys)
          actor.continue(state)
        }
        False, False, False -> {
          let self = state.self
          let fetch = state.fetch
          process.spawn_unlinked(fn() { process.send(self, Fetched(fetch())) })
          actor.continue(CacheState(..state, refreshing: True, last_attempt: now, waiters: [reply]))
        }
      }
    }
    Fetched(result) -> {
      // A failed or empty fetch keeps the previous keys.
      let keys = case result {
        Ok([_, ..] as fresh) -> fresh
        _ -> state.keys
      }
      list.each(state.waiters, process.send(_, keys))
      actor.continue(CacheState(..state, keys:, refreshing: False, waiters: []))
    }
  }
}

/// The cached keys, without re-fetching.
pub fn cached_keys(cache: JwksCache) -> List(Jwk) {
  ask(cache, Current)
}

/// The keys after making sure `kid` was looked for: a re-fetch if it is not
/// cached and the last attempt is old enough.
pub fn keys_for(cache: JwksCache, kid: String) -> List(Jwk) {
  ask(cache, Refresh(kid, _))
}

fn ask(cache: JwksCache, message: fn(Subject(List(Jwk))) -> CacheMessage) -> List(Jwk) {
  let reply = process.new_subject()
  process.send(cache.subject, message(reply))
  process.receive(reply, cache_wait_ms) |> result.unwrap([])
}
