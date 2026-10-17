# ADR 0010: Release images without GPL-family software

Status: accepted

`server/release/` builds the API and worker release images required by
DESIGN.md section 3. `server/Dockerfile` stays the development and test
image, built on the upstream Gleam image.

## Runtime

- **Erlang/OTP 29.1.1 built from source** (`build-otp.sh`): pinned SHA-256,
  on Alpine 3.24, with clang 22, lld, libc++, compiler-rt and LLVM libunwind
  against musl. Neither the runtime nor its JIT links libstdc++ or libgcc_s.
  The script fails on any GCC runtime dependency or GNU symbol-version
  requirement. The upstream Gleam image links both, which is why the
  release cannot reuse it.
- **Findings:**
  - There is no binutils, so the LLVM tools stand in for `ld`, `ar`,
    `ranlib`, `nm` and `strings`. The toolchain flags live in `CC`/`CXX`
    themselves, because OTP's configure probes `-Wl,-export-dynamic` without
    `LDFLAGS`. A failed probe silently dropped the flag, after which NIFs
    (crypto) could not resolve `enif_*`.
  - Only the applications the programs need are built and staged: kernel,
    stdlib, compiler, crypto, public_key, asn1, ssl, inets and sasl. There is
    no terminal library, wx, ODBC, Java or SSH.
- **Compatibility:** beams are compiled in the Gleam image, whose OTP
  version must equal the release OTP; the build checks this.

## Image layout

- **Base:** `scratch` plus exactly what the programs need (`stage.py`):
  - the pruned OTP tree;
  - the two Gleam shipments, without `entrypoint.sh`/`.ps1`;
  - the static decoder sandbox;
  - web assets and migrations;
  - the shared libraries the binaries need, resolved transitively;
  - CA certificates.
- **No shell:**
  - Programs start by exec'ing `erlexec` (`/app/bin/erlexec`) with a
    generated `-args_file` holding the code path, plus `-eval` for the main
    function. `ROOTDIR`, `BINDIR`, `EMU` and `PROGNAME` are image
    environment variables.
  - Name resolution uses OTP's own DNS client (`ERL_INETRC=/etc/inetrc`,
    `{lookup, [file, dns]}`), because the native resolver port is started
    through `/bin/sh -c`.
  - No dependency calls `os:cmd` or `open_port({spawn, …})`; the decoder
    uses `spawn_executable`.
- **Size:** 78.7 MB per image, against 209 MB for the development image.
- **Commands:**
  - API: `docker run libarrie-api [serve|migrate|reindex|…]`.
  - Worker: `docker run libarrie-worker [once]`.
  - Debugging uses an ephemeral debug container, not a shell in the image.

## SBOM and license gate

- **Attribution:** `sbom.py` attributes every file in the root filesystem to
  a component and writes a CycloneDX 1.5 SBOM (`/app/sbom.cdx.json`; the
  `sbom` target exports it). Components come from:
  - OTP, plus the third-party code it vendors into the runtime (from OTP's
    own `vendor.info` files);
  - Alpine packages, for every copied library and the CA bundle;
  - each Gleam/Hex package's declared license, including first-party
    packages. Those are path dependencies, so the build reads them from
    their own `gleam.toml`; the project's own code is Apache-2.0, and a
    first-party package declaring nothing fails the gate rather than being
    assumed Apache-2.0;
  - the decoder's license table;
  - htmx.
- **Failure conditions:**
  - an unattributed file;
  - an unknown license;
  - a GCC runtime library;
  - any GPL-family license (including `WITH` exceptions), unless the
    component is dual-licensed and `license-elections.tsv` records a non-GPL
    alternative.
- **Recorded elections:**
  - zstd (vendored in the Erlang runtime): BSD-3-Clause;
  - libcap (in the decoder launcher): BSD-3-Clause.

## Checks

- **Smoke test:** `smoke.sh` boots each program from the staged root with
  `chroot`. It checks:
  - the JIT;
  - application start;
  - the TLS trust store;
  - the OTP resolver;
  - starting the decoder.

  The API must also reach its command-line handling. The chroot gets
  temporary `/dev` nodes, which a real container gets from its runtime.
- **Verified locally:**
  - `migrate` from the image against Postgres;
  - DNS and certificate-verified TLS from a running container.
- **CI:** `.github/workflows/release-images.yml` builds both images and the
  SBOM on amd64 and arm64, rejects shells and GCC runtimes in the exported
  filesystems, runs `migrate`, and keeps the SBOMs as artifacts.

## Still open

- **Native app binaries:** the iOS and Android apps need their own SBOM
  step.
- **Web bundle:** no separate SBOM yet; the release image's SBOM covers the
  shipped assets.
- **Debug image:** a documented debug-container recipe for operators.
