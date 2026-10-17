# ADR 0002: Purge, exports, account closure, spend controls and maintenance jobs

Status: accepted
Date: 2026-10-12

## Context

ADR 0001 left several design areas unimplemented. This change adds:
- permanent purge and trash expiry;
- exports;
- durable account closure;
- provider spend controls, permits and rate limits;
- maintenance as leased jobs, with job archiving;
- search highlights;
- a lock-order harness.

The schema for these lives in `database/migrations/0001_baseline.sql` (see ADR 0001).

## Decisions

### Purge waits for the journal

Purge requests set `purge_requested_at`, hide the targets, invalidate
exports that pin affected artifacts and journal the intent (202
`recovery_pending`). Physical erasure runs only after the journal shipper
acknowledges the event; the deletion is idempotent and leaves
`deletion_tombstones`. Storage objects are queued in
`pending_object_deletions` inside the erasing transaction and removed by a
maintenance task, so a crash never leaks or prematurely deletes bytes. Trash
older than the retention window (30 days) is purged the same way by the
`trash_expiry` task.

### Exports

- **Admission:** a single `INSERT … SELECT` snapshots `export_items`, and
  artifact pins are written in the same transaction. Pages are packed
  greedily into parts of at most `EXPORT_PART_BYTES` (2 GB default); a page
  is never split, and an oversized page gets its own part.
- **Assembly:** one leased job per part, with a one-hour stage deadline.
  Each part streams a ZIP64 archive (stored entries, UTF-8 names, ZIP64
  records always present) through an 8 MiB buffer into an S3 multipart
  upload, so memory stays bounded per part. Every part carries the full
  `manifest.json`; transcripts appear only in the part holding their image.
  Each image's checksum is verified; a missing or mismatched artifact fails
  the export with `missing_artifact` or `artifact_checksum_mismatch`.
- **Completion:** a finalize job checks every part with HEAD, then sets one
  `completed_at`, sets `expires_at = completed_at + 7 days` and releases the
  source pins. Download URL issuance never touches retention.

### Account closure

- **Transitions:** each one increments `lifecycle_revision` and writes one
  full desired-state command to the `journal` destination, and to a
  lifecycle subscriber when one is configured (ADR 0009),
  under the same command ID. The primary key of `lifecycle_outbox` is now
  `(command_id, destination)`.
- **Deadline job:** keyed by revision, so stale jobs are no-ops. Assembling
  exports extend the deadline within the 30-day cap rather than being
  cancelled. Export admission during grace extends the deadline, or is
  refused with `export_exceeds_closure_window`.
- **Cancellation:** keeps grace restrictions until the journal acknowledges
  the higher active revision.
- **Purge:** runs only after the `closing` command is durable. It records the
  HMAC identity ledger under every retained key (keeping the highest
  consumed value), erases tenant data, deletes identity mappings and blanks
  the display name. It keeps the account row, closure intents, lifecycle
  commands and tombstones for subscriber reconciliation.
- **After purge:** a sign-in by the same identity gets a status-only answer.
  `POST /v1/accounts` explicitly creates a new account that inherits the
  prior lifetime usage.
- **Subscriber delivery:** when `LIFECYCLE_SUBSCRIBER_URL` and
  `LIFECYCLE_SUBSCRIBER_TOKEN` are set, the worker sends commands with
  `PUT {LIFECYCLE_SUBSCRIBER_URL}/accounts/{id}/lifecycle`. Without a
  subscriber, no subscriber destination is recorded.

### Spend controls, permits and circuits

- **Budgets:** every model request (OCR, document and query embeddings)
  first reserves its estimated cost against daily `spend_windows` for the
  deployment and the account, all-or-nothing, and is recorded in
  `provider_spend`. Unknown outcomes stay charged at the estimate.
- **Budget exhaustion:** the job is postponed without spending an attempt
  (`jobs.postpone`) and the operation records `paused_since`. After
  `SPEND_MAX_PAUSE_HOURS` (36) it fails with a system fault into a recovery
  hold. Search falls back to `lexical_only`.
- **Permits:** `provider_permits` slots with expiring holders bound
  concurrency across replicas.
- **Circuits:** `provider_circuits` opens after sustained errors, and for
  ten times longer on invalid credentials, instead of exhausting user jobs.
- **Production values:** spend budgets and costs are configuration;
  production needs reviewed values.

### Rate limits

- **Per-account requests** (1200/min) and **searches** (60/min) use
  Postgres fixed-window counters (`rate_limit_counters`), so limits hold
  across replicas.
- **Corrections** (60 per page per hour) and **rescans** (3 per page per
  rolling 24 h) are counted from their own records.
- Responses are 429 `rate_limited` with `Retry-After`.

### Maintenance as leased jobs

- **Scheduling:** every worker's scheduler calls
  `jobs.enqueue_periodic(stage, bucket)`, which inserts a `maint:<task>` job
  only if no job (live, terminal or archived) has that bucket's dedupe key,
  so each bucket runs once across replicas.
- **Tasks:** journal shipping, lifecycle subscriber delivery, object deletions, upload
  and hold sweeps, slot reconciliation, export and trash expiry, job
  archiving (`jobs_archive`, `job_attempts_archive`) and pruning (rate-limit
  windows, ledger entries after two years, expired tombstones).

### Lock-order harness

`concurrent_paths_do_not_deadlock_test` runs renumbering, uploads, trash,
corrections, worker drains, exports, maintenance and entitlement updates
concurrently on one account. It asserts that Postgres's
`pg_stat_database.deadlocks` counter does not change and that no 5xx other
than retryable 503 occurs.

### Interop added

- `erlang:crc32/2` (BIF) for ZIP CRC-32: no Gleam package provides CRC-32,
  and a pure-Gleam loop is too slow for 20 MB images. Covered by the
  standard check value test (`crc32("123456789") = 0xCBF43926`) and by
  Python `zipfile`/`unzip -t` validation of a real export.

## Consequences and remaining limits

- **Account purge** now deletes large tables in bounded batches (ADR 0007).
- **Export manifests** are now streamed as `index.jsonl` (ADR 0007).
- **Job archiving** prunes the archive after a retention period (ADR 0007).
- **Spend estimates** for the mock providers are placeholders.
