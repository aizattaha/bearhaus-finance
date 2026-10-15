# BearHaus — handover (15 Oct 2026, updated after v2 sprint 1)

Written for the next engineer (Claude Code on Aizat's Mac). Read `CLAUDE.md` first, then this, then `DECISIONS.md`.

## 1 · What it is
- Household finance PWA for two people, two countries (AUD + SGD). Phone app (`app/`) for capture and the daily/monthly view; **Desk** (`desktop/`) for reconciliation against bank/card statements, bulk edits, pots, activity, and the one-off "Sort fund spending" job.
- Supabase (Postgres + RLS + security-definer RPCs; PostgREST from the browser with the publishable key). Static hosting on GitHub Pages from `main`: `https://aizattaha.github.io/bearhaus-finance/app/` and `/desktop/`.
- Users: Aizat (owner) and Paige (member — **login not yet created**, see §5).

## 2 · State of production (v2 sprint 1)
- **v2 is under way.** The review panel's plan (2 phases × 4 sprints, QA gate per sprint) is in Aizat's Drive: `Reports/2026-10 v2 review/00-CTO-v2-plan.md`. Sprint 1 shipped: data-leak containment, fail-fast CI, privilege lockdown, transfer guard, statement-import and select-all fixes, card opening positions, SG cards for fund purchases. See DECISIONS §E.
- Schema: baseline + 29 migrations, last `20261015010000_card_openings`. The Action's `test` job applies the chain from scratch on Postgres 17 (as production).
- The October architecture review is **fully implemented** (items 1–6); the ledger plan **phases 1–3 are shipped**; phase 4 deferred.
- QA round 2 (three testers) — every finding fixed and verified; summary in `docs/qa/2026-10-14-round-2.md`.
- Known production-data facts the next engineer should know (no numbers here on purpose): the 356 historical "money out of a fund" rows are **still unsorted** — Desk → Sort fund spending is waiting for Aizat; no real card payments have been recorded yet, so every card shows its charges since `pot_start` (1 Sep 2026) as owed; HSBC's closing day (2) and the other cards' closing days are not set yet.

## 3 · How the money works (10 lines)
1. A **purchase** (category, card, payer) lives in `expenses`. It counts against a fund: its category's spending pot by default (`pot_fund_id`), or the fund it names (`fund_id`).
2. A **movement/allocation** (income in, transfer, plan write, travel send, swap leg, card payment, "money out that is not a purchase") lives in `fund_transactions_all` (view `fund_transactions`).
3. **Available** (`fund_balances`) = movements in − allocations out − purchases counted against the fund (card payments excluded).
4. **In the bank** (`fund_cash.cash_balance`) = movements − non-card purchases − card payments. **Owed on cards** = card purchases − card payments. In the bank = Available + owed.
5. A card payment is recorded once, from one or more funds (`record_card_payment` legs), optionally against a statement; it never changes Available.
6. Refunds: positive amount + `is_refund`, counted negative everywhere.
7. Statements: Desk ticks rows → `reconcile_rows` (lock); close → rows hidden from later periods; opening + ticked = closing check; payment panel proposes legs from the ticked rows (remainder → spending pot).
8. Fund-funded purchases are **not** monthly budget money: excluded from Budget sums/pace, shown as "paid from funds".
9. Splits (`expense_splits`) are derived from payer + amount; settle-up reads them.
10. Soft delete everywhere; transfers and card payments delete/restore as a unit; purge after 30 days.

## 4 · What Aizat still has to do (reminded repeatedly; unchanged)
1. ~~Backup passphrase~~ — done 13 Oct; the first backup ran that day. Still to do: confirm the passphrase is long and random and in the password manager; nobody has tried a restore yet (v2 sprint 1 item 7 needs it).
2. Phone → Settings → People → **that's me** (links his login to his profile).
3. Settings → People → **invite to sign in** for Paige → send her the JOIN code; she signs up with it.
4. Settings → Payment cards → closing day per credit card (HSBC = 2; the rest as on the statements).
5. Desk → Statements → for each credit card, **first** fill *Owed on <card> on 1 Sep* (the panel under the card picker: the bank's balance owing on 31 Aug, or the first statement's opening balance plus its purchases dated before 1 Sep). Then close each statement since 1 Sep and **record the real payments** (dated when they happened). Without the opening, paying the first statement pushes the card and the pot below zero.
6. Desk → **Sort fund spending** (~15 min with the suggestions pre-filtered).
7. New habit: anything bought with a fund's money → **Expense → From a fund**, never a movement.

## 5 · Open questions for Aizat (not decided)
- **Turn off the Supabase GitHub integration's production deploy** (Supabase → Project Settings → Integrations → GitHub → "Deploy to production" off, or disconnect it). It applies migrations from `main` before our tested Action does, so production doesn't wait for the tests, and it races the Action. The Action alone should deploy.
- Should **only the owner** be able to invite logins? (Today any writer can — DECISIONS C6.)
- Supabase **PITR** add-on (paid) vs. the weekly encrypted dump — currently dump only.
- Phase 4 (bank balances per real account) — decide after a month.
- Whether to keep the **Sort fund spending** page after the backlog is empty (it hides itself when the list is empty; code can then be removed).

## 6 · Known limitations / things that look like bugs but aren't
- The app degrades when a migration hasn't landed yet (probe flags `reconOK … fundIdOK`); the phone's edit-sheet falls back to the old `save_expense` signature with a message. Both deploys (Pages, DB) are independent and can land minutes apart — by design.
- `supabase db push` has twice failed on its own history insert after the SQL applied (passes 3 and phase 2). Rerun the failed job → "Remote database is up to date". The workflow prints the push log tail as an annotation.
- Deleting one side of a transfer deletes both (said plainly in the sheet).
- Activity shows a Sort move as "expense deleted + fund row added" (same id).
- No realtime: a partner's new rows appear on save/refetch (≥ 60 s away) or reload.
- Exchange rates: the app fetches frankfurter.app for pot swaps; blocked in the sandbox, fine in production.
- A view-only or member login can no longer change the household's owner or delete it; the public app key can run only the two sign-up checks (v2 sprint 1). One side of a transfer (or a card-payment leg) can't be edited on its own — the phone shows those fields dimmed.
- Desk `Pots` lists spending pots plus any other fund with money on cards.

## 7 · Local development & QA
- **Since v2 sprint 1: `tools/dev/README.md`** — the real Supabase stack on this Mac (Docker + `supabase start` from `~/Code/bh-local`), migrations by `run.sh`, apps via `tools/dev/serve.mjs`, synthetic data only. The working git clone is `~/Code/bearhaus-finance`. The notes below describe the older cloud-sandbox harness.
- **Scratch CI run** (what the Action does): `createdb bh_ci2 && tools/sql-tests/run.sh "postgresql://…/bh_ci2"` — expect `✓ test_core.sql` and `✓ test_fund_purchases.sql`. Needs Postgres 16 with `psql`.
- **Whole product locally**: `tools/qa-local/README.md`. Requires a Postgres copy of the schema (restore the latest Drive backup, then apply any newer migrations), `setup.sql`, `start.sh` → `http://127.0.0.1:54321/app/` and `/desktop/`. The shim emulates PostgREST/GoTrue; `VIEW_BASE` inside it maps writes to compat views onto their base tables — extend it if you add a view the apps write to.
- **Browser verification scripts** (Playwright): Drive `QA/tools/browser/` (`phase2.mjs`, `phase3.mjs`, `round2fix.mjs`, plus the round-1/2 batch and feature scripts). **Smoke harness** (no DB — a mock Supabase client fed by a JSON snapshot of the real data, so it stays in Drive): `QA/tools/smoke/` — `run.mjs` (phone) and `desk.mjs` (Desk) inline `common.js`, write `serve/app.html` / `serve/desk.html`, expect `python3 -m http.server 8766 --directory serve`, and print a long log ending in `ERRORS (0)` / `no console/page errors`. Both suites take ~2 min and are the fastest regression check for UI changes.
- **QA rounds**: three persona agents, briefs in `tools/qa-local/BRIEF.md` + `ROUND2.md`; summaries in `docs/qa/`; raw round-2 reports in Drive `QA/round-2/` (they quote real balances).
- Expected noise in suites: deliberate 400/406 responses from refusal tests.

## 8 · Where things live outside the repo
- Drive folder (synced on Aizat's Mac): Aizat's Google Drive → `My Drive/Aizat/Claude/A Personal Finance/`
  - `bearhaus-v2-rebuild-summary.md` — the long-form handbook, every sprint since Jul 2026, newest section first (Oct 2026 sections: architecture passes 1–4, ledger phases 1–3, QA round 2).
  - `app/`, `desktop/`, `supabase/migrations/` — mirrors of the repo.
  - `QA/` — round summaries, raw reports, `tools/sql-tests/`, `tools/qa-local/`, `tools/browser/`.
  - `Backups/` — schema + data dumps used to seed the local copy. **Private.**
  - `Bank Accounts & Credit Cards/` — Aizat's statements (used for import testing). **Private.**
- GitHub secrets: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_ID` (`diqaezhdxloqhglndqrq`), `SUPABASE_DB_PASSWORD`; `BACKUP_PASSPHRASE` pending.
- Supabase project ref `diqaezhdxloqhglndqrq` (publishable key is in `app/common.js`; RLS does the protecting).

## 9 · If you only do three things
1. Keep the hygiene step (CLAUDE.md rule 4) — it is what has kept production clean through 13 migrations in two days.
2. Never put a real number in the repo.
3. When Aizat says "go", he means: build the agreed plan end to end, verify, deploy, report in point form.
