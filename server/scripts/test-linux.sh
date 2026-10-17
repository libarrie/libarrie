#!/usr/bin/env bash
# Runs every server suite inside Linux with the sandboxed decoder enabled,
# against the development Postgres and SeaweedFS containers.
#   TIER=minijail (default, privileged container) or TIER=unprivileged
#   (non-root, default container profile: Landlock + seccomp tier).
set -euo pipefail
cd "$(dirname "$0")/.."
TIER="${TIER:-minijail}"
docker build -q -f native/decoder/Dockerfile --target adapter-test -t libarrie-decoder-adapter . >/dev/null
docker network create libarrie-test-net >/dev/null 2>&1 || true
for c in libarrie-pg libarrie-s3; do docker network connect libarrie-test-net "$c" 2>/dev/null || true; done
docker exec libarrie-pg psql -q -U libarrie -d postgres \
  -c "drop database if exists libarrie_test with (force)" -c "create database libarrie_test"
if [ "$TIER" = minijail ]; then RUN_AS=(--privileged); else RUN_AS=(--user 1000:1000); fi
docker run --rm "${RUN_AS[@]}" --network libarrie-test-net \
  -v "$(cd .. && pwd):/repo:ro" --entrypoint /bin/sh \
  -e HOME=/tmp -v libarrie-gleam-cache:/tmp/.cache \
  -e DATABASE_URL=postgres://libarrie:libarrie@libarrie-pg:5432/libarrie_test \
  -e S3_ENDPOINT=http://libarrie-s3:8333 -e S3_BUCKET=libarrie-test \
  -e LIBARRIE_TEST_S3_ENDPOINT=http://libarrie-s3:8333 \
  -e JOURNAL_S3_BUCKET="libarrie-journal-test-$(date +%s)" \
  -e DEV_ISSUER_SECRET=test-dev-secret -e MIGRATIONS_DIR=/tmp/w/database/migrations \
  -e DECODER_SANDBOX="$TIER" -e DECODER_BIN_DIR=/opt/libarrie/bin \
  -e DECODER_POLICY=/opt/libarrie/policy/decoder.policy -e DECODER_SCRATCH_DIR=/tmp/scratch \
  -e LIBARRIE_DECODER_TIER="$TIER" \
  libarrie-decoder-adapter /repo/server/scripts/linux-test.sh
