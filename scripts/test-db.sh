#!/usr/bin/env bash
#
# Manages the throwaway database used by `npm test`.
#
#   scripts/test-db.sh reset    (default) drop + create + migrate
#   scripts/test-db.sh create   create if missing, then migrate
#   scripts/test-db.sh drop     drop
#
# The dev database (`shelfcase`) is never touched.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DB_HOST="${TEST_DB_HOST:-localhost}"
DB_PORT="${TEST_DB_PORT:-55432}"
DB_USER="${TEST_DB_USER:-shelfcase}"
DB_PASSWORD="${TEST_DB_PASSWORD:-shelfcase}"
DB_NAME="${TEST_DB_NAME:-shelfcase_test}"

export PGPASSWORD="$DB_PASSWORD"
ADMIN_URL="postgres://${DB_USER}@${DB_HOST}:${DB_PORT}/postgres"

command="${1:-reset}"

wait_for_pg() {
  for _ in $(seq 1 60); do
    if psql "$ADMIN_URL" -q -c "SELECT 1" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "!! PostgreSQL not reachable at ${DB_HOST}:${DB_PORT} — run 'docker compose up -d' first" >&2
  return 1
}

case "$command" in
  create|reset)
    wait_for_pg
    if [[ "$command" == "reset" ]]; then
      psql "$ADMIN_URL" -q -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"${DB_NAME}\" WITH (FORCE);"
      echo "==> dropped ${DB_NAME} (if it existed)"
    fi
    psql "$ADMIN_URL" -q -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"${DB_NAME}\";" 2>/dev/null \
      || echo "==> ${DB_NAME} already exists"
    echo "==> test database ready: ${DB_NAME}"
    ;;
  drop)
    wait_for_pg
    psql "$ADMIN_URL" -q -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"${DB_NAME}\" WITH (FORCE);"
    echo "==> dropped ${DB_NAME}"
    ;;
  *)
    echo "usage: $0 [reset|create|drop]" >&2
    exit 2
    ;;
esac
