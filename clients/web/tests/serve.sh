#!/usr/bin/env bash
# Starts the Libarrie worker and API for browser tests against a fresh
# database and bucket on the development stack (Postgres :5433, S3 :8333).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export DATABASE_URL="postgres://libarrie:libarrie@localhost:5433/libarrie_e2e"
export S3_BUCKET="libarrie-e2e"
export JOURNAL_S3_BUCKET="libarrie-e2e-journal"
export DEV_ISSUER_SECRET="e2e-dev-issuer-secret"
export SECRET_KEY_BASE="e2e-secret-key-base-0123456789abcdef0123456789abcdef0123456789abcdef"
export WEB_ORIGIN="http://localhost:8080"
export PORT=8080
export MIGRATIONS_DIR="$ROOT/database/migrations"
export WEB_STATIC_DIR="$ROOT/clients/web/static"
export WORKER_CONCURRENCY=2

docker exec libarrie-pg psql -q -U libarrie -d postgres \
  -c "drop database if exists libarrie_e2e with (force)" -c "create database libarrie_e2e"
(cd "$ROOT/server/apps/api" && gleam run -- migrate)

cleanup() { pkill -f "libarrie_worker" 2>/dev/null || true; }
trap cleanup EXIT
(cd "$ROOT/server/apps/worker" && gleam run) &
cd "$ROOT/server/apps/api" && gleam run -- serve
