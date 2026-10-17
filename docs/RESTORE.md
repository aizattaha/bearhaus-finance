# Restoring BearHaus from a backup

First drill: **15 Oct 2026, passed**: all 20 tables, every row and every login came back, and the money
checks hold. **17 Oct 2026:** steps 4 and 6 rebuilt (re-running the lockdown migration had stopped working),
proven on a synthetic copy of the local stack: afterwards every function, table and view has exactly the
rights of a database built from the migrations. **Drill with a real backup, 17 Oct 2026, passed** (the
pre-deploy snapshot of that day, on the local stack, with the new steps): every table, row and login came back,
the money checks hold (the one known exception only), the public key runs 4 functions and reads no table, and
the privilege test passes. Production's rights match a migrations-built database except one harmless leftover in
the build itself (logins hold MAINTAIN on `beta_invites` there, not in production). Run the drill again once a
month and after any change to how backups are made.

## Where the backups are
- **Daily** (since Bundle B, 17 Oct 2026): GitHub → Actions → *Backup database* (every day 17:00 UTC, plus on
  demand). Artifact `bearhaus-db-YYYY-MM-DD`, kept 14 days; Monday's kept 90 days. Supabase's Free plan keeps no
  backups of its own, so these are the only copies.
- **Before every database deploy:** GitHub → Actions → *Deploy database migrations*. Artifact
  `pre-deploy-<commit>`, kept 14 days. A push that only changes tests makes none (nothing is deployed).
- Both are complete dumps (schema + data, including logins), encrypted with **`BACKUP_PASSPHRASE`**.
- Each daily backup leaves a heartbeat: the Desk Dashboard's top line shows the last one (amber after 50 hours,
  red after 8 days). Red means look at GitHub → Actions → *Backup database*.

## The passphrase
- It lives in Aizat's password manager, in the entry **"BearHaus backup passphrase (GitHub BACKUP_PASSPHRASE)"**.
  It was reset on 15 Oct 2026; backups made before then can't be opened.
- GitHub never shows a secret again. To change it: **save the new one in the password manager first**, then
  `gh secret set BACKUP_PASSPHRASE -R aizattaha/bearhaus-finance` and paste it. Then run *Backup database*
  by hand, so a backup with the new passphrase exists.

## Restore, step by step
1. **Download** the artifact. Use the website, or:
   `gh api repos/aizattaha/bearhaus-finance/actions/artifacts/<id>/zip > b.zip && unzip b.zip`.
   List the ids with `gh api repos/aizattaha/bearhaus-finance/actions/artifacts`.
2. **Unlock** it in the Mac's own **Terminal app**. The Claude app's terminal panel can't take hidden input.
   Paste the passphrase when asked:
   `gpg --pinentry-mode loopback --output bearhaus.sql --decrypt bearhaus-YYYY-MM-DD.sql.gpg`
3. **Choose the target.**
   - **Drill:** the local stack (`tools/dev/README.md`), reset to blank with
     `cd ~/Code/bh-local && supabase db reset`.
   - **Real recovery:** a new or existing Supabase project. With a new project, also change, before anyone uses it:
     the URL and publishable key in `app/common.js`; the project host in the Content Security Policy
     (`connect-src`) of **both** `app/index.html` and `desktop/index.html`; the GitHub secrets
     `SUPABASE_PROJECT_ID` and `SUPABASE_DB_PASSWORD`; `POOLER_HOST` in `money-check.yml`, `backup-db.yml`,
     `monitor-login.yml` and the connection line in `tools/ops/run-data-fix.sh` (Supabase → Connect → Session pooler);
     the auth settings (confirm email on, 12-character minimum, Site URL and redirect URLs = the live app); the
     sign-up hook (Authentication → Hooks → Before User Created → `public.hook_before_user_created`). After the
     load, run GitHub → Actions → *Monitor login* so the nightly check can sign in again.
4. **Load it, with the target's automatic grants off.** A fresh Supabase database hands every new table, view
   and function in `public` to the public key and to every login the moment it is created. The dump re-creates
   everything and its own grant lines only add, so loading straight in leaves those extra rights mixed with the
   real ones, and nothing can tell them apart afterwards (17 Oct: 108 functions and 36 tables/views open to the
   public key, and every login able to run the server-only helpers). The first command switches that off for the
   loading login (it refuses unless `public` is still empty); the second loads. The dump turns triggers off while
   it reloads data (`session_replication_role`), so both need the same admin login: `supabase_admin` on the
   local stack (`postgresql://supabase_admin:postgres@127.0.0.1:55322/postgres`), or the project's `postgres`
   connection string.
   `psql "<db url>" -qAt -v ON_ERROR_STOP=1 -f tools/restore/before-load.sql`
   `psql "<db url>" -q -f bearhaus.sql`
5. **Check it:** `psql "<db url>" -At -F ' · ' -f tools/restore/check-restore.sql`. Every "want 0" must be 0
   (one known exception is listed in the script).
6. **Re-lock the doors.** `relock.sql` restates the lockdown (DECISIONS E5) from the catalog, so it fits the
   schema of any backup: the public key runs only the 2 sign-up checks and the 2 membership helpers and reads nothing, objects
   created later stay closed, logins can't empty tables. It ends with `relock ok · the public key runs 4
   functions (…) and reads nothing`. Then re-run step 5 (4 functions, 0 tables, 0 for "automatic grants") and
   the privilege test with the `postgres` login (local: `postgresql://postgres:postgres@127.0.0.1:55322/postgres`).
   The test must end with "privileges and client guards hold"; it undoes everything it writes.
   `psql "<db url>" -qAt -v ON_ERROR_STOP=1 -f tools/restore/relock.sql`
   `psql "<postgres db url>" -v ON_ERROR_STOP=1 -q -f tools/sql-tests/test_privileges.sql`
   If relock stops with *"the load kept the database's automatic grants"*, step 4's first command was skipped:
   the public key is already shut, but every login holds every right. Start again from step 3.
   (Don't re-run `supabase/migrations/20261015000000_privilege_lockdown.sql` for this: it names a function that
   sprint 3 replaced, so it stops part-way and its whole transaction is undone.)
7. **Real recovery only: record the migration history,** so the next deploy doesn't replay every migration
   (the dump doesn't include `supabase_migrations`). From the repo, linked to the project:
   `ls supabase/migrations/*.sql | xargs -n1 basename | cut -c1-14 | xargs supabase migration repair --status applied`
8. **Clean up:** delete the unlocked `.sql` (`rm -P bearhaus.sql`). After a drill, reset the local stack
   and load the synthetic household again (`tools/dev/seed.sh`) so no real data stays on it; the reset also puts
   back the admin login's automatic grants that step 4 switched off. Clear gpg's cached passphrase with `gpgconf --reload gpg-agent`.

## What a restore brings back, and what it doesn't
- **Back:** every app table, every login (people sign in with their old passwords), the activity log.
- **Not back:** the migration history (step 7), the lockdown's rule for objects created later (step 6), anything
  after the backup was taken: up to a day with the daily backup; nothing lost if you restore the snapshot taken just
  before a bad deploy. The nightly check's login comes back without its password (run *Monitor login*).

---

# When something goes wrong (Bundle B, DECISIONS E37)

Three one-page runbooks. In all three: **don't reset production to fix one row**, and Aizat decides anything that
loses data, on a plain-words summary. For two people, "please don't use the app for an hour" is the pause button.

## A number looks wrong
1. **Write down** which screen, which number, what you expected, and since when (a screenshot is fine; it stays private).
2. **Run the money check by hand:** GitHub → Actions → *Money check* → *Run workflow*. A 'fail' line or a count that
   went up names the kind of problem. The Desk Dashboard's top line shows the same after the run.
3. **Find the rows:** Desk → Activity (every change with before/after, who and when), or the fund's history on the
   Dashboard (`fund_history`, month by month) to find the month it moved.
4. **Partial recovery, if a row was damaged:** restore the latest backup into the *local* stack (steps 1–6 above,
   Drill target), and copy out only the rows needed. Never restore over production for one row.
5. **Fix it with a data fix** in Drive → `Data fixes/YYYY-MM-DD-what.sql` (guarded by household id, asserted
   before/after, counts only in messages — `supabase/data-fixes/README.md`), run with
   `tools/ops/run-data-fix.sh` (it takes a backup first and records the fix).
6. **Make it impossible next time:** a new line in `bh_money_check()` or a guard in a migration, with a test.
7. **Three lines in the handbook** (`bearhaus-v2-rebuild-summary.md`): what, why, what now stops it.

## A deploy went wrong
- **The app (a page looks broken):** `git revert <commit>` and push. Pages republishes in about a minute; phones may
  hold the old page up to ~10 minutes (pull to refresh / reopen).
- **The database (a migration did the wrong thing):** fix forward with a new migration that puts it right — tested
  from scratch in CI like any other. Never edit production by hand.
- **Only if data was damaged** (not just a wrong rule): restore the `pre-deploy-<commit>` snapshot of that deploy.
  That loses **every write since the snapshot** — list them first from Desk → Activity so they can be re-entered.
  Aizat decides. Then steps 1–8 above with the snapshot as the backup, step 7 included.
- After any of these: run the money check by hand and look at the Dashboard's top line.

## I think we've been hacked
Signs: the Money check email lists a *takeover?* line nobody explains (a new login, member, invite, owner change,
password reset), Activity shows changes nobody made, or GitHub/Supabase/Google warn of a new sign-in.
1. **Supabase** (supabase.com → the project): Authentication → Users → sign out every user (and delete any login
   nobody knows); Project Settings → Database → **Reset database password**. Then put the new password in the
   password manager and in GitHub: `gh secret set SUPABASE_DB_PASSWORD -R aizattaha/bearhaus-finance`.
2. **The access token:** supabase.com → Account → Access Tokens → revoke the old one, generate a new one,
   `gh secret set SUPABASE_ACCESS_TOKEN -R aizattaha/bearhaus-finance`.
3. **The nightly check's login:** set a new `MONITOR_DB_PASSWORD` and run *Monitor login* ("Keys and passwords" below).
4. **The backup passphrase:** "The passphrase" above (password manager first, then `gh secret set`, then a backup).
5. **GitHub, Google, Supabase:** change the passwords, check two-step sign-in is still on, look at the security logs
   for sessions you don't know and sign them out.
6. **Look at what changed:** Desk → Activity, newest first; the Money check's counts.
7. **Restore only if data was changed:** the last backup from before the first strange sign (steps above), then
   re-enter anything real since then from Activity.

## Keys and passwords (who holds what, and when they change)
| Secret | Used by | Where the value lives | Rotate |
|---|---|---|---|
| `SUPABASE_ACCESS_TOKEN` (account-wide, never expires) | deploys, backups; the check only until `MONITOR_DB_PASSWORD` exists | GitHub only | on any suspicion; before going commercial: an expiring token + calendar reminder 2 weeks ahead |
| `SUPABASE_DB_PASSWORD` | deploys, backups (`supabase link`); `tools/ops/run-data-fix.sh` asks for it | password manager + GitHub | on any suspicion (Supabase → Project Settings → Database → Reset) |
| `MONITOR_DB_PASSWORD` (login `bh_monitor`: runs the check and records a backup, reads nothing) | nightly check, backup heartbeat | GitHub only (nobody needs to see it) | every 6 months, or on suspicion: the one Terminal line in HANDOVER §4, then *Monitor login* |
| `BACKUP_PASSPHRASE` | backups, pre-deploy snapshots | password manager + GitHub | on suspicion; old backups keep the old one |
| `SUPABASE_PROJECT_ID` | all four workflows | GitHub (not secret: it is in HANDOVER) | with a new project |
