# BearHaus Finance — working rules for Claude Code

Household finance PWA for Aizat & Paige (Melbourne; AUD + SGD). Owner: Aizat (not a developer — explain in plain words, point form, frank expert engagement; he gives standing authority to build without per-step sign-off once a plan is agreed).

Read in this order when you start: this file → `docs/HANDOVER.md` (state of play, what's pending) → `docs/DECISIONS.md` (why things are the way they are) → the two `docs/architecture-review-*.md`. The long-form handbook (`bearhaus-v2-rebuild-summary.md`) lives **outside the repo** in Aizat's Drive folder (see HANDOVER) because it quotes real balances.

## Hard rules
1. **Private data.** The repo is PUBLIC. Never commit real balances, statement figures, invite codes, dumps, or anything from the production database. Fund/card *names* already appear in code and tests and are fine. QA raw reports that quote real numbers go to Drive, not here.
2. **Supabase only.** No other backend, no build step, no framework. Two static pages (`app/index.html` phone, `desktop/index.html` Desk) + `app/common.js`, deployed by GitHub Pages from `main`.
3. **No copy-paste deploys.** Claude commits and pushes to `main`. Migrations under `supabase/migrations/` auto-deploy via `.github/workflows/deploy-db.yml` — *only after* the `test` job applies the whole chain from scratch and `tools/sql-tests/` pass. Never ask Aizat to paste SQL into the Supabase editor.
4. **Every sprint ends with the hygiene step** (Aizat's standing instruction, 14 Oct 2026): SQL tests extended → CI green locally (`tools/sql-tests/run.sh` against a scratch DB) → browser verification → smoke + QA suites → commit/push → confirm the Action (both jobs) → handbook section → Drive mirror → short report.
5. **Money invariants are asserted, not assumed.** A move/undo RPC that could change a fund's balance asserts before/after and refuses otherwise. Keep that pattern.
6. Don't add a framework, bundler, or TypeScript. Don't rename the compat views (`daily_expenses`, `travel_expenses`, `fund_transactions`) — both apps and every RPC read them by name.

## Repo map
- `app/index.html` — phone PWA (single file, ~5k lines). `desktop/index.html` — the Desk (reconciliation, bulk edit, pots, activity, sort). `app/common.js` — shared helpers (`sb`, `$`, `esc`, money/date/country helpers).
- `supabase/migrations/*.sql` — the whole schema history (baseline dump + 27 migrations). Each migration is wrapped `begin; … notify pgrst, 'reload schema'; commit;`.
- `tools/sql-tests/` — `bootstrap.sql` (auth emulation, roles, extensions), `fixture.sql` (skeleton of the original household — a few data-fix migrations reference its ids), `run.sh`, `test_core.sql`, `test_fund_purchases.sql`.
- `tools/qa-local/` — local Supabase look-alike (`shim.mjs`, PostgREST + GoTrue enough for both pages), `BRIEF.md`/`ROUND2.md` tester briefs, `README.md` for setup.
- `docs/` — architecture reviews, decision log, handover, QA round summaries (`docs/qa/`).
- `.github/workflows/` — `deploy-db.yml` (test → push), `backup-db.yml` (weekly encrypted dump; needs `BACKUP_PASSPHRASE`).
- `index.html`, `dashboard.html`, `welcome/` — v1 landing/legacy, leave alone.

## Database conventions (read before touching SQL)
- Two ledgers by meaning: **`expenses`** = every purchase/refund (category, card, payer, optional `fund_id`); **`fund_transactions_all`** = movements and allocations (`kind` movement | allocation | card_payment). `fund_transactions` is a *view* over `_all` hiding soft-deleted rows. Compat views `daily_expenses` / `travel_expenses` split `expenses` by `trip_id`.
- RLS reads `household_members`: `bh_member_of()` (read), `bh_writer_of()` (write: owner|member). Write RPCs resolve the household with `bh_current_household()` and raise `42501 'no household — or your login is view-only'` for viewers. Security-definer RPCs set `set_config('bh.via_rpc','on',true)` so guard triggers can tell an RPC from a raw client write.
- Trigger order on `expenses` is alphabetical by name and matters: `bx_expenses_category` (name↔id sync) → `bz_expenses_fund` (fund guard) → `expenses_before_write` → `expenses_check_refs` → `expenses_lock` (reconciliation lock: amount/date/currency/card/payer/is_refund frozen; `fund_id`, category, comments free) → `expenses_soft_delete` → `zx_…_by` → `zy_expenses_stamp_pot` (`pot_fund_id = coalesce(fund_id, expense_pot_for(...))`) → `zz_…_touch` → `zza_…_splits` (derived, clients read-only) → `zzz_…_audit`.
- Views that define the money: `fund_balances` (Available), `fund_balances_cleared`, `fund_cash` (in the bank, owed on cards), `card_balances`, `statement_balances`, `pot_month_spend`. Refunds: positive amount, counted negative everywhere.
- Text columns (`category`, `category_group`, `paid_with`) are display copies kept in sync both ways by triggers; ids (`category_id`, `group_id`, `payment_method_id`) are the truth.
- When you add a column the apps need, append it to the compat views too (they are `security_invoker` and rebuilt in the latest migration that touched them).
- The apps probe for optional columns at load (`reconOK swapOK updOK kindOK refundOK fundIdOK`) and degrade; keep that pattern for any new column so the Pages deploy and the DB deploy can land minutes apart.

## Local testing
- Scratch CI run: `createdb bh_ci2 && tools/sql-tests/run.sh "postgresql://…/bh_ci2"` — must end with both `✓` lines.
- Full product locally: see `tools/qa-local/README.md` (Postgres on `/tmp:55432`, `start.sh`, app at `http://127.0.0.1:54321/app/`, Desk at `/desktop/`). Login for the seeded copy is in that README. Browser tests are Playwright scripts; the ones kept are in Drive `QA/tools/browser/` (phase2/phase3/round2fix) and the Drive `QA/` folder.
- Known expected noise in suites: a handful of deliberate 400/406 responses from refusal tests.

## Deploy
- Push to `main`. Pages redeploys the HTML in ~1 min. The DB Action runs on migration/test changes only. A known flake: `supabase db push` sometimes fails on its own history insert *after* the SQL applied — rerun the failed job; it reports "up to date". The workflow echoes the push log tail as an annotation.
- Secrets in GitHub: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_ID`, `SUPABASE_DB_PASSWORD`; `BACKUP_PASSPHRASE` still to be added by Aizat.

## Mirror
After every sprint, mirror changed files to Aizat's Drive folder `…/My Drive/Aizat/Claude/A Personal Finance/` (same layout: `app/`, `desktop/`, `supabase/migrations/`, `QA/tools/sql-tests/`, `QA/tools/browser/`, `QA/`, handbook at the root). From Claude Code on his Mac that is a plain `cp`.
