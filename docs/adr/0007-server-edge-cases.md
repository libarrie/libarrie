# ADR 0007: Credit revocation, provisional renewals, large-account batching and archive pruning

Status: accepted

These close the server gaps listed in ADRs 0001 and 0002.

## Credit revoke-on-release (section 10)

Before this change, revoking a grant removed only its unreserved units. A
unit that was reserved at the time returned to the spendable balance when
its work released it.

- **Revoked marker:** `credit_grants.revoked_at` records the revocation.
  `release_processing` moves a released unit on a revoked grant to
  `revoked`.
- **Accounting:** `reserved + consumed + revoked <= granted` still holds at
  every step.
- **Coverage records:** revocation is now explicit there too, through
  `processing_coverage.revoked_at`. Previously a shortened admission interval
  was the only signal of revocation, and that would wrongly revoke units on a
  provisional record that merely reached its grace end.

## Provisional renewal coverage (section 10)

`renewal_policy` accepts `bounded_outage` (see
`contracts/entitlements/README.md`).

- **When:** processing admission calls `renewal.provision` under the account
  and usage locks, so a boundary takes effect the moment it passes.
- **What:** it issues one provisional base record per outage window:
  - a deterministic UUIDv5 ID;
  - an interval from `authorized_through` to the next clamped anniversary;
  - admission ending at the grace end (at most seven days).
- **Authority recovery:** the entitlement authority confirms the record (same ID, interval and
  budget), which reopens admission, or rejects it with
  `provisional_rejected`.
- **Exposure:** `entitlement-status` reports provisional records and their
  exposure.
- **Timestamp precision:** issued-record comparison now uses Postgres's
  microsecond precision (rounded). Before, a delivered timestamp with
  nanoseconds made an unchanged record look changed, an intermittent false
  `coverage_conflict`.

There is no background job: provisioning happens at admission. Until then,
usage shows no upcoming record, which is acceptable because nothing can
spend it before admission.

## Large accounts

- **Account purge:**
  - **Batches:** it first deletes the large tables in batches of 2,000 rows
    per transaction: passages (embeddings cascade from them), search release
    pages, usage events, content changes and idempotency records. It also
    queues storage objects for deletion in batches.
  - **Rescheduling:** each batch returns `Continue`, which reschedules the
    job immediately without spending an attempt.
  - **Final step:** the identity ledger, the remaining rows and the status
    change to `closed` happen in one final transaction. Its size is bounded
    by pages and revisions, not by passages.
  - **Safety:** the account is already closed to every request, so partial
    erasure is never visible, and a crash resumes where it stopped.
- **Export parts:**
  - **Memory:** a part loads only its own items.
  - **Manifest:** `manifest.json` is a small header (`manifest_version` 2,
    `item_count`, `index`).
  - **Index:** the full index is `index.jsonl`, one JSON object per page in
    order. It is streamed from the database 1,000 rows at a time as a ZIP
    entry with a ZIP64 data descriptor.
  - **Size:** a part's memory no longer grows with the size of the library.
  - **Checking:** the ZIP writer gained `begin`, `chunk` and `end`, and a
    test reads the output back with OTP's own `zip` module.

## Job archive pruning

The hourly prune deletes `jobs_archive` rows, and their attempts, older than
`JOBS_ARCHIVE_RETENTION_DAYS` (default 30). It runs in batches of 2,000, at
most 40,000 per run.

Periodic-job deduplication uses the archive only for the current time
bucket, so pruning old rows never re-enables a duplicate.

## Tests

- **Credits:** revoke-on-release through cancellation, refusal of new work,
  and idempotent revocation.
- **Renewals:**
  - provisioning, reuse of the deterministic ID, and the grace cutoff;
  - a refused budget change, then confirmation reopening admission;
  - rejection with exposure;
  - nothing provisioned past grace or for a closing account;
  - invalid policies.
- **Anniversaries:** January 31 clamps to February 28 and back to March 31,
  and February 29 in a leap year.
- **ZIP:** a streamed entry round-trips through OTP's `zip`.
- **Archive pruning:** old archived jobs are deleted with their attempts.
