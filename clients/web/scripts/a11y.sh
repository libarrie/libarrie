#!/usr/bin/env bash
# Automated accessibility audit (WCAG 2.2 A/AA via axe-core):
# 1. the server test suite renders every screen, light and dark, to HTML
#    (it uses the same test database as server/scripts/test.sh);
# 2. Playwright loads each snapshot with the real stylesheet and runs axe.
# No API, worker or web server is started.
set -euo pipefail
WEB="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$WEB/../.." && pwd)"
OUT="$(mktemp -d)/a11y-snapshots"
trap 'rm -rf "$(dirname "$OUT")"' EXIT
cd "$ROOT/server"
# A fresh database per run, like server/scripts/test.sh.
docker exec "${PG_CONTAINER:-libarrie-pg}" psql -q -U libarrie -d postgres \
  -c "drop database if exists libarrie_a11y with (force)" -c "create database libarrie_a11y"
export DATABASE_URL="postgres://libarrie:libarrie@localhost:5433/libarrie_a11y"
export DEV_ISSUER_SECRET=test-dev-secret MIGRATIONS_DIR="$ROOT/database/migrations"
export S3_BUCKET="${S3_BUCKET:-libarrie-test}" LIBARRIE_TEST_S3_ENDPOINT="${S3_ENDPOINT:-http://localhost:8333}"
export JOURNAL_S3_BUCKET="libarrie-journal-a11y-$(date +%s)"
(cd apps/api && gleam run -- migrate >/dev/null && LIBARRIE_A11Y_SNAPSHOTS="$OUT" gleam test >/dev/null)
cd "$WEB"
LIBARRIE_A11Y_SNAPSHOTS="$OUT" npx playwright test -c playwright.a11y.config.ts
