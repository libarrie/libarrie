//// Libarrie core worker (section 8).
////
//// Each runner claims one job at a time, runs the stage in a separate
//// process and keeps the lease alive from the runner, so heartbeats stay
//// responsive during provider calls. If renewal fails (token changed, lease
//// expired, stage deadline reached or the database is unreachable) the
//// runner stops the stage process and initiates no further side effects;
//// fenced publication rejects any late result. A stage process that crashes
//// is detected through a monitor and counts as an attempt. Graceful shutdown
//// relies on lease expiry for unfinished work.
////
//// Periodic maintenance runs as deduplicated, leased `maint:<task>` jobs:
//// every replica's scheduler enqueues one job per task and time bucket, and
//// exactly one runner executes it.

import argv
import envoy
import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import libarrie/database
import libarrie/domain/closure
import libarrie/domain/context.{type Context}
import libarrie/domain/derived
import libarrie/domain/error.{type AppError}
import libarrie/domain/exports
import libarrie/domain/maintenance.{type Services}
import libarrie/domain/moderation
import libarrie/domain/processing
import libarrie/domain/search_migration
import libarrie/domain/settings
import libarrie/integrations/providers
import libarrie/integrations/storage
import libarrie/jobs.{type Job}

pub fn stages() -> List(String) {
  list.append(
    [
      "recognize", "index", "derive", "export_part", "export_finalize",
      "account_closure_deadline", "account_purge", "shadow_index",
    ],
    list.map(maintenance.tasks, fn(t) { maintenance.stage(t.0) }),
  )
}

pub fn main() -> Nil {
  case settings.load() {
    Error(message) -> io.println_error("configuration error: " <> message)
    Ok(config) -> {
      let assert Ok(conn) =
        database.connect(config.database_url, config.database_pool_size)
      let ctx = context.Context(db: conn, config: config.domain)
      let services = services(config)
      let runners =
        envoy.get("WORKER_CONCURRENCY")
        |> result.try(int.parse)
        |> result.unwrap(4)
      let owner =
        "worker-"
        <> {
          crypto.strong_random_bytes(6)
          |> bit_array.base16_encode
          |> string.lowercase
        }
      let _ = storage.ensure_bucket(services.journal_store)
      let ocr = config.ocr
      case argv.load().arguments {
        ["once"] -> {
          // Drain available work once (used by tests and operators).
          process.sleep(500)
          schedule_periodic(ctx)
          drain(ctx, services, ocr, owner)
          log("drained")
          halt(0)
        }
        _ -> {
          log(
            "libarrie worker "
            <> owner
            <> " starting "
            <> int.to_string(runners)
            <> " runner(s)",
          )
          int.range(from: 1, to: runners + 1, with: Nil, run: fn(_, i) {
            process.spawn(fn() {
              runner_loop(ctx, services, ocr, owner <> "-" <> int.to_string(i))
            })
            Nil
          })
          process.spawn(fn() { scheduler_loop(ctx) })
          process.sleep_forever()
        }
      }
    }
  }
}

pub fn services(config: settings.Settings) -> Services {
  maintenance.Services(
    journal_store: config.domain.journal_store,
    subscriber: settings.subscriber_client(config),
  )
}

fn scheduler_loop(ctx: Context) -> Nil {
  schedule_periodic(ctx)
  process.sleep(1000)
  scheduler_loop(ctx)
}

/// Enqueue one maintenance job per task and time bucket (deduplicated).
pub fn schedule_periodic(ctx: Context) -> Nil {
  let #(now, _) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  list.each(maintenance.tasks, fn(task) {
    let #(name, interval) = task
    let _ =
      jobs.enqueue_periodic(
        ctx.db,
        maintenance.stage(name),
        int.to_string(now / interval),
        Some(600),
      )
    Nil
  })
}

fn runner_loop(
  ctx: Context,
  services: Services,
  ocr: providers.OcrProvider,
  owner: String,
) -> Nil {
  case jobs.claim(ctx.db, owner, stages(), ctx.config.jobs, 1) {
    Ok([job]) -> {
      run_job(ctx, services, ocr, job)
      runner_loop(ctx, services, ocr, owner)
    }
    Ok(_) -> {
      process.sleep(1000)
      runner_loop(ctx, services, ocr, owner)
    }
    Error(e) -> {
      log("claim failed: " <> database.describe(e))
      process.sleep(2000)
      runner_loop(ctx, services, ocr, owner)
    }
  }
}

/// Claim and run everything currently available, sequentially.
pub fn drain(
  ctx: Context,
  services: Services,
  ocr: providers.OcrProvider,
  owner: String,
) -> Nil {
  case jobs.claim(ctx.db, owner, stages(), ctx.config.jobs, 1) {
    Ok([job]) -> {
      run_job(ctx, services, ocr, job)
      drain(ctx, services, ocr, owner)
    }
    _ -> Nil
  }
}

/// Normalized result of any stage.
pub type Outcome {
  Finished(summary: String)
  RetryLater(reason: String)
  PostponeFor(reason: String, seconds: Int)
  Lost
  ExportFailed(code: String)
}

type StageMessage {
  StageResult(Result(Outcome, AppError))
  StageCrashed(reason: String)
}

pub fn run_job(
  ctx: Context,
  services: Services,
  ocr: providers.OcrProvider,
  job: Job,
) -> Nil {
  case jobs.exhausted(job) {
    True -> terminal(ctx, job, "attempts_exhausted")
    False -> {
      let results = process.new_subject()
      let worker =
        process.spawn_unlinked(fn() {
          process.send(results, StageResult(run_stage(ctx, services, ocr, job)))
        })
      let monitor = process.monitor(worker)
      let selector =
        process.new_selector()
        |> process.select(results)
        |> process.select_specific_monitor(monitor, fn(down) {
          StageCrashed(string.inspect(down.reason))
        })
      let heartbeat_ms = int.max(1000, ctx.config.jobs.lease_seconds * 1000 / 4)
      let outcome = await(ctx, job, selector, worker, heartbeat_ms)
      process.demonitor_process(monitor)
      case outcome {
        Error(Nil) -> log("job " <> job.id <> " lost ownership; stage stopped")
        Ok(StageCrashed(reason)) -> {
          log("job " <> job.id <> " stage crashed: " <> reason)
          retry_or_fail(ctx, job, "stage_crashed")
        }
        Ok(StageResult(Error(e))) -> {
          log(
            "job " <> job.id <> " error " <> e.code <> " " <> string.inspect(e.details),
          )
          retry_or_fail(ctx, job, e.code)
        }
        Ok(StageResult(Ok(result))) -> handle(ctx, job, result)
      }
    }
  }
}

fn handle(ctx: Context, job: Job, outcome: Outcome) -> Nil {
  case outcome {
    Finished(summary) -> report(job, summary)
    Lost -> log("job " <> job.id <> " lost ownership; result discarded")
    RetryLater(reason) -> retry_or_fail(ctx, job, reason)
    PostponeFor(reason, seconds) -> {
      let _ = processing.postpone(ctx, job, reason, seconds)
      report(job, "postponed (" <> reason <> ")")
    }
    ExportFailed(code) -> {
      let _ = exports.fail(ctx, job, code)
      report(job, "export failed: " <> code)
    }
  }
}

fn retry_or_fail(ctx: Context, job: Job, reason: String) -> Nil {
  case job.attempts >= job.max_attempts {
    True -> terminal(ctx, job, reason)
    False -> {
      let _ = processing.retry(ctx, job, reason)
      log("job " <> job.id <> " retry: " <> reason)
    }
  }
}

/// Terminal handling once attempts are exhausted.
fn terminal(ctx: Context, job: Job, reason: String) -> Nil {
  case job.stage {
    "recognize" | "index" ->
      case processing.fail_exhausted(ctx, job, reason) {
        Ok(o) -> report(job, json.to_string(processing.outcome_json(o)))
        Error(e) -> log("job " <> job.id <> " failed: " <> e.code)
      }
    "export_part" | "export_finalize" -> {
      let _ = exports.fail(ctx, job, reason)
      report(job, "export failed: " <> reason)
    }
    _ -> {
      // Lifecycle and maintenance jobs alert operators rather than failing
      // silently.
      log("ALERT job " <> job.id <> " " <> job.stage <> " exhausted: " <> reason)
      let _ = complete_plain(ctx, job, Some(reason))
      Nil
    }
  }
}

fn await(
  ctx: Context,
  job: Job,
  selector: process.Selector(StageMessage),
  worker: process.Pid,
  heartbeat_ms: Int,
) -> Result(StageMessage, Nil) {
  case process.selector_receive(selector, heartbeat_ms) {
    Ok(message) -> Ok(message)
    Error(Nil) ->
      case jobs.heartbeat(ctx.db, job, ctx.config.jobs) {
        Ok(True) -> await(ctx, job, selector, worker, heartbeat_ms)
        // Lost or unknowable ownership: stop initiating side effects.
        _ -> {
          process.kill(worker)
          Error(Nil)
        }
      }
  }
}

fn run_stage(
  ctx: Context,
  services: Services,
  ocr: providers.OcrProvider,
  job: Job,
) -> Result(Outcome, AppError) {
  // Processing for a blocked account waits until it is unblocked
  // (unblocking makes these jobs runnable at once).
  let paused = case job.stage, job.account_id {
    "recognize", Some(account) | "index", Some(account) | "derive", Some(account)
    | "shadow_index", Some(account) -> moderation.suspended(ctx.db, account)
    _, _ -> Ok(False)
  }
  case paused {
    Ok(True) -> Ok(PostponeFor("account_suspended", 3600))
    Error(e) -> Error(e)
    Ok(False) -> run_unpaused_stage(ctx, services, ocr, job)
  }
}

fn run_unpaused_stage(
  ctx: Context,
  services: Services,
  ocr: providers.OcrProvider,
  job: Job,
) -> Result(Outcome, AppError) {
  case job.stage {
    "recognize" ->
      processing.recognize(ctx, ocr, job) |> result.map(from_processing)
    "index" -> processing.index(ctx, job) |> result.map(from_processing)
    "shadow_index" -> search_migration.shadow_index(ctx, job) |> result.map(from_processing)
    "derive" ->
      derived.run(ctx, job)
      |> result.map(fn(outcome) {
        case outcome {
          derived.Done(summary) -> Finished(summary)
          derived.Skipped(reason) -> Finished("derived images skipped: " <> reason)
          derived.RetryLater(reason) -> RetryLater(reason)
          derived.LeaseLost -> Lost
        }
      })
    "export_part" -> exports.assemble_part(ctx, job) |> result.map(from_export)
    "export_finalize" -> exports.finalize(ctx, job) |> result.map(from_export)
    "account_closure_deadline" ->
      closure.run_deadline(ctx, job) |> result.map(from_closure)
    "account_purge" -> closure.run_purge(ctx, job) |> result.map(from_closure)
    "maint:" <> task -> {
      use summary <- result.try(maintenance.run(ctx, services, task))
      use owned <- result.try(complete_plain(ctx, job, None))
      case owned {
        True -> Ok(Finished(summary))
        False -> Ok(Lost)
      }
    }
    other -> Error(error.internal("unsupported stage " <> other))
  }
}

fn from_processing(outcome: processing.StageOutcome) -> Outcome {
  case outcome {
    processing.Completed(summary) -> Finished(summary)
    processing.Retry(reason) -> RetryLater(reason)
    processing.Discarded -> Lost
    processing.Postpone(reason, seconds) -> PostponeFor(reason, seconds)
  }
}

fn from_export(outcome: exports.AssemblyResult) -> Outcome {
  case outcome {
    exports.Assembled(summary) -> Finished(summary)
    exports.Stale -> Finished("stale export work discarded")
    exports.Failed(code) -> ExportFailed(code)
    exports.Unavailable -> RetryLater("object_store_unavailable")
  }
}

fn from_closure(outcome: closure.StageResult) -> Outcome {
  case outcome {
    closure.Done(summary) -> Finished(summary)
    closure.NotYet -> PostponeFor("waiting_for_prerequisite", 30)
    closure.LeaseLost -> Lost
    // Not a retry: postponing does not spend an attempt.
    closure.Continue(summary) -> PostponeFor(summary, 0)
  }
}

/// Complete (or, with a reason, fail) a job after verifying ownership.
fn complete_plain(
  ctx: Context,
  job: Job,
  failure: option.Option(String),
) -> Result(Bool, AppError) {
  context.transaction(ctx, fn(tx) {
    use owned <- result.try(
      jobs.lock_owned(tx, job) |> result.map_error(error.from_query),
    )
    case owned, failure {
      False, _ -> Ok(False)
      True, None ->
        jobs.complete(tx, job)
        |> result.map_error(error.from_query)
        |> result.replace(True)
      True, Some(reason) ->
        jobs.fail(tx, job, reason)
        |> result.map_error(error.from_query)
        |> result.replace(True)
    }
  })
}

fn report(job: Job, summary: String) -> Nil {
  log(
    "job "
    <> job.id
    <> " "
    <> job.stage
    <> " attempt "
    <> int.to_string(job.attempts)
    <> ": "
    <> summary,
  )
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

fn log(message: String) -> Nil {
  io.println(message)
}
