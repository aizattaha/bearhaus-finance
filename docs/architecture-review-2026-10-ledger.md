# BearHaus — the ledger question: one table, or two by meaning?
*Senior data architect's recommendation + CTO build plan · 14 Oct 2026*

Trigger: **a car-parts purchase** sits in the Car Fund's history as a *fund movement*, but it was bought on a credit card. Today a fund spend cannot name a card, so it never appears on the card's statement, is never reconciled, and the Car Fund shows no "on cards / in the bank" line. Aizat's question: should daily expenses and fund movements become **one table**?

---

## Part 1 — Senior data architect

### 1.1 What the two tables actually hold today

| Table | Rows (BearHaus) | What they are |
|---|---|---|
| `expenses` | 2,672 | **Purchases**: something was bought. Category → group → pot; card; payer; refund flag; trip. The *budget event*. |
| `fund_transactions` | 1,134 | A mix of four things, told apart by `kind`/`type`: |
| · `allocation` | 423 | plan writes, transfers between funds, travel sends, pot-swap legs — bookkeeping, no cash moves |
| · `movement` in | 355 | salary, interest, dividends, opening balances — cash arriving |
| · `card_payment` | 0 so far | paying a card from a fund (built yesterday) |
| · `movement` out | **356** | **the muddle** — see below |

The 356 "money out of a fund" rows are not one thing:

| Looks like | Examples in the data | Is it a purchase? |
|---|---|---|
| a purchase funded from a non-pot fund | Car parts, Vic Roads (Car Fund) · Shopee, Apple, Vapes (Monthly Expenses) · insurance premiums (DreamHouse SG) | **yes** — it should carry a card, a category, a payer, and sit on a statement |
| an investment / transfer to a real account | Stashaway, "For Serious Business" reimbursements, Pruwealth | **no** — money moved to another place; no card, no category |
| a settlement to a person | "Transferred 4 Jan 2026 (shortfall …)" | no — a movement |

So the real defect is not "two tables"; it is that **purchases are allowed in the movements table**. A purchase has a card, a merchant, a category, a payer and a statement; a movement has none of those. They were forced into one shape because the phone's *Fund* form was the only way to spend from a non-pot fund.

### 1.2 The three options

**A · One table for everything ("the god ledger").** Union of both column sets, every column nullable, a `kind` column and a CHECK constraint per kind to say which columns are allowed.
- For: one place for statements, locks, audit, soft delete, refunds; one set of RPCs.
- Against: a row's meaning lives in a CHECK constraint; every query starts with `where kind in (…)`; fund balances, pots, settle-up and the budget tab all become filters over a table where half the columns are null for half the rows. Every screen in both apps is rewritten for no behavioural gain — statements, locks, audit and soft delete already work across both tables today (the Desk reconciles both; the audit log and the bin hold both).
- Verdict: **no**. We would be merging two *shapes* because one *row* is in the wrong place.

**B · Proper double-entry** (journal + postings, cards and funds as accounts).
- For: textbook; nothing can ever be in the wrong place; card liability falls out naturally.
- Against: a full rewrite of 24 migrations' worth of views and both apps; the pot stamping and the three-numbers views already give us the parts of double-entry a household needs (budget view, cash view, card liability). The cost is weeks; the benefit over what exists is academic at this scale.
- Verdict: **not now**. Keep it as the shape to grow into if BearHaus becomes multi-tenant with accountants as users.

**C · Two tables, split by meaning, not by screen** — *recommended*.
- **`expenses` = every purchase and refund**, whatever fund pays for it. Today a purchase can only count against a *spending pot* (via its category's budget line). Add one nullable column, **`fund_id`** = "count this against *that* fund instead of the pot rule". Car parts becomes: category Car · card Visa · payer Aizat · **fund Car Fund**. It appears on the Visa statement, is reconciled like any purchase, and the Car Fund gets the same three numbers as a pot (Available · on cards · in the bank).
- **`fund_transactions` = movements and allocations only**: income in, transfers, plan writes, travel sends, swap legs, card payments, and "money out that is not a purchase" (an investment, a reimbursement, a bank fee). No merchant, no category, no card — exactly what the table was for.
- The 356 money-out rows get sorted once: purchase-shaped ones move to `expenses` (keeping id links, dates, reconciliation marks), movement-shaped ones stay. The sort is a one-screen job on the Desk with a suggested answer per row; nothing moves until confirmed.

### 1.3 Why C is the right cut

- **It matches the money.** A purchase is a budget event with a card behind it; a movement is cash changing place. Every rule we built this week keys off that distinction (card payments, refunds, pot stamping, statements). C makes the tables *be* that distinction instead of approximating it.
- **It is additive.** One new column, one trigger line (`pot_fund_id := coalesce(fund_id, pot rule)`), views gain `or de.fund_id = f.id`. The compatibility views, RPCs, locks, audit, bin, members — all unchanged. Both apps keep working the day the migration lands; the new UI arrives on top.
- **It fixes a second standing complaint for free.** "Fund" spending has never been categorised, so Budget and Settings → Categories know nothing about a large share of the outgoings. After C, a car service is *Transportation › Car* funded from the Car Fund — the budget pace cards exclude it (it isn't monthly budget money) but category history, search and the Desk see it.
- **It generalises the three numbers.** `fund_cash`'s formula (`cash = movements − non-card purchases`, `owed = card purchases − card payments`) already works for any fund once purchases can point at any fund. The Car Fund in the screenshot would read *Available A$X · on cards A$Y · in the bank A$X+Y* (until the card is paid).
- **It keeps the exits open.** If B is ever wanted, C's tables map onto it 1:1 (expenses → journal lines against a fund/pot and a card; movements → lines between accounts).

### 1.4 The design, precisely

```
expenses
  + fund_id uuid null references funds(id)        -- explicit "counts against this fund"
    pot_fund_id := coalesce(fund_id, expense_pot_for(...))   -- stamp trigger, one line
    constraint: fund_id's fund belongs to the household (bh_check_refs)
    rule: a fund_id row is excluded from monthly budget pace (not budget money) — the app, not the DB

fund_transactions (unchanged shape; sharper meaning)
    kind movement  · type expense  = money out that is NOT a purchase (investment, reimbursement, fee)
    everything else as today

views
  fund_balances        : for every fund, subtract expenses where pot_fund_id = f.id and date <= today
                         (pots keep the pot_start gate; explicit-fund rows count from their own date)
  fund_balances_cleared, fund_cash, pot_month_spend : same change
  card_balances / statement_balances : no change (they already read expenses by card)

one-off sort (Desk → "Sort fund spending", temporary page)
  suggestion per row: purchase if remarks look like a merchant and the fund is not an investment/tax/
  savings fund; movement if remarks match Stashaway / Pruwealth / "For Serious Business" / "Transfer" /
  the fund is an investment fund. Aizat ticks, picks a category + card per purchase (defaults: category
  "Fund spending › <fund name>" if nothing better, card "no card"), presses Move. RPC moves rows
  expenses ← fund_transactions preserving id, date, amount, reconciliation marks, created_by; audit-logged.
```

What I would **not** change: amounts stay positive with a refund flag; the two-row transfer convention; pot stamping; the compatibility views; the statements model. None of them is in the way.

### 1.5 Consequences to be honest about

- **Budget tab semantics.** A fund-funded purchase must not count against the month's budget (it is paid from a fund you already contributed to) — otherwise October's "so far" jumps by every car service. The exclusion is one filter (`!r.fund_id`) in the three budget sums; shown as a muted "+ A$x funded from funds" line so it isn't invisible.
- **Payer on migrated rows.** Fund rows have no payer; migrated purchases default to joint unless a personal card is chosen, in which case the existing trigger names the owner.
- **Plan "Into funds" is untouched.** Contributions are allocations; they stay in `fund_transactions`.
- **Income.** Salary is a movement into a fund and stays where it is. The income/plan double-count (QA F13) is a UI rule, not a table problem — merging tables would not have touched it.
- **The sort is a human step.** ~350 rows, mostly obvious; 15 minutes on the Desk with the suggestions pre-ticked. It is the one part that cannot be fully automatic without me guessing which of your SGD outflows were purchases.

---

## Part 2 — CTO build plan (four phases)

Each phase ends with its hygiene step (tests in `tools/sql-tests`, smoke + full-stack runs, handbook, Drive mirror). Effort is in working sessions of the kind we have been doing.

### Phase 1 — Purchases can name their fund *(1 session · DB + Desk sort tool)*
- Migration `expenses.fund_id`, stamp rule, `bh_check_refs`, the five views/functions, `move_fund_spend_to_expenses(ids, category, card)` RPC (id-preserving, audit-logged, reconciliation carried), `suggest_fund_spend_kind()` helper.
- Desk → temporary **Sort fund spending** page: the 356 rows with suggestion, category + card pickers, bulk Move; a "keep as movement" button. Disappears when the list is empty.
- Tests: balance invariant (every fund balance identical before/after a move), statement visibility of a moved row, budget exclusion.
- Exit: Car parts is a purchase on the Visa, Car Fund shows its three numbers, Aizat has sorted the backlog.

### Phase 2 — The apps speak the new language *(1–2 sessions · phone + Desk)*
- Phone **+ → Expense**: the *Fund* scope becomes "**from a fund**" — same form as Daily (description, category, card, payer, refund) plus a fund picker; the old "money out of fund" (no card, no category) moves under **Transfer → Money out (not a purchase)** with a one-line explanation of when to use it.
- Funds tab: every fund gets the pot treatment — *Available · on cards · in the bank* — and its drill lists purchases and movements together, purchases with their category and card.
- Budget tab: fund-funded purchases excluded from pace, shown as a muted "funded from funds" line; category drill includes them with a *from Car Fund* tag.
- Desk: ＋ add transaction gains a "counts against" fund picker; Transactions page filter "funded from fund"; bulk edit can set/clear the fund.
- Exit: nobody needs the Fund-movement form for a purchase again.

### Phase 3 — Statements close the loop on every account *(1 session · Desk)*
- Bank-account statement view: purchases paid by a bank/debit card against any fund appear beside movements (today only pot purchases do).
- Card statements: the fund a purchase counts against shows in the row (so a mixed Visa statement reads "Float · Float · Car Fund · Float").
- Card-payment split by pot/fund already works — verify with a statement containing a Car Fund purchase; the default split should propose Car Fund (its purchase) + Float the rest.
- **QA round 2**: the three personas against phases 1–3 (the scenarios that were brittle in round 1 plus: fund purchase on a card, refund, soft delete, Paige's login, viewer).
- Exit: a full month closed end-to-end on real data — every card, the uBank account, payments recorded, Pots' "in the bank" within cents of the bank.

### Phase 4 — Accounts, if we still want them *(decide after living with 1–3 for a month)*
- The remaining gap is "In the bank" **per real bank account** (uBank vs Macquarie transaction account vs UOB): today cash is per fund, not per account. Option: `funds.account_payment_method_id` (which bank account holds this fund's cash) + a Desk "Bank balances" page that sums funds per account and compares to the statement balance you type.
- Only if that proves insufficient would B (double-entry) earn its cost. My expectation: it won't.

### Order of risk
1. Phase 1 migration is additive and asserted (balances unchanged until a row is *moved*; each move is asserted to leave the fund's balance identical).
2. The sort is reversible: a moved row can be sent back by the same RPC in reverse until phase 3 closes.
3. Phase 2 is UI only. Phase 3 is UI + testing. Nothing in 1–3 touches identity, reconciliation locks or the card-payment model built this week.

**Recommendation:** approve option C and phases 1–3; defer 4. Say "go" and Phase 1 starts.
