# ADR 0003: Mistral OCR, Voyage embeddings, decoder sandbox and R2 journal

Status: accepted
Date: 2026-10-13

## Decisions

### Model providers

- **OCR:** Mistral, pinned to `mistral-ocr-4-1` (OCR 4.1, generally
  available 2026-08-31; `mistral-ocr-4-0` retired 2026-09-30).
- **Embeddings:** Voyage, pinned to `voyage-4-large`, default 1,024
  dimensions (256, 512 and 2,048 are allowed).
- **Explicit versions only:** `-latest` aliases are refused at startup.
  Changing the embedding model creates a new search configuration;
  `libarrie_api reindex` runs the section 19 interim migration.
  - Each account gets a new release that keeps lexical results for
    not-yet-reindexed pages.
  - Search reports `index_migration_pending`, and unmigrated accounts search
    `lexical_only`.
  - Reindexing is uncharged.
  - The old release is marked `rollback_unavailable`.
- **Mistral classification:** Mistral returns no blank-page determination,
  so:
  - empty text is `no_text_detected`, never `blank_confirmed`;
  - average page confidence below `MISTRAL_MIN_CONFIDENCE` (0.5) is
    `unreadable`;
  - image-only pages are `unsupported_content`;
  - 401/403 are `Misconfigured` (the circuit opens instead of exhausting
    user jobs);
  - 408/429/5xx are transient;
  - 400/413/415/422 mean the image was refused.
  - Block bounding boxes are normalized to 0..1 and stored with the OCR
    result; none are invented.
- **Voyage requests:**
  - `input_type` is `document` or `query`, and `truncation: false` so
    oversized input fails loudly.
  - Requests are split to stay under 1,000 inputs and the token limit,
    results are reordered by index, and dimensions are validated.
  - The cost estimate is one token per character at
    `VOYAGE_PRICE_MICROS_PER_MTOK` (default $0.12 per million). That figure
    comes from third-party price listings; confirm it against your contract.
  - OCR is estimated at `SPEND_OCR_COST_MICROS` (6,000 = $0.006, a ceiling
    over the listed $4 per 1,000 pages).
- **Hosted gates:** hosted mode refuses mock providers, requires
  `MISTRAL_TERMS_RECORD` and `VOYAGE_TERMS_RECORD` (a reference to the
  recorded no-training, retention, DPA and region terms), requires an
  explicit `SPEND_ACCOUNT_DAILY_MICROS`, and refuses to start if it is below
  `LARGEST_MONTHLY_PROCESSING_ALLOWANCE` × per-page cost × 1.5.
- **No real calls yet:** no real API calls were made. The adapters are
  verified against in-test fake servers implementing the documented request
  and response shapes, including error statuses and malformed bodies. A live
  evaluation needs your keys and the consented evaluation set.

### Decoder sandbox

- **Toolchain:** `native/decoder` builds `decoder`, `launcher` and
  `minijail0` as static musl binaries with clang, lld and compiler-rt. The
  build fails on any GCC runtime symbol or dynamic linkage. Licenses are in
  `server/native/decoder/LICENSES.md`, including the recorded BSD election
  for libcap.
- **Two tiers, both verified in Colima on Linux 6.8 (aarch64):**
  - `minijail`: 19 sandbox checks, plus the full server suite with real
    decoding;
  - `unprivileged` (Landlock, seccomp, rlimits; non-root, default container
    profile): 12 checks, plus the full server suite.
- **Findings that shaped the implementation:**
  - minijail's `-p` remounts `/proc`, so the empty sandbox root gets a fresh
    read-only procfs (`-k proc,/proc,proc,MS_RDONLY`).
  - `-I` would make the decoder PID 1, and PID 1 ignores default-action
    signals such as SIGALRM, which would defeat the wall clock.
  - With static binaries, minijail installs seccomp before its init forks,
    so the policy admits init's `clone` (fork flags only), `wait4`,
    `prctl`, `rt_sigaction`, `kill` and `getpid`. Process creation by the
    decoder is still blocked by `RLIMIT_NPROC=0`.
  - minijail's init reports every signal death as exit 254, so the launcher
    forks once and reports `128 + signal` itself. This keeps crash (SIGSEGV),
    CPU limit (SIGKILL), wall clock (SIGALRM) and seccomp (SIGSYS)
    distinguishable.
  - libjpeg-turbo treats truncated data as a warning; the decoder treats it
    as corrupt.
  - Unprivileged user namespaces are blocked on Ubuntu 24.04 hosts
    (`apparmor_restrict_unprivileged_userns`), hence the unprivileged tier.
    The Colima VM's kernel settings were not changed.
- **Interop:** `libarrie_decoder_ffi.erl` opens the launcher with
  `spawn_executable` only. Packages considered:
  - `child_process`: its kill and stop use `os:cmd("kill …")`, and it cannot
    half-close stdin;
  - `shellout`: no binary stdin;
  - `glexec`: wraps erlexec's C++ port, built with libstdc++.

  Input and output go through a private per-run scratch directory, and all
  limits are kernel-enforced, so nothing is ever signalled from the BEAM.
- **Where decoding happens:**
  - Upload completion fully decodes the frozen copy in the sandbox. Refusal
    is `unsupported_image`; a sandbox outage is retryable.
  - A `derive` job produces a 320 px thumbnail and a 1,600 px preview, with
    orientation applied and no metadata, at no charge.
  - These are served from same-origin `/img/{source_object_id}/thumb` and
    `/img/{source_object_id}/preview`, authorized per request with
    `private, max-age=86400` and no redirect.
- **x86_64 seccomp policy:** ported from the verified arm64 set; verified by CI on push (ADR 0008).

### R2

- **Primary store:** R2 does not verify `x-amz-checksum-sha256` on
  PutObject or UploadPart; it verifies `Content-MD5`. With
  `S3_UPLOAD_INTEGRITY=md5`, presigned uploads bind a signed `Content-MD5`,
  so the store itself rejects mismatched bodies. Clients send
  `checksum_md5`; SHA-256 remains the API's own verification of the frozen
  copy.
- **Journal store:** `JOURNAL_S3_*` configures a separate store; hosted mode
  requires a different bucket and credentials. Events are written
  write-once (`If-None-Match: *`) under sequence-ordered keys
  `journal/v1/<seq>-<command>.json`, and a pre-existing object counts as
  delivered only if it is byte-identical. Overwrite and delete protection
  comes from an R2 bucket lock rule on `journal/`, because R2 does not
  support S3 Object Lock headers.
- **`storage-check`:** verifies both stores with the operator's own keys.
- **`journal-replay`:** recovers from a restored database (coverage check,
  ordered idempotent replay, usage reconciliation). It refuses on journal
  unavailability or gaps.

## Remaining for launch

- **Your actions:**
  - Run `storage-check` against R2 with the real credentials.
  - Configure the bucket lock and tokens per
    `docs/runbooks/r2-storage-and-journal.md`.
  - Record the Mistral and Voyage privacy terms, and run the live evaluation
    with your keys.
  - Choose the worker sandbox tier your platform supports.
- **Verification:** confirm the decoder-x86_64 workflow passes.
- **Clients:** native and web clients must send `checksum_md5` when the
  deployment uses R2.
