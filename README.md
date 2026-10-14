# BearHaus Finance

Household finance app for two people and two currencies — a phone PWA for capturing money as it moves, and a desktop **Desk** for reconciling it against bank and card statements. Static HTML on GitHub Pages, Supabase behind it (Postgres, RLS, SQL RPCs), no build step.

- Phone: `app/index.html` (+ `app/common.js`) · Desk: `desktop/index.html`
- Database: `supabase/migrations/` — deployed automatically from `main` after the from-scratch SQL test job passes (`.github/workflows/deploy-db.yml`)
- Tests: `tools/sql-tests/` (schema + money invariants) · local full-product harness: `tools/qa-local/`
- Docs: `CLAUDE.md` (working rules) · `docs/HANDOVER.md` (state of play) · `docs/DECISIONS.md` (why) · `docs/architecture-review-*.md` · `docs/qa/`

Private household — the code is public, the data is not. Nothing from the production database belongs in this repo.
