#!/usr/bin/env bash
# Run one private data fix on production, safely (Bundle B, DH-10 — DECISIONS E37). Run it in the Mac's own
# Terminal app (it asks for the database password, which the Claude app's panel can't take):
#   ~/Code/bearhaus-finance/tools/ops/run-data-fix.sh "<path to the fix in Drive → Data fixes>"
# What it does, in order:
#   1. refuses a fix that isn't a private Drive file named YYYY-MM-DD-what.sql;
#   2. starts the "Backup database" workflow and waits for it (a restore point from minutes before the fix);
#   3. signs in to production as postgres (it asks for the database password; typing shows nothing),
#      refuses if the fix already ran (data_fixes_applied), shows the money check's non-zero lines (counts only),
#      runs the fix (it stops at the first error, and the fix's own begin/commit undoes everything), records it,
#      and shows the money check again.
set -euo pipefail
FIX="${1:-}"
PSQL=/opt/homebrew/opt/libpq/bin/psql; [ -x "$PSQL" ] || PSQL="$(command -v psql || true)"
REPO=aizattaha/bearhaus-finance
CONN="host=aws-0-ap-southeast-2.pooler.supabase.com port=5432 dbname=postgres user=postgres.diqaezhdxloqhglndqrq sslmode=require connect_timeout=20"
# a rehearsal on the local stack: BH_FIX_CONN="host=127.0.0.1 port=55322 dbname=postgres user=postgres" (no backup step)
LOCAL=""
if [ -n "${BH_FIX_CONN:-}" ]; then
  case "$BH_FIX_CONN" in *host=127.0.0.1*) CONN="$BH_FIX_CONN"; LOCAL=1;; *) echo "✗ BH_FIX_CONN is for the local stack only"; exit 1;; esac
fi

[ -n "$PSQL" ] || { echo "✗ psql isn't installed: brew install libpq"; exit 1; }
[ -n "$FIX" ] && [ -f "$FIX" ] || { echo "✗ give the fix file: $0 \"<path to the .sql file>\""; exit 1; }
NAME="$(basename "$FIX")"
[[ "$NAME" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+\.sql$ ]] || { echo "✗ a data fix is named YYYY-MM-DD-what.sql (got $NAME)"; exit 1; }
case "$(cd "$(dirname "$FIX")" && pwd)" in
  *"/Data fixes"*) ;;
  *) echo "✗ data fixes live in the private Drive folder \"Data fixes\", never in the repo"; exit 1;;
esac

if [ -n "$LOCAL" ]; then echo "▶ 1/3 local rehearsal: no backup"; else
echo "▶ 1/3 a fresh backup first (about 2 minutes)"
before="$(gh run list -R "$REPO" --workflow backup-db.yml -L 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)"
gh workflow run backup-db.yml -R "$REPO" >/dev/null
for i in $(seq 1 30); do
  sleep 4
  run="$(gh run list -R "$REPO" --workflow backup-db.yml -L 1 --json databaseId -q '.[0].databaseId')"
  [ -n "$run" ] && [ "$run" != "$before" ] && break
done
[ -n "${run:-}" ] && [ "$run" != "$before" ] || { echo "✗ the backup didn't start — nothing was changed"; exit 1; }
gh run watch "$run" -R "$REPO" --exit-status >/dev/null || { echo "✗ the backup failed (run $run) — nothing was changed"; exit 1; }
echo "  ✓ backup done (run $run)"
fi

echo "▶ 2/3 the fix: type the database password when asked (typing shows nothing), then press Enter"
"$PSQL" "$CONN" -X -q -v ON_ERROR_STOP=1 -v fix="$NAME" <<SQL
\pset footer off
select exists (select 1 from public.data_fixes_applied where name = :'fix') as done \gset
\if :done
  \echo '✗ this fix already ran — nothing changed'
  \quit
\endif
\echo 'money check before (non-zero lines, counts only):'
select severity, bad, check_name from public.bh_money_check() where bad > 0 order by severity, check_name;
\i '$FIX'
insert into public.data_fixes_applied (name) values (:'fix');
\echo 'money check after:'
select severity, bad, check_name from public.bh_money_check() where bad > 0 order by severity, check_name;
\echo '✓ fix applied and recorded'
SQL
echo "▶ 3/3 finished. Tell Claude what the last line above says (✓ fix applied, or already ran, or the error)."
