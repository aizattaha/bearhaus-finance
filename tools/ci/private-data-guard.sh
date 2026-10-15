#!/usr/bin/env bash
# Private-data guard (v2 sprint 1). The repository is public and GitHub Pages serves every file in it,
# so nothing from the real household may land here: no money figures in migrations or docs, no
# hard-coded household/fund ids in new migrations, no personal emails, no statements or dumps.
# Runs in CI on every push and pull request; run it locally before committing:  tools/ci/private-data-guard.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
fail=0
flag() { echo "✗ $1"; echo "$2" | sed 's/^/    /'; fail=1; }
# money is masked in what we print — the point is to find it, not to repeat it in a public CI log
mask() { sed -E 's/[0-9][0-9,]*\.[0-9]{2}/N.NN/g' | cut -c1-160; }

files() { git ls-files -- "$@" 2>/dev/null; }

# 1 · money literals in migrations (data fixes for the real household belong in the private ops folder)
hits=$(files 'supabase/migrations/*.sql' | xargs grep -nE '\b[1-9][0-9,]*\.[0-9]{2}\b' 2>/dev/null | mask)
[ -n "$hits" ] && flag "migration contains a money-looking figure — real-household data fixes go to the private ops folder, not a migration" "$hits"

# 2 · money with a currency sign in docs and top-level markdown (A$X placeholders are fine; allow-listed examples are fine)
allow=$(grep -v '^#' tools/ci/private-data-allow.txt 2>/dev/null | sed '/^$/d' | paste -sd'|' -)
hits=$(files 'docs/*' '*.md' | xargs grep -nE '(A|S|US|NZ|HK)\$ ?(−|-)?[0-9][0-9,]*(\.[0-9]{2}|k\b)' 2>/dev/null | { if [ -n "$allow" ]; then grep -vE "$allow"; else cat; fi; } | mask)
[ -n "$hits" ] && flag "document quotes a money figure — use A\$X placeholders (or add a made-up example to tools/ci/private-data-allow.txt)" "$hits"

# 3 · uuid literals in migrations: only the legacy files that pre-date this guard may name real rows
legacy='20260722000000_sgcn_pretrip|20260724000000_qa_hardening|20260724010000_july_unwind|20260808010000_spending_pot|20260810000000_income_backfill|20261009010000_pots_by_category|20261009020000_reconciliation'
hits=$(files 'supabase/migrations/*.sql' | grep -vE "$legacy" | xargs grep -nE "'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'" 2>/dev/null | cut -c1-160)
[ -n "$hits" ] && flag "migration hard-codes a row id — schema migrations must work for every household" "$hits"

# 4 · personal email addresses anywhere
hits=$(git ls-files | grep -v '^tools/ci/' | xargs grep -nIoE '[A-Za-z0-9._%+-]+@(gmail|googlemail|outlook|hotmail|live|icloud|me|yahoo|proton|protonmail)\.[a-z.]+' 2>/dev/null)
[ -n "$hits" ] && flag "personal email address in the repo" "$hits"

# 5 · statements, spreadsheets and database dumps never belong here
hits=$(git ls-files | grep -iE '\.(pdf|xlsx|xls|csv|dump|backup|gpg|ofx|qif)$|statement|transhist' | grep -v '^tools/ci/')
[ -n "$hits" ] && flag "statement / spreadsheet / dump file in the repo" "$hits"

if [ $fail -eq 0 ]; then echo "✓ private-data guard: nothing private found"; fi
exit $fail
