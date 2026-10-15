# Restoring BearHaus from a backup

First drill: **15 Oct 2026, passed**: all 20 tables, every row and every login came back, and the money
checks hold. Run the drill again once a month and after any change to how backups are made.

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
4. **Load it** in a single run. The dump turns triggers off while it reloads data (`session_replication_role`),
   so it needs an admin login: `supabase_admin` on the local stack, or the project's `postgres` connection string.
   `psql "<db url>" -q -f bearhaus.sql`
5. **Check it:** `psql "<db url>" -At -F ' · ' -f tools/restore/check-restore.sql`. Every "want 0" must be 0
   (one known exception is listed in the script).
6. **Re-apply the lockdown.** Loading a dump into a fresh Supabase database re-grants the public key on every
   function; the 15 Oct drill found 64. Run the privilege migration again, then re-run step 5. You want 4 functions and 0 tables:
   `psql "<db url>" -f supabase/migrations/20261015000000_privilege_lockdown.sql`
7. **Real recovery only: record the migration history,** so the next deploy doesn't replay every migration
   (the dump doesn't include `supabase_migrations`). From the repo, linked to the project:
   `ls supabase/migrations/*.sql | xargs -n1 basename | cut -c1-14 | xargs supabase migration repair --status applied`
8. **Clean up:** delete the unlocked `.sql` (`rm -P bearhaus.sql`). After a drill, reset the local stack
   (`supabase db reset`) so no real data stays on it. Clear gpg's cached passphrase with `gpgconf --reload gpg-agent`.

## What a restore brings back, and what it doesn't
- **Back:** every app table, every login (people sign in with their old passwords), the activity log.
- **Not back:** the migration history (step 7), the lockdown grants (step 6), anything after the backup was
  taken. Up to a week for the weekly backup; nothing lost if you restore the snapshot taken just before a bad deploy.
