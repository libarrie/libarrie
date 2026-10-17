//// Model provider adapters (sections 7 and 9).
////
//// Recognition must return a classified outcome; an empty string alone is
//// never treated as a blank page. Embedding adapters declare their model and
//// dimensions so search never compares incompatible vector families.
////
//// Only development mock adapters ship here. Real providers (for example
//// Mistral OCR and Voyage embeddings) require an explicitly authorized
//// evaluation and recorded privacy terms before a hosted deployment enables
//// them (section 6).

import gleam/bit_array
import gleam/crypto
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import libarrie/integrations/image

pub type ProviderError {
  /// Timeouts, 429 and temporary 5xx: retry with backoff.
  Transient(detail: String)
  /// Invalid credentials or configuration: pause and alert instead of
  /// exhausting every user job.
  Misconfigured(detail: String)
  /// Malformed provider output.
  InvalidOutput(detail: String)
}

/// A recognized text block with its bounding box normalized to 0..1 of the
/// page width/height. Only provider-reported boxes are kept; none are ever
/// invented.
pub type Block {
  Block(
    kind: String,
    text: String,
    left: Float,
    top: Float,
    right: Float,
    bottom: Float,
    confidence: Option(Float),
  )
}

pub type Recognition {
  TextDetected(text: String, language: Option(String), blocks: List(Block))
  BlankConfirmed
  Unreadable
  UnsupportedContent
  /// A valid response with no text and no supported blank determination.
  NoTextDetected
}

pub type OcrProvider {
  OcrProvider(
    name: String,
    model_id: String,
    processing_version: String,
    recognize: fn(BitArray, String) -> Result(Recognition, ProviderError),
  )
}

pub type EmbeddingPurpose {
  Document
  Query
}

pub type EmbeddingProvider {
  EmbeddingProvider(
    name: String,
    model_id: String,
    dimensions: Int,
    embed: fn(List(String), EmbeddingPurpose) ->
      Result(List(List(Float)), ProviderError),
    /// Conservative cost ceiling (USD micros) for embedding these inputs.
    estimate_micros: fn(List(String)) -> Int,
  )
}

/// Development-only OCR. Reads text embedded in the image (see
/// `image.embedded_text`). Control markers exercise the outcome contract:
/// `[[blank]]`, `[[unreadable]]`, `[[unsupported]]`, `[[transient]]`,
/// `[[invalid]]`. Images without embedded text report `NoTextDetected`.
pub fn mock_ocr() -> OcrProvider {
  OcrProvider(
    name: "mock",
    model_id: "mock-ocr-1",
    processing_version: "mock-ocr-1/v1",
    recognize: fn(bytes, _content_type) {
      case image.embedded_text(bytes) {
        None -> Ok(NoTextDetected)
        Some(text) ->
          case string.trim(text) {
            "[[blank]]" -> Ok(BlankConfirmed)
            "[[unreadable]]" -> Ok(Unreadable)
            "[[unsupported]]" -> Ok(UnsupportedContent)
            "[[transient]]" -> Error(Transient("mock transient failure"))
            "[[invalid]]" -> Error(InvalidOutput("mock malformed response"))
            "" -> Ok(NoTextDetected)
            trimmed -> Ok(TextDetected(trimmed, Some("und"), []))
          }
      }
    },
  )
}

/// Development-only embedder: deterministic feature hashing of words and
/// character trigrams, L2-normalized. Similar wording yields similar vectors,
/// which is enough to exercise hybrid retrieval end to end.
pub fn mock_embedding(dimensions: Int) -> EmbeddingProvider {
  EmbeddingProvider(
    name: "mock",
    model_id: "mock-hash-embed-1",
    dimensions:,
    embed: fn(texts, _purpose) {
      Ok(list.map(texts, hash_embed(_, dimensions)))
    },
    estimate_micros: fn(_) { 100 },
  )
}

/// An embedder that always fails, for degraded-mode tests.
pub fn unavailable_embedding(dimensions: Int) -> EmbeddingProvider {
  EmbeddingProvider(
    name: "mock",
    model_id: "mock-hash-embed-1",
    dimensions:,
    embed: fn(_, _) { Error(Transient("embedding provider unavailable")) },
    estimate_micros: fn(_) { 100 },
  )
}

fn hash_embed(text: String, dimensions: Int) -> List(Float) {
  let words =
    text
    |> string.lowercase
    |> string.split(" ")
    |> list.flat_map(string.split(_, "\n"))
    |> list.map(strip_punctuation)
    |> list.filter(fn(w) { w != "" })
  let features =
    list.append(
      list.map(words, fn(w) { #("w:" <> w, 1.0) }),
      list.flat_map(words, fn(w) {
        trigrams(" " <> w <> " ") |> list.map(fn(t) { #("t:" <> t, 0.5) })
      }),
    )
  let buckets =
    list.fold(features, dict_new(dimensions), fn(acc, feature) {
      let #(key, weight) = feature
      let digest = crypto.hash(crypto.Sha256, bit_array.from_string(key))
      let assert <<index:32, sign:8, _:bits>> = digest
      let slot = index % dimensions
      let signed = case sign % 2 {
        0 -> weight
        _ -> 0.0 -. weight
      }
      add_at(acc, slot, signed)
    })
  let norm =
    buckets
    |> list.fold(0.0, fn(sum, v) { sum +. v *. v })
    |> float.square_root
    |> fn(r) {
      case r {
        Ok(n) if n >. 0.0 -> n
        _ -> 1.0
      }
    }
  list.map(buckets, fn(v) { v /. norm })
}

fn dict_new(dimensions: Int) -> List(Float) {
  list.repeat(0.0, dimensions)
}

fn add_at(values: List(Float), index: Int, amount: Float) -> List(Float) {
  list.index_map(values, fn(v, i) {
    case i == index {
      True -> v +. amount
      False -> v
    }
  })
}

fn trigrams(word: String) -> List(String) {
  let graphemes = string.to_graphemes(word)
  let n = list.length(graphemes)
  case n < 3 {
    True -> [word]
    False ->
      int.range(from: 0, to: n - 2, with: [], run: fn(acc, i) {
        [graphemes |> list.drop(i) |> list.take(3) |> string.concat, ..acc]
      })
  }
}

fn strip_punctuation(word: String) -> String {
  word
  |> string.to_graphemes
  |> list.filter(fn(c) { !string.contains(".,;:!?\"'()[]{}", c) })
  |> string.concat
}
