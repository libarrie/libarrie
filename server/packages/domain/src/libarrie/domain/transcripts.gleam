//// Transcript corrections (section 5).
////
//// A correction uses If-Match on `content_version` plus the target source
//// and base transcript IDs. It saves and selects a new user transcript
//// immediately, records a content change and queues indexing. Corrections
//// consume no successful-page processing unit.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import libarrie/database
import libarrie/domain/accounts
import libarrie/domain/context.{type Context}
import libarrie/domain/error.{type AppError, db}
import libarrie/domain/operations
import libarrie/domain/pages
import libarrie/domain/processing
import libarrie/domain/quota
import libarrie/domain/ratelimit
import libarrie/jobs

pub type Action {
  Save(text: String)
  AcceptCandidate(ocr_result_id: String)
  ConfirmBlank
}

pub type Request {
  Request(
    source_revision_id: String,
    base_transcript_revision_id: Option(String),
    action: Action,
  )
}

pub fn decoder() -> decode.Decoder(Request) {
  use source <- decode.field("source_revision_id", decode.string)
  use base <- decode.optional_field(
    "base_transcript_revision_id",
    None,
    decode.optional(decode.string),
  )
  use action <- decode.optional_field("action", "save", decode.string)
  use text <- decode.optional_field("text", None, decode.optional(decode.string))
  use candidate <- decode.optional_field(
    "ocr_result_id",
    None,
    decode.optional(decode.string),
  )
  let parsed = case action, text, candidate {
    "save", Some(t), _ -> Ok(Save(t))
    "accept_candidate", _, Some(id) -> Ok(AcceptCandidate(string.lowercase(id)))
    "confirm_blank", _, _ -> Ok(ConfirmBlank)
    _, _, _ -> Error(Nil)
  }
  case parsed {
    Ok(action) ->
      decode.success(Request(
        string.lowercase(source),
        option.map(base, string.lowercase),
        action,
      ))
    Error(_) ->
      decode.failure(Request("", None, ConfirmBlank), "action with its fields")
  }
}

const max_transcript_length = 200_000

pub fn save(
  ctx: Context,
  account_id: String,
  page_id: String,
  if_match: Option(Int),
  request: Request,
) -> Result(pages.Page, AppError) {
  use expected <- result.try(option.to_result(if_match, error.precondition_required()))
  use <- error.guard(
    case request.action {
      Save(text) -> string.length(text) <= max_transcript_length
      _ -> True
    },
    error.unprocessable("The transcript is too long."),
  )
  context.transaction(ctx, fn(tx) {
    use _ <- result.try(accounts.lock_active(tx, account_id))
    use _ <- result.try(quota.lock_usage(tx, account_id))
    use _ <- db(jobs.lock_account_slots(tx, account_id))
    use page <- result.try(pages.get(tx, account_id, page_id))
    use _ <- result.try(pages.lock_notebooks(tx, account_id, [page.notebook_id]))
    use _ <- result.try(pages.lock_pages(tx, account_id, [page_id]))
    use page <- result.try(pages.get(tx, account_id, page_id))
    use <- error.guard(page.content_version == expected, error.version_conflict())
    use _ <- result.try(ratelimit.corrections(
      tx,
      account_id,
      page_id,
      ctx.config.rate_limits.corrections_per_page_hour,
    ))
    use <- error.guard(
      page.revision_id == Some(request.source_revision_id),
      error.version_conflict(),
    )
    use <- error.guard(
      case request.base_transcript_revision_id {
        Some(base) -> page.transcript_revision_id == Some(base)
        None -> True
      },
      error.version_conflict(),
    )
    // A pending source replacement or OCR reprocess blocks edits; every
    // client can see which operation blocks and offer to wait or cancel.
    use live <- result.try(operations.live_for_page(tx, account_id, page_id))
    use _ <- result.try(case live {
      Some(op) -> Error(operations.conflict(op))
      None -> Ok(Nil)
    })
    let revision_id = request.source_revision_id
    use transcript_id <- result.try(case request.action {
      Save(text) ->
        processing.insert_transcript(tx, account_id, revision_id, None, text, "user", False)
      ConfirmBlank ->
        processing.insert_transcript(tx, account_id, revision_id, None, "", "user", True)
      AcceptCandidate(ocr_result_id) -> {
        use raw <- error.found(database.query_one(
          tx,
          "select raw_text from ocr_results
           where account_id = $1::uuid and id = $2::uuid and revision_id = $3::uuid",
          [
            database.text(account_id),
            database.text(ocr_result_id),
            database.text(revision_id),
          ],
          decode.at([0], decode.string),
        ))
        processing.insert_transcript(
          tx,
          account_id,
          revision_id,
          Some(ocr_result_id),
          raw,
          "ocr",
          False,
        )
      }
    })
    use _ <- result.try(processing.select_transcript(tx, account_id, revision_id, transcript_id))
    use _ <- db(database.execute(
      tx,
      "update pages set content_version = content_version + 1,
         awaiting_processing = false, updated_at = now()
       where account_id = $1::uuid and id = $2::uuid",
      [database.text(account_id), database.text(page_id)],
    ))
    use _ <- result.try(accounts.record_content_change(tx, account_id, page_id, "correction"))
    // Further corrections supersede obsolete indexing work.
    use _ <- db(jobs.cancel_for_page_stage(tx, account_id, page_id, "index"))
    use _ <- result.try(case request.action {
      ConfirmBlank ->
        processing.publish_empty(ctx, tx, account_id, page_id, revision_id, transcript_id, None)
      _ ->
        processing.enqueue_index(tx, account_id, page_id, revision_id, transcript_id, None)
    })
    pages.get(tx, account_id, page_id)
  })
}

pub fn response_json(page: pages.Page) -> json.Json {
  json.object([#("page", pages.to_json(page))])
}
