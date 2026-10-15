# Local development: the real stack on this Mac

Since v2 sprint 1 the whole product runs locally on the real Supabase image (Postgres 17, PostgREST,
GoTrue), the same platform as production. It replaces `tools/qa-local/shim.mjs` for day-to-day work.
**Synthetic data only.** Never load a production dump here unless the task needs it, and never commit one.

## One-time setup
```
brew install libpq node            # psql (keg-only: add /opt/homebrew/opt/libpq/bin to PATH) and node
open -a Docker                     # Docker Desktop must be running
mkdir -p ~/Code/bh-local/supabase  # a separate workdir, so the repo's config.toml is never edited
```
Copy `supabase/config.toml` to `~/Code/bh-local/supabase/config.toml` and change three things:
`project_id = "bh_local"`, `[db.migrations] enabled = false`, `[db.seed] enabled = false`.
Migrations are applied by our own runner below, exactly as CI does.

## Start, migrate, test
```
cd ~/Code/bh-local && supabase start -x analytics,edge-runtime,functions,imgproxy,inbucket,realtime,storage,studio,vector,meta
cd ~/Code/bearhaus-finance
tools/sql-tests/run.sh "postgresql://postgres:postgres@127.0.0.1:55322/postgres"   # chain + every test
```
The same runner works against a plain Postgres 17 container (what CI uses):
```
docker run -d --name bh-ci -e POSTGRES_PASSWORD=postgres -p 55432:5432 postgres:17
tools/sql-tests/run.sh "postgresql://postgres:postgres@127.0.0.1:55432/postgres"
```
`run.sh` stops at the first error and expects every `test_*.sql` to print ✓.

## Run the apps against it
```
SUPABASE_URL=http://127.0.0.1:55321 SUPABASE_ANON_KEY=<ANON_KEY from `supabase status -o env`> node tools/dev/serve.mjs
```
Open http://127.0.0.1:8790/app/ and /desktop/. The server patches `app/common.js` to point at the local
stack and refuses a hosted URL. Sign up with any `@*.test` email; the sign-up needs a beta code, which you
add locally: `insert into public.beta_invites (code, max_uses) values ('LOCAL-TEST', 20);`.

## Before every push
```
tools/ci/private-data-guard.sh     # no real figures, ids, emails or statements
node tools/ci/check-js.mjs         # every inline script compiles
tools/sql-tests/run.sh <db-url>    # migrations from scratch + tests
```
CI runs the same three.
