//// Pages: browsing, attribution edits, trash/restore and bulk renumbering
//// (sections 5, 10, 11 and 14).
////
//// Every read path selects `active` pages in non-deleted notebooks
//// explicitly. Attribution edits (move, renumber) match the resource
//// `version`; text edits match `content_version`.

import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import libarrie/database.{type Connection}
import libarrie/domain/accounts
import libarrie/domain/context.{type Context}
import libarrie/domain/error.{type AppError, db}
import libarrie/domain/expiry
import libarrie/domain/journal
import libarrie/domain/operations
import libarrie/domain/quota
import libarrie/jobs
import youid/uuid

pub type Page {
  Page(
    id: String,
    notebook_id: String,
    notebook_name: String,
    page_number: Int,
    visibility: String,
    version: Int,
    content_version: Int,
    revision_id: Option(String),
    pending_revision_id: Option(String),
    awaiting_processing: Bool,
    transcript_revision_id: Option(String),
    revision_status: Option(String),
    index_generation_id: Option(String),
    indexed_transcript_revision_id: Option(String),
    backup_status: Option(String),
    live_operation_status: Option(String),
    live_operation_id: Option(String),
    deleted_at: Option(String),
    deletion_batch_id: Option(String),
    created_at: String,
    updated_at: String,
    source_object_id: Option(String),
    has_derived: Bool,
  )
}

const select_page = "select p.id::text, p.notebook_id::text, n.name, p.page_number,
    p.visibility, p.version, p.content_version, p.active_revision_id::text,
    p.pending_revision_id::text, p.awaiting_processing,
    r.selected_transcript_revision_id::text, r.status,
    srp.index_generation_id::text, g.transcript_revision_id::text,
    o.backup_status, live.status, live.id::text, rfc3339(p.deleted_at),
    p.deletion_batch_id::text, rfc3339(p.created_at), rfc3339(p.updated_at),
    r.source_object_id::text, r.thumbnail_object_id is not null
  from pages p
  join notebooks n on n.id = p.notebook_id
  join accounts a on a.id = p.account_id
  left join page_revisions r on r.id = p.active_revision_id
  left join objects o on o.id = r.source_object_id
  left join search_release_pages srp
    on srp.release_id = a.active_search_release_id and srp.page_id = p.id
  left join index_generations g on g.id = srp.index_generation_id
  left join lateral (
    select op.status, op.id from operations op
    where op.account_id = p.account_id and op.page_id = p.id
      and op.status in ('awaiting_upload', 'validating', 'queued', 'recognizing', 'indexing')
    order by op.created_at desc limit 1) live on true"

fn page_decoder() -> decode.Decoder(Page) {
  use id <- decode.field(0, decode.string)
  use notebook_id <- decode.field(1, decode.string)
  use notebook_name <- decode.field(2, decode.string)
  use page_number <- decode.field(3, decode.int)
  use visibility <- decode.field(4, decode.string)
  use version <- decode.field(5, decode.int)
  use content_version <- decode.field(6, decode.int)
  use revision_id <- decode.field(7, decode.optional(decode.string))
  use pending_revision_id <- decode.field(8, decode.optional(decode.string))
  use awaiting_processing <- decode.field(9, decode.bool)
  use transcript_revision_id <- decode.field(10, decode.optional(decode.string))
  use revision_status <- decode.field(11, decode.optional(decode.string))
  use index_generation_id <- decode.field(12, decode.optional(decode.string))
  use indexed_transcript <- decode.field(13, decode.optional(decode.string))
  use backup_status <- decode.field(14, decode.optional(decode.string))
  use live_status <- decode.field(15, decode.optional(decode.string))
  use live_id <- decode.field(16, decode.optional(decode.string))
  use deleted_at <- decode.field(17, decode.optional(decode.string))
  use deletion_batch_id <- decode.field(18, decode.optional(decode.string))
  use created_at <- decode.field(19, decode.string)
  use updated_at <- decode.field(20, decode.string)
  use source_object_id <- decode.field(21, decode.optional(decode.string))
  use has_derived <- decode.field(22, decode.bool)
  decode.success(Page(
    id:,
    notebook_id:,
    notebook_name:,
    page_number:,
    visibility:,
    version:,
    content_version:,
    revision_id:,
    pending_revision_id:,
    awaiting_processing:,
    transcript_revision_id:,
    revision_status:,
    index_generation_id:,
    indexed_transcript_revision_id: indexed_transcript,
    backup_status:,
    live_operation_status: live_status,
    live_operation_id: live_id,
    deleted_at:,
    deletion_batch_id:,
    created_at:,
    updated_at:,
    source_object_id:,
    has_derived:,
  ))
}

pub fn processing_status(page: Page) -> String {
  case page.awaiting_processing, page.live_operation_status, page.revision_status {
    True, _, _ -> "awaiting_processing"
    _, Some(status), _ -> status
    _, None, Some(status) -> status
    _, None, None -> "unknown"
  }
}

pub fn indexing_pending(page: Page) -> Bool {
  case page.transcript_revision_id, page.indexed_transcript_revision_id {
    Some(selected), Some(indexed) -> selected != indexed
    Some(_), None -> page.revision_status != Some("needs_user_action")
    None, _ -> False
  }
}

pub fn etag(page: Page) -> String {
  "\"v" <> int.to_string(page.version) <> "\""
}

pub fn content_etag(page: Page) -> String {
  "\"c" <> int.to_string(page.content_version) <> "\""
}

pub fn to_json(page: Page) -> json.Json {
  json.object([
    #("id", json.string(page.id)),
    #("notebook", json.object([
      #("id", json.string(page.notebook_id)),
      #("name", json.string(page.notebook_name)),
    ])),
    #("page_number", json.int(page.page_number)),
    #("visibility", json.string(page.visibility)),
    #("version", json.int(page.version)),
    #("content_version", json.int(page.content_version)),
    #("revision_id", context.optional_string(page.revision_id)),
    #("pending_revision_id", context.optional_string(page.pending_revision_id)),
    #("transcript_revision_id", context.optional_string(page.transcript_revision_id)),
    #("index_generation_id", context.optional_string(page.index_generation_id)),
    #("processing_status", json.string(processing_status(page))),
    #("indexing_pending", json.bool(indexing_pending(page))),
    #("live_operation_id", context.optional_string(page.live_operation_id)),
    #("backup_status", context.optional_string(page.backup_status)),
    #("deleted_at", context.optional_string(page.deleted_at)),
    #("deletion_batch_id", context.optional_string(page.deletion_batch_id)),
    #("created_at", json.string(page.created_at)),
    #("updated_at", json.string(page.updated_at)),
    // Same-origin, cacheable image routes (available once derived).
    #("thumbnail_url", image_url(page, "thumb")),
    #("preview_url", image_url(page, "preview")),
  ])
}

fn image_url(page: Page, variant: String) -> json.Json {
  case page.source_object_id, page.has_derived {
    Some(id), True -> json.string("/img/" <> id <> "/" <> variant)
    _, _ -> json.null()
  }
}

/// Load an active, account-owned page in a non-deleted notebook.
pub fn get(
  conn: Connection,
  account_id: String,
  page_id: String,
) -> Result(Page, AppError) {
  use page <- error.found(database.query_one(
    conn,
    select_page
      <> " where p.account_id = $1::uuid and p.id = $2::uuid
           and p.visibility = 'active' and n.deleted_at is null",
    [database.text(account_id), database.text(page_id)],
    page_decoder(),
  ))
  Ok(page)
}

/// The active page with this number in an active notebook.
pub fn by_number(
  conn: Connection,
  account_id: String,
  notebook_id: String,
  page_number: Int,
) -> Result(Page, AppError) {
  use page <- error.found(database.query_one(
    conn,
    select_page
      <> " where p.account_id = $1::uuid and p.notebook_id = $2::uuid
           and p.page_number = $3 and p.visibility = 'active'
           and n.deleted_at is null",
    [database.text(account_id), database.text(notebook_id), database.int(page_number)],
    page_decoder(),
  ))
  Ok(page)
}

pub type TranscriptText {
  Transcribed(String)
  NotTranscribed
  /// The page is in a private notebook now, named here.
  InPrivateNotebook(name: String)
}

/// The text of the transcript the lookup selected, unless the page's
/// current notebook is private. One statement reads the flag and the text,
/// so a privacy change or a move into a private notebook after the lookup
/// is refused too (ADR 0017). Unlike the module's other reads, it doesn't
/// filter by visibility or trash: the lookup already did, and a private
/// flag counts whatever state its notebook is in now.
pub fn transcript_text(
  conn: Connection,
  account_id: String,
  page: Page,
) -> Result(TranscriptText, AppError) {
  use row <- db(database.query_one(
    conn,
    "select n.private, n.name, t.text
     from pages p
     join notebooks n on n.id = p.notebook_id
     left join transcript_revisions t
       on t.account_id = p.account_id and t.id = $3::uuid
     where p.account_id = $1::uuid and p.id = $2::uuid",
    [
      database.text(account_id),
      database.text(page.id),
      database.nullable_text(page.transcript_revision_id),
    ],
    {
      use private <- decode.field(0, decode.bool)
      use name <- decode.field(1, decode.string)
      use text <- decode.field(2, decode.optional(decode.string))
      decode.success(#(private, name, text))
    },
  ))
  case row {
    Some(#(True, name, _)) -> Ok(InPrivateNotebook(name))
    Some(#(False, _, Some(text))) -> Ok(Transcribed(text))
    Some(#(False, _, None)) | None -> Ok(NotTranscribed)
  }
}

/// Load a page in any visibility except placeholder (trash and restore).
fn get_any(
  conn: Connection,
  account_id: String,
  page_id: String,
) -> Result(Page, AppError) {
  use page <- error.found(database.query_one(
    conn,
    select_page
      <> " where p.account_id = $1::uuid and p.id = $2::uuid
           and p.visibility <> 'placeholder' and p.purge_requested_at is null",
    [database.text(account_id), database.text(page_id)],
    page_decoder(),
  ))
  Ok(page)
}

pub fn detail_json(
  conn: Connection,
  account_id: String,
  page: Page,
) -> Result(json.Json, AppError) {
  use transcript <- result.try(case page.transcript_revision_id {
    None -> Ok(None)
    Some(id) ->
      database.query_one(
        conn,
        "select text, origin, blank from transcript_revisions
         where account_id = $1::uuid and id = $2::uuid",
        [database.text(account_id), database.text(id)],
        {
          use text <- decode.field(0, decode.string)
          use origin <- decode.field(1, decode.string)
          use blank <- decode.field(2, decode.bool)
          decode.success(#(text, origin, blank))
        },
      )
      |> result.map_error(error.from_query)
  })
  use candidate <- result.try(ocr_candidate(conn, account_id, page))
  use operation <- result.try(latest_operation(conn, account_id, page.id))
  let transcript_json = case transcript {
    None -> json.null()
    Some(#(text, origin, blank)) ->
      json.object([
        #("transcript_revision_id", context.optional_string(page.transcript_revision_id)),
        #("text", json.string(text)),
        #("origin", json.string(origin)),
        #("blank", json.bool(blank)),
      ])
  }
  Ok(
    json.object([
      #("page", to_json(page)),
      #("transcript", transcript_json),
      #("ocr_candidate", candidate),
      #("latest_operation", operation),
    ]),
  )
}

/// A newer OCR result on the active source that was not selected because the
/// transcript carries user edits (explicit acceptance required).
fn ocr_candidate(
  conn: Connection,
  account_id: String,
  page: Page,
) -> Result(json.Json, AppError) {
  case page.revision_id {
    None -> Ok(json.null())
    Some(revision_id) -> {
      use row <- db(database.query_one(
        conn,
        "select o.id::text, o.raw_text, o.recognition_outcome
         from ocr_results o
         where o.account_id = $1::uuid and o.revision_id = $2::uuid
           and not exists (
             select 1 from transcript_revisions t
             where t.account_id = o.account_id and t.ocr_result_id = o.id)
         order by o.created_at desc limit 1",
        [database.text(account_id), database.text(revision_id)],
        {
          use id <- decode.field(0, decode.string)
          use text <- decode.field(1, decode.string)
          use outcome <- decode.field(2, decode.string)
          decode.success(#(id, text, outcome))
        },
      ))
      case row {
        None -> Ok(json.null())
        Some(#(id, text, outcome)) ->
          Ok(json.object([
            #("ocr_result_id", json.string(id)),
            #("text", json.string(text)),
            #("recognition_outcome", json.string(outcome)),
          ]))
      }
    }
  }
}

fn latest_operation(
  conn: Connection,
  account_id: String,
  page_id: String,
) -> Result(json.Json, AppError) {
  use row <- db(database.query_one(
    conn,
    "select id::text from operations where account_id = $1::uuid
       and page_id = $2::uuid order by created_at desc limit 1",
    [database.text(account_id), database.text(page_id)],
    decode.at([0], decode.string),
  ))
  case row {
    None -> Ok(json.null())
    Some(id) -> {
      use op <- result.try(operations.load(conn, account_id, id, False))
      case op {
        Some(op) -> Ok(operations.to_json(op, []))
        None -> Ok(json.null())
      }
    }
  }
}

/// Ordered page list for a notebook. The cursor is the last page number.
pub fn list_for_notebook(
  conn: Connection,
  account_id: String,
  notebook_id: String,
  after_number: Int,
  limit: Int,
) -> Result(List(Page), AppError) {
  use rows <- db(database.query(
    conn,
    select_page
      <> " where p.account_id = $1::uuid and p.notebook_id = $2::uuid
           and p.visibility = 'active' and n.deleted_at is null
           and p.page_number > $3
         order by p.page_number limit $4",
    [
      database.text(account_id),
      database.text(notebook_id),
      database.int(after_number),
      database.int(limit),
    ],
    page_decoder(),
  ))
  Ok(rows)
}

/// Trashed pages (and notebooks) for the trash listing.
pub fn list_trashed(
  conn: Connection,
  account_id: String,
  after_id: String,
  limit: Int,
) -> Result(List(Page), AppError) {
  use rows <- db(database.query(
    conn,
    select_page
      <> " where p.account_id = $1::uuid and p.visibility = 'trashed'
           and p.purge_requested_at is null
           and p.id > $2::uuid order by p.id limit $3",
    [database.text(account_id), database.text(after_id), database.int(limit)],
    page_decoder(),
  ))
  Ok(rows)
}

/// Active pages uploaded with deferred processing that still wait for it,
/// in stable notebook/page order (the order `process-deferred` admits).
pub fn list_awaiting_processing(
  conn: Connection,
  account_id: String,
  limit: Int,
) -> Result(List(Page), AppError) {
  use rows <- db(database.query(
    conn,
    select_page
      <> " where p.account_id = $1::uuid and p.visibility = 'active'
           and n.deleted_at is null and p.awaiting_processing
           and p.active_revision_id is not null
         order by n.name, p.notebook_id, p.page_number limit $2",
    [database.text(account_id), database.int(limit)],
    page_decoder(),
  ))
  Ok(rows)
}

/// How many active pages wait for deferred processing.
pub fn count_awaiting_processing(conn: Connection, account_id: String) -> Result(Int, AppError) {
  use count <- error.found(database.query_one(
    conn,
    "select count(*)::int from pages p join notebooks n on n.id = p.notebook_id
     where p.account_id = $1::uuid and p.visibility = 'active'
       and n.deleted_at is null and p.awaiting_processing",
    [database.text(account_id)],
    decode.at([0], decode.int),
  ))
  Ok(count)
}

// Locking helpers ------------------------------------------------------------

/// Lock notebooks in ID order (level 4); returns those found active.
pub fn lock_notebooks(
  conn: Connection,
  account_id: String,
  notebook_ids: List(String),
) -> Result(List(#(String, Bool)), AppError) {
  let ids = notebook_ids |> list.unique |> list.sort(string.compare)
  use rows <- db(database.query(
    conn,
    "select id::text, deleted_at is null from notebooks
     where account_id = $1::uuid and id = any($2::uuid[])
     order by id for update",
    [database.text(account_id), database.text_array(ids)],
    {
      use id <- decode.field(0, decode.string)
      use active <- decode.field(1, decode.bool)
      decode.success(#(id, active))
    },
  ))
  Ok(rows)
}

fn require_active_notebook(
  locked: List(#(String, Bool)),
  notebook_id: String,
) -> Result(Nil, AppError) {
  case list.key_find(locked, notebook_id) {
    Ok(True) -> Ok(Nil)
    _ -> Error(error.not_found())
  }
}

/// Lock page rows in ID order (level 5).
pub fn lock_pages(
  conn: Connection,
  account_id: String,
  page_ids: List(String),
) -> Result(Nil, AppError) {
  let ids = page_ids |> list.unique |> list.sort(string.compare)
  use _ <- db(database.execute(
    conn,
    "select 1 from pages where account_id = $1::uuid and id = any($2::uuid[])
     order by id for update",
    [database.text(account_id), database.text_array(ids)],
  ))
  Ok(Nil)
}

fn page_notebook(
  conn: Connection,
  account_id: String,
  page_id: String,
) -> Result(String, AppError) {
  use notebook_id <- error.found(database.query_one(
    conn,
    "select notebook_id::text from pages where account_id = $1::uuid and id = $2::uuid",
    [database.text(account_id), database.text(page_id)],
    decode.at([0], decode.string),
  ))
  Ok(notebook_id)
}

/// Whether a page number is held by any non-trashed page (active,
/// placeholder or restore claim) other than `except_page`.
pub fn number_holder(
  conn: Connection,
  notebook_id: String,
  page_number: Int,
  except_page: String,
) -> Result(Option(#(String, String)), AppError) {
  use row <- db(database.query_one(
    conn,
    "select id::text, visibility from pages
     where notebook_id = $1::uuid and page_number = $2
       and visibility <> 'trashed' and id <> $3::uuid",
    [
      database.text(notebook_id),
      database.int(page_number),
      database.text(except_page),
    ],
    {
      use id <- decode.field(0, decode.string)
      use visibility <- decode.field(1, decode.string)
      decode.success(#(id, visibility))
    },
  ))
  Ok(row)
}

fn number_conflict(holder: #(String, String), number: Int) -> AppError {
  let #(id, visibility) = holder
  error.page_number_conflict([
    #("page_number", json.int(number)),
    #("held_by", json.object([
      #("page_id", json.string(id)),
      #("visibility", json.string(visibility)),
    ])),
  ])
}

// Attribution edits ------------------------------------------------------------

pub type PageChange {
  PageChange(page_number: Option(Int), notebook_id: Option(String))
}

pub fn change_decoder() -> decode.Decoder(PageChange) {
  use page_number <- decode.optional_field("page_number", None, decode.optional(decode.int))
  use notebook_id <- decode.optional_field("notebook_id", None, decode.optional(decode.string))
  decode.success(PageChange(page_number:, notebook_id:))
}

/// Rename (renumber) or move a page. Requires If-Match on `version`.
pub fn update(
  ctx: Context,
  account_id: String,
  page_id: String,
  if_match: Option(Int),
  change: PageChange,
) -> Result(Page, AppError) {
  use expected <- result.try(option.to_result(if_match, error.precondition_required()))
  use <- error.guard(
    case change.page_number {
      Some(n) -> n > 0
      None -> True
    },
    error.unprocessable("page_number must be a positive integer"),
  )
  use _ <- result.try(case change.notebook_id {
    Some(id) -> context.require_uuid(id, fn(_) { Ok(Nil) })
    None -> Ok(Nil)
  })
  context.transaction(ctx, fn(tx) {
    use _ <- result.try(accounts.lock_active(tx, account_id))
    use _ <- result.try(expiry.require_clean(tx, account_id, ctx.config.lazy_expiry_batch))
    use current_notebook <- result.try(page_notebook(tx, account_id, page_id))
    let destination = option.unwrap(change.notebook_id, current_notebook)
    use locked <- result.try(lock_notebooks(tx, account_id, [current_notebook, destination]))
    use _ <- result.try(require_active_notebook(locked, current_notebook))
    use _ <- result.try(require_active_notebook(locked, destination))
    use _ <- result.try(lock_pages(tx, account_id, [page_id]))
    use page <- result.try(get(tx, account_id, page_id))
    use <- error.guard(page.version == expected, error.version_conflict())
    let number = option.unwrap(change.page_number, page.page_number)
    use holder <- result.try(number_holder(tx, destination, number, page_id))
    use _ <- result.try(case holder {
      Some(h) -> Error(number_conflict(h, number))
      None -> Ok(Nil)
    })
    case number == page.page_number && destination == page.notebook_id {
      True -> Ok(page)
      False -> {
        use _ <- db(database.execute(
          tx,
          "update pages set notebook_id = $3::uuid, page_number = $4,
             version = version + 1, updated_at = now()
           where account_id = $1::uuid and id = $2::uuid",
          [
            database.text(account_id),
            database.text(page_id),
            database.text(destination),
            database.int(number),
          ],
        ))
        use _ <- result.try(operations.bump_numbering(tx, account_id, page.notebook_id))
        use _ <- result.try(case destination == page.notebook_id {
          True -> Ok(Nil)
          False -> operations.bump_numbering(tx, account_id, destination)
        })
        get(tx, account_id, page_id)
      }
    }
  })
}

// Trash and restore ------------------------------------------------------------

/// Trash an active page: hide it immediately, decrement stored usage once,
/// cancel pending work (no refund of consumed units) and journal the intent.
pub fn trash(
  ctx: Context,
  account_id: String,
  page_id: String,
  if_match: Option(Int),
) -> Result(#(Page, journal.Intent), AppError) {
  context.transaction(ctx, fn(tx) {
    use _ <- result.try(accounts.lock_readable(tx, account_id))
    use _ <- result.try(quota.lock_usage(tx, account_id))
    use _ <- db(jobs.lock_account_slots(tx, account_id))
    use notebook_id <- result.try(page_notebook(tx, account_id, page_id))
    use locked <- result.try(lock_notebooks(tx, account_id, [notebook_id]))
    use _ <- result.try(require_active_notebook(locked, notebook_id))
    use _ <- result.try(lock_pages(tx, account_id, [page_id]))
    use page <- result.try(get(tx, account_id, page_id))
    use <- error.guard(
      case if_match {
        Some(v) -> v == page.version
        None -> True
      },
      error.version_conflict(),
    )
    use pending <- result.try(journal.pending_for_scope(tx, account_id, page_id))
    use <- error.guard(!pending, recovery_pending())
    use live <- result.try(operations.live_for_page(tx, account_id, page_id))
    use _ <- result.try(case live {
      Some(op) ->
        operations.end_accepted(tx, account_id, op, "deleted", None, None)
      None -> Ok(Nil)
    })
    let batch = uuid.v7_string()
    use _ <- db(database.execute(
      tx,
      "update pages set visibility = 'trashed', deleted_at = now(),
         deletion_batch_id = $3::uuid, awaiting_processing = false,
         version = version + 1, updated_at = now()
       where account_id = $1::uuid and id = $2::uuid",
      [database.text(account_id), database.text(page_id), database.text(batch)],
    ))
    use _ <- result.try(quota.adjust_usage(tx, account_id, -1, 0, 0))
    use _ <- result.try(operations.bump_numbering(tx, account_id, notebook_id))
    use _ <- result.try(accounts.record_content_change(tx, account_id, page_id, "trash"))
    use intent <- result.try(journal.record(
      tx,
      account_id,
      "page",
      page_id,
      page.version + 1,
      "trash",
      [#("page_ids", json.array([page_id], json.string))],
    ))
    use page <- result.try(get_any(tx, account_id, page_id))
    Ok(#(page, intent))
  })
}

pub fn recovery_pending() -> AppError {
  error.new(
    409,
    "recovery_pending",
    "A lifecycle change for this item is awaiting durable confirmation.",
  )
}

pub type RestoreTarget {
  RestoreTarget(notebook_id: Option(String), page_number: Option(Int))
}

pub fn restore_decoder() -> decode.Decoder(RestoreTarget) {
  use notebook_id <- decode.optional_field("notebook_id", None, decode.optional(decode.string))
  use page_number <- decode.optional_field("page_number", None, decode.optional(decode.int))
  decode.success(RestoreTarget(notebook_id:, page_number:))
}

/// Restore a trashed page. Capacity and the target number are claimed
/// immediately (`restore_pending`); the page becomes active only after the
/// compensating journal entry is durable.
pub fn restore(
  ctx: Context,
  account_id: String,
  page_id: String,
  target: RestoreTarget,
) -> Result(#(Page, journal.Intent), AppError) {
  context.transaction(ctx, fn(tx) {
    use _ <- result.try(accounts.lock_active(tx, account_id))
    use _ <- result.try(expiry.require_clean(tx, account_id, ctx.config.lazy_expiry_batch))
    use usage <- result.try(quota.lock_usage(tx, account_id))
    use ent <- result.try(quota.entitlement(tx, ctx.config, account_id))
    use current_notebook <- result.try(page_notebook(tx, account_id, page_id))
    let destination = option.unwrap(target.notebook_id, current_notebook)
    use locked <- result.try(lock_notebooks(tx, account_id, [current_notebook, destination]))
    use _ <- result.try(require_active_notebook(locked, destination))
    use _ <- result.try(lock_pages(tx, account_id, [page_id]))
    use page <- result.try(get_any(tx, account_id, page_id))
    use <- error.guard(page.visibility == "trashed", error.not_found())
    use pending <- result.try(journal.pending_for_scope(tx, account_id, page_id))
    use <- error.guard(!pending, recovery_pending())
    use _ <- result.try(quota.require_page_capacity(usage, ent, 1))
    let number = option.unwrap(target.page_number, page.page_number)
    use <- error.guard(number > 0, error.unprocessable("page_number must be positive"))
    use holder <- result.try(number_holder(tx, destination, number, page_id))
    use _ <- result.try(case holder {
      Some(h) ->
        Error(
          error.new(409, "restore_conflict", "The page number is now in use.")
          |> error.with_details([
            #("conflicts", json.array([page_id], fn(id) {
              json.object([
                #("page_id", json.string(id)),
                #("page_number", json.int(number)),
                #("held_by", json.string(h.0)),
              ])
            })),
          ]),
        )
      None -> Ok(Nil)
    })
    use _ <- db(database.execute(
      tx,
      "update pages set visibility = 'restore_pending', notebook_id = $3::uuid,
         page_number = $4, version = version + 1, updated_at = now()
       where account_id = $1::uuid and id = $2::uuid",
      [
        database.text(account_id),
        database.text(page_id),
        database.text(destination),
        database.int(number),
      ],
    ))
    use _ <- result.try(quota.adjust_usage(tx, account_id, 0, 1, 0))
    use _ <- result.try(operations.bump_numbering(tx, account_id, destination))
    use _ <- result.try(case destination == current_notebook {
      True -> Ok(Nil)
      False -> operations.bump_numbering(tx, account_id, current_notebook)
    })
    use intent <- result.try(journal.record(
      tx,
      account_id,
      "page",
      page_id,
      page.version + 1,
      "restore",
      [
        #("pages", json.array([#(page_id, destination, number)], fn(p) {
          json.object([
            #("page_id", json.string(p.0)),
            #("notebook_id", json.string(p.1)),
            #("page_number", json.int(p.2)),
          ])
        })),
      ],
    ))
    use page <- result.try(get_any(tx, account_id, page_id))
    Ok(#(page, intent))
  })
}

/// After the journal acknowledges a restore intent, convert its claims into
/// active stored pages atomically. Idempotent.
pub fn activate_restore(
  ctx: Context,
  account_id: String,
  page_ids: List(String),
) -> Result(Int, AppError) {
  context.transaction(ctx, fn(tx) {
    use _ <- result.try(accounts.lock(tx, account_id))
    use _ <- result.try(quota.lock_usage(tx, account_id))
    use notebooks <- db(database.query(
      tx,
      "select distinct notebook_id::text from pages
       where account_id = $1::uuid and id = any($2::uuid[])",
      [database.text(account_id), database.text_array(page_ids)],
      decode.at([0], decode.string),
    ))
    use _ <- result.try(lock_notebooks(tx, account_id, notebooks))
    use _ <- result.try(lock_pages(tx, account_id, page_ids))
    use activated <- db(database.query(
      tx,
      "update pages set visibility = 'active', deleted_at = null,
         deletion_batch_id = null, version = version + 1, updated_at = now()
       where account_id = $1::uuid and id = any($2::uuid[])
         and visibility = 'restore_pending'
       returning id::text",
      [database.text(account_id), database.text_array(page_ids)],
      decode.at([0], decode.string),
    ))
    let n = list.length(activated)
    use _ <- result.try(case n {
      0 -> Ok(Nil)
      _ -> quota.adjust_usage(tx, account_id, n, 0 - n, 0)
    })
    use _ <- result.try(list.try_each(notebooks, fn(id) {
      operations.bump_numbering(tx, account_id, id)
    }))
    use _ <- result.try(list.try_each(activated, fn(id) {
      accounts.record_content_change(tx, account_id, id, "restore")
    }))
    Ok(n)
  })
}

// Bulk renumbering ---------------------------------------------------------------

pub type RenumberPlan {
  Shift(from: Int, to: Int, by: Int)
  Mapping(entries: List(#(String, Int, Int)))
}

pub fn renumber_decoder() -> decode.Decoder(RenumberPlan) {
  let shift = {
    use from <- decode.subfield(["shift", "from"], decode.int)
    use to <- decode.subfield(["shift", "to"], decode.int)
    use by <- decode.subfield(["shift", "by"], decode.int)
    decode.success(Shift(from:, to:, by:))
  }
  let mapping = {
    use entries <- decode.field(
      "mapping",
      decode.list({
        use page_id <- decode.field("page_id", decode.string)
        use number <- decode.field("page_number", decode.int)
        use version <- decode.field("version", decode.int)
        decode.success(#(page_id, number, version))
      }),
    )
    decode.success(Mapping(entries))
  }
  decode.one_of(shift, [mapping])
}

pub type Numbering {
  Numbering(notebook_id: String, numbering_revision: Int, pages: List(#(String, Int, Int)))
}

pub fn numbering(
  conn: Connection,
  account_id: String,
  notebook_id: String,
) -> Result(Numbering, AppError) {
  use revision <- error.found(database.query_one(
    conn,
    "select numbering_revision from notebooks
     where account_id = $1::uuid and id = $2::uuid and deleted_at is null",
    [database.text(account_id), database.text(notebook_id)],
    decode.at([0], decode.int),
  ))
  use pages <- db(database.query(
    conn,
    "select id::text, page_number, version from pages
     where account_id = $1::uuid and notebook_id = $2::uuid and visibility = 'active'
     order by page_number limit 10000",
    [database.text(account_id), database.text(notebook_id)],
    {
      use id <- decode.field(0, decode.string)
      use number <- decode.field(1, decode.int)
      use version <- decode.field(2, decode.int)
      decode.success(#(id, number, version))
    },
  ))
  Ok(Numbering(notebook_id, revision, pages))
}

pub fn numbering_etag(revision: Int) -> String {
  "\"n" <> int.to_string(revision) <> "\""
}

pub fn numbering_json(numbering: Numbering) -> json.Json {
  json.object([
    #("notebook_id", json.string(numbering.notebook_id)),
    #("numbering_revision", json.int(numbering.numbering_revision)),
    #("pages", json.array(numbering.pages, fn(p) {
      json.object([
        #("page_id", json.string(p.0)),
        #("page_number", json.int(p.1)),
        #("version", json.int(p.2)),
      ])
    })),
  ])
}

type Holder {
  Holder(id: String, number: Int, version: Int, visibility: String)
}

/// Apply a range shift or explicit mapping atomically. Validation is scoped
/// to the pages the plan touches; the uniqueness constraint is deferred to
/// commit so swaps and shifts never hit intermediate collisions.
pub fn renumber(
  ctx: Context,
  account_id: String,
  notebook_id: String,
  plan: RenumberPlan,
  expected_numbering: Option(Int),
) -> Result(#(List(json.Json), Int), AppError) {
  context.transaction(ctx, fn(tx) {
    use _ <- result.try(accounts.lock_active(tx, account_id))
    use _ <- result.try(expiry.require_clean(tx, account_id, ctx.config.lazy_expiry_batch))
    use locked <- result.try(lock_notebooks(tx, account_id, [notebook_id]))
    use _ <- result.try(require_active_notebook(locked, notebook_id))
    use revision <- error.found(database.query_one(
      tx,
      "select numbering_revision from notebooks where id = $1::uuid",
      [database.text(notebook_id)],
      decode.at([0], decode.int),
    ))
    use <- error.guard(
      case expected_numbering {
        Some(n) -> n == revision
        None -> True
      },
      error.version_conflict(),
    )
    // Lock every non-trashed page of the notebook in ID order: this covers
    // the affected set and every holder of a potential target number.
    use holders <- db(database.query(
      tx,
      "select id::text, page_number, version, visibility from pages
       where account_id = $1::uuid and notebook_id = $2::uuid
         and visibility <> 'trashed'
       order by id for update",
      [database.text(account_id), database.text(notebook_id)],
      {
        use id <- decode.field(0, decode.string)
        use number <- decode.field(1, decode.int)
        use version <- decode.field(2, decode.int)
        use visibility <- decode.field(3, decode.string)
        decode.success(Holder(id, number, version, visibility))
      },
    ))
    use moves <- result.try(plan_moves(plan, holders))
    let moving = moves |> list.map(fn(m) { m.0 }) |> set.from_list
    let final =
      holders
      |> list.map(fn(h) {
        case list.find(moves, fn(m) { m.0 == h.id }) {
          Ok(#(_, number)) -> #(h, number)
          Error(_) -> #(h, h.number)
        }
      })
    let conflicts =
      final
      |> list.group(fn(entry) { entry.1 })
      |> dict.to_list
      |> list.filter(fn(group) { list.length(group.1) > 1 })
      |> list.flat_map(fn(group) {
        group.1
        |> list.filter(fn(entry) { !set.contains(moving, { entry.0 }.id) })
        |> list.map(fn(entry) {
          json.object([
            #("page_number", json.int(group.0)),
            #("held_by", json.string({ entry.0 }.id)),
            #("visibility", json.string({ entry.0 }.visibility)),
          ])
        })
      })
      |> list.take(20)
    use <- error.guard(
      conflicts == [],
      error.page_number_conflict([#("conflicts", json.preprocessed_array(conflicts))]),
    )
    use _ <- db(database.execute(tx, "set constraints pages_number_unique deferred", []))
    let changed =
      final
      |> list.filter(fn(entry) { { entry.0 }.number != entry.1 })
    use moved <- result.try(list.try_map(changed, fn(entry) {
      let #(holder, number) = entry
      use _ <- db(database.execute(
        tx,
        "update pages set page_number = $3, version = version + 1, updated_at = now()
         where account_id = $1::uuid and id = $2::uuid",
        [database.text(account_id), database.text(holder.id), database.int(number)],
      ))
      Ok(json.object([
        #("page_id", json.string(holder.id)),
        #("from", json.int(holder.number)),
        #("to", json.int(number)),
        #("version", json.int(holder.version + 1)),
      ]))
    }))
    case moved {
      [] -> Ok(#([], revision))
      _ -> {
        use _ <- result.try(operations.bump_numbering(tx, account_id, notebook_id))
        Ok(#(moved, revision + 1))
      }
    }
  })
}

fn plan_moves(
  plan: RenumberPlan,
  holders: List(Holder),
) -> Result(List(#(String, Int)), AppError) {
  case plan {
    Shift(from:, to:, by:) -> {
      use <- error.guard(
        from > 0 && to >= from && by != 0,
        error.unprocessable("shift requires 0 < from <= to and a non-zero offset"),
      )
      let moves =
        holders
        |> list.filter(fn(h) {
          h.visibility == "active" && h.number >= from && h.number <= to
        })
        |> list.map(fn(h) { #(h.id, h.number + by) })
      use <- error.guard(
        list.all(moves, fn(m) { m.1 > 0 }),
        error.unprocessable("page numbers must stay positive"),
      )
      Ok(moves)
    }
    Mapping(entries) -> {
      use <- error.guard(entries != [], error.unprocessable("mapping is empty"))
      use <- error.guard(
        list.all(entries, fn(e) { e.1 > 0 }),
        error.unprocessable("page numbers must be positive"),
      )
      use <- error.guard(
        list.length(list.unique(list.map(entries, fn(e) { e.0 })))
          == list.length(entries),
        error.unprocessable("a page appears twice in the mapping"),
      )
      list.try_map(entries, fn(entry) {
        let #(page_id, number, version) = entry
        case list.find(holders, fn(h) { h.id == string.lowercase(page_id) }) {
          Ok(h) if h.visibility == "active" && h.version == version ->
            Ok(#(h.id, number))
          // Changed or left the notebook since the plan was built.
          _ -> Error(error.version_conflict())
        }
      })
    }
  }
}

/// One past the highest page number held in a notebook (active pages,
/// placeholders and restore claims), the default start for new uploads.
pub fn next_page_number(
  conn: Connection,
  account_id: String,
  notebook_id: String,
) -> Result(Int, AppError) {
  use n <- error.found(database.query_one(
    conn,
    "select coalesce(max(page_number), 0) + 1 from pages
     where account_id = $1::uuid and notebook_id = $2::uuid and visibility <> 'trashed'",
    [database.text(account_id), database.text(notebook_id)],
    decode.at([0], decode.int),
  ))
  Ok(n)
}
