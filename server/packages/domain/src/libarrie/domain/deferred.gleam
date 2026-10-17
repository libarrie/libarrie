//// Automatic admission of deferred pages (section 7). Off by default; an
//// account opts in through `PUT /v1/settings`. It uses exactly the
//// `process-deferred` contract: the same per-item checks and capacity
//// admission. Operation IDs are derived from the page and its source, so a
//// repeated or concurrent run never starts two operations for one source.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import libarrie/database
import libarrie/domain/context.{type Context}
import libarrie/domain/error.{type AppError, db}
import libarrie/domain/pages
import libarrie/domain/uploads
import youid/uuid

pub type Settings {
  Settings(auto_process_deferred: Bool)
}

pub fn settings_json(settings: Settings) -> json.Json {
  json.object([#("auto_process_deferred", json.bool(settings.auto_process_deferred))])
}

pub fn get(ctx: Context, account_id: String) -> Result(Settings, AppError) {
  use found <- error.found(database.query_one(
    ctx.db,
    "select auto_process_deferred from accounts where id = $1::uuid",
    [database.text(account_id)],
    decode.at([0], decode.bool),
  ))
  Ok(Settings(found))
}

pub fn decoder() -> decode.Decoder(Option(Bool)) {
  decode.optional_field("auto_process_deferred", None, decode.optional(decode.bool), decode.success)
}

/// `PUT /v1/settings`. Turning it on admits waiting pages on the next
/// maintenance run (within a minute).
pub fn update(ctx: Context, account_id: String, enabled: Option(Bool)) -> Result(Settings, AppError) {
  case enabled {
    None -> get(ctx, account_id)
    Some(value) -> {
      use _ <- db(database.execute(
        ctx.db,
        "update accounts set auto_process_deferred = $2 where id = $1::uuid and status = 'active'",
        [database.text(account_id), database.bool(value)],
      ))
      get(ctx, account_id)
    }
  }
}

/// Namespace for deterministic deferred-admission operation IDs.
fn namespace() -> uuid.Uuid {
  let assert Ok(ns) = uuid.from_string("9e3c1f62-7a4b-5d8e-a1c2-3b4d5e6f7081")
  ns
}

fn operation_id(page_id: String, revision_id: String) -> String {
  let assert Ok(id) = uuid.v5(namespace(), <<"deferred:", page_id:utf8, ":", revision_id:utf8>>)
  uuid.to_string(id)
}

/// The maintenance step: for opted-in accounts with waiting pages, admit as
/// many as capacity allows. Returns the operations started.
pub fn run(ctx: Context) -> Result(Int, AppError) {
  use accounts <- db(database.query(
    ctx.db,
    "select a.id::text from accounts a
     where a.auto_process_deferred and a.status = 'active'
       and exists (select 1 from pages p where p.account_id = a.id and p.awaiting_processing
                   and p.visibility = 'active')
     order by a.id limit 20",
    [],
    decode.at([0], decode.string),
  ))
  list.try_fold(accounts, 0, fn(started, account_id) {
    use waiting <- result.try(pages.list_awaiting_processing(ctx.db, account_id, 100))
    let items =
      list.filter_map(waiting, fn(page) {
        case page.revision_id {
          Some(revision) -> Ok(uploads.DeferredItem(page.id, revision, operation_id(page.id, revision)))
          None -> Error(Nil)
        }
      })
    case items {
      [] -> Ok(started)
      _ -> {
        use body <- result.try(uploads.process_deferred(ctx, account_id, items))
        let admitted =
          json.parse(json.to_string(body), decode.at(["results"], decode.list(decode.at(["result"], decode.string))))
          |> result.unwrap([])
          |> list.count(fn(r) { r == "admitted" })
        Ok(started + admitted)
      }
    }
  })
}
