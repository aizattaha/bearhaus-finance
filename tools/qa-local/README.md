# qa-local — run the whole product locally, as a stranger would

A ~500-line Node server that speaks enough PostgREST + GoTrue for `app/` and `desktop/` to run
unchanged against a local Postgres copy of the schema. Sign-up, onboarding, RLS, triggers and
RPCs are all the real thing; only the transport is emulated. Built 10 Oct 2026 for QA round 1
(`docs/qa/2026-10-10-round-1.md`).

## Needs
- Postgres 16 on `/tmp:55432`, database `bh`, superuser `bh`, restored from the Drive backups
  (`Backups/bearhaus-schema-*.sql` + `bearhaus-data-*.sql`) with every migration in
  `supabase/migrations/` applied on top. (Claude's build container keeps one at `/home/pguser/pg`.)
- `npm install pg@8 @supabase/supabase-js@2.117.3` in this folder; Playwright from `/opt/npm-tools`.

## Run
```
psql -h /tmp -p 55432 -U bh -d bh -f setup.sql   # auth.users table, auth.uid() from the request claims, QA-TEST invite, seeded copy login
./start.sh                                        # starts Postgres if needed + the shim on http://127.0.0.1:54321
```
- app: http://127.0.0.1:54321/app/ · desk: http://127.0.0.1:54321/desktop/ · request log: /__log
- Sign up with invite `QA-TEST` and any `@test.local` email (no confirmation mail).
- `bearhaus-copy@test.local` / `copy-pass-2026` owns the copied BearHaus household.
- Snapshot before a round: `pg_dump -Fc -f pre-qa.dump …`; restore with `pg_restore -c`.

## Testers
`BRIEF.md` is the shared brief handed to each tester agent; personas live in the round's doc.
Known emulation gaps: no realtime/storage; `or()` filters on embedded columns unsupported;
upserts only with `on_conflict`; the exchange-rate fetch and Google Fonts are blocked by the sandbox.
