//// End-to-end processing with the Mistral OCR and Voyage adapters pointed
//// at in-test fake servers (no real credentials), plus the embedding-model
//// migration path.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import libarrie/api/router
import libarrie/domain/accounts
import libarrie/domain/context
import libarrie/domain/search_migration
import libarrie/integrations/image
import libarrie/integrations/mistral
import libarrie/integrations/providers
import libarrie/integrations/voyage
import mist
import support.{call, str}

fn reply(body: String) {
  response.new(200)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

/// Fake Mistral: transcribes the mock text embedded in the PNG and reports
/// one paragraph block covering the top half of the page.
fn fake_mistral(req: request.Request(mist.Connection)) {
  let assert Ok(req) = mist.read_body(req, 30_000_000)
  let assert Ok(body) = bit_array.to_string(req.body)
  let assert Ok(url) = json.parse(body, decode.at(["document", "image_url", "url"], decode.string))
  let assert Ok(#(_, payload)) = string.split_once(url, "base64,")
  let assert Ok(bytes) = bit_array.base64_decode(payload)
  let text = image.embedded_text(bytes) |> option.unwrap("")
  reply(
    "{\"model\":\"mistral-ocr-4-1\",\"pages\":[{\"index\":0,\"markdown\":"
    <> json.to_string(json.string(text))
    <> ",\"images\":[],\"dimensions\":{\"dpi\":200,\"height\":480,\"width\":640},"
    <> "\"confidence_scores\":{\"average_page_confidence_score\":0.91},"
    <> "\"blocks\":[{\"type\":\"text\",\"bbox\":{\"top_left_x\":0,\"top_left_y\":0,"
    <> "\"bottom_right_x\":640,\"bottom_right_y\":240},\"text\":"
    <> json.to_string(json.string(text))
    <> ",\"confidence\":0.9}]}],\"usage_info\":{\"pages_processed\":1}}",
  )
}

/// Fake Voyage: deterministic vectors from the development hash embedder.
fn fake_voyage(req: request.Request(mist.Connection)) {
  let assert Ok(req) = mist.read_body(req, 10_000_000)
  let assert Ok(body) = bit_array.to_string(req.body)
  let assert Ok(#(input, dims)) =
    json.parse(body, {
      use input <- decode.field("input", decode.list(decode.string))
      use dims <- decode.field("output_dimension", decode.int)
      decode.success(#(input, dims))
    })
  let assert Ok(vectors) = providers.mock_embedding(dims).embed(input, providers.Document)
  let data =
    list.index_map(vectors, fn(v, i) {
      json.object([#("embedding", json.array(v, json.float)), #("index", json.int(i))])
    })
  reply(json.to_string(json.object([
    #("data", json.preprocessed_array(data)),
    #("usage", json.object([#("total_tokens", json.int(1))])),
  ])))
}

fn serve(handler) -> String {
  let port = 24_000 + int.random(10_000)
  let assert Ok(_) = mist.new(handler) |> mist.port(port) |> mist.start
  "http://localhost:" <> int.to_string(port)
}

fn with_voyage(app: router.App, base_url: String, dims: Int, previous: List(providers.EmbeddingProvider)) -> router.App {
  let embedding =
    voyage.provider(voyage.Config(..voyage.default_config("test-key"), base_url:, dimensions: dims))
  router.App(..app, ctx: context.Context(..app.ctx, config: context.Config(..app.ctx.config, embedding:, previous_embeddings: previous)))
}

/// When the release's model is no longer callable, new pages publish for
/// word search only, and rollback to that model is refused.
pub fn unavailable_previous_model_test() {
  let voyage_url = serve(fake_voyage)
  let mock_app = support.app()
  let token = support.user(mock_app)
  let account = support.account_id(mock_app, token)
  let notebook = support.notebook(mock_app, token, "Deprecated")
  let app = with_voyage(mock_app, voyage_url, 256, [])
  let #(_, page) = support.upload_page(app, token, notebook, 1, Some("Harbor permit renewal"), "immediate")
  support.drain(app)
  let assert "ready" = str(call(app, http.Get, "/v1/pages/" <> page, token, None, []), ["page", "processing_status"])
  let found = call(app, http.Post, "/v1/search", token, Some(json.object([#("query", json.string("permit"))])), [])
  let assert "lexical_only" = str(found, ["search_mode"])
  let assert True = support.get(found, ["index_migration_pending"], decode.bool)
  let assert [_] = support.get(found, ["results"], decode.list(decode.dynamic))
  let assert Ok(target) = accounts.search_configuration(app.ctx)
  let assert Ok(True) = search_migration.start(app.ctx, account, target)
  let shadow = support.sql_str(app, "select id::text from search_releases where account_id = $1::uuid and state = 'shadow'", [account])
  support.drain(app)
  let assert Ok(True) = search_migration.cutover(app.ctx, shadow, account)
  let assert "hybrid" =
    str(call(app, http.Post, "/v1/search", token, Some(json.object([#("query", json.string("permit"))])), []), ["search_mode"])
  let assert "rollback_unavailable" =
    support.sql_str(app, "select state from search_releases where id = (select previous_release_id from search_releases where id = $1::uuid)", [shadow])
  let assert Error(refused) = search_migration.rollback(app.ctx, account)
  let assert "rollback_unavailable" = refused.code
}

/// Chinese, Japanese and Korean have no spaces between words: character
/// bigrams give word search and trigram matching word boundaries.
pub fn cjk_search_test() {
  let app = support.app()
  let token = support.user(app)
  let notebook = support.notebook(app, token, "会議メモ")
  let #(_, japanese) = support.upload_page(app, token, notebook, 1, Some("東京駅で予算会議をしました"), "immediate")
  let #(_, korean) = support.upload_page(app, token, notebook, 2, Some("서울에서 회의를 했습니다"), "immediate")
  support.drain(app)
  let hits = fn(query) {
    call(app, http.Post, "/v1/search", token, Some(json.object([#("query", json.string(query))])), [])
    |> support.get(["results"], decode.list(decode.at(["page_id"], decode.string)))
  }
  let assert True = list.contains(hits("会議"), japanese)
  let assert True = list.contains(hits("予算会議"), japanese)
  let assert True = list.contains(hits("東京"), japanese)
  // One misread character still finds the page.
  let assert True = list.contains(hits("予算会儀"), japanese)
  let assert True = list.contains(hits("회의"), korean)
  let assert False = list.contains(hits("会議"), korean)
}

pub fn mistral_and_voyage_pipeline_and_migration_test() {
  let ocr =
    mistral.provider(mistral.Config(..mistral.default_config("test-key"), base_url: serve(fake_mistral)))
  let voyage_url = serve(fake_voyage)
  // Start on the development embedder, then migrate to Voyage.
  let mock_app = support.app()
  let token = support.user(mock_app)
  let notebook = support.notebook(mock_app, token, "Providers")
  let #(_, first) =
    support.upload_page(mock_app, token, notebook, 1, Some("Quarterly budget review with Lin"), "immediate")
  support.drain_with(mock_app, ocr)
  let page = call(mock_app, http.Get, "/v1/pages/" <> first, token, None, [])
  let assert "ready" = str(page, ["page", "processing_status"])
  let assert "Quarterly budget review with Lin" = str(page, ["transcript", "text"])
  // Provider-reported boxes are stored normalized, never invented.
  let assert 1 =
    support.sql_int(mock_app,
      "select count(*)::int from ocr_results o join page_revisions r on r.id = o.revision_id
       where r.page_id = $1::uuid and o.model_id = 'mistral-ocr-4-1'
         and (o.boxes->0->>'bottom')::float = 0.5", [first])
  // Switch the deployment to Voyage, keeping the development model callable
  // as a previous model. Nothing changes for the account until migration.
  let old_model = mock_app.ctx.config.embedding
  let app = with_voyage(mock_app, voyage_url, 512, [old_model])
  let account = support.account_id(app, token)
  let search = fn(query) {
    call(app, http.Post, "/v1/search", token, Some(json.object([#("query", json.string(query))])), [])
  }
  let assert "hybrid" = str(search("budget"), ["search_mode"])
  // New pages keep publishing into the current release with its own model.
  let #(_, second) =
    support.upload_page(app, token, notebook, 2, Some("Grant application deadline Friday"), "immediate")
  support.drain_with(app, ocr)
  let assert "ready" = str(call(app, http.Get, "/v1/pages/" <> second, token, None, []), ["page", "processing_status"])
  // Start this account's migration (the `reindex` command starts every
  // account's; this test touches only its own).
  let assert Ok(target) = accounts.search_configuration(app.ctx)
  let assert Ok(True) = search_migration.start(app.ctx, account, target)
  let shadow = support.sql_str(app, "select id::text from search_releases where account_id = $1::uuid and state = 'shadow'", [account])
  let migrating = search("budget")
  let assert True = support.get(migrating, ["index_migration_pending"], decode.bool)
  let assert "hybrid" = str(migrating, ["search_mode"])
  // A page published mid-migration reaches the shadow through catch-up.
  let #(_, third) =
    support.upload_page(app, token, notebook, 3, Some("Lin moved the review to Tuesday"), "immediate")
  support.drain_with(app, ocr)
  // Not complete yet: the cutover refuses until catch-up has run.
  let assert Ok(False) = search_migration.cutover(app.ctx, shadow, account)
  let assert Ok(_) = search_migration.catch_up(app.ctx, shadow, account)
  support.drain_with(app, ocr)
  let assert Ok(True) = search_migration.cutover(app.ctx, shadow, account)
  let done = search("grant deadline")
  let assert False = support.get(done, ["index_migration_pending"], decode.bool)
  let assert "hybrid" = str(done, ["search_mode"])
  let assert [hit, ..] = support.get(done, ["results"], decode.list(decode.at(["page_id"], decode.string)))
  let assert True = hit == second
  let assert [_, ..] = support.get(search("Tuesday"), ["results"], decode.list(decode.dynamic))
  // Voyage vectors use the configured dimension.
  let assert 512 =
    support.sql_int(app,
      "select max(e.dimensions) from embeddings e join index_generations g on g.id = e.index_generation_id
       join search_release_pages s on s.index_generation_id = g.id and s.release_id = $2::uuid
       where g.page_id = $1::uuid", [third, shadow])
  // The previous release is retained for rollback.
  let assert "retired" =
    support.sql_str(app, "select state from search_releases where id = (select previous_release_id from search_releases where id = $1::uuid)", [shadow])
  // Rollback replays into the previous release, then cuts over to it.
  let assert Ok(Nil) = search_migration.rollback(app.ctx, account)
  let reverse = support.sql_str(app, "select id::text from search_releases where account_id = $1::uuid and state = 'shadow'", [account])
  let assert Ok(_) = search_migration.catch_up(app.ctx, reverse, account)
  support.drain_with(app, ocr)
  let assert Ok(True) = search_migration.cutover(app.ctx, reverse, account)
  let assert True =
    support.sql_str(app, "select r.configuration_id::text from accounts a join search_releases r on r.id = a.active_search_release_id where a.id = $1::uuid", [account]) != target
  let assert [_, ..] = support.get(search("Tuesday"), ["results"], decode.list(decode.dynamic))
  let assert 1 = support.sql_int(app, "select search_migration_held::int from accounts where id = $1::uuid", [account])
  // Migration indexing never charges processing units: three pages, three charges.
  let usage = call(app, http.Get, "/v1/usage", token, None, [])
  let assert 3 = support.get(usage, ["lifetime_allowance", "used"], decode.int)
}
