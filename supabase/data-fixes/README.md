# Data fixes for a real household: not here

Schema migrations (`supabase/migrations/`) must work for every household and contain no real data.
CI enforces this with `tools/ci/private-data-guard.sh`.

A one-off fix to the original household's rows (re-anchoring balances, relabelling history, moving rows)
is a **data fix**. It never goes in this public repository:

- Write it in the owner's private Drive folder (`Data fixes/`), named `YYYY-MM-DD-what.sql`.
- Guard every statement with the household id, wrap it in `begin; … commit;`, and assert balances before
  and after, as the migrations do.
- Error messages print counts and ids only, never amounts.
- Run it once against production with the service role (`psql "$DATABASE_URL" -f …`), after a
  snapshot, and record it in the handbook.
