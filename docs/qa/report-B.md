# QA report — Persona B ("Wei & Priya", two-country household AUD + SGD, phone for capture, Desk for the heavy work)

Screenshots: `/tmp/claude-0/-home-claude-bearhaus-finance/e03bbdd2-013a-5236-9e14-5d322a7a0b54/scratchpad/qa/B/sNN-*.png` (phone 390×844) and `dNN-*.png` (Desk 1280×860). Scripts in the same folder.

## 1. Persona & what I did
- Account `qa-b-1791609033050@test.local`, household "Wei & Priya" (id `d65aa4e0-ac53-415b-9488-84a1c9bb561c`), countries AU + SG, people Wei + Priya + joint pot. Same login on phone and Desk.
- Inspected the two-country defaults (funds, pots, cards, categories, Budget tab per country), then built what a real household needs: funds Float SG (spending pot), Future DreamHouse SG, Rainy Day AU, "Travel Fund AU" (near-duplicate on purpose), Wei pocket SG (second SG pot, to get the pot chip); cards UOB — Wei (credit, SGD, closes 20), Macquarie — Priya (credit, AUD, closes 15), DBS — Wei (bank, SGD).
- October plan with two countries: AU income 6,500 + 4,200, budgets Rent 2,400 / Daily 1,500 / Transport 300, funds 400 + 300 + 200; SG income 5,000, budget lines "Daily Expenses" 800 → Float SG and "Parents allowance" 1,000 → Wei pocket SG (via the pot chip), funds 500 + 1,500. Saved, reviewed, applied.
- Phone: 16 daily expenses across SGD/AUD, 5 cards, 3 payers, dates 20 Sep → 22 Oct (around the UOB period 21 Sep–20 Oct), two Payment-category rows (refund + card bill payment), an AUD row on the SGD card and an SGD row on an AUD debit card; 3 fund rows (salary in, bonus in, insurance premium out); trip "Tokyo" with 3 JPY lines + 1 SGD line.
- Desk → Statements: UOB periods, tick/reconcile, statement total ± one row, ± 5 days, include earlier unreconciled, lock-icon unlock, "Un-reconcile selected", close/reopen, reload; DBS bank account with fund rows; text import (5 lines) and CSV upload with Debit/Credit columns; Macquarie period.
- Desk → Transactions: filters, bulk card+category on 3 rows, "whoever owns the card", a mix including a reconciled row, "(no card)", deep link `?rows=nocard`.
- Desk → Pot swap: Lazada S$25 @ 1.12 (defaults, record, SQL, rate edit, undo), then the trip line Changi lounge S$68; Desk → Pots before/after reconciling two more rows.
- Phone again: locks in All transactions, edit amount vs category on a reconciled row, "⇄ swapped" tag, trip settle-up after the swap, Budget SG, Funds.

## 2. Bugs

**B1 · major · A two-country household gets no SGD spending pot, no SGD card and no SGD budget lines — the second country is half set up**
- Steps: onboard with AU + SG. Open Funds, Budget → Singapore, Settings → Payment cards, the plan editor.
- Expected: symmetric defaults per country: a Float per currency (marked spending pot), a cash/bank card per currency, the standard budget rows in both currency blocks of the plan.
- Actual: funds seeded = Float AU (pot) + Savings/Emergency/Travel AU + Savings/Emergency/Travel **SG — no Float SG, nothing marked as an SG pot** (`funds.is_spend_pot` true only for Float AU). Cards: Cash (AUD), Bank card — Wei (AUD), Bank card — Priya (AUD) — nothing in SGD. Budget → Singapore has no "spending pots" card at all (s06b-budget-sg.png) and the plan editor's Singapore block has no Rent/Daily/… rows, only "+ add budget line" (s15-plan-open.png; `renderPlanSheet` adds `BUDGET_ROWS` only when `cur === PC`). Until the user discovers Settings → Funds → "spending pots", an SGD budget line has nowhere to land and SGD spending counts down nothing.
- Evidence: SQL `select name,is_spend_pot from funds` right after onboarding; `payment_methods` all `currency='AUD'`; s06b, s08-settings-funds.png.
- Fix: in `create_household_setup` seed `Float <CC>` with `is_spend_pot=true` for every country and a per-currency Cash card (or make Cash multi-currency); in the plan editor emit the default budget rows for every home currency, not just the primary.

**B2 · major · Closed statement still accepts ticks and "Reconcile selected"**
- Steps: UOB — Wei, period 21 Sep–20 Oct, reconcile 4 rows, type the matching total, Close statement (confirm). Tick Shopee → Reconcile selected.
- Expected: a closed statement is read-only (checkboxes gone, buttons disabled, or a "reopen first" toast); the diff badge should stay "matches".
- Actual: checkboxes remain (6), toast `1 reconciled 🔒`, ticked jumps to S$178.40 and the badge flips to "ticked is S$45.00 more than the statement" while the chip still says `closed 10 Oct 2026`. After reload the statement is still closed and still wrong.
- Evidence: d07-uob-closed.png; console log of `B/d02-statements2.mjs` ("reconcile while closed: 1 reconciled").
- Fix: when `st.statement.closed_at` is set, render rows without checkboxes, disable Reconcile/Edit/Un-reconcile and import, and have `reconcile_rows` refuse a `p_statement` that is closed server-side.

**B3 · major · Bulk edit "(no card)" always fails with a raw constraint error**
- Steps: Desk → Transactions, tick Lazada → Edit selected → Card "(no card)" → Apply.
- Expected: row loses its card (it then shows under "— no card —"), or the option isn't offered.
- Actual: toast `couldn't update: null value in column "paid_with" of relation "daily_expenses" violates not-null constraint` (HTTP 400, `/__log` error 23502). `applyBulk` writes `paid_with: null` but the baseline schema has `paid_with text default '' not null`.
- Evidence: `B/d05-transactions.mjs` output; `supabase/migrations/20260721000000_baseline.sql:215`.
- Fix: write `paid_with: ''` (what the app itself stores for "no card") or drop the NOT NULL; same for travel_expenses.

**B4 · major · Pot-swap defaults are the developer's own fund names, so a new household gets "Savings AU → Savings AU" and a disabled button with no explanation**
- Steps: Desk → Pot swap → pick Lazada.
- Expected: sensible defaults from fund flags (e.g. cover = leftover target, lands in = first non-pot AUD fund ≠ cover, SG bank pot = the currency's default pot), and a reason when Record is disabled.
- Actual: `pickSwapRow` looks up `fundByName('Investment Fund AU (Aizat)')`, `'BearHaus Rainy Day AU'`, `'Future DreamHouse SG'`, `'Travel Fund AU'` and `name.includes('(' + payer + ')')`. For Wei & Priya: Covered by = Savings AU, Lands in = Savings AU (identical → Record swap disabled, nothing says why). For the trip line the cover defaulted to my near-duplicate "Travel Fund AU" (capital F) because that string matched, not the seeded "Travel fund AU". The preview copy hard-codes "which the DreamHouse money tops up" regardless of the fund chosen, and the page header says "Paid with Singapore money" although the currency selector offers AUD too.
- Evidence: d18-swap-form.png; `B/d06-swap.mjs` output (`cover: Savings AU`, `land: Savings AU`, `go disabled: true`).
- Fix: derive defaults from flags/order (leftover target, first non-pot fund of the other currency that isn't the cover, default pot of the purchase currency), keep remembering last choices per kind, show "cover and lands-in must differ" under the button, and templatise the copy with the selected fund names.

**B5 · minor · "Un-reconcile selected" ignores the selection and un-reconciles the whole statement**
- Steps: with nothing selected (locked rows have no checkbox) press "Un-reconcile selected".
- Actual: a browser `confirm("Un-reconcile 5 rows on this statement?…")` then all manual rows on the statement are unlocked. The label promises a selection that can't be made; the button is enabled while "nothing selected" is shown next to it.
- Evidence: `B/d02-statements2.mjs` output (`dialog: Un-reconcile 5 rows…`, toast `5 un-reconciled 🔓`).
- Fix: rename to "Un-reconcile all on this statement" (or let locked rows be ticked and act on the ticks); replace `confirm()` with the in-page confirm pattern the app uses elsewhere.

**B6 · minor · Negative totals formatted as "S$-35.10" / "S$-5,220.00" and sign conventions differ by surface**
- Steps: UOB in-progress period (bill payment + refund > spend) → KPI "In the app · this period" = `S$-35.10`; DBS bank account → `S$-5,220.00`; selection bar `4 selected · S$-168.50`.
- Expected: `−S$35.10`; for a bank account money-in positive (a bank statement reads credits as +; the hint "type the closing balance" can never match a negative "spend").
- Actual: as above. On the phone the same Payment rows render `−S$59.90` in grey while the Desk renders `+S$59.90` in green.
- Evidence: d02b-uob-inprogress.png, d08-dbs.png, s29-alltx.png.
- Fix: `fmtMoney` handles sign (prefix `−`); for `kind='bank'` flip the KPI sign (credits positive) and label it "net movement"; on the phone show Payment rows with `+` or a "credit" tag.

**B7 · minor · "Ticked · reconciled" count excludes rows in another currency, so the count disagrees with the locks on screen**
- Steps: UOB period with the AUD Qantas row reconciled alongside 5 SGD rows.
- Actual: `S$201.40 · 5 of 10 rows shown` while 6 rows carry a 🔒. Un-reconciling Qantas via the lock changes nothing in the KPI, which looks like the click failed.
- Fix: count every locked row; keep only the total currency-filtered, e.g. "6 of 10 rows · 1 in another currency not in the total".

**B8 · minor · A custom plan budget line can never be spent against — it is in the total but has no pace card and no category**
- Steps: SG block → "+ add budget line" "Parents allowance" 1,000 → Wei pocket SG. Apply. Budget → Singapore.
- Actual: hero says "of S$1,800.00" but only "Daily Expenses S$800" has a pace row (`paceCards` iterates `BUDGET_ROWS`); no category maps to the line, so every SGD expense lands in Float SG's countdown and Wei pocket SG can only ever go up (Pots: Spent = Cleared = S$1,000.00, Pending 0).
- Evidence: s32-budget-sg.png; SQL `category_budgets` row `Parents allowance|SGD|1000|Wei pocket SG`; d22-pots-after.png.
- Fix: either create a category group when a custom line is added (and offer it in the category picker) or restrict budget lines to existing groups; show custom lines as pace cards.

**B9 · minor · Deep link `?rows=nocard` lands on Statements, not Transactions**
- Steps: open `http://127.0.0.1:54321/desktop/?rows=nocard`.
- Actual: Statements screen is active; the "— no card —" filter is pre-set but only visible after clicking Transactions by hand.
- Fix: `go('nocard')` when the param is present.

**B10 · minor · Currency mix-ups are accepted silently**
- Steps: record "Qantas" A$450 on UOB — Wei (SGD card); "Lazada" S$25 on Bank card — Wei (AUD); bulk-move Woolworths (AUD) onto DBS — Wei (SGD bank).
- Actual: all accepted without a hint. On the Desk such rows get a yellow `AUD` tag, are excluded from the KPI total and can never be matched by import (candidates are filtered to the card's currency: Qantas showed `?` even when the CSV had a Qantas line). A real UOB statement shows the converted SGD amount, so the row can never reconcile.
- Fix: warn in the add sheet when the card's currency ≠ the amount currency ("UOB — Wei is an S$ card — enter the S$ amount from the statement, or keep A$ and it won't reconcile"); in import, match foreign-currency rows loosely (±3 % after a typed rate) or at least list them under "can't match".

**B11 · minor · JPY shown with two decimals; future-dated row shown as "today"**
- `¥3,200.00`, `¥28,000.00` everywhere (toasts, trip, All transactions, Desk). Home → Recent lists Kopitiam (22 Oct) as "today" above today's rows while the Scheduled block says "not counted yet". (Same as persona A's B5/B9 — confirmed in a second household.)

## 3. UX friction
- Plan editor, Singapore block: "spending budget · lands in the pot on each line" with zero lines and only "+ add budget line" — a first-time SG user has to invent line names; the AU block got seven ready rows. The SG leftover shows "…" until the first keystroke and the equation footer lists only Australia at first.
- Plan review with a single pot per currency has no section total top-right (only when ≥ 2 pots) — AU showed one card without a total while SG had both; make it consistent.
- The applied plan's income rows count as income on Home ("Income A$10,700 + S$10,400"): the real S$5,000 salary I logged on 1 Oct is counted on top of the plan's S$5,000. Nothing warns.
- Settings → Funds: adding "Travel Fund AU" next to "Travel fund AU" is accepted silently — a case-insensitive duplicate check would avoid it (it later hijacked the swap default, B4).
- Settings → Payment cards: a new card defaults to "bank account", currency "multi"; the caption under the name ("Wei · bank account") does not refresh after you change type/day/currency until the section re-renders, so DBS — Wei looked currency-less right after I picked S$. The card list order interleaves owners because `sort_order` is per owner. Placeholder still says "e.g. Amex - Aizat".
- Refunds: no refund affordance on the phone. The only way is category "Payment", described as "settle-up transfers between you two"; the Desk then treats it as a credit. Add a "refund / credit" toggle that writes a credit flag instead of overloading Payment, and let Transactions (Desk) show Payment rows (they are filtered out there).
- Statements defaults to the most recent *closed* period; for DBS (bank, calendar months) that is September, which was empty ("no rows … try ± 5 days") although all my rows were in October. Default to the latest period that has rows.
- Fund rows on the bank statement show "Joint" in the Who column (they have no payer).
- `confirm()` dialogs (Un-reconcile, close with unticked rows, undo swap) look foreign next to the app's own toasts; the import/reconcile toast sits on top of the sticky buttons (d11).
- All transactions after a trip-line swap shows the S$68 three times (trip line "⇄ swapped", "Pot swap · Changi lounge · paid from bank pot", and the DreamHouse→Float SG transfer) — group the swap rows under one expandable entry like the plan rows.
- Pot swap list: the recorded rows render the rate as an unlabeled editable input; the "undo" confirm text mentions "four transfer rows" but a trip swap writes five.
- Desk Transactions excludes Payment rows and the search is description-only; a "credits" toggle would help.

## 4. Data-integrity checks
| Check | App | SQL | Result |
|---|---|---|---|
| Plan apply → pots & funds | Float AU 4,200 · Float SG 800 · Wei pocket SG 1,000 · Savings AU 5,600 · Savings SG 1,200 · Emergency 400/500 · DreamHouse 1,500 · Rainy Day 300 · Travel AU 200 | `fund_transactions origin='planned'` 10 rows, same amounts | pass |
| Home "Expense" | A$854.85 + S$176.90 | Oct daily to date, excl. Payment: AUD 854.85 / SGD 176.90 | pass |
| Home "Spent this week" | A$365.95 + S$144.80 | 4–10 Oct: 365.95 / 144.80 | pass |
| Home "Income" SGD | S$10,400 | SGD fund income rows 5,000 (plan) + 5,000 (salary) + 400 | pass numerically — double-counts the salary (friction) |
| Budget SG "so far" | S$188.90 of S$1,800 | SGD Oct incl. 22 Oct Kopitiam = 188.90; category_budgets SGD = 1,800 | pass (includes a future row, A's B3) |
| UOB "In the app · this period" | S$-35.10 (out 324.80 · in 359.90) | 6 SGD debits 324.80, credits 300 + 59.90 | pass (format B6) |
| Statement diff message | typed 169.30 vs ticked 201.40 → "ticked is S$32.10 more" | 201.40 − 169.30 = 32.10 | pass |
| Pot swap Lazada @ 1.12 | 4 rows, A$28.00 / S$25.00 | Emergency AU 400→372, Rainy Day 300→328, DreamHouse 1,900→1,875, Float SG +25 | pass; after undo 0 rows, balances restored |
| Trip swap Changi lounge @ 1.12 | A$76.16 | Travel fund AU 200→123.84, Rainy Day →376.16, DreamHouse →1,832, Float SG +68 −68; `travel_expenses.sent_to_fund = true` | pass; settle-up dropped the S$68 |
| Pots: reconcile Officeworks 38.90 + Myki 50 | Float AU Cleared 4,111.80→4,022.90, Pending 766.65→677.75 | `fund_balances_cleared` same; Δ = 88.90 both | pass |
| Funds tab totals | A$9,845.15 across 6 · S$9,975.10 across 6 | `sum(balance)` per currency 9,845.15 / 9,975.10 | pass |
| UOB period boundaries | 20 Sep row in previous period, 21 Sep row in current, 22 Oct only with ± 5 days ("margin") | `closing_day = 20` | pass |

## 5. Security/permissions probes
- Not in this persona's scope. Observed: the server enforces the lock (`save_expense` → HTTP 400 "locked: this row is reconciled…" when changing the amount on the phone) while category-only edits pass — enforcement is not purely client-side.

## 6. Worked well
- Credit-card periods from the closing day are right, including the boundary days; "± 5 days" and "include earlier unreconciled" tag rows as `margin` / `earlier`; statement total diff messages are clear in both directions; close/reopen survive a reload.
- Text import parsed a PDF-style paste with a trailing `CR` and matched 4/5 with a 3-day window; the CSV with Debit/Credit columns parsed correctly; the result panel separates "on the statement but not in the app" from "? app rows with no line".
- Bank-account statements pick up fund rows and tie them to the account on tick (`account_payment_method_id`).
- Bulk edit: mixed reconciled/unreconciled handled as documented ("2 updated · 1 reconciled rows kept their card/payer"); "whoever owns the card" re-assigned Shell petrol to Priya after moving it to her card.
- Pot swap writes clean, reversible transfer groups; rate edit recomputes the AUD side; the trip line is marked sent and settle-up skips it; the phone shows "⇄ swapped".
- Phone edit sheet shows the lock note and allows category/description edits on reconciled rows; lock toggle on the list works both ways; Pots' Spent/Cleared/Pending reconcile exactly with the views.
- Plan editor equation per currency and pot chip cycling; review shows one card per pot with the section total.

## 7. Harness issues
- `api.frankfurter.app/.dev` blocked (expected) — the swap rate fetch fails and the form says to type the rate. Google Fonts blocked.
- Trip creation with `currencies: ["JPY"]` worked here (no array-literal error this run), unlike persona A's note.
- No 5xx in `/__log`; the only 4xx were the app's own: 23502 on bulk "(no card)" (B3) and P0001 "locked" from `save_expense` (expected).
