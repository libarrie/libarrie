//// Artifact pins and the object-deletion queue (sections 5 and 14).
////
//// Exports pin the source objects and transcript revisions they snapshot,
//// so ordinary garbage collection cannot race assembly. Permanent purge and
//// account closure are the documented exceptions: they invalidate the
//// affected exports and release their pins before erasing protected data.

import gleam/dynamic/decode
import gleam/list
import gleam/result
import libarrie/database.{type Connection}
import libarrie/domain/error.{type AppError, db}
import libarrie/jobs
import youid/uuid

/// Queue a storage object for deletion once the surrounding transaction
/// commits. The deletion task removes it and then drops the row.
pub fn queue_object_deletion(
  conn: Connection,
  bucket: String,
  key: String,
  reason: String,
) -> Result(Nil, AppError) {
  use _ <- db(database.execute(
    conn,
    "insert into pending_object_deletions (id, bucket, key, reason)
     values ($1::uuid, $2, $3, $4) on conflict (bucket, key) do nothing",
    [
      database.text(uuid.v7_string()),
      database.text(bucket),
      database.text(key),
      database.text(reason),
    ],
  ))
  Ok(Nil)
}

/// Queue the given account objects for storage deletion.
pub fn queue_objects(
  conn: Connection,
  account_id: String,
  object_ids: List(String),
  reason: String,
) -> Result(Nil, AppError) {
  use _ <- db(database.execute(
    conn,
    "insert into pending_object_deletions (id, bucket, key, reason)
     select gen_random_uuid(), bucket, key, $3 from objects
     where account_id = $1::uuid and id = any($2::uuid[])
     on conflict (bucket, key) do nothing",
    [
      database.text(account_id),
      database.text_array(object_ids),
      database.text(reason),
    ],
  ))
  Ok(Nil)
}

/// Invalidate exports that pin any of the given artifacts: cancel their
/// assembly, release their pins and queue their part archives for deletion.
/// Call with the account job-slot row already locked.
pub fn invalidate_exports(
  conn: Connection,
  account_id: String,
  artifact_kind: String,
  artifact_ids: List(String),
) -> Result(List(String), AppError) {
  use exports <- db(database.query(
    conn,
    "update exports set state = 'invalidated', error_code = 'artifact_purged'
     where account_id = $1::uuid and state in ('assembling', 'completed')
       and id in (select owner_id from artifact_pins
                  where owner_kind = 'export' and artifact_kind = $2
                    and artifact_id = any($3::uuid[]))
     returning id::text",
    [
      database.text(account_id),
      database.text(artifact_kind),
      database.text_array(artifact_ids),
    ],
    decode.at([0], decode.string),
  ))
  use _ <- result.try(release_export_artifacts(conn, account_id, exports, "export_invalidated"))
  Ok(exports)
}

/// Release pins, cancel jobs and queue part archives for the given exports.
pub fn release_export_artifacts(
  conn: Connection,
  account_id: String,
  export_ids: List(String),
  reason: String,
) -> Result(Nil, AppError) {
  use _ <- result.try(
    list.try_each(export_ids, fn(id) {
      jobs.cancel_for_operation(conn, account_id, id)
      |> result.map_error(error.from_query)
    }),
  )
  use _ <- db(database.execute(
    conn,
    "delete from artifact_pins where owner_kind = 'export' and owner_id = any($1::uuid[])",
    [database.text_array(export_ids)],
  ))
  use _ <- db(database.execute(
    conn,
    "insert into pending_object_deletions (id, bucket, key, reason)
     select gen_random_uuid(), b.bucket, p.key, $2
     from export_parts p, (select $3::text as bucket) b
     where p.export_id = any($1::uuid[])
     on conflict (bucket, key) do nothing",
    [
      database.text_array(export_ids),
      database.text(reason),
      database.text(export_bucket_marker),
    ],
  ))
  Ok(Nil)
}

/// Export parts live in the primary bucket; the deletion task resolves this
/// marker to the configured bucket name.
pub const export_bucket_marker = "$primary"
