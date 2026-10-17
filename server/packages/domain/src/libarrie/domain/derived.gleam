//// Thumbnails and previews (sections 6 and 7).
////
//// Produced by the sandboxed decoder after source acceptance, as
//// metadata-free JPEGs (orientation applied, no location data). They are
//// rebuildable artifacts, served from same-origin routes with private
//// caching, and erased together with their source revision.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import gleam/result
import libarrie/database
import libarrie/domain/accounts
import libarrie/domain/context.{type Context}
import libarrie/domain/error.{type AppError, db}
import libarrie/domain/pages
import libarrie/domain/pins
import libarrie/integrations/decoder
import libarrie/integrations/storage
import libarrie/jobs.{type Job}
import youid/uuid

pub const thumbnail_dimension = 320

pub const preview_dimension = 1600

pub type Outcome {
  Done(summary: String)
  RetryLater(reason: String)
  Skipped(reason: String)
  LeaseLost
}

pub fn run(ctx: Context, job: Job) -> Result(Outcome, AppError) {
  let assert Some(account_id) = job.account_id
  let assert Some(revision_id) = job.revision_id
  let assert Some(page_id) = job.page_id
  case ctx.config.decoder {
    None -> complete(ctx, job, account_id, page_id, None) |> result.map(fn(_) { Skipped("decoder disabled") })
    Some(config) -> {
      use source <- db(database.query_one(
        ctx.db,
        "select o.key from page_revisions r join objects o on o.id = r.source_object_id
         where r.account_id = $1::uuid and r.id = $2::uuid and r.purge_requested_at is null",
        [database.text(account_id), database.text(revision_id)],
        decode.at([0], decode.string),
      ))
      case source {
        None -> complete(ctx, job, account_id, page_id, None) |> result.map(fn(_) { Skipped("source gone") })
        Some(key) ->
          case storage.get(ctx.config.storage, key) {
            Error(_) -> Ok(RetryLater("object_store_unavailable"))
            Ok(bytes) -> {
              let thumb = decoder.resize(config, bytes, thumbnail_dimension, 80)
              let preview = decoder.resize(config, bytes, preview_dimension, 85)
              case thumb, preview {
                Ok(t), Ok(p) -> store(ctx, job, account_id, page_id, revision_id, t, p)
                Error(decoder.Unavailable(reason)), _ | _, Error(decoder.Unavailable(reason)) ->
                  Ok(RetryLater(reason))
                // The source already passed full validation; a refusal here
                // leaves the original viewable without derived images.
                Error(decoder.Unsupported(reason)), _ | _, Error(decoder.Unsupported(reason)) ->
                  complete(ctx, job, account_id, page_id, None)
                  |> result.map(fn(_) { Skipped(reason) })
              }
            }
          }
      }
    }
  }
}

fn store(
  ctx: Context,
  job: Job,
  account_id: String,
  page_id: String,
  revision_id: String,
  thumbnail: BitArray,
  preview: BitArray,
) -> Result(Outcome, AppError) {
  let thumb_id = uuid.v7_string()
  let preview_id = uuid.v7_string()
  let thumb_key = "derived/" <> account_id <> "/" <> thumb_id <> ".jpg"
  let preview_key = "derived/" <> account_id <> "/" <> preview_id <> ".jpg"
  let config = ctx.config.storage
  case
    storage.put(config, thumb_key, thumbnail, "image/jpeg"),
    storage.put(config, preview_key, preview, "image/jpeg")
  {
    Ok(_), Ok(_) ->
      complete(ctx, job, account_id, page_id, Some(#(
        revision_id,
        #(thumb_id, thumb_key, thumbnail),
        #(preview_id, preview_key, preview),
      )))
    _, _ -> {
      let _ = storage.delete(config, thumb_key)
      let _ = storage.delete(config, preview_key)
      Ok(RetryLater("object_store_unavailable"))
    }
  }
}

/// Fenced: link the derived objects (if the revision still exists) and
/// complete the job. Late or orphaned uploads are queued for deletion.
fn complete(
  ctx: Context,
  job: Job,
  account_id: String,
  page_id: String,
  derived: Option(#(String, #(String, String, BitArray), #(String, String, BitArray))),
) -> Result(Outcome, AppError) {
  let outcome =
    context.transaction(ctx, fn(tx) {
      use _ <- result.try(accounts.lock(tx, account_id))
      use _ <- db(jobs.lock_account_slots(tx, account_id))
      use _ <- result.try(pages.lock_pages(tx, account_id, [page_id]))
      use owned <- db(jobs.lock_owned(tx, job))
      use <- error.guard(owned, error.new(409, "lease_lost", "job ownership lost"))
      use summary <- result.try(case derived {
        None -> Ok("nothing stored")
        Some(#(revision_id, thumb, preview)) -> {
          use linked <- db(database.query_one(
            tx,
            "select 1 from page_revisions where account_id = $1::uuid and id = $2::uuid
               and purge_requested_at is null for update",
            [database.text(account_id), database.text(revision_id)],
            decode.at([0], decode.int),
          ))
          case linked {
            None -> {
              use _ <- result.try(pins.queue_object_deletion(tx, ctx.config.storage.bucket, thumb.1, "orphaned_derived"))
              use _ <- result.try(pins.queue_object_deletion(tx, ctx.config.storage.bucket, preview.1, "orphaned_derived"))
              Ok("revision gone; discarded")
            }
            Some(_) -> {
              use _ <- result.try(insert_object(ctx, tx, account_id, thumb, "thumbnail"))
              use _ <- result.try(insert_object(ctx, tx, account_id, preview, "preview"))
              use _ <- db(database.execute(
                tx,
                "update page_revisions set thumbnail_object_id = $3::uuid, preview_object_id = $4::uuid
                 where account_id = $1::uuid and id = $2::uuid",
                [
                  database.text(account_id),
                  database.text(revision_id),
                  database.text(thumb.0),
                  database.text(preview.0),
                ],
              ))
              Ok("thumbnail and preview stored")
            }
          }
        }
      })
      use _ <- db(jobs.complete(tx, job))
      Ok(summary)
    })
  case outcome {
    Ok(summary) -> Ok(Done(summary))
    Error(e) if e.code == "lease_lost" -> Ok(LeaseLost)
    Error(e) -> Error(e)
  }
}

fn insert_object(
  ctx: Context,
  tx: database.Connection,
  account_id: String,
  object: #(String, String, BitArray),
  kind: String,
) -> Result(Nil, AppError) {
  let #(id, key, bytes) = object
  use _ <- db(database.execute(
    tx,
    "insert into objects (id, account_id, bucket, key, content_type, bytes, checksum,
       state, kind)
     values ($1::uuid, $2::uuid, $3, $4, 'image/jpeg', $5, '', 'stored', $6)",
    [
      database.text(id),
      database.text(account_id),
      database.text(ctx.config.storage.bucket),
      database.text(key),
      database.int(bit_array.byte_size(bytes)),
      database.text(kind),
    ],
  ))
  Ok(Nil)
}

/// Bytes and content type of a derived image for the same-origin route.
/// The caller must already have authorized the account.
pub fn fetch(
  ctx: Context,
  account_id: String,
  source_object_id: String,
  variant: String,
) -> Result(BitArray, AppError) {
  let column = case variant {
    "thumb" -> "thumbnail_object_id"
    _ -> "preview_object_id"
  }
  use key <- error.found(database.query_one(
    ctx.db,
    "select d.key from page_revisions r
     join pages p on p.id = r.page_id
     join objects d on d.id = r." <> column <> "
     where r.account_id = $1::uuid and r.source_object_id = $2::uuid
       and r.purge_requested_at is null and p.purge_requested_at is null
       and p.visibility in ('active', 'trashed')",
    [database.text(account_id), database.text(source_object_id)],
    decode.at([0], decode.string),
  ))
  storage.get(ctx.config.storage, key)
  |> result.map_error(fn(e) {
    case e {
      storage.NotFound -> error.not_found()
      _ -> error.unavailable()
    }
  })
}
