//// Search text normalization and passage chunking (sections 7 and 9).
////
//// Passages keep their original text (punctuation-bearing identifiers
//// survive) plus a normalized form used for lexical matching. Chunking
//// follows paragraphs, targeting roughly 200-500 tokens with bounded overlap
//// only when a single paragraph must be split.

import gleam/int
import gleam/list
import gleam/string

/// `norm-v2` adds CJK and Thai bigrams (see `normalize_with`).
pub const normalization_version = "norm-v2"

pub const chunking_version = "para-v1"

const max_words = 320

const overlap_words = 30

/// Normalize with the current version.
pub fn normalize(text: String) -> String {
  normalize_with(normalization_version, text)
}

/// Normalize as a given search configuration did. Queries use the version
/// of the release they search, so text and queries always match.
///
/// - `norm-v1`: lowercase, map punctuation and symbols to spaces and
///   collapse whitespace. Letters and digits from every script are kept.
/// - `norm-v2`: `norm-v1`, then runs of Chinese, Japanese, Korean or Thai
///   characters (scripts written without spaces between words) become
///   overlapping character bigrams: `東京駅で会議` becomes
///   `東京 京駅 駅で で会 会議`. Word-based text search and pg_trgm's word
///   similarity then see word boundaries, so partial queries and a misread
///   character still match. A single character stays as it is.
pub fn normalize_with(version: String, text: String) -> String {
  let basic = normalize_v1(text)
  case version {
    "norm-v1" -> basic
    _ -> bigram_scripts(basic)
  }
}

fn normalize_v1(text: String) -> String {
  text
  |> string.lowercase
  |> string.to_graphemes
  |> list.map(fn(c) {
    case is_separator(c) {
      True -> " "
      False -> c
    }
  })
  |> string.concat
  |> string.split(" ")
  |> list.filter(fn(w) { w != "" })
  |> string.join(" ")
}

/// Scripts written without spaces between words.
pub fn is_unspaced_script(grapheme: String) -> Bool {
  case string.to_utf_codepoints(grapheme) {
    [first, ..] -> {
      let c = string.utf_codepoint_to_int(first)
      { c >= 0x0E00 && c <= 0x0E7F }
      || { c >= 0x1100 && c <= 0x11FF }
      || { c >= 0x3040 && c <= 0x30FF }
      || { c >= 0x3130 && c <= 0x318F }
      || { c >= 0x31F0 && c <= 0x31FF }
      || { c >= 0x3400 && c <= 0x4DBF }
      || { c >= 0x4E00 && c <= 0x9FFF }
      || { c >= 0xAC00 && c <= 0xD7AF }
      || { c >= 0xF900 && c <= 0xFAFF }
      || { c >= 0x20000 && c <= 0x2FA1F }
    }
    [] -> False
  }
}

fn bigram_scripts(normalized: String) -> String {
  normalized
  |> string.split(" ")
  |> list.flat_map(fn(word) {
    word
    |> string.to_graphemes
    |> list.chunk(is_unspaced_script)
    |> list.flat_map(fn(run) {
      case run {
        [first, ..] ->
          case is_unspaced_script(first) {
            True -> bigrams(run)
            False -> [string.concat(run)]
          }
        [] -> []
      }
    })
  })
  |> list.filter(fn(w) { w != "" })
  |> string.join(" ")
}

fn bigrams(run: List(String)) -> List(String) {
  case run {
    [single] -> [single]
    _ -> list.window_by_2(run) |> list.map(fn(pair) { pair.0 <> pair.1 })
  }
}

fn is_separator(c: String) -> Bool {
  string.contains(" \t\r\n.,;:!?\"'`()[]{}<>/\\|-_=+*&^%$#@~", c)
  || c == "\u{00A0}"
  || c == "\u{2014}"
  || c == "\u{2013}"
  || c == "\u{2018}"
  || c == "\u{2019}"
  || c == "\u{201C}"
  || c == "\u{201D}"
}

pub type Chunk {
  Chunk(ordinal: Int, text: String, start_offset: Int, end_offset: Int)
}

type Segment {
  Segment(text: String, start: Int, end: Int, words: Int)
}

/// Split a transcript into passages with grapheme offsets into the original.
/// Short pages become one passage; empty text produces none.
pub fn chunk(text: String) -> List(Chunk) {
  let segments =
    paragraphs(string.to_graphemes(text), 0, 0, [], [])
    |> list.flat_map(split_long)
  pack(segments, [], [])
  |> list.index_map(fn(seg, i) { Chunk(i, seg.text, seg.start, seg.end) })
}

/// Paragraph segments separated by blank lines.
fn paragraphs(
  chars: List(String),
  index: Int,
  start: Int,
  current: List(String),
  done: List(Segment),
) -> List(Segment) {
  case chars {
    [] -> list.reverse(push(done, current, start))
    ["\n", "\n", ..rest] -> {
      let #(rest, skipped) = skip_newlines(rest, 0)
      let next = index + 2 + skipped
      paragraphs(rest, next, next, [], push(done, current, start))
    }
    [c, ..rest] -> paragraphs(rest, index + 1, start, [c, ..current], done)
  }
}

fn skip_newlines(chars: List(String), n: Int) -> #(List(String), Int) {
  case chars {
    ["\n", ..rest] -> skip_newlines(rest, n + 1)
    _ -> #(chars, n)
  }
}

fn push(done: List(Segment), current: List(String), start: Int) -> List(Segment) {
  let text = current |> list.reverse |> string.concat
  let trimmed = string.trim(text)
  case trimmed {
    "" -> done
    _ -> {
      let leading = string.length(text) - string.length(string.trim_start(text))
      let s = start + leading
      [Segment(trimmed, s, s + string.length(trimmed), word_count(trimmed)), ..done]
    }
  }
}

fn word_count(text: String) -> Int {
  text
  |> string.replace("\n", " ")
  |> string.split(" ")
  |> list.filter(fn(w) { w != "" })
  |> list.length
}

/// Split an oversized paragraph into word windows with bounded overlap.
fn split_long(segment: Segment) -> List(Segment) {
  case segment.words <= max_words {
    True -> [segment]
    False -> {
      let words = word_spans(string.to_graphemes(segment.text), 0, -1, [])
      windows(words, segment, [])
    }
  }
}

fn word_spans(
  chars: List(String),
  index: Int,
  start: Int,
  spans: List(#(Int, Int)),
) -> List(#(Int, Int)) {
  case chars {
    [] ->
      case start >= 0 {
        True -> list.reverse([#(start, index), ..spans])
        False -> list.reverse(spans)
      }
    [c, ..rest] ->
      case c == " " || c == "\n" || c == "\t", start >= 0 {
        True, True -> word_spans(rest, index + 1, -1, [#(start, index), ..spans])
        True, False -> word_spans(rest, index + 1, -1, spans)
        False, True -> word_spans(rest, index + 1, start, spans)
        False, False -> word_spans(rest, index + 1, index, spans)
      }
  }
}

fn windows(
  words: List(#(Int, Int)),
  segment: Segment,
  done: List(Segment),
) -> List(Segment) {
  case words {
    [] -> list.reverse(done)
    _ -> {
      let window = list.take(words, max_words)
      let assert Ok(#(first, _)) = list.first(window)
      let assert Ok(#(_, last)) = list.last(window)
      let text = string.slice(segment.text, first, last - first)
      let piece =
        Segment(text, segment.start + first, segment.start + last, list.length(window))
      case list.length(words) > max_words {
        True ->
          windows(list.drop(words, max_words - overlap_words), segment, [
            piece,
            ..done
          ])
        False -> list.reverse([piece, ..done])
      }
    }
  }
}

/// Greedily pack adjacent segments into passages of at most `max_words`.
fn pack(
  segments: List(Segment),
  current: List(Segment),
  done: List(Segment),
) -> List(Segment) {
  case segments {
    [] -> list.reverse(flush(current, done))
    [seg, ..rest] -> {
      let size = list.fold(current, 0, fn(n, s) { n + s.words })
      case current != [] && size + seg.words > max_words {
        True -> pack(rest, [seg], flush(current, done))
        False -> pack(rest, [seg, ..current], done)
      }
    }
  }
}

fn flush(current: List(Segment), done: List(Segment)) -> List(Segment) {
  case list.reverse(current) {
    [] -> done
    [first, ..] as ordered -> {
      let assert Ok(last) = list.last(ordered)
      let text = ordered |> list.map(fn(s) { s.text }) |> string.join("\n\n")
      let words = list.fold(ordered, 0, fn(n, s) { n + s.words })
      [Segment(text, first.start, last.end, words), ..done]
    }
  }
}

/// A short snippet around the first occurrence of any query word, falling
/// back to the start of the passage.
pub fn snippet(text: String, query: String, max_length: Int) -> String {
  let lowered = string.lowercase(text)
  let position =
    normalize(query)
    |> string.split(" ")
    |> list.filter_map(fn(word) {
      case string.split_once(lowered, word) {
        Ok(#(before, _)) if word != "" -> Ok(string.length(before))
        _ -> Error(Nil)
      }
    })
    |> list.sort(int.compare)
    |> list.first
  let start = case position {
    Ok(p) if p > max_length / 3 -> p - max_length / 3
    _ -> 0
  }
  let piece = string.slice(text, start, max_length)
  let prefix = case start > 0 {
    True -> "…"
    False -> ""
  }
  let suffix = case start + max_length < string.length(text) {
    True -> "…"
    False -> ""
  }
  prefix <> string.trim(piece) <> suffix
}

/// Grapheme ranges in `text` matching any normalized query word (two or
/// more characters), merged when they overlap. Used to render `<mark>`
/// highlights in snippets without trusting HTML.
pub fn highlights(text: String, query: String) -> List(#(Int, Int)) {
  let lowered = string.lowercase(text)
  normalize(query)
  |> string.split(" ")
  |> list.filter(fn(word) { string.length(word) >= 2 })
  |> list.unique
  |> list.flat_map(fn(word) { occurrences(lowered, word, 0, []) })
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
  |> merge_ranges([])
}

fn occurrences(
  haystack: String,
  needle: String,
  offset: Int,
  found: List(#(Int, Int)),
) -> List(#(Int, Int)) {
  case string.split_once(haystack, needle) {
    Error(_) -> found
    Ok(#(before, after)) -> {
      let start = offset + string.length(before)
      let end = start + string.length(needle)
      occurrences(after, needle, end, [#(start, end), ..found])
    }
  }
}

fn merge_ranges(
  ranges: List(#(Int, Int)),
  merged: List(#(Int, Int)),
) -> List(#(Int, Int)) {
  case ranges, merged {
    [], _ -> list.reverse(merged)
    [r, ..rest], [last, ..done] if r.0 <= last.1 ->
      merge_ranges(rest, [#(last.0, int.max(last.1, r.1)), ..done])
    [r, ..rest], _ -> merge_ranges(rest, [r, ..merged])
  }
}
