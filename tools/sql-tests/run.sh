#!/usr/bin/env bash
# Apply every migration to a scratch database from nothing, then run the SQL tests.
# Usage: tools/sql-tests/run.sh [database-url]   (default: postgresql://postgres:postgres@127.0.0.1:5432/postgres)
# Stops at the FIRST error anywhere: a migration that doesn't apply must turn CI red (v2 sprint 1).
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${1:-postgresql://postgres:postgres@127.0.0.1:5432/postgres}"
export PGOPTIONS='-c client_min_messages=warning'
LOG="$(mktemp)"; trap 'rm -f "$LOG"' EXIT

# psql with ON_ERROR_STOP; on failure print everything it said and stop the run
run_psql() {
  if ! psql "$DB" -v ON_ERROR_STOP=1 -q "$@" >"$LOG" 2>&1; then
    cat "$LOG"; echo "✗ failed: psql $*"; exit 1
  fi
  grep -v '^$\|"wal_level" is insufficient' "$LOG" || true
}

DBNAME="$(psql "$DB" -At -c "select current_database()")"
echo "▶ bootstrap"
run_psql -v dbname="$DBNAME" -f tools/sql-tests/bootstrap.sql
for f in supabase/migrations/*.sql; do
  echo "▶ $f"
  if [[ "$f" == *baseline.sql ]]; then
    # the baseline is a Supabase dump: one platform extension (vault) doesn't exist on plain Postgres
    BASE="$(mktemp)"; grep -v 'supabase_vault' "$f" > "$BASE"
    run_psql -f "$BASE"; rm -f "$BASE"
    echo "▶ fixture (the original household's skeleton)"; run_psql -f tools/sql-tests/fixture.sql
  else
    run_psql -f "$f"
  fi
done
echo "▶ tests"
fail=0
for t in tools/sql-tests/test_*.sql; do
  if psql "$DB" -v ON_ERROR_STOP=1 -q -f "$t" > "$LOG" 2>&1; then echo "  ✓ $(basename "$t")"; else echo "  ✗ $(basename "$t")"; cat "$LOG"; fail=1; fi
done
exit $fail
