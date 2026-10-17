//// Structural validation of frozen upload bytes (section 7, step 7).
////
//// This reads only container headers (file signature and declared
//// dimensions) in pure Gleam; it never decompresses pixel data. Full decoding
//// for thumbnails/previews belongs in the isolated decoder subprocess run
//// under the OS-level launcher (section 7), which is a separate adapter.

import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import libarrie/integrations/zip

pub type Format {
  Jpeg
  Png
}

pub type ImageInfo {
  ImageInfo(format: Format, width: Int, height: Int)
}

pub type Limits {
  Limits(max_bytes: Int, max_dimension: Int, max_pixels: Int)
}

pub fn default_limits() -> Limits {
  Limits(max_bytes: 20_000_000, max_dimension: 20_000, max_pixels: 80_000_000)
}

pub fn content_type(format: Format) -> String {
  case format {
    Jpeg -> "image/jpeg"
    Png -> "image/png"
  }
}

/// Validate signature, dimensions and bounds. Returns `Error(reason)` for
/// anything that must fail as `unsupported_image`.
pub fn inspect(bytes: BitArray, limits: Limits) -> Result(ImageInfo, String) {
  use _ <- result.try(case bit_array.byte_size(bytes) <= limits.max_bytes {
    True -> Ok(Nil)
    False -> Error("too_large")
  })
  use info <- result.try(case bytes {
    <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _:32, "IHDR", width:32, height:32, _:bits>> ->
      Ok(ImageInfo(Png, width, height))
    <<0xFF, 0xD8, rest:bits>> -> jpeg_dimensions(rest)
    _ -> Error("unrecognized_format")
  })
  case info.width, info.height {
    w, h if w <= 0 || h <= 0 -> Error("invalid_dimensions")
    w, h if w > limits.max_dimension || h > limits.max_dimension ->
      Error("dimensions_exceed_limit")
    w, h if w * h > limits.max_pixels -> Error("pixels_exceed_limit")
    _, _ -> Ok(info)
  }
}

fn jpeg_dimensions(bytes: BitArray) -> Result(ImageInfo, String) {
  case bytes {
    // Fill bytes between markers.
    <<0xFF, 0xFF, _:bits>> -> {
      let assert <<_, rest:bits>> = bytes
      jpeg_dimensions(rest)
    }
    <<0xFF, marker, _length:16, _precision, height:16, width:16, _:bits>>
      if marker >= 0xC0
      && marker <= 0xCF
      && marker != 0xC4
      && marker != 0xC8
      && marker != 0xCC
    -> Ok(ImageInfo(Jpeg, width, height))
    <<0xFF, 0xD9, _:bits>> | <<0xFF, 0xDA, _:bits>> -> Error("missing_frame_header")
    <<0xFF, marker, _:bits>> if marker >= 0xD0 && marker <= 0xD7 -> {
      let assert <<_, _, rest:bits>> = bytes
      jpeg_dimensions(rest)
    }
    <<0xFF, _marker, length:16, _:bits>> if length >= 2 -> {
      let skip = 2 + length
      case bit_array.slice(bytes, skip, bit_array.byte_size(bytes) - skip) {
        Ok(rest) -> jpeg_dimensions(rest)
        Error(_) -> Error("truncated")
      }
    }
    _ -> Error("truncated")
  }
}

/// Text embedded for the development mock OCR provider: a PNG `tEXt` chunk
/// with keyword `libarrie:text`, or a JPEG COM segment. Development only.
pub fn embedded_text(bytes: BitArray) -> Option(String) {
  case bytes {
    <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, rest:bits>> -> png_text(rest)
    <<0xFF, 0xD8, rest:bits>> -> jpeg_comment(rest)
    _ -> None
  }
}

fn png_text(bytes: BitArray) -> Option(String) {
  case bytes {
    <<length:32, "tEXt", rest:bits>> ->
      case bit_array.slice(rest, 0, length) {
        Ok(data) -> {
          let prefix = <<"libarrie:text", 0>>
          let n = bit_array.byte_size(prefix)
          case bit_array.slice(data, 0, n) == Ok(prefix) {
            True ->
              bit_array.slice(data, n, length - n)
              |> result.try(bit_array.to_string)
              |> option.from_result
            False -> skip_png_chunk(bytes, length)
          }
        }
        Error(_) -> None
      }
    <<length:32, _type:32, _:bits>> -> skip_png_chunk(bytes, length)
    _ -> None
  }
}

fn skip_png_chunk(bytes: BitArray, length: Int) -> Option(String) {
  let skip = 12 + length
  case bit_array.slice(bytes, skip, bit_array.byte_size(bytes) - skip) {
    Ok(rest) -> png_text(rest)
    Error(_) -> None
  }
}

fn jpeg_comment(bytes: BitArray) -> Option(String) {
  case bytes {
    <<0xFF, 0xFE, length:16, rest:bits>> ->
      bit_array.slice(rest, 0, length - 2)
      |> result.try(bit_array.to_string)
      |> option.from_result
    <<0xFF, 0xDA, _:bits>> -> None
    <<0xFF, _marker, length:16, _:bits>> if length >= 2 -> {
      let skip = 2 + length
      case bit_array.slice(bytes, skip, bit_array.byte_size(bytes) - skip) {
        Ok(rest) -> jpeg_comment(rest)
        Error(_) -> None
      }
    }
    _ -> None
  }
}

/// Build a valid white grayscale PNG carrying mock OCR text, for tests and
/// development seed tooling. Pixel data is stored in uncompressed deflate
/// blocks, and every chunk has a correct CRC, so real decoders accept it.
pub fn mock_png(width: Int, height: Int, text: Option(String)) -> BitArray {
  let ihdr = <<width:32, height:32, 8, 0, 0, 0, 0>>
  let row = <<0, { list.repeat(<<255>>, width) |> bit_array.concat }:bits>>
  let raw = list.repeat(row, height) |> bit_array.concat
  let chunks = [
    chunk("IHDR", ihdr),
    ..list.append(
      case text {
        Some(t) -> [chunk("tEXt", <<"libarrie:text", 0, t:utf8>>)]
        None -> []
      },
      [chunk("IDAT", zlib_stored(raw))],
    )
  ]
  bit_array.concat([
    <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>>,
    ..list.append(chunks, [chunk("IEND", <<>>)])
  ])
}

fn chunk(kind: String, data: BitArray) -> BitArray {
  let body = <<kind:utf8, data:bits>>
  <<bit_array.byte_size(data):32, body:bits, zip.crc32(body):32>>
}

/// zlib stream made of stored (uncompressed) deflate blocks.
fn zlib_stored(data: BitArray) -> BitArray {
  bit_array.concat([<<0x78, 0x01>>, stored_blocks(data, []), <<adler32(data):32>>])
}

fn stored_blocks(data: BitArray, acc: List(BitArray)) -> BitArray {
  let size = bit_array.byte_size(data)
  case size > 65_535 {
    True -> {
      let assert Ok(block) = bit_array.slice(data, 0, 65_535)
      let assert Ok(rest) = bit_array.slice(data, 65_535, size - 65_535)
      stored_blocks(rest, [block_bytes(block, False), ..acc])
    }
    False ->
      [block_bytes(data, True), ..acc] |> list.reverse |> bit_array.concat
  }
}

fn block_bytes(block: BitArray, final: Bool) -> BitArray {
  let n = bit_array.byte_size(block)
  let header = case final {
    True -> 1
    False -> 0
  }
  <<header, n:little-size(16), { 65_535 - n }:little-size(16), block:bits>>
}

fn adler32(data: BitArray) -> Int {
  let #(a, b) = adler_loop(data, 1, 0)
  b * 65_536 + a
}

fn adler_loop(data: BitArray, a: Int, b: Int) -> #(Int, Int) {
  case data {
    <<byte, rest:bits>> -> {
      let a = { a + byte } % 65_521
      adler_loop(rest, a, { b + a } % 65_521)
    }
    _ -> #(a, b)
  }
}

pub fn format_name(format: Format) -> String {
  case format {
    Jpeg -> "jpeg"
    Png -> "png"
  }
  |> string.lowercase
}
