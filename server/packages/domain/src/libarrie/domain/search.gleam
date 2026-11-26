//// Hybrid page retrieval (section 9).
////
//// Lexical retrieval combines an exact normalized substring path (for
//// identifiers and very short queries), word-based full-text search and
//// substring-aware trigram matching (`<%` for candidates, `word_similarity`
//// for ranking). Semantic retrieval runs exact, account-filtered vector
//// search over the release's configuration. Candidates merge with
//// reciprocal rank fusion and aggregate to one result per page. Tenant,
//// visibility and current-generation filters run in SQL before truncation.
////
//// Hits from a private notebook say where the text matched (the notebook,
//// page and IDs) but carry no snippet and no highlights. The flag is read
//// when each hit is built, not stored in the index, so a change applies
//// from the next search without reindexing (ADR 0017).

import gleam/dict
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import libarrie/database.{type Connection}
import libarrie/domain/context.{type Context}
import libarrie/domain/error.{type AppError, db}
import libarrie/domain/processing
import libarrie/domain/search_configs
import libarrie/domain/spend
import libarrie/domain/text
import libarrie/integrations/providers

pub type Request {
  Request(query: String, notebook_id: Option(String), limit: Int)
}

pub fn decoder() -> decode.Decoder(Request) {
  use query <- decode.field("query", decode.string)
  use notebook_id <- decode.optional_field(
    "notebook_id",
    None,
    decode.optional(decode.string),
  )
  use limit <- decode.optional_field("limit", 10, decode.int)
  decode.success(Request(query:, notebook_id:, limit:))
}

const candidate_limit = 50

const rrf_k = 60.0

/// Cosine distance above which semantic matches are treated as noise
/// rather than filling result slots.
const max_semantic_distance = 0.75

const word_similarity_threshold = "0.5"

const unspaced_word_similarity_threshold = "0.3"

pub type Candidate {
  Candidate(passage_id: String, page_id: String, text: String, kind: String)
}

pub type Hit {
  Hit(
    page_id: String,
    revision_id: String,
    transcript_revision_id: String,
    index_generation_id: String,
    indexing_pending: Bool,
    notebook_id: String,
    notebook_name: String,
    page_number: Int,
    /// None for a page in a private notebook.
    snippet: Option(String),
    match_kind: String,
  )
}

pub type Results {
  Results(search_mode: String, index_migration_pending: Bool, hits: List(Hit))
}

pub fn search(
  ctx: Context,
  account_id: String,
  request: Request,
) -> Result(json.Json, AppError) {
  use results <- result.map(run(ctx, account_id, request))
  let query = string.trim(request.query)
  json.object([
    #("search_mode", json.string(results.search_mode)),
    #("index_migration_pending", json.bool(results.index_migration_pending)),
    #("results", json.array(results.hits, hit_json(_, query))),
  ])
}

pub fn run(
  ctx: Context,
  account_id: String,
  request: Request,
) -> Result(Results, AppError) {
  let query = string.trim(request.query)
  use <- error.guard(
    query != "" && string.length(query) <= 500,
    error.unprocessable("query must be 1-500 characters"),
  )
  use <- error.guard(
    request.limit >= 1 && request.limit <= 50,
    error.unprocessable("limit must be between 1 and 50"),
  )
  use notebook_id <- result.try(case request.notebook_id {
    Some(id) -> context.require_uuid(id, fn(id) { Ok(Some(id)) })
    None -> Ok(None)
  })
  // The query uses the active release's own configuration: its model for
  // the embedding and its normalization for lexical matching. A release
  // whose model is no longer callable is searched by words only. Embed
  // outside any transaction; degrade to lexical-only on failure.
  use #(_, release_configuration) <- result.try(search_configs.active(ctx.db, account_id))
  let normalized = text.normalize_with(release_configuration.normalization_version, query)
  let query_vector = case normalized, search_configs.provider(ctx, release_configuration) {
    "", _ | _, None -> Error(Nil)
    _, Some(embedder) ->
      // Query embedding is budget-controlled; when blocked, search
      // degrades to lexical-only instead of failing.
      case
        spend.guarded(
          ctx,
          spend.Call(
            account_id: Some(account_id),
            operation_id: None,
            job_id: None,
            provider: embedder.name <> ":" <> embedder.model_id,
            purpose: spend.QueryEmbedding,
            estimate_micros: embedder.estimate_micros([query]),
          ),
          fn() { embedder.embed([query], providers.Query) },
        )
      {
        Ok([vector]) -> Ok(vector)
        _ -> Error(Nil)
      }
  }
  context.transaction(ctx, fn(tx) {
    // Pin one release/configuration for the whole request.
    use release <- error.found(database.query_one(
      tx,
      "select r.id::text, r.configuration_id::text from accounts a
       join search_releases r on r.id = a.active_search_release_id
       where a.id = $1::uuid",
      [database.text(account_id)],
      {
        use id <- decode.field(0, decode.string)
        use configuration <- decode.field(1, decode.string)
        decode.success(#(id, configuration))
      },
    ))
    let #(release_id, configuration_id) = release
    use lexical <- result.try(case normalized {
      "" -> Ok([])
      _ -> lexical(tx, account_id, release_id, notebook_id, normalized)
    })
    use #(semantic, mode) <- result.try(case query_vector, configuration_id == release_configuration.id {
      Ok(vector), True -> {
        use rows <- result.try(semantic(
          tx,
          account_id,
          release_id,
          configuration_id,
          notebook_id,
          vector,
        ))
        Ok(#(rows, "hybrid"))
      }
      _, _ -> Ok(#([], "lexical_only"))
    })
    let fused = fuse(lexical, semantic) |> list.take(request.limit)
    use hits <- result.try(list.try_map(fused, fn(entry) {
      hit(tx, account_id, release_id, entry, query)
    }))
    // A migration to a new search model is in progress for this account
    // (results come from the current release until cutover), or some pages
    // were stored for word search only.
    use migrating <- error.found(database.query_one(
      tx,
      "select exists (select 1 from search_releases s where s.account_id = $1::uuid and s.state = 'shadow')
         or exists (select 1 from search_release_pages srp
           join index_generations g on g.id = srp.index_generation_id
           where srp.release_id = $2::uuid and g.state <> 'empty'
             and (g.configuration_id <> $3::uuid
               or not exists (select 1 from embeddings e where e.account_id = $1::uuid
                              and e.index_generation_id = g.id)))",
      [database.text(account_id), database.text(release_id), database.text(configuration_id)],
      decode.at([0], decode.bool),
    ))
    Ok(Results(search_mode: mode, index_migration_pending: migrating, hits:))
  })
}

const visible_cte = "with visible as (
    select srp.page_id, srp.index_generation_id
    from search_release_pages srp
    join pages p on p.id = srp.page_id and p.account_id = srp.account_id
      and p.visibility = 'active'
    join notebooks n on n.id = p.notebook_id and n.deleted_at is null
    where srp.account_id = $1::uuid and srp.release_id = $2::uuid
      and ($3::uuid is null or p.notebook_id = $3::uuid))"

fn lexical(
  tx: Connection,
  account_id: String,
  release_id: String,
  notebook_id: Option(String),
  normalized: String,
) -> Result(List(Candidate), AppError) {
  use _ <- db(database.execute(
    tx,
    "select set_config('pg_trgm.word_similarity_threshold', $1, true)",
    [database.text(case string.to_graphemes(normalized) |> list.any(text.is_unspaced_script) {
      // CJK and Thai queries compare character bigrams; one misread
      // character in a short query scores about 0.33, so the threshold is
      // lower. Calibrate on the evaluation set before claiming support.
      True -> unspaced_word_similarity_threshold
      False -> word_similarity_threshold
    })],
  ))
  use rows <- db(database.query(
    tx,
    visible_cte
      <> "
     select ps.id::text, v.page_id::text, ps.text
     from passages ps
     join visible v on v.index_generation_id = ps.index_generation_id
     where ps.account_id = $1::uuid
       and (ps.normalized_text like $5 escape '\\'
         or $4 <% ps.normalized_text
         or ps.search_vector @@ plainto_tsquery('simple', $4))
     order by
       (ps.normalized_text like $5 escape '\\') desc,
       ts_rank(ps.search_vector, plainto_tsquery('simple', $4)) desc,
       word_similarity($4, ps.normalized_text) desc,
       ps.id
     limit $6",
    [
      database.text(account_id),
      database.text(release_id),
      database.nullable_text(notebook_id),
      database.text(normalized),
      database.text("%" <> escape_like(normalized) <> "%"),
      database.int(candidate_limit),
    ],
    candidate_decoder("lexical"),
  ))
  Ok(rows)
}

fn semantic(
  tx: Connection,
  account_id: String,
  release_id: String,
  configuration_id: String,
  notebook_id: Option(String),
  vector: List(Float),
) -> Result(List(Candidate), AppError) {
  use rows <- db(database.query(
    tx,
    visible_cte
      <> ", ranked as (
       select e.passage_id, v.page_id, e.embedding <=> $4::text::vector as distance
       from embeddings e
       join visible v on v.index_generation_id = e.index_generation_id
       where e.account_id = $1::uuid and e.configuration_id = $5::uuid
       order by distance limit $6)
     select ps.id::text, r.page_id::text, ps.text
     from ranked r join passages ps on ps.account_id = $1::uuid and ps.id = r.passage_id
     where r.distance <= $7
     order by r.distance, ps.id",
    [
      database.text(account_id),
      database.text(release_id),
      database.nullable_text(notebook_id),
      database.text(processing.vector_literal(vector)),
      database.text(configuration_id),
      database.int(candidate_limit),
      database.float(max_semantic_distance),
    ],
    candidate_decoder("semantic"),
  ))
  Ok(rows)
}

fn candidate_decoder(kind: String) -> decode.Decoder(Candidate) {
  use passage_id <- decode.field(0, decode.string)
  use page_id <- decode.field(1, decode.string)
  use text <- decode.field(2, decode.string)
  decode.success(Candidate(passage_id, page_id, text, kind))
}

fn escape_like(value: String) -> String {
  value
  |> string.replace("\\", "\\\\")
  |> string.replace("%", "\\%")
  |> string.replace("_", "\\_")
}

pub type Fused {
  Fused(page_id: String, score: Float, best: Candidate, kinds: List(String))
}

/// Reciprocal rank fusion over passages, then one entry per page carrying
/// its best-scoring passage as evidence.
pub fn fuse(lexical: List(Candidate), semantic: List(Candidate)) -> List(Fused) {
  let scored =
    list.append(
      list.index_map(lexical, fn(c, i) { #(c, 1.0 /. { rrf_k +. int.to_float(i + 1) }) }),
      list.index_map(semantic, fn(c, i) { #(c, 1.0 /. { rrf_k +. int.to_float(i + 1) }) }),
    )
  let by_passage =
    list.fold(scored, dict.new(), fn(acc, entry) {
      let #(candidate, score) = entry
      dict.upsert(acc, candidate.passage_id, fn(existing) {
        case existing {
          Some(#(c, s, kinds)) -> #(c, s +. score, list.unique([candidate.kind, ..kinds]))
          None -> #(candidate, score, [candidate.kind])
        }
      })
    })
  by_passage
  |> dict.values
  |> list.group(fn(entry) { { entry.0 }.page_id })
  |> dict.to_list
  |> list.map(fn(group) {
    let #(page_id, entries) = group
    let assert Ok(#(best, score, _)) =
      list.reduce(entries, fn(a, b) {
        case b.1 >. a.1 {
          True -> b
          False -> a
        }
      })
    let kinds = entries |> list.flat_map(fn(e) { e.2 }) |> list.unique
    Fused(page_id, score, best, kinds)
  })
  |> list.sort(fn(a, b) {
    float.compare(b.score, a.score)
    |> order.lazy_break_tie(fn() { string.compare(a.page_id, b.page_id) })
  })
}

fn hit(
  tx: Connection,
  account_id: String,
  release_id: String,
  entry: Fused,
  query: String,
) -> Result(Hit, AppError) {
  // The snippet's text comes from the candidate queries, and this statement
  // reads the page's current notebook and its private flag after them. So
  // text indexed after a privacy change can't go out with an older flag. A
  // later change, such as batching these lookups, must not read the flags
  // before the candidate queries (ADR 0017).
  use row <- error.found(database.query_one(
    tx,
    "select p.id::text, p.page_number, n.id::text, n.name, g.revision_id::text,
       g.transcript_revision_id::text, g.id::text,
       r.selected_transcript_revision_id is distinct from g.transcript_revision_id
         or p.active_revision_id is distinct from g.revision_id,
       n.private
     from pages p
     join notebooks n on n.id = p.notebook_id
     join search_release_pages srp on srp.page_id = p.id and srp.release_id = $3::uuid
     join index_generations g on g.id = srp.index_generation_id
     left join page_revisions r on r.id = p.active_revision_id
     where p.account_id = $1::uuid and p.id = $2::uuid",
    [database.text(account_id), database.text(entry.page_id), database.text(release_id)],
    {
      use page_id <- decode.field(0, decode.string)
      use number <- decode.field(1, decode.int)
      use notebook_id <- decode.field(2, decode.string)
      use notebook_name <- decode.field(3, decode.string)
      use revision_id <- decode.field(4, decode.string)
      use transcript_id <- decode.field(5, decode.string)
      use generation_id <- decode.field(6, decode.string)
      use pending <- decode.field(7, decode.bool)
      use private <- decode.field(8, decode.bool)
      decode.success(#(
        page_id,
        number,
        notebook_id,
        notebook_name,
        revision_id,
        transcript_id,
        generation_id,
        pending,
        private,
      ))
    },
  ))
  let #(
    page_id,
    number,
    notebook_id,
    notebook_name,
    revision_id,
    transcript_id,
    generation_id,
    pending,
    private,
  ) = row
  // A private notebook's text is never built into a snippet.
  let snippet = case private {
    True -> None
    False -> Some(text.snippet(entry.best.text, query, 240))
  }
  let match_kind = case list.contains(entry.kinds, "lexical"), list.contains(entry.kinds, "semantic") {
    True, True -> "hybrid"
    True, False -> "lexical"
    _, _ -> "semantic"
  }
  Ok(Hit(
    page_id:,
    revision_id:,
    transcript_revision_id: transcript_id,
    index_generation_id: generation_id,
    indexing_pending: pending,
    notebook_id:,
    notebook_name:,
    page_number: number,
    snippet:,
    match_kind:,
  ))
}

fn hit_json(hit: Hit, query: String) -> json.Json {
  // Evidence comes from the published generation, never attached to
  // newer unindexed text. A hit from a private notebook has no `snippet`
  // or `highlights` key at all.
  let evidence = case hit.snippet {
    Some(snippet) -> [
      #("snippet", json.string(snippet)),
      #(
        "highlights",
        json.array(text.highlights(snippet, query), fn(range) {
          json.object([
            #("kind", json.string("text")),
            #("field", json.string("snippet")),
            #("start", json.int(range.0)),
            #("end", json.int(range.1)),
          ])
        }),
      ),
    ]
    None -> []
  }
  json.object(
    list.flatten([
      [
        #("page_id", json.string(hit.page_id)),
        #("revision_id", json.string(hit.revision_id)),
        #("transcript_revision_id", json.string(hit.transcript_revision_id)),
        #("index_generation_id", json.string(hit.index_generation_id)),
        #("indexing_pending", json.bool(hit.indexing_pending)),
        #(
          "notebook",
          json.object([
            #("id", json.string(hit.notebook_id)),
            #("name", json.string(hit.notebook_name)),
          ]),
        ),
        #("page_number", json.int(hit.page_number)),
      ],
      evidence,
      [#("match_kind", json.string(hit.match_kind))],
    ]),
  )
}
