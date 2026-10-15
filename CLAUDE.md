# BearHaus Finance — working rules for Claude Code

Household finance PWA for Aizat & Paige (Melbourne; AUD + SGD). Owner: Aizat (not a developer — explain in plain words, point form, frank expert engagement; he gives standing authority to build without per-step sign-off once a plan is agreed).

Read in this order when you start: this file → `docs/HANDOVER.md` (state of play, what's pending) → `docs/DECISIONS.md` (why things are the way they are) → the two `docs/architecture-review-*.md`. The long-form handbook (`bearhaus-v2-rebuild-summary.md`) and the **v2 review + plan** (`Reports/2026-10 v2 review/00-CTO-v2-plan.md`: 6 specialist reports, 2 phases × 4 sprints) live **outside the repo** in Aizat's Drive folder (see HANDOVER), because they quote real balances or describe security holes before they are fixed.

The working copy is a git clone at `~/Code/bearhaus-finance` (outside Drive). Commit and push from there.

## Hard rules
1. **Private data.** The repo is PUBLIC, and GitHub Pages serves every file in it. Never commit real balances, statement figures, invite codes, emails, dumps, or anything from the production database. Fund/card *names* already appear in code and tests and are fine. QA raw reports that quote real numbers go to Drive, not here. `tools/ci/private-data-guard.sh` enforces this in CI. **Real-household data fixes are never migrations**: see `supabase/data-fixes/README.md`. Database error messages carry counts and ids, never amounts, because CI logs are public.
2. **Supabase only.** No other backend, no build step, no framework. Two static pages (`app/index.html` phone, `desktop/index.html` Desk) + `app/common.js`, deployed by GitHub Pages from `main`.
3. **No copy-paste deploys.** Claude commits and pushes to `main`. Migrations under `supabase/migrations/` auto-deploy via `.github/workflows/deploy-db.yml` — *only after* the `test` job applies the whole chain from scratch and `tools/sql-tests/` pass. Never ask Aizat to paste SQL into the Supabase editor.
4. **Every sprint ends with the hygiene step** (Aizat's standing instruction, 14 Oct 2026): SQL tests extended → CI green locally (`tools/sql-tests/run.sh` against Postgres 17 *and* the local Supabase stack, `tools/dev/README.md`) → private-data guard + JS check → browser verification on the local stack with synthetic data → commit/push → confirm the Actions (Checks + both deploy jobs) → handbook section → Drive mirror → short report.
5. **Money invariants are asserted, not assumed.** A move/undo RPC that could change a fund's balance asserts before/after and refuses otherwise. Keep that pattern.
6. Don't add a framework, bundler, or TypeScript. Don't rename the compat views (`daily_expenses`, `travel_expenses`, `fund_transactions`) — both apps and every RPC read them by name.
7. **Every migration states its own grants** (v2 sprint 1). Nothing new is executable or readable by the API roles by default: a new function needs `grant execute … to authenticated` (never `anon` — only `check_invite`/`invite_info` are public), a new table or view needs explicit `grant select/insert/…` plus RLS policies. `tools/sql-tests/test_privileges.sql` checks the catalog and the list of RPCs/tables the apps use — extend it when the apps start using a new one.

## Repo map
- `app/index.html` — phone PWA (single file, ~5k lines). `desktop/index.html` — the Desk (reconciliation, bulk edit, pots, activity, sort). `app/common.js` — shared helpers (`sb`, `$`, `esc`, money/date/country helpers).
- `supabase/migrations/*.sql` — the whole schema history (baseline dump + 29 migrations; two early data fixes are now empty stubs). Each migration is wrapped `begin; … notify pgrst, 'reload schema'; commit;`.
- `tools/sql-tests/` — `bootstrap.sql` (auth emulation on plain Postgres; skipped on the Supabase image), `fixture.sql` (skeleton of the original household — a few old data-fix migrations reference its ids), `run.sh` (stops at the first error), `test_core.sql`, `test_fund_purchases.sql`, `test_privileges.sql`, `test_card_openings.sql`.
- `tools/ci/` — `private-data-guard.sh`, `check-js.mjs` (run by the Checks workflow on every push). `tools/dev/` — `serve.mjs` + README: the apps against the local Supabase stack.
- `tools/qa-local/` — local Supabase look-alike (`shim.mjs`, PostgREST + GoTrue enough for both pages), `BRIEF.md`/`ROUND2.md` tester briefs, `README.md` for setup.
- `docs/` — architecture reviews, decision log, handover, QA round summaries (`docs/qa/`).
- `.github/workflows/` — `checks.yml` (private-data guard + JS syntax, every push), `deploy-db.yml` (Postgres 17 test → encrypted snapshot → push; CLI and actions pinned), `backup-db.yml` (weekly encrypted dump).
- `index.html`, `dashboard.html`, `welcome/` — v1 landing/legacy, leave alone.

## Database conventions (read before touching SQL)
- Two ledgers by meaning: **`expenses`** = every purchase/refund (category, card, payer, optional `fund_id`); **`fund_transactions_all`** = movements and allocations (`kind` movement | allocation | card_payment). `fund_transactions` is a *view* over `_all` hiding soft-deleted rows. Compat views `daily_expenses` / `travel_expenses` split `expenses` by `trip_id`.
- RLS reads `household_members`: `bh_member_of()` (read), `bh_writer_of()` (write: owner|member). Write RPCs resolve the household with `bh_current_household()` and raise `42501 'no household — or your login is view-only'` for viewers. Security-definer RPCs set `set_config('bh.via_rpc','on',true)` so guard triggers can tell an RPC from a raw client write. Newer guards use `current_user in ('authenticated','anon')` = a direct client write (inside a definer function `current_user` is the owner): `b0_expenses_client_guard` / `b0_fund_client_guard` clear server-owned columns on client inserts and freeze grouped fund rows (transfer sides, card-payment legs) against one-sided edits.
- Trigger order on `expenses` is alphabetical by name and matters: `b0_expenses_client_guard` → `bx_expenses_category` (name↔id sync) → `bz_expenses_fund` (fund guard) → `expenses_before_write` → `expenses_check_refs` → `expenses_lock` (reconciliation lock: amount/date/currency/card/payer/is_refund frozen; `fund_id`, category, comments free) → `expenses_soft_delete` → `zx_…_by` → `zy_expenses_stamp_pot` (`pot_fund_id = coalesce(fund_id, expense_pot_for(...))`) → `zz_…_touch` → `zza_…_splits` (derived, clients read-only) → `zzz_…_audit`.
- Views that define the money: `fund_balances` (Available), `fund_balances_cleared`, `fund_cash` (in the bank, owed on cards; includes `card_openings` the fund backs), `card_balances` (opening + charges − credits − payments, all from `pot_start`), `statement_balances`, `pot_month_spend`. Refunds: positive amount, counted negative everywhere.
- Text columns (`category`, `category_group`, `paid_with`) are display copies kept in sync both ways by triggers; ids (`category_id`, `group_id`, `payment_method_id`) are the truth.
- When you add a column the apps need, append it to the compat views too (they are `security_invoker` and rebuilt in the latest migration that touched them).
- The apps probe for optional columns at load (`reconOK swapOK updOK kindOK refundOK fundIdOK`) and degrade; keep that pattern for any new column so the Pages deploy and the DB deploy can land minutes apart.

## Local testing
- **`tools/dev/README.md`** — Docker + `supabase start` (real Postgres 17 / PostgREST / GoTrue) from `~/Code/bh-local`, migrations applied by `run.sh`, apps served by `tools/dev/serve.mjs`. Synthetic data only.
- Scratch CI run: `tools/sql-tests/run.sh "postgresql://…"` — must end with every `test_*.sql` ✓.
- The older shim harness (`tools/qa-local/`) and the Playwright scripts in Drive `QA/tools/browser/` still exist but were built for a cloud sandbox; prefer the local stack.
- Known expected noise in suites: a handful of deliberate 400/406 responses from refusal tests.

## Deploy
- Push to `main`. Pages redeploys the HTML in ~1 min. The DB Action runs on migration/test changes only.
- **Two deployers (found 15 Oct 2026):** the Supabase GitHub integration (check run "Supabase Preview") *also* applies new migrations from `main` to production, ~2 minutes before the Action's tested push — so the Action usually reports "Remote database is up to date", and production does not wait for our tests. It is also the likely cause of the old "history insert" flake (both racing). Until Aizat turns the integration's production deploy off (Supabase → Project Settings → Integrations → GitHub), treat every push to `main` with a migration as going live immediately: **run the full local suite on Postgres 17 and the local Supabase stack before pushing**, never after.
- Secrets in GitHub: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_ID`, `SUPABASE_DB_PASSWORD`, `BACKUP_PASSPHRASE` (reset 15 Oct 2026, kept in Aizat's password manager; the deploy refuses to run without it because it snapshots first). Restoring: `docs/RESTORE.md` + `tools/restore/check-restore.sql`.

## Mirror
After every sprint, mirror changed files to Aizat's Drive folder `…/My Drive/Aizat/Claude/A Personal Finance/` (same layout: `app/`, `desktop/`, `supabase/migrations/`, `QA/tools/sql-tests/`, `QA/tools/ci/`, `QA/workflows/`, `QA/`, handbook at the root). From Claude Code on his Mac that is a plain `cp` from `~/Code/bearhaus-finance`.
