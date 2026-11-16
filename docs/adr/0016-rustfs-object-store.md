# ADR 0016: RustFS as the bundled object store

Status: accepted

Supersedes the object store choice in ADR 0001 and ADR 0013.

The development and self-hosted stacks bundled SeaweedFS. They now bundle
RustFS 1.0.6 (`rustfs/rustfs`), which is also Apache-2.0, so section 3's
dependency policy still holds. Hosted and Kubernetes deployments are
unchanged: they use any S3-compatible store, as before.

## Why

- **Configured from the environment.** Credentials and CORS are plain
  variables (`RUSTFS_ACCESS_KEY`, `RUSTFS_SECRET_KEY`,
  `RUSTFS_CORS_ALLOWED_ORIGINS`). The production stack no longer writes an
  identity file from a shell entrypoint, and `deploy/dev/s3.json` is gone.
- **A single process.** SeaweedFS ran a master, a volume server, a filer and
  the S3 gateway in one container, with volume sizing to tune.

## How it's run

- **Port 8333,** set with `RUSTFS_ADDRESS`, so presigned URLs, the clients'
  development instructions, fixtures and test scripts are unchanged.
- **CORS** is limited to the app's origin. RustFS 1.0 sends no CORS headers
  unless this is set, and browsers can't upload without it.
- **A new volume,** `objects` rather than `objdata`. An upgrade starts
  RustFS empty and leaves SeaweedFS's data untouched, so it can be copied
  across and nothing is lost if the copy is skipped.
- **The web console is off.** Nothing uses it, and it would be one more
  thing to secure.
- **Pinned** to `1.0.6`, not `latest`. Builds before 1.0.1 didn't apply
  bucket lifecycle rules, and builds before 1.0.0-beta.2 sent permissive
  CORS headers by default (CVE-2026-46685).

## Consequences

- **Existing self-hosted installs** that use the bundled store must copy
  their page images across when they upgrade, since RustFS can't read
  SeaweedFS's volume. The copy goes store to store, so each object keeps its
  `Content-Type`, which presigned downloads return. `docs/runbooks/seaweedfs-to-rustfs.md` covers it.
  Installs on R2 or another external store are unaffected.
- **Verification:** the integration suites must pass against RustFS
  (`server/scripts/test.sh` with `deploy/docker-compose.yml`), including the
  presigned PUT with `x-amz-checksum-sha256` that uploads depend on.
