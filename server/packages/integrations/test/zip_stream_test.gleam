import gleam/bit_array
import libarrie/integrations/zip

@external(erlang, "zip_ffi", "unzip")
fn unzip(archive: BitArray) -> Result(List(#(String, BitArray)), String)

/// Whole and streamed entries in one archive read back with OTP's zip.
pub fn streamed_entries_round_trip_test() {
  let w = zip.new()
  let #(w, first) = zip.add(w, "manifest.json", <<"{\"a\":1}":utf8>>)
  let #(streaming, header) = zip.begin(w, "index.jsonl")
  let one = <<"{\"ordinal\":0}\n":utf8>>
  let two = <<"{\"ordinal\":1}\n":utf8>>
  let streaming = zip.chunk(zip.chunk(streaming, one), two)
  let #(w, descriptor) = zip.end(w, streaming)
  let #(w, last) = zip.add(w, "notebooks/page-1.jpg", <<1, 2, 3>>)
  let archive = bit_array.concat([first, header, one, two, descriptor, last, zip.finish(w)])
  let assert Ok(files) = unzip(archive)
  let assert [
    #("manifest.json", <<"{\"a\":1}":utf8>>),
    #("index.jsonl", index),
    #("notebooks/page-1.jpg", <<1, 2, 3>>),
  ] = files
  let assert True = index == <<one:bits, two:bits>>
}
