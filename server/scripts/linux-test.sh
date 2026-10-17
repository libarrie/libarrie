#!/bin/sh
# Runs the server test suites inside Linux with the sandboxed decoder
# enabled (invoked by scripts/test-linux.sh). Expects the repository mounted
# read-only at /repo and Postgres/S3 reachable as libarrie-pg/libarrie-s3.
# Works as root (minijail tier) or as an unprivileged user.
set -e
W=/tmp/w
mkdir -p "$W" /tmp/scratch
cd /repo && tar --exclude='./server/*/*/build' -cf - server database | tar -xf - -C "$W"
cd "$W/server"
for pkg in packages/database packages/jobs packages/integrations packages/domain apps/worker; do
  echo "== $pkg"
  (cd "$pkg" && rm -rf build && gleam test)
done
echo "== apps/api (migrations + integration, decoder: ${DECODER_SANDBOX})"
cd apps/api && rm -rf build && gleam run -- migrate && gleam test
