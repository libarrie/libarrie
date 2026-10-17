//// `libarrie_api storage-check`: verify the object stores behave as the
//// design requires before launch (sections 7, 14 and 20). Run it with the
//// real hosted credentials; it creates a few small probe objects.
////
//// Primary store: presigned uploads must be rejected by the store itself
//// when the body does not match the signed checksum or length, and
//// conditional copy must refuse a stale ETag. Journal store: writes must be
//// write-once and deletes must be refused (an R2 bucket lock rule covering
//// `journal/`), and the two stores must not share credentials.

import gleam/bit_array
import gleam/crypto
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{Some}
import gleam/string
import libarrie/integrations/storage

pub type Check {
  Check(name: String, passed: Bool, required: Bool, detail: String)
}

pub fn run(primary: storage.Config, journal: storage.Config) -> List(Check) {
  let stamp =
    crypto.strong_random_bytes(6) |> bit_array.base16_encode |> string.lowercase
  list.flatten([primary_checks(primary, stamp), journal_checks(primary, journal, stamp)])
}

pub fn report(checks: List(Check)) -> Bool {
  list.each(checks, fn(c) {
    let label = case c.passed, c.required {
      True, _ -> "PASS"
      False, True -> "FAIL"
      False, False -> "WARN"
    }
    io.println(label <> "  " <> c.name <> case c.detail {
      "" -> ""
      d -> " (" <> d <> ")"
    })
  })
  !list.any(checks, fn(c) { !c.passed && c.required })
}

fn client_put(signed: storage.PresignedRequest, body: BitArray) -> Int {
  case request.to(signed.url) {
    Error(_) -> 0
    Ok(req) -> {
      let req =
        signed.headers
        |> list.filter(fn(h) { h.0 != "content-length" })
        |> list.fold(req, fn(r, h) { request.set_header(r, h.0, h.1) })
        |> request.set_method(http.Put)
        |> request.set_body(body)
      case httpc.dispatch_bits(httpc.configure() |> httpc.timeout(30_000), req) {
        Ok(resp) -> resp.status
        Error(_) -> 0
      }
    }
  }
}

fn primary_checks(config: storage.Config, stamp: String) -> List(Check) {
  let body = <<"libarrie storage check body":utf8>>
  let size = bit_array.byte_size(body)
  let sha = crypto.hash(crypto.Sha256, body) |> bit_array.base64_encode(True)
  let md5 = crypto.hash(crypto.Md5, body) |> bit_array.base64_encode(True)
  let key = "staging/storage-check-" <> stamp
  let signed = storage.presign_put(config, key, size, "image/png", sha, Some(md5), 300)
  let ok_status = client_put(signed, body)
  let tampered = client_put(signed, <<"LIBARRIE STORAGE CHECK BODY":utf8>>)
  let longer = client_put(signed, <<body:bits, "extra":utf8>>)
  let copy = case storage.head(config, key) {
    Ok(_) ->
      case storage.copy_if_match(config, key, key <> "-copy", "\"0000\"") {
        Error(storage.PreconditionFailed) -> True
        _ -> False
      }
    Error(_) -> False
  }
  let download =
    case request.to(storage.presign_get(config, key, 60, "private, no-store").url) {
      Ok(req) ->
        case httpc.dispatch_bits(httpc.configure(), request.set_body(req, <<>>)) {
          Ok(resp) -> resp.status == 200 && resp.body == body
          Error(_) -> False
        }
      Error(_) -> False
    }
  let _ = storage.delete(config, key)
  let _ = storage.delete(config, key <> "-copy")
  let mode = case config.upload_integrity {
    storage.ContentMd5 -> "Content-MD5"
    storage.Sha256Header -> "x-amz-checksum-sha256"
  }
  [
    Check("primary: presigned upload with matching body succeeds", ok_status >= 200 && ok_status < 300, True, "status " <> int.to_string(ok_status)),
    Check("primary: store rejects a same-length body that fails " <> mode, tampered < 200 || tampered >= 300, True, "status " <> int.to_string(tampered)),
    Check("primary: store rejects a body longer than the signed Content-Length", longer < 200 || longer >= 300, True, "status " <> int.to_string(longer)),
    Check("primary: conditional copy refuses a stale ETag", copy, True, ""),
    Check("primary: short-lived signed download works", download, True, ""),
  ]
}

fn journal_checks(primary: storage.Config, journal: storage.Config, stamp: String) -> List(Check) {
  let key = "journal/probes/storage-check-" <> stamp <> ".json"
  let first = storage.put_if_absent(journal, key, <<"{\"probe\":1}":utf8>>, "application/json")
  let second = storage.put_if_absent(journal, key, <<"{\"probe\":2}":utf8>>, "application/json")
  let unchanged = storage.get(journal, key) == Ok(<<"{\"probe\":1}":utf8>>)
  // With a bucket lock, deleting (and overwriting) is refused by the store.
  let delete_refused = case storage.delete(journal, key) {
    Ok(Nil) -> storage.get(journal, key) == Ok(<<"{\"probe\":1}":utf8>>)
    Error(_) -> True
  }
  let separate_credentials = journal.access_key_id != primary.access_key_id
  let separate_bucket =
    !{ journal.endpoint == primary.endpoint && journal.bucket == primary.bucket }
  let primary_cannot_delete_journal = case
    storage.delete(storage.Config(..journal, access_key_id: primary.access_key_id, secret_access_key: primary.secret_access_key), "journal/probes/nonexistent-" <> stamp)
  {
    Error(_) -> True
    Ok(_) -> False
  }
  [
    Check("journal: first write succeeds", first == Ok(storage.Created), True, string.inspect(first)),
    Check("journal: rewrites are refused (write-once)", second == Ok(storage.AlreadyExists) && unchanged, True, string.inspect(second)),
    Check("journal: deletes are refused (bucket lock rule covering journal/)", delete_refused, True, "configure an R2 bucket lock rule with prefix journal/"),
    Check("journal: credentials differ from the primary store", separate_credentials, True, ""),
    Check("journal: bucket differs from the primary bucket", separate_bucket, True, ""),
    Check("journal: primary credentials cannot modify the journal bucket", primary_cannot_delete_journal, False, "scope the primary R2 token to the primary bucket only"),
  ]
}
