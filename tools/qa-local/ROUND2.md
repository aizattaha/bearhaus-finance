# QA round 2 — addendum to BRIEF.md (14 Oct 2026)

Read BRIEF.md first; everything there still applies. Round 2 targets what shipped since round 1. Sign up fresh (invite `QA-TEST`), onboard, then work through your persona's list below. You may ALSO reuse the pre-seeded household for anything that needs history: login `bearhaus-copy@test.local` / `copy-pass-2026` — it has 2,600+ purchases, 22 funds, cards in AUD and SGD. Keep your own test rows recognisable (put your letter + a timestamp in descriptions) and do not delete rows you didn't create.

## What is new since round 1 (the product's own words)

**Money model.** Every fund now shows three numbers: **Available** (what you can still spend), **on cards** (spent but the card isn't paid yet), **in the bank** (cash really there). Spending pots ("Float") are funds that daily spending counts down automatically; other funds are counted down by purchases that *name* them.

**Purchases vs movements** (the "ledger plan"): a *purchase* (bought something — has a category, a card, who paid) always lives in the expense tables, whichever fund pays for it. A *movement* (money changing place — salary in, transfer between funds, an investment out, paying a card) lives in fund transactions.

- Phone **＋ → Expense** has three scopes: **Daily** (counts against the month's budget) · **From a fund** (same form + "counts against" fund picker; the currency follows the fund; it still goes on the card's statement) · **Trip**.
- Phone **＋ → Transfer**: **Between funds** · **Money out** (money leaving a fund that is NOT a purchase) · **💳 Pay a card** (pay a credit card from one or more funds; Available doesn't change, only in-the-bank and what the card is owed).
- Editing a daily purchase shows **counts against** (the month's budget, or a fund in the same currency).
- Funds tab: tap a fund → its history; the "<Month> spending" line opens All transactions filtered to that fund (its purchases and movements together).
- Budget tab: purchases funded from a fund are shown as "A$x paid from funds, not counted"; inside a category they are listed with a 💰 tag and not added.
- **Refunds**: the refund chip on Expense (phone) / "↩ refund / credit" (Desk add transaction). A refund is a positive amount counted as a minus everywhere; it is a credit on the statement.
- **Recently deleted**: deleting a purchase or fund movement moves it to Settings → Recently deleted (phone) for 30 days; restore from there. Reconciled rows and transfer halves can't be deleted outright.
- **Household logins**: Settings → People: "that's me" links your login to a profile; **Invite** makes a JOIN-XXXX-XXXX code; the partner enters it at sign-up (the welcome screen shows "join a household"); a login can be **viewer** (read-only) or **writer**; the owner can remove a login.
- **Desk** (desktop): Statements per card/bank account — tick rows → Reconcile; close a statement; type the statement total / opening / closing / due; **card payment panel** proposes a split by fund (a Car Fund purchase on the card → a Car Fund leg) and records it; reconciled rows of *other* statements are hidden from an open one; rows funded from a fund wear a 💰 tag. Transactions page: filters incl. "funded from a fund"; **Edit selected** changes card / category / who / comments / counts-against in bulk, and can "send back to fund movements". **Sort fund spending**: the historical money-out rows with a suggestion each (purchase or movement) — Move as purchases / Keep as movements / undo. **Pots** page: the three numbers per fund + credit cards owed. **Activity**: who changed what, when.

## Persona lists

### A — Mia & Jordan (phone only, AU/AUD, new household; create a second login for Jordan)
1. Onboard; set up a plan; add 3 Daily purchases on a credit card, 1 cash.
2. Add a purchase **From a fund** (pick a non-pot fund, e.g. the Rainy Day fund): does Home/Budget leave it out of "so far"? Does the fund drop? Does it appear in the card's history? Edit it → counts against → the month's budget → does the fund come back up?
3. Refund of a purchase (and refund of a From-a-fund purchase): numbers everywhere.
4. Delete a purchase → Recently deleted → restore. Delete a transfer half (should refuse politely).
5. Settings → People → invite Jordan. Sign up Jordan in a second browser context with the JOIN code. Jordan adds a purchase; Mia sees it; Jordan tries Settings → People actions. Then Mia removes Jordan's login: Jordan's next action?
6. Transfer → Money out: what does the copy say? Is it clear when to use it vs From a fund?

### B — Wei & Priya (phone + Desk, AUD + SGD, use the seeded household `bearhaus-copy@test.local`)
1. Phone: From a fund in SGD (a SG fund) on a SGD card; and an AUD one on the Macquarie card. Check the Funds tab three numbers before/after (SQL: `fund_cash`).
2. Desk → Statements → that card → current period: the rows wear 💰 tags? Tick and Reconcile both; type the statement total; the **payment panel** proposes legs — are they right (fund purchase → that fund's leg)? Record the payment; check Pots (in the bank down, owed down, Available unchanged); undo it.
3. Desk → Transactions: filter "funded from a fund"; bulk edit → counts against (set/clear); "send back to fund movements" on a row you created; confirm it reappears in the Funds tab as money out, and the fund balance didn't change (SQL `fund_balances` before/after).
4. Desk → Sort fund spending: sort 3–4 rows (Move as purchases with a category and card; Keep as movements for an investment-looking one); undo last move; check balances identical before/after each action.
5. Bank account statement (uBank): does a From-a-fund purchase paid with the bank card show there? Card payments appear as money out?
6. A statement closed in one period must hide its rows from the next period; "include earlier unreconciled" should still show earlier open rows.
7. Round-trip currencies: can an SGD purchase count against an AUD fund? (should be refused with a plain message on both phone and Desk).

### C — Sam (sceptic; integrity + permissions; fresh household, plus a VIEWER login)
1. Create a household; create an invite; sign up a second login with it; then in SQL (SELECT only) look at `household_members` — role? Try as that second login: `sb.from('household_members').update({role:'owner'})`, `sb.rpc('remove_member', …)` on the owner, inserting a `daily_expenses` row with `fund_id` of a fund from the seeded household, with `fund_id` of a fund in another currency, with `household_id` of another household. Everything must be refused (0 rows / 42501 / plain message) and nothing leak.
2. Sign up a THIRD login with a **view-only invite** (owner's Settings → People has a separate view-only invite; roles are fixed at invite time — there is no role switch). As viewer: every write path — add expense, edit, delete, soft_delete_rows, restore_rows, move_expense_to_fund_spend, record_card_payment, save_expense with p_set_fund — must be refused with a readable message in the UI (what does the phone show? is it a toast, a 403 spinner, silent?). Reads must still work.
3. Balance invariants (SQL vs UI): for one fund, `fund_balances.balance`, `fund_cash.cash_balance`, `fund_cash.owed_on_cards`, `card_balances.owed` after: a From-a-fund purchase on a card; its refund; soft delete; restore; purge (if reachable); sending it back to movements; moving it to purchases again from Sort fund spending.
4. Reconciliation lock vs the new fields: on a reconciled daily row try changing `fund_id` (allowed by design), `is_refund` (locked), `amount` (locked) via `sb.from('daily_expenses').update(...)`. Which ones succeed? Does the UI explain?
5. Soft delete edges: delete a row that is on an open statement; on a closed statement; a fund movement that is one half of a transfer; a card-payment leg. What's refused, what's allowed, and are the Desk and phone consistent?
6. Audit: is every action above visible in Desk → Activity with the right "who"?

## Report
Same seven sections as BRIEF.md, file name `report-<letter>2.md` in your own folder's parent (`…/scratchpad/qa/report-A2.md` etc.). Severity: blocker (money wrong or data lost) / major / minor. For every number you call wrong, show the SQL and the screen value side by side.
