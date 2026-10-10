# QA report — Persona A ("Mia & Jordan", Melbourne couple, phone only, 390×844)

Screenshots: `/tmp/claude-0/-home-claude-bearhaus-finance/e03bbdd2-013a-5236-9e14-5d322a7a0b54/scratchpad/qa/A/sNN-*.png`

## 1. Persona & what I did
- Account: `qa-a-1791606422182@test.local` / household "Mia & Jordan" (id `162d413b-2275-4912-9b5b-a21e8a8d8fcf`), AU/AUD only, people Mia + Jordan + joint pot. Never opened the Desk.
- Sign-up with wrong then right invite code; onboarding form submitted empty / name-only / no-country to read validation; read all 14 tour steps.
- October plan from the Home card: 2 income sources (5,200 + 4,300), budget Rent 2,200 / Daily 1,200 / Transport 300 / Utilities 250, Emergency 500 + Travel 400 → leftover 4,650. Saved, re-opened, changed Transport to 350, saved, applied.
- 7 daily expenses via + (cash coffee, groceries on Mia's card, joint dinner, petrol, one dated 3 Oct, one dated 24 Oct, one with emoji/apostrophe description + note, calculator `45+12.5`), one income to Savings; edited petrol (amount + category), deleted the dinner.
- Budget tab + "See transactions"; All transactions filters, Scheduled block, lock/unlock on cash rows, delete from the list.
- Funds: Float detail, transfer Savings→Emergency 300, deposit 650 to Emergency, history.
- Travel: Bali trip (IDR + AUD), 5 expenses across 3 payers/2 currencies, settle-up, sent AUD then IDR-as-AUD to Travel fund.
- Settings: added "Amex — Jordan" (credit card, closes day 15), archived a card (and restored one archived by mistake), renamed group Daily Expenses→Everyday, added category Pets, renamed joint label to "Us"; confirmed all in the add sheet.
- Sign out (double tap), forgot password, wrong password, sign in, duplicate sign-up.

## 2. Bugs

**B1 · major · "Cash" can't be chosen when Mia or Jordan is the payer — the error then tells you to pick Cash**
- Steps: + → Daily expense, payer Mia, open "paid with". Options are "Bank card — Mia" and "no card". Pick "no card", tap ✓.
- Expected: a cash option for any payer (cash is seeded for the household), or the "no card" option not offered if it can't be saved.
- Actual: toast `couldn't save: pick the card you paid with (or Cash)` — but Cash is nowhere in Mia's list. Cash only appears after switching the payer to Joint/"Us" (`cardOptions()` filters cards strictly by `profile_id`; seeded Cash has `profile_id = null`). A first-time user cannot record "Mia paid cash for coffee" without guessing that cash lives under the joint pot. Also means "paid by Jordan with Mia's card" is impossible by design.
- Evidence: s34-paidwith-picker.png, s36-coffee-saved.png (error), s37-paidwith-jordan.png; `app/index.html` lines 3643-3656 and 4322-4325.
- Fix: list `kind='cash'` cards for every payer (or seed a Cash card per person), hide "no card" for new daily/trip rows since it is always rejected, and make the error name the actual options.

**B2 · major · Cash rows are locked instantly, so the edit sheet refuses to edit/delete a row you entered a minute ago, with reconciliation jargon**
- Steps: add a cash expense (joint dinner 142) → tap it on Home → change amount or tap Delete twice.
- Expected: a brand-new row is editable; if a lock exists, the edit sheet should show it and offer to unlock.
- Actual: `couldn't delete: locked: this row is reconciled — un-reconcile it first` / `couldn't save: locked: this row is reconciled — un-reconcile it to change amount, date, currency, card or payer`. The edit sheet shows no lock state and no unlock control; the only unlock is a 🔒 icon on the All-transactions list, which a new user has not seen and the words "reconciled"/"un-reconcile" don't appear anywhere in the tour.
- Evidence: s54-delete-fail.png; `daily_expenses.reconciled_by = 'auto'` on all three cash rows; HTTP 400 on DELETE and `rpc/save_expense` (P0001).
- Fix: show a lock row in the edit sheet with an "unlock to edit" button (same RPC the list uses); or don't auto-lock cash rows until the day/month closes; reword to plain language ("this cash row is locked — tap to unlock").

**B3 · major · Three different answers to "how much have we spent / have left" for the same month**
- Steps: add an expense dated 24 Oct (Car rego 845). Compare Home, Budget, All transactions.
- Expected: one consistent rule for future-dated rows, stated once.
- Actual:
  - Home "Expense" card: A$380.35 (excludes it).
  - Budget "October 2026 so far": A$1,225.35 of 4,000, "A$2,774.65 still available" (includes it) — while the Float pot two lines below says A$3,619.65 (excludes it). Transport pot "A$977 of 350 — A$627 over" includes it.
  - All transactions Scheduled block: "next due 24 Oct 2026 · not counted yet" (contradicts Budget).
- Evidence: s55-budget-tab.png, s105-budget-final.png, s57-month-tx.png; SQL `oct all = 1225.35`, `oct to date = 380.35`, `fund_balances.Float = 3619.65`.
- Fix: decide one rule. If scheduled rows should reduce "available", show them as a separate "scheduled −A$845" line in the Budget hero and the Float pot, and change the Scheduled block copy; otherwise exclude them from "so far" like Home and the view do.

**B4 · major · Funds tab shows a stale Float after editing or deleting an expense**
- Steps: with the Funds tab already visited (the tour visits it), edit petrol 78.20→82 and delete the 142 dinner from Home/All transactions, then open Funds.
- Expected: Float 3,619.65.
- Actual: Float 3,481.45 (= balance before the edit/delete). Reload fixes it. Adding an expense does refresh it; the `editDaily`/delete paths don't call `loadFunds()`.
- Evidence: s62-funds-tab.png (3,481.45) vs SQL `fund_balances.Float = 3619.65`; after reload 3,619.65.
- Fix: refresh funds (and Budget pots) after edit/delete/lock-toggle, same as after add.

**B5 · minor · Future-dated row shows as "today" on Home**
- Steps: add an expense dated 24 Oct; look at Home → Recent.
- Expected: "24 Oct" (or "scheduled").
- Actual: "Car · Us · today", sorted above today's rows, and it is excluded from the week/expense totals on the same screen.
- Evidence: s50-home-after-adds.png; `daily_expenses.date = 2026-10-24`.
- Fix: date-label future rows explicitly (and consider a "scheduled" tag like the All-transactions list).

**B6 · minor · Home isn't refreshed after "Apply October's plan"**
- Steps: apply the plan from the Home card.
- Actual: sheet closes, Home card disappears, Income still shows A$0.00 "log it with + → Income" until the next write; after the first expense it jumps to A$9,500. Also the plan sheet still read "plan saved ✓ — nothing has moved yet" at the moment the applied toast fired.
- Evidence: s30-after-apply.png vs s38-coffee-saved.png.
- Fix: re-render Home after apply; keep a compact "October plan applied ✓ · open" card so the plan stays reachable from Home (today it is only in Settings/Budget after apply).

**B7 · minor · Negative fund balance formatted as "A$-1,580.50"**
- Steps: send A$1,980.50 of trip spend to a Travel fund holding 400.
- Actual: Funds tab shows `A$-1,580.50`; no warning that the fund went overdrawn.
- Evidence: s83-funds-negative-travel.png; SQL `Travel fund = -1580.50`.
- Fix: format as `−A$1,580.50` in red (fmtMoney handles the sign) and warn on the settle-up button when the fund can't cover it.

**B8 · minor · New card gets no currency ("multi") in a single-currency household; Add button clipped**
- Steps: Settings → Payment cards → add "Amex — Jordan".
- Actual: row reads "Jordan · bank account" with currency select on "multi"; the "Add" button is cut off at the right edge of the 390px viewport. Placeholder reads "e.g. Amex - Aizat" (developer's name).
- Evidence: s90-group-rename-inline.png, s85-settings-cards.png.
- Fix: default currency to the household's only currency; wrap the add row; neutral placeholder ("e.g. Amex — Jordan").

**B9 · minor · IDR amounts shown with two decimals**
- "Rp185,000.00", "Rp1,635,000.00" everywhere (toasts, trip card, settle-up). IDR has no minor unit.
- Fix: currency-aware fraction digits (0 for IDR/JPY/KRW/VND).

## 3. UX friction
- Tour step 5 "Add anything … Expense/Income/Transfer, Daily/Fund/Trip" — the card sits exactly over those toggles, so you can't see what it's describing (s14-tour5.png). Step 6 likewise covers the description field. Anchor the card lower for those steps.
- Add sheet defaults the category to "Rent" (later to whatever is most used), so a first coffee is one tap from being saved as Rent. "MOST USED" lists Rent/Dining out/… with zero history — label it "Suggested" until there is history.
- Income after applying the plan: Home "Income A$9,500" is the plan's fund deposits, not real pay. If Mia now logs her actual salary via + → Income it double counts. Nothing explains this; the plan sheet should say "income lines are planning only — don't log pay again" or the income form should warn when a planned source already exists this month.
- "Into funds" in the plan editor shows a Float box even though the budget already lands in Float; and Savings has no box ("receives the leftover"). Hide Float there or explain it.
- Daily expenses have no split — "dinner split between us" has to be the joint pot. Fine, but the payer segment should hint that "Us" means shared/split.
- Delete / Send-to-fund confirmations expire in ~3 s with no visible countdown; I missed the window twice. Keep the confirm state 8–10 s or show it as a second button.
- Sending IDR as converted AUD had no second-tap confirm while the AUD send did; keep them consistent.
- New category row defaults the group select to "Rent" — Pets landed in Rent (s98-signout-1.png). Default to the last group used or force a choice.
- Enter does not submit the inline rename inputs (group / joint label); you must find the ✓.
- All transactions opened from Budget highlights "Home" in the bottom nav; the back link says "‹ Budget".
- Card rows (non-cash) have no lock icon at all, so the legend "reconciled rows are locked" has nothing to anchor to until a statement exists.
- Row labels in fund history truncate ("October 2026 s…") at 390px; the amount column could be narrower.
- Duplicate sign-up shows raw Supabase text "User already registered" — say "that email already has an account — sign in or reset your password".

## 4. Data-integrity checks
| Check | App | SQL | Result |
|---|---|---|---|
| Plan apply → Float / Savings / Emergency / Travel | 4,000 / 4,600 / 500 / 400 | fund_balances 4000 / 4600 / 500 / 400 | pass |
| Float after expenses + edit + delete (after reload) | A$3,619.65 | 4000 − 380.35 = 3619.65 | pass (stale 3,481.45 before reload → B4) |
| Emergency fund after transfer + deposit | A$1,450.00 | 500 + 300 + 650 = 1450 | pass |
| Savings after transfer | A$4,420.00 | 4600 + 120 − 300 = 4420 | pass |
| Budget "so far" | A$1,225.35 of 4,000 | sum Oct daily_expenses = 1225.35; category_budgets = 4000 | pass numerically, but includes the 24 Oct row (B3) |
| Budget "still available" vs Float pot on same screen | 2,774.65 vs 3,619.65 | differ by the 845 scheduled row | fail (B3) |
| Trip total | Rp1,635,000 + A$1,820 | travel_expenses IDR 1,635,000 / AUD 1,820 | pass |
| Travel fund after settle-up | A$-1,580.50 | 400 − 1820 − 160.50 = −1580.50 | pass (format B7) |
| Spent this week after delete | A$330.35 | 4.5 + 186.35 + 82 + 57.5 | pass |
| Cash rows auto-locked | 🔒 on Coffee, Dinner, Rego, Warung | reconciled_by = 'auto' on those rows only | pass |

## 5. Security/permissions probes
- Not in this persona's scope. Only note: wrong password returns a clean "email or password didn't match" (HTTP 400), forgot-password with no email is caught client-side ("type your email above first, then tap forgot password"); with an email: "reset link sent — check your email, then come back here".

## 6. Worked well
- Onboarding validation copy is specific and scrolls to the error; invite-code error is clear.
- Plan editor recalculates live and the footer equation (9,500 − 4,000 − 900 = 4,600) matches what apply writes.
- Calculator keypad: shows the pending expression ("45 + 12.5"), first ✓ evaluates, second saves.
- Trip expense sheet defaults the date to the trip start and offers exactly the trip's currencies; settle-up "Joint owes Mia / Jordan" per currency was right; "settled" badge after both sends.
- Lock/unlock toggle on the list with clear titles; group rename "budgets followed" really did carry the budget line; joint label rename applied retroactively to old rows.
- Long emoji/apostrophe description and note stored and displayed intact.
- Sign-out double-tap toast is clear; session survives reload; tour doesn't re-run on sign-in.

## 7. Harness issues
- `POST /rest/v1/trips` with array columns fails: `malformed array literal: "[\"IDR\"]"` (and `"[]"`), HTTP 400 — the emulation doesn't coerce JSON arrays to `text[]`. Worked around by inserting the trip via `sb.from('trips').insert({... currencies:'{IDR}', countries:'{ID}'})` from the console. Real Supabase/PostgREST would accept the app's payload. (App-side nit: if the user deselects every currency the app sends `[]`; falling back to the primary currency would be friendlier.)
- Google Fonts / frankfurter blocked as expected; no other 5xx in `/__log`.
