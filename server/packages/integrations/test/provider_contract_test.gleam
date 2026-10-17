//// Contract tests for the Mistral OCR and Voyage adapters against a local
//// fake server that implements the documented request/response shapes.
//// No real credentials are used.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import libarrie/integrations/mistral
import libarrie/integrations/providers
import libarrie/integrations/voyage
import mist
import simplifile

const token = "test-key-not-real"

fn reply(status: Int, body: String) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn page_json(markdown: String, confidence: Float, blocks: String, images: String) -> String {
  "{\"model\":\"mistral-ocr-4-1\",\"pages\":[{\"index\":0,\"markdown\":"
  <> json.to_string(json.string(markdown))
  <> ",\"images\":" <> images
  <> ",\"dimensions\":{\"dpi\":200,\"height\":1000,\"width\":800},"
  <> "\"confidence_scores\":{\"average_page_confidence_score\":"
  <> string.inspect(confidence)
  <> ",\"minimum_page_confidence_score\":0.2},\"blocks\":" <> blocks
  <> "}],\"usage_info\":{\"pages_processed\":1,\"doc_size_bytes\":10}}"
}

/// The fake Mistral server decides its answer from the uploaded bytes.
fn mistral_handler(req: request.Request(mist.Connection)) {
  let assert Ok(req) = mist.read_body(req, 10_000_000)
  let assert Ok(body) = bit_array.to_string(req.body)
  let fields =
    json.parse(body, {
      use model <- decode.field("model", decode.string)
      use kind <- decode.subfield(["document", "type"], decode.string)
      use url <- decode.subfield(["document", "image_url", "url"], decode.string)
      use include_images <- decode.field("include_image_base64", decode.bool)
      decode.success(#(model, kind, url, include_images))
    })
  case request.get_header(req, "authorization"), req.path, fields {
    Ok("Bearer test-key-not-real"), "/v1/ocr",
      Ok(#("mistral-ocr-4-1", "image_url", url, False))
    -> {
      let assert Ok(#(_, payload)) = string.split_once(url, "base64,")
      let assert Ok(bits) = bit_array.base64_decode(payload)
      let assert Ok(marker) = bit_array.to_string(bits)
      case marker {
        "text" ->
          reply(200, page_json(
            "# Notes\n\nCall Ada about INV-2024-07.\n\n![img-0.jpeg](img-0.jpeg)\n",
            0.93,
            "[{\"top_left_x\":80,\"top_left_y\":100,\"bottom_right_x\":720,\"bottom_right_y\":200,\"content\":\"Call Ada about INV-2024-07.\",\"confidence_scores\":null,\"type\":\"text\"}]",
            "[{\"id\":\"img-0.jpeg\",\"top_left_x\":0,\"top_left_y\":0,\"bottom_right_x\":10,\"bottom_right_y\":10}]",
          ))
        "faint" -> reply(200, page_json("smudged words", 0.31, "[]", "[]"))
        "diagram" ->
          reply(200, page_json("![img-0.jpeg](img-0.jpeg)", 0.9, "[]",
            "[{\"id\":\"img-0.jpeg\",\"top_left_x\":0,\"top_left_y\":0,\"bottom_right_x\":10,\"bottom_right_y\":10}]"))
        "empty" -> reply(200, page_json("", 0.99, "[]", "[]"))
        "throttle" -> reply(429, "{\"message\":\"rate limited\"}")
        "outage" -> reply(503, "{\"message\":\"unavailable\"}")
        "bad-image" -> reply(422, "{\"message\":\"invalid image\"}")
        "malformed" -> reply(200, "{\"pages\":[{\"oops\":true}]}")
        _ -> reply(500, "{}")
      }
    }
    Ok(_), _, _ | Error(_), _, _ -> reply(401, "{\"message\":\"unauthorized\"}")
  }
}

/// The fake Voyage server returns deterministic vectors in reverse order to
/// prove results are reordered by index.
fn voyage_handler(requests: process.Subject(Int)) {
  fn(req: request.Request(mist.Connection)) {
    let assert Ok(req) = mist.read_body(req, 10_000_000)
    let assert Ok(body) = bit_array.to_string(req.body)
    let parsed =
      json.parse(body, {
        use input <- decode.field("input", decode.list(decode.string))
        use model <- decode.field("model", decode.string)
        use input_type <- decode.field("input_type", decode.string)
        use dims <- decode.field("output_dimension", decode.int)
        use truncation <- decode.field("truncation", decode.bool)
        decode.success(#(input, model, input_type, dims, truncation))
      })
    case request.get_header(req, "authorization"), parsed {
      Ok("Bearer test-key-not-real"), Ok(#(input, "voyage-4-large", kind, dims, False))
        if kind == "document" || kind == "query"
      -> {
        process.send(requests, list.length(input))
        case input {
          ["force-malformed", ..] ->
            reply(200, "{\"data\":[{\"index\":0,\"embedding\":[1.0]}]}")
          _ -> {
            let data =
              input
              |> list.index_map(fn(text, i) {
                let v = list.repeat(int.to_float(string.length(text) + i), dims)
                json.object([
                  #("object", json.string("embedding")),
                  #("embedding", json.array(v, json.float)),
                  #("index", json.int(i)),
                ])
              })
              |> list.reverse
            reply(200, json.to_string(json.object([
              #("object", json.string("list")),
              #("data", json.preprocessed_array(data)),
              #("model", json.string("voyage-4-large")),
              #("usage", json.object([#("total_tokens", json.int(10))])),
            ])))
          }
        }
      }
      Ok("Bearer test-key-not-real"), _ -> reply(400, "{\"detail\":\"bad request\"}")
      _, _ -> reply(401, "{\"detail\":\"unauthorized\"}")
    }
  }
}

fn start(handler) -> Int {
  let port = 19_000 + int.random(5000)
  let assert Ok(_) = mist.new(handler) |> mist.port(port) |> mist.start
  port
}

pub fn mistral_classification_contract_test() {
  let port = start(mistral_handler)
  let config =
    mistral.Config(..mistral.default_config(token), base_url: "http://localhost:" <> int.to_string(port))
  let ocr = mistral.provider(config)
  let assert "mistral-ocr-4-1" = ocr.model_id
  let run = fn(marker: String) { ocr.recognize(<<marker:utf8>>, "image/png") }
  let assert Ok(providers.TextDetected(text, None, [block])) = run("text")
  let assert "# Notes\n\nCall Ada about INV-2024-07." = text
  // Pixel boxes are normalized to the page dimensions.
  let assert 0.1 = block.left
  let assert 0.1 = block.top
  let assert 0.9 = block.right
  let assert 0.2 = block.bottom
  let assert Ok(providers.Unreadable) = run("faint")
  let assert Ok(providers.UnsupportedContent) = run("diagram")
  // An empty response is never treated as a confirmed blank page.
  let assert Ok(providers.NoTextDetected) = run("empty")
  let assert Error(providers.Transient(_)) = run("throttle")
  let assert Error(providers.Transient(_)) = run("outage")
  let assert Ok(providers.UnsupportedContent) = run("bad-image")
  let assert Error(providers.InvalidOutput(_)) = run("malformed")
  let wrong_key = mistral.provider(mistral.Config(..config, api_key: "nope"))
  let assert Error(providers.Misconfigured(_)) = wrong_key.recognize(<<"text":utf8>>, "image/png")
  // Unreachable endpoint is transient, not a user failure.
  let down = mistral.provider(mistral.Config(..config, base_url: "http://localhost:1"))
  let assert Error(providers.Transient(_)) = down.recognize(<<"text":utf8>>, "image/png")
}

pub fn voyage_embedding_contract_test() {
  let requests = process.new_subject()
  let port = start(voyage_handler(requests))
  let config =
    voyage.Config(
      ..voyage.default_config(token),
      base_url: "http://localhost:" <> int.to_string(port),
      dimensions: 256,
      max_chars_per_request: 20,
    )
  let embedder = voyage.provider(config)
  let assert 256 = embedder.dimensions
  // Inputs are split into batches and results stay in input order.
  let texts = ["alpha", "beta-gamma", "delta", "epsilon-zeta", "eta"]
  let assert Ok(vectors) = embedder.embed(texts, providers.Document)
  let assert 5 = list.length(vectors)
  let assert True = list.all(vectors, fn(v) { list.length(v) == 256 })
  let firsts = list.map(vectors, fn(v) { let assert [x, ..] = v x })
  // The fake encodes (length + index within its batch): batch one is
  // alpha, beta-gamma, delta; batch two is epsilon-zeta, eta.
  let assert [5.0, 11.0, 7.0, 12.0, 4.0] = firsts
  let assert Ok(3) = process.receive(requests, 1000)
  let assert Ok(2) = process.receive(requests, 1000)
  let assert Ok([_]) = embedder.embed(["what did ada say"], providers.Query)
  let assert Error(providers.InvalidOutput(_)) = embedder.embed(["force-malformed"], providers.Query)
  let wrong_key = voyage.provider(voyage.Config(..config, api_key: "nope"))
  let assert Error(providers.Misconfigured(_)) = wrong_key.embed(["x"], providers.Query)
  // Cost estimate: upper bound of one token per character.
  let assert 1 = embedder.estimate_micros(["short"])
  let assert 12_000 = voyage.estimate_micros(voyage.default_config(token), [string.repeat("a", 100_000)])
}

pub fn voyage_batches_respect_limits_test() {
  let config = voyage.Config(..voyage.default_config(token), max_inputs_per_request: 2, max_chars_per_request: 10)
  let assert [["aa", "bb"], ["cc"], ["dddddddddddd"], ["e"]] =
    voyage.batches(config, ["aa", "bb", "cc", "dddddddddddd", "e"])
}

/// A real `mistral-ocr-4-1` response, captured for a synthetic two-line
/// test image, classifies with both blocks and their pixel boxes.
pub fn mistral_real_response_test() {
  let assert Ok(body) = simplifile.read("test/fixtures/mistral-ocr-4-1-response.json")
  let config = mistral.default_config("not-used")
  let assert Ok(providers.TextDetected(text, None, [first, second])) = mistral.classify(config, body)
  let assert "Meeting notes 12 May\n\nCall Dana about the budget" = text
  let assert "Meeting notes 12 May" = first.text
  let assert "Call Dana about the budget" = second.text
  // 36 px of a 900 px wide page.
  let assert 0.04 = first.left
}
