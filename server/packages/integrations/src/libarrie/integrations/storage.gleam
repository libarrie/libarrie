//// Private S3-compatible object storage with AWS Signature Version 4
//// (sections 6 and 7).
////
//// Implemented in Gleam on `gleam_crypto` and `gleam_httpc`; no Erlang interop
//// is needed. Uses path-style addressing so local S3-compatible stores work.
////
//// Upload URLs sign `content-length`, `content-type` and
//// `x-amz-checksum-sha256`, so a store that enforces signed headers rejects
//// oversize or mismatched bodies. Completion never trusts the staging object:
//// it copies it to an immutable final key conditioned on the observed ETag,
//// then reads and verifies the final copy.

import gleam/bit_array
import gleam/crypto
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import gleam/uri

pub type Config {
  Config(
    /// Endpoint used by the server, for example `http://localhost:8333`.
    endpoint: String,
    /// Endpoint embedded in URLs handed to clients. Often the same.
    public_endpoint: String,
    region: String,
    bucket: String,
    access_key_id: String,
    secret_access_key: String,
    /// How presigned uploads bind body integrity so the store itself
    /// rejects mismatched bytes: `Sha256Header` (x-amz-checksum-sha256) or
    /// `ContentMd5` for stores such as Cloudflare R2 that verify only
    /// Content-MD5.
    upload_integrity: UploadIntegrity,
  )
}

pub type UploadIntegrity {
  Sha256Header
  ContentMd5
}

pub type StorageError {
  NotFound
  PreconditionFailed
  Unavailable(detail: String)
  Rejected(status: Int, detail: String)
}

pub type PresignedRequest {
  PresignedRequest(
    method: String,
    url: String,
    headers: List(#(String, String)),
    expires_in_seconds: Int,
  )
}

pub type ObjectInfo {
  ObjectInfo(bytes: Int, etag: String)
}

/// A presigned PUT whose signature binds the exact length, content type and
/// a body checksum the store verifies: SHA-256 (base64, in
/// `x-amz-checksum-sha256`) or, in `ContentMd5` mode, the base64 MD5 in
/// `Content-MD5`.
pub fn presign_put(
  config: Config,
  key: String,
  content_length: Int,
  content_type: String,
  checksum_sha256_base64: String,
  md5_base64: option.Option(String),
  expires_in_seconds: Int,
) -> PresignedRequest {
  let integrity = case config.upload_integrity, md5_base64 {
    ContentMd5, Some(md5) -> [#("content-md5", md5)]
    ContentMd5, None -> []
    Sha256Header, _ -> [#("x-amz-checksum-sha256", checksum_sha256_base64)]
  }
  let headers = [
    #("content-length", int.to_string(content_length)),
    #("content-type", content_type),
    ..integrity
  ]
  let url = presign(config, "PUT", key, headers, [], expires_in_seconds)
  PresignedRequest(method: "PUT", url:, headers:, expires_in_seconds:)
}

/// A presigned GET for direct, short-lived downloads.
pub fn presign_get(
  config: Config,
  key: String,
  expires_in_seconds: Int,
  response_cache_control: String,
) -> PresignedRequest {
  presign_download(config, key, expires_in_seconds, response_cache_control, None)
}

/// A presigned GET that also sets the response Content-Disposition (for
/// export archives). Range requests work against the same URL.
pub fn presign_download(
  config: Config,
  key: String,
  expires_in_seconds: Int,
  response_cache_control: String,
  attachment_name: option.Option(String),
) -> PresignedRequest {
  let params = case attachment_name {
    Some(name) -> [
      #("response-cache-control", response_cache_control),
      #("response-content-disposition", "attachment; filename=\"" <> name <> "\""),
    ]
    None -> [#("response-cache-control", response_cache_control)]
  }
  let url = presign(config, "GET", key, [], params, expires_in_seconds)
  PresignedRequest(method: "GET", url:, headers: [], expires_in_seconds:)
}

// Multipart uploads ------------------------------------------------------------

pub fn create_multipart(
  config: Config,
  key: String,
  content_type: String,
) -> Result(String, StorageError) {
  use resp <- result.try(
    send_query(config, http.Post, key, [#("uploads", "")], [#("content-type", content_type)], <<>>),
  )
  case resp.status {
    200 ->
      bit_array.to_string(resp.body)
      |> result.try(fn(body) { xml_value(body, "UploadId") })
      |> result.replace_error(Rejected(200, "create multipart: no UploadId"))
    status -> Error(Rejected(status, "create multipart"))
  }
}

/// Upload one part (every part except the last must be at least 5 MiB).
/// Returns the part's ETag.
pub fn upload_part(
  config: Config,
  key: String,
  upload_id: String,
  part_number: Int,
  body: BitArray,
) -> Result(String, StorageError) {
  use resp <- result.try(send_query(
    config,
    http.Put,
    key,
    [#("partNumber", int.to_string(part_number)), #("uploadId", upload_id)],
    [],
    body,
  ))
  case resp.status {
    200 -> response.get_header(resp, "etag") |> result.replace_error(Rejected(200, "part etag"))
    status -> Error(Rejected(status, "upload part"))
  }
}

pub fn complete_multipart(
  config: Config,
  key: String,
  upload_id: String,
  parts: List(#(Int, String)),
) -> Result(Nil, StorageError) {
  let body =
    "<CompleteMultipartUpload>"
    <> {
      parts
      |> list.map(fn(p) {
        "<Part><PartNumber>"
        <> int.to_string(p.0)
        <> "</PartNumber><ETag>"
        <> p.1
        <> "</ETag></Part>"
      })
      |> string.concat
    }
    <> "</CompleteMultipartUpload>"
  use resp <- result.try(send_query(
    config,
    http.Post,
    key,
    [#("uploadId", upload_id)],
    [#("content-type", "application/xml")],
    bit_array.from_string(body),
  ))
  case resp.status, bit_array.to_string(resp.body) {
    200, Ok(text) ->
      case string.contains(text, "<Error>") {
        True -> Error(Rejected(200, "complete multipart"))
        False -> Ok(Nil)
      }
    200, _ -> Ok(Nil)
    status, _ -> Error(Rejected(status, "complete multipart"))
  }
}

pub fn abort_multipart(
  config: Config,
  key: String,
  upload_id: String,
) -> Result(Nil, StorageError) {
  use resp <- result.try(
    send_query(config, http.Delete, key, [#("uploadId", upload_id)], [], <<>>),
  )
  case resp.status {
    200 | 204 | 404 -> Ok(Nil)
    status -> Error(Rejected(status, "abort multipart"))
  }
}

fn xml_value(body: String, tag: String) -> Result(String, Nil) {
  use #(_, after) <- result.try(string.split_once(body, "<" <> tag <> ">"))
  use #(value, _) <- result.try(string.split_once(after, "</" <> tag <> ">"))
  Ok(value)
}

pub fn head(config: Config, key: String) -> Result(ObjectInfo, StorageError) {
  use resp <- result.try(send(config, http.Head, key, [], <<>>))
  case resp.status {
    200 -> {
      let bytes =
        response.get_header(resp, "content-length")
        |> result.try(int.parse)
        |> result.unwrap(-1)
      let etag = response.get_header(resp, "etag") |> result.unwrap("")
      Ok(ObjectInfo(bytes:, etag:))
    }
    404 -> Error(NotFound)
    status -> Error(Rejected(status, "head"))
  }
}

pub fn get(config: Config, key: String) -> Result(BitArray, StorageError) {
  use resp <- result.try(send(config, http.Get, key, [], <<>>))
  case resp.status {
    200 -> Ok(resp.body)
    404 -> Error(NotFound)
    status -> Error(Rejected(status, "get"))
  }
}

/// Server-side PUT (used for derived artifacts and tests).
pub fn put(
  config: Config,
  key: String,
  body: BitArray,
  content_type: String,
) -> Result(Nil, StorageError) {
  use resp <- result.try(
    send(config, http.Put, key, [#("content-type", content_type)], body),
  )
  case resp.status {
    200 | 201 | 204 -> Ok(Nil)
    status -> Error(Rejected(status, "put"))
  }
}

pub type PutOutcome {
  Created
  AlreadyExists
}

/// Write-once PUT (`If-None-Match: *`): never overwrites an existing key.
pub fn put_if_absent(
  config: Config,
  key: String,
  body: BitArray,
  content_type: String,
) -> Result(PutOutcome, StorageError) {
  use resp <- result.try(
    send(config, http.Put, key, [#("content-type", content_type), #("if-none-match", "*")], body),
  )
  case resp.status {
    200 | 201 | 204 -> Ok(Created)
    412 | 409 -> Ok(AlreadyExists)
    status -> Error(Rejected(status, "put if absent"))
  }
}

pub type Listing {
  Listing(keys: List(String), next_token: option.Option(String))
}

/// One page of ListObjectsV2 under `prefix` (keys in lexicographic order).
pub fn list_objects(
  config: Config,
  prefix: String,
  continuation: option.Option(String),
) -> Result(Listing, StorageError) {
  let query = [
    #("list-type", "2"),
    #("prefix", prefix),
    #("max-keys", "1000"),
    ..case continuation {
      Some(token) -> [#("continuation-token", token)]
      None -> []
    }
  ]
  use resp <- result.try(send_path(config, http.Get, "/" <> config.bucket, query, [], <<>>))
  case resp.status, bit_array.to_string(resp.body) {
    200, Ok(body) -> {
      let keys =
        string.split(body, "<Key>")
        |> list.drop(1)
        |> list.filter_map(fn(part) {
          string.split_once(part, "</Key>") |> result.map(fn(p) { xml_unescape(p.0) })
        })
      let next = case string.contains(body, "<IsTruncated>true</IsTruncated>") {
        True -> xml_value(body, "NextContinuationToken") |> option.from_result
        False -> None
      }
      Ok(Listing(keys:, next_token: next))
    }
    200, Error(_) -> Error(Rejected(200, "list: invalid body"))
    status, _ -> Error(Rejected(status, "list"))
  }
}

fn xml_unescape(text: String) -> String {
  text
  |> string.replace("&lt;", "<")
  |> string.replace("&gt;", ">")
  |> string.replace("&quot;", "\"")
  |> string.replace("&apos;", "'")
  |> string.replace("&amp;", "&")
}

/// Copy `source_key` to `destination_key` only if the source still has
/// `etag`. A concurrent overwrite of the staging object fails with
/// `PreconditionFailed` instead of freezing different bytes.
pub fn copy_if_match(
  config: Config,
  source_key: String,
  destination_key: String,
  etag: String,
) -> Result(Nil, StorageError) {
  let source = "/" <> config.bucket <> "/" <> encode_path(source_key)
  use resp <- result.try(
    send(
      config,
      http.Put,
      destination_key,
      [
        #("x-amz-copy-source", source),
        #("x-amz-copy-source-if-match", etag),
      ],
      <<>>,
    ),
  )
  case resp.status {
    200 ->
      // S3 can report copy errors with a 200 status and an <Error> body.
      case bit_array.to_string(resp.body) {
        Ok(body) ->
          case string.contains(body, "<Error>") {
            True ->
              case string.contains(body, "PreconditionFailed") {
                True -> Error(PreconditionFailed)
                False -> Error(Rejected(200, "copy"))
              }
            False -> Ok(Nil)
          }
        Error(_) -> Ok(Nil)
      }
    412 -> Error(PreconditionFailed)
    404 -> Error(NotFound)
    status -> Error(Rejected(status, "copy"))
  }
}

pub fn delete(config: Config, key: String) -> Result(Nil, StorageError) {
  use resp <- result.try(send(config, http.Delete, key, [], <<>>))
  case resp.status {
    200 | 204 | 404 -> Ok(Nil)
    status -> Error(Rejected(status, "delete"))
  }
}

/// Create the bucket if it does not exist (development stacks only).
pub fn ensure_bucket(config: Config) -> Result(Nil, StorageError) {
  use resp <- result.try(send_bucket(config, http.Put))
  case resp.status {
    200 | 204 | 409 -> Ok(Nil)
    status -> Error(Rejected(status, "create bucket"))
  }
}

// Signing ------------------------------------------------------------------

fn send(
  config: Config,
  method: http.Method,
  key: String,
  extra_headers: List(#(String, String)),
  body: BitArray,
) -> Result(Response(BitArray), StorageError) {
  send_query(config, method, key, [], extra_headers, body)
}

fn send_query(
  config: Config,
  method: http.Method,
  key: String,
  query: List(#(String, String)),
  extra_headers: List(#(String, String)),
  body: BitArray,
) -> Result(Response(BitArray), StorageError) {
  let path = "/" <> config.bucket <> "/" <> encode_path(key)
  send_path(config, method, path, query, extra_headers, body)
}

fn send_bucket(
  config: Config,
  method: http.Method,
) -> Result(Response(BitArray), StorageError) {
  send_path(config, method, "/" <> config.bucket, [], [], <<>>)
}

fn send_path(
  config: Config,
  method: http.Method,
  path: String,
  query: List(#(String, String)),
  extra_headers: List(#(String, String)),
  body: BitArray,
) -> Result(Response(BitArray), StorageError) {
  let canonical_query =
    query
    |> list.map(fn(q) { #(encode(q.0), encode(q.1)) })
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    |> list.map(fn(q) { q.0 <> "=" <> q.1 })
    |> string.join("&")
  use endpoint <- result.try(
    uri.parse(config.endpoint) |> result.replace_error(Unavailable("endpoint")),
  )
  let host = host_header(endpoint)
  let #(amz_date, date) = now_stamps()
  let payload_hash = hex(crypto.hash(crypto.Sha256, body))
  let headers =
    [
      #("host", host),
      #("x-amz-content-sha256", payload_hash),
      #("x-amz-date", amz_date),
      ..extra_headers
    ]
    |> list.map(fn(h) { #(string.lowercase(h.0), string.trim(h.1)) })
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  let signed_headers = headers |> list.map(fn(h) { h.0 }) |> string.join(";")
  let canonical =
    string.join(
      [
        http.method_to_string(method) |> string.uppercase,
        path,
        canonical_query,
        canonical_headers(headers),
        signed_headers,
        payload_hash,
      ],
      "\n",
    )
  let scope = scope(config, date)
  let signature = sign(config, date, string_to_sign(amz_date, scope, canonical))
  let authorization =
    "AWS4-HMAC-SHA256 Credential="
    <> config.access_key_id
    <> "/"
    <> scope
    <> ", SignedHeaders="
    <> signed_headers
    <> ", Signature="
    <> signature
  let scheme = case endpoint.scheme {
    Some("https") -> http.Https
    _ -> http.Http
  }
  let req =
    request.new()
    |> request.set_method(method)
    |> request.set_scheme(scheme)
    |> request.set_host(option.unwrap(endpoint.host, "localhost"))
    |> request.set_path(path)
    |> request.set_body(body)
  let req = case canonical_query {
    "" -> req
    q -> request.Request(..req, query: Some(q))
  }
  let req = case endpoint.port {
    Some(port) -> request.set_port(req, port)
    None -> req
  }
  let req =
    headers
    |> list.filter(fn(h) { h.0 != "host" })
    |> list.fold(req, fn(r, h) { request.set_header(r, h.0, h.1) })
    |> request.set_header("authorization", authorization)
  httpc.configure()
  |> httpc.timeout(60_000)
  |> httpc.dispatch_bits(req)
  |> result.map_error(fn(e) { Unavailable(string.inspect(e)) })
}

fn presign(
  config: Config,
  method: String,
  key: String,
  headers: List(#(String, String)),
  extra_query: List(#(String, String)),
  expires_in_seconds: Int,
) -> String {
  let endpoint =
    uri.parse(config.public_endpoint)
    |> result.unwrap(uri.empty)
  let host = host_header(endpoint)
  let #(amz_date, date) = now_stamps()
  let path = "/" <> config.bucket <> "/" <> encode_path(key)
  let headers =
    [#("host", host), ..headers]
    |> list.map(fn(h) { #(string.lowercase(h.0), string.trim(h.1)) })
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  let signed_headers = headers |> list.map(fn(h) { h.0 }) |> string.join(";")
  let scope = scope(config, date)
  let query =
    [
      #("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
      #("X-Amz-Credential", config.access_key_id <> "/" <> scope),
      #("X-Amz-Date", amz_date),
      #("X-Amz-Expires", int.to_string(expires_in_seconds)),
      #("X-Amz-SignedHeaders", signed_headers),
      ..extra_query
    ]
    |> list.map(fn(q) { #(encode(q.0), encode(q.1)) })
    |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  let canonical_query =
    query |> list.map(fn(q) { q.0 <> "=" <> q.1 }) |> string.join("&")
  let canonical =
    string.join(
      [
        method,
        path,
        canonical_query,
        canonical_headers(headers),
        signed_headers,
        "UNSIGNED-PAYLOAD",
      ],
      "\n",
    )
  let signature = sign(config, date, string_to_sign(amz_date, scope, canonical))
  string.trim_end(config.public_endpoint)
  |> trim_trailing_slash
  <> path
  <> "?"
  <> canonical_query
  <> "&X-Amz-Signature="
  <> signature
}

fn trim_trailing_slash(s: String) -> String {
  case string.ends_with(s, "/") {
    True -> string.drop_end(s, 1)
    False -> s
  }
}

fn host_header(endpoint: uri.Uri) -> String {
  let host = option.unwrap(endpoint.host, "localhost")
  case endpoint.port, endpoint.scheme {
    None, _ -> host
    Some(80), Some("http") -> host
    Some(443), Some("https") -> host
    Some(port), _ -> host <> ":" <> int.to_string(port)
  }
}

fn canonical_headers(headers: List(#(String, String))) -> String {
  headers
  |> list.map(fn(h) { h.0 <> ":" <> h.1 <> "\n" })
  |> string.concat
}

fn scope(config: Config, date: String) -> String {
  date <> "/" <> config.region <> "/s3/aws4_request"
}

fn string_to_sign(amz_date: String, scope: String, canonical: String) -> String {
  "AWS4-HMAC-SHA256\n"
  <> amz_date
  <> "\n"
  <> scope
  <> "\n"
  <> hex(crypto.hash(crypto.Sha256, bit_array.from_string(canonical)))
}

fn sign(config: Config, date: String, string_to_sign: String) -> String {
  let mac = fn(key: BitArray, data: String) {
    crypto.hmac(bit_array.from_string(data), crypto.Sha256, key)
  }
  let k_date = mac(bit_array.from_string("AWS4" <> config.secret_access_key), date)
  let k_region = mac(k_date, config.region)
  let k_service = mac(k_region, "s3")
  let k_signing = mac(k_service, "aws4_request")
  hex(mac(k_signing, string_to_sign))
}

fn now_stamps() -> #(String, String) {
  let #(date, time) =
    timestamp.system_time() |> timestamp.to_calendar(calendar.utc_offset)
  let pad = fn(n: Int, width: Int) {
    string.pad_start(int.to_string(n), width, "0")
  }
  let day =
    pad(date.year, 4)
    <> pad(calendar.month_to_int(date.month), 2)
    <> pad(date.day, 2)
  let amz = day <> "T" <> pad(time.hours, 2) <> pad(time.minutes, 2) <> pad(time.seconds, 2) <> "Z"
  #(amz, day)
}

pub fn hex(bits: BitArray) -> String {
  bit_array.base16_encode(bits) |> string.lowercase
}

/// RFC 3986 encoding as required by SigV4 (unreserved characters only).
pub fn encode(value: String) -> String {
  value
  |> bit_array.from_string
  |> encode_bytes("", True)
}

/// Encode each path segment, preserving `/`.
pub fn encode_path(value: String) -> String {
  value
  |> bit_array.from_string
  |> encode_bytes("", False)
}

fn encode_bytes(bytes: BitArray, acc: String, encode_slash: Bool) -> String {
  case bytes {
    <<>> -> acc
    <<b, rest:bits>> -> {
      let piece = case b {
        _ if b >= 0x41 && b <= 0x5A -> char(b)
        _ if b >= 0x61 && b <= 0x7A -> char(b)
        _ if b >= 0x30 && b <= 0x39 -> char(b)
        0x2D | 0x2E | 0x5F | 0x7E -> char(b)
        0x2F if !encode_slash -> "/"
        _ -> "%" <> string.pad_start(string.uppercase(int.to_base16(b)), 2, "0")
      }
      encode_bytes(rest, acc <> piece, encode_slash)
    }
    _ -> acc
  }
}

fn char(b: Int) -> String {
  let assert Ok(s) = bit_array.to_string(<<b>>)
  s
}
