# Libarrie core server

Gleam (Erlang/OTP) implementation of the core API and worker described in
`docs/design/DESIGN.md`. Scope, decisions and remaining gaps are recorded in
`docs/adr/0001-core-server-vertical-slice.md`,
`docs/adr/0002-lifecycle-exports-and-controls.md` and
`docs/adr/0003-providers-decoder-sandbox-r2.md`,
`docs/adr/0004-web-ui-foundation.md` and later ADRs (0009 covers the
entitlement-authority boundary and web extensions). Operations runbooks are in
`docs/runbooks/`.

```text
server/
  apps/api/              HTTP API (Wisp/Mist): /v1 JSON, /internal entitlement routes
  apps/worker/           Job runners and maintenance (sweepers, journal shipper)
  packages/database/     pog helpers and the migration runner
  packages/jobs/         Durable Postgres queue: leases, heartbeats, fencing, slots
  packages/integrations/ S3 SigV4 storage, OIDC tokens, image inspection, providers
  packages/domain/       Accounts, quotas, notebooks, pages, uploads, processing, search
  packages/web/          htmx web UI: Gleam HTML views, sessions, OIDC sign-in
database/migrations/     SQL migrations (repository root)
contracts/               OpenAPI and entitlement contract
```

## Local development

Requirements: Gleam 1.19+, Erlang/OTP 27+, Docker.

```sh
# Postgres with pgvector and SeaweedFS (S3); see deploy/docker-compose.yml.
docker run -d --name libarrie-pg -e POSTGRES_USER=libarrie -e POSTGRES_PASSWORD=libarrie \
  -e POSTGRES_DB=libarrie -p 5433:5432 pgvector/pgvector:pg17
docker run -d --name libarrie-s3 -p 8333:8333 -v "$PWD/deploy/dev/s3.json:/etc/seaweedfs/s3.json:ro" \
  chrislusf/seaweedfs:latest server -dir=/data -s3 -s3.port=8333 -s3.config=/etc/seaweedfs/s3.json

export DEV_ISSUER_SECRET=dev-secret INTERNAL_API_TOKEN=internal-dev
cd server/apps/api
gleam run -- migrate                 # one deployment job, not per replica
gleam run -- serve                   # http://localhost:8080
# Web UI: open http://localhost:8080 and sign in through the development issuer.
TOKEN=$(gleam run -- dev-token alice "Alice" | tail -1)
curl -H "Authorization: Bearer $TOKEN" localhost:8080/v1/me

cd ../worker && gleam run            # or `gleam run -- once` to drain once
```

## Configuration

| Variable | Default | Notes |
| --- | --- | --- |
| `LIBARRIE_MODE` | `selfhost` | `hosted` refuses the dev issuer and mock providers |
| `DATABASE_URL` | `postgres://libarrie:libarrie@localhost:5433/libarrie` | |
| `DATABASE_POOL_SIZE` | `10` | Per process; keep the sum within the DB connection budget |
| `PORT` | `8080` | |
| `MIGRATIONS_DIR` | `../../../database/migrations` | |
| `OIDC_ISSUER`, `OIDC_AUDIENCE` | dev issuer, `libarrie` | |
| `OIDC_JWKS_URL` | — | RS256 verification for a real issuer. Fetched at startup and re-fetched when a token names an unknown key ID (key rotation), at most once a minute |
| `DEV_ISSUER_SECRET` | — | Enables the HS256 development issuer (development and tests only). Refused unless `WEB_ORIGIN` is localhost or a private-network IP address |
| `INTERNAL_API_TOKEN` | — | Enables `/internal/v1` for the entitlement authority |
| `INTERNAL_PORT` | — | Serves `/internal` only on this port, so it can stay off the public network |
| `WEB_ORIGIN` | `http://localhost:8080` | Exact web origin (CSRF Origin checks, OIDC redirect URI) |
| `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` | `OIDC_AUDIENCE`, none | Browser sign-in client |
| `OIDC_AUTHORIZATION_ENDPOINT`, `OIDC_TOKEN_ENDPOINT` | discovered from `OIDC_ISSUER` | Override discovery |
| `EMBEDDING_PREVIOUS` | none | Earlier embedding models kept callable during a search migration and its rollback window, e.g. `voyage:voyage-3-large:1024` (see ADR 0008) |
| `JOBS_ARCHIVE_RETENTION_DAYS` | `30` | Finished jobs stay in `jobs_archive` this long, then the hourly prune deletes them |
| `OIDC_NATIVE_CLIENT_ID` | `libarrie-native` with the dev issuer, else none | Public (PKCE) client for the native apps; native sign-in is off until set |
| `OIDC_NATIVE_REDIRECT_URI` | `libarrie://oauth/callback` | Must be registered with the issuer for the native client |
| `MCP_OAUTH_AUDIENCE` | `WEB_ORIGIN` + `/mcp` | Audience of identity-provider access tokens accepted by the MCP server (ADR 0012). Ignored with the development issuer, where only API keys work |
| `MCP_OAUTH_SCOPES` | none | Space-separated scopes MCP clients should request from the identity provider |
| `LIBARRIE_OWNER` | — | A sign-in subject made an owner whenever it signs in (ADR 0011); otherwise claim ownership with the setup code printed at startup |
| `SECRET_KEY_BASE` | random (dev only) | 64+ characters, identical on all replicas; required in hosted mode |
| `WEB_STATIC_DIR` | `../../../clients/web/static` | Web assets |
| `LIFECYCLE_SUBSCRIBER_URL`, `LIFECYCLE_SUBSCRIBER_TOKEN` | — | Optional receiver of account lifecycle commands (`PUT {url}/accounts/{id}/lifecycle`); never required to boot (ADR 0009) |
| `S3_ENDPOINT`, `S3_PUBLIC_ENDPOINT`, `S3_REGION`, `S3_BUCKET`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | local SeaweedFS | Private bucket |
| `JOURNAL_BUCKET` | `libarrie-journal` | Interim lifecycle journal target (worker) |
| `DEFAULT_STORED_PAGES`, `DEFAULT_NOTEBOOKS`, `DEFAULT_LIFETIME_PROCESSING` | `30`, `1`, `30` | Defaults when no assignment exists; integer or `unlimited` |
| `ACCOUNT_JOB_SLOTS` | `4` | Per-account running-job cap |
| `OCR_PROVIDER` | `mock` | `mistral` in production (`MISTRAL_API_KEY`, `MISTRAL_OCR_MODEL`=`mistral-ocr-4-1`, `MISTRAL_MIN_CONFIDENCE`, `MISTRAL_TERMS_RECORD`) |
| `EMBEDDING_PROVIDER` | `mock` | `voyage` in production (`VOYAGE_API_KEY`, `VOYAGE_MODEL`=`voyage-4-large`, `EMBEDDING_DIMENSIONS`=1024, `VOYAGE_PRICE_MICROS_PER_MTOK`, `VOYAGE_TERMS_RECORD`) |
| `LARGEST_MONTHLY_PROCESSING_ALLOWANCE` | `1000` | Hosted spend-ceiling validation |
| `S3_UPLOAD_INTEGRITY` | `sha256` | `md5` for Cloudflare R2 |
| `JOURNAL_S3_ENDPOINT`, `JOURNAL_S3_REGION`, `JOURNAL_S3_BUCKET`, `JOURNAL_S3_ACCESS_KEY_ID`, `JOURNAL_S3_SECRET_ACCESS_KEY` | primary store, bucket `libarrie-journal` | Independent journal; required and distinct in hosted mode |
| `DECODER_SANDBOX` | `none` | `minijail` or `unprivileged` (see `docs/runbooks/decoder-sandbox.md`); required in hosted mode |
| `WORKER_CONCURRENCY` | `4` | Runner processes per worker |
| `IDENTITY_HASH_KEYS` | dev key | `key_id:secret` list (1–3) for the identity usage ledger |
| `ACCOUNT_CLOSURE_GRACE_DAYS` | `7` | 0–30 self-hosted; 1–30 hosted |
| `EXPORT_PART_BYTES` | `2000000000` | Maximum archive part size |
| `EXPORT_UPLOAD_CHUNK_BYTES` | `8388608` | Multipart chunk (at least 5 MiB) |
| `EXPORT_MAX_CONCURRENT` | `2` | Assembling exports per account |
| `SPEND_OCR_COST_MICROS`, `SPEND_EMBEDDING_COST_MICROS` | `6000`, `100` | Conservative per-request estimates |
| `SPEND_ACCOUNT_DAILY_MICROS`, `SPEND_DEPLOYMENT_DAILY_MICROS` | `5000000`, `50000000` | Staging defaults; production needs reviewed budgets |
| `SPEND_MAX_PAUSE_HOURS` | `36` | Must exceed the 24-hour budget window |
| `PROVIDER_CONCURRENCY` | `8` | Global permits per provider across replicas |
| `RATE_REQUESTS_PER_MINUTE`, `RATE_SEARCHES_PER_MINUTE` | `1200`, `60` | Per-account limits |

The mock OCR reads text embedded in the image: a PNG `tEXt` chunk with
keyword `libarrie:text`, or a JPEG COM segment. Markers such as `[[blank]]`,
`[[unreadable]]` and `[[transient]]` exercise the outcome contract.

## Commands

`libarrie_api` accepts:
- `serve`
- `migrate`
- `reindex`, after changing the search configuration (embedding model,
  dimensions or text normalization): starts a per-account migration. Keep
  the old model in `EMBEDDING_PREVIOUS` until `reindex-status` shows no
  shadow releases, and through the seven-day rollback window.
- `reindex-status`, search releases per state
- `reindex-rollback ACCOUNT_ID`, to return one account to its previous release
- `setup-code`, a one-time recovery code for claiming ownership at `/setup`
  (for example when the only owner lost access; ADR 0011)
- `storage-check`, to verify the primary and journal stores
- `journal-replay`, after a database restore and before traffic
- `dev-token`

## MCP server

The API serves an MCP server at `/mcp` (Streamable HTTP; ADR 0012) so
agents can search a person's notes and read page text. Its tools are
`get_me`, `search` (`query`, optional `notebook`) and `get_text`
(`notebook`, `page`). A notebook is named by its name or ID.

Authenticate with an API key, created under Settings → API keys, sent as
`Authorization: Bearer lbk_…`. For example, with Claude Code:

```sh
claude mcp add --transport http libarrie https://notes.example.com/mcp \
  --header "Authorization: Bearer lbk_…"
```

With a real identity provider, agents can sign in with OAuth instead: the
401 challenge points them to `/.well-known/oauth-protected-resource/mcp`,
which names `OIDC_ISSUER` as the authorization server. The provider must
issue JWT access tokens with the MCP URL (or `MCP_OAUTH_AUDIENCE`) as the
audience, and let MCP clients register (dynamic registration or client ID
metadata documents).

## Tests

```sh
server/scripts/test.sh
```

On Linux with the real decoder sandbox (via Colima or any Docker host):

```sh
TIER=minijail server/scripts/test-linux.sh      # privileged container
TIER=unprivileged server/scripts/test-linux.sh  # non-root, default profile
```

`scripts/test.sh` creates a fresh `libarrie_test` database, runs the unit suites, applies
migrations and runs the API integration suite against real Postgres and
SeaweedFS. The integration suite covers the upload → OCR → index → search
slice and these section 17 scenarios:
- the last-slot race;
- operation replay and changed bodies;
- lost completion responses;
- staging overwrites;
- stale-lease fencing and slot transfer;
- per-account slot limits;
- classified OCR outcomes;
- recovery holds;
- corrections and processing conflicts;
- replacements;
- bulk renumbering;
- lazy expiry;
- deferred processing;
- entitlement validation and revocation;
- credit idempotency;
- trash/restore through the journal;
- cookie/bearer/CSRF rules;
- tenant isolation;
- permanent purge with recent authentication, revision purge and trash expiry;
- export snapshots, ZIP64 parts, retention, invalidation by purge and missing artifacts;
- account closure scheduling, cancellation, stale deadlines, export extension,
  coverage-end acknowledgement, closing, purge, the identity ledger and
  status-only sign-in;
- lifecycle delivery to a fake subscriber;
- web extensions (Usage sections, routes, notices, form-action origins);
- spend-budget pauses into recovery holds, provider permits and rate limits;
- search highlights, maintenance-job deduplication and archiving;
- a lock-order harness that checks Postgres's deadlock counter.

## Release images

`server/release/` builds the production images: Erlang/OTP built without
any GCC runtime, a `scratch` root with no shell, and a CycloneDX SBOM with a
license gate (ADR 0010).

```sh
docker build -f server/release/Dockerfile --target api    -t libarrie-api .
docker build -f server/release/Dockerfile --target worker -t libarrie-worker .
docker build -f server/release/Dockerfile --target sbom --output type=local,dest=out/sbom .
docker run --rm -e DATABASE_URL=... libarrie-api migrate
```

The first build compiles Erlang/OTP and takes a few minutes. `server/Dockerfile`
remains the development image used by `compose.yaml`.

## Run it for real

`docs/self-hosting.md` covers a personal or small deployment with
`deploy/production/compose.yaml`: HTTPS with Caddy, the release images, your
identity provider, storage, backups and upgrades. Version tags (`v1.2.3`)
publish the release images to `ghcr.io/libarrie/libarrie-api` and
`ghcr.io/libarrie/libarrie-worker`.

## Try the whole stack with Docker Compose

`compose.yaml` at the repository root runs Postgres, SeaweedFS, migrations,
the worker and the API/web UI from one image (`server/Dockerfile`):

```sh
docker compose up --build      # needs the Docker Compose v2 plugin
```

Open <http://localhost:8080> in Chrome or Firefox (the `__Host-` session
cookie is `Secure`; Safari may refuse it on plain-HTTP localhost) and sign in
with any name. OCR and embeddings are mocked by default. To try the real
providers, create a `.env` next to `compose.yaml` (it is git-ignored):

```sh
OCR_PROVIDER=mistral
MISTRAL_API_KEY=...
EMBEDDING_PROVIDER=voyage
VOYAGE_API_KEY=...
```

Only ports 8080 (web) and 8333 (object store, for presigned uploads and
downloads) are published, both on 127.0.0.1. `docker compose down -v`
deletes all data. If image decoding fails because the kernel lacks Landlock,
set `DECODER_SANDBOX=none` in `.env`.
