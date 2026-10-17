//// Mistral OCR adapter (`POST /v1/ocr`), pinned to an explicit model
//// version (default `mistral-ocr-4-1`); never a mutable `-latest` alias.
////
//// Classification (sections 7 and 17): Mistral returns markdown, paragraph
//// blocks with pixel bounding boxes and page confidence, but no explicit
//// blank-page determination. Therefore:
//// - text with average page confidence at or above the threshold ->
////   `TextDetected` with normalized block boxes;
//// - text below the threshold -> `Unreadable`;
//// - no text but embedded images/figures only -> `UnsupportedContent`
////   (diagram-only page, kept viewable);
//// - no text at all -> `NoTextDetected` (never `BlankConfirmed`: an empty
////   string alone is not proof of a blank page).
//// HTTP 401/403 are `Misconfigured`; 408/429/5xx and network failures are
//// `Transient`; 400/413/415/422 mean the image itself was refused
//// (`UnsupportedContent`); malformed bodies are `InvalidOutput`.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/result
import gleam/string
import libarrie/integrations/providers.{
  type ProviderError, type Recognition, InvalidOutput, Misconfigured, Transient,
}

pub type Config {
  Config(
    api_key: String,
    base_url: String,
    model: String,
    /// Average page confidence below this is treated as unreadable.
    min_confidence: Float,
    timeout_ms: Int,
  )
}

pub fn default_config(api_key: String) -> Config {
  Config(
    api_key:,
    base_url: "https://api.mistral.ai",
    model: "mistral-ocr-4-1",
    min_confidence: 0.5,
    timeout_ms: 90_000,
  )
}

pub fn provider(config: Config) -> providers.OcrProvider {
  providers.OcrProvider(
    name: "mistral",
    model_id: config.model,
    processing_version: config.model <> "/libarrie-ocr-v1",
    recognize: fn(bytes, content_type) { recognize(config, bytes, content_type) },
  )
}

pub fn request_body(config: Config, bytes: BitArray, content_type: String) -> String {
  json.object([
    #("model", json.string(config.model)),
    #(
      "document",
      json.object([
        #("type", json.string("image_url")),
        #(
          "image_url",
          json.object([
            #(
              "url",
              json.string(
                "data:" <> content_type <> ";base64," <> bit_array.base64_encode(bytes, True),
              ),
            ),
          ]),
        ),
      ]),
    ),
    #("include_image_base64", json.bool(False)),
    #("include_blocks", json.bool(True)),
    #("confidence_scores_granularity", json.string("page")),
  ])
  |> json.to_string
}

pub fn recognize(
  config: Config,
  bytes: BitArray,
  content_type: String,
) -> Result(Recognition, ProviderError) {
  use req <- result.try(
    request.to(trim_slash(config.base_url) <> "/v1/ocr")
    |> result.replace_error(Misconfigured("invalid Mistral base URL")),
  )
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("authorization", "Bearer " <> config.api_key)
    |> request.set_header("content-type", "application/json")
    |> request.set_header("accept", "application/json")
    |> request.set_body(request_body(config, bytes, content_type))
  case httpc.configure() |> httpc.timeout(config.timeout_ms) |> httpc.dispatch(req) {
    Error(e) -> Error(Transient("mistral request failed: " <> string.inspect(e)))
    Ok(resp) ->
      case resp.status {
        200 -> classify(config, resp.body)
        401 | 403 -> Error(Misconfigured("mistral rejected credentials"))
        400 | 413 | 415 | 422 -> Ok(providers.UnsupportedContent)
        408 | 429 -> Error(Transient("mistral " <> int.to_string(resp.status) <> ": " <> excerpt(resp.body)))
        s if s >= 500 -> Error(Transient("mistral " <> int.to_string(s) <> ": " <> excerpt(resp.body)))
        s -> Error(InvalidOutput("mistral unexpected status " <> int.to_string(s) <> ": " <> excerpt(resp.body)))
      }
  }
}

type Page {
  Page(
    markdown: String,
    width: Int,
    height: Int,
    confidence: Option(Float),
    blocks: List(RawBlock),
    image_count: Int,
  )
}

type RawBlock {
  RawBlock(
    kind: String,
    text: String,
    x0: Int,
    y0: Int,
    x1: Int,
    y1: Int,
    confidence: Option(Float),
  )
}

fn number() -> decode.Decoder(Float) {
  decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)])
}

fn page_decoder() -> decode.Decoder(Page) {
  use markdown <- decode.field("markdown", decode.string)
  use width <- decode.subfield(["dimensions", "width"], decode.int)
  use height <- decode.subfield(["dimensions", "height"], decode.int)
  use confidence <- decode.then(decode.optionally_at(
    ["confidence_scores", "average_page_confidence_score"],
    None,
    decode.optional(number()),
  ))
  use blocks <- decode.optional_field(
    "blocks",
    [],
    decode.optional(decode.list(block_decoder())) |> decode.map(option.unwrap(_, [])),
  )
  use images <- decode.optional_field(
    "images",
    [],
    decode.optional(decode.list(decode.dynamic)) |> decode.map(option.unwrap(_, [])),
  )
  decode.success(Page(
    markdown:,
    width:,
    height:,
    confidence:,
    blocks:,
    image_count: list.length(images),
  ))
}

/// A block as `mistral-ocr-4-1` returns it: pixel corners at the top level,
/// the text in `content`, and `confidence_scores` (null at page
/// granularity). A nested `bbox` and a `text` field are also accepted.
fn block_decoder() -> decode.Decoder(RawBlock) {
  use kind <- decode.optional_field("type", "text", decode.string)
  use content <- decode.optional_field("content", None, decode.optional(decode.string))
  use legacy_text <- decode.optional_field("text", None, decode.optional(decode.string))
  use #(x0, y0, x1, y1) <- decode.then(decode.one_of(corners([]), [corners(["bbox"])]))
  use confidence <- decode.optional_field(
    "confidence_scores",
    None,
    decode.one_of(decode.optional(number()), [decode.success(None)]),
  )
  let text = option.or(content, legacy_text) |> option.unwrap("")
  decode.success(RawBlock(kind, text, x0, y0, x1, y1, confidence))
}

fn corners(prefix: List(String)) -> decode.Decoder(#(Int, Int, Int, Int)) {
  let at = fn(name) { list.append(prefix, [name]) }
  use x0 <- decode.subfield(at("top_left_x"), decode.int)
  use y0 <- decode.subfield(at("top_left_y"), decode.int)
  use x1 <- decode.subfield(at("bottom_right_x"), decode.int)
  use y1 <- decode.subfield(at("bottom_right_y"), decode.int)
  decode.success(#(x0, y0, x1, y1))
}

/// Classify a 200 response body. Public for contract tests.
pub fn classify(config: Config, body: String) -> Result(Recognition, ProviderError) {
  case json.parse(body, decode.at(["pages"], decode.list(page_decoder()))) {
    Error(_) -> Error(InvalidOutput("mistral response did not match the OCR schema"))
    Ok([]) -> Error(InvalidOutput("mistral returned no pages"))
    Ok([page, ..]) -> {
      let text = clean_markdown(page.markdown)
      case text, page.image_count > 0 || has_figure_blocks(page.blocks) {
        "", True -> Ok(providers.UnsupportedContent)
        "", False -> Ok(providers.NoTextDetected)
        _, _ ->
          case page.confidence {
            Some(c) if c <. config.min_confidence -> Ok(providers.Unreadable)
            _ -> Ok(providers.TextDetected(text, None, normalize_blocks(page)))
          }
      }
    }
  }
}

fn has_figure_blocks(blocks: List(RawBlock)) -> Bool {
  list.any(blocks, fn(b) {
    let kind = string.lowercase(b.kind)
    kind == "image" || kind == "figure" || kind == "picture"
  })
}

/// Drop image references and collapse whitespace while keeping the
/// recognized text, line breaks and punctuation intact.
pub fn clean_markdown(markdown: String) -> String {
  let assert Ok(images) = regexp.from_string("!\\[[^\\]]*\\]\\([^)]*\\)")
  regexp.replace(images, markdown, "")
  |> string.split("\n")
  |> list.map(string.trim_end)
  |> string.join("\n")
  |> collapse_blank_lines
  |> string.trim
}

fn collapse_blank_lines(text: String) -> String {
  case string.contains(text, "\n\n\n") {
    True -> collapse_blank_lines(string.replace(text, "\n\n\n", "\n\n"))
    False -> text
  }
}

fn normalize_blocks(page: Page) -> List(providers.Block) {
  case page.width > 0 && page.height > 0 {
    False -> []
    True -> {
      let w = int.to_float(page.width)
      let h = int.to_float(page.height)
      let clamp = fn(v: Float) {
        case v <. 0.0, v >. 1.0 {
          True, _ -> 0.0
          _, True -> 1.0
          _, _ -> v
        }
      }
      page.blocks
      |> list.filter(fn(b) { string.trim(b.text) != "" && b.x1 > b.x0 && b.y1 > b.y0 })
      |> list.map(fn(b) {
        providers.Block(
          kind: b.kind,
          text: b.text,
          left: clamp(int.to_float(b.x0) /. w),
          top: clamp(int.to_float(b.y0) /. h),
          right: clamp(int.to_float(b.x1) /. w),
          bottom: clamp(int.to_float(b.y1) /. h),
          confidence: b.confidence,
        )
      })
    }
  }
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
