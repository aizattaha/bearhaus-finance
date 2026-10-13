# BearHaus Finance — architecture review and the credit-card question

*Written 14 Oct 2026, from the schema as deployed (17 tables, 2 views, 23 functions, 20 triggers, 52 indexes, 18 RLS policies) and the two single-file front ends. Facts below were checked against a copy of the database; opinions are mine.*

---

## Part 1 — What I would improve, as the database architect

### 1.0 What is right and should stay

- **Household as the tenant.** Every table carries `household_id`, every policy is "own household only", every RPC resolves the household from `auth.uid()`. This is the correct unit for a shared-finance product and it survived an adversarial tester without a single cross-household leak.
- **Invariants live in the database.** Locks, cash auto-tick, payer-follows-card, same-household references, one-household-per-login, pair deletes — all triggers or constraints, so the phone, the Desk and any future client get the same behaviour for free.
- **Multi-row writes are RPCs** (`save_expense`, `reconcile_rows`, `record_pot_swap`, `create_household_setup`): one transaction, one place to reason about.
- **Migrations as code, deployed by the repo.** The Action-driven `supabase db push` plus the local full-stack harness is a better release path than most small products have.
- **The Scheduled rule** (a row dated after today exists but counts nowhere) is a clean idea and, since batch 1, is applied uniformly.

### 1.1 The model's one real fault line: two ledgers in one table

`fund_transactions` holds two different things:

| What | Examples | Is money moving? |
|---|---|---|
| **Movements** — cash that actually changed hands | salary in, insurance premium out, a BPAY to the card | yes — shows on a bank statement |
| **Allocations** — the household's own bookkeeping | plan writes ("Rent — spending budget"), transfers between pots, "Travel: trip" sends, pot-swap legs | no — purely internal |

They are told apart today by *convention* (`origin = 'planned'`, remarks starting `Transfer →`, remarks containing `Pot swap ·`, `income_source` not null) rather than by a column. Every view and the Desk's bank-statement page re-derive the distinction with pattern matches, and each new feature adds another pattern. This is also the root of the credit-card question in Part 2: a spend pot's balance currently mixes *budget* (every charge the day it happens) with *cash* (money in the bank), so there is no honest place to put a card payment.

**Recommendation (highest value, moderate effort):** make it a column and a rule.

```
fund_transactions.kind  text not null check (kind in
   ('movement',      -- real cash in/out of the household: salary, premium, card payment, bank fee
    'allocation',    -- internal: plan writes, pot-to-pot transfers, travel sends, swap legs
    'card_payment')) -- a movement that settles a card (see Part 2) — kept distinct for the liability math
```

Backfill from the existing conventions (I can do it exactly), then the views become `sum(... where kind = …)` instead of regex, and the bank-statement page simply lists `movement` rows.

### 1.2 Categories are referenced by name

`daily_expenses.category`, `travel_expenses.category` and `category_budgets.category_group` are **text**, matched by name to `categories.name` / `group_name` at read time (`GROUP_OF` is built in the browser). Renaming a category or group therefore either orphans history or needs a sweep (the group-rename does a sweep today). Pot mapping (`expense_pot`) also joins on names.

**Recommendation:** `category_id uuid references categories(id)` on both expense tables and `category_group_id` on `category_budgets` (groups become rows in a small `category_groups` table). Keep the text columns as denormalised display copies for one release, backfill by name, then make the ids authoritative. The budget line → pot mapping then survives any rename, and the "custom budget line with no category" case (QA B-B8) becomes impossible by construction — a budget line *is* a group.

### 1.3 Daily and travel expenses are two copies of one table

`daily_expenses` and `travel_expenses` differ by one column (`trip_id`) and one flag (`sent_to_fund`), yet every feature is written twice: two splits tables, two branches in `save_expense`, `reconcile_rows`, `bh_check_refs`, two selects on every Desk page, `p_kind` everywhere.

**Recommendation:** a single `expenses` table with `trip_id uuid null` (null = daily) and `sent_to_fund`. Migration is mechanical (insert-select both tables with a `kind` column, repoint FKs, replace the two old tables with **views of the same names** so the current app keeps working while screens are moved over). Halves the surface area of every future change.

### 1.4 Splits carry no information

Both splits tables are written as "payer +amount, joint −amount" — a deterministic function of `payer_profile_id` and `amount`. They are read only for settle-up, which could compute the same thing from the payer. Either make splits real (actual shares between people — a feature the testers asked about) or drop the tables and derive. I would drop them now and bring back real splits if the feature is wanted; it removes a write, a trigger surface and a failure mode.

### 1.5 "Payment" is an overloaded category

`category = 'Payment'` currently means *settle-up between the two of you*, *card bill payment* and *refund* (43 rows, Feb 2024 → Jan 2026, descriptions like "Aizat&Paige paid Paige"). Each needs different treatment (settle-up is an allocation; a card payment is a movement; a refund is a negative expense). Part 2 gives card payments a home; refunds deserve a `is_refund` flag (amount stays positive, sign handled in views); settle-ups become `allocation` transfers.

### 1.6 Identity: one login per household

`households.owner_user_id` is the only link to auth. Paige is a *profile*, not a login — fine for today, a wall for the SaaS goal and for "who changed this".

**Recommendation:** `household_members (household_id, user_id, profile_id null, role check in ('owner','member','viewer'))`, RLS predicates rewritten as `household_id in (select household_id from household_members where user_id = auth.uid())`, and `created_by / updated_by uuid` on the ledger tables (auth.uid() via trigger). The single-owner index from batch 1 becomes "one owner row per household". This is the one change that is cheaper the earlier it's done, because every policy and RPC touches it.

### 1.7 Balances are computed by scanning, with a function call per row

`fund_balances` evaluates `expense_pot(household, category, currency, date)` for **every daily expense of every spend pot on every read**. On the local copy that is 267 ms for 41 funds; it grows with history and the phone reads it on the Funds tab, the Budget tab and after every save.

**Recommendation:** decide the pot **at write time**. Add `pot_fund_id uuid` to expenses, set by the before-write trigger (same `expense_pot` rule), and re-stamp a month's rows inside `save_month_plan` when budget lines change (the only event that moves a mapping). Balances become indexed sums — single-digit milliseconds — and the row itself records *which pot it counted against*, which is also what Part 2 needs. A monthly rollup table (`pot_months`: pot, month, spent, cleared) maintained by trigger is the next step if the household count grows.

### 1.8 Statements should carry their balances

`statements` has `statement_total` only. Add `opening_balance`, `closing_balance`, `payment_due`, `paid_at`. With those, the Desk can check *opening + spend − credits = closing* (the arithmetic I used on your HSBC PDFs) and chain statements, and Part 2 can link a card payment to the statement it settles.

### 1.9 History and recovery

- **No audit trail.** Two people edit the same ledger; batch 4 added `updated_at` and a version check, but not *who* or *what changed*. A small `audit_log (table, row_id, household_id, at, by, op, before jsonb, after jsonb)` fed by one generic trigger on the four ledger tables answers "why is Float different today" in one query. Cheap; do it.
- **Hard deletes.** A deleted expense is gone. `deleted_at` on expenses (views hide it, a 30-day "recently deleted" list restores it) is the conventional safety net.
- **Backups.** The Drive `Backups/` dump is manual. Turn on Supabase point-in-time recovery (or at least daily scheduled dumps to Drive via the Action) before anyone else's household lives in this database.

### 1.10 Application layer

- The phone (≈4,900 lines) and the Desk (≈1,200) duplicate helpers (`fmtMoney`, `CURSYM`, `countryTitle`, `addDays`, the Supabase constants). Extract `app/common.js` now; split screens into modules when the next big feature lands. Keep "single deploy, no build step" — it's a strength, not a debt.
- The `bh-ctx` localStorage cache holds financial data in clear on the device; it's cleared on sign-out (good). Consider holding only ids/names there and re-fetching numbers.
- Tests: the smoke suites and `tools/qa-local` are the regression net; the next step is a handful of **SQL-level tests** for the triggers/RPCs (pgTAP or plain `do $$ … assert … $$` blocks run by the Action against a scratch database) so a trigger change can't ship without the lock, pair-delete and closed-statement cases passing.

### 1.11 Priority order

| # | Change | Why first | Effort |
|---|---|---|---|
| 1 | `kind` on `fund_transactions` + card-payment model (Part 2) | unblocks the cash-vs-budget question, simplifies every view | 1 migration + Desk/app screens |
| 2 | `pot_fund_id` stamped on expenses | 50–100× faster balances; records the pot per row | 1 migration, no UI |
| 3 | `household_members` + `created_by/updated_by` + audit log | cheapest now, expensive later; needed for Paige's login and SaaS | 1 migration + login flow |
| 4 | `category_id` / `category_group_id` | rename-safe mapping, closes the custom-line gap | 1 migration + picker changes |
| 5 | merge daily/travel into `expenses` (views keep old names) | halves future work | 1 migration, screens migrate gradually |
| 6 | statement balances, refund flag, drop splits, soft delete, PITR, common.js, SQL tests | hygiene | small, as convenient |

---

## Part 2 — The credit-card question

### What you asked for, restated

1. When something is charged to a credit card, it should count against its **pot and the month's budget on the transaction date** (live tracking, accrual view).
2. The money hasn't moved yet. It moves when you **pay the card**, typically after topping up a pot/float.
3. You want the **card payment itself recorded as a line** — and if that line also hits the pot, every card purchase is counted twice.

### The principle: a credit card is a liability, and it needs its own account

Every accounting system solves exactly this with one idea: the card is a **third place money can be**, between your pot and the shop.

```
Purchase on card   →   Pot (budget)  −50.00      Card owed  +50.00      Bank: unchanged
Pay the card       →   Card owed     −50.00      Bank        −50.00      Pot (budget): unchanged
```

The purchase is the *budget* event; the payment is the *cash* event. Each is recorded once. The pot never sees the payment, and the bank never sees the purchase. There is no double count because the two lines touch different accounts — the card account is what links them.

### What BearHaus already has, in those terms

- **Pot (budget) view** = today's `fund_balances.balance`: cash in minus every expense the day it happens. That is already the accrual view you asked for in (1). Keep it.
- **Card owed** = you can already compute it: unreconciled-or-reconciled charges on a card minus payments. The `statements` table even groups them into bills. What's missing is the payment line and a place to show the liability.
- **Bank/cash view** = doesn't exist yet as a number. `Cleared` (reconciled only) was a step towards it but it is still a *budget* view (it subtracts purchases, not payments).

So the alignment is: **don't change how purchases work; add the card account and the payment line; show three numbers per pot instead of two.**

### The three numbers per pot

| Number | Formula | Answers |
|---|---|---|
| **Available** (today's "Spent" balance, renamed) | money allocated in − all expenses mapped to the pot by category (any card, cash, debit) | "How much of this pot is still free to spend?" — the budget question |
| **Owed on cards** | expenses mapped to the pot that were charged to a credit card and **not yet covered by a card payment** | "How much of the pot's spending is still sitting on cards?" |
| **In the bank** | Available + Owed on cards | "How much cash is physically in this pot right now?" |

Worked example, Float AU, October:

```
Plan applied            +1,000.00   (allocation in)
Groceries on Macquarie    −100.00   budget event: Available 900.00 · Owed 100.00 · Bank 1,000.00
Coffee, cash                −4.50   cash event too: Available 895.50 · Owed 100.00 · Bank 995.50
Pay Macquarie statement   −100.00   card payment from Float: Available 895.50 · Owed 0 · Bank 895.50
```

Available never moved on the payment; Bank never moved on the charge. One line each.

### How it maps onto the tables (small changes, no rewrite)

1. **`fund_transactions.kind`** (Part 1.1) with the value `card_payment`, plus two columns on that row: `settles_payment_method_id` (which card) and `settles_statement_id` (which bill, optional). A card payment is a normal *out* row on the pot that paid it, so bank-statement reconciliation (Desk → bank account) matches it as any other movement.
2. **Views:**
   - `fund_balances.balance` (Available) — **exclude `kind = 'card_payment'` rows**. One `where` clause. That is the whole double-count fix.
   - New `fund_cash` (In the bank) — allocations and movements **including** card payments, **minus only expenses paid by cash/debit/bank** (`payment_methods.kind <> 'credit_card'`). Credit-card expenses do not touch cash until the payment row does.
   - New `card_balances` — per card: charges − payments, and per statement: closing balance − payments against it ("paid / part-paid / unpaid").
   - `Owed on cards` per pot = `fund_cash − fund_balances`; no separate storage.
3. **Stamping the pot on each expense** (Part 1.7) makes all three views cheap and lets "Owed on cards" be split by pot exactly, since every charge knows its pot.
4. **Where the payment gets recorded:**
   - **Desk → Statements → Close statement**: the natural moment. The dialog asks "Pay $X from [Float AU ▾] on [date]?" and writes the `card_payment` row linked to the statement. Partial payments allowed (another row later). "Paid" badge on the statement.
   - **Phone → + → Transfer → "Pay a card"**: card picker + pot picker + amount (defaults to the card's current owed), for people who pay before the Desk session.
   - **Bank-statement import** (uBank etc.): the BPAY line matches the `card_payment` row like any other movement; reconciling it ties the payment to the bank statement.
5. **The SG flow stays consistent.** Pot swap moves DreamHouse SG → Float SG (allocation). Paying the UOB card is a `card_payment` from Float SG (movement). Float SG's *Available* already came down when the SGD purchase was entered; the payment only moves *Bank*.
6. **Pre-payment top-ups** ("I move money to a pot before paying it off") are what they are today: a pot-to-pot transfer (allocation). It raises *Available* and *Bank* of the receiving pot; the card payment then lowers *Bank*. Nothing double counts because the top-up is between pots, never against a card.
7. **The old "Payment" category rows** (settle-ups and historic card payments) migrate: card-payment-shaped ones become `card_payment` rows on the pot that paid them; settle-ups become allocation transfers; the `Payment` category retires from the picker (kept on history until migrated).

### What changes on the screens

- **Funds → spend pot card:** three lines — *Available* (big, the number you budget by), *Owed on cards*, *In the bank* — replacing today's single balance; Desk → Pots shows the same three plus *Cleared*.
- **Desk → Statements:** a *Paid* column/badge per statement; closing adds the payment step.
- **Phone + sheet:** one more Transfer sub-type, "Pay a card".
- **Budget tab:** unchanged — it is already the accrual view.
- **All transactions:** card payments show as `💳 → ` rows ("Paid Macquarie · from Float AU · statement 16 Aug–15 Sep").

### What I would *not* do

- Don't record card purchases twice (once at purchase, once at payment) with a flag to cancel one — every report has to remember the flag and one day one won't.
- Don't move the budget hit to payment date; it destroys monthly budgeting and the pot countdown, which is the product's core.
- Don't model the card as a *fund* with a negative balance. It is tempting (the math works) but it pollutes every fund list, plan sheet and country total with liabilities; a dedicated card view is clearer and the `payment_methods` row already exists to hang it on.

### Sequence if you say go

1. Migration: `kind` + backfill, `settles_*` columns, `pot_fund_id` stamp, `fund_cash` and `card_balances` views, `record_card_payment` RPC, `fund_balances` excludes card payments. Verified on the local copy; your Float numbers must not move (card payments don't exist yet, so Available is unchanged by construction).
2. Desk: close-statement payment step, Paid badge, Pots three numbers.
3. Phone: Pay-a-card transfer, three numbers on pot cards, card-payment rows in All transactions.
4. Migrate the 43 "Payment" rows after you confirm which were card payments and which settle-ups (I'll list them).
