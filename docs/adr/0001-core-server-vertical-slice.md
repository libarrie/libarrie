# ADR 0001: Core server vertical slice, interop and interim deviations

Status: accepted for the vertical slice (milestones 1–2)
Date: 2026-10-12

## Context

DESIGN.md (v1.10, frozen) describes the full core server. This first
implementation delivers the foundation and vertical slice for work packages
A–E. It records the decisions the design leaves to implementation, the
Erlang interop it needed, and where interim behavior deviates from the
design.

## Decisions

### Packages and versions

| Package | License | Use |
| --- | --- | --- |
| gleam_stdlib, gleam_erlang, gleam_otp, gleam_json, gleam_http, gleam_crypto, gleam_time, gleam_httpc | Apache-2.0 | Standard library, HTTP client, crypto |
| wisp 2.2, mist 6.0 | Apache-2.0 | HTTP server |
| pog 4.1 (pgo, pg_types) | Apache-2.0 | Postgres client |
| youid 1.6 | Apache-2.0 | UUIDv7 identifiers |
| envoy, argv, simplifile | Apache-2.0 | Configuration, CLI, migration files |

Toolchain: Gleam 1.19, Erlang/OTP 29, PostgreSQL 17 with pgvector. The
development object store is SeaweedFS (Apache-2.0). No GPL-family dependency
was added.

### Erlang interop

1. **RS256 JWT verification** (`server/packages/integrations/src/libarrie_identity_ffi.erl`).
   Packages considered: `gwt` (HS256/384/512 only), `gleam_crypto` (hashes
   and HMAC only, no public-key verification); no maintained Gleam package
   verifies RSA signatures. The boundary is one function wrapping
   `crypto:verify/5`, returns a boolean and never raises. Tested through the
   HS256 path and covered by the identity adapter; RS256 needs a test against
   the selected hosted issuer.
2. **`erlang:halt/1`** in the API and worker CLI entrypoints to exit with a
   status code after `migrate`, `dev-token` and `once`. No Gleam package
   exposes process exit codes.
3. **Test-only `support_ffi.erl`** caches one database pool across
   concurrently running integration tests (`persistent_term` plus
   `global:trans`).

Everything else (SigV4 signing, image header inspection, the job queue, and
process supervision via `gleam_erlang` monitors) uses Gleam packages.

### Driver conventions

`pgo` encodes parameters by inferred type. UUIDs are bound as text and cast
(`$1::uuid`). `vector` and `timestamptz` parameters must be cast through text
(`$1::text::vector`), and functions returning `void` must be selected from
(`select 1 from pg_advisory_xact_lock(...)`). Timestamps are returned
through the SQL function `rfc3339(timestamptz)`.

### Lock order

Every mutation takes the account row lock first (level 1), so within an
account the remaining levels are serialized. Paths still follow the
documented order where they lock explicitly: usage → funding → job slots →
notebooks → pages → revisions → operations → search release → jobs. Worker
claims lock `account_job_slots` before `jobs`. Lazy expiry inside admission
may touch a notebook other than the target after the target's lock; this is
safe under the account lock. The lock-order contention harness (scenario 49)
is described in ADR 0002.

## Schema history

Before the first deployment, the schema's migrations were folded into one
file, `database/migrations/0001_baseline.sql`. A schema dump of that file
is identical to one from the earlier seven-migration chain (checked with
`pg_dump --schema-only`).

From the first deployment on, schema changes are new numbered migrations
and the baseline is never edited. A database created before the squash
must be recreated, for example with `docker compose down -v`.

## Interim deviations and gaps (tracked for the owning work packages)

Items completed later are recorded in ADRs 0002 and 0003. Still open:

- **Search:** per-account cutover and rollback done (ADR 0008).
- **Credit revocation:** done; see ADR 0007.
- **Provisional renewal coverage:** done; see ADR 0007.
- **Web login flow:** done; see ADR 0004.
