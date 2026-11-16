#!/usr/bin/env bash
# Run every server test suite. Integration suites need the development stack
# (Postgres with pgvector on :5433 and RustFS S3 on :8333); see
# deploy/docker-compose.yml. A fresh `libarrie_test` database is created per
# run.
set -euo pipefail
cd "$(dirname "$0")/.."

PG_CONTAINER="${PG_CONTAINER:-libarrie-pg}"
export DATABASE_URL="${TEST_DATABASE_URL:-postgres://libarrie:libarrie@localhost:5433/libarrie_test}"
export S3_ENDPOINT="${S3_ENDPOINT:-http://localhost:8333}"
export S3_BUCKET="${S3_BUCKET:-libarrie-test}"
export DEV_ISSUER_SECRET=test-dev-secret
export MIGRATIONS_DIR="$PWD/../database/migrations"
export LIBARRIE_TEST_S3_ENDPOINT="$S3_ENDPOINT"
# A fresh journal bucket per run, so replay sees only this run's events.
export JOURNAL_S3_BUCKET="libarrie-journal-test-$(date +%s)"

docker exec "$PG_CONTAINER" psql -q -U libarrie -d postgres \
  -c "drop database if exists libarrie_test with (force)" \
  -c "create database libarrie_test"

for pkg in packages/database packages/jobs packages/integrations packages/domain apps/worker; do
  echo "== $pkg"
  (cd "$pkg" && gleam test)
done

echo "== apps/api (migrations + integration)"
(cd apps/api && gleam run -- migrate && gleam test)
