#!/usr/bin/env bash
# Apply every migration to a scratch database from nothing, then run the SQL tests.
# Usage: tools/sql-tests/run.sh [database-url]   (default: postgresql://postgres:postgres@127.0.0.1:5432/postgres)
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="${1:-postgresql://postgres:postgres@127.0.0.1:5432/postgres}"
DBNAME="$(psql "$DB" -At -c "select current_database()")"
echo "▶ bootstrap"
psql "$DB" -v ON_ERROR_STOP=1 -q -v dbname="$DBNAME" -f tools/sql-tests/bootstrap.sql
# data-only rewrites of the original household that assert against its real balances — meaningless on a scratch database;
# the view they rebuild is superseded by later migrations, so skipping them changes nothing about the end schema
SKIP="20261009000000_itemised_history.sql"
for f in supabase/migrations/*.sql; do
  if [[ " $SKIP " == *" $(basename "$f") "* ]]; then echo "▷ $f (skipped: data-only history rewrite)"; continue; fi
  echo "▶ $f"
  # the baseline is a Supabase dump: one platform extension (vault) doesn't exist on plain Postgres
  if [[ "$f" == *baseline.sql ]]; then grep -v 'supabase_vault' "$f" | psql "$DB" -v ON_ERROR_STOP=1 -q 2>&1 | grep -v "NOTICE:\|^$" || true
    echo "▶ fixture (the original household's skeleton)"; psql "$DB" -v ON_ERROR_STOP=1 -q -f tools/sql-tests/fixture.sql
  else psql "$DB" -v ON_ERROR_STOP=1 -q -f "$f" 2>&1 | grep -v "NOTICE:\|^$" || true; fi
done
echo "▶ tests"
fail=0
for t in tools/sql-tests/test_*.sql; do
  if psql "$DB" -v ON_ERROR_STOP=1 -q -f "$t" > /tmp/sqltest.out 2>&1; then echo "  ✓ $(basename "$t")"; else echo "  ✗ $(basename "$t")"; cat /tmp/sqltest.out; fail=1; fi
done
exit $fail
