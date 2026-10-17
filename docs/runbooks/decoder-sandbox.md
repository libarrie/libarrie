# Runbook: image decoder sandbox

All server image decoding (upload validation, thumbnails, previews) runs in
`/opt/libarrie/bin/decoder`, a static musl binary (libjpeg-turbo, libpng,
zlib; clang + compiler-rt, no GCC runtime), launched only through
`launcher` and never inside the BEAM.

## Build

```sh
cd server
docker build -f native/decoder/Dockerfile --target artifact -t libarrie-decoder .
```

The `artifact` stage is a `scratch` layer containing:
- `/opt/libarrie/bin/{decoder,launcher,minijail0}`;
- `/opt/libarrie/policy/decoder.policy`, the seccomp allowlist for the build
  architecture;
- `/opt/libarrie/sandbox-root/`.

Copy it into the API and worker runtime images. The build fails if any
binary is dynamically linked or contains GCC runtime symbols.

## Choose a tier

| `DECODER_SANDBOX` | Requirements | Isolation |
| --- | --- | --- |
| `minijail` | Worker container may create namespaces (root in the container with `CAP_SYS_ADMIN`, or a Kubernetes pod user namespace via `hostUsers: false`) | New mount/pid/net/ipc/uts/cgroup namespaces, pivot_root into an empty root with read-only binaries and one writable scratch dir, uid nobody, no capabilities, no_new_privs, seccomp, rlimits, wall-clock alarm |
| `unprivileged` | Linux 5.13+ with Landlock enabled; runs as any non-root user under the default container profile | Landlock (scratch dir and decoder binary only), seccomp (no sockets), no_new_privs, rlimits (CPU, memory, file size, no new processes), wall-clock alarm. No pid/net/mount namespaces. |
| `none` | Development only (for example macOS) | Header inspection only; refused in hosted mode |

Unprivileged user namespaces are disabled on many hosts (for example
Ubuntu 24.04's `kernel.apparmor_restrict_unprivileged_userns=1`), which is
why a non-root worker needs either the `unprivileged` tier or a
platform-provided user namespace for `minijail`.

Other settings: `DECODER_BIN_DIR`, `DECODER_POLICY`, `DECODER_ROOT`,
`DECODER_SCRATCH_DIR` (private to the worker user), `DECODER_CPU_SECONDS`
(20), `DECODER_WALL_SECONDS` (30) and `DECODER_MEMORY_BYTES` (1 GiB).

## Outcomes

| Decoder result | API/worker outcome |
| --- | --- |
| exit 0 | accepted / derived images stored |
| exit 2 (corrupt or unsupported) or 3 (limits) | `unsupported_image` (user-actionable) |
| killed by SIGSEGV, SIGKILL (CPU), SIGALRM (wall clock), SIGSYS (seccomp) | `unsupported_image`, never a transient retry; only the subprocess dies |
| sandbox setup failure (exit 1 or 4) | retryable system error (`unavailable`) |

## Verify

```sh
cd server
docker build -f native/decoder/Dockerfile --target test -t libarrie-decoder-test .
docker run --rm --privileged libarrie-decoder-test           # minijail tier: 19 checks
docker run --rm --user 1000:1000 libarrie-decoder-test       # unprivileged tier: 12 checks
TIER=minijail ./scripts/test-linux.sh                        # full server suite on Linux
TIER=unprivileged ./scripts/test-linux.sh
```

The seccomp policy was derived and verified on aarch64. The x86_64 policy
(`decoder.x86_64.policy`) is a best-effort equivalent; verify it on x86_64
hosts (with `minijail0 -L` and the test image) before relying on it.
