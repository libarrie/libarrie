# Runbook: Cloudflare R2 for originals and the deletion journal

This covers the two R2 stores in hosted mode. Nothing here requires sharing
credentials with anyone; the checks run with your own keys.

## 1. Primary store (originals, derived images, export parts)

1. Create a private bucket, for example `libarrie-prod`.
2. Create an R2 API token with **Object Read & Write** scoped to **this bucket
   only**.
3. Configure CORS to allow `PUT` from the web origin only (direct uploads)
   and `GET` from the web origin only.
4. Set:

   ```sh
   S3_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
   S3_PUBLIC_ENDPOINT=https://<account-id>.r2.cloudflarestorage.com
   S3_REGION=auto
   S3_BUCKET=libarrie-prod
   S3_ACCESS_KEY_ID=...            # from your secret manager
   S3_SECRET_ACCESS_KEY=...
   S3_UPLOAD_INTEGRITY=md5         # R2 verifies Content-MD5, not x-amz-checksum-sha256
   ```

R2 does not verify `x-amz-checksum-sha256`, so `S3_UPLOAD_INTEGRITY=md5`
binds the client's MD5 into every presigned upload as a signed `Content-MD5`
header. R2 then rejects mismatched bodies itself, and the signed
`Content-Length` rejects oversize bodies. Clients send `checksum_md5`
alongside `checksum_sha256`; the API still verifies SHA-256 on the frozen
copy before acceptance.

## 2. Journal store (independent deletion/lifecycle journal)

Use a **separate R2 account** if possible (separate failure and credential
domain); at minimum a separate bucket and token.

1. Create the bucket, for example `libarrie-journal`.
2. Add a **bucket lock rule** covering the prefix `journal/`. Its retention
   must outlast every backup/PITR/object-version recovery horizon plus seven
   days: at least **37 days** for a 30-day recovery horizon. Extend it before
   lengthening any backup horizon.

   ```sh
   npx wrangler r2 bucket lock add libarrie-journal journal-retention journal/ \
     --retention-days 37
   npx wrangler r2 bucket lock list libarrie-journal
   ```

3. Create an R2 token with **Object Read & Write** scoped to this bucket
   only. (R2 tokens cannot be write-only; the bucket lock is what prevents
   rewriting or deleting history. The worker also writes with
   `If-None-Match: *`, so it never overwrites an event.)
4. Set:

   ```sh
   JOURNAL_S3_ENDPOINT=https://<journal-account-id>.r2.cloudflarestorage.com
   JOURNAL_S3_REGION=auto
   JOURNAL_S3_BUCKET=libarrie-journal
   JOURNAL_S3_ACCESS_KEY_ID=...
   JOURNAL_S3_SECRET_ACCESS_KEY=...
   ```

Hosted mode refuses to start if the journal shares the primary bucket or
credentials.

## 3. Verify before launch

```sh
libarrie_api storage-check
```

Every `FAIL` must be fixed before launch:

- primary: matching upload succeeds; a same-length tampered body and an
  oversize body are rejected by R2 itself; conditional copy refuses a stale
  ETag; signed downloads work;
- journal: first write succeeds; rewrites are refused; **deletes are
  refused** (fails if the bucket lock rule is missing); credentials and
  bucket are separate from the primary store.

The check leaves a few tiny probe objects under `journal/probes/`, which the
lock retains for the retention period.

## 4. Restoring the database

The journal is the source of truth for deletions, restores, purges and
account lifecycle changes made after the database recovery point.

1. Keep API and worker replicas stopped (no traffic, jobs or lifecycle subscriber deliveries).
2. Restore the database snapshot (and objects per the backup runbook).
3. Run migrations if needed: `libarrie_api migrate`.
4. Run `libarrie_api journal-replay`.
   - It lists the journal; if the journal is unreachable it exits non-zero
     with `RECOVERY CLOSED` (do not start the service).
   - It checks coverage: every lifecycle event the restored database
     recorded as delivered must exist in the journal. A gap exits non-zero
     with `RECOVERY CLOSED`.
   - It re-applies newer events in sequence order: deletions and purges are
     re-applied, restores re-activate pages (or are reported as `CONFLICT`
     and left hidden), and newer account lifecycle revisions win (a
     cancellation after the recovery point defeats an old deadline).
   - It is idempotent; running it twice replays nothing the second time.
5. Block `/mcp` in front of the API, and check the block, before the API
   starts (ADR 0017). Privacy changes and page moves made after the
   recovery point aren't in the journal, so agents must not reach the
   restored notebooks until owners have re-checked them. Answer `/mcp` with
   503 and the body `MCP is paused.`, as `docs/self-hosting.md` (Compose)
   or "Blocking `/mcp`" in `deploy/helm/libarrie/README.md` describes. Only
   that response confirms the block: a 401 with a `WWW-Authenticate` header
   comes from the MCP server.
6. Review any `CONFLICT` lines, then start the worker and API.
7. Tell account owners the recovery point. Ask them to re-check which
   notebooks are private, to move again any pages they moved after it, and
   to revoke again any API key they revoked after it, because revoking
   records no journal intent. Unblock `/mcp` once they have.
