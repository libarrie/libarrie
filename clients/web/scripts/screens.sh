#!/usr/bin/env bash
# Screenshots of every screen, light and dark, for design review:
# the server test suite renders the screens to HTML (as for the
# accessibility audit), then Chrome captures each one with the real
# stylesheet. No API, worker or web server is started.
#   scripts/screens.sh [OUTPUT_DIR]   (default: test-results/screens)
set -euo pipefail
WEB="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$WEB/../.." && pwd)"
SCREENS_OUT="$(cd "$WEB" && mkdir -p "${1:-test-results/screens}" && cd "${1:-test-results/screens}" && pwd)"
export SCREENS_OUT
SNAP="$(mktemp -d)/snapshots"
trap 'rm -rf "$(dirname "$SNAP")"' EXIT
cd "$ROOT/server"
docker exec "${PG_CONTAINER:-libarrie-pg}" psql -q -U libarrie -d postgres \
  -c "drop database if exists libarrie_screens with (force)" -c "create database libarrie_screens"
export DATABASE_URL="postgres://libarrie:libarrie@localhost:5433/libarrie_screens"
export DEV_ISSUER_SECRET=test-dev-secret MIGRATIONS_DIR="$ROOT/database/migrations"
export S3_BUCKET="${S3_BUCKET:-libarrie-test}" LIBARRIE_TEST_S3_ENDPOINT="${S3_ENDPOINT:-http://localhost:8333}"
export S3_ENDPOINT="${S3_ENDPOINT:-http://localhost:8333}"
export JOURNAL_S3_BUCKET="libarrie-journal-screens-$(date +%s)"
(cd apps/api && gleam run -- migrate >/dev/null && LIBARRIE_A11Y_SNAPSHOTS="$SNAP" gleam test >/dev/null)
cd "$WEB"
LIBARRIE_A11Y_SNAPSHOTS="$SNAP" npx playwright test -c playwright.screens.config.ts
echo "screenshots in $SCREENS_OUT"
