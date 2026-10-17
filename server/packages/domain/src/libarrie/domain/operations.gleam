//// Durable operation records and their terminal transitions (sections 7, 8
//// and 10).
////
//// Every source-changing request is an operation unique per account for the
//// account's lifetime. Terminal transitions settle each reservation
//// component once and invalidate job tokens in the same transaction.
////
//// Callers hold, in order: the account row, the usage row, the account job
//// slot row, affected notebooks and pages. Functions here then touch
//// revisions, operations, reservations and jobs (levels 6, 7 and 10).

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import libarrie/database.{type Connection}
import libarrie/domain/context
import libarrie/domain/error.{type AppError, db}
import libarrie/domain/quota
import libarrie/jobs

pub type Operation {
  Operation(
    id: String,
    kind: String,
    status: String,
    request_hash: String,
    failure_fault: Option(String),
    client_label: String,
    notebook_id: Option(String),
    page_id: Option(String),
    revision_id: Option(String),
    processing_mode: String,
    upload_accepted_at: Option(String),
    parent_operation_id: Option(String),
    charge_root_operation_id: String,
    terminal_reason: Option(String),
    error_code: Option(String),
    created_at: String,
    updated_at: String,
  )
}

/// Live (non-terminal) states. These hold the per-page source guard.
pub const live_states = [
  "awaiting_upload", "validating", "queued", "recognizing", "indexing",
]

pub fn is_live(op: Operation) -> Bool {
  list.contains(live_states, op.status)
}

const columns = "id::text, kind, status, request_hash, failure_fault, client_label,
  notebook_id::text, page_id::text, revision_id::text, processing_mode,
  rfc3339(upload_accepted_at), parent_operation_id::text,
  charge_root_operation_id::text, terminal_reason, error_code,
  rfc3339(created_at), rfc3339(updated_at)"

fn decoder() -> decode.Decoder(Operation) {
  use id <- decode.field(0, decode.string)
  use kind <- decode.field(1, decode.string)
  use status <- decode.field(2, decode.string)
  use request_hash <- decode.field(3, decode.string)
  use failure_fault <- decode.field(4, decode.optional(decode.string))
  use client_label <- decode.field(5, decode.string)
  use notebook_id <- decode.field(6, decode.optional(decode.string))
  use page_id <- decode.field(7, decode.optional(decode.string))
  use revision_id <- decode.field(8, decode.optional(decode.string))
  use processing_mode <- decode.field(9, decode.string)
  use upload_accepted_at <- decode.field(10, decode.optional(decode.string))
  use parent_operation_id <- decode.field(11, decode.optional(decode.string))
  use charge_root_operation_id <- decode.field(12, decode.string)
  use terminal_reason <- decode.field(13, decode.optional(decode.string))
  use error_code <- decode.field(14, decode.optional(decode.string))
  use created_at <- decode.field(15, decode.string)
  use updated_at <- decode.field(16, decode.string)
  decode.success(Operation(
    id:,
    kind:,
    status:,
    request_hash:,
    failure_fault:,
    client_label:,
    notebook_id:,
    page_id:,
    revision_id:,
    processing_mode:,
    upload_accepted_at:,
    parent_operation_id:,
    charge_root_operation_id:,
    terminal_reason:,
    error_code:,
    created_at:,
    updated_at:,
  ))
}

pub fn load(
  conn: Connection,
  account_id: String,
  operation_id: String,
  for_update: Bool,
) -> Result(Option(Operation), AppError) {
  let lock = case for_update {
    True -> " for update"
    False -> ""
  }
  use op <- db(database.query_one(
    conn,
    "select " <> columns <> " from operations
     where account_id = $1::uuid and id = $2::uuid" <> lock,
    [database.text(account_id), database.text(operation_id)],
    decoder(),
  ))
  Ok(op)
}

pub fn require(
  conn: Connection,
  account_id: String,
  operation_id: String,
  for_update: Bool,
) -> Result(Operation, AppError) {
  use op <- result.try(load(conn, account_id, operation_id, for_update))
  option.to_result(op, error.not_found())
}

/// The live source-changing operation on a page, if any.
pub fn live_for_page(
  conn: Connection,
  account_id: String,
  page_id: String,
) -> Result(Option(Operation), AppError) {
  use op <- db(database.query_one(
    conn,
    "select " <> columns <> " from operations
     where account_id = $1::uuid and page_id = $2::uuid
       and status = any($3::text[])
     for update",
    [
      database.text(account_id),
      database.text(page_id),
      database.text_array(live_states),
    ],
    decoder(),
  ))
  Ok(op)
}

pub fn insert(
  conn: Connection,
  account_id: String,
  id: String,
  kind: String,
  request_hash: String,
  status: String,
  client_label: String,
  notebook_id: Option(String),
  page_id: Option(String),
  revision_id: Option(String),
  processing_mode: String,
  parent_operation_id: Option(String),
  charge_root_operation_id: String,
) -> Result(Nil, AppError) {
  use _ <- db(database.execute(
    conn,
    "insert into operations (id, account_id, kind, request_hash, status,
       client_label, notebook_id, page_id, revision_id, processing_mode,
       parent_operation_id, charge_root_operation_id)
     values ($1::uuid, $2::uuid, $3, $4, $5, $6, $7::uuid, $8::uuid, $9::uuid,
       $10, $11::uuid, $12::uuid)",
    [
      database.text(id),
      database.text(account_id),
      database.text(kind),
      database.text(request_hash),
      database.text(status),
      database.text(client_label),
      database.nullable_text(notebook_id),
      database.nullable_text(page_id),
      database.nullable_text(revision_id),
      database.text(processing_mode),
      database.nullable_text(parent_operation_id),
      database.text(charge_root_operation_id),
    ],
  ))
  Ok(Nil)
}

pub fn set_status(
  conn: Connection,
  account_id: String,
  operation_id: String,
  status: String,
  failure_fault: Option(String),
  error_code: Option(String),
  terminal_reason: Option(String),
) -> Result(Nil, AppError) {
  use _ <- db(database.execute(
    conn,
    "update operations set status = $3,
       failure_fault = coalesce($4, failure_fault),
       error_code = coalesce($5, error_code),
       terminal_reason = coalesce($6, terminal_reason),
       updated_at = now()
     where account_id = $1::uuid and id = $2::uuid",
    [
      database.text(account_id),
      database.text(operation_id),
      database.text(status),
      database.nullable_text(failure_fault),
      database.nullable_text(error_code),
      database.nullable_text(terminal_reason),
    ],
  ))
  Ok(Nil)
}

/// End an operation that never had its source accepted: release both
/// reservation components, remove a new-page placeholder and its number
/// claim, and fence the upload session. `status` is `cancelled`, `expired`
/// or `failed`.
pub fn end_unaccepted(
  conn: Connection,
  account_id: String,
  op: Operation,
  status: String,
  failure_fault: Option(String),
  error_code: Option(String),
) -> Result(Nil, AppError) {
  use _ <- result.try(quota.release_page_slot(conn, account_id, op.id))
  use _ <- result.try(quota.release_processing(conn, account_id, op.id))
  let session_status = case status {
    "expired" -> "expired"
    "failed" -> "failed"
    _ -> "cancelled"
  }
  use _ <- db(database.execute(
    conn,
    "update upload_sessions set status = $3
     where account_id = $1::uuid and operation_id = $2::uuid
       and status in ('awaiting_upload', 'completing')",
    [database.text(account_id), database.text(op.id), database.text(session_status)],
  ))
  use _ <- result.try(case op.kind, op.page_id, op.revision_id {
    "upload", Some(page_id), Some(revision_id) ->
      remove_placeholder(conn, account_id, page_id, revision_id)
    _, _, Some(revision_id) ->
      mark_revision(conn, account_id, revision_id, session_status)
    _, _, _ -> Ok(Nil)
  })
  use _ <- result.try(jobs.cancel_for_operation(conn, account_id, op.id)
    |> result.map_error(error.from_query))
  set_status(conn, account_id, op.id, status, failure_fault, error_code, Some(status))
}

fn remove_placeholder(
  conn: Connection,
  account_id: String,
  page_id: String,
  revision_id: String,
) -> Result(Nil, AppError) {
  use notebook <- db(database.query_one(
    conn,
    "select notebook_id::text from pages
     where account_id = $1::uuid and id = $2::uuid and visibility = 'placeholder'",
    [database.text(account_id), database.text(page_id)],
    decode.at([0], decode.string),
  ))
  case notebook {
    None -> mark_revision(conn, account_id, revision_id, "cancelled")
    Some(notebook_id) -> {
      use _ <- db(database.execute(
        conn,
        "delete from page_revisions where account_id = $1::uuid and page_id = $2::uuid",
        [database.text(account_id), database.text(page_id)],
      ))
      use _ <- db(database.execute(
        conn,
        "delete from pages where account_id = $1::uuid and id = $2::uuid
           and visibility = 'placeholder'",
        [database.text(account_id), database.text(page_id)],
      ))
      bump_numbering(conn, account_id, notebook_id)
    }
  }
}

pub fn bump_numbering(
  conn: Connection,
  account_id: String,
  notebook_id: String,
) -> Result(Nil, AppError) {
  use _ <- db(database.execute(
    conn,
    "update notebooks set numbering_revision = numbering_revision + 1
     where account_id = $1::uuid and id = $2::uuid",
    [database.text(account_id), database.text(notebook_id)],
  ))
  Ok(Nil)
}

fn mark_revision(
  conn: Connection,
  account_id: String,
  revision_id: String,
  status: String,
) -> Result(Nil, AppError) {
  use _ <- db(database.execute(
    conn,
    "update page_revisions set status = $3
     where account_id = $1::uuid and id = $2::uuid",
    [database.text(account_id), database.text(revision_id), database.text(status)],
  ))
  Ok(Nil)
}

/// End an operation whose source was already accepted, before publication.
/// The accepted initial image stays viewable; a pending replacement is
/// dropped and the previous source stays active. Unconsumed processing is
/// released (`cancelled`, `superseded`, `deleted`, user-fault `failed`,
/// `needs_user_action`).
pub fn end_accepted(
  conn: Connection,
  account_id: String,
  op: Operation,
  status: String,
  failure_fault: Option(String),
  error_code: Option(String),
) -> Result(Nil, AppError) {
  use _ <- result.try(quota.release_processing(conn, account_id, op.id))
  use _ <- result.try(clear_pending_source(conn, account_id, op, status))
  use _ <- result.try(jobs.cancel_for_operation(conn, account_id, op.id)
    |> result.map_error(error.from_query))
  set_status(conn, account_id, op.id, status, failure_fault, error_code, Some(status))
}

/// Terminal system-fault failure after acceptance: move the unconsumed
/// allocation into the charge root's recovery hold.
pub fn fail_system(
  conn: Connection,
  config: context.Config,
  account_id: String,
  op: Operation,
  reason: String,
) -> Result(Nil, AppError) {
  use hold <- result.try(case op.revision_id {
    Some(revision_id) ->
      quota.hold_processing(
        conn,
        config,
        account_id,
        op.id,
        op.charge_root_operation_id,
        revision_id,
        op.request_hash,
      )
    None -> Ok(None)
  })
  use _ <- result.try(case hold {
    Some(hold_id) ->
      database.execute(
        conn,
        "update operations set recovery_hold_id = $3::uuid
         where account_id = $1::uuid and id = $2::uuid",
        [database.text(account_id), database.text(op.id), database.text(hold_id)],
      )
      |> result.map_error(error.from_query)
      |> result.replace(Nil)
    None -> Ok(Nil)
  })
  use _ <- result.try(clear_pending_source(conn, account_id, op, "failed"))
  use _ <- result.try(jobs.cancel_for_operation(conn, account_id, op.id)
    |> result.map_error(error.from_query))
  set_status(conn, account_id, op.id, "failed", Some("system"), Some(reason), Some(reason))
}

fn clear_pending_source(
  conn: Connection,
  account_id: String,
  op: Operation,
  status: String,
) -> Result(Nil, AppError) {
  case op.kind, op.page_id, op.revision_id {
    "replacement", Some(page_id), Some(revision_id) -> {
      use _ <- db(database.execute(
        conn,
        "update pages set pending_revision_id = null, updated_at = now()
         where account_id = $1::uuid and id = $2::uuid
           and pending_revision_id = $3::uuid",
        [database.text(account_id), database.text(page_id), database.text(revision_id)],
      ))
      mark_revision(conn, account_id, revision_id, status)
    }
    "upload", _, Some(revision_id) | "deferred_processing", _, Some(revision_id) ->
      mark_revision(conn, account_id, revision_id, status)
    _, _, _ -> Ok(Nil)
  }
}

pub fn to_json(op: Operation, extra: List(#(String, json.Json))) -> json.Json {
  json.object([
    #("operation_id", json.string(op.id)),
    #("kind", json.string(op.kind)),
    #("status", json.string(op.status)),
    #("failure_fault", context.optional_string(op.failure_fault)),
    #("error_code", context.optional_string(op.error_code)),
    #("client_label", json.string(op.client_label)),
    #("notebook_id", context.optional_string(op.notebook_id)),
    #("page_id", context.optional_string(op.page_id)),
    #("revision_id", context.optional_string(op.revision_id)),
    #("processing_mode", json.string(op.processing_mode)),
    #("upload_accepted_at", context.optional_string(op.upload_accepted_at)),
    #("parent_operation_id", context.optional_string(op.parent_operation_id)),
    #("charge_root_operation_id", json.string(op.charge_root_operation_id)),
    #("created_at", json.string(op.created_at)),
    #("updated_at", json.string(op.updated_at)),
    ..extra
  ])
}

/// Error details naming a blocking operation (409 processing_conflict).
pub fn conflict(op: Operation) -> AppError {
  error.new(
    409,
    "processing_conflict",
    "Another source operation is pending for this page.",
  )
  |> error.with_details([
    #("operation_id", json.string(op.id)),
    #("kind", json.string(op.kind)),
    #("status", json.string(op.status)),
    #("client_label", json.string(op.client_label)),
    #("created_at", json.string(op.created_at)),
  ])
}
