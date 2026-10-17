import envoy
import gleam/bit_array
import gleam/crypto
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/list
import gleam/int
import gleam/option.{None, Some}
import gleeunit
import libarrie/integrations/identity
import libarrie/integrations/image
import libarrie/integrations/providers
import libarrie/integrations/storage
import libarrie/integrations/zip

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn png_inspection_and_mock_text_test() {
  let bytes = image.mock_png(640, 480, Some("Meeting notes with Ada"))
  let assert Ok(image.ImageInfo(image.Png, 640, 480)) =
    image.inspect(bytes, image.default_limits())
  let assert Some("Meeting notes with Ada") = image.embedded_text(bytes)
  let assert Error("unrecognized_format") =
    image.inspect(<<"GIF89a">>, image.default_limits())
  // A header declaring 20,000 x 20,000 pixels is refused before decoding.
  let huge_header = <<
    0x89, "PNG":utf8, 0x0D, 0x0A, 0x1A, 0x0A, 13:32, "IHDR":utf8, 20_000:32,
    20_000:32, 8, 0, 0, 0, 0, 0:32,
  >>
  let assert Error("pixels_exceed_limit") =
    image.inspect(huge_header, image.default_limits())
}

pub fn jpeg_inspection_test() {
  // SOI, COM segment, SOF0 with 100x50.
  let bytes = <<
    0xFF, 0xD8, 0xFF, 0xFE, 0, 7, "hello":utf8, 0xFF, 0xC0, 0, 11, 8, 0, 50, 0,
    100, 1, 1, 0x11, 0, 0xFF, 0xD9,
  >>
  let assert Ok(image.ImageInfo(image.Jpeg, 100, 50)) =
    image.inspect(bytes, image.default_limits())
  let assert Some("hello") = image.embedded_text(bytes)
}

pub fn mock_ocr_outcomes_test() {
  let ocr = providers.mock_ocr()
  let assert Ok(providers.BlankConfirmed) =
    ocr.recognize(image.mock_png(1, 1, Some("[[blank]]")), "image/png")
  let assert Ok(providers.NoTextDetected) =
    ocr.recognize(image.mock_png(1, 1, None), "image/png")
  let assert Error(providers.Transient(_)) =
    ocr.recognize(image.mock_png(1, 1, Some("[[transient]]")), "image/png")
}

pub fn mock_embedding_similarity_test() {
  let embedder = providers.mock_embedding(64)
  let assert Ok([a, b, c]) =
    embedder.embed(
      [
        "quarterly budget review", "budget review for the quarter",
        "grocery list eggs milk",
      ],
      providers.Document,
    )
  let dot = fn(x, y) { list.zip(x, y) |> list.fold(0.0, fn(s, p) { s +. p.0 *. p.1 }) }
  let assert True = dot(a, b) >. dot(a, c)
}

pub fn development_token_round_trip_test() {
  let token =
    identity.mint_development_token("secret", "http://dev", "libarrie", "user-1", "Ada", 1000, 600)
  let verifier = identity.Verifier("http://dev", "libarrie", identity.Hs256Secret("secret"), 0)
  let assert Ok(claims) = identity.verify(verifier, token, 1100)
  let assert "user-1" = claims.subject
  let assert Error(identity.Expired) = identity.verify(verifier, token, 1700)
  let assert Error(identity.BadSignature) =
    identity.verify(identity.Verifier(..verifier, keys: identity.Hs256Secret("other")), token, 1100)
  let assert Error(identity.WrongAudience) =
    identity.verify(identity.Verifier(..verifier, audience: "x"), token, 1100)
}

pub fn sigv4_encoding_test() {
  let assert "a%20b%2Fc~" = storage.encode("a b/c~")
  let assert "staging/a%20b/c" = storage.encode_path("staging/a b/c")
}

/// Runs only when LIBARRIE_TEST_S3_ENDPOINT is set (local SeaweedFS stack).
pub fn object_store_contract_test() {
  case envoy.get("LIBARRIE_TEST_S3_ENDPOINT") {
    Error(_) -> Nil
    Ok(endpoint) -> {
      let config =
        storage.Config(
          endpoint:,
          public_endpoint: endpoint,
          region: "us-east-1",
          bucket: "libarrie-test",
          access_key_id: "libarrie-dev-access",
          secret_access_key: "libarrie-dev-secret",
          upload_integrity: storage.Sha256Header,
        )
      let assert Ok(Nil) = storage.ensure_bucket(config)
      let body = <<"hello object store":utf8>>
      let checksum =
        crypto.hash(crypto.Sha256, body) |> bit_array.base64_encode(True)
      let signed =
        storage.presign_put(config, "staging/obj 1", 18, "image/png", checksum, None, 300)
      let assert 200 = client_put(signed, body)
      // Wrong body with the same declared headers must be rejected.
      let assert False =
        client_put(signed, <<"HELLO object store":utf8>>) == 200
      let assert Ok(info) = storage.head(config, "staging/obj 1")
      let assert 18 = info.bytes
      let assert Ok(Nil) =
        storage.copy_if_match(config, "staging/obj 1", "final/obj-1", info.etag)
      let assert Error(storage.PreconditionFailed) =
        storage.copy_if_match(config, "staging/obj 1", "final/obj-2", "\"deadbeef\"")
      let assert Ok(copied) = storage.get(config, "final/obj-1")
      let assert True = copied == body
      let assert Ok(Nil) = storage.delete(config, "final/obj-1")
      Nil
    }
  }
}

/// R2 mode: the presigned URL binds Content-MD5, so the store rejects a
/// tampered body of the same length. Also write-once puts and listing.
pub fn md5_integrity_and_journal_primitives_test() {
  case envoy.get("LIBARRIE_TEST_S3_ENDPOINT") {
    Error(_) -> Nil
    Ok(endpoint) -> {
      let config =
        storage.Config(
          endpoint:,
          public_endpoint: endpoint,
          region: "us-east-1",
          bucket: "libarrie-test",
          access_key_id: "libarrie-dev-access",
          secret_access_key: "libarrie-dev-secret",
          upload_integrity: storage.ContentMd5,
        )
      let assert Ok(Nil) = storage.ensure_bucket(config)
      let body = <<"md5 bound body!!":utf8>>
      let md5 = crypto.hash(crypto.Md5, body) |> bit_array.base64_encode(True)
      let key = "staging/md5-" <> int.to_string(int.random(1_000_000))
      let signed = storage.presign_put(config, key, 16, "image/png", "", Some(md5), 300)
      let assert True = list.key_find(signed.headers, "content-md5") == Ok(md5)
      let assert False = list.any(signed.headers, fn(h) { h.0 == "x-amz-checksum-sha256" })
      let assert False = client_put(signed, <<"MD5 BOUND BODY!!":utf8>>) == 200
      let assert 200 = client_put(signed, body)
      // Write-once journal objects.
      let jkey = "journal-test/" <> int.to_string(int.random(1_000_000_000)) <> ".json"
      let assert Ok(storage.Created) = storage.put_if_absent(config, jkey, <<"{}":utf8>>, "application/json")
      let assert Ok(storage.AlreadyExists) = storage.put_if_absent(config, jkey, <<"{\"x\":1}":utf8>>, "application/json")
      let assert Ok(<<"{}":utf8>>) = storage.get(config, jkey)
      let assert Ok(listing) = storage.list_objects(config, "journal-test/", None)
      let assert True = list.contains(listing.keys, jkey)
      Nil
    }
  }
}

/// Multipart upload (used for export parts over the chunk size).
pub fn multipart_upload_contract_test() {
  case envoy.get("LIBARRIE_TEST_S3_ENDPOINT") {
    Error(_) -> Nil
    Ok(endpoint) -> {
      let config =
        storage.Config(
          endpoint:,
          public_endpoint: endpoint,
          region: "us-east-1",
          bucket: "libarrie-test",
          access_key_id: "libarrie-dev-access",
          secret_access_key: "libarrie-dev-secret",
          upload_integrity: storage.Sha256Header,
        )
      let assert Ok(Nil) = storage.ensure_bucket(config)
      let first = crypto.strong_random_bytes(5_242_880)
      let second = <<"tail bytes":utf8>>
      let assert Ok(upload_id) = storage.create_multipart(config, "multi/obj", "application/zip")
      let assert Ok(etag1) = storage.upload_part(config, "multi/obj", upload_id, 1, first)
      let assert Ok(etag2) = storage.upload_part(config, "multi/obj", upload_id, 2, second)
      let assert Ok(Nil) =
        storage.complete_multipart(config, "multi/obj", upload_id, [#(1, etag1), #(2, etag2)])
      let assert Ok(body) = storage.get(config, "multi/obj")
      let assert True = body == bit_array.concat([first, second])
      let assert Ok(Nil) = storage.delete(config, "multi/obj")
      Nil
    }
  }
}

fn client_put(signed: storage.PresignedRequest, body: BitArray) -> Int {
  let assert Ok(req) = request.to(signed.url)
  let req =
    signed.headers
    |> list.filter(fn(h) { h.0 != "content-length" })
    |> list.fold(req, fn(r, h) { request.set_header(r, h.0, h.1) })
    |> request.set_method(http.Put)
    |> request.set_body(body)
  case httpc.dispatch_bits(httpc.configure(), req) {
    Ok(resp) -> resp.status
    Error(_) -> 0
  }
}

pub fn zip64_records_test() {
  let assert 0xCBF43926 = zip.crc32(<<"123456789":utf8>>)
  let w = zip.new()
  let #(w, a) = zip.add(w, "a.txt", <<"abc":utf8>>)
  let end = zip.finish(w)
  // Local header signature, ZIP64 end record, locator and classic end record.
  let assert <<0x50, 0x4b, 0x03, 0x04, _:bits>> = a
  let size = bit_array.byte_size(end)
  let assert Ok(<<0x50, 0x4b, 0x05, 0x06, _:bits>>) = bit_array.slice(end, size - 22, 22)
  let assert Ok(<<0x50, 0x4b, 0x06, 0x07, _:bits>>) = bit_array.slice(end, size - 42, 20)
}
