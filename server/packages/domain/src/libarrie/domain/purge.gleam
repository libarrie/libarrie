//// Permanent purge of trash and of non-active source revisions, plus trash
//// retention expiry (sections 5, 10 and 14).
////
//// A purge request hides its targets and journals the intent; physical
//// erasure happens only after the independent journal acknowledges it.
//// Exports pinning affected artifacts are invalidated first. Independent
//// backups still age out on their own documented window.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import libarrie/database.{type Connection}
import libarrie/domain/accounts
import libarrie/domain/context.{type Context}
import libarrie/domain/error.{type AppError, db}
import libarrie/domain/journal
import libarrie/domain/operations
import libarrie/domain/pages
import libarrie/domain/pins
import libarrie/domain/quota
import libarrie/jobs
import youid/uuid

pub type Request {
  Request(page_ids: List(String), notebook_ids: List(String), all: Bool)
}

pub fn decoder() -> decode.Decoder(Request) {
  use page_ids <- decode.optional_field("page_ids", [], decode.list(decode.string))
  use notebook_ids <- decode.optional_field(
    "notebook_ids",
    [],
    decode.list(decode.string),
  )
  use all <- decode.optional_field("all", False, decode.bool)
  decode.success(Request(
    list.map(page_ids, string.lowercase),
    list.map(notebook_ids, string.lowercase),
    all,
  ))
}

/// `POST /v1/trash/purge`: permanently delete selected trash, or all of it.
pub fn purge_trash(
  ctx: Context,
  account_id: String,
  request: Request,
) -> Result(#(json.Json, journal.Intent), AppError) {
  use <- error.guard(
    request.all || request.page_ids != [] || request.notebook_ids != [],
    error.unprocessable("Select pages or notebooks, or set all to true."),
  )
  use <- error.guard(
    list.all(list.append(request.page_ids, request.notebook_ids), context.is_uuid),
    error.bad_request("page_ids and notebook_ids must be UUIDs"),
  )
  context.transaction(ctx, fn(tx) {
    use _ <- result.try(accounts.lock_readable(tx, account_id))
    use _ <- result.try(quota.lock_usage(tx, account_id))
    use _ <- db(jobs.lock_account_slots(tx, account_id))
    use notebook_ids <- db(database.query(
      tx,
      "select id::text from notebooks
       where account_id = $1::uuid and deleted_at is not null
         and purge_requested_at is null
         and ($2 or id = any($3::uuid[]))
       order by id for update",
      [
        database.text(account_id),
        database.bool(request.all),
        database.text_array(request.notebook_ids),
      ],
      decode.at([0], decode.string),
    ))
    use page_ids <- db(database.query(
      tx,
      "select id::text from pages
       where account_id = $1::uuid and visibility = 'trashed'
         and purge_requested_at is null
         and ($2 or id = any($3::uuid[]) or notebook_id = any($4::uuid[]))
       order by id for update",
      [
        database.text(account_id),
        database.bool(request.all),
        database.text_array(request.page_ids),
        database.text_array(notebook_ids),
      ],
      decode.at([0], decode.string),
    ))
    // Explicitly named targets that are not in trash are not found.
    use <- error.guard(
      list.all(request.page_ids, list.contains(page_ids, _))
        && list.all(request.notebook_ids, list.contains(notebook_ids, _)),
      error.not_found(),
    )
    use blocked <- result.try(
      list.try_fold(list.append(page_ids, notebook_ids), False, fn(found, id) {
        case found {
          True -> Ok(True)
          False -> journal.pending_for_scope(tx, account_id, id)
        }
      }),
    )
    use <- error.guard(!blocked, pages.recovery_pending())
    request_purge(tx, account_id, page_ids, notebook_ids, "user")
  })
}

/// Hide targets, invalidate pinning exports and journal the purge intent.
/// The caller holds the account, usage and job-slot locks.
pub fn request_purge(
  tx: Connection,
  account_id: String,
  page_ids: List(String),
  notebook_ids: List(String),
  actor: String,
) -> Result(#(json.Json, journal.Intent), AppError) {
  use _ <- db(database.execute(
    tx,
    "update pages set purge_requested_at = now() where account_id = $1::uuid
       and id = any($2::uuid[])",
    [database.text(account_id), database.text_array(page_ids)],
  ))
  use _ <- db(database.execute(
    tx,
    "update notebooks set purge_requested_at = now() where account_id = $1::uuid
       and id = any($2::uuid[])",
    [database.text(account_id), database.text_array(notebook_ids)],
  ))
  use objects <- db(database.query(
    tx,
    "select o.id::text from page_revisions r join objects o on o.id = r.source_object_id
     where r.account_id = $1::uuid and r.page_id = any($2::uuid[])",
    [database.text(account_id), database.text_array(page_ids)],
    decode.at([0], decode.string),
  ))
  use invalidated <- result.try(pins.invalidate_exports(tx, account_id, "object", objects))
  let scope_id = uuid.v7_string()
  use intent <- result.try(journal.record(
    tx,
    account_id,
    "trash_set",
    scope_id,
    1,
    "purge",
    [
      #("actor", json.string(actor)),
      #("page_ids", json.array(page_ids, json.string)),
      #("notebook_ids", json.array(notebook_ids, json.string)),
    ],
  ))
  Ok(#(
    json.object([
      #("page_ids", json.array(page_ids, json.string)),
      #("notebook_ids", json.array(notebook_ids, json.string)),
      #("invalidated_export_ids", json.array(invalidated, json.string)),
    ]),
    intent,
  ))
}

/// `DELETE /v1/pages/{id}/revisions/{revision_id}`: purge a non-active
/// source revision and its derived data without trashing the page.
pub fn purge_revision(
  ctx: Context,
  account_id: String,
  page_id: String,
  revision_id: String,
) -> Result(journal.Intent, AppError) {
  context.transaction(ctx, fn(tx) {
    use _ <- result.try(accounts.lock_readable(tx, account_id))
    use _ <- result.try(quota.lock_usage(tx, account_id))
    use _ <- db(jobs.lock_account_slots(tx, account_id))
    use page <- result.try(pages.get(tx, account_id, page_id))
    use _ <- result.try(pages.lock_notebooks(tx, account_id, [page.notebook_id]))
    use _ <- result.try(pages.lock_pages(tx, account_id, [page_id]))
    use page <- result.try(pages.get(tx, account_id, page_id))
    use found <- error.found(database.query_one(
      tx,
      "select r.purge_requested_at is null, r.source_object_id::text from page_revisions r
       where r.account_id = $1::uuid and r.page_id = $2::uuid and r.id = $3::uuid
       for update",
      [database.text(account_id), database.text(page_id), database.text(revision_id)],
      {
        use fresh <- decode.field(0, decode.bool)
        use object <- decode.field(1, decode.optional(decode.string))
        decode.success(#(fresh, object))
      },
    ))
    use <- error.guard(found.0, error.not_found())
    use <- error.guard(
      page.revision_id != Some(revision_id),
      error.new(409, "active_source", "Replace the active source before purging it."),
    )
    use <- error.guard(
      page.pending_revision_id != Some(revision_id),
      error.new(409, "processing_conflict", "This source is still being processed."),
    )
    use live <- result.try(operations.live_for_page(tx, account_id, page_id))
    use _ <- result.try(case live {
      Some(op) if op.revision_id == Some(revision_id) -> Error(operations.conflict(op))
      _ -> Ok(Nil)
    })
    use pending <- result.try(journal.pending_for_scope(tx, account_id, revision_id))
    use <- error.guard(!pending, pages.recovery_pending())
    use _ <- db(database.execute(
      tx,
      "update page_revisions set purge_requested_at = now() where id = $1::uuid",
      [database.text(revision_id)],
    ))
    use transcripts <- db(database.query(
      tx,
      "select id::text from transcript_revisions where revision_id = $1::uuid",
      [database.text(revision_id)],
      decode.at([0], decode.string),
    ))
    use _ <- result.try(pins.invalidate_exports(
      tx,
      account_id,
      "object",
      option.values([found.1]),
    ))
    use _ <- result.try(pins.invalidate_exports(tx, account_id, "transcript_revision", transcripts))
    journal.record(tx, account_id, "source_revision", revision_id, 1, "purge", [
      #("page_id", json.string(page_id)),
      #("revision_ids", json.array([revision_id], json.string)),
    ])
  })
}

/// After journal acknowledgement: erase purged pages, notebooks and
/// revisions. Idempotent; rows already gone are skipped.
pub fn finalize(
  ctx: Context,
  account_id: String,
  payload: String,
) -> Result(Int, AppError) {
  let ids = fn(field) {
    json.parse(payload, decode.at([field], decode.list(decode.string)))
    |> result.unwrap([])
  }
  let page_ids = ids("page_ids")
  let notebook_ids = ids("notebook_ids")
  let revision_ids = ids("revision_ids")
  context.transaction(ctx, fn(tx) {
    use _ <- result.try(accounts.lock(tx, account_id))
    use _ <- result.try(pages.lock_notebooks(tx, account_id, notebook_ids))
    use _ <- result.try(pages.lock_pages(tx, account_id, page_ids))
    use purgeable_pages <- db(database.query(
      tx,
      "select id::text from pages where account_id = $1::uuid and id = any($2::uuid[])
         and visibility = 'trashed' and purge_requested_at is not null",
      [database.text(account_id), database.text_array(page_ids)],
      decode.at([0], decode.string),
    ))
    use page_revisions <- db(database.query(
      tx,
      "select id::text from page_revisions where account_id = $1::uuid
         and page_id = any($2::uuid[])",
      [database.text(account_id), database.text_array(purgeable_pages)],
      decode.at([0], decode.string),
    ))
    use purgeable_revisions <- db(database.query(
      tx,
      "select r.id::text from page_revisions r join pages p on p.id = r.page_id
       where r.account_id = $1::uuid and r.id = any($2::uuid[])
         and r.purge_requested_at is not null
         and p.active_revision_id is distinct from r.id
         and p.pending_revision_id is distinct from r.id",
      [database.text(account_id), database.text_array(revision_ids)],
      decode.at([0], decode.string),
    ))
    let revisions = list.append(page_revisions, purgeable_revisions)
    use _ <- result.try(erase_revisions(tx, account_id, revisions, purgeable_pages))
    use _ <- result.try(erase_pages(tx, account_id, purgeable_pages))
    use notebooks <- db(database.query(
      tx,
      "delete from notebooks n where account_id = $1::uuid and id = any($2::uuid[])
         and purge_requested_at is not null
         and not exists (select 1 from pages p where p.notebook_id = n.id)
       returning id::text",
      [database.text(account_id), database.text_array(notebook_ids)],
      decode.at([0], decode.string),
    ))
    use _ <- result.try(
      list.try_each(
        list.flatten([
          list.map(purgeable_pages, fn(id) { #("page", id) }),
          list.map(purgeable_revisions, fn(id) { #("source_revision", id) }),
          list.map(notebooks, fn(id) { #("notebook", id) }),
        ]),
        fn(scope) { tombstone(tx, account_id, scope.0, scope.1) },
      ),
    )
    Ok(list.length(purgeable_pages) + list.length(purgeable_revisions) + list.length(notebooks))
  })
}

/// Delete revisions with everything derived from them, queueing their
/// source objects for storage deletion.
pub fn erase_revisions(
  tx: Connection,
  account_id: String,
  revision_ids: List(String),
  page_ids: List(String),
) -> Result(Nil, AppError) {
  let account = database.text(account_id)
  let revisions = database.text_array(revision_ids)
  use objects <- db(database.query(
    tx,
    "select unnest(array_remove(array[source_object_id, thumbnail_object_id,
       preview_object_id], null))::text
     from page_revisions where account_id = $1::uuid and id = any($2::uuid[])",
    [account, revisions],
    decode.at([0], decode.string),
  ))
  let statements = [
    "delete from search_release_pages where account_id = $1::uuid
       and index_generation_id in (select id from index_generations
         where account_id = $1::uuid and revision_id = any($2::uuid[]))",
    "delete from passages where account_id = $1::uuid and index_generation_id in
       (select id from index_generations where account_id = $1::uuid
          and revision_id = any($2::uuid[]))",
    "delete from index_generations where account_id = $1::uuid and revision_id = any($2::uuid[])",
    "update page_revisions set selected_transcript_revision_id = null
       where account_id = $1::uuid and id = any($2::uuid[])",
    "delete from transcript_revisions where account_id = $1::uuid and revision_id = any($2::uuid[])",
    "delete from ocr_results where account_id = $1::uuid and revision_id = any($2::uuid[])",
    "delete from artifact_pins where artifact_kind = 'object'
       and artifact_id in (select source_object_id from page_revisions
         where account_id = $1::uuid and id = any($2::uuid[]))",
  ]
  use _ <- result.try(
    list.try_each(statements, fn(sql) {
      database.execute(tx, sql, [account, revisions])
      |> result.map_error(error.from_query)
    }),
  )
  // Pages whose revisions are going away entirely drop their pointers first.
  use _ <- db(database.execute(
    tx,
    "update pages set active_revision_id = null, pending_revision_id = null
     where account_id = $1::uuid and id = any($2::uuid[])",
    [account, database.text_array(page_ids)],
  ))
  use _ <- db(database.execute(
    tx,
    "delete from page_revisions where account_id = $1::uuid and id = any($2::uuid[])",
    [account, revisions],
  ))
  use _ <- result.try(pins.queue_objects(tx, account_id, objects, "purge"))
  use _ <- db(database.execute(
    tx,
    "delete from objects where account_id = $1::uuid and id = any($2::uuid[])",
    [account, database.text_array(objects)],
  ))
  Ok(Nil)
}

fn erase_pages(
  tx: Connection,
  account_id: String,
  page_ids: List(String),
) -> Result(Nil, AppError) {
  let account = database.text(account_id)
  let pages = database.text_array(page_ids)
  use _ <- db(database.execute(
    tx,
    "delete from search_release_pages where account_id = $1::uuid and page_id = any($2::uuid[])",
    [account, pages],
  ))
  use _ <- db(database.execute(
    tx,
    "delete from upload_sessions where account_id = $1::uuid and page_id = any($2::uuid[])",
    [account, pages],
  ))
  use _ <- db(database.execute(
    tx,
    "delete from pages where account_id = $1::uuid and id = any($2::uuid[])",
    [account, pages],
  ))
  Ok(Nil)
}

fn tombstone(
  tx: Connection,
  account_id: String,
  scope_kind: String,
  scope_id: String,
) -> Result(Nil, AppError) {
  use _ <- db(database.execute(
    tx,
    "insert into deletion_tombstones (account_id, scope_kind, scope_id, generation,
       action, command_id, retention_deadline)
     values ($1::uuid, $2, $3::uuid, 1, 'purge', $4::uuid, now() + interval '37 days')
     on conflict do nothing",
    [
      database.text(account_id),
      database.text(scope_kind),
      database.text(scope_id),
      database.text(uuid.v7_string()),
    ],
  ))
  Ok(Nil)
}

/// Trash retention: request purge for items trashed longer than the
/// retention window. Bounded per account and per run.
pub fn expire_trash(ctx: Context, limit: Int) -> Result(Int, AppError) {
  use accounts_due <- db(database.query(
    ctx.db,
    "select distinct account_id::text from (
       select account_id from pages where visibility = 'trashed'
         and purge_requested_at is null
         and deleted_at < now() - make_interval(days => $1)
       union
       select account_id from notebooks where deleted_at is not null
         and purge_requested_at is null
         and deleted_at < now() - make_interval(days => $1)) due
     limit $2",
    [database.int(ctx.config.trash_retention_days), database.int(limit)],
    decode.at([0], decode.string),
  ))
  list.try_fold(accounts_due, 0, fn(count, account_id) {
    let outcome =
      context.transaction(ctx, fn(tx) {
        use _ <- result.try(accounts.lock(tx, account_id))
        use _ <- result.try(quota.lock_usage(tx, account_id))
        use _ <- db(jobs.lock_account_slots(tx, account_id))
        use notebooks <- db(database.query(
          tx,
          "select id::text from notebooks where account_id = $1::uuid
             and deleted_at is not null and purge_requested_at is null
             and deleted_at < now() - make_interval(days => $2)
           order by id limit 100 for update",
          [database.text(account_id), database.int(ctx.config.trash_retention_days)],
          decode.at([0], decode.string),
        ))
        use page_ids <- db(database.query(
          tx,
          "select id::text from pages where account_id = $1::uuid
             and visibility = 'trashed' and purge_requested_at is null
             and (deleted_at < now() - make_interval(days => $2)
               or notebook_id = any($3::uuid[]))
           order by id limit 500 for update",
          [
            database.text(account_id),
            database.int(ctx.config.trash_retention_days),
            database.text_array(notebooks),
          ],
          decode.at([0], decode.string),
        ))
        use _ <- result.try(request_purge(tx, account_id, page_ids, notebooks, "trash_expiry"))
        Ok(list.length(page_ids) + list.length(notebooks))
      })
    case outcome {
      Ok(n) -> Ok(count + n)
      Error(e) -> Error(e)
    }
  })
}
