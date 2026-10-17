//// Voyage AI embeddings adapter (`POST /v1/embeddings`), pinned to an
//// explicit model (default `voyage-4-large`) and output dimension.
////
//// Requests set `input_type` (`document` for passages, `query` for search),
//// `truncation: false` so oversize input fails loudly instead of being
//// silently cut, and are split to respect per-request limits (1,000 inputs;
//// 120K tokens for voyage-4-large). Results are reordered by `index` and
//// every vector's dimension is validated.

import gleam/dynamic/decode
import gleam/float
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import libarrie/integrations/providers.{
  type ProviderError, InvalidOutput, Misconfigured, Transient,
}

pub type Config {
  Config(
    api_key: String,
    base_url: String,
    model: String,
    dimensions: Int,
    max_inputs_per_request: Int,
    /// Conservative character budget per request (a token is at least one
    /// character, so this stays under the model's token limit).
    max_chars_per_request: Int,
    price_micros_per_million_tokens: Int,
    timeout_ms: Int,
  )
}

pub fn default_config(api_key: String) -> Config {
  Config(
    api_key:,
    base_url: "https://api.voyageai.com",
    model: "voyage-4-large",
    dimensions: 1024,
    max_inputs_per_request: 1000,
    max_chars_per_request: 100_000,
    price_micros_per_million_tokens: 120_000,
    timeout_ms: 60_000,
  )
}

pub const allowed_dimensions = [256, 512, 1024, 2048]

pub fn provider(config: Config) -> providers.EmbeddingProvider {
  providers.EmbeddingProvider(
    name: "voyage",
    model_id: config.model,
    dimensions: config.dimensions,
    embed: fn(texts, purpose) { embed(config, texts, purpose) },
    estimate_micros: fn(texts) { estimate_micros(config, texts) },
  )
}

/// Upper bound: one token per character.
pub fn estimate_micros(config: Config, texts: List(String)) -> Int {
  let chars = list.fold(texts, 0, fn(n, t) { n + string.length(t) })
  int.max(1, { chars * config.price_micros_per_million_tokens + 999_999 } / 1_000_000)
}

/// Split inputs into request batches within the count and size budgets.
pub fn batches(config: Config, texts: List(String)) -> List(List(String)) {
  let #(done, current, _) =
    list.fold(texts, #([], [], 0), fn(state, text) {
      let #(done, current, size) = state
      let n = string.length(text)
      case
        current != []
        && {
          list.length(current) >= config.max_inputs_per_request
          || size + n > config.max_chars_per_request
        }
      {
        True -> #([list.reverse(current), ..done], [text], n)
        False -> #(done, [text, ..current], size + n)
      }
    })
  case current {
    [] -> list.reverse(done)
    _ -> list.reverse([list.reverse(current), ..done])
  }
}

pub fn embed(
  config: Config,
  texts: List(String),
  purpose: providers.EmbeddingPurpose,
) -> Result(List(List(Float)), ProviderError) {
  batches(config, texts)
  |> list.try_map(embed_batch(config, _, purpose))
  |> result.map(list.flatten)
}

pub fn request_body(
  config: Config,
  texts: List(String),
  purpose: providers.EmbeddingPurpose,
) -> String {
  json.object([
    #("input", json.array(texts, json.string)),
    #("model", json.string(config.model)),
    #(
      "input_type",
      json.string(case purpose {
        providers.Document -> "document"
        providers.Query -> "query"
      }),
    ),
    #("output_dimension", json.int(config.dimensions)),
    #("output_dtype", json.string("float")),
    #("truncation", json.bool(False)),
  ])
  |> json.to_string
}

fn embed_batch(
  config: Config,
  texts: List(String),
  purpose: providers.EmbeddingPurpose,
) -> Result(List(List(Float)), ProviderError) {
  use req <- result.try(
    request.to(trim_slash(config.base_url) <> "/v1/embeddings")
    |> result.replace_error(Misconfigured("invalid Voyage base URL")),
  )
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("authorization", "Bearer " <> config.api_key)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(request_body(config, texts, purpose))
  case httpc.configure() |> httpc.timeout(config.timeout_ms) |> httpc.dispatch(req) {
    Error(e) -> Error(Transient("voyage request failed: " <> string.inspect(e)))
    Ok(resp) ->
      case resp.status {
        200 -> parse(config, resp.body, list.length(texts))
        401 | 403 -> Error(Misconfigured("voyage rejected credentials"))
        408 | 429 -> Error(Transient("voyage " <> int.to_string(resp.status) <> ": " <> excerpt(resp.body)))
        s if s >= 500 -> Error(Transient("voyage " <> int.to_string(s) <> ": " <> excerpt(resp.body)))
        s -> Error(InvalidOutput("voyage status " <> int.to_string(s)))
      }
  }
}

/// Parse and validate a 200 response body. Public for contract tests.
pub fn parse(
  config: Config,
  body: String,
  expected: Int,
) -> Result(List(List(Float)), ProviderError) {
  let number = decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
  let item = {
    use index <- decode.field("index", decode.int)
    use embedding <- decode.field("embedding", decode.list(number))
    decode.success(#(index, embedding))
  }
  case json.parse(body, decode.at(["data"], decode.list(item))) {
    Error(_) -> Error(InvalidOutput("voyage response did not match the schema"))
    Ok(items) -> {
      let ordered =
        list.sort(items, fn(a, b) { int.compare(a.0, b.0) })
        |> list.map(fn(i) { i.1 })
      let indexes = list.map(items, fn(i) { i.0 }) |> list.sort(int.compare)
      case
        list.length(ordered) == expected
        && indexes == list.index_map(ordered, fn(_, i) { i })
        && list.all(ordered, fn(v) { list.length(v) == config.dimensions })
        && list.all(ordered, fn(v) { list.all(v, is_finite) })
      {
        True -> Ok(ordered)
        False -> Error(InvalidOutput("voyage returned mismatched embeddings"))
      }
    }
  }
}

fn is_finite(x: Float) -> Bool {
  float.absolute_value(x) <. 1.0e30
}

fn trim_slash(url: String) -> String {
  case string.ends_with(url, "/") {
    True -> string.drop_end(url, 1)
    False -> url
  }
}

/// The start of an error response body, for operator logs.
fn excerpt(body: String) -> String {
  string.slice(body, 0, 300)
}
