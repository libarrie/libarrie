//// Per-account search migration (section 9).
////
//// When the deployment's search configuration changes (a new embedding
//// model, dimension or text normalization), `libarrie_api reindex` starts
//// a migration for each account:
////
//// 1. **Shadow release.** A release on the new configuration, with a
////    snapshot of the account content sequence S. Every searchable page of
////    the active release is queued for a `shadow_index` job; confirmed-blank
////    pages get an empty marker directly. The active release keeps serving
////    search, and new or corrected pages keep publishing into it with its
////    own model.
//// 2. **Catch-up.** The maintenance task replays the account's content-change
////    log past the shadow watermark, coalescing changes per page, and
////    re-queues or removes pages. Applying changes to a shadow never appends
////    content changes, so catch-up cannot feed itself.
//// 3. **Cutover.** Under the account lock shared by every content writer,
////    and only when the watermark equals the current sequence, no shadow job
////    is pending and every searchable page maps to the same source and
////    transcript in both releases, the active pointer swaps in one short
////    transaction. No embedding happens while locks are held.
//// 4. **Retention and rollback.** The previous release stays `retired` for
////    seven days (`rollback_unavailable` if its model is no longer callable).
////    Rollback makes it the shadow again and replays the change log into it
////    under the same checks; it is never a pointer flip. A rolled-back
////    account is held until an operator runs `reindex` again.
////
//// Migration work carries no processing allocation (users are never
//// charged), uses its own spend purpose, and occupies no account job slots.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import libarrie/database.{type Connection}
import libarrie/domain/accounts
import libarrie/domain/context.{type Context}
import libarrie/domain/error.{type AppError, db}
import libarrie/domain/processing
import libarrie/domain/search_configs
import libarrie/domain/spend
import libarrie/domain/text
import libarrie/integrations/providers
import libarrie/jobs.{type Job}
import youid/uuid

/// How long a replaced release is kept for rollback.
pub const retention_seconds = 604_800

const catch_up_batch = 500

// Starting -----------------------------------------------------------------------------------

/// `reindex`: clear rollback holds and start migrations for up to `batch`
/// accounts not on the deployment's configuration. Call until it returns 0.
pub fn start_all(ctx: Context, batch: Int) -> Result(Int, AppError) {
  use target <- result.try(accounts.search_configuration(ctx))
  use _ <- db(database.execute(ctx.db, "update accounts set search_migration_held = false where search_migration_held", []))
  use pending <- db(database.query(
    ctx.db,
    "select a.id::text from accounts a join search_releases r on r.id = a.active_search_release_id
     where r.configuration_id <> $1::uuid and a.status in ('active', 'closure_scheduled')
       and not exists (select 1 from search_releases s where s.account_id = a.id and s.state = 'shadow')
     order by a.id limit $2",
    [database.text(target), database.int(batch)],
    decode.at([0], decode.string),
  ))
  list.try_fold(pending, 0, fn(started, account_id) {
    use did <- result.try(start(ctx, account_id, target))
    Ok(started + case did { True -> 1 False -> 0 })
  })
}

/// Start one account's migration to `target` (no-op if already on it or
/// already migrating).
pub fn start(ctx: Context, account_id: String, target: String) -> Result(Bool, AppError) {
  context.transaction(ctx, fn(tx) {
    use status <- result.try(accounts.lock(tx, account_id))
    use row <- error.found(database.query_one(
      tx,
      "select r.id::text, r.configuration_id::text, a.content_sequence,
         exists (select 1 from search_releases s where s.account_id = a.id and s.state = 'shadow')
       from accounts a join search_releases r on r.id = a.active_search_release_id
       where a.id = $1::uuid for update of r",
      [database.text(account_id)],
      {
        use id <- decode.field(0, decode.string)
        use configuration <- decode.field(1, decode.string)
        use sequence <- decode.field(2, decode.int)
        use migrating <- decode.field(3, decode.bool)
        decode.success(#(id, configuration, sequence, migrating))
      },
    ))
    let #(active, configuration, sequence, migrating) = row
    case configuration == target || migrating || !{ status == "active" || status == "closure_scheduled" } {
      True -> Ok(False)
      False -> {
        let shadow = uuid.v7_string()
        use _ <- db(database.execute(
          tx,
          "insert into search_releases (id, account_id, configuration_id, state,
             backfill_sequence, applied_sequence, previous_release_id)
           values ($1::uuid, $2::uuid, $3::uuid, 'shadow', $4, $4, $5::uuid)",
          [database.text(shadow), database.text(account_id), database.text(target),
           database.int(sequence), database.text(active)],
        ))
        use pages <- db(database.query(
          tx,
          "select page_id::text from search_release_pages where release_id = $1::uuid order by page_id",
          [database.text(active)],
          decode.at([0], decode.string),
        ))
        use _ <- result.try(list.try_each(pages, fn(page) { sync_page(tx, account_id, active, shadow, target, page) }))
        Ok(True)
      }
    }
  })
}

/// Bring one page of the shadow in line with the active release: queue a
/// shadow build, map an empty marker, or remove it.
fn sync_page(
  tx: Connection,
  account_id: String,
  active: String,
  shadow: String,
  shadow_configuration: String,
  page_id: String,
) -> Result(Nil, AppError) {
  use mapping <- db(database.query_one(
    tx,
    "select g.revision_id::text, g.transcript_revision_id::text, g.state = 'empty',
       (select gs.revision_id = g.revision_id and gs.transcript_revision_id = g.transcript_revision_id
               and (gs.state = 'empty') = (g.state = 'empty')
        from search_release_pages s join index_generations gs on gs.id = s.index_generation_id
        where s.release_id = $2::uuid and s.page_id = $3::uuid)
     from search_release_pages a join index_generations g on g.id = a.index_generation_id
     where a.release_id = $1::uuid and a.page_id = $3::uuid",
    [database.text(active), database.text(shadow), database.text(page_id)],
    {
      use revision <- decode.field(0, decode.string)
      use transcript <- decode.field(1, decode.string)
      use empty <- decode.field(2, decode.bool)
      use current <- decode.field(3, decode.optional(decode.bool))
      decode.success(#(revision, transcript, empty, option.unwrap(current, False)))
    },
  ))
  case mapping {
    // No longer searchable (trashed, purged, replaced while failing).
    None -> {
      use _ <- db(database.execute(
        tx,
        "delete from search_release_pages where release_id = $1::uuid and page_id = $2::uuid",
        [database.text(shadow), database.text(page_id)],
      ))
      Ok(Nil)
    }
    Some(#(_, _, _, True)) -> Ok(Nil)
    Some(#(revision, transcript, True, False)) -> {
      // Blank pages need an empty marker, never a vector.
      let generation = uuid.v7_string()
      use _ <- db(database.execute(
        tx,
        "insert into index_generations (id, account_id, page_id, revision_id,
           transcript_revision_id, configuration_id, state)
         values ($1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6::uuid, 'empty')",
        [database.text(generation), database.text(account_id), database.text(page_id),
         database.text(revision), database.text(transcript), database.text(shadow_configuration)],
      ))
      processing.map_release(tx, account_id, shadow, page_id, generation)
    }
    Some(#(revision, transcript, False, False)) -> {
      use _ <- db(jobs.enqueue(
        tx,
        jobs.NewJob(
          ..jobs.new_job("shadow_index", "shadow:" <> shadow <> ":" <> transcript),
          page_id: Some(page_id),
          revision_id: Some(revision),
          transcript_revision_id: Some(transcript),
          configuration_id: Some(shadow_configuration),
          payload: json.object([
            #("release_id", json.string(shadow)),
            #("account_id", json.string(account_id)),
          ]),
        ),
      ))
      Ok(Nil)
    }
  }
}

// Building shadow pages ----------------------------------------------------------------------

/// The `shadow_index` stage: embed a page's transcript with the shadow
/// configuration and map it into the shadow release. Stale work (the page
/// changed, or the migration ended) completes without effect; catch-up
/// queues the current version.
pub fn shadow_index(ctx: Context, job: Job) -> Result(processing.StageOutcome, AppError) {
  use #(release_id, account_id) <- result.try(
    json.parse(job.payload, {
      use release <- decode.field("release_id", decode.string)
      use account <- decode.field("account_id", decode.string)
      decode.success(#(release, account))
    })
    |> result.replace_error(error.internal("shadow_index payload")),
  )
  let assert Some(page_id) = job.page_id
  let assert Some(revision_id) = job.revision_id
  let assert Some(transcript_id) = job.transcript_revision_id
  use release <- db(database.query_one(
    ctx.db,
    "select state, configuration_id::text from search_releases where id = $1::uuid",
    [database.text(release_id)],
    {
      use state <- decode.field(0, decode.string)
      use configuration <- decode.field(1, decode.string)
      decode.success(#(state, configuration))
    },
  ))
  use source <- db(database.query_one(
    ctx.db,
    "select text, blank from transcript_revisions where account_id = $1::uuid and id = $2::uuid",
    [database.text(account_id), database.text(transcript_id)],
    {
      use body <- decode.field(0, decode.string)
      use blank <- decode.field(1, decode.bool)
      decode.success(#(body, blank))
    },
  ))
  case release, source {
    Some(#("shadow", configuration_id)), Some(#(body, blank)) -> {
      use configuration <- result.try(search_configs.get(ctx.db, configuration_id))
      case search_configs.provider(ctx, configuration) {
        None -> Ok(processing.Postpone("embedding_model_unavailable", 300))
        Some(embedder) -> {
          let chunks = case blank {
            True -> []
            False -> text.chunk(body)
          }
          case embed(ctx, job, account_id, embedder, chunks) {
            Error(outcome) -> Ok(outcome)
            Ok(passages) ->
              processing.fenced_shadow(ctx, job, account_id, page_id, fn(tx) {
                publish_shadow(tx, account_id, release_id, configuration, page_id, revision_id, transcript_id, passages)
              })
          }
        }
      }
    }
    _, _ -> processing.complete_without_account(ctx, job, "migration ended or source gone")
  }
}

fn embed(
  ctx: Context,
  job: Job,
  account_id: String,
  embedder: providers.EmbeddingProvider,
  chunks: List(text.Chunk),
) -> Result(List(#(text.Chunk, Option(List(Float)))), processing.StageOutcome) {
  case chunks {
    [] -> Ok([])
    _ -> {
      let inputs = list.map(chunks, fn(c) { c.text })
      case
        spend.guarded(
          ctx,
          spend.Call(
            account_id: Some(account_id),
            operation_id: None,
            job_id: Some(job.id),
            provider: embedder.name <> ":" <> embedder.model_id,
            purpose: spend.MigrationEmbedding,
            estimate_micros: embedder.estimate_micros(inputs),
          ),
          fn() { embedder.embed(inputs, providers.Document) },
        )
      {
        Ok(vectors) ->
          case list.length(vectors) == list.length(chunks)
            && list.all(vectors, fn(v) { list.length(v) == embedder.dimensions })
          {
            True -> Ok(list.zip(chunks, list.map(vectors, Some)))
            False -> Error(processing.Retry("embedding_invalid_output"))
          }
        Error(spend.BudgetExhausted) -> Error(processing.Postpone("operational_limit_reached", 900))
        Error(spend.CircuitOpen) -> Error(processing.Postpone("provider_unavailable", 30))
        Error(spend.NoPermit) -> Error(processing.Postpone("provider_permit_wait", 5))
        Error(_) -> Error(processing.Retry("embedding_unavailable"))
      }
    }
  }
}

fn publish_shadow(
  tx: Connection,
  account_id: String,
  release_id: String,
  configuration: search_configs.Configuration,
  page_id: String,
  revision_id: String,
  transcript_id: String,
  passages: List(#(text.Chunk, Option(List(Float)))),
) -> Result(String, AppError) {
  use current <- db(database.query_one(
    tx,
    "select r.state = 'shadow' and exists (
       select 1 from search_release_pages a join index_generations g on g.id = a.index_generation_id
       where a.release_id = r.previous_release_id and a.page_id = $2::uuid
         and g.revision_id = $3::uuid and g.transcript_revision_id = $4::uuid)
     from search_releases r where r.id = $1::uuid for update",
    [database.text(release_id), database.text(page_id), database.text(revision_id), database.text(transcript_id)],
    decode.at([0], decode.bool),
  ))
  case current {
    Some(True) -> {
      let state = case passages {
        [] -> "empty"
        _ -> "published"
      }
      use generation <- result.try(processing.insert_generation(
        tx, account_id, page_id, revision_id, transcript_id, configuration, state, passages,
      ))
      use _ <- result.try(processing.map_release(tx, account_id, release_id, page_id, generation))
      Ok("shadow page indexed")
    }
    _ -> Ok("stale shadow work; catch-up requeues the current version")
  }
}

// Catch-up and cutover --------------------------------------------------------------------

pub type Progress {
  Progress(caught_up: Int, cut_over: Int, retired: Int)
}

/// The maintenance step: catch every shadow up, cut over those that are
/// complete, and drop releases past their retention.
pub fn advance(ctx: Context) -> Result(Progress, AppError) {
  use shadows <- db(database.query(
    ctx.db,
    "select id::text, account_id::text from search_releases where state = 'shadow'
     order by created_at limit 50",
    [],
    {
      use id <- decode.field(0, decode.string)
      use account <- decode.field(1, decode.string)
      decode.success(#(id, account))
    },
  ))
  use #(caught_up, cut_over) <- result.try(list.try_fold(shadows, #(0, 0), fn(counts, shadow) {
    use applied <- result.try(catch_up(ctx, shadow.0, shadow.1))
    use swapped <- result.try(cutover(ctx, shadow.0, shadow.1))
    Ok(#(counts.0 + applied, counts.1 + case swapped { True -> 1 False -> 0 }))
  }))
  use retired <- result.try(drop_expired(ctx))
  Ok(Progress(caught_up, cut_over, retired))
}

/// Replay changes past the shadow watermark. Returns the changes applied.
pub fn catch_up(ctx: Context, release_id: String, account_id: String) -> Result(Int, AppError) {
  context.transaction(ctx, fn(tx) {
    use release <- error.found(database.query_one(
      tx,
      "select applied_sequence, previous_release_id::text, configuration_id::text, state
       from search_releases where id = $1::uuid for update",
      [database.text(release_id)],
      {
        use applied <- decode.field(0, decode.int)
        use active <- decode.field(1, decode.string)
        use configuration <- decode.field(2, decode.string)
        use state <- decode.field(3, decode.string)
        decode.success(#(applied, active, configuration, state))
      },
    ))
    let #(applied, active, configuration, state) = release
    case state {
      "shadow" -> {
        use changes <- db(database.query(
          tx,
          "select sequence, page_id::text from content_changes
           where account_id = $1::uuid and sequence > $2 order by sequence limit $3",
          [database.text(account_id), database.int(applied), database.int(catch_up_batch)],
          {
            use sequence <- decode.field(0, decode.int)
            use page <- decode.field(1, decode.string)
            decode.success(#(sequence, page))
          },
        ))
        case list.last(changes) {
          Error(_) -> Ok(0)
          Ok(#(last, _)) -> {
            // Coalesce: each page is synced once, to its current state.
            let pages = changes |> list.map(fn(c) { c.1 }) |> list.unique
            use _ <- result.try(list.try_each(pages, fn(page) { sync_page(tx, account_id, active, release_id, configuration, page) }))
            use _ <- db(database.execute(
              tx,
              "update search_releases set applied_sequence = $2 where id = $1::uuid",
              [database.text(release_id), database.int(last)],
            ))
            Ok(list.length(changes))
          }
        }
      }
      _ -> Ok(0)
    }
  })
}

/// Swap the shadow in if it is complete; otherwise leave it for later.
pub fn cutover(ctx: Context, release_id: String, account_id: String) -> Result(Bool, AppError) {
  context.transaction(ctx, fn(tx) {
    // The account row is the lock every content writer takes to advance the
    // content sequence, so nothing can publish while this checks and swaps.
    use _ <- result.try(accounts.lock(tx, account_id))
    use row <- error.found(database.query_one(
      tx,
      "select s.state, s.applied_sequence = a.content_sequence, s.previous_release_id::text,
         a.active_search_release_id::text, p.configuration_id::text
       from search_releases s join accounts a on a.id = s.account_id
       join search_releases p on p.id = s.previous_release_id
       where s.id = $1::uuid for update of s, p",
      [database.text(release_id)],
      {
        use state <- decode.field(0, decode.string)
        use caught_up <- decode.field(1, decode.bool)
        use previous <- decode.field(2, decode.string)
        use active <- decode.field(3, decode.string)
        use previous_configuration <- decode.field(4, decode.string)
        decode.success(#(state, caught_up, previous, active, previous_configuration))
      },
    ))
    let #(state, caught_up, previous, active, previous_configuration) = row
    use pending <- error.found(database.query_one(
      tx,
      "select count(*)::int from jobs where stage = 'shadow_index'
         and payload->>'release_id' = $1 and state not in ('succeeded', 'failed', 'cancelled')",
      [database.text(release_id)],
      decode.at([0], decode.int),
    ))
    // Every searchable page maps to the same source and transcript (and
    // blank-ness) in both releases.
    use missing <- error.found(database.query_one(
      tx,
      "select count(*)::int from search_release_pages a
       join index_generations ga on ga.id = a.index_generation_id
       left join search_release_pages s on s.release_id = $2::uuid and s.page_id = a.page_id
       left join index_generations gs on gs.id = s.index_generation_id
       where a.release_id = $1::uuid
         and (gs.id is null or gs.revision_id <> ga.revision_id
           or gs.transcript_revision_id <> ga.transcript_revision_id
           or (gs.state = 'empty') <> (ga.state = 'empty'))",
      [database.text(active), database.text(release_id)],
      decode.at([0], decode.int),
    ))
    case state == "shadow" && previous == active && caught_up && pending == 0 && missing == 0 {
      False -> Ok(False)
      True -> {
        use previous_config <- result.try(search_configs.get(tx, previous_configuration))
        let retired_state = case search_configs.provider(ctx, previous_config) {
          Some(_) -> "retired"
          None -> "rollback_unavailable"
        }
        use _ <- db(database.execute(
          tx,
          "delete from search_release_pages s where s.release_id = $1::uuid
             and not exists (select 1 from search_release_pages a
                             where a.release_id = $2::uuid and a.page_id = s.page_id)",
          [database.text(release_id), database.text(active)],
        ))
        use _ <- db(database.execute(
          tx,
          "update search_releases set state = 'active' where id = $1::uuid",
          [database.text(release_id)],
        ))
        use _ <- db(database.execute(
          tx,
          "update search_releases set state = $2, retired_at = now(),
             applied_sequence = (select content_sequence from accounts where id = $3::uuid)
           where id = $1::uuid",
          [database.text(active), database.text(retired_state), database.text(account_id)],
        ))
        use _ <- db(database.execute(
          tx,
          "update accounts set active_search_release_id = $2::uuid where id = $1::uuid",
          [database.text(account_id), database.text(release_id)],
        ))
        Ok(True)
      }
    }
  })
}

// Rollback and retention ----------------------------------------------------------------------

/// Roll an account back to its previous release: a reverse migration that
/// replays the change log into it, then cuts over under the same checks.
pub fn rollback(ctx: Context, account_id: String) -> Result(Nil, AppError) {
  context.transaction(ctx, fn(tx) {
    use _ <- result.try(accounts.lock(tx, account_id))
    use row <- error.found(database.query_one(
      tx,
      "select r.id::text, r.state, r.configuration_id::text, a.active_search_release_id::text,
         r.retired_at > now() - make_interval(secs => $2),
         exists (select 1 from search_releases s where s.account_id = a.id and s.state = 'shadow')
       from accounts a join search_releases cur on cur.id = a.active_search_release_id
       join search_releases r on r.id = cur.previous_release_id
       where a.id = $1::uuid for update of r",
      [database.text(account_id), database.int(retention_seconds)],
      {
        use id <- decode.field(0, decode.string)
        use state <- decode.field(1, decode.string)
        use configuration <- decode.field(2, decode.string)
        use active <- decode.field(3, decode.string)
        use retained <- decode.field(4, decode.optional(decode.bool))
        use migrating <- decode.field(5, decode.bool)
        decode.success(#(id, state, configuration, active, option.unwrap(retained, False), migrating))
      },
    ))
    let #(previous, state, configuration, active, retained, migrating) = row
    use config <- result.try(search_configs.get(tx, configuration))
    let refused = fn(message) { Error(error.new(409, "rollback_unavailable", message)) }
    case state, retained, migrating, search_configs.provider(ctx, config) {
      "retired", True, False, Some(_) -> {
        use _ <- db(database.execute(
          tx,
          "update search_releases set state = 'shadow', retired_at = null,
             previous_release_id = $2::uuid where id = $1::uuid",
          [database.text(previous), database.text(active)],
        ))
        use _ <- db(database.execute(
          tx,
          "update accounts set search_migration_held = true where id = $1::uuid",
          [database.text(account_id)],
        ))
        Ok(Nil)
      }
      "rollback_unavailable", _, _, _ | _, _, _, None ->
        refused("The previous search model is no longer available.")
      _, False, _, _ -> refused("The previous search release is past its retention period.")
      _, _, True, _ -> refused("A search migration is already in progress for this account.")
      _, _, _, _ -> refused("There is no previous search release to roll back to.")
    }
  })
}

/// Delete releases past retention, a bounded batch of passages at a time.
fn drop_expired(ctx: Context) -> Result(Int, AppError) {
  use expired <- db(database.query(
    ctx.db,
    "select id::text, account_id::text, configuration_id::text from search_releases
     where state in ('retired', 'rollback_unavailable')
       and retired_at < now() - make_interval(secs => $1)
     order by retired_at limit 10",
    [database.int(retention_seconds)],
    {
      use id <- decode.field(0, decode.string)
      use account <- decode.field(1, decode.string)
      use configuration <- decode.field(2, decode.string)
      decode.success(#(id, account, configuration))
    },
  ))
  list.try_fold(expired, 0, fn(done, release) {
    let #(id, account_id, _) = release
    context.transaction(ctx, fn(tx) {
      use _ <- db(database.execute(
        tx,
        "delete from search_release_pages where release_id = $1::uuid",
        [database.text(id)],
      ))
      // Generations no release maps any more (their passages first;
      // embeddings cascade).
      let orphans =
        "select g.id from index_generations g where g.account_id = $1::uuid
           and not exists (select 1 from search_release_pages m where m.index_generation_id = g.id)"
      use removed <- db(database.execute(
        tx,
        "delete from passages where account_id = $1::uuid and id in (
           select p.id from passages p where p.account_id = $1::uuid
             and p.index_generation_id in (" <> orphans <> ") limit 5000)",
        [database.text(account_id)],
      ))
      case removed {
        0 -> {
          use _ <- db(database.execute(
            tx,
            "delete from index_generations where id in (" <> orphans <> ")",
            [database.text(account_id)],
          ))
          use _ <- db(database.execute(
            tx,
            "update search_releases set previous_release_id = null where previous_release_id = $1::uuid",
            [database.text(id)],
          ))
          use _ <- db(database.execute(tx, "delete from search_releases where id = $1::uuid", [database.text(id)]))
          Ok(done + 1)
        }
        // More passages remain: the release row stays until a later run.
        _ -> {
          use _ <- db(database.execute(
            tx,
            "update search_releases set retired_at = retired_at where id = $1::uuid",
            [database.text(id)],
          ))
          Ok(done)
        }
      }
    })
  })
}

/// Status for an operator: releases per state across the deployment.
pub fn summary(ctx: Context) -> Result(List(#(String, Int)), AppError) {
  use rows <- db(database.query(
    ctx.db,
    "select state, count(*)::int from search_releases group by state order by state",
    [],
    {
      use state <- decode.field(0, decode.string)
      use count <- decode.field(1, decode.int)
      decode.success(#(state, count))
    },
  ))
  Ok(rows)
}
