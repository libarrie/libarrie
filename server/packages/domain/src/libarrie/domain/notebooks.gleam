//// Notebooks (sections 2, 11 and 14).

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
import libarrie/domain/journal
import libarrie/domain/operations
import libarrie/domain/pages
import libarrie/domain/quota
import libarrie/jobs
import youid/uuid

pub type Notebook {
  Notebook(
    id: String,
    name: String,
    description: String,
    color: Option(String),
    version: Int,
    numbering_revision: Int,
    page_count: Int,
    deleted_at: Option(String),
    deletion_batch_id: Option(String),
    created_at: String,
    updated_at: String,
    private: Bool,
  )
}

const select_notebook = "select n.id::text, n.name, n.description, n.color, n.version,
    n.numbering_revision,
    (select count(*)::int from pages p where p.notebook_id = n.id and p.visibility = 'active'),
    rfc3339(n.deleted_at), n.deletion_batch_id::text,
    rfc3339(n.created_at), rfc3339(n.updated_at), n.private
  from notebooks n"

fn decoder() -> decode.Decoder(Notebook) {
  use id <- decode.field(0, decode.string)
  use name <- decode.field(1, decode.string)
  use description <- decode.field(2, decode.string)
  use color <- decode.field(3, decode.optional(decode.string))
  use version <- decode.field(4, decode.int)
  use numbering_revision <- decode.field(5, decode.int)
  use page_count <- decode.field(6, decode.int)
  use deleted_at <- decode.field(7, decode.optional(decode.string))
  use deletion_batch_id <- decode.field(8, decode.optional(decode.string))
  use created_at <- decode.field(9, decode.string)
  use updated_at <- decode.field(10, decode.string)
  use private <- decode.field(11, decode.bool)
  decode.success(Notebook(
    id:,
    name:,
    description:,
    color:,
    version:,
    numbering_revision:,
    page_count:,
    deleted_at:,
    deletion_batch_id:,
    created_at:,
    updated_at:,
    private:,
  ))
}

pub fn to_json(notebook: Notebook) -> json.Json {
  json.object([
    #("id", json.string(notebook.id)),
    #("name", json.string(notebook.name)),
    #("description", json.string(notebook.description)),
    #("color", context.optional_string(notebook.color)),
    #("private", json.bool(notebook.private)),
    #("version", json.int(notebook.version)),
    #("numbering_revision", json.int(notebook.numbering_revision)),
    #("page_count", json.int(notebook.page_count)),
    #("deleted_at", context.optional_string(notebook.deleted_at)),
    #("deletion_batch_id", context.optional_string(notebook.deletion_batch_id)),
    #("created_at", json.string(notebook.created_at)),
    #("updated_at", json.string(notebook.updated_at)),
  ])
}

pub fn etag(notebook: Notebook) -> String {
  "\"v" <> int.to_string(notebook.version) <> "\""
}

pub fn get(
  conn: Connection,
  account_id: String,
  notebook_id: String,
) -> Result(Notebook, AppError) {
  use notebook <- error.found(database.query_one(
    conn,
    select_notebook
      <> " where n.account_id = $1::uuid and n.id = $2::uuid and n.deleted_at is null",
    [database.text(account_id), database.text(notebook_id)],
    decoder(),
  ))
  Ok(notebook)
}

/// Active notebooks whose name matches, ignoring case and surrounding
/// spaces. Names aren't unique, so this can return several.
pub fn named(
  conn: Connection,
  account_id: String,
  name: String,
) -> Result(List(Notebook), AppError) {
  use rows <- db(database.query(
    conn,
    select_notebook
      <> " where n.account_id = $1::uuid and n.deleted_at is null
           and lower(btrim(n.name)) = lower(btrim($2))
         order by n.id",
    [database.text(account_id), database.text(name)],
    decoder(),
  ))
  Ok(rows)
}

fn get_any(
  conn: Connection,
  account_id: String,
  notebook_id: String,
) -> Result(Notebook, AppError) {
  use notebook <- error.found(database.query_one(
    conn,
    select_notebook
      <> " where n.account_id = $1::uuid and n.id = $2::uuid
           and n.purge_requested_at is null",
    [database.text(account_id), database.text(notebook_id)],
    decoder(),
  ))
  Ok(notebook)
}

/// Active notebooks ordered by creation (IDs are time-ordered UUIDv7).
pub fn list(
  conn: Connection,
  account_id: String,
  after_id: Option(String),
  limit: Int,
) -> Result(List(Notebook), AppError) {
  use rows <- db(database.query(
    conn,
    select_notebook
      <> " where n.account_id = $1::uuid and n.deleted_at is null
           and ($2::uuid is null or n.id > $2::uuid)
         order by n.id limit $3",
    [
      database.text(account_id),
      database.nullable_text(after_id),
      database.int(limit),
    ],
    decoder(),
  ))
  Ok(rows)
}

pub fn list_trashed(
  conn: Connection,
  account_id: String,
  limit: Int,
) -> Result(List(Notebook), AppError) {
  use rows <- db(database.query(
    conn,
    select_notebook
      <> " where n.account_id = $1::uuid and n.deleted_at is not null
           and n.purge_requested_at is null
         order by n.deleted_at desc, n.id limit $2",
    [database.text(account_id), database.int(limit)],
    decoder(),
  ))
  Ok(rows)
}

pub type NotebookInput {
  NotebookInput(
    name: Option(String),
    description: Option(String),
    color: Option(String),
    private: Option(Bool),
  )
}

pub fn input_decoder() -> decode.Decoder(NotebookInput) {
  use name <- decode.optional_field("name", None, decode.optional(decode.string))
  use description <- decode.optional_field(
    "description",
    None,
    decode.optional(decode.string),
  )
  use color <- decode.optional_field("color", None, decode.optional(decode.string))
  // Omitted or null: false on create, unchanged on update.
  use private <- decode.optional_field("private", None, decode.optional(decode.bool))
  decode.success(NotebookInput(name:, description:, color:, private:))
}

fn validate(input: NotebookInput, require_name: Bool) -> Result(Nil, AppError) {
  let name_ok = case input.name {
    Some(name) -> {
      let length = string.length(string.trim(name))
      length >= 1 && length <= 200
    }
    None -> !require_name
  }
  let description_ok = case input.description {
    Some(d) -> string.length(d) <= 2000
    None -> True
  }
  let color_ok = case input.color {
    // An empty string clears the color.
    Some(c) -> c == "" || is_hex_color(c)
    None -> True
  }
  case name_ok, description_ok, color_ok {
    True, True, True -> Ok(Nil)
    False, _, _ -> Error(error.unprocessable("name must be 1-200 characters"))
    _, False, _ ->
      Error(error.unprocessable("description must be at most 2000 characters"))
    _, _, False -> Error(error.unprocessable("color must be #RRGGBB, or empty to clear it"))
  }
}

fn is_hex_color(value: String) -> Bool {
  case string.to_graphemes(value) {
    ["#", ..digits] ->
      list.length(digits) == 6
      && list.all(digits, fn(c) { string.contains("0123456789abcdefABCDEF", c) })
    _ -> False
  }
}

/// Create a notebook, enforcing the optional notebook-count limit.
pub fn create(
  conn: Connection,
  config: context.Config,
  account_id: String,
  input: NotebookInput,
) -> Result(Notebook, AppError) {
  use _ <- result.try(validate(input, True))
  use _ <- result.try(accounts.lock_active(conn, account_id))
  use usage <- result.try(quota.lock_usage(conn, account_id))
  use ent <- result.try(quota.entitlement(conn, config, account_id))
  use <- error.guard(
    context.fits(ent.notebooks, usage.notebooks, 1),
    error.new(409, "notebook_limit_reached", "The notebook limit has been reached.")
      |> error.with_details([#("limit", context.limit_json(ent.notebooks))]),
  )
  let id = uuid.v7_string()
  use _ <- db(database.execute(
    conn,
    "insert into notebooks (id, account_id, name, description, color, private)
     values ($1::uuid, $2::uuid, $3, $4, nullif($5, ''), coalesce($6, false))",
    [
      database.text(id),
      database.text(account_id),
      database.text(string.trim(option.unwrap(input.name, ""))),
      database.text(option.unwrap(input.description, "")),
      database.nullable_text(input.color),
      database.nullable_bool(input.private),
    ],
  ))
  use _ <- result.try(quota.adjust_usage(conn, account_id, 0, 0, 1))
  get(conn, account_id, id)
}

/// Update metadata. Requires If-Match on `version`; never changes
/// `numbering_revision`.
pub fn update(
  ctx: Context,
  account_id: String,
  notebook_id: String,
  if_match: Option(Int),
  input: NotebookInput,
) -> Result(Notebook, AppError) {
  use expected <- result.try(option.to_result(if_match, error.precondition_required()))
  use _ <- result.try(validate(input, False))
  context.transaction(ctx, fn(tx) {
    use _ <- result.try(accounts.lock_active(tx, account_id))
    use locked <- result.try(pages.lock_notebooks(tx, account_id, [notebook_id]))
    use <- error.guard(list.key_find(locked, notebook_id) == Ok(True), error.not_found())
    use notebook <- result.try(get(tx, account_id, notebook_id))
    use <- error.guard(notebook.version == expected, error.version_conflict())
    use _ <- db(database.execute(
      tx,
      "update notebooks set name = coalesce($3, name),
         description = coalesce($4, description), color = case when $5 = '' then null else coalesce($5, color) end,
         private = coalesce($6, private),
         version = version + 1, updated_at = now()
       where account_id = $1::uuid and id = $2::uuid",
      [
        database.text(account_id),
        database.text(notebook_id),
        database.nullable_text(option.map(input.name, string.trim)),
        database.nullable_text(input.description),
        database.nullable_text(input.color),
        database.nullable_bool(input.private),
      ],
    ))
    get(tx, account_id, notebook_id)
  })
}

/// Trash a notebook and its currently active children under one new
/// deletion batch. Pending uploads into it are cancelled and their
/// reservations released; pages already in trash keep their earlier batch.
pub fn trash(
  ctx: Context,
  account_id: String,
  notebook_id: String,
  if_match: Option(Int),
) -> Result(#(Notebook, journal.Intent), AppError) {
  context.transaction(ctx, fn(tx) {
    use _ <- result.try(accounts.lock_readable(tx, account_id))
    use _ <- result.try(quota.lock_usage(tx, account_id))
    use _ <- db(jobs.lock_account_slots(tx, account_id))
    use locked <- result.try(pages.lock_notebooks(tx, account_id, [notebook_id]))
    use <- error.guard(list.key_find(locked, notebook_id) == Ok(True), error.not_found())
    use notebook <- result.try(get(tx, account_id, notebook_id))
    use <- error.guard(
      case if_match {
        Some(v) -> v == notebook.version
        None -> True
      },
      error.version_conflict(),
    )
    use pending <- result.try(journal.pending_for_scope(tx, account_id, notebook_id))
    use <- error.guard(!pending, pages.recovery_pending())
    use children <- db(database.query(
      tx,
      "select id::text, visibility from pages
       where account_id = $1::uuid and notebook_id = $2::uuid
         and visibility <> 'trashed' order by id for update",
      [database.text(account_id), database.text(notebook_id)],
      {
        use id <- decode.field(0, decode.string)
        use visibility <- decode.field(1, decode.string)
        decode.success(#(id, visibility))
      },
    ))
    use <- error.guard(
      !list.any(children, fn(c) { c.1 == "restore_pending" }),
      pages.recovery_pending(),
    )
    // Settle live operations: placeholders end unaccepted, accepted pages
    // cancel pending work.
    use _ <- result.try(list.try_each(children, fn(child) {
      use live <- result.try(operations.live_for_page(tx, account_id, child.0))
      case live, child.1 {
        Some(op), "placeholder" ->
          operations.end_unaccepted(tx, account_id, op, "cancelled", None, Some("notebook_deleted"))
        Some(op), _ ->
          operations.end_accepted(tx, account_id, op, "deleted", None, None)
        None, _ -> Ok(Nil)
      }
    }))
    let batch = uuid.v7_string()
    use trashed <- db(database.query(
      tx,
      "update pages set visibility = 'trashed', deleted_at = now(),
         deletion_batch_id = $3::uuid, awaiting_processing = false,
         version = version + 1, updated_at = now()
       where account_id = $1::uuid and notebook_id = $2::uuid and visibility = 'active'
       returning id::text",
      [database.text(account_id), database.text(notebook_id), database.text(batch)],
      decode.at([0], decode.string),
    ))
    let count = list.length(trashed)
    use _ <- result.try(quota.adjust_usage(tx, account_id, 0 - count, 0, -1))
    use _ <- result.try(list.try_each(trashed, fn(id) {
      accounts.record_content_change(tx, account_id, id, "trash")
    }))
    use _ <- db(database.execute(
      tx,
      "update notebooks set deleted_at = now(), deletion_batch_id = $3::uuid,
         version = version + 1, numbering_revision = numbering_revision + 1,
         updated_at = now()
       where account_id = $1::uuid and id = $2::uuid",
      [database.text(account_id), database.text(notebook_id), database.text(batch)],
    ))
    use intent <- result.try(journal.record(
      tx,
      account_id,
      "notebook",
      notebook_id,
      notebook.version + 1,
      "trash",
      [
        #("deletion_batch_id", json.string(batch)),
        #("page_ids", json.array(trashed, json.string)),
      ],
    ))
    use notebook <- result.try(get_any(tx, account_id, notebook_id))
    Ok(#(notebook, intent))
  })
}

pub type RestoreRequest {
  RestoreRequest(page_ids: Option(List(String)), mappings: List(#(String, Int)))
}

pub fn restore_decoder() -> decode.Decoder(RestoreRequest) {
  use page_ids <- decode.optional_field(
    "page_ids",
    None,
    decode.optional(decode.list(decode.string)),
  )
  use mappings <- decode.optional_field(
    "page_numbers",
    [],
    decode.list({
      use page_id <- decode.field("page_id", decode.string)
      use number <- decode.field("page_number", decode.int)
      decode.success(#(page_id, number))
    }),
  )
  decode.success(RestoreRequest(page_ids:, mappings:))
}

/// Restore a notebook and its still-retained batch children atomically
/// (all-or-nothing for the selected set). Previously trashed children are
/// never implicitly restored. Children become active after the journal
/// acknowledges the restore intent.
pub fn restore(
  ctx: Context,
  account_id: String,
  notebook_id: String,
  request: RestoreRequest,
) -> Result(#(Notebook, journal.Intent), AppError) {
  context.transaction(ctx, fn(tx) {
    use _ <- result.try(accounts.lock_active(tx, account_id))
    use _ <- result.try(expiry.require_clean(tx, account_id, ctx.config.lazy_expiry_batch))
    use usage <- result.try(quota.lock_usage(tx, account_id))
    use ent <- result.try(quota.entitlement(tx, ctx.config, account_id))
    use locked <- result.try(pages.lock_notebooks(tx, account_id, [notebook_id]))
    use <- error.guard(list.key_find(locked, notebook_id) == Ok(False), error.not_found())
    use notebook <- result.try(get_any(tx, account_id, notebook_id))
    use pending <- result.try(journal.pending_for_scope(tx, account_id, notebook_id))
    use <- error.guard(!pending, pages.recovery_pending())
    use <- error.guard(
      context.fits(ent.notebooks, usage.notebooks, 1),
      error.new(409, "restore_conflict", "The notebook limit has been reached.")
        |> error.with_details([#("reason", json.string("notebook_limit_reached"))]),
    )
    let batch = option.unwrap(notebook.deletion_batch_id, "")
    use children <- db(database.query(
      tx,
      "select id::text, page_number from pages
       where account_id = $1::uuid and notebook_id = $2::uuid
         and visibility = 'trashed' and deletion_batch_id = $3::uuid
       order by id for update",
      [database.text(account_id), database.text(notebook_id), database.text(batch)],
      {
        use id <- decode.field(0, decode.string)
        use number <- decode.field(1, decode.int)
        decode.success(#(id, number))
      },
    ))
    let selected = case request.page_ids {
      None -> children
      Some(ids) -> {
        let ids = list.map(ids, string.lowercase)
        list.filter(children, fn(c) { list.contains(ids, c.0) })
      }
    }
    let targets =
      list.map(selected, fn(child) {
        case list.key_find(request.mappings, child.0) {
          Ok(number) -> #(child.0, number)
          Error(_) -> child
        }
      })
    use <- error.guard(
      context.fits(
        ent.stored_pages,
        usage.stored_pages + usage.reserved_page_slots,
        list.length(targets),
      ),
      error.new(409, "restore_conflict", "Not enough page capacity to restore.")
        |> error.with_details([
          #("reason", json.string("storage_limit_reached")),
          #("requested", json.int(list.length(targets))),
        ]),
    )
    use conflicts <- result.try(list.try_fold(targets, [], fn(acc, target) {
      use holder <- result.try(pages.number_holder(tx, notebook_id, target.1, target.0))
      let duplicate =
        list.count(targets, fn(other) { other.1 == target.1 }) > 1
      case holder, duplicate {
        None, False -> Ok(acc)
        _, _ ->
          Ok([
            json.object([
              #("page_id", json.string(target.0)),
              #("page_number", json.int(target.1)),
            ]),
            ..acc
          ])
      }
    }))
    use <- error.guard(
      conflicts == [],
      error.new(409, "restore_conflict", "Some page numbers are now in use.")
        |> error.with_details([
          #("conflicts", json.preprocessed_array(list.take(conflicts, 50))),
        ]),
    )
    use _ <- db(database.execute(
      tx,
      "update notebooks set deleted_at = null, deletion_batch_id = null,
         version = version + 1, numbering_revision = numbering_revision + 1,
         updated_at = now()
       where account_id = $1::uuid and id = $2::uuid",
      [database.text(account_id), database.text(notebook_id)],
    ))
    use _ <- result.try(quota.adjust_usage(tx, account_id, 0, list.length(targets), 1))
    use _ <- result.try(list.try_each(targets, fn(target) {
      use _ <- db(database.execute(
        tx,
        "update pages set visibility = 'restore_pending', page_number = $3,
           version = version + 1, updated_at = now()
         where account_id = $1::uuid and id = $2::uuid",
        [database.text(account_id), database.text(target.0), database.int(target.1)],
      ))
      Ok(Nil)
    }))
    use intent <- result.try(journal.record(
      tx,
      account_id,
      "notebook",
      notebook_id,
      notebook.version + 1,
      "restore",
      [
        #("pages", json.array(targets, fn(t) {
          json.object([
            #("page_id", json.string(t.0)),
            #("notebook_id", json.string(notebook_id)),
            #("page_number", json.int(t.1)),
          ])
        })),
      ],
    ))
    use notebook <- result.try(get(tx, account_id, notebook_id))
    Ok(#(notebook, intent))
  })
}
