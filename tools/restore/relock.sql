-- Re-lock the doors after a restore (docs/RESTORE.md step 6, 17 Oct 2026; the v2 sprint 1 lockdown, DECISIONS E5).
-- Idempotent, and written from the catalog (names, never signatures), so it fits whatever schema the backup
-- holds. Run it with the same admin login as the load, then re-run check-restore.sql and test_privileges.sql:
--   psql "<admin db url>" -v ON_ERROR_STOP=1 -f tools/restore/relock.sql
-- It replaces re-running the lockdown migration, which stopped at its first line once sprint 3 replaced
-- restamp_pots(uuid, date, date) and so left the public key's rights in place.
--
--  1  New objects stay closed: the lockdown's default privileges for postgres. A dump only adds to the
--     target's own, so a fresh database's hand-outs to anon and authenticated survive the load.
--  2  The public key (anon) runs only check_invite, invite_info, bh_member_of and bh_writer_of (found by name)
--     and holds no table, view or sequence rights. PUBLIC holds none either, since anon inherits PUBLIC.
--  3  Signed-in logins can't empty, reference or put triggers on a table (lockdown §2); the server key keeps
--     every right, as every migration gives it. Everything else a login may do comes from the dump's own
--     grant lines, which is why step 4 runs before-load.sql: after a load without it every login holds
--     every right, and no rule can tell which ones the migrations meant (test: tools/sql-tests/test_relock.sql).
--  4  Refuses, after committing 1-3 so the public key is shut either way, when the load kept the database's
--     automatic grants: start again from step 3, with before-load.sql.
\set ON_ERROR_STOP on
begin;

-- ── 1 · nothing created from now on is open to the API roles (lockdown §1) ──
alter default privileges for role postgres in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges for role postgres revoke execute on functions from public;
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;

-- ── 2 · the public key: the sign-up checks and the two membership helpers RLS evaluates ──
revoke execute on all routines in schema public from public, anon;
revoke all on all tables in schema public from public, anon;
revoke all on all sequences in schema public from public, anon;
do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('check_invite', 'invite_info', 'bh_member_of', 'bh_writer_of') loop
    execute format('grant execute on function %s to anon', f);
  end loop;
end $$;

-- ── 3 · logins and the server key ──
revoke truncate, references, trigger on all tables in schema public from authenticated;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant execute on all routines in schema public to service_role;

-- ── proof: the public key runs exactly the four and reads nothing ──
do $$
declare v text;
begin
  select string_agg(p.oid::regprocedure::text, ', ') into v from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not in ('check_invite', 'invite_info', 'bh_member_of', 'bh_writer_of');
  if v is not null then raise exception 'relock: the public key can still run %', v; end if;
  select string_agg(c.relname, ', ') into v from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm', 'S')
     and case when c.relkind = 'S' then has_sequence_privilege('anon', c.oid, 'usage, select, update')
              else has_table_privilege('anon', c.oid, 'select, insert, update, delete, truncate, references, trigger')
                or has_any_column_privilege('anon', c.oid, 'select, insert, update, references') end;
  if v is not null then raise exception 'relock: the public key still has rights on %', v; end if;
end $$;
notify pgrst, 'reload schema';
commit;

-- ── 4 · did the load keep the database's automatic grants? ──
-- The migrations keep the trigger guards and the server-only helpers away from logins, so a login that can
-- run every function in public means the dump's rights were mixed with the target's own.
do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and not has_function_privilege('authenticated', p.oid, 'execute')) then
    raise exception 'relock: the public key is shut, but every login can run every function, so the load kept the database''s automatic grants. Start again from docs/RESTORE.md step 3 and run before-load.sql before the load.';
  end if;
end $$;

select 'relock ok · the public key runs ' || count(*) || ' functions (' || string_agg(p.proname, ', ' order by p.proname) || ') and reads nothing' as relock
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
