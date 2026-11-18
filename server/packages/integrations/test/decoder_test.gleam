//// Decoder adapter tests. They run only inside Linux with the sandbox
//// artifacts present (see native/decoder/Dockerfile, target adapter-test);
//// elsewhere they are skipped. LIBARRIE_DECODER_TIER selects `minijail` or
//// `unprivileged`.

import envoy
import gleam/bit_array
import gleam/string
import libarrie/integrations/decoder
import simplifile

fn config(bin_dir: String) -> Result(decoder.Config, Nil) {
  case envoy.get("LIBARRIE_DECODER_BIN"), envoy.get("LIBARRIE_DECODER_TIER") {
    Ok(_), Ok(tier) -> {
      let policy = "/opt/libarrie/policy/decoder.policy"
      let sandbox = case tier {
        "unprivileged" -> decoder.Unprivileged(policy:)
        _ ->
          decoder.Minijail(
            minijail: "/opt/libarrie/bin/minijail0",
            root: "/opt/libarrie/sandbox-root",
            policy:,
          )
      }
      Ok(
        decoder.Config(
          ..decoder.default_config(bin_dir, sandbox, "/tmp/scratch"),
          cpu_seconds: 2,
          wall_seconds: 3,
        ),
      )
    }
    _, _ -> Error(Nil)
  }
}

fn fixture(name: String) -> BitArray {
  let assert Ok(dir) = envoy.get("LIBARRIE_DECODER_FIXTURES")
  let assert Ok(bytes) = simplifile.read_bits(dir <> "/" <> name)
  bytes
}

pub fn decoder_validates_and_resizes_test() {
  case config("/opt/libarrie/bin") {
    Error(_) -> Nil
    Ok(config) -> {
      let assert Ok(decoder.Info("jpeg", 1200, 900)) = decoder.validate(config, fixture("photo.jpg"))
      let assert Ok(thumb) = decoder.resize(config, fixture("photo.jpg"), 256, 80)
      let assert <<0xFF, 0xD8, _:bits>> = thumb
      let assert True = bit_array.byte_size(thumb) < 20_000
      let assert Error(decoder.Unsupported("corrupt_or_unsupported")) =
        decoder.validate(config, fixture("truncated.jpg"))
      let assert Error(decoder.Unsupported("corrupt_or_unsupported")) =
        decoder.validate(config, <<"not an image":utf8>>)
      let assert Error(decoder.Unsupported("limits_exceeded")) =
        decoder.validate(decoder.Config(..config, max_pixels: 1000), fixture("photo.jpg"))
      // Scratch directories are removed after each run.
      let assert Ok([]) = simplifile.read_directory("/tmp/scratch")
      Nil
    }
  }
}

/// Scenario 35: a decoder-crashing image kills only the subprocess; the
/// worker observes a user-actionable unsupported image.
pub fn decoder_crash_is_contained_test() {
  case config("/test/crashbin") {
    Error(_) -> Nil
    Ok(config) -> {
      let assert Error(decoder.Unsupported(reason)) = decoder.validate(config, fixture("photo.jpg"))
      let assert True = reason == "decoder_killed:SIGSEGV"
      Nil
    }
  }
}

pub fn decoder_cpu_limit_is_enforced_test() {
  case config("/test/spinbin") {
    Error(_) -> Nil
    Ok(config) -> {
      let assert Error(decoder.Unsupported(reason)) = decoder.validate(config, fixture("photo.jpg"))
      let assert True = string.starts_with(reason, "decoder_killed:")
      Nil
    }
  }
}

pub fn exit_status_classification_test() {
  let assert decoder.Unsupported("decoder_killed:SIGALRM") = decoder.classify(142, <<>>)
  let assert decoder.Unsupported("decoder_killed:seccomp") = decoder.classify(253, <<>>)
  let assert decoder.Unavailable(_) = decoder.classify(1, <<"minijail: setup failed":utf8>>)
  let assert decoder.Unavailable(_) = decoder.classify(4, <<>>)
}
