//// RS256 verification against issuer keys, and the JWKS cache that keeps
//// them current when the issuer rotates its signing keys.

import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/json
import libarrie/integrations/identity

type KeyPair {
  KeyPair(jwk: identity.Jwk, private: Dynamic)
}

@external(erlang, "libarrie_identity_test_ffi", "rsa_keypair")
fn rsa_keypair() -> #(BitArray, BitArray, Dynamic)

@external(erlang, "libarrie_identity_test_ffi", "rsa_sign")
fn rsa_sign(message: BitArray, private: Dynamic) -> BitArray

fn key(kid: String) -> KeyPair {
  let #(modulus, exponent, private) = rsa_keypair()
  KeyPair(identity.Jwk(kid:, modulus:, exponent:), private)
}

fn segment(value: json.Json) -> String {
  bit_array.base64_url_encode(<<json.to_string(value):utf8>>, False)
}

fn token(pair: KeyPair) -> String {
  let signing_input =
    segment(json.object([
      #("alg", json.string("RS256")),
      #("typ", json.string("JWT")),
      #("kid", json.string(pair.jwk.kid)),
    ]))
    <> "."
    <> segment(json.object([
      #("iss", json.string("https://issuer.test")),
      #("aud", json.string("libarrie")),
      #("sub", json.string("user-1")),
      #("exp", json.int(2000)),
    ]))
  let signature = rsa_sign(<<signing_input:utf8>>, pair.private)
  signing_input <> "." <> bit_array.base64_url_encode(signature, False)
}

fn verifier(keys: identity.Keys) -> identity.Verifier {
  identity.Verifier("https://issuer.test", "libarrie", keys, 0)
}

/// A fetch function that reports each call and returns `result`.
fn counting_fetch(result: Result(List(identity.Jwk), String)) {
  let calls = process.new_subject()
  #(calls, fn() {
    process.send(calls, Nil)
    result
  })
}

fn count(calls: process.Subject(Nil)) -> Int {
  case process.receive(calls, 0) {
    Ok(_) -> 1 + count(calls)
    Error(_) -> 0
  }
}

pub fn rs256_tokens_verify_against_issuer_keys_test() {
  let k1 = key("k1")
  let k2 = key("k2")
  let keys = identity.RsaKeys([k1.jwk])
  let assert Ok(claims) = identity.verify(verifier(keys), token(k1), 1000)
  let assert "user-1" = claims.subject
  // A static key set cannot verify a token from a key it does not have.
  let assert Error(identity.UnknownKey) = identity.verify(verifier(keys), token(k2), 1000)
  // A signature from another key under a known key ID is rejected.
  let forged = KeyPair(identity.Jwk(..k2.jwk, kid: "k1"), k2.private)
  let assert Error(identity.BadSignature) = identity.verify(verifier(keys), token(forged), 1000)
  let assert Error(identity.Expired) = identity.verify(verifier(keys), token(k1), 3000)
}

pub fn rotated_keys_are_fetched_once_test() {
  let k1 = key("k1")
  let k2 = key("k2")
  let #(calls, fetch) = counting_fetch(Ok([k1.jwk, k2.jwk]))
  let assert Ok(cache) = identity.start_cache([k1.jwk], fetch, 3600, fn() { 1000 })
  let v = verifier(identity.RemoteKeys(cache))
  // A known key needs no fetch.
  let assert Ok(_) = identity.verify(v, token(k1), 1000)
  let assert 0 = count(calls)
  // The issuer rotated to k2: one fetch brings it in.
  let assert Ok(_) = identity.verify(v, token(k2), 1000)
  let assert 1 = count(calls)
  let assert Ok(_) = identity.verify(v, token(k2), 1000)
  let assert 0 = count(calls)
  // An unknown key ID within the interval does not fetch again.
  let assert Error(identity.UnknownKey) = identity.verify(v, token(key("forged")), 1000)
  let assert 0 = count(calls)
}

pub fn refetch_is_allowed_after_the_interval_test() {
  let k1 = key("k1")
  let #(calls, fetch) = counting_fetch(Ok([k1.jwk]))
  let assert Ok(cache) = identity.start_cache([k1.jwk], fetch, 0, fn() { 1000 })
  let assert [_] = identity.keys_for(cache, "missing")
  let assert [_] = identity.keys_for(cache, "missing")
  let assert 2 = count(calls)
}

pub fn failed_fetch_keeps_the_previous_keys_test() {
  let k1 = key("k1")
  let #(calls, fetch) = counting_fetch(Error("issuer unavailable"))
  let assert Ok(cache) = identity.start_cache([k1.jwk], fetch, 0, fn() { 1000 })
  let v = verifier(identity.RemoteKeys(cache))
  let assert Error(identity.UnknownKey) = identity.verify(v, token(key("k2")), 1000)
  let assert 1 = count(calls)
  let assert Ok(_) = identity.verify(v, token(k1), 1000)
}
