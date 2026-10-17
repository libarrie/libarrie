//// Upload protocol, operation recovery and deferred processing (section 7).

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import libarrie/database.{type Connection}
import libarrie/domain/accounts
import libarrie/domain/context.{type Context}
import libarrie/domain/error.{type AppError, db}
import libarrie/domain/expiry
import libarrie/domain/operations.{type Operation}
import libarrie/domain/pages
import libarrie/domain/quota
import libarrie/domain/ratelimit
import libarrie/integrations/decoder
import libarrie/integrations/image
import libarrie/integrations/storage
import libarrie/jobs
import youid/uuid

pub type Target {
  NewPage(notebook_id: String, page_number: Int)
  Replacement(page_id: String)
}

pub type CreateRequest {
  CreateRequest(
    operation_id: String,
    target: Target,
    bytes: Int,
    content_type: String,
    checksum_sha256: String,
    /// Hex MD5, required when the primary store verifies only Content-MD5.
    checksum_md5: Option(String),
    processing_mode: String,
    client_label: String,
    background: Bool,
    parent_operation_id: Option(String),
  )
}

pub fn create_decoder() -> decode.Decoder(CreateRequest) {
  use operation_id <- decode.field("operation_id", decode.string)
  use notebook_id <- decode.optional_field("notebook_id", None, decode.optional(decode.string))
  use page_number <- decode.optional_field("page_number", None, decode.optional(decode.int))
  use page_id <- decode.optional_field("page_id", None, decode.optional(decode.string))
  use bytes <- decode.field("bytes", decode.int)
  use content_type <- decode.field("content_type", decode.string)
  use checksum <- decode.field("checksum_sha256", decode.string)
  use md5 <- decode.optional_field("checksum_md5", None, decode.optional(decode.string))
  use mode <- decode.optional_field("processing_mode", "immediate", decode.string)
  use label <- decode.optional_field("client_label", "", decode.string)
  use transfer <- decode.optional_field("transfer", "foreground", decode.string)
  use parent <- decode.optional_field(
    "retry_of_operation_id",
    None,
    decode.optional(decode.string),
  )
  let target = case notebook_id, page_number, page_id {
    Some(n), Some(p), None -> Ok(NewPage(string.lowercase(n), p))
    None, None, Some(p) -> Ok(Replacement(string.lowercase(p)))
    _, _, _ -> Error(Nil)
  }
  case target {
    Ok(target) ->
      decode.success(CreateRequest(
        operation_id: string.lowercase(operation_id),
        target:,
        bytes:,
        content_type:,
        checksum_sha256: string.lowercase(checksum),
        checksum_md5: option.map(md5, string.lowercase),
        processing_mode: mode,
        client_label: string.slice(label, 0, 120),
        background: transfer == "background",
        parent_operation_id: option.map(parent, string.lowercase),
      ))
    Error(_) ->
      decode.failure(
        CreateRequest("", Replacement(""), 0, "", "", None, "", "", False, None),
        "either notebook_id and page_number, or page_id",
      )
  }
}

/// The canonical request hash excludes transport-only fields (transfer
/// lifetime), so a background retry of the same operation still matches.
fn create_hash(request: CreateRequest, if_match: Option(Int)) -> String {
  let target = case request.target {
    NewPage(notebook_id, page_number) -> [
      #("notebook_id", json.string(notebook_id)),
      #("page_number", json.int(page_number)),
    ]
    Replacement(page_id) -> [
      #("page_id", json.string(page_id)),
      #("if_match", context.optional_int(if_match)),
    ]
  }
  context.request_hash(
    list.flatten([
      [#("operation_id", json.string(request.operation_id))],
      target,
      [
        #("bytes", json.int(request.bytes)),
        #("content_type", json.string(request.content_type)),
        #("checksum_sha256", json.string(request.checksum_sha256)),
        #("checksum_md5", context.optional_string(request.checksum_md5)),
        #("processing_mode", json.string(request.processing_mode)),
        #("client_label", json.string(request.client_label)),
        #("retry_of", context.optional_string(request.parent_operation_id)),
      ],
    ]),
  )
}

fn validate(ctx: Context, request: CreateRequest) -> Result(Nil, AppError) {
  use _ <- result.try(context.require_uuid(request.operation_id, fn(_) { Ok(Nil) })
    |> result.replace_error(error.bad_request("operation_id must be a UUID")))
  use <- error.guard(
    request.content_type == "image/jpeg" || request.content_type == "image/png",
    error.new(422, "unsupported_image", "Only JPEG and PNG uploads are accepted."),
  )
  use <- error.guard(
    request.bytes > 0 && request.bytes <= ctx.config.image_limits.max_bytes,
    error.new(422, "unsupported_image", "The image exceeds the upload size limit.")
      |> error.with_details([
        #("max_bytes", json.int(ctx.config.image_limits.max_bytes)),
      ]),
  )
  use <- error.guard(
    string.length(request.checksum_sha256) == 64
      && list.all(string.to_graphemes(request.checksum_sha256), fn(c) {
      string.contains("0123456789abcdef", c)
    }),
    error.bad_request("checksum_sha256 must be 64 hex characters"),
  )
  use <- error.guard(
    case request.checksum_md5, ctx.config.storage.upload_integrity {
      Some(md5), _ ->
        string.length(md5) == 32
        && list.all(string.to_graphemes(md5), fn(c) { string.contains("0123456789abcdef", c) })
      None, storage.ContentMd5 -> False
      None, storage.Sha256Header -> True
    },
    error.unprocessable(
      "checksum_md5 (32 hex characters) is required: this deployment's object store verifies uploads with Content-MD5",
    ),
  )
  use <- error.guard(
    request.processing_mode == "immediate" || request.processing_mode == "deferred",
    error.bad_request("processing_mode must be immediate or deferred"),
  )
  case request.target, request.processing_mode {
    Replacement(_), "deferred" ->
      Error(error.new(
        422,
        "deferred_replacement_unsupported",
        "Replacement scans cannot be deferred; keep them queued until processing is available.",
      ))
    NewPage(notebook_id, page_number), _ -> {
      use _ <- result.try(context.require_uuid(notebook_id, fn(_) { Ok(Nil) }))
      use <- error.guard(
        page_number > 0,
        error.unprocessable("page_number must be a positive integer"),
      )
      Ok(Nil)
    }
    Replacement(page_id), _ -> context.require_uuid(page_id, fn(_) { Ok(Nil) })
  }
}

// Session view ------------------------------------------------------------------

pub type Session {
  Session(
    id: String,
    operation_id: String,
    page_id: String,
    revision_id: String,
    staging_key: String,
    final_key: Option(String),
    expected_bytes: Int,
    checksum: String,
    content_type: String,
    status: String,
    expires_at: String,
    expired: Bool,
    checksum_md5: Option(String),
  )
}

const session_columns = "id::text, operation_id::text, page_id::text, revision_id::text,
  staging_key, final_key, expected_bytes, checksum, content_type, status,
  rfc3339(expires_at), expires_at <= now(), checksum_md5"

fn session_decoder() -> decode.Decoder(Session) {
  use id <- decode.field(0, decode.string)
  use operation_id <- decode.field(1, decode.string)
  use page_id <- decode.field(2, decode.string)
  use revision_id <- decode.field(3, decode.string)
  use staging_key <- decode.field(4, decode.string)
  use final_key <- decode.field(5, decode.optional(decode.string))
  use expected_bytes <- decode.field(6, decode.int)
  use checksum <- decode.field(7, decode.string)
  use content_type <- decode.field(8, decode.string)
  use status <- decode.field(9, decode.string)
  use expires_at <- decode.field(10, decode.string)
  use expired <- decode.field(11, decode.bool)
  use checksum_md5 <- decode.field(12, decode.optional(decode.string))
  decode.success(Session(
    id:,
    operation_id:,
    page_id:,
    revision_id:,
    staging_key:,
    final_key:,
    expected_bytes:,
    checksum:,
    content_type:,
    status:,
    expires_at:,
    expired:,
    checksum_md5:,
  ))
}

fn load_session(
  conn: Connection,
  account_id: String,
  session_id: String,
  for_update: Bool,
) -> Result(Session, AppError) {
  let lock = case for_update {
    True -> " for update"
    False -> ""
  }
  use session <- error.found(database.query_one(
    conn,
    "select " <> session_columns <> " from upload_sessions
     where account_id = $1::uuid and id = $2::uuid" <> lock,
    [database.text(account_id), database.text(session_id)],
    session_decoder(),
  ))
  Ok(session)
}

fn session_for_operation(
  conn: Connection,
  account_id: String,
  operation_id: String,
) -> Result(Option(Session), AppError) {
  use session <- db(database.query_one(
    conn,
    "select " <> session_columns <> " from upload_sessions
     where account_id = $1::uuid and operation_id = $2::uuid",
    [database.text(account_id), database.text(operation_id)],
    session_decoder(),
  ))
  Ok(session)
}

fn checksum_base64(hex: String) -> String {
  case bit_array.base16_decode(string.uppercase(hex)) {
    Ok(bits) -> bit_array.base64_encode(bits, True)
    Error(_) -> ""
  }
}

/// Issue a staging URL, never beyond the reservation expiry.
fn upload_url(
  ctx: Context,
  session: Session,
  seconds_left: Int,
  background: Bool,
) -> json.Json {
  let lifetime = case background {
    True -> ctx.config.background_upload_url_seconds
    False -> ctx.config.foreground_upload_url_seconds
  }
  let expires_in = int.max(1, int.min(lifetime, seconds_left))
  let signed =
    storage.presign_put(
      ctx.config.storage,
      session.staging_key,
      session.expected_bytes,
      session.content_type,
      checksum_base64(session.checksum),
      option.map(session.checksum_md5, checksum_base64),
      expires_in,
    )
  json.object([
    #("method", json.string(signed.method)),
    #("url", json.string(signed.url)),
    #("headers", json.object(
      signed.headers
      |> list.filter(fn(h) { h.0 != "content-length" })
      |> list.map(fn(h) { #(h.0, json.string(h.1)) }),
    )),
    #("expires_in_seconds", json.int(expires_in)),
  ])
}

fn seconds_until(conn: Connection, session_id: String) -> Result(Int, AppError) {
  use seconds <- error.found(database.query_one(
    conn,
    "select greatest(0, floor(extract(epoch from expires_at - now())))::int
     from upload_sessions where id = $1::uuid",
    [database.text(session_id)],
    decode.at([0], decode.int),
  ))
  Ok(seconds)
}

fn session_json(
  ctx: Context,
  conn: Connection,
  account_id: String,
  session: Session,
  background: Bool,
) -> Result(json.Json, AppError) {
  use op <- result.try(operations.require(conn, account_id, session.operation_id, False))
  use upload <- result.try(case op.status == "awaiting_upload" && !session.expired {
    True -> {
      use left <- result.try(seconds_until(conn, session.id))
      Ok(upload_url(ctx, session, left, background))
    }
    False -> Ok(json.null())
  })
  Ok(json.object([
    #("upload_session_id", json.string(session.id)),
    #("status", json.string(session.status)),
    #("expires_at", json.string(session.expires_at)),
    #("upload", upload),
    #("constraints", json.object([
      #("bytes", json.int(session.expected_bytes)),
      #("content_type", json.string(session.content_type)),
      #("checksum_sha256", json.string(session.checksum)),
    ])),
    #("operation", operations.to_json(op, [])),
  ]))
}

// Admission ------------------------------------------------------------------------

/// `POST /v1/upload-sessions`. The client operation UUID is the durable
/// deduplication key: replaying the same body returns the existing session
/// without new reservations; a changed body returns 409.
pub fn create(
  ctx: Context,
  account_id: String,
  request: CreateRequest,
  if_match: Option(Int),
) -> Result(#(Int, json.Json), AppError) {
  use _ <- result.try(validate(ctx, request))
  let hash = create_hash(request, if_match)
  context.transaction(ctx, fn(tx) {
    use status <- result.try(accounts.lock(tx, account_id))
    use existing <- result.try(operations.load(tx, account_id, request.operation_id, True))
    case existing {
      Some(op) -> replay(ctx, tx, account_id, op, hash, request.background)
      None -> {
        use <- error.guard(status == "active", error.account_closing())
        admit(ctx, tx, account_id, request, if_match, hash)
      }
    }
  })
}

fn replay(
  ctx: Context,
  tx: Connection,
  account_id: String,
  op: Operation,
  hash: String,
  background: Bool,
) -> Result(#(Int, json.Json), AppError) {
  use <- error.guard(op.request_hash == hash, error.idempotency_conflict())
  use session <- result.try(session_for_operation(tx, account_id, op.id))
  case session {
    Some(session) -> {
      use body <- result.try(session_json(ctx, tx, account_id, session, background))
      Ok(#(200, body))
    }
    None -> Ok(#(200, json.object([#("operation", operations.to_json(op, []))])))
  }
}

fn admit(
  ctx: Context,
  tx: Connection,
  account_id: String,
  request: CreateRequest,
  if_match: Option(Int),
  hash: String,
) -> Result(#(Int, json.Json), AppError) {
  use _ <- result.try(expiry.require_clean(tx, account_id, ctx.config.lazy_expiry_batch))
  use usage <- result.try(quota.lock_usage(tx, account_id))
  use ent <- result.try(quota.entitlement(tx, ctx.config, account_id))
  use charge_root <- result.try(retry_root(tx, account_id, request))
  let session_id = uuid.v7_string()
  let revision_id = uuid.v7_string()
  let staging_key = "staging/" <> account_id <> "/" <> session_id
  let reservation_seconds = ctx.config.reservation_seconds
  case request.target {
    NewPage(notebook_id, page_number) -> {
      use locked <- result.try(pages.lock_notebooks(tx, account_id, [notebook_id]))
      use <- error.guard(list.key_find(locked, notebook_id) == Ok(True), error.not_found())
      use _ <- result.try(quota.require_page_capacity(usage, ent, 1))
      use holder <- result.try(pages.number_holder(tx, notebook_id, page_number, "00000000-0000-0000-0000-000000000000"))
      use <- error.guard(
        holder == None,
        error.page_number_conflict([#("page_number", json.int(page_number))]),
      )
      use funding <- result.try(case request.processing_mode {
        "deferred" -> Ok(None)
        _ -> quota.reserve_processing(tx, ent, account_id) |> result.map(Some)
      })
      let page_id = uuid.v7_string()
      use _ <- db(database.execute(
        tx,
        "insert into pages (id, account_id, notebook_id, page_number, visibility)
         values ($1::uuid, $2::uuid, $3::uuid, $4, 'placeholder')",
        [
          database.text(page_id),
          database.text(account_id),
          database.text(notebook_id),
          database.int(page_number),
        ],
      ))
      use _ <- result.try(operations.bump_numbering(tx, account_id, notebook_id))
      use _ <- result.try(insert_revision(tx, account_id, page_id, revision_id))
      use _ <- result.try(operations.insert(
        tx,
        account_id,
        request.operation_id,
        "upload",
        hash,
        "awaiting_upload",
        request.client_label,
        Some(notebook_id),
        Some(page_id),
        Some(revision_id),
        request.processing_mode,
        request.parent_operation_id,
        option.unwrap(charge_root, request.operation_id),
      ))
      use _ <- result.try(quota.insert_reservation(
        tx,
        account_id,
        request.operation_id,
        True,
        funding,
        Some(reservation_seconds),
      ))
      use _ <- result.try(quota.adjust_usage(tx, account_id, 0, 1, 0))
      finish_admission(ctx, tx, account_id, request, session_id, page_id, revision_id, staging_key)
    }
    Replacement(page_id) -> {
      use expected <- result.try(option.to_result(if_match, error.precondition_required()))
      use notebook_id <- error.found(database.query_one(
        tx,
        "select notebook_id::text from pages where account_id = $1::uuid and id = $2::uuid",
        [database.text(account_id), database.text(page_id)],
        decode.at([0], decode.string),
      ))
      use locked <- result.try(pages.lock_notebooks(tx, account_id, [notebook_id]))
      use <- error.guard(list.key_find(locked, notebook_id) == Ok(True), error.not_found())
      use _ <- result.try(pages.lock_pages(tx, account_id, [page_id]))
      use page <- result.try(pages.get(tx, account_id, page_id))
      use <- error.guard(page.content_version == expected, error.version_conflict())
      use live <- result.try(operations.live_for_page(tx, account_id, page_id))
      use _ <- result.try(case live {
        Some(op) -> Error(operations.conflict(op))
        None -> Ok(Nil)
      })
      use funding <- result.try(quota.reserve_processing(tx, ent, account_id)
        |> result.map_error(fn(e) {
          // Replacements stay queued on the device; no deferral offered.
          error.AppError(..e, details: [])
        }))
      use _ <- result.try(insert_revision(tx, account_id, page_id, revision_id))
      use _ <- result.try(operations.insert(
        tx,
        account_id,
        request.operation_id,
        "replacement",
        hash,
        "awaiting_upload",
        request.client_label,
        Some(notebook_id),
        Some(page_id),
        Some(revision_id),
        "immediate",
        request.parent_operation_id,
        option.unwrap(charge_root, request.operation_id),
      ))
      use _ <- result.try(quota.insert_reservation(
        tx,
        account_id,
        request.operation_id,
        False,
        Some(funding),
        Some(reservation_seconds),
      ))
      finish_admission(ctx, tx, account_id, request, session_id, page_id, revision_id, staging_key)
    }
  }
}

/// An explicit retry references a terminal operation. It never revives the
/// old operation; it only links the charge root for reporting.
fn retry_root(
  tx: Connection,
  account_id: String,
  request: CreateRequest,
) -> Result(Option(String), AppError) {
  case request.parent_operation_id {
    None -> Ok(None)
    Some(parent_id) -> {
      use parent <- result.try(operations.load(tx, account_id, parent_id, False))
      case parent {
        Some(op) if op.status != "awaiting_upload" -> Ok(Some(request.operation_id))
        Some(_) -> Error(error.new(409, "operation_conflict", "The referenced operation is still pending."))
        None -> Error(error.not_found())
      }
    }
  }
}

fn insert_revision(
  tx: Connection,
  account_id: String,
  page_id: String,
  revision_id: String,
) -> Result(Nil, AppError) {
  use _ <- db(database.execute(
    tx,
    "insert into page_revisions (id, account_id, page_id, source_generation, status)
     values ($1::uuid, $2::uuid, $3::uuid,
       (select count(*) + 1 from page_revisions where page_id = $3::uuid),
       'awaiting_upload')",
    [database.text(revision_id), database.text(account_id), database.text(page_id)],
  ))
  Ok(Nil)
}

fn finish_admission(
  ctx: Context,
  tx: Connection,
  account_id: String,
  request: CreateRequest,
  session_id: String,
  page_id: String,
  revision_id: String,
  staging_key: String,
) -> Result(#(Int, json.Json), AppError) {
  use _ <- db(database.execute(
    tx,
    "insert into upload_sessions (id, account_id, operation_id, page_id, revision_id,
       staging_key, expected_bytes, checksum, content_type, status, expires_at,
       checksum_md5)
     values ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6, $7, $8, $9,
       'awaiting_upload', now() + make_interval(secs => $10), $11)",
    [
      database.text(session_id),
      database.text(account_id),
      database.text(request.operation_id),
      database.text(page_id),
      database.text(revision_id),
      database.text(staging_key),
      database.int(request.bytes),
      database.text(request.checksum_sha256),
      database.text(request.content_type),
      database.int(ctx.config.reservation_seconds),
      database.nullable_text(request.checksum_md5),
    ],
  ))
  use session <- result.try(load_session(tx, account_id, session_id, False))
  use body <- result.try(session_json(ctx, tx, account_id, session, request.background))
  Ok(#(201, body))
}

// Refresh and status -----------------------------------------------------------------

pub fn get(
  ctx: Context,
  account_id: String,
  session_id: String,
) -> Result(json.Json, AppError) {
  use session <- result.try(load_session(ctx.db, account_id, session_id, False))
  session_json(ctx, ctx.db, account_id, session, False)
}

/// Renew the upload URL while the reservation is valid; keeps the same
/// operation and reservation.
pub fn refresh(
  ctx: Context,
  account_id: String,
  session_id: String,
  background: Bool,
) -> Result(json.Json, AppError) {
  use session <- result.try(load_session(ctx.db, account_id, session_id, False))
  use op <- result.try(operations.require(ctx.db, account_id, session.operation_id, False))
  use <- error.guard(
    op.status == "awaiting_upload" && !session.expired,
    expired_or_terminal(op, session),
  )
  session_json(ctx, ctx.db, account_id, session, background)
}

fn expired_or_terminal(op: Operation, session: Session) -> AppError {
  case session.expired || op.status == "expired" {
    True ->
      error.new(409, "upload_expired", "The upload reservation expired.")
      |> error.with_details([#("operation_id", json.string(op.id))])
    False ->
      error.new(409, "operation_terminal", "The operation is no longer accepting uploads.")
      |> error.with_details([
        #("operation_id", json.string(op.id)),
        #("status", json.string(op.status)),
      ])
  }
}

// Completion -----------------------------------------------------------------------

/// `POST /v1/upload-sessions/{id}/complete`, idempotent.
pub fn complete(
  ctx: Context,
  account_id: String,
  session_id: String,
) -> Result(json.Json, AppError) {
  use session <- result.try(load_session(ctx.db, account_id, session_id, False))
  use op <- result.try(operations.require(ctx.db, account_id, session.operation_id, False))
  case op.status {
    "awaiting_upload" ->
      case session.expired {
        True -> {
          use _ <- result.try(expire_now(ctx, account_id))
          Error(expired_or_terminal(op, session))
        }
        False -> freeze_and_accept(ctx, account_id, session)
      }
    "expired" | "cancelled" -> Error(expired_or_terminal(op, session))
    "failed" if op.upload_accepted_at == None ->
      Error(
        error.new(422, "unsupported_image", "The uploaded file is not a supported image.")
        |> error.with_details([#("operation_id", json.string(op.id))]),
      )
    // Already accepted (or beyond): return the same result.
    _ -> accepted_json(ctx, account_id, op.id)
  }
}

fn expire_now(ctx: Context, account_id: String) -> Result(Nil, AppError) {
  context.transaction(ctx, fn(tx) {
    use _ <- result.try(accounts.lock(tx, account_id))
    use _ <- result.try(expiry.expire_abandoned(tx, account_id, ctx.config.lazy_expiry_batch))
    Ok(Nil)
  })
}

fn accepted_json(
  ctx: Context,
  account_id: String,
  operation_id: String,
) -> Result(json.Json, AppError) {
  use op <- result.try(operations.require(ctx.db, account_id, operation_id, False))
  use visibility <- db(database.query_one(
    ctx.db,
    "select visibility from pages where account_id = $1::uuid and id = $2::uuid",
    [database.text(account_id), database.nullable_text(op.page_id)],
    decode.at([0], decode.string),
  ))
  Ok(json.object([
    #("operation", operations.to_json(op, [])),
    #("page_visibility", context.optional_string(visibility)),
  ]))
}

fn freeze_and_accept(
  ctx: Context,
  account_id: String,
  session: Session,
) -> Result(json.Json, AppError) {
  let config = ctx.config.storage
  // Record the final key in a pending object row before copying, so a crash
  // between storage and database writes is reconciled rather than leaked.
  let object_id = uuid.v7_string()
  let final_key = "objects/" <> account_id <> "/" <> object_id
  use final_key <- result.try(reserve_final_key(ctx, account_id, session, object_id, final_key))
  use info <- result.try(
    storage.head(config, session.staging_key)
    |> result.map_error(fn(e) {
      case e {
        storage.NotFound ->
          error.new(409, "upload_missing", "No uploaded bytes were found; upload, then complete.")
        _ -> error.unavailable()
      }
    }),
  )
  use <- error.guard(
    info.bytes == session.expected_bytes,
    error.new(409, "upload_missing", "The uploaded size does not match the declared size."),
  )
  use _ <- result.try(
    storage.copy_if_match(config, session.staging_key, final_key, info.etag)
    |> result.map_error(fn(e) {
      case e {
        storage.PreconditionFailed ->
          error.new(409, "upload_changed", "The upload changed during completion; retry.")
        storage.NotFound ->
          error.new(409, "upload_missing", "No uploaded bytes were found; upload, then complete.")
        _ -> error.unavailable()
      }
    }),
  )
  // Validate the frozen final object, never the mutable staging object.
  use bytes <- result.try(
    storage.get(config, final_key) |> result.replace_error(error.unavailable()),
  )
  let actual_checksum =
    crypto.hash(crypto.Sha256, bytes) |> bit_array.base16_encode |> string.lowercase
  let validation = case
    actual_checksum == session.checksum
    && bit_array.byte_size(bytes) == session.expected_bytes
  {
    False -> Error("checksum_mismatch")
    True ->
      case image.inspect(bytes, ctx.config.image_limits) {
        Ok(info) ->
          case image.content_type(info.format) == session.content_type {
            True -> Ok(info)
            False -> Error("content_type_mismatch")
          }
        Error(reason) -> Error(reason)
      }
  }
  // Header checks pass: fully decode the frozen copy in the sandboxed
  // decoder (section 7). A sandbox outage is retryable, never a rejection.
  use validation <- result.try(case validation, ctx.config.decoder {
    Ok(info), Some(config) ->
      case decoder.validate(config, bytes) {
        Ok(_) -> Ok(Ok(info))
        Error(decoder.Unsupported(reason)) -> Ok(Error("decode:" <> reason))
        Error(decoder.Unavailable(_)) -> Error(error.unavailable())
      }
    other, _ -> Ok(other)
  })
  case validation {
    Error(reason) -> {
      let _ = storage.delete(config, final_key)
      use _ <- result.try(reject(ctx, account_id, session, reason))
      Error(
        error.new(422, "unsupported_image", "The uploaded file is not a supported image.")
        |> error.with_details([
          #("reason", json.string(reason)),
          #("operation_id", json.string(session.operation_id)),
        ]),
      )
    }
    Ok(info) -> {
      let accepted = accept(ctx, account_id, session, final_key, info)
      case accepted {
        Ok(_) -> {
          let _ = storage.delete(config, session.staging_key)
          accepted_json(ctx, account_id, session.operation_id)
        }
        Error(e) -> {
          // Lost the race (expiry/cancellation): the frozen copy is garbage.
          case e.code {
            "upload_expired" | "operation_terminal" -> {
              let _ = storage.delete(config, final_key)
              Nil
            }
            _ -> Nil
          }
          Error(e)
        }
      }
    }
  }
}

fn reserve_final_key(
  ctx: Context,
  account_id: String,
  session: Session,
  object_id: String,
  final_key: String,
) -> Result(String, AppError) {
  case session.final_key {
    Some(key) -> Ok(key)
    None ->
      context.transaction(ctx, fn(tx) {
        use current <- result.try(load_session(tx, account_id, session.id, True))
        case current.final_key {
          Some(key) -> Ok(key)
          None -> {
            use _ <- db(database.execute(
              tx,
              "insert into objects (id, account_id, bucket, key, content_type, bytes,
                 checksum, state)
               values ($1::uuid, $2::uuid, $3, $4, $5, $6, $7, 'pending')",
              [
                database.text(object_id),
                database.text(account_id),
                database.text(ctx.config.storage.bucket),
                database.text(final_key),
                database.text(session.content_type),
                database.int(session.expected_bytes),
                database.text(session.checksum),
              ],
            ))
            use _ <- db(database.execute(
              tx,
              "update upload_sessions set final_key = $2 where id = $1::uuid",
              [database.text(session.id), database.text(final_key)],
            ))
            Ok(final_key)
          }
        }
      })
  }
}

fn reject(
  ctx: Context,
  account_id: String,
  session: Session,
  reason: String,
) -> Result(Nil, AppError) {
  context.transaction(ctx, fn(tx) {
    use _ <- result.try(accounts.lock(tx, account_id))
    use _ <- result.try(quota.lock_usage(tx, account_id))
    use _ <- db(jobs.lock_account_slots(tx, account_id))
    use op <- result.try(operations.require(tx, account_id, session.operation_id, True))
    use _ <- db(database.execute(
      tx,
      "update objects set state = 'rejected' where account_id = $1::uuid and key = $2",
      [database.text(account_id), database.nullable_text(session.final_key)],
    ))
    case op.status {
      "awaiting_upload" ->
        operations.end_unaccepted(tx, account_id, op, "failed", Some("user"), Some("unsupported_image:" <> reason))
      _ -> Ok(Nil)
    }
  })
}

fn accept(
  ctx: Context,
  account_id: String,
  session: Session,
  final_key: String,
  info: image.ImageInfo,
) -> Result(Nil, AppError) {
  context.transaction(ctx, fn(tx) {
    use status <- result.try(accounts.lock(tx, account_id))
    use _ <- result.try(quota.lock_usage(tx, account_id))
    use _ <- db(jobs.lock_account_slots(tx, account_id))
    use op <- result.try(operations.require(tx, account_id, session.operation_id, False))
    use notebook_id <- error.found(database.query_one(
      tx,
      "select notebook_id::text from pages where account_id = $1::uuid and id = $2::uuid",
      [database.text(account_id), database.text(session.page_id)],
      decode.at([0], decode.string),
    ))
    use _ <- result.try(pages.lock_notebooks(tx, account_id, [notebook_id]))
    use _ <- result.try(pages.lock_pages(tx, account_id, [session.page_id]))
    // Recheck operation state and expiry under lock using database time.
    use op <- result.try(operations.require(tx, account_id, op.id, True))
    use current <- result.try(load_session(tx, account_id, session.id, True))
    use <- error.guard(
      op.status == "awaiting_upload" && !current.expired && status != "closing" && status != "closed",
      expired_or_terminal(op, current),
    )
    use object_id <- error.found(database.query_one(
      tx,
      "update objects set state = 'stored', width = $3, height = $4
       where account_id = $1::uuid and key = $2 returning id::text",
      [
        database.text(account_id),
        database.text(final_key),
        database.int(info.width),
        database.int(info.height),
      ],
      decode.at([0], decode.string),
    ))
    use _ <- db(database.execute(
      tx,
      "update page_revisions set source_object_id = $3::uuid, status = 'accepted'
       where account_id = $1::uuid and id = $2::uuid",
      [database.text(account_id), database.text(session.revision_id), database.text(object_id)],
    ))
    use _ <- result.try(case ctx.config.decoder {
      Some(_) -> enqueue_derive(tx, account_id, session.page_id, session.revision_id)
      None -> Ok(Nil)
    })
    use _ <- db(database.execute(
      tx,
      "update upload_sessions set status = 'accepted' where id = $1::uuid",
      [database.text(session.id)],
    ))
    use _ <- db(database.execute(
      tx,
      "update operations set upload_accepted_at = now(), updated_at = now()
       where account_id = $1::uuid and id = $2::uuid",
      [database.text(account_id), database.text(op.id)],
    ))
    case op.kind {
      "upload" -> {
        let deferred = op.processing_mode == "deferred"
        use _ <- db(database.execute(
          tx,
          "update pages set visibility = 'active', active_revision_id = $3::uuid,
             awaiting_processing = $4, updated_at = now()
           where account_id = $1::uuid and id = $2::uuid",
          [
            database.text(account_id),
            database.text(session.page_id),
            database.text(session.revision_id),
            database.bool(deferred),
          ],
        ))
        use _ <- result.try(quota.store_page_slot(tx, account_id, op.id))
        use _ <- result.try(operations.bump_numbering(tx, account_id, notebook_id))
        use _ <- result.try(accounts.record_content_change(tx, account_id, session.page_id, "accept"))
        case deferred {
          // A deferred upload ends its upload operation at acceptance.
          True -> {
            use _ <- result.try(operations.set_status(tx, account_id, op.id, "accepted", None, None, None))
            use _ <- db(database.execute(
              tx,
              "update page_revisions set status = 'awaiting_processing' where id = $1::uuid",
              [database.text(session.revision_id)],
            ))
            Ok(Nil)
          }
          False -> enqueue_recognition(ctx, tx, account_id, op.id, session.page_id, session.revision_id)
        }
      }
      _ -> {
        use _ <- db(database.execute(
          tx,
          "update pages set pending_revision_id = $3::uuid, updated_at = now()
           where account_id = $1::uuid and id = $2::uuid",
          [
            database.text(account_id),
            database.text(session.page_id),
            database.text(session.revision_id),
          ],
        ))
        enqueue_recognition(ctx, tx, account_id, op.id, session.page_id, session.revision_id)
      }
    }
  })
}

/// Queue thumbnail/preview generation for an accepted source. Derived
/// images carry no processing allocation and never charge the user.
pub fn enqueue_derive(
  tx: Connection,
  account_id: String,
  page_id: String,
  revision_id: String,
) -> Result(Nil, AppError) {
  use _ <- db(jobs.enqueue(
    tx,
    jobs.NewJob(
      ..jobs.new_job("derive", "derive:" <> revision_id <> ":g0"),
      account_id: Some(account_id),
      page_id: Some(page_id),
      revision_id: Some(revision_id),
      max_attempts: 3,
    ),
  ))
  Ok(Nil)
}

/// Queue the first processing stage for an admitted operation.
pub fn enqueue_recognition(
  _ctx: Context,
  tx: Connection,
  account_id: String,
  operation_id: String,
  page_id: String,
  revision_id: String,
) -> Result(Nil, AppError) {
  use _ <- result.try(operations.set_status(tx, account_id, operation_id, "queued", None, None, None))
  use _ <- db(jobs.enqueue(
    tx,
    jobs.NewJob(
      ..jobs.new_job(
        "recognize",
        "recognize:" <> operation_id <> ":" <> revision_id <> ":g0",
      ),
      account_id: Some(account_id),
      operation_id: Some(operation_id),
      page_id: Some(page_id),
      revision_id: Some(revision_id),
    ),
  ))
  Ok(Nil)
}

// Operations ------------------------------------------------------------------------

/// `GET /v1/operations/{operation_id}`: recover status without a session ID.
pub fn operation_status(
  ctx: Context,
  account_id: String,
  operation_id: String,
) -> Result(json.Json, AppError) {
  use op <- result.try(operations.require(ctx.db, account_id, operation_id, False))
  use session <- result.try(session_for_operation(ctx.db, account_id, operation_id))
  use visibility <- db(database.query_one(
    ctx.db,
    "select visibility from pages where account_id = $1::uuid and id = $2::uuid",
    [database.text(account_id), database.nullable_text(op.page_id)],
    decode.at([0], decode.string),
  ))
  Ok(operations.to_json(op, [
    #("upload_session_id", context.optional_string(option.map(session, fn(s) { s.id }))),
    #("page_visibility", context.optional_string(visibility)),
  ]))
}

/// `POST /v1/operations/{operation_id}/cancel`, idempotent.
pub fn cancel(
  ctx: Context,
  account_id: String,
  operation_id: String,
) -> Result(json.Json, AppError) {
  use _ <- result.try(context.transaction(ctx, fn(tx) {
    use _ <- result.try(accounts.lock(tx, account_id))
    use _ <- result.try(quota.lock_usage(tx, account_id))
    use _ <- db(jobs.lock_account_slots(tx, account_id))
    use op <- result.try(operations.require(tx, account_id, operation_id, False))
    use _ <- result.try(case op.notebook_id {
      Some(n) -> pages.lock_notebooks(tx, account_id, [n]) |> result.replace(Nil)
      None -> Ok(Nil)
    })
    use _ <- result.try(case op.page_id {
      Some(p) -> pages.lock_pages(tx, account_id, [p])
      None -> Ok(Nil)
    })
    use op <- result.try(operations.require(tx, account_id, operation_id, True))
    case op.status, op.upload_accepted_at {
      "awaiting_upload", _ ->
        operations.end_unaccepted(tx, account_id, op, "cancelled", None, None)
      status, _ ->
        case list.contains(operations.live_states, status) {
          True -> {
            use _ <- result.try(case op.kind {
              "deferred_processing" | "reprocess" ->
                // The source stays; it becomes eligible for deferred
                // admission again only if it was a deferred new page.
                case op.kind, op.page_id {
                  "deferred_processing", Some(page_id) ->
                    database.execute(
                      tx,
                      "update pages set awaiting_processing = true
                       where account_id = $1::uuid and id = $2::uuid
                         and visibility = 'active'",
                      [database.text(account_id), database.text(page_id)],
                    )
                    |> result.map_error(error.from_query)
                    |> result.replace(Nil)
                  _, _ -> Ok(Nil)
                }
              _ -> Ok(Nil)
            })
            operations.end_accepted(tx, account_id, op, "cancelled", None, None)
          }
          // Completed operations keep their outcome.
          False -> Ok(Nil)
        }
    }
  }))
  operation_status(ctx, account_id, operation_id)
}

// Deferred processing --------------------------------------------------------------

pub type DeferredItem {
  DeferredItem(page_id: String, source_revision_id: String, operation_id: String)
}

pub fn deferred_decoder() -> decode.Decoder(List(DeferredItem)) {
  decode.at(
    ["items"],
    decode.list({
      use page_id <- decode.field("page_id", decode.string)
      use revision <- decode.field("source_revision_id", decode.string)
      use operation_id <- decode.field("operation_id", decode.string)
      decode.success(DeferredItem(
        string.lowercase(page_id),
        string.lowercase(revision),
        string.lowercase(operation_id),
      ))
    }),
  )
}

/// `POST /v1/pages/process-deferred`: admit as many eligible deferred pages
/// as processing capacity allows. Results come back in stable
/// notebook/page/ID order; repeated or concurrent batches start at most one
/// operation per source.
pub fn process_deferred(
  ctx: Context,
  account_id: String,
  items: List(DeferredItem),
) -> Result(json.Json, AppError) {
  use <- error.guard(
    items != [] && list.length(items) <= 100,
    error.unprocessable("items must contain 1-100 entries"),
  )
  use <- error.guard(
    list.all(items, fn(i) {
      context.is_uuid(i.page_id)
      && context.is_uuid(i.source_revision_id)
      && context.is_uuid(i.operation_id)
    }),
    error.bad_request("items require UUID page_id, source_revision_id and operation_id"),
  )
  context.transaction(ctx, fn(tx) {
    use _ <- result.try(accounts.lock_active(tx, account_id))
    use _ <- result.try(quota.lock_usage(tx, account_id))
    use ent <- result.try(quota.entitlement(tx, ctx.config, account_id))
    use _ <- db(jobs.lock_account_slots(tx, account_id))
    let page_ids = list.map(items, fn(i) { i.page_id })
    use rows <- db(database.query(
      tx,
      "select p.id::text, p.notebook_id::text, p.page_number,
         p.active_revision_id::text, p.awaiting_processing,
         p.visibility = 'active' and n.deleted_at is null
       from pages p join notebooks n on n.id = p.notebook_id
       where p.account_id = $1::uuid and p.id = any($2::uuid[])
       order by n.created_at, n.id, p.page_number, p.id",
      [database.text(account_id), database.text_array(page_ids)],
      {
        use id <- decode.field(0, decode.string)
        use notebook <- decode.field(1, decode.string)
        use number <- decode.field(2, decode.int)
        use revision <- decode.field(3, decode.optional(decode.string))
        use awaiting <- decode.field(4, decode.bool)
        use visible <- decode.field(5, decode.bool)
        decode.success(#(id, notebook, number, revision, awaiting, visible))
      },
    ))
    use _ <- result.try(pages.lock_notebooks(tx, account_id, list.map(rows, fn(r) { r.1 })))
    use _ <- result.try(pages.lock_pages(tx, account_id, page_ids))
    use results <- result.try(list.try_map(rows, fn(row) {
      let #(page_id, _, _, revision, awaiting, visible) = row
      let assert Ok(item) = list.find(items, fn(i) { i.page_id == page_id })
      let result_json = fn(status: String, operation: Option(String)) {
        json.object([
          #("page_id", json.string(page_id)),
          #("operation_id", context.optional_string(operation)),
          #("result", json.string(status)),
        ])
      }
      use existing <- result.try(operations.load(tx, account_id, item.operation_id, False))
      case existing, visible && revision == Some(item.source_revision_id) && awaiting {
        Some(op), _ if op.page_id == Some(page_id) ->
          Ok(result_json("already_admitted", Some(op.id)))
        Some(_), _ -> Ok(result_json("conflict", None))
        None, False -> Ok(result_json("conflict", None))
        None, True ->
          case quota.reserve_processing(tx, ent, account_id) {
            Error(e) if e.code == "processing_limit_reached" ->
              Ok(result_json("limit", None))
            Error(e) -> Error(e)
            Ok(funding) -> {
              let hash =
                context.request_hash([
                  #("page_id", json.string(page_id)),
                  #("source_revision_id", json.string(item.source_revision_id)),
                ])
              use _ <- result.try(operations.insert(
                tx,
                account_id,
                item.operation_id,
                "deferred_processing",
                hash,
                "queued",
                "",
                Some(row.1),
                Some(page_id),
                Some(item.source_revision_id),
                "immediate",
                None,
                item.operation_id,
              ))
              use _ <- result.try(quota.insert_reservation(
                tx,
                account_id,
                item.operation_id,
                False,
                Some(funding),
                None,
              ))
              use _ <- db(database.execute(
                tx,
                "update pages set awaiting_processing = false
                 where account_id = $1::uuid and id = $2::uuid",
                [database.text(account_id), database.text(page_id)],
              ))
              use _ <- result.try(enqueue_recognition(
                ctx,
                tx,
                account_id,
                item.operation_id,
                page_id,
                item.source_revision_id,
              ))
              Ok(result_json("admitted", Some(item.operation_id)))
            }
          }
      }
    }))
    let missing =
      items
      |> list.filter(fn(i) { !list.any(rows, fn(r) { r.0 == i.page_id }) })
      |> list.sort(fn(a, b) { string.compare(a.page_id, b.page_id) })
      |> list.map(fn(i) {
        json.object([
          #("page_id", json.string(i.page_id)),
          #("operation_id", json.null()),
          #("result", json.string("conflict")),
        ])
      })
    Ok(json.object([#("results", json.preprocessed_array(list.append(results, missing)))]))
  })
}

// Reprocess --------------------------------------------------------------------------

pub type ReprocessRequest {
  ReprocessRequest(operation_id: String, source_revision_id: String)
}

pub fn reprocess_decoder() -> decode.Decoder(ReprocessRequest) {
  use operation_id <- decode.field("operation_id", decode.string)
  use revision <- decode.field("source_revision_id", decode.string)
  decode.success(ReprocessRequest(string.lowercase(operation_id), string.lowercase(revision)))
}

/// `POST /v1/pages/{id}/reprocess`: an explicit rescan of the active source
/// follows ordinary admission and holds the source-operation guard. If a
/// recovery hold exists for this source, the retry claims it instead of new
/// allowance.
pub fn reprocess(
  ctx: Context,
  account_id: String,
  page_id: String,
  if_match: Option(Int),
  request: ReprocessRequest,
) -> Result(json.Json, AppError) {
  use expected <- result.try(option.to_result(if_match, error.precondition_required()))
  use <- error.guard(
    context.is_uuid(request.operation_id) && context.is_uuid(request.source_revision_id),
    error.bad_request("operation_id and source_revision_id must be UUIDs"),
  )
  let hash =
    context.request_hash([
      #("page_id", json.string(page_id)),
      #("source_revision_id", json.string(request.source_revision_id)),
      #("if_match", json.int(expected)),
    ])
  use _ <- result.try(context.transaction(ctx, fn(tx) {
    use _ <- result.try(accounts.lock_active(tx, account_id))
    use existing <- result.try(operations.load(tx, account_id, request.operation_id, False))
    case existing {
      Some(op) -> {
        use <- error.guard(op.request_hash == hash, error.idempotency_conflict())
        Ok(Nil)
      }
      None -> {
        use _ <- result.try(quota.lock_usage(tx, account_id))
        use ent <- result.try(quota.entitlement(tx, ctx.config, account_id))
        use _ <- db(jobs.lock_account_slots(tx, account_id))
        use page <- result.try(pages.get(tx, account_id, page_id))
        use _ <- result.try(pages.lock_notebooks(tx, account_id, [page.notebook_id]))
        use _ <- result.try(pages.lock_pages(tx, account_id, [page_id]))
        use page <- result.try(pages.get(tx, account_id, page_id))
        use <- error.guard(page.content_version == expected, error.version_conflict())
        use <- error.guard(
          page.revision_id == Some(request.source_revision_id),
          error.version_conflict(),
        )
        use _ <- result.try(ratelimit.rescans(
          tx,
          account_id,
          page_id,
          ctx.config.rate_limits.rescans_per_page_day,
        ))
        use live <- result.try(operations.live_for_page(tx, account_id, page_id))
        use _ <- result.try(case live {
          Some(op) -> Error(operations.conflict(op))
          None -> Ok(Nil)
        })
        use hold <- result.try(claimable_hold(tx, account_id, request.source_revision_id))
        let charge_root = case hold {
          Some(#(_, root)) -> root
          None -> request.operation_id
        }
        use _ <- result.try(operations.insert(
          tx,
          account_id,
          request.operation_id,
          "reprocess",
          hash,
          "queued",
          "",
          Some(page.notebook_id),
          Some(page_id),
          Some(request.source_revision_id),
          "immediate",
          None,
          charge_root,
        ))
        use _ <- result.try(case hold {
          Some(#(hold_id, _)) -> claim_hold(tx, account_id, hold_id, request.operation_id)
          None -> {
            use funding <- result.try(quota.reserve_processing(tx, ent, account_id))
            quota.insert_reservation(tx, account_id, request.operation_id, False, Some(funding), None)
            |> result.replace(Nil)
          }
        })
        use _ <- db(database.execute(
          tx,
          "update pages set awaiting_processing = false where id = $1::uuid",
          [database.text(page_id)],
        ))
        enqueue_recognition(ctx, tx, account_id, request.operation_id, page_id, request.source_revision_id)
      }
    }
  }))
  operation_status(ctx, account_id, request.operation_id)
}

fn claimable_hold(
  tx: Connection,
  account_id: String,
  source_revision_id: String,
) -> Result(Option(#(String, String)), AppError) {
  use row <- db(database.query_one(
    tx,
    "select id::text, charge_root_operation_id::text from recovery_holds
     where account_id = $1::uuid and source_revision_id = $2::uuid
       and state = 'held' and claim_deadline > now()
     order by first_failure_at limit 1 for update",
    [database.text(account_id), database.text(source_revision_id)],
    {
      use id <- decode.field(0, decode.string)
      use root <- decode.field(1, decode.string)
      decode.success(#(id, root))
    },
  ))
  Ok(row)
}

/// Move a held allocation to the retry operation atomically: the same
/// funding and charge root, no fresh allocation.
fn claim_hold(
  tx: Connection,
  account_id: String,
  hold_id: String,
  operation_id: String,
) -> Result(Nil, AppError) {
  use _ <- db(database.execute(
    tx,
    "update quota_reservations q set operation_id = $3::uuid, processing_state = 'reserved'
     from recovery_holds h
     where h.id = $2::uuid and h.account_id = $1::uuid and q.id = h.reservation_id
       and q.processing_state = 'held'",
    [database.text(account_id), database.text(hold_id), database.text(operation_id)],
  ))
  use _ <- db(database.execute(
    tx,
    "update recovery_holds set state = 'claimed', active_retry_operation_id = $2::uuid
     where id = $1::uuid",
    [database.text(hold_id), database.text(operation_id)],
  ))
  Ok(Nil)
}

/// Release recovery holds whose claim deadline passed (sweeper).
pub fn expire_holds(ctx: Context, account_id: String) -> Result(Int, AppError) {
  context.transaction(ctx, fn(tx) {
    use _ <- result.try(accounts.lock(tx, account_id))
    use _ <- result.try(quota.lock_usage(tx, account_id))
    use expired <- db(database.query(
      tx,
      "update recovery_holds set state = 'released'
       where account_id = $1::uuid and state = 'held' and claim_deadline <= now()
       returning reservation_id::text",
      [database.text(account_id)],
      decode.at([0], decode.string),
    ))
    use _ <- result.try(list.try_each(expired, fn(reservation_id) {
      use operation_id <- error.found(database.query_one(
        tx,
        "select operation_id::text from quota_reservations where id = $1::uuid",
        [database.text(reservation_id)],
        decode.at([0], decode.string),
      ))
      quota.release_processing(tx, account_id, operation_id)
    }))
    Ok(list.length(expired))
  })
}
