//// Sandboxed image decoding (DESIGN.md section 7).
////
//// All server image decoding (full validation, thumbnails and previews)
//// runs in a separate OS process under OS-level limits, never in the BEAM.
//// Two tiers:
////
//// - `Minijail`: new user-visible namespaces (mount, pid, net, ipc, uts,
////   cgroup), pivot_root into an empty root with read-only binaries and one
////   writable scratch directory, uid/gid nobody, no capabilities,
////   no_new_privs and a seccomp allowlist. Requires a worker allowed to
////   create namespaces (root in the container with CAP_SYS_ADMIN, or a pod
////   user namespace).
//// - `Unprivileged`: for workers that cannot create namespaces. Landlock
////   confines filesystem access to the scratch directory and the decoder
////   binary; seccomp, no_new_privs and rlimits still apply. Weaker (no pid,
////   network or mount isolation; seccomp blocks sockets) and documented as
////   such.
////
//// In both tiers the launcher enforces CPU, address-space, output-size,
//// file-descriptor and process limits plus a kernel wall-clock alarm. A
//// decoder crash or limit breach is a user-actionable `Unsupported`
//// outcome, never a transient retry; only sandbox setup failures are
//// `Unavailable`.

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import simplifile

pub type Sandbox {
  Minijail(minijail: String, root: String, policy: String)
  Unprivileged(policy: String)
}

pub type Config {
  Config(
    /// Directory holding `decoder` and `launcher`.
    bin_dir: String,
    sandbox: Sandbox,
    /// Private directory for per-run scratch subdirectories.
    scratch_root: String,
    cpu_seconds: Int,
    memory_bytes: Int,
    wall_seconds: Int,
    output_bytes: Int,
    max_pixels: Int,
  )
}

pub fn default_config(bin_dir: String, sandbox: Sandbox, scratch_root: String) -> Config {
  Config(
    bin_dir:,
    sandbox:,
    scratch_root:,
    cpu_seconds: 20,
    memory_bytes: 1_073_741_824,
    wall_seconds: 30,
    output_bytes: 33_554_432,
    max_pixels: 80_000_000,
  )
}

pub type DecodeError {
  /// The image (or its decode) was refused: corrupt, unsupported, over a
  /// limit, crashed or timed out. User-actionable `unsupported_image`.
  Unsupported(reason: String)
  /// The sandbox itself could not run (configuration or host problem).
  Unavailable(reason: String)
}

pub type Info {
  Info(format: String, width: Int, height: Int)
}

type PortResult {
  Exited(status: Int, output: BitArray)
  TimedOut(output: BitArray)
  LaunchFailed(reason: String)
}

@external(erlang, "libarrie_decoder_ffi", "run")
fn run_port(executable: String, args: List(String), timeout_ms: Int) -> PortResult

/// Fully decode the image and report its format and dimensions.
pub fn validate(config: Config, bytes: BitArray) -> Result(Info, DecodeError) {
  use output <- result.try(
    run(config, bytes, fn(input, out) {
      ["validate", input, out, int.to_string(config.max_pixels)]
    }),
  )
  let decoder = {
    use format <- decode.field("format", decode.string)
    use width <- decode.field("width", decode.int)
    use height <- decode.field("height", decode.int)
    decode.success(Info(format:, width:, height:))
  }
  use text <- result.try(
    bit_array.to_string(output) |> result.replace_error(Unavailable("invalid decoder output")),
  )
  json.parse(text, decoder) |> result.replace_error(Unavailable("invalid decoder output"))
}

/// Decode, apply EXIF orientation and downsize to fit `max_dimension`,
/// returning a metadata-free JPEG.
pub fn resize(
  config: Config,
  bytes: BitArray,
  max_dimension: Int,
  quality: Int,
) -> Result(BitArray, DecodeError) {
  run(config, bytes, fn(input, out) {
    [
      "resize", input, out, int.to_string(config.max_pixels),
      int.to_string(max_dimension), int.to_string(quality),
    ]
  })
}

fn run(
  config: Config,
  bytes: BitArray,
  arguments: fn(String, String) -> List(String),
) -> Result(BitArray, DecodeError) {
  let name =
    crypto.strong_random_bytes(12) |> bit_array.base16_encode |> string.lowercase
  let host_dir = config.scratch_root <> "/" <> name
  use _ <- result.try(
    simplifile.create_directory_all(host_dir)
    |> result.replace_error(Unavailable("cannot create scratch directory")),
  )
  let outcome = run_in(config, bytes, host_dir, arguments)
  let _ = simplifile.delete(host_dir)
  outcome
}

fn run_in(
  config: Config,
  bytes: BitArray,
  host_dir: String,
  arguments: fn(String, String) -> List(String),
) -> Result(BitArray, DecodeError) {
  use _ <- result.try(
    simplifile.write_bits(host_dir <> "/input", bytes)
    |> result.replace_error(Unavailable("cannot write scratch input")),
  )
  let limits = [
    int.to_string(config.cpu_seconds),
    int.to_string(config.memory_bytes),
    int.to_string(config.wall_seconds),
    int.to_string(config.output_bytes),
  ]
  let #(executable, args) = case config.sandbox {
    Minijail(minijail:, root:, policy:) -> {
      // The decoder runs as nobody; only this run's directory is shared.
      let _ = simplifile.set_permissions_octal(host_dir, 0o777)
      let _ = simplifile.set_permissions_octal(host_dir <> "/input", 0o644)
      #(minijail, list.flatten([
        [
          "-T", "static", "-n", "-e", "-l", "-p", "--uts", "-N",
          "-u", "65534", "-g", "65534", "-c", "0", "--ambient",
          "-P", root, "-k", "proc,/proc,proc,0x1",
          "-b", config.bin_dir <> ",/bin,0", "-b", host_dir <> ",/work,1",
          "-S", policy, "--env-reset", "--", "/bin/launcher",
        ],
        limits,
        ["--", "/bin/decoder", ..arguments("/work/input", "/work/output")],
      ]))
    }
    Unprivileged(policy:) -> #(
      config.bin_dir <> "/launcher",
      list.flatten([
        [
          "--require-landlock", "--seccomp", policy,
          "--landlock-ro", config.bin_dir <> "/decoder", "--landlock-rw", host_dir,
        ],
        limits,
        [
          "--",
          config.bin_dir <> "/decoder",
          ..arguments(host_dir <> "/input", host_dir <> "/output")
        ],
      ]),
    )
  }
  // Grace beyond the kernel wall clock for process teardown.
  let timeout_ms = { config.wall_seconds + 5 } * 1000
  case run_port(executable, args, timeout_ms) {
    LaunchFailed(reason) -> Error(Unavailable("decoder launch failed: " <> reason))
    TimedOut(_) -> Error(Unsupported("decode_timeout"))
    Exited(0, _) ->
      simplifile.read_bits(host_dir <> "/output")
      |> result.replace_error(Unavailable("decoder produced no output"))
    Exited(status, output) -> Error(classify(status, output))
  }
}

/// Map launcher/decoder exit statuses to outcomes. Public for tests.
pub fn classify(status: Int, output: BitArray) -> DecodeError {
  let detail = bit_array.to_string(output) |> result.unwrap("") |> string.trim
  case status {
    2 -> Unsupported("corrupt_or_unsupported")
    3 -> Unsupported("limits_exceeded")
    // minijail: seccomp violation in the decoder.
    253 -> Unsupported("decoder_killed:seccomp")
    s if s > 128 && s < 160 -> Unsupported("decoder_killed:" <> signal_name(s - 128))
    // 1 (minijail setup), 4 (launcher/decoder I/O or usage) and anything
    // else point at the sandbox or host, not the image.
    s -> Unavailable("decoder exit " <> int.to_string(s) <> ": " <> string.slice(detail, 0, 200))
  }
}

fn signal_name(signal: Int) -> String {
  case signal {
    6 -> "SIGABRT"
    9 -> "SIGKILL"
    11 -> "SIGSEGV"
    14 -> "SIGALRM"
    24 -> "SIGXCPU"
    25 -> "SIGXFSZ"
    31 -> "SIGSYS"
    n -> "signal_" <> int.to_string(n)
  }
}

