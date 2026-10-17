//// Consistent, durable user exports (section 14).
////
//// Admission materializes `export_items` from one database snapshot and pins
//// the source objects and transcript revisions in the same transaction.
//// Assembly reads only that immutable manifest and its pinned artifacts, so
//// later corrections, moves, renumbering, replacement or trash never change
//// an export. Items pack into ordered ZIP64 parts of at most
//// `part_bytes` (a page is never split); every part carries the full
//// metadata index and only its own items' images and transcripts.
////
//// Completed exports are retained for exactly seven days from whole-export
//// completion; URL issuance and downloads never change retention.

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import libarrie/database
import libarrie/domain/accounts
import libarrie/domain/closure
import libarrie/domain/context.{type Context}
import libarrie/domain/error.{type AppError, db}
import libarrie/domain/pins
import libarrie/integrations/storage
import libarrie/integrations/zip
import libarrie/jobs.{type Job}
import youid/uuid

pub type Request {
  Request(notebook_ids: Option(List(String)), include_trash: Bool)
}

pub fn decoder() -> decode.Decoder(Request) {
  use notebook_ids <- decode.optional_field(
    "notebook_ids",
    None,
    decode.optional(decode.list(decode.string)),
  )
  use include_trash <- decode.optional_field("include_trash", False, decode.bool)
  decode.success(Request(
    option.map(notebook_ids, list.map(_, string.lowercase)),
    include_trash,
  ))
}

/// Default execution deadline: 24 hours plus one hour per 5,000 pages,
/// capped at 72 hours.
pub fn execution_deadline_seconds(item_count: Int) -> Int {
  int.min(72 * 3600, 24 * 3600 + { item_count + 4999 } / 5000 * 3600)
}

/// Greedy packing in manifest order; a page is never split, and a page
/// larger than the limit gets a part of its own.
pub fn assign_parts(sizes: List(Int), limit: Int) -> List(Int) {
  let #(parts, _, _) =
    list.fold(sizes, #([], 1, 0), fn(state, size) {
      let #(acc, part, used) = state
      case used > 0 && used + size > limit {
        True -> #([part + 1, ..acc], part + 1, size)
        False -> #([part, ..acc], part, used + size)
      }
    })
  list.reverse(parts)
}

/// Per-entry archive overhead estimate (headers, names, transcript text).
const entry_overhead = 4096

// Admission -----------------------------------------------------------------------------

/// `POST /v1/exports`.
pub fn create(
  ctx: Context,
  account_id: String,
  request: Request,
) -> Result(json.Json, AppError) {
  use <- error.guard(
    case request.notebook_ids {
      Some(ids) -> ids != [] && list.all(ids, context.is_uuid)
      None -> True
    },
    error.bad_request("notebook_ids must be a non-empty list of UUIDs"),
  )
  let export_id = uuid.v7_string()
  use _ <- result.try(context.transaction(ctx, fn(tx) {
    // Exports remain available during the closure grace period.
    use _ <- result.try(accounts.lock_readable(tx, account_id))
    use _ <- db(jobs.lock_account_slots(tx, account_id))
    use running <- error.found(database.query_one(
      tx,
      "select count(*)::int from exports where account_id = $1::uuid and state = 'assembling'",
      [database.text(account_id)],
      decode.at([0], decode.int),
    ))
    use <- error.guard(
      running < ctx.config.exports.max_concurrent,
      error.new(
        409,
        "operational_limit_reached",
        "Too many exports are assembling; wait for one to finish.",
      ),
    )
    use _ <- result.try(case request.notebook_ids {
      Some(ids) -> {
        use owned <- error.found(database.query_one(
          tx,
          "select count(*)::int from notebooks where account_id = $1::uuid
             and id = any($2::uuid[]) and purge_requested_at is null
             and ($3 or deleted_at is null)",
          [
            database.text(account_id),
            database.text_array(ids),
            database.bool(request.include_trash),
          ],
          decode.at([0], decode.int),
        ))
        case owned == list.length(list.unique(ids)) {
          True -> Ok(Nil)
          False -> Error(error.not_found())
        }
      }
      None -> Ok(Nil)
    })
    use _ <- db(database.execute(
      tx,
      "insert into exports (id, account_id, state, include_trash, notebook_ids,
         execution_deadline, part_size_limit)
       values ($1::uuid, $2::uuid, 'assembling', $3, $4::uuid[], now(), $5)",
      [
        database.text(export_id),
        database.text(account_id),
        database.bool(request.include_trash),
        case request.notebook_ids {
          Some(ids) -> database.text_array(ids)
          None -> database.null()
        },
        database.int(ctx.config.exports.part_bytes),
      ],
    ))
    // One consistent snapshot of the manifest.
    use count <- db(database.execute(
      tx,
      "insert into export_items (export_id, ordinal, page_id, notebook_id, notebook_name,
         page_number, visibility, source_revision_id, transcript_revision_id,
         object_id, object_key, content_type, bytes, checksum, processing_status)
       select $1::uuid,
         row_number() over (order by n.created_at, n.id, p.visibility, p.page_number, p.id)::int,
         p.id, n.id, n.name, p.page_number, p.visibility, r.id,
         r.selected_transcript_revision_id, o.id, o.key, o.content_type, o.bytes,
         o.checksum,
         case when p.awaiting_processing then 'awaiting_processing'
              when r.selected_transcript_revision_id is null then 'absent_transcript'
              else r.status end
       from pages p
       join notebooks n on n.id = p.notebook_id
       join page_revisions r on r.id = p.active_revision_id
       join objects o on o.id = r.source_object_id and o.state = 'stored'
       where p.account_id = $2::uuid and p.purge_requested_at is null
         and n.purge_requested_at is null
         and ($4::uuid[] is null or n.id = any($4::uuid[]))
         and ((p.visibility = 'active' and n.deleted_at is null)
           or ($3 and p.visibility = 'trashed'))",
      [
        database.text(export_id),
        database.text(account_id),
        database.bool(request.include_trash),
        case request.notebook_ids {
          Some(ids) -> database.text_array(ids)
          None -> database.null()
        },
      ],
    ))
    use sizes <- db(database.query(
      tx,
      "select bytes from export_items where export_id = $1::uuid order by ordinal",
      [database.text(export_id)],
      decode.at([0], decode.int),
    ))
    let parts =
      assign_parts(
        list.map(sizes, fn(b) { b + entry_overhead }),
        ctx.config.exports.part_bytes,
      )
    let part_count = list.fold(parts, 1, int.max)
    use _ <- db(database.execute(
      tx,
      "update export_items e set part_number = v.part
       from unnest($2::int[], $3::int[]) as v(ordinal, part)
       where e.export_id = $1::uuid and e.ordinal = v.ordinal",
      [
        database.text(export_id),
        int_array(list.index_map(parts, fn(_, i) { i + 1 })),
        int_array(parts),
      ],
    ))
    let deadline = execution_deadline_seconds(count)
    use _ <- db(database.execute(
      tx,
      "update exports set part_count = $2, item_count = $3,
         total_bytes = (select coalesce(sum(bytes), 0) from export_items where export_id = $1::uuid),
         execution_deadline = now() + make_interval(secs => $4)
       where id = $1::uuid",
      [
        database.text(export_id),
        database.int(part_count),
        database.int(count),
        database.int(deadline),
      ],
    ))
    // Pins use the same protocol as garbage collection.
    use _ <- db(database.execute(
      tx,
      "insert into artifact_pins (owner_kind, owner_id, artifact_kind, artifact_id, expires_at)
       select 'export', $1::uuid, 'object', object_id, now() + make_interval(secs => $2 + 86400)
       from export_items where export_id = $1::uuid
       union
       select 'export', $1::uuid, 'transcript_revision', transcript_revision_id,
         now() + make_interval(secs => $2 + 86400)
       from export_items where export_id = $1::uuid and transcript_revision_id is not null
       on conflict do nothing",
      [database.text(export_id), database.int(deadline)],
    ))
    use _ <- result.try(closure.extend_for_export(ctx, tx, account_id, deadline))
    try_range(1, part_count, fn(part) {
      use _ <- db(database.execute(
        tx,
        "insert into export_parts (export_id, part_number, key, item_count)
         values ($1::uuid, $2, $3,
           (select count(*)::int from export_items where export_id = $1::uuid and part_number = $2))",
        [
          database.text(export_id),
          database.int(part),
          database.text(part_key(account_id, export_id, part)),
        ],
      ))
      use _ <- db(jobs.enqueue(
        tx,
        jobs.NewJob(
          ..jobs.new_job(
            "export_part",
            "export:" <> export_id <> ":part:" <> int.to_string(part) <> ":g0",
          ),
          account_id: Some(account_id),
          operation_id: Some(export_id),
          payload: json.object([#("part", json.int(part))]),
          deadline_seconds: Some(3600),
        ),
      ))
      Ok(Nil)
    })
  }))
  get(ctx, account_id, export_id)
}

fn int_array(values: List(Int)) -> database.Value {
  database.int_array(values)
}

fn try_range(
  from: Int,
  to: Int,
  f: fn(Int) -> Result(Nil, AppError),
) -> Result(Nil, AppError) {
  case from > to {
    True -> Ok(Nil)
    False -> {
      use _ <- result.try(f(from))
      try_range(from + 1, to, f)
    }
  }
}

fn part_key(account_id: String, export_id: String, part: Int) -> String {
  "exports/" <> account_id <> "/" <> export_id <> "/part-" <> pad(part, 4) <> ".zip"
}

fn pad(n: Int, width: Int) -> String {
  string.pad_start(int.to_string(n), width, "0")
}

// Reads ------------------------------------------------------------------------------------

const export_columns = "id::text, state, include_trash, rfc3339(snapshot_at),
  rfc3339(execution_deadline), rfc3339(completed_at), rfc3339(expires_at),
  manifest_version, part_count, item_count, total_bytes, error_code,
  rfc3339(created_at), expires_at is not null and expires_at <= now()"

fn export_decoder() -> decode.Decoder(#(String, String, json.Json)) {
  use id <- decode.field(0, decode.string)
  use state <- decode.field(1, decode.string)
  use include_trash <- decode.field(2, decode.bool)
  use snapshot_at <- decode.field(3, decode.string)
  use deadline <- decode.field(4, decode.string)
  use completed_at <- decode.field(5, decode.optional(decode.string))
  use expires_at <- decode.field(6, decode.optional(decode.string))
  use manifest_version <- decode.field(7, decode.int)
  use part_count <- decode.field(8, decode.int)
  use item_count <- decode.field(9, decode.int)
  use total_bytes <- decode.field(10, decode.int)
  use error_code <- decode.field(11, decode.optional(decode.string))
  use created_at <- decode.field(12, decode.string)
  use lapsed <- decode.field(13, decode.bool)
  let state = case state, lapsed {
    "completed", True -> "expired"
    s, _ -> s
  }
  decode.success(#(
    id,
    state,
    json.object([
      #("id", json.string(id)),
      #("state", json.string(state)),
      #("include_trash", json.bool(include_trash)),
      #("snapshot_at", json.string(snapshot_at)),
      #("execution_deadline", json.string(deadline)),
      #("completed_at", context.optional_string(completed_at)),
      #("expires_at", context.optional_string(expires_at)),
      #("manifest_version", json.int(manifest_version)),
      #("part_count", json.int(part_count)),
      #("item_count", json.int(item_count)),
      #("total_bytes", json.int(total_bytes)),
      #("error_code", context.optional_string(error_code)),
      #("created_at", json.string(created_at)),
    ]),
  ))
}

/// `GET /v1/exports/{id}`: status and part list.
pub fn get(ctx: Context, account_id: String, export_id: String) -> Result(json.Json, AppError) {
  use #(_, state, body) <- error.found(database.query_one(
    ctx.db,
    "select " <> export_columns <> " from exports where account_id = $1::uuid and id = $2::uuid",
    [database.text(account_id), database.text(export_id)],
    export_decoder(),
  ))
  use parts <- db(database.query(
    ctx.db,
    "select part_number, item_count, bytes, checksum, rfc3339(ready_at)
     from export_parts where export_id = $1::uuid order by part_number",
    [database.text(export_id)],
    {
      use n <- decode.field(0, decode.int)
      use items <- decode.field(1, decode.int)
      use bytes <- decode.field(2, decode.optional(decode.int))
      use checksum <- decode.field(3, decode.optional(decode.string))
      use ready <- decode.field(4, decode.optional(decode.string))
      decode.success(json.object([
        #("part_number", json.int(n)),
        #("item_count", json.int(items)),
        #("bytes", context.optional_int(bytes)),
        #("checksum_sha256", context.optional_string(checksum)),
        #("ready_at", context.optional_string(ready)),
        #("downloadable", json.bool(state == "completed")),
      ]))
    },
  ))
  Ok(json.object([#("export", body), #("parts", json.preprocessed_array(parts))]))
}

/// `GET /v1/exports`.
pub fn list(ctx: Context, account_id: String) -> Result(json.Json, AppError) {
  use rows <- db(database.query(
    ctx.db,
    "select " <> export_columns <> " from exports where account_id = $1::uuid
     order by created_at desc limit 50",
    [database.text(account_id)],
    export_decoder(),
  ))
  Ok(json.object([#("exports", json.preprocessed_array(list.map(rows, fn(r) { r.2 })))]))
}

/// `GET /v1/exports/{id}/parts/{n}/download-url`: reissuable while the
/// export is retained. Issuance is not a download receipt and never changes
/// retention. Clients resume with HTTP range requests on a fresh URL.
pub fn download_url(
  ctx: Context,
  account_id: String,
  export_id: String,
  part: Int,
) -> Result(json.Json, AppError) {
  use row <- error.found(database.query_one(
    ctx.db,
    "select p.key, p.bytes, p.checksum,
       e.state = 'completed' and e.expires_at > now()
         and a.status in ('active', 'closure_scheduled')
     from exports e join export_parts p on p.export_id = e.id
     join accounts a on a.id = e.account_id
     where e.account_id = $1::uuid and e.id = $2::uuid and p.part_number = $3",
    [database.text(account_id), database.text(export_id), database.int(part)],
    {
      use key <- decode.field(0, decode.string)
      use bytes <- decode.field(1, decode.optional(decode.int))
      use checksum <- decode.field(2, decode.optional(decode.string))
      use available <- decode.field(3, decode.bool)
      decode.success(#(key, bytes, checksum, available))
    },
  ))
  let #(key, bytes, checksum, available) = row
  use <- error.guard(
    available,
    error.new(409, "export_unavailable", "This export is not available for download."),
  )
  let name = "libarrie-export-" <> string.slice(export_id, 0, 8) <> "-part-" <> pad(part, 4) <> ".zip"
  let signed =
    storage.presign_download(
      ctx.config.storage,
      key,
      ctx.config.download_url_seconds,
      "private, no-store",
      Some(name),
    )
  Ok(json.object([
    #("url", json.string(signed.url)),
    #("expires_in_seconds", json.int(signed.expires_in_seconds)),
    #("bytes", context.optional_int(bytes)),
    #("checksum_sha256", context.optional_string(checksum)),
    #("supports_range_requests", json.bool(True)),
    #(
      "notice",
      json.string(
        "This bearer URL works until it expires; downloads already started cannot be recalled.",
      ),
    ),
  ]))
}

// Assembly ----------------------------------------------------------------------------------

pub type Item {
  Item(
    ordinal: Int,
    part_number: Int,
    page_id: String,
    notebook_id: String,
    notebook_name: String,
    page_number: Int,
    visibility: String,
    source_revision_id: String,
    transcript_revision_id: Option(String),
    object_id: String,
    object_key: String,
    content_type: String,
    bytes: Int,
    checksum: String,
    processing_status: String,
  )
}

fn item_decoder() -> decode.Decoder(Item) {
  use ordinal <- decode.field(0, decode.int)
  use part <- decode.field(1, decode.int)
  use page_id <- decode.field(2, decode.string)
  use notebook_id <- decode.field(3, decode.string)
  use notebook_name <- decode.field(4, decode.string)
  use page_number <- decode.field(5, decode.int)
  use visibility <- decode.field(6, decode.string)
  use source <- decode.field(7, decode.string)
  use transcript <- decode.field(8, decode.optional(decode.string))
  use object_id <- decode.field(9, decode.string)
  use key <- decode.field(10, decode.string)
  use content_type <- decode.field(11, decode.string)
  use bytes <- decode.field(12, decode.int)
  use checksum <- decode.field(13, decode.string)
  use status <- decode.field(14, decode.string)
  decode.success(Item(
    ordinal,
    part,
    page_id,
    notebook_id,
    notebook_name,
    page_number,
    visibility,
    source,
    transcript,
    object_id,
    key,
    content_type,
    bytes,
    checksum,
    status,
  ))
}

/// Sanitized, collision-free archive paths built from stable IDs.
pub fn image_path(item: Item) -> String {
  folder(item) <> "/" <> file_stem(item) <> "." <> extension(item.content_type)
}

pub fn transcript_path(item: Item) -> String {
  folder(item) <> "/" <> file_stem(item) <> ".txt"
}

fn folder(item: Item) -> String {
  let trash = case item.visibility {
    "trashed" -> "trash/"
    _ -> ""
  }
  "notebooks/" <> trash <> slug(item.notebook_name) <> "-" <> string.slice(item.notebook_id, 0, 8)
}

fn file_stem(item: Item) -> String {
  "page-" <> pad(item.page_number, 5) <> "-" <> item.page_id
}

fn extension(content_type: String) -> String {
  case content_type {
    "image/png" -> "png"
    _ -> "jpg"
  }
}

/// Lowercase ASCII letters, digits and single hyphens, at most 40 chars.
pub fn slug(name: String) -> String {
  let cleaned =
    name
    |> string.lowercase
    |> string.to_graphemes
    |> list.map(fn(c) {
      case string.contains("abcdefghijklmnopqrstuvwxyz0123456789", c) {
        True -> c
        False -> "-"
      }
    })
    |> string.concat
    |> string.split("-")
    |> list.filter(fn(s) { s != "" })
    |> string.join("-")
    |> string.slice(0, 40)
  case cleaned {
    "" -> "notebook"
    s -> s
  }
}

fn item_json(item: Item) -> json.Json {
  json.object([
    #("ordinal", json.int(item.ordinal)),
    #("part_number", json.int(item.part_number)),
    #("page_id", json.string(item.page_id)),
    #("notebook", json.object([
      #("id", json.string(item.notebook_id)),
      #("name", json.string(item.notebook_name)),
    ])),
    #("page_number", json.int(item.page_number)),
    #("visibility", json.string(item.visibility)),
    #("source_revision_id", json.string(item.source_revision_id)),
    #("transcript_revision_id", context.optional_string(item.transcript_revision_id)),
    #("object_id", json.string(item.object_id)),
    #("content_type", json.string(item.content_type)),
    #("bytes", json.int(item.bytes)),
    #("checksum_sha256", json.string(item.checksum)),
    #("processing_status", json.string(item.processing_status)),
    #("image_path", json.string(image_path(item))),
    #(
      "transcript_path",
      case item.transcript_revision_id {
        Some(_) -> json.string(transcript_path(item))
        None -> json.null()
      },
    ),
  ])
}

pub type AssemblyResult {
  Assembled(summary: String)
  Stale
  Failed(code: String)
  Unavailable
}

/// Output sink: buffers bytes and switches to a multipart upload once the
/// buffer reaches the chunk size, keeping memory bounded.
type Sink {
  Sink(
    key: String,
    chunk: Int,
    buffer: List(BitArray),
    buffered: Int,
    upload_id: Option(String),
    parts: List(#(Int, String)),
    hasher: crypto.Hasher,
    total: Int,
  )
}

fn sink_write(
  config: storage.Config,
  sink: Sink,
  bytes: BitArray,
) -> Result(Sink, Nil) {
  let size = bit_array.byte_size(bytes)
  let sink =
    Sink(
      ..sink,
      buffer: [bytes, ..sink.buffer],
      buffered: sink.buffered + size,
      hasher: crypto.hash_chunk(sink.hasher, bytes),
      total: sink.total + size,
    )
  case sink.buffered >= sink.chunk {
    False -> Ok(sink)
    True -> flush(config, sink)
  }
}

fn flush(config: storage.Config, sink: Sink) -> Result(Sink, Nil) {
  use upload_id <- result.try(case sink.upload_id {
    Some(id) -> Ok(id)
    None ->
      storage.create_multipart(config, sink.key, "application/zip")
      |> result.replace_error(Nil)
  })
  let number = list.length(sink.parts) + 1
  let body = sink.buffer |> list.reverse |> bit_array.concat
  use etag <- result.try(
    storage.upload_part(config, sink.key, upload_id, number, body)
    |> result.replace_error(Nil),
  )
  Ok(Sink(
    ..sink,
    buffer: [],
    buffered: 0,
    upload_id: Some(upload_id),
    parts: [#(number, etag), ..sink.parts],
  ))
}

fn sink_close(config: storage.Config, sink: Sink) -> Result(#(Int, String), Nil) {
  let checksum =
    crypto.digest(sink.hasher) |> bit_array.base16_encode |> string.lowercase
  case sink.upload_id {
    None -> {
      let body = sink.buffer |> list.reverse |> bit_array.concat
      use _ <- result.try(
        storage.put(config, sink.key, body, "application/zip") |> result.replace_error(Nil),
      )
      Ok(#(sink.total, checksum))
    }
    Some(_) -> {
      use sink <- result.try(case sink.buffered > 0 {
        True -> flush(config, sink)
        False -> Ok(sink)
      })
      let assert Some(upload_id) = sink.upload_id
      use _ <- result.try(
        storage.complete_multipart(config, sink.key, upload_id, list.reverse(sink.parts))
        |> result.replace_error(Nil),
      )
      Ok(#(sink.total, checksum))
    }
  }
}

fn sink_abort(config: storage.Config, sink: Sink) -> Nil {
  case sink.upload_id {
    Some(id) -> {
      let _ = storage.abort_multipart(config, sink.key, id)
      Nil
    }
    None -> Nil
  }
}

/// Assemble one part. Runs outside database transactions; the result is
/// recorded by a fenced transaction afterwards.
pub fn assemble_part(ctx: Context, job: Job) -> Result(AssemblyResult, AppError) {
  let assert Some(export_id) = job.operation_id
  let assert Some(account_id) = job.account_id
  use part <- result.try(
    json.parse(job.payload, decode.at(["part"], decode.int))
    |> result.replace_error(error.internal("export part payload")),
  )
  use header <- error.found(database.query_one(
    ctx.db,
    "select state = 'assembling' and execution_deadline > now(), rfc3339(snapshot_at),
       part_count, manifest_version
     from exports where id = $1::uuid and account_id = $2::uuid",
    [database.text(export_id), database.text(account_id)],
    {
      use live <- decode.field(0, decode.bool)
      use snapshot <- decode.field(1, decode.string)
      use part_count <- decode.field(2, decode.int)
      use version <- decode.field(3, decode.int)
      decode.success(#(live, snapshot, part_count, version))
    },
  ))
  let #(live, snapshot_at, part_count, manifest_version) = header
  case live {
    False -> Ok(Stale)
    True -> {
      // Only this part's items are held in memory; the full index is
      // streamed below in pages.
      use mine <- db(database.query(
        ctx.db,
        "select " <> item_columns <> " from export_items
         where export_id = $1::uuid and part_number = $2 order by ordinal",
        [database.text(export_id), database.int(part)],
        item_decoder(),
      ))
      use item_count <- error.found(database.query_one(
        ctx.db,
        "select count(*)::int from export_items where export_id = $1::uuid",
        [database.text(export_id)],
        decode.at([0], decode.int),
      ))
      use key <- error.found(database.query_one(
        ctx.db,
        "select key from export_parts where export_id = $1::uuid and part_number = $2",
        [database.text(export_id), database.int(part)],
        decode.at([0], decode.string),
      ))
      // Every part is self-describing: a small manifest.json plus the full
      // metadata index as index.jsonl (one JSON object per page, in order).
      let manifest =
        json.object([
          #("format", json.string("libarrie-export")),
          #("manifest_version", json.int(manifest_version)),
          #("export_id", json.string(export_id)),
          #("snapshot_at", json.string(snapshot_at)),
          #("part_number", json.int(part)),
          #("part_count", json.int(part_count)),
          #("item_count", json.int(item_count)),
          #("index", json.string("index.jsonl")),
        ])
        |> json.to_string
      let config = ctx.config.storage
      let sink =
        Sink(
          key:,
          chunk: ctx.config.exports.upload_chunk_bytes,
          buffer: [],
          buffered: 0,
          upload_id: None,
          parts: [],
          hasher: crypto.new_hasher(crypto.Sha256),
          total: 0,
        )
      let writer = zip.new()
      let #(writer, bytes) = zip.add(writer, "manifest.json", bit_array.from_string(manifest))
      let started =
        sink_write(config, sink, bytes)
        |> result.replace_error(Unavailable)
        |> result.try(fn(sink) { write_index(ctx, config, export_id, writer, sink) })
      let written =
        result.try(started, fn(sink) {
          let #(writer, sink) = sink
          list.try_fold(mine, #(writer, sink), fn(state, item) {
            let #(writer, sink) = state
            write_item(ctx, config, account_id, writer, sink, item)
          })
        })
      case written {
        Error(outcome) -> {
          case started {
            Ok(#(_, sink)) -> sink_abort(config, sink)
            Error(_) -> Nil
          }
          Ok(outcome)
        }
        Ok(#(writer, sink)) -> {
          let closing =
            sink_write(config, sink, zip.finish(writer))
            |> result.try(sink_close(config, _))
          case closing {
            Error(_) -> {
              sink_abort(config, sink)
              Ok(Unavailable)
            }
            Ok(#(bytes, checksum)) -> {
              use recorded <- result.try(record_part(ctx, job, export_id, part, bytes, checksum))
              Ok(recorded)
            }
          }
        }
      }
    }
  }
}

const item_columns = "ordinal, part_number, page_id::text, notebook_id::text, notebook_name,
  page_number, visibility, source_revision_id::text,
  transcript_revision_id::text, object_id::text, object_key, content_type,
  bytes, checksum, processing_status"

/// Rows of the index per database page while streaming it.
const index_page_size = 1000

/// Stream `index.jsonl`: every export item, a page of rows at a time, so a
/// 30,000-page export never builds its index in memory.
fn write_index(
  ctx: Context,
  config: storage.Config,
  export_id: String,
  writer: zip.Writer,
  sink: Sink,
) -> Result(#(zip.Writer, Sink), AssemblyResult) {
  let #(streaming, header) = zip.begin(writer, "index.jsonl")
  use sink <- result.try(sink_write(config, sink, header) |> result.replace_error(Unavailable))
  use #(streaming, sink) <- result.try(index_pages(ctx, config, export_id, -1, streaming, sink))
  let #(writer, descriptor) = zip.end(writer, streaming)
  use sink <- result.try(sink_write(config, sink, descriptor) |> result.replace_error(Unavailable))
  Ok(#(writer, sink))
}

fn index_pages(
  ctx: Context,
  config: storage.Config,
  export_id: String,
  after: Int,
  streaming: zip.Streaming,
  sink: Sink,
) -> Result(#(zip.Streaming, Sink), AssemblyResult) {
  use rows <- result.try(
    database.query(
      ctx.db,
      "select " <> item_columns <> " from export_items
       where export_id = $1::uuid and ordinal > $2 order by ordinal limit $3",
      [database.text(export_id), database.int(after), database.int(index_page_size)],
      item_decoder(),
    )
    |> result.replace_error(Unavailable),
  )
  case list.last(rows) {
    Error(_) -> Ok(#(streaming, sink))
    Ok(last) -> {
      let bytes =
        rows
        |> list.map(fn(item) { json.to_string(item_json(item)) <> "\n" })
        |> string.concat
        |> bit_array.from_string
      use sink <- result.try(sink_write(config, sink, bytes) |> result.replace_error(Unavailable))
      index_pages(ctx, config, export_id, last.ordinal, zip.chunk(streaming, bytes), sink)
    }
  }
}

fn write_item(
  ctx: Context,
  config: storage.Config,
  account_id: String,
  writer: zip.Writer,
  sink: Sink,
  item: Item,
) -> Result(#(zip.Writer, Sink), AssemblyResult) {
  use image <- result.try(case storage.get(config, item.object_key) {
    Ok(bytes) -> Ok(bytes)
    // A missing required artifact fails the export explicitly; never
    // substitute another revision or silently omit a page.
    Error(storage.NotFound) -> Error(Failed("missing_artifact"))
    Error(_) -> Error(Unavailable)
  })
  let actual = crypto.hash(crypto.Sha256, image) |> bit_array.base16_encode |> string.lowercase
  use <- result_guard(actual == item.checksum, Failed("artifact_checksum_mismatch"))
  let #(writer, bytes) = zip.add(writer, image_path(item), image)
  use sink <- result.try(sink_write(config, sink, bytes) |> result.replace_error(Unavailable))
  case item.transcript_revision_id {
    None -> Ok(#(writer, sink))
    Some(transcript_id) -> {
      let text =
        database.query_one(
          ctx.db,
          "select text from transcript_revisions where account_id = $1::uuid and id = $2::uuid",
          [database.text(account_id), database.text(transcript_id)],
          decode.at([0], decode.string),
        )
      case text {
        Ok(Some(text)) -> {
          let #(writer, bytes) =
            zip.add(writer, transcript_path(item), bit_array.from_string(text))
          use sink <- result.try(
            sink_write(config, sink, bytes) |> result.replace_error(Unavailable),
          )
          Ok(#(writer, sink))
        }
        Ok(None) -> Error(Failed("missing_artifact"))
        Error(_) -> Error(Unavailable)
      }
    }
  }
}

fn result_guard(condition: Bool, otherwise: e, next: fn() -> Result(a, e)) -> Result(a, e) {
  case condition {
    True -> next()
    False -> Error(otherwise)
  }
}

fn lease_lost() -> AppError {
  error.new(409, "lease_lost", "job ownership lost")
}

/// Fenced: record the part and, once every part is ready, enqueue
/// whole-export verification.
fn record_part(
  ctx: Context,
  job: Job,
  export_id: String,
  part: Int,
  bytes: Int,
  checksum: String,
) -> Result(AssemblyResult, AppError) {
  let assert Some(account_id) = job.account_id
  let outcome =
    context.transaction(ctx, fn(tx) {
      use _ <- result.try(accounts.lock(tx, account_id))
      use _ <- db(jobs.lock_account_slots(tx, account_id))
      use state <- error.found(database.query_one(
        tx,
        "select state from exports where id = $1::uuid for update",
        [database.text(export_id)],
        decode.at([0], decode.string),
      ))
      use owned <- db(jobs.lock_owned(tx, job))
      use <- error.guard(owned, lease_lost())
      case state {
        "assembling" -> {
          use _ <- db(database.execute(
            tx,
            "update export_parts set bytes = $3, checksum = $4, ready_at = now()
             where export_id = $1::uuid and part_number = $2",
            [
              database.text(export_id),
              database.int(part),
              database.int(bytes),
              database.text(checksum),
            ],
          ))
          use pending <- error.found(database.query_one(
            tx,
            "select count(*)::int from export_parts where export_id = $1::uuid and ready_at is null",
            [database.text(export_id)],
            decode.at([0], decode.int),
          ))
          use _ <- result.try(case pending {
            0 ->
              jobs.enqueue(
                tx,
                jobs.NewJob(
                  ..jobs.new_job("export_finalize", "export:" <> export_id <> ":finalize:g0"),
                  account_id: Some(account_id),
                  operation_id: Some(export_id),
                  deadline_seconds: Some(1800),
                ),
              )
              |> result.map_error(error.from_query)
              |> result.replace(Nil)
            _ -> Ok(Nil)
          })
          use _ <- db(jobs.complete(tx, job))
          Ok(Assembled("part " <> int.to_string(part) <> " ready"))
        }
        // Invalidated or cancelled meanwhile: discard the archive.
        _ -> {
          use key <- error.found(database.query_one(
            tx,
            "select key from export_parts where export_id = $1::uuid and part_number = $2",
            [database.text(export_id), database.int(part)],
            decode.at([0], decode.string),
          ))
          use _ <- result.try(pins.queue_object_deletion(
            tx,
            pins.export_bucket_marker,
            key,
            "export_discarded",
          ))
          use _ <- db(jobs.complete(tx, job))
          Ok(Stale)
        }
      }
    })
  case outcome {
    Error(e) if e.code == "lease_lost" -> Ok(Stale)
    other -> other
  }
}

/// Verify every part exists with its recorded size, then set the single
/// whole-export `completed_at`, start the fixed seven-day retention and
/// release source pins (archives are retained until `expires_at`).
pub fn finalize(ctx: Context, job: Job) -> Result(AssemblyResult, AppError) {
  let assert Some(export_id) = job.operation_id
  let assert Some(account_id) = job.account_id
  use parts <- db(database.query(
    ctx.db,
    "select key, bytes from export_parts where export_id = $1::uuid order by part_number",
    [database.text(export_id)],
    {
      use key <- decode.field(0, decode.string)
      use bytes <- decode.field(1, decode.optional(decode.int))
      decode.success(#(key, bytes))
    },
  ))
  let verified =
    list.try_each(parts, fn(part) {
      case storage.head(ctx.config.storage, part.0), part.1 {
        Ok(info), Some(bytes) if info.bytes == bytes -> Ok(Nil)
        Error(storage.Unavailable(_)), _ -> Error("unavailable")
        _, _ -> Error("part_verification_failed")
      }
    })
  case verified {
    Error("unavailable") -> Ok(Unavailable)
    Error(code) -> Ok(Failed(code))
    Ok(Nil) -> {
      let outcome =
        context.transaction(ctx, fn(tx) {
          use _ <- result.try(accounts.lock(tx, account_id))
          use _ <- db(jobs.lock_account_slots(tx, account_id))
          use state <- error.found(database.query_one(
            tx,
            "select state from exports where id = $1::uuid for update",
            [database.text(export_id)],
            decode.at([0], decode.string),
          ))
          use owned <- db(jobs.lock_owned(tx, job))
          use <- error.guard(owned, lease_lost())
          case state {
            "assembling" -> {
              use _ <- db(database.execute(
                tx,
                "update exports set state = 'completed', completed_at = now(),
                   expires_at = now() + make_interval(secs => $2)
                 where id = $1::uuid",
                [
                  database.text(export_id),
                  database.int(ctx.config.exports.retention_seconds),
                ],
              ))
              use _ <- db(database.execute(
                tx,
                "delete from artifact_pins where owner_kind = 'export' and owner_id = $1::uuid",
                [database.text(export_id)],
              ))
              use _ <- db(jobs.complete(tx, job))
              Ok(Assembled("export completed"))
            }
            _ -> {
              use _ <- db(jobs.complete(tx, job))
              Ok(Stale)
            }
          }
        })
      case outcome {
        Error(e) if e.code == "lease_lost" -> Ok(Stale)
        other -> other
      }
    }
  }
}

/// Fail an export explicitly: release pins, cancel remaining part jobs and
/// queue any archives for deletion.
pub fn fail(ctx: Context, job: Job, code: String) -> Result(Nil, AppError) {
  let assert Some(export_id) = job.operation_id
  let assert Some(account_id) = job.account_id
  context.transaction(ctx, fn(tx) {
    use _ <- result.try(accounts.lock(tx, account_id))
    use _ <- db(jobs.lock_account_slots(tx, account_id))
    use _ <- db(database.execute(
      tx,
      "update exports set state = 'failed', error_code = $2
       where id = $1::uuid and state = 'assembling'",
      [database.text(export_id), database.text(code)],
    ))
    use owned <- db(jobs.lock_owned(tx, job))
    use _ <- result.try(pins.release_export_artifacts(tx, account_id, [export_id], "export_failed"))
    case owned {
      True -> jobs.fail(tx, job, code) |> result.map_error(error.from_query)
      False -> Ok(Nil)
    }
  })
}

/// Maintenance: expire completed exports at `expires_at` and fail exports
/// that overran their execution deadline.
pub fn expire(ctx: Context) -> Result(Int, AppError) {
  use due <- db(database.query(
    ctx.db,
    "select account_id::text, id::text, state from exports
     where (state = 'completed' and expires_at <= now())
        or (state = 'assembling' and execution_deadline <= now())
     limit 100",
    [],
    {
      use account <- decode.field(0, decode.string)
      use id <- decode.field(1, decode.string)
      use state <- decode.field(2, decode.string)
      decode.success(#(account, id, state))
    },
  ))
  list.try_fold(due, 0, fn(count, row) {
    let #(account_id, export_id, state) = row
    let outcome =
      context.transaction(ctx, fn(tx) {
        use _ <- result.try(accounts.lock(tx, account_id))
        use _ <- db(jobs.lock_account_slots(tx, account_id))
        use _ <- db(database.execute(
          tx,
          "update exports set state = case when state = 'completed' then 'expired' else 'failed' end,
             error_code = case when state = 'assembling' then 'deadline_exceeded' else error_code end
           where id = $1::uuid and state = $2",
          [database.text(export_id), database.text(state)],
        ))
        pins.release_export_artifacts(tx, account_id, [export_id], "export_expired")
      })
    case outcome {
      Ok(_) -> Ok(count + 1)
      Error(e) -> Error(e)
    }
  })
}
