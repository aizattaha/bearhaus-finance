# BearHaus — decision log

One line per decision: what was decided, why, and where it lives. Newest at the bottom of each section. Dates are when it shipped. "Aizat" = product owner's call; "Claude" = engineering call Aizat accepted. Older history (Jul–Sep 2026 rebuild, sprints 1–6) is in the Drive handbook; this log starts where the October architecture work starts.

## A · Architecture (Oct 2026 review — `docs/architecture-review-2026-10.md`)

| # | Decision | Why | Where |
|---|---|---|---|
| A1 | **One `expenses` table** for daily + travel rows; `daily_expenses` / `travel_expenses` stay as updatable compat views split by `trip_id`. | Two near-identical tables had drifted; every rule (locks, audit, soft delete, refunds) would otherwise be written twice. Views keep both apps and all RPCs unchanged. | `20261014000000_expenses_merge` |
| A2 | **Pot stamped at write time** (`expenses.pot_fund_id`), not resolved in every view. | Budget lines move between months; a purchase must keep counting against the pot it was made under. `restamp_pots` exists for deliberate re-stamps. | `20261014010000_pot_stamp` |
| A3 | **Credit cards are liabilities; a purchase is the budget event, paying the card is the cash event.** Every pot shows *Available · owed on cards · in the bank*. Paying a card never changes Available. | Removes the double count between "spent" and "paid the bill"; gives Aizat the "in the bank" number he reconciles against. | `20261014020000_card_payments`, views `fund_cash`, `card_balances`, `statement_balances` |
| A4 | `fund_transactions.kind` = movement \| allocation \| card_payment; card payments carry `settles_payment_method_id` / `settles_statement_id`; legs split by fund with the Desk proposing the split from the ticked rows. | Plan writes, transfers, swap legs are bookkeeping, not cash; the card payment needs to know which fund's cash left. | same |
| A5 | **Identity = `household_members`** (owner \| member \| viewer); one household per login; every RLS policy reads it; `bh_member_of()` read / `bh_writer_of()` write. Partner joins with a `JOIN-XXXX-XXXX` code tied to a person; view-only invites for an accountant/parent. | Paige needs her own login without sharing a password; a viewer role was cheap to add at the same time. | `20261014030000_members_audit` |
| A6 | **Audit log** on every ledger and settings table (not splits); `created_by/updated_by`. Starts 14 Oct 2026, nothing backfilled. | "Who changed what" was unanswerable before. | same; Desk → Activity |
| A7 | **Categories by id** (`category_groups`, `categories.group_id`, `expenses.category_id`, `category_budgets.category_group_id`); text columns kept as display copies synced both ways by triggers. | Renames used to orphan budget lines and the pot mapping. Keeping the text columns meant zero client changes on day one. | `20261014040000_category_ids` |
| A8 | **Refunds** = `is_refund` flag, amount stays positive, every view counts it negative. | One sign convention everywhere; the statement shows it as a credit; no negative amounts in the data. | `20261014050000_hygiene` |
| A9 | **Splits are derived** by trigger from payer + amount; clients may only read `expense_splits`. | 131 rows disagreed with their payer; nothing should be able to drift again. | same |
| A10 | **Soft delete** (`deleted_at`); `fund_transactions` becomes a view over `fund_transactions_all`; transfers and card payments delete as a unit; 30-day bin; only `purge_deleted` may hard-delete, and only non-manually-reconciled rows. | Undo for fat fingers without touching reconciliation. | same |
| A11 | **Reconciliation lock** freezes amount/date/currency/card/payer/refund on a reconciled row; description, category, comments and (later) `fund_id` stay editable; a row on a *closed* statement can't be binned until reopened. The lock cannot be bypassed by clearing `reconciled_at` in the same UPDATE. | A statement that has been agreed with the bank must stay agreed; classification can still be fixed. | batch1 + hygiene migrations, `test_core.sql` |
| A12 | **SQL tests gate production.** `deploy-db.yml` applies every migration from nothing to a scratch Postgres and runs `tools/sql-tests/` before `supabase db push`. `20261009000000_itemised_history` is skipped in that run (data-only rewrite of a superseded view). | Migrations used to be verified only on the local copy. | `.github/workflows/deploy-db.yml`, `tools/sql-tests/` |
| A13 | **Weekly encrypted backup** as a workflow artifact (gpg symmetric, 90 days); refuses to run without `BACKUP_PASSPHRASE`. Supabase PITR not bought (Aizat's call pending). | Public repo + personal finances → never a plaintext dump anywhere. | `.github/workflows/backup-db.yml` |
| A14 | `app/common.js` shared by both pages; **still no build step**. | Duplicate helpers had diverged; a bundler is not worth it for two files. | `app/common.js` |

## B · The ledger question (Oct 2026 — `docs/architecture-review-2026-10-ledger.md`)

| # | Decision | Why | Where |
|---|---|---|---|
| B1 | **Not one table.** Option C: `expenses` = every purchase and refund whatever fund pays; `fund_transactions` = movements and allocations only. Rejected A (god table) and B (double-entry) — the defect was purchases living in the movements table, not two tables. Aizat approved phases 1–3, deferred 4. | Matches the money; additive; both apps keep working the day it lands. | review doc, Part 1 |
| B2 | `expenses.fund_id` = "count this against *that* fund instead of the pot rule"; stamp = `coalesce(fund_id, pot rule)`; guard: same household, same currency, not a trip row. Fund-funded purchases are **excluded from the month's budget** sums (shown as "paid from funds, not counted") but listed under their category with a 💰 tag. | A car service from the Car Fund is not budget money, but it is still a Car purchase on a card. | `20261014060000_fund_purchases` (phase 1) |
| B3 | Historical "money out of a fund" rows are **sorted by a human** on the Desk (Sort fund spending) with a suggestion per row; moves are id-preserving, carry reconciliation marks, and **assert the fund balance unchanged**; reversible (`move_expense_to_fund_spend`). | ~350 rows; I can't know which SGD outflows were purchases. | same; Desk → Sort fund spending |
| B4 | Phone **＋ → Expense** = Daily · From a fund · Trip; the old no-card form moves to **Transfer → Money out**. Edit sheet exposes *counts against*. `save_expense(p_set_fund, p_fund_id)` — the fund changes only when the client says so (an old client can't clear it). | Nobody should need the movement form for a purchase again. | `20261014070000_fund_purchases_ui` (phase 2) |
| B5 | Phase 3 was **verification only** (bank statement view, fund tag on card rows, payment split with a fund leg) — the code paths from phases 1–2 already covered it. | — | `docs/qa/2026-10-14-round-2.md` |
| B6 | **Phase 4 deferred**: "in the bank per real bank account" (`funds.account_payment_method_id` + a Bank balances page) only if a month of living with 1–3 shows it is needed. | Cash is per fund today; may be enough. | review doc, Phase 4 |

## C · Product / UX calls

| # | Decision | Why | Where |
|---|---|---|---|
| C1 | Cash can be chosen for any payer; cash rows auto-reconcile; a reconciled row explains itself and offers *unlock* in the sheet. | QA round 1 blockers. | round-1 batch |
| C2 | Desk confirms use an in-page dialog (`ask()`), never `confirm()`; phone destructive actions are two-tap. | QA round 1. | both pages |
| C3 | Statements open on the most recent period **with rows**; "± 5 days" margin and "include earlier unreconciled" toggles; rows reconciled on *another* statement are hidden from an open one; a closed statement shows exactly its rows. | Aizat's reconciliation feedback (14 Oct). | Desk → Statements |
| C4 | Desk tables: Description gets the room; Who/Source hide under 1180 px. | Aizat's screenshot feedback. | Desk CSS |
| C5 | **Joint payer may sit on anyone's card** (joint cards first); cards in the purchase's currency come first; ✈️ travel-only is a per-card toggle in Settings. | QA round 2 A-B4 / B-B3. | phone `cardOptions` |
| C6 | **Writers (not only the owner) can invite logins.** Left as is after round 2 flagged it — *open question for Aizat*. | Convenience for a couple; owner-only is a one-line change (`create_member_invite` + People screen). | `members_audit` |
| C7 | Deleting one side of a transfer deletes **both** sides (bin restores both) — said plainly rather than refused. | A half-transfer is never valid; refusing just adds a step. | phone edit sheet |
| C8 | Viewer logins see a banner and no ＋ button; RLS/42501 errors are mapped to "this login is view-only". Invite codes readable by writers only. | QA round 2 C-B1/C-B3. | `20261014080000_qa_round2`, both pages |
| C9 | Card-payment split: unexplained statement remainder goes to the **spending pot** leg, never a named fund. | QA round 2 B-B1 (Car Fund "paid" Float's charges). | Desk `defaultLegs` |
| C10 | Sort → undo restores each row's **original card** (`p_cards`). "Send back to fund movements" from Transactions keeps the card (it *was* a card purchase). | QA round 2 B-B2 vs. design intent. | `move_expense_to_fund_spend(p_ids, p_cards)` |
| C11 | A refund entered with no category takes the default category (same as Daily). Not changed. | Low value; Daily behaves the same. | — |
| C12 | Every successful save refreshes Budget / Funds / All transactions if they were visited; returning to the app after ≥ 60 s refetches the visible tab. No realtime. | Two phones, one household; realtime not worth its complexity yet. | phone `done()`, `visibilitychange` |

## D · Process

| # | Decision | Where |
|---|---|---|
| D1 | Claude commits and pushes; no copy-paste deploys (Aizat, Oct 2026). | `CLAUDE.md` rule 3 |
| D2 | Every sprint ends with the hygiene step (Aizat, 14 Oct 2026). | `CLAUDE.md` rule 4 |
| D3 | QA = three independent tester personas on the local harness, isolated, with SQL cross-checks; raw reports that quote real balances stay in Drive. | `tools/qa-local/BRIEF.md`, `ROUND2.md`, `docs/qa/` |
| D4 | Handbook (`bearhaus-v2-rebuild-summary.md`) is the narrative record and lives in Drive, not the public repo. This log + `HANDOVER.md` are the in-repo record. | Drive folder |

## E · v2 (Oct 2026 review — plan in Aizat's Drive, `Reports/2026-10 v2 review/00-CTO-v2-plan.md`)

| # | Decision | Why | Where |
|---|---|---|---|
| E1 | **Six-specialist review → two phases × four sprints, QA gate in every sprint.** Phase 1 "safe, correct, ready for Paige"; phase 2 "fast, structured, travel-ready, beta-ready". Option B (double-entry) still not built; instead balanced server-side money events + a read-only ledger view later. | Every reviewer found the core design sound; the problems were at the joins and in the client. | Drive plan |
| E2 | **Contain the leak first.** The two data migrations that held real figures are empty stubs (same filenames — production tracks versions); round-1 raw reports and an email removed; real figures in docs/tests replaced by made-up ones. History clean-up / hosting move waits for Aizat's call (plan §6). | Pages served them as web pages. | `18a925a` |
| E3 | **Private-data guard + JS syntax check on every push**; real-household data fixes never ship as migrations (`supabase/data-fixes/README.md`). | Make rule 1 enforced, not remembered. | `tools/ci/`, `checks.yml` |
| E4 | **CI fails fast and matches production**: `run.sh` stops at the first error (it swallowed failures); Postgres 17; Supabase CLI pinned 2.120.0; actions pinned by SHA; one deploy at a time; encrypted snapshot before every push. | A green CI must mean the chain applied. | `run.sh`, `deploy-db.yml` |
| E5 | **Privilege lockdown**: no default EXECUTE/table rights for the API roles (every migration grants explicitly); anon runs only `check_invite`/`invite_info`; `restamp_pots`/`seed_default_categories` server-only; `bh_category_for`/`bh_group_for` check the caller writes to the household; members can't change the owner, `pot_start` or delete the household; no client TRUNCATE. | Four definer helpers were callable by anyone with the public key, against any household. | `20261015000000_privilege_lockdown` |
| E6 | **Server-owned columns can't be forged by a direct client write** (reconciliation marks, bin date, pot stamp, created_by), and **grouped fund rows are frozen against one-sided edits** (amount/date/fund/type/kind/group); the phone dims those fields and saves only the note. Guard = `current_user` is an API role. | One side of a transfer could be edited alone (money created/destroyed); a client could insert pre-reconciled rows. | same + `app/index.html` |
| E7 | **Card opening positions** (`card_openings`: what a credit card owed on `pot_start`, and the fund that backs it): `card_balances` adds it and counts payments from `pot_start` like purchases; `fund_cash` adds it to the backing fund's cash. Available never moves. Set once per card on the Desk. | Paying the first statement after 1 Sep pushed cards and pots below zero. | `20261015010000_card_openings`, Desk Statements |
| E8 | **Statement import**: "new spend" excludes the card-payment lines; the difference check compares it with ticked spend (payments excluded); select-all takes only unreconciled rows inside the period; the date margin reaches back 5 days only; archived cards are listed (own group) for reconciling. | False "something is ticked" alarm and an underpaid proposal on every catch-up statement. | Desk |
| E9 | **Fund purchases and edits offer travel-only cards** (SG cards appear for an SGD fund). Stop-gap: sprint 2 replaces "travel only" with per-card Daily · Trip · From-a-fund choices, per-person defaults per context, archived cards refused by the database except Desk overrides (Aizat, 15 Oct; "More cards…" row confirmed). | Aizat couldn't tag his SG cards on fund purchases. | phone `cardOptions` |
