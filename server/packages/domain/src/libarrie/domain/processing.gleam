//// Processing stages run by workers: recognition, indexing and fenced
//// publication (sections 7 and 8).
////
//// Provider calls happen outside database transactions. Every canonical
//// write happens in one fenced transaction that takes the shared lock order
//// (account, usage, job slots, notebook, page, revision, operation, search
//// release) and then locks the job row and validates the attempt token,
//// lease and stage deadline. Late results from a superseded attempt are
//// discarded.

import gleam/dynamic/decode
import gleam/float
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import libarrie/database.{type Connection}
import libarrie/domain/accounts
import libarrie/domain/context.{type Context}
import libarrie/domain/error.{type AppError, db}
import libarrie/domain/operations.{type Operation}
import libarrie/domain/pages
import libarrie/domain/quota
import libarrie/domain/search_configs
import libarrie/domain/spend
import libarrie/domain/text
import libarrie/integrations/providers
import libarrie/integrations/storage
import libarrie/jobs.{type Job}
import youid/uuid

pub type StageOutcome {
  Completed(summary: String)
  /// Transient failure: schedule another attempt.
  Retry(reason: String)
  /// Ownership was lost; results were discarded.
  Discarded
  /// Not a failure of the job: budget pause, open provider circuit or no
  /// free provider permit. Retry later without spending an attempt.
  Postpone(reason: String, seconds: Int)
}

fn lease_lost() -> AppError {
  error.new(409, "lease_lost", "job ownership lost")
}

/// Run `body` in the fenced transaction for `job`. The caller's body must
/// perform its own level 6-8 locks before calling `verify`.
fn fenced(
  ctx: Context,
  job: Job,
  account_id: String,
  page_id: Option(String),
  body: fn(Connection, fn() -> Result(Nil, AppError)) -> Result(String, AppError),
) -> Result(StageOutcome, AppError) {
  let outcome =
    context.transaction(ctx, fn(tx) {
      use _ <- result.try(accounts.lock(tx, account_id))
      use _ <- result.try(quota.lock_usage(tx, account_id))
      use _ <- db(jobs.lock_account_slots(tx, account_id))
      use _ <- result.try(case page_id {
        Some(page_id) -> {
          use notebook <- db(database.query_one(
            tx,
            "select notebook_id::text from pages where id = $1::uuid",
            [database.text(page_id)],
            decode.at([0], decode.string),
          ))
          use _ <- result.try(case notebook {
            Some(n) -> pages.lock_notebooks(tx, account_id, [n]) |> result.replace(Nil)
            None -> Ok(Nil)
          })
          pages.lock_pages(tx, account_id, [page_id])
        }
        None -> Ok(Nil)
      })
      let verify = fn() {
        use owned <- db(jobs.lock_owned(tx, job))
        case owned {
          True -> Ok(Nil)
          False -> Error(lease_lost())
        }
      }
      use summary <- result.try(body(tx, verify))
      use _ <- db(jobs.complete(tx, job))
      Ok(summary)
    })
  case outcome {
    Ok(summary) -> Ok(Completed(summary))
    Error(e) if e.code == "lease_lost" -> Ok(Discarded)
    Error(e) -> Error(e)
  }
}

/// A fenced transaction for search-migration work on one page: the same
/// lock order as publication, then the body, then job completion.
pub fn fenced_shadow(
  ctx: Context,
  job: Job,
  account_id: String,
  page_id: String,
  body: fn(Connection) -> Result(String, AppError),
) -> Result(StageOutcome, AppError) {
  fenced(ctx, job, account_id, Some(page_id), fn(tx, verify) {
    use _ <- result.try(verify())
    body(tx)
  })
}

/// Complete a job that has nothing left to do.
pub fn complete_without_account(ctx: Context, job: Job, summary: String) -> Result(StageOutcome, AppError) {
  let outcome =
    context.transaction(ctx, fn(tx) {
      use owned <- db(jobs.lock_owned(tx, job))
      case owned {
        False -> Error(lease_lost())
        True -> {
          use _ <- db(jobs.complete(tx, job))
          Ok(summary)
        }
      }
    })
  case outcome {
    Ok(summary) -> Ok(Completed(summary))
    Error(e) if e.code == "lease_lost" -> Ok(Discarded)
    Error(e) -> Error(e)
  }
}

/// Schedule a retry for an owned job (outside any domain transaction).
pub fn retry(ctx: Context, job: Job, reason: String) -> Result(Bool, AppError) {
  let outcome =
    context.transaction(ctx, fn(tx) {
      use _ <- result.try(case job.account_id {
        Some(account) -> jobs.lock_account_slots(tx, account) |> result.map_error(error.from_query)
        None -> Ok(Nil)
      })
      use owned <- db(jobs.lock_owned(tx, job))
      case owned {
        False -> Ok(False)
        True -> {
          use _ <- db(jobs.retry(tx, job, reason, ctx.config.jobs))
          Ok(True)
        }
      }
    })
  outcome
}

fn lock_revision(tx: Connection, revision_id: String) -> Result(Nil, AppError) {
  use _ <- db(database.execute(
    tx,
    "select 1 from page_revisions where id = $1::uuid for update",
    [database.text(revision_id)],
  ))
  Ok(Nil)
}

fn lock_release(tx: Connection, account_id: String) -> Result(String, AppError) {
  use release <- error.found(database.query_one(
    tx,
    "select r.id::text from accounts a join search_releases r
       on r.id = a.active_search_release_id
     where a.id = $1::uuid for update of r",
    [database.text(account_id)],
    decode.at([0], decode.string),
  ))
  Ok(release)
}

fn reload_operation(
  tx: Connection,
  account_id: String,
  job: Job,
) -> Result(Option(Operation), AppError) {
  case job.operation_id {
    Some(id) -> operations.load(tx, account_id, id, True)
    None -> Ok(None)
  }
}

// Recognition --------------------------------------------------------------------

type Source {
  Source(object_key: String, content_type: String, page_id: String)
}

pub fn recognize(
  ctx: Context,
  ocr: providers.OcrProvider,
  job: Job,
) -> Result(StageOutcome, AppError) {
  let assert Some(account_id) = job.account_id
  let assert Some(revision_id) = job.revision_id
  let assert Some(operation_id) = job.operation_id
  use op <- result.try(operations.require(ctx.db, account_id, operation_id, False))
  case operations.is_live(op) {
    False -> finish_noop(ctx, job, account_id, "operation " <> op.status)
    True -> {
      use source <- error.found(database.query_one(
        ctx.db,
        "select o.key, o.content_type, r.page_id::text from page_revisions r
         join objects o on o.id = r.source_object_id
         where r.account_id = $1::uuid and r.id = $2::uuid and o.state = 'stored'",
        [database.text(account_id), database.text(revision_id)],
        {
          use key <- decode.field(0, decode.string)
          use content_type <- decode.field(1, decode.string)
          use page_id <- decode.field(2, decode.string)
          decode.success(Source(key, content_type, page_id))
        },
      ))
      use _ <- db(database.execute(
        ctx.db,
        "update operations set status = 'recognizing', updated_at = now()
         where account_id = $1::uuid and id = $2::uuid and status = 'queued'",
        [database.text(account_id), database.text(operation_id)],
      ))
      case storage.get(ctx.config.storage, source.object_key) {
        Error(_) -> Ok(Retry("object_store_unavailable"))
        Ok(bytes) ->
          case
            spend.guarded(
              ctx,
              spend.Call(
                account_id: Some(account_id),
                operation_id: Some(operation_id),
                job_id: Some(job.id),
                provider: ocr.name <> ":" <> ocr.model_id,
                purpose: spend.Recognition,
                estimate_micros: ctx.config.spend.ocr_cost_micros,
              ),
              fn() { ocr.recognize(bytes, source.content_type) },
            )
          {
            Error(spend.BudgetExhausted) -> budget_pause(ctx, job, account_id, operation_id)
            Error(spend.CircuitOpen) -> Ok(Postpone("provider_unavailable", 30))
            Error(spend.NoPermit) -> Ok(Postpone("provider_permit_wait", 5))
            Error(spend.ProviderFailed(providers.Transient(detail))) -> {
              log_provider_error(job, detail)
              Ok(Retry("provider_transient"))
            }
            Error(spend.ProviderFailed(providers.InvalidOutput(detail))) -> {
              log_provider_error(job, detail)
              Ok(Retry("provider_invalid_output"))
            }
            // Invalid credentials pause processing (the circuit opens) rather
            // than exhausting every user job.
            Error(spend.ProviderFailed(providers.Misconfigured(detail))) -> {
              log_provider_error(job, detail)
              Ok(Postpone("provider_misconfigured", 300))
            }
            Ok(recognition) ->
              publish_recognition(ctx, ocr, job, account_id, source.page_id, revision_id, recognition)
          }
      }
    }
  }
}

/// The provider's own error, for operators. Only the classified reason is
/// stored on the job and shown to users.
fn log_provider_error(job: Job, detail: String) -> Nil {
  io.println("job " <> job.id <> " provider error: " <> string.slice(detail, 0, 1000))
}

fn finish_noop(
  ctx: Context,
  job: Job,
  account_id: String,
  summary: String,
) -> Result(StageOutcome, AppError) {
  fenced(ctx, job, account_id, None, fn(_tx, verify) {
    use _ <- result.try(verify())
    Ok(summary)
  })
}

fn publish_recognition(
  ctx: Context,
  ocr: providers.OcrProvider,
  job: Job,
  account_id: String,
  page_id: String,
  revision_id: String,
  recognition: providers.Recognition,
) -> Result(StageOutcome, AppError) {
  fenced(ctx, job, account_id, Some(page_id), fn(tx, verify) {
    use _ <- result.try(lock_revision(tx, revision_id))
    use op <- result.try(reload_operation(tx, account_id, job))
    use _ <- result.try(lock_release(tx, account_id))
    use _ <- result.try(verify())
    case op {
      Some(op) ->
        case operations.is_live(op) {
          False -> Ok("operation " <> op.status)
          True -> apply_recognition(ctx, tx, ocr, account_id, page_id, revision_id, op, recognition)
        }
      None -> Ok("no operation")
    }
  })
}

fn apply_recognition(
  ctx: Context,
  tx: Connection,
  ocr: providers.OcrProvider,
  account_id: String,
  page_id: String,
  revision_id: String,
  op: Operation,
  recognition: providers.Recognition,
) -> Result(String, AppError) {
  let #(outcome, raw_text, language) = case recognition {
    providers.TextDetected(text, language, _) -> #("text_detected", text, language)
    providers.BlankConfirmed -> #("blank_confirmed", "", None)
    providers.Unreadable -> #("unreadable", "", None)
    providers.UnsupportedContent -> #("unsupported_content", "", None)
    providers.NoTextDetected -> #("text_detected", "", None)
  }
  let ocr_id = uuid.v7_string()
  use _ <- db(database.execute(
    tx,
    "insert into ocr_results (id, account_id, revision_id, processing_version, raw_text,
       recognition_outcome, language, provider, model_id, boxes)
     values ($1::uuid, $2::uuid, $3::uuid, $4, $5, $6, $7, $8, $9, $10::text::jsonb)",
    [
      database.text(ocr_id),
      database.text(account_id),
      database.text(revision_id),
      database.text(ocr.processing_version),
      database.text(raw_text),
      database.text(outcome),
      database.nullable_text(language),
      database.text(ocr.name),
      database.text(ocr.model_id),
      database.nullable_text(boxes_json(recognition)),
    ],
  ))
  case recognition {
    providers.Unreadable ->
      needs_user_action(tx, account_id, op, "unreadable")
    providers.NoTextDetected ->
      needs_user_action(tx, account_id, op, "no_text_detected")
    providers.UnsupportedContent ->
      needs_user_action(tx, account_id, op, "unsupported_content")
    providers.BlankConfirmed -> {
      use transcript_id <- result.try(insert_transcript(tx, account_id, revision_id, Some(ocr_id), "", "ocr", True))
      use _ <- result.try(select_transcript(tx, account_id, revision_id, transcript_id))
      use _ <- result.try(publish_empty(ctx, tx, account_id, page_id, revision_id, transcript_id, Some(op)))
      Ok("ready_empty")
    }
    providers.TextDetected(text, _, _) -> {
      use keep_user_text <- result.try(case op.kind {
        "reprocess" -> selected_is_user(tx, account_id, revision_id)
        _ -> Ok(False)
      })
      case keep_user_text {
        // The saved user transcript stays selected; the new OCR text is a
        // candidate the user may explicitly accept. Processing succeeded.
        True -> {
          use _ <- result.try(quota.consume_processing(tx, account_id, op.id, op.charge_root_operation_id))
          use _ <- result.try(operations.set_status(tx, account_id, op.id, "ready", None, None, None))
          Ok("candidate_stored")
        }
        False -> {
          use transcript_id <- result.try(insert_transcript(tx, account_id, revision_id, Some(ocr_id), text, "ocr", False))
          use _ <- result.try(select_transcript(tx, account_id, revision_id, transcript_id))
          use _ <- result.try(operations.set_status(tx, account_id, op.id, "indexing", None, None, None))
          use _ <- db(database.execute(
            tx,
            "update page_revisions set status = 'indexing' where id = $1::uuid",
            [database.text(revision_id)],
          ))
          use _ <- result.try(enqueue_index(tx, account_id, page_id, revision_id, transcript_id, Some(op.id)))
          Ok("indexing")
        }
      }
    }
  }
}

/// Provider-reported text blocks with normalized boxes; `None` when the
/// provider reported none (boxes are never invented).
fn boxes_json(recognition: providers.Recognition) -> Option(String) {
  case recognition {
    providers.TextDetected(_, _, [_, ..] as blocks) ->
      Some(
        json.array(blocks, fn(b) {
          json.object([
            #("kind", json.string(b.kind)),
            #("text", json.string(b.text)),
            #("left", json.float(b.left)),
            #("top", json.float(b.top)),
            #("right", json.float(b.right)),
            #("bottom", json.float(b.bottom)),
            #("confidence", json.nullable(b.confidence, json.float)),
          ])
        })
        |> json.to_string,
      )
    _ -> None
  }
}

fn needs_user_action(
  tx: Connection,
  account_id: String,
  op: Operation,
  code: String,
) -> Result(String, AppError) {
  use _ <- result.try(operations.end_accepted(tx, account_id, op, "needs_user_action", None, Some(code)))
  Ok("needs_user_action:" <> code)
}

fn selected_is_user(
  tx: Connection,
  account_id: String,
  revision_id: String,
) -> Result(Bool, AppError) {
  use origin <- db(database.query_one(
    tx,
    "select t.origin from page_revisions r
     join transcript_revisions t on t.id = r.selected_transcript_revision_id
     where r.account_id = $1::uuid and r.id = $2::uuid",
    [database.text(account_id), database.text(revision_id)],
    decode.at([0], decode.string),
  ))
  Ok(origin == Some("user"))
}

pub fn insert_transcript(
  tx: Connection,
  account_id: String,
  revision_id: String,
  ocr_result_id: Option(String),
  text: String,
  origin: String,
  blank: Bool,
) -> Result(String, AppError) {
  let id = uuid.v7_string()
  use _ <- db(database.execute(
    tx,
    "insert into transcript_revisions (id, account_id, revision_id, parent_id,
       ocr_result_id, text, origin, blank)
     values ($1::uuid, $2::uuid, $3::uuid,
       (select selected_transcript_revision_id from page_revisions where id = $3::uuid),
       $4::uuid, $5, $6, $7)",
    [
      database.text(id),
      database.text(account_id),
      database.text(revision_id),
      database.nullable_text(ocr_result_id),
      database.text(text),
      database.text(origin),
      database.bool(blank),
    ],
  ))
  Ok(id)
}

pub fn select_transcript(
  tx: Connection,
  account_id: String,
  revision_id: String,
  transcript_id: String,
) -> Result(Nil, AppError) {
  use _ <- db(database.execute(
    tx,
    "update page_revisions set selected_transcript_revision_id = $3::uuid
     where account_id = $1::uuid and id = $2::uuid",
    [database.text(account_id), database.text(revision_id), database.text(transcript_id)],
  ))
  Ok(Nil)
}

pub fn enqueue_index(
  tx: Connection,
  account_id: String,
  page_id: String,
  revision_id: String,
  transcript_id: String,
  operation_id: Option(String),
) -> Result(Nil, AppError) {
  let key =
    "index:"
    <> option.unwrap(operation_id, "correction")
    <> ":"
    <> transcript_id
    <> ":g0"
  use _ <- db(jobs.enqueue(
    tx,
    jobs.NewJob(
      ..jobs.new_job("index", key),
      account_id: Some(account_id),
      operation_id:,
      page_id: Some(page_id),
      revision_id: Some(revision_id),
      transcript_revision_id: Some(transcript_id),
    ),
  ))
  Ok(Nil)
}

// Publication ----------------------------------------------------------------------

/// Publish a confirmed-blank transcript: an empty marker generation (no
/// passages, no embedding call) mapped into the active release. Replacement
/// by a confirmed blank removes the previous text result atomically.
pub fn publish_empty(
  ctx: Context,
  tx: Connection,
  account_id: String,
  page_id: String,
  revision_id: String,
  transcript_id: String,
  op: Option(Operation),
) -> Result(Nil, AppError) {
  let _ = ctx
  use release_id <- result.try(lock_release(tx, account_id))
  use configuration_id <- error.found(database.query_one(
    tx,
    "select configuration_id::text from search_releases where id = $1::uuid",
    [database.text(release_id)],
    decode.at([0], decode.string),
  ))
  let generation_id = uuid.v7_string()
  use _ <- db(database.execute(
    tx,
    "insert into index_generations (id, account_id, page_id, revision_id,
       transcript_revision_id, configuration_id, state)
     values ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6::uuid, 'empty')",
    [
      database.text(generation_id),
      database.text(account_id),
      database.text(page_id),
      database.text(revision_id),
      database.text(transcript_id),
      database.text(configuration_id),
    ],
  ))
  use _ <- result.try(map_release(tx, account_id, release_id, page_id, generation_id))
  use _ <- result.try(finish_publication(tx, account_id, page_id, revision_id, op, "ready_empty"))
  Ok(Nil)
}

pub fn map_release(
  tx: Connection,
  account_id: String,
  release_id: String,
  page_id: String,
  generation_id: String,
) -> Result(Nil, AppError) {
  use _ <- db(database.execute(
    tx,
    "update index_generations set state = 'superseded'
     where id = (select index_generation_id from search_release_pages
                 where release_id = $1::uuid and page_id = $2::uuid)",
    [database.text(release_id), database.text(page_id)],
  ))
  use _ <- db(database.execute(
    tx,
    "insert into search_release_pages (release_id, account_id, page_id, index_generation_id)
     values ($1::uuid, $2::uuid, $3::uuid, $4::uuid)
     on conflict (release_id, page_id) do update
       set index_generation_id = excluded.index_generation_id",
    [
      database.text(release_id),
      database.text(account_id),
      database.text(page_id),
      database.text(generation_id),
    ],
  ))
  Ok(Nil)
}

/// Source switch, revision/operation status and the one-time charge.
fn finish_publication(
  tx: Connection,
  account_id: String,
  page_id: String,
  revision_id: String,
  op: Option(Operation),
  status: String,
) -> Result(Nil, AppError) {
  use switched <- db(database.query(
    tx,
    "update pages set active_revision_id = pending_revision_id,
       pending_revision_id = null, content_version = content_version + 1,
       updated_at = now()
     where account_id = $1::uuid and id = $2::uuid and pending_revision_id = $3::uuid
     returning id::text",
    [database.text(account_id), database.text(page_id), database.text(revision_id)],
    decode.at([0], decode.string),
  ))
  use _ <- result.try(case switched {
    [] -> Ok(Nil)
    _ -> {
      use _ <- db(database.execute(
        tx,
        "update page_revisions set status = 'superseded'
         where account_id = $1::uuid and page_id = $2::uuid and id <> $3::uuid
           and status in ('ready', 'ready_empty', 'accepted', 'needs_user_action', 'indexing')",
        [database.text(account_id), database.text(page_id), database.text(revision_id)],
      ))
      Ok(Nil)
    }
  })
  use _ <- db(database.execute(
    tx,
    "update page_revisions set status = $2 where id = $1::uuid",
    [database.text(revision_id), database.text(status)],
  ))
  use _ <- result.try(accounts.record_content_change(tx, account_id, page_id, "publish"))
  case op {
    None -> Ok(Nil)
    Some(op) -> {
      use _ <- result.try(quota.consume_processing(tx, account_id, op.id, op.charge_root_operation_id))
      use _ <- result.try(settle_hold(tx, account_id, op))
      use _ <- db(database.execute(
        tx,
        "update operations set paused_since = null where account_id = $1::uuid and id = $2::uuid",
        [database.text(account_id), database.text(op.id)],
      ))
      operations.set_status(tx, account_id, op.id, status, None, None, None)
    }
  }
}

fn settle_hold(tx: Connection, account_id: String, op: Operation) -> Result(Nil, AppError) {
  use _ <- db(database.execute(
    tx,
    "update recovery_holds set state = 'consumed'
     where account_id = $1::uuid and active_retry_operation_id = $2::uuid
       and state = 'claimed'",
    [database.text(account_id), database.text(op.id)],
  ))
  Ok(Nil)
}

// Indexing --------------------------------------------------------------------------

type IndexInput {
  IndexInput(page_id: String, text: String, blank: Bool, selected: Bool)
}

pub fn index(ctx: Context, job: Job) -> Result(StageOutcome, AppError) {
  let assert Some(account_id) = job.account_id
  let assert Some(revision_id) = job.revision_id
  let assert Some(transcript_id) = job.transcript_revision_id
  use input <- error.found(database.query_one(
    ctx.db,
    "select r.page_id::text, t.text, t.blank,
       r.selected_transcript_revision_id = t.id
     from transcript_revisions t join page_revisions r on r.id = t.revision_id
     where t.account_id = $1::uuid and t.id = $2::uuid and r.id = $3::uuid",
    [database.text(account_id), database.text(transcript_id), database.text(revision_id)],
    {
      use page_id <- decode.field(0, decode.string)
      use text <- decode.field(1, decode.string)
      use blank <- decode.field(2, decode.bool)
      use selected <- decode.field(3, decode.bool)
      decode.success(IndexInput(page_id, text, blank, selected))
    },
  ))
  // Publish into the account's active release with that release's own
  // configuration: during a search migration the active release keeps its
  // earlier model until cutover (section 9).
  use #(_, configuration) <- result.try(search_configs.active(ctx.db, account_id))
  case input.selected, search_configs.provider(ctx, configuration) {
    // A newer correction superseded this transcript.
    False, _ -> finish_noop(ctx, job, account_id, "superseded transcript")
    // The release's model is no longer callable (deprecated before this
    // account was migrated): publish passages for word search only. The
    // migration's catch-up embeds them with the new model before cutover.
    True, None -> {
      let chunks = text.chunk(input.text) |> list.map(fn(c) { #(c, None) })
      publish_index(ctx, job, account_id, input, revision_id, transcript_id, configuration, chunks)
    }
    True, Some(embedder) -> {
      let chunks = text.chunk(input.text)
      let embedded = case chunks {
        [] -> Ok([])
        _ ->
          spend.guarded(
            ctx,
            spend.Call(
              account_id: Some(account_id),
              operation_id: job.operation_id,
              job_id: Some(job.id),
              provider: embedder.name <> ":" <> embedder.model_id,
              purpose: spend.DocumentEmbedding,
              estimate_micros: embedder.estimate_micros(list.map(chunks, fn(c) { c.text })),
            ),
            fn() {
              embedder.embed(list.map(chunks, fn(c) { c.text }), providers.Document)
            },
          )
      }
      case embedded {
        Error(spend.BudgetExhausted) ->
          case job.operation_id {
            Some(operation_id) -> budget_pause(ctx, job, account_id, operation_id)
            // Corrections carry no allocation; just wait for the window.
            None -> Ok(Postpone("operational_limit_reached", 900))
          }
        Error(spend.CircuitOpen) -> Ok(Postpone("provider_unavailable", 30))
        Error(spend.NoPermit) -> Ok(Postpone("provider_permit_wait", 5))
        Error(spend.ProviderFailed(providers.Misconfigured(_))) ->
          Ok(Postpone("provider_misconfigured", 300))
        Error(_) -> Ok(Retry("embedding_unavailable"))
        Ok(vectors) ->
          case list.length(vectors) == list.length(chunks)
            && list.all(vectors, fn(v) { list.length(v) == embedder.dimensions })
          {
            False -> Ok(Retry("embedding_invalid_output"))
            True ->
              publish_index(ctx, job, account_id, input, revision_id, transcript_id, configuration,
                list.zip(chunks, list.map(vectors, Some)))
          }
      }
    }
  }
}

fn publish_index(
  ctx: Context,
  job: Job,
  account_id: String,
  input: IndexInput,
  revision_id: String,
  transcript_id: String,
  configuration: search_configs.Configuration,
  passages: List(#(text.Chunk, Option(List(Float)))),
) -> Result(StageOutcome, AppError) {
  let configuration_id = configuration.id
  fenced(ctx, job, account_id, Some(input.page_id), fn(tx, verify) {
    use _ <- result.try(lock_revision(tx, revision_id))
    use op <- result.try(reload_operation(tx, account_id, job))
    use release_id <- result.try(lock_release(tx, account_id))
    use _ <- result.try(verify())
    // Publication preconditions, all under lock.
    use state <- db(database.query_one(
      tx,
      "select p.visibility = 'active' and n.deleted_at is null
         and (p.active_revision_id = r.id or p.pending_revision_id = r.id)
         and r.selected_transcript_revision_id = $3::uuid,
         rel.configuration_id = $4::uuid
       from pages p join notebooks n on n.id = p.notebook_id
       join page_revisions r on r.id = $2::uuid
       join accounts a on a.id = p.account_id
       join search_releases rel on rel.id = a.active_search_release_id
       where p.id = $1::uuid",
      [
        database.text(input.page_id),
        database.text(revision_id),
        database.text(transcript_id),
        database.text(configuration_id),
      ],
      {
        use publishable <- decode.field(0, decode.bool)
        use compatible <- decode.field(1, decode.bool)
        decode.success(#(publishable, compatible))
      },
    ))
    let op_ok = case op {
      Some(op) -> op.status == "indexing"
      None -> True
    }
    case state, op_ok {
      Some(#(True, True)), True -> {
        use _ <- result.try(case input.blank || passages == [] {
          True ->
            publish_empty(ctx, tx, account_id, input.page_id, revision_id, transcript_id, op)
          False -> {
            use generation_id <- result.try(insert_generation(
              tx,
              account_id,
              input.page_id,
              revision_id,
              transcript_id,
              configuration,
              "published",
              passages,
            ))
            use _ <- result.try(map_release(tx, account_id, release_id, input.page_id, generation_id))
            finish_publication(tx, account_id, input.page_id, revision_id, op, "ready")
          }
        })
        Ok("published")
      }
      // A cutover overtook this work between embedding and publication:
      // never publish incompatible vectors. Roll back; the retry embeds
      // with the current configuration and nothing is charged.
      Some(#(True, False)), True ->
        Error(error.new(503, "search_migration_required", "configuration changed"))
      _, _ -> Ok("stale; not published")
    }
  })
}

/// One generation: passages normalized with the configuration's version and,
/// when the model is callable, their embeddings.
pub fn insert_generation(
  tx: Connection,
  account_id: String,
  page_id: String,
  revision_id: String,
  transcript_id: String,
  configuration: search_configs.Configuration,
  state: String,
  passages: List(#(text.Chunk, Option(List(Float)))),
) -> Result(String, AppError) {
  let configuration_id = configuration.id
  let generation_id = uuid.v7_string()
  use _ <- db(database.execute(
    tx,
    "insert into index_generations (id, account_id, page_id, revision_id,
       transcript_revision_id, configuration_id, state)
     values ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6::uuid, $7)",
    [
      database.text(generation_id),
      database.text(account_id),
      database.text(page_id),
      database.text(revision_id),
      database.text(transcript_id),
      database.text(configuration_id),
      database.text(state),
    ],
  ))
  use _ <- result.try(list.try_each(passages, fn(entry) {
    let #(chunk, vector) = entry
    let passage_id = uuid.v7_string()
    use _ <- db(database.execute(
      tx,
      "insert into passages (id, account_id, index_generation_id, ordinal, text,
         normalized_text, start_offset, end_offset)
       values ($1::uuid, $2::uuid, $3::uuid, $4, $5, $6, $7, $8)",
      [
        database.text(passage_id),
        database.text(account_id),
        database.text(generation_id),
        database.int(chunk.ordinal),
        database.text(chunk.text),
        database.text(text.normalize_with(configuration.normalization_version, chunk.text)),
        database.int(chunk.start_offset),
        database.int(chunk.end_offset),
      ],
    ))
    case vector {
      None -> Ok(Nil)
      Some(vector) -> {
        use _ <- db(database.execute(
          tx,
          "insert into embeddings (passage_id, account_id, index_generation_id,
             configuration_id, embedding, model_id, dimensions)
           values ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::text::vector, $6, $7)",
          [
            database.text(passage_id),
            database.text(account_id),
            database.text(generation_id),
            database.text(configuration_id),
            database.text(vector_literal(vector)),
            database.text(configuration.model),
            database.int(configuration.dimensions),
          ],
        ))
        Ok(Nil)
      }
    }
  }))
  Ok(generation_id)
}

pub fn vector_literal(vector: List(Float)) -> String {
  "[" <> { vector |> list.map(float.to_string) |> string.join(",") } <> "]"
}

/// Budget exhaustion pauses the operation (reservation stays attached) up
/// to a bounded maximum, after which it fails with a system fault and its
/// allocation moves into a recovery hold.
fn budget_pause(
  ctx: Context,
  job: Job,
  account_id: String,
  operation_id: String,
) -> Result(StageOutcome, AppError) {
  use paused <- error.found(database.query_one(
    ctx.db,
    "update operations set paused_since = coalesce(paused_since, now()),
       error_code = 'operational_limit_reached', updated_at = now()
     where account_id = $1::uuid and id = $2::uuid
     returning extract(epoch from now() - paused_since)::int",
    [database.text(account_id), database.text(operation_id)],
    decode.at([0], decode.int),
  ))
  case paused >= ctx.config.spend.max_pause_seconds {
    True -> fail_exhausted(ctx, job, "operational_limit_reached")
    False -> Ok(Postpone("operational_limit_reached", 900))
  }
}

/// Postpone an owned job without spending an attempt.
pub fn postpone(ctx: Context, job: Job, reason: String, seconds: Int) -> Result(Bool, AppError) {
  context.transaction(ctx, fn(tx) {
    use _ <- result.try(case job.account_id {
      Some(account) -> jobs.lock_account_slots(tx, account) |> result.map_error(error.from_query)
      None -> Ok(Nil)
    })
    use owned <- db(jobs.lock_owned(tx, job))
    case owned {
      False -> Ok(False)
      True -> {
        use _ <- db(jobs.postpone(tx, job, reason, seconds))
        Ok(True)
      }
    }
  })
}

// Exhausted attempts --------------------------------------------------------------

/// Terminal handling when a job has used all attempts. A billable operation
/// fails with `failure_fault: system` and keeps its allocation in a recovery
/// hold; correction indexing just stops (saved text is unaffected).
pub fn fail_exhausted(
  ctx: Context,
  job: Job,
  reason: String,
) -> Result(StageOutcome, AppError) {
  let assert Some(account_id) = job.account_id
  let outcome =
    context.transaction(ctx, fn(tx) {
      use _ <- result.try(accounts.lock(tx, account_id))
      use _ <- result.try(quota.lock_usage(tx, account_id))
      use _ <- db(jobs.lock_account_slots(tx, account_id))
      use _ <- result.try(case job.page_id {
        Some(page_id) -> pages.lock_pages(tx, account_id, [page_id])
        None -> Ok(Nil)
      })
      use op <- result.try(reload_operation(tx, account_id, job))
      use owned <- db(jobs.lock_owned(tx, job))
      use <- error.guard(owned, lease_lost())
      use _ <- result.try(case op {
        Some(op) ->
          case operations.is_live(op) {
            True -> operations.fail_system(tx, ctx.config, account_id, op, reason)
            False -> Ok(Nil)
          }
        None -> Ok(Nil)
      })
      use _ <- db(jobs.fail(tx, job, reason))
      Ok("failed: " <> reason)
    })
  case outcome {
    Ok(summary) -> Ok(Completed(summary))
    Error(e) if e.code == "lease_lost" -> Ok(Discarded)
    Error(e) -> Error(e)
  }
}

pub fn outcome_json(outcome: StageOutcome) -> json.Json {
  case outcome {
    Completed(summary) -> json.object([#("completed", json.string(summary))])
    Retry(reason) -> json.object([#("retry", json.string(reason))])
    Discarded -> json.object([#("discarded", json.bool(True))])
    Postpone(reason, seconds) ->
      json.object([#("postponed", json.string(reason)), #("seconds", json.int(seconds))])
  }
}
