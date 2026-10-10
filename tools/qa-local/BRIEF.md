# BearHaus Finance — QA tester brief (shared by all testers)

You are testing a real household-finance web app as if you were a new user. Everything runs locally:

- **Mobile app:** http://127.0.0.1:54321/app/  (designed for a phone — use a 390×844 viewport unless your persona says otherwise)
- **Desk (desktop companion):** http://127.0.0.1:54321/desktop/  (use 1280×860)
- **Invite code for sign-up:** `QA-TEST` (the app asks for it when you tap "joining the beta? create your account")
- Use a unique email like `qa-<yourletter>-<timestamp>@test.local` and any password ≥ 6 chars. Sign-up needs no email confirmation here.
- If a page refuses to connect, run `/tmp/claude-0/-home-claude-bearhaus-finance/e03bbdd2-013a-5236-9e14-5d322a7a0b54/scratchpad/qa/start.sh` once and retry.

## How to drive the browser
Headless Playwright from Node:
```js
import { chromium } from '/opt/npm-tools/node_modules/playwright/index.mjs';
const browser = await chromium.launch();
const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });   // keep ONE context per persona so the login persists (localStorage)
const page = await ctx.newPage();
page.on('pageerror', e => console.log('PAGEERROR', e.message));
page.on('console', m => { if (m.type() === 'error') console.log('CONSOLE', m.text()); });
page.on('response', r => { if (r.status() >= 400) console.log('HTTP', r.status(), r.request().method(), r.url()); });
await page.goto('http://127.0.0.1:54321/app/');
```
Write small scripts in YOUR OWN folder (`/tmp/claude-0/-home-claude-bearhaus-finance/e03bbdd2-013a-5236-9e14-5d322a7a0b54/scratchpad/qa/<yourletter>/`), take screenshots there and look at them with the Read tool — you are judging what a human would see. Use the real UI (taps, typing) rather than calling internal functions, except to inspect state. `page.evaluate(() => ...)` gives you the page's JS (`sb` is the Supabase client, `CTX` the loaded household context) when you need to peek or to probe security.

Ignore these, they are the sandbox not the app: Google Fonts and the exchange-rate fetch (api.frankfurter.app) are blocked (console "ERR_FAILED"/"Failed to load resource" for those); the "← mobile app" link; the service worker is disabled.

## Verifying numbers
Read-only SQL is allowed to check what the app shows against what is stored:
`psql -h /tmp -p 55432 -U bh -d bh -Atc "select ... "` — SELECT only, never modify. Your household id: `select id, name from households where owner_user_id = (select id from auth.users where email = '<your email>')`. Useful views: `fund_balances`, `fund_balances_cleared`; tables: `daily_expenses`, `travel_expenses`, `fund_transactions`, `funds`, `categories`, `category_budgets`, `income_budgets`, `fund_budgets`, `payment_methods`, `statements`, `pot_swaps`, `trips`.
The backend's request log is at http://127.0.0.1:54321/__log (last 300 calls) — handy to see what a tap actually sent.

## Harness vs app
The backend is a local emulation of Supabase. If you see an HTTP 500 from 127.0.0.1:54321, or an error message like "unsupported operator", "no relationship", "bad filter", "bad select", that is probably the **harness**, not the app — record it under "Harness issues" and work around it (don't spend long on it). Everything else (what the pages do, say, compute and store, RLS/permission behaviour, triggers) is the real product and fair game.

## Rules
- Do not edit anything under /home/claude/bearhaus-finance. Do not run DDL or UPDATE/DELETE in psql.
- Be a user first: follow the flows the UI suggests, read its copy, notice when you are confused. Then be a tester: try the edges your persona lists.
- Keep going when something fails — note it and continue with the next flow. Aim for breadth across the whole product, then depth where you find smoke.
- Budget: roughly 60–100 tool calls. Stop when you have covered your persona's list.

## Report
Write `/tmp/claude-0/-home-claude-bearhaus-finance/e03bbdd2-013a-5236-9e14-5d322a7a0b54/scratchpad/qa/report-<yourletter>.md` with exactly these sections:
1. **Persona & what I did** — 5–10 lines, which flows you exercised, your account email.
2. **Bugs** — one entry each: `B<n> · <severity: blocker/major/minor> · <title>`; Steps; Expected; Actual; Evidence (screenshot path or SQL/log excerpt); Recommended fix (be concrete — which screen/behaviour should change).
3. **UX friction** — things that worked but confused or slowed you, with a suggested change.
4. **Data-integrity checks** — each check, the two numbers compared, pass/fail.
5. **Security/permissions probes** (if your persona includes them) — what you tried, what happened.
6. **Worked well** — short.
7. **Harness issues** — anything you believe is the local emulation, not the app.
Your final message to the orchestrator should be a short summary (≤ 15 lines) plus the report path.
