#!/usr/bin/env bash
# Rebuild the LOCAL stack from scratch and load a synthetic household (v2 sprint 2). Local only — refuses a
# hosted database. Every name and amount here is made up.
#   tools/dev/seed.sh            (needs the local stack running: see tools/dev/README.md)
# Sign in at http://127.0.0.1:8790/app/ as  owner@bh-local.test / local-test-pass-2026  (test credentials, local only)
set -euo pipefail
cd "$(dirname "$0")/../.."
WORKDIR="${BH_LOCAL:-$HOME/Code/bh-local}"
ENV="$(supabase status -o env --workdir "$WORKDIR" 2>/dev/null)"
val() { printf '%s\n' "$ENV" | grep -E "^$1=" | cut -d'"' -f2; }
API="$(val API_URL)"; DB="$(val DB_URL)"; SERVICE="$(val SERVICE_ROLE_KEY)"
case "$API$DB" in *supabase.co*|*pooler.supabase*) echo "refusing: not a local stack"; exit 1;; esac
[ -n "$API" ] && [ -n "$SERVICE" ] || { echo "local stack not running — cd $WORKDIR && supabase start"; exit 1; }
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"

echo "▶ wipe the local database"
(cd "$WORKDIR" && supabase db reset >/dev/null 2>&1)
echo "▶ migrations + tests"
tools/sql-tests/run.sh "$DB" | tail -n +1 | grep -E "✓|✗|tests" || true

echo "▶ test login"
UID_="$(curl -s -X POST "$API/auth/v1/admin/users" -H "apikey: $SERVICE" -H "Authorization: Bearer $SERVICE" -H "Content-Type: application/json" \
  -d '{"email":"owner@bh-local.test","password":"local-test-pass-2026","email_confirm":true}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')"

echo "▶ synthetic household"
psql "$DB" -v ON_ERROR_STOP=1 -q -v uid="$UID_" -f tools/dev/seed.sql
echo "✓ seeded — sign in as owner@bh-local.test / local-test-pass-2026"
