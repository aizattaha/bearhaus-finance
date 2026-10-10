# QA report — Persona C ("Sam", sceptical solo user)

Screenshots and scripts: `/tmp/claude-0/-home-claude-bearhaus-finance/e03bbdd2-013a-5236-9e14-5d322a7a0b54/scratchpad/qa/C/`
Account: `qa-c-1791611717727@test.local` · household `4b71e04e-babd-4191-9097-fe6f8e0b08b3` ("Sam", AU only, one person; the onboarding "keep a joint pot" toggle was left at its default = on)
Probe targets: household B `d65aa4e0-…` (qa-b), A `162d413b-…`, seeded `82f25ed0-…` (bearhaus-copy)

## 1. Persona & what I did
- Signed up with QA-TEST, onboarded as one person / AU only, took the plan nudge: Salary 5,200; Rent 1,900, Daily Expenses 1,200, Transportation 250, Utilities 180; Emergency 300, Travel 200 → applied (leftover 1,170 → Savings).
- Added a credit card "Amex — Sam" (closing day 31) in Settings; logged ten ordinary expenses (Cash / Bank card / Amex, 28 Sept – 10 Oct).
- Desk: signed in, reconciled Coles + Bunnings on the in-progress Amex period, checked Pots / Transactions / Pot swap pages.
- Then probed: keypad & description edge cases, archive/delete with dependants, reconciliation locks via `sb` from the page, cross-household RLS/RPC calls, future-dated rows, settings renames and card-kind change, sign-out / token corruption, two tabs editing the same row.
- Verified 9 app numbers against SQL (section 4).

## 2. Bugs

**B1 · major · A login can create a second `households` row and the app then silently degrades**
- Steps: from the signed-in app, `sb.from('households').insert({name:'Second', owner_user_id:<my uid>})` → 201. Reload.
- Expected: refused (one household per login is what `create_household_setup` enforces).
- Actual: insert accepted (RLS WITH CHECK is only `owner_user_id = auth.uid()`). `loadContext()` does `households.select(...).single()` → `PGRST116 multiple rows`; the app keeps running on the cached `bh-ctx` with no message, new trips never appear in CTX, Settings are stale. Every security-definer RPC does `select id into v_hh from households where owner_user_id = auth.uid()` with no `strict`/ordering, so reconcile/save_expense would act on an arbitrary one of the two.
- Evidence: `s07-trip.mjs` output `R22 → {"err":null,"n":1}`, `reload ctx → PGRST116`; screenshot `C/s14a-two-households.png`; `__log` shows `GET households n=2`.
- Fix: DB — `create unique index households_one_per_owner on households(owner_user_id)`; RLS — drop INSERT from the household policy (only the RPC inserts); app — if households returns ≠1 row show an error screen instead of cached data.

**B2 · major · Reconciliation lock is bypassed by one UPDATE that clears `reconciled_at` and changes the amount**
- Steps: on manually reconciled Coles: `update({amount:1})` → refused (good); `update({amount:42.16, reconciled_at:null, reconciled_by:null})` → 200, amount changed, row now unreconciled.
- Expected: direct writes can never change `reconciled_*`; only `reconcile_rows/unreconcile_rows` can.
- Actual: `bh_expense_lock` only fires when *both* old and new `reconciled_at` are non-null. Same hole in `bh_fund_lock`.
- Evidence: `s06-probe.mjs` L1/L2 (refused) vs L6 (`"amount":42.16,"reconciled_at":null`).
- Fix: trigger — in `bh_expense_lock`/`bh_fund_lock`, `if new.reconciled_at is distinct from old.reconciled_at and current_setting('bh.via_rpc', true) is distinct from 'on' then raise 'use un-reconcile'`; have the two RPCs `set_config('bh.via_rpc','on',true)` before their updates. (RLS cannot express this; UI already behaves.)

**B3 · major · Half of a transfer can be deleted, leaving an orphan that inflates a fund**
- Steps: transfer Float → Savings 100 (UI). `sb.from('fund_transactions').delete().eq('id', <Float half>)` → 200.
- Expected: refused, or the sibling (same `transfer_group_id`) goes with it.
- Actual: Float half gone, Savings keeps `Transfer ← Float +A$100 🔒`; Savings = 1,270 instead of 1,170 (SQL `orphan transfer halves = 1`). The UI shows one combined locked row so it is not reachable from the sheet, but auto-reconciled rows are deletable at the DB and nothing checks the pair.
- Evidence: `s06-probe.mjs` L11; SQL `select … from fund_transactions where transfer_group_id is not null` → one row; Funds tab `Savings A$1,270.00` (`C/s17-funds-sched.png`).
- Fix: trigger — in `bh_fund_lock` DELETE branch: if `old.transfer_group_id is not null` and the sibling still exists, either `delete from fund_transactions where transfer_group_id = old.transfer_group_id and id <> old.id` (cascade pair) or raise. `reconcile/unreconcile_rows` already treat the pair as a unit, so the delete path should too.

**B4 · major · Budget tab counts future-dated expenses; Home, Float and Funds do not**
- Steps: add "Future dentist" A$80 dated 20 Oct 2026 (Medical Expenses). Compare screens.
- Expected: not counted anywhere until the date (All transactions shows it under "Scheduled · not counted yet").
- Actual: Budget "October 2026 so far A$497.15 of A$3,530.00" and the Daily Expenses pot "A$373.95 of A$1,200.00" include the 80; Home month = 417.15, Float pot on the same screen = 3,112.85 (= 3,530 − 417.15), `fund_balances` excludes it. The same card contradicts itself: Float 3,112.85 vs "3,032.85 still available".
- Evidence: `s11-final.mjs` output + SQL (`oct to date 417.15`, `oct all incl future 497.15`, `daily-exp pot to date 293.95`); `C/s26-expense-story.png`.
- Fix: UI query for the Budget month total and per-group pots — add `date <= today` (same rule as the `fund_balances` view and Home), and show the scheduled amount as a separate muted line if wanted.

**B5 · minor · Home "Recent" lists future-dated rows and labels them "today"**
- Steps: rows dated 20 Oct 2026 and 31 Dec 2099 appear at the top of Recent as "Medical Expenses · Samira · today".
- Expected: hidden from Recent (they are "Scheduled") or labelled "scheduled · 20 Oct".
- Actual: `daysAgo <= 0 ? 'today'` (index.html ~line 1040).
- Evidence: `C/s16-home-sched.png`.
- Fix: UI — filter `date <= today` in the recent query, or branch `daysAgo < 0 → 'scheduled · d MMM'`.

**B6 · major · A corrupted/invalid session token shows a zeroed account instead of the sign-in screen**
- Steps: edit `localStorage['sb-127-auth-token'].access_token` (last 12 chars garbled), reload.
- Expected: app detects the auth failure, signs out, shows login.
- Actual: Home renders with "October's plan isn't set up yet", Spent A$0.00, no expenses, Expense/Income A$0.00 — looks like the data is gone; no toast, no redirect (`households` returned 406, the rest empty). The expired-token case (valid refresh token) recovered correctly.
- Evidence: `C/s23-garbled-token.png`; console `HTTP 406 GET /rest/v1/households`.
- Fix: UI — in `loadContext`, if `households` errors (401/406/PGRST116) or returns no row for a session that claims to be signed in, call `sb.auth.signOut()` and show `#login` with "session expired — sign in again". (Caveat: the real backend returns 401 for a bad JWT; same handling applies.)

**B7 · minor · Rows can reference another household's profile or fund**
- Steps: `daily_expenses.insert({household_id:<mine>, payer_profile_id:<B's profile>})` → 201 (shows as "Joint" in the UI); `fund_transactions.insert({household_id:<mine>, fund_id:<B's fund>, type:'income', amount:1})` → 201.
- Expected: refused — a row's profile/fund must belong to the same household.
- Actual: accepted; the fund row is invisible to both households via `fund_balances` (security-invoker + RLS) but pollutes B's fund in any service-role/export query (`sum` over `fund_transactions by fund_id`).
- Evidence: `s06-probe.mjs` R26/R27; SQL `ft.household_id = f.household_id → f`. (Rows cleaned up afterwards.)
- Fix: DB — composite FKs `(fund_id, household_id) → funds(id, household_id)`, `(payer_profile_id, household_id) → profiles(id, household_id)`, same for `payment_method_id`, `trip_id`, `reconciled_statement_id`; or a before-write trigger check.

**B8 · minor · Solo household: Cash cannot be chosen unless the payer is "Joint"**
- Steps: one person, joint pot left on (onboarding default). Add expense, payer Sam → card picker offers Bank card / Amex / no card only; Cash appears only after switching payer to Joint, and then the row is attributed to Joint.
- Expected: Cash available to every payer (it is a kind, not a person's card); for a one-person household the joint toggle should default off.
- Actual: `cardOptions()` filters cards strictly by `profile_id`; Cash is created with `profile_id = null` (= Joint). With the joint pot disabled, Cash is offered to Sam — so the behaviour depends on a setting most solo users won't touch.
- Evidence: `s03-normal.mjs` output `[cards: Bank card — Sam ✓, Amex — Sam, no card]`; `s09-settings.mjs` "cards (no joint): Cash ✓".
- Fix: UI — in `cardOptions` always include `kind === 'cash'` cards; onboarding — pre-untick "keep a joint pot" when only one name is filled.

**B9 · minor · Archiving a fund rewrites the "October's plan · Applied" summary and drops its balance from the total**
- Steps: Emergency fund has an applied +300 contribution. Settings → Funds → Archive.
- Expected: the applied summary is history (2 contributions, leftover 1,170); the total should still say where the 300 is.
- Actual: Funds tab shows "Into funds · 1 −A$200.00 · Leftover +A$1,470.00" and the AU total shrinks by 300 with no "archived" line; restoring puts it back.
- Evidence: `s05-deps.mjs` output "FUNDS after archive"; `C/s12-funds-archived.png`.
- Fix: UI — compute the applied summary from `fund_transactions origin='planned'` for the month, not from the current active fund list; show an "archived funds A$300" line (or refuse to archive a fund with a non-zero balance and tell the user to move it first).

**B10 · minor · No upper bounds on amount or description**
- Steps: keypad accepts 8 digits → saved `A$99,999,999.00` without a confirm (display shows a dangling "99,999,999." when you type "." after 8 digits); description of 500 chars saved.
- Expected: a sanity confirm above e.g. A$100,000; description capped (~120 chars) at input and DB.
- Actual: both saved; the 500-char row stretches the Desk Statements table horizontally (`C/d05-bank-credit.png`).
- Fix: UI `maxlength` on `#descInput` + "tap ✓ again" confirm for large amounts; DB `check (length(description) <= 200)`.

**B11 · minor · Dates are unbounded: 1 Jan 1900 and 31 Dec 2099 accepted silently**
- Steps: calendar back to Jan 1900 / forward to Dec 2099, save.
- Expected: a confirm when > 1 year from today.
- Actual: 1900 row is saved and never visible on Home/Budget (only in All transactions at the very bottom); 2099 sits in "Scheduled" forever. (29 Feb 2027 correctly cannot be picked.)
- Fix: UI — confirm toast for |today − date| > 365 days; DB `check (date between '2000-01-01' and current_date + interval '2 years')`.

**B12 · minor · Archived category still offered under "most used"**
- Steps: archive Groceries → open category picker.
- Actual: Groceries still listed (top list built from recent expenses, not filtered by `is_active`).
- Fix: UI — filter `CTX.topDaily/topTravel` by the active catalogue.

**B13 · minor · Desk "Pot swap" page copy is hard-coded to the owner's SG/AU setup**
- Actual: an AU-only household sees "Paid with Singapore money … moves the AUD (cover fund → Rainy Day) and the SGD (DreamHouse → your SG bank pot)". The currency filter shows only AUD; the list shows every expense including scheduled ones.
- Fix: UI — derive copy from the household's countries/funds; hide the page when the household has one currency.

**B14 · minor · `check_invite` is an unauthenticated true/false oracle**
- Steps: `sb.rpc('check_invite',{p_code:'QA-TEST'})` ×3 → true each time, no throttle; bogus → false.
- Nothing else leaks, but codes are brute-forceable by `anon`.
- Fix: RPC — only expose through `create_household_setup` (which already errors on a bad code), or rate-limit per IP; revoke from `anon`.

**B15 · minor · Concurrent edits: last write wins silently**
- Steps: two tabs open the same expense; tab 1 saves 51, tab 2 saves 52 + category change. Final: 52 / Gas/fuel; tab 1 is never told. (Editing a row another tab deleted *is* caught: "couldn't save: expense not found".)
- Fix: RPC `save_expense` — accept `p_updated_at`/version and raise "changed elsewhere — reload" on mismatch.

**B16 · minor · Settings card row label does not refresh after a kind change**
- After choosing "credit card" the row summary still reads "debit card" until the closing day is set; the toast is right.
- Fix: UI — re-render the row after `save()` in `kindSel.onchange`.

**B17 · minor · Rename consistency gaps**
- Renaming a fund changes its icon (Travel fund ✈️ → Holiday fund 💰) because the icon is derived from the name; trip "Send to Holiday fund" and plan rows follow the name correctly.
- Renaming the person leaves "Bank card — Sam" / "Amex — Sam" for Samira.
- Fix: UI — store an icon on funds (or keep the old one when renaming); offer to rename cards that embed the old name.

**B18 · minor · Trip "Settle up · Joint owes Samira" shown for a one-person household**
- `Payment` category is hidden solo ("settle-up is meaningless solo") but the settle-up card still appears.
- Fix: UI — hide settle-up when `payerNames().length < 2`.

## 3. UX friction
- Payer is sticky: after one Joint/Cash expense the next sheet opens with Joint + Cash preselected; a quick entry lands on the wrong person. → reset payer to the primary person per open, or show the payer in the save toast.
- Onboarding: "keep a joint pot" is on by default even with one name → see B8.
- Delete and Sign out are two-tap confirmations with no visible state change on the sheet other than button text; fine, but the toast text ("tap Sign out again") is easy to miss.
- Funds tab "Edit" on the applied plan opens the review, not the editor; one more tap needed.
- Desk Statements defaults to the last *closed* period; for a new user that is empty — defaulting to "in progress" would be friendlier.
- All transactions: the "Scheduled" group header sums mixed signs (+500 −80 −3 = "+A$417.00") which reads like income.
- Keypad: "." after 8 digits shows "99,999,999." — should be ignored.

## 4. Data-integrity checks (app vs SQL)
| Check | App | SQL | Result |
|---|---|---|---|
| Home "Spent this week" (Sun 4 – Sat 10 Oct, date ≤ today) | A$261.10 | 261.10 | pass |
| Home month Expense (1 Oct – today) | A$417.15 | 417.15 | pass |
| Budget "October so far" | A$497.15 | 417.15 to date / 497.15 incl. 20 Oct row | **fail** (B4) |
| Budget pot Daily Expenses | A$373.95 | 293.95 to date | **fail** (B4) |
| Budget pot Transportation | A$123.20 | 71.20 + 52.00 = 123.20 | pass |
| Funds Float | A$3,112.85 | `fund_balances` 3,112.85 = 3,530 − 417.15 | pass |
| Funds Savings | A$1,270.00 | 1,170 + 100 orphan half | pass vs view, **wrong in substance** (B3) |
| Funds Emergency / Holiday fund | 300 / 200 | 300 / 200 | pass |
| Desk Pots Float Spent / Cleared / Pending | 3,112.85 / 3,420.36 / 307.51 | 3,112.85 / 3,530 − 109.64 = 3,420.36 / diff 307.51 | pass |
| Trip Hobart totals | A$45.00 · US$220.00 | 45.00 AUD · 220.00 USD | pass |
| Double-tap Save | one toast | `count(*) where description='double tap'` = 1 | pass |
| Amex closing day 31 periods | 1 Feb – 28 Feb · 1 Apr – 30 Apr | — | pass |
| Bank card debit → credit (closes 15) | period flips to 16 Sept – 15 Oct | — | pass |
| USD trip expense in an AUD household | shown as US$220 on the trip, not in Float/Budget | travel_expenses USD 220 | pass (daily sheet offers A$ only, so a USD *daily* expense is impossible) |

## 5. Security / permissions probes (from my signed-in page unless noted)
| Probe | Result |
|---|---|
| `households.select('*')` | 1 row (mine) |
| `daily_expenses.select('*').limit(5)` / all | 5 / 17 rows, all my household |
| `funds.select().eq('household_id', B)` | 0 rows |
| UPDATE B's expense | 0 rows affected, no error |
| INSERT daily_expenses with B's household_id | 403 "new row violates row-level security policy" |
| UPDATE my expense's household_id → B | 403 RLS |
| `reconcile_rows('daily',[B id])` / `unreconcile_rows` with B's reconciled id | returns 0, B untouched |
| `statements.insert({household_id:B,…})` | 403 RLS |
| `fund_balances`, `fund_balances_cleared`, `pot_swaps`, `profiles`, `payment_methods` unfiltered | only my rows (pot_swaps 0) |
| `beta_invites` select / update used_count | 0 rows (RLS hides) |
| `trips` select/delete B's trip | 0 rows |
| `delete_pot_swap(B swap)` / `save_expense(B id)` | "swap not found" / "expense not found" |
| UPDATE B household `owner_user_id` = me | 0 rows |
| INSERT a second household for myself | **accepted** → B1 |
| `create_household_setup` again | "this login already has a household" |
| `check_invite('QA-TEST')` ×3, 'NOPE', '%' | true/true/true/false/false — boolean only, no throttle (B14) |
| Insert with B's `payer_profile_id` / B's `fund_id` into my household | **accepted** → B7 |
| `auth.users` via REST (`users`, `schema('auth')`) | 404 |
| Lock: update amount / delete on manual-reconciled and on cash auto-reconciled rows | both refused with readable "locked: … un-reconcile it first" |
| Lock: change category/comments on a locked row | allowed (by design) |
| Lock: `{amount, reconciled_at:null}` in one update | **accepted** → B2 |
| Delete one half of a transfer | **accepted** → B3 |
| Delete own trip with expenses | FK `travel_expenses_trip_id_fkey` blocks (no UI for it anyway) |
| Desk in a fresh context | sign-in page only |
| Sign out on phone, Desk in same browser storage | Desk also signed out on reload |
| Garbled access token | zeroed Home, no login (B6); expired token with valid refresh → recovered |

## 6. Worked well
- XSS/SQL-ish/emoji descriptions stored and rendered escaped everywhere (phone, Desk).
- Triple-click on ✓ writes one row; stale edit of a deleted row is refused with a clear message.
- RLS and the security-definer RPCs are correctly household-scoped on every read/write I tried; no cross-household rows leaked.
- Lock error messages are readable; category/comments still editable on locked rows as documented.
- Closing-day maths: day 31 → month ends; debit→credit flips the period list immediately.
- Renaming a person follows into history, payer segment and Desk; renaming a fund follows into plan rows, trip "Send to", Funds.
- Future-dated expense / deposit / transfer excluded from Home, Funds, Float and Desk Pots and grouped as "Scheduled · not counted yet" (Budget is the exception, B4).
- Desk Pots Spent/Cleared/Pending tie out to the cent.

## 7. Harness issues
- `households?...single()` returns HTTP 406 for 0/2 rows (PostgREST-style); fine, but note the app's own handling in B1/B6.
- With a garbled JWT the emulation returned 200 + empty sets rather than 401; a real backend would 401 — B6 still applies.
- My `record_pot_swap` call used the wrong argument names ("function … does not exist") — my error, not the app's; not retried.
- Google Fonts / frankfurter blocked as expected; nothing else attributed to the shim.
