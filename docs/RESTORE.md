# Restoring BearHaus from a backup

First drill: **15 Oct 2026, passed**: all 20 tables, every row and every login came back, and the money
checks hold. **17 Oct 2026:** steps 4 and 6 rebuilt (re-running the lockdown migration had stopped working),
proven on a synthetic copy of the local stack: afterwards every function, table and view has exactly the
rights of a database built from the migrations. Run the drill again once a month and after any change to how
backups are made.

## Where the backups are
- **Weekly:** GitHub → Actions → *Backup database* (every Monday, plus on demand). Artifact
  `bearhaus-db-YYYY-MM-DD`, kept 90 days.
- **Before every database deploy:** GitHub → Actions → *Deploy database migrations*. Artifact
  `pre-deploy-<commit>`, kept 30 days.
- Both are complete dumps (schema + data, including logins), encrypted with **`BACKUP_PASSPHRASE`**.

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
   - **Real recovery:** a new or existing Supabase project. With a new project, also update the URL and
     publishable key in `app/common.js`, and the auth redirect URLs.
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
  after the backup was taken. Up to a week for the weekly backup; nothing lost if you restore the snapshot taken just before a bad deploy.
