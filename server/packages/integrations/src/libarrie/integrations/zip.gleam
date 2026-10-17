//// Minimal streaming ZIP64 writer for export parts (section 14).
////
//// Entries are stored (images are already compressed) with UTF-8 names.
//// Every entry and the end records always use ZIP64 fields, so archives
//// larger than 4 GiB or with more than 65,535 entries need no special case.
//// Callers stream bytes out as they are produced; only the central
//// directory (one small record per entry) is kept in memory.
////
//// Interop note: CRC-32 uses the `erlang:crc32/2` BIF. gleam_stdlib and the
//// evaluated Gleam packages provide no CRC-32, and a pure-Gleam byte loop is
//// far too slow for 20 MB images.

import gleam/bit_array
import gleam/list

@external(erlang, "erlang", "crc32")
fn crc32_update(previous: Int, data: BitArray) -> Int

pub fn crc32(data: BitArray) -> Int {
  crc32_update(0, data)
}

pub type Entry {
  Entry(name: String, size: Int, crc: Int, offset: Int, flags: Int)
}

/// An entry being written in pieces (see `begin`).
pub type Streaming {
  Streaming(name: String, offset: Int, size: Int, crc: Int)
}

pub type Writer {
  Writer(offset: Int, entries: List(Entry))
}

pub fn new() -> Writer {
  Writer(offset: 0, entries: [])
}

const version = 45

const utf8_flag = 0x0800

// General purpose bit 3: CRC and sizes follow the data in a descriptor.
const descriptor_flag = 0x0008

// 1980-01-01 00:00 in DOS date/time format.
const dos_time = 0

const dos_date = 0x0021

/// Bytes for one stored entry (local header followed by the data) and the
/// updated writer.
pub fn add(writer: Writer, name: String, data: BitArray) -> #(Writer, BitArray) {
  let name_bits = bit_array.from_string(name)
  let size = bit_array.byte_size(data)
  let crc = crc32(data)
  let header = <<
    0x04034b50:little-size(32), version:little-size(16),
    utf8_flag:little-size(16), 0:little-size(16), dos_time:little-size(16),
    dos_date:little-size(16), crc:little-size(32), 0xFFFFFFFF:little-size(32),
    0xFFFFFFFF:little-size(32), bit_array.byte_size(name_bits):little-size(16),
    20:little-size(16), name_bits:bits, 0x0001:little-size(16),
    16:little-size(16), size:little-size(64), size:little-size(64),
  >>
  let bytes = <<header:bits, data:bits>>
  let entry = Entry(name:, size:, crc:, offset: writer.offset, flags: utf8_flag)
  #(
    Writer(
      offset: writer.offset + bit_array.byte_size(bytes),
      entries: [entry, ..writer.entries],
    ),
    bytes,
  )
}

/// Start an entry whose content is not known up front (for example a large
/// index produced page by page). Returns the local header bytes; follow with
/// `chunk` for each piece and `end` for the trailing data descriptor.
pub fn begin(writer: Writer, name: String) -> #(Streaming, BitArray) {
  let name_bits = bit_array.from_string(name)
  let header = <<
    0x04034b50:little-size(32), version:little-size(16),
    { utf8_flag + descriptor_flag }:little-size(16), 0:little-size(16),
    dos_time:little-size(16), dos_date:little-size(16), 0:little-size(32),
    0xFFFFFFFF:little-size(32), 0xFFFFFFFF:little-size(32),
    bit_array.byte_size(name_bits):little-size(16), 20:little-size(16), name_bits:bits,
    0x0001:little-size(16), 16:little-size(16), 0:little-size(64), 0:little-size(64),
  >>
  #(Streaming(name:, offset: writer.offset, size: 0, crc: 0), header)
}

/// Account for one piece of a streamed entry (the caller writes the bytes).
pub fn chunk(streaming: Streaming, data: BitArray) -> Streaming {
  Streaming(
    ..streaming,
    size: streaming.size + bit_array.byte_size(data),
    crc: crc32_update(streaming.crc, data),
  )
}

/// Finish a streamed entry: the ZIP64 data descriptor bytes and the writer
/// with the entry recorded for the central directory.
pub fn end(writer: Writer, streaming: Streaming) -> #(Writer, BitArray) {
  let name_bits = bit_array.from_string(streaming.name)
  let descriptor = <<
    0x08074b50:little-size(32), streaming.crc:little-size(32),
    streaming.size:little-size(64), streaming.size:little-size(64),
  >>
  let header_size = 30 + bit_array.byte_size(name_bits) + 20
  let entry =
    Entry(
      name: streaming.name,
      size: streaming.size,
      crc: streaming.crc,
      offset: streaming.offset,
      flags: utf8_flag + descriptor_flag,
    )
  #(
    Writer(
      offset: streaming.offset + header_size + streaming.size + bit_array.byte_size(descriptor),
      entries: [entry, ..writer.entries],
    ),
    descriptor,
  )
}

/// Central directory plus ZIP64 end records.
pub fn finish(writer: Writer) -> BitArray {
  let entries = list.reverse(writer.entries)
  let directory =
    entries
    |> list.map(fn(entry) {
      let name_bits = bit_array.from_string(entry.name)
      <<
        0x02014b50:little-size(32), version:little-size(16),
        version:little-size(16), entry.flags:little-size(16), 0:little-size(16),
        dos_time:little-size(16), dos_date:little-size(16),
        entry.crc:little-size(32), 0xFFFFFFFF:little-size(32),
        0xFFFFFFFF:little-size(32),
        bit_array.byte_size(name_bits):little-size(16), 28:little-size(16),
        0:little-size(16), 0:little-size(16), 0:little-size(16),
        0:little-size(32), 0xFFFFFFFF:little-size(32), name_bits:bits,
        0x0001:little-size(16), 24:little-size(16), entry.size:little-size(64),
        entry.size:little-size(64), entry.offset:little-size(64),
      >>
    })
    |> bit_array.concat
  let count = list.length(entries)
  let directory_size = bit_array.byte_size(directory)
  let zip64_end_offset = writer.offset + directory_size
  <<
    directory:bits,
    // ZIP64 end of central directory record.
    0x06064b50:little-size(32), 44:little-size(64), version:little-size(16),
    version:little-size(16), 0:little-size(32), 0:little-size(32),
    count:little-size(64), count:little-size(64), directory_size:little-size(64),
    writer.offset:little-size(64),
    // ZIP64 end of central directory locator.
    0x07064b50:little-size(32), 0:little-size(32),
    zip64_end_offset:little-size(64), 1:little-size(32),
    // Classic end record pointing at the ZIP64 values.
    0x06054b50:little-size(32), 0:little-size(16), 0:little-size(16),
    0xFFFF:little-size(16), 0xFFFF:little-size(16), 0xFFFFFFFF:little-size(32),
    0xFFFFFFFF:little-size(32), 0:little-size(16),
  >>
}
