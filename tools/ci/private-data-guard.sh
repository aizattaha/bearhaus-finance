#!/usr/bin/env bash
# Private-data guard (v2 sprint 1; more shapes and a pre-push hook in Bundle B, DECISIONS E37). The repository
# is public and GitHub Pages serves every file in it, so nothing from the real household may land here: no money
# figures in migrations or docs, no hard-coded household/fund ids in new migrations, no email but test ones, no
# statements or dumps, no invite codes, keys, tokens or database passwords.
# Runs before every push (tools/git-hooks/pre-push) and in CI on every push and pull request. By hand:
#   tools/ci/private-data-guard.sh
# GUARD_ROOT=<folder> checks another checkout with this copy's rules (the pre-push hook checks each pushed commit).
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
cd "${GUARD_ROOT:-$here/../..}"
fail=0
flag() { echo "✗ $1"; echo "$2" | sed 's/^/    /'; fail=1; }
# money is masked in what we print — the point is to find it, not to repeat it in a public CI log
mask() { sed -E 's/\$ ?(−|-)?[0-9][0-9,.]*k?/$N/g; s/[0-9][0-9,]*\.[0-9]{2}/N.NN/g' | cut -c1-160; }
# a secret is never printed at all: only where it is (an email: where, and its domain)
where() { cut -d: -f1,2; }
domain() { sed -E 's/^([^:]+:[0-9]+:).*@/\1…@/'; }

files() { git ls-files -- "$@" 2>/dev/null; }
# every tracked text file except the guard's own folder (its patterns would match themselves)
textfiles() { git ls-files | grep -v '^tools/ci/'; }

# 1 · money literals in migrations (data fixes for the real household belong in the private ops folder)
hits=$(files 'supabase/migrations/*.sql' | xargs grep -HnE '\b[1-9][0-9,]*\.[0-9]{2}\b' 2>/dev/null | mask)
[ -n "$hits" ] && flag "migration contains a money-looking figure — real-household data fixes go to the private ops folder, not a migration" "$hits"

# 2 · money with a currency sign in docs and markdown, bare $ included (A$X placeholders are fine; allow-listed examples are fine)
allow=$(grep -v '^#' "$here/private-data-allow.txt" 2>/dev/null | sed '/^$/d' | paste -sd'|' -)
money='(A|S|US|NZ|HK)\$ ?(−|-)?[0-9][0-9,]*(\.[0-9]{2}|k\b)'
bare='(^|[^A-Za-z0-9$\\{])\$ ?(−|-)?([0-9]{1,3}(,[0-9]{3})+|[0-9]+\.[0-9]{2}|[0-9]+k\b|[0-9]{3,})'
hits=$(files 'docs/*' '*.md' | xargs grep -HnE "$money|$bare" 2>/dev/null | { if [ -n "$allow" ]; then grep -vE "$allow"; else cat; fi; } | mask)
[ -n "$hits" ] && flag "document quotes a money figure — use A\$X placeholders (or add a made-up example to tools/ci/private-data-allow.txt)" "$hits"

# 3 · uuid literals in migrations: only the legacy files that pre-date this guard may name real rows
legacy='20260722000000_sgcn_pretrip|20260724000000_qa_hardening|20260724010000_july_unwind|20260808010000_spending_pot|20260810000000_income_backfill|20261009010000_pots_by_category|20261009020000_reconciliation'
hits=$(files 'supabase/migrations/*.sql' | grep -vE "$legacy" | xargs grep -HnE "'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'" 2>/dev/null | cut -c1-160)
[ -n "$hits" ] && flag "migration hard-codes a row id — schema migrations must work for every household" "$hits"

# 4 · email addresses: only test ones (*.test, *.local, *.localhost, example.*), the GitHub no-reply address and
#     Supabase's own config placeholder
hits=$(textfiles | xargs grep -HnIoE '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}' 2>/dev/null \
  | grep -vE '@([A-Za-z0-9-]+\.)*(test|local|localhost|example|invalid)$|@example\.(com|org|net)$|@users\.noreply\.github\.com$|^supabase/config\.toml:[0-9]+:admin@email\.com$' | domain)
[ -n "$hits" ] && flag "email address in the repo — only made-up test addresses (name@something.test) belong here" "$hits"

# 5 · statements, spreadsheets and database dumps never belong here
hits=$(git ls-files | grep -iE '\.(pdf|xlsx|xls|csv|dump|backup|gpg|age|ofx|qif)$|statement|transhist' | grep -v '^tools/ci/')
[ -n "$hits" ] && flag "statement / spreadsheet / dump file in the repo" "$hits"

# 6 · household invite codes (a live one is a member login to the household); JOIN-XXXX-XXXX is the placeholder
hits=$(textfiles | xargs grep -HnIoE 'JOIN-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}' 2>/dev/null | grep -v ':JOIN-XXXX-XXXX$' | where)
[ -n "$hits" ] && flag "household invite code in the repo — use JOIN-XXXX-XXXX in docs and generate codes in tests" "$hits"

# 7 · Supabase keys and tokens: personal access tokens, secret keys, JWTs (the legacy anon / service keys);
#     the publishable key in app/common.js is public by design
hits=$(textfiles | xargs grep -HnIoE 'sbp_[A-Za-z0-9]{20,}|sb_secret_[A-Za-z0-9_-]{10,}|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+' 2>/dev/null | where)
[ -n "$hits" ] && flag "a Supabase key or token in the repo — keys live in GitHub secrets and the password manager" "$hits"

# 8 · database connection strings with a password, to anything but this computer
hits=$(textfiles | xargs grep -HnIoE 'postgres(ql)?://[^:/@[:space:]]+:[^@[:space:]]+@[^/:[:space:]]+' 2>/dev/null \
  | grep -vE '@(127\.0\.0\.1|localhost|\[::1\]|db|postgres)$' | grep -vE '://[^:]+:(<|\$|…|\.\.\.|\*)' | where)
[ -n "$hits" ] && flag "a database connection string with a password — leave the password out (psql asks for it)" "$hits"

if [ $fail -eq 0 ]; then echo "✓ private-data guard: nothing private found"; fi
exit $fail
