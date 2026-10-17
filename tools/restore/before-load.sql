-- Before loading a backup (docs/RESTORE.md step 4, added 17 Oct 2026). Run it on the BLANK target, with the
-- same admin login that will load the dump, straight before the load:
--   psql "<admin db url>" -v ON_ERROR_STOP=1 -f tools/restore/before-load.sql
--
-- Why: a fresh Supabase database hands every new table, view, sequence and function in public to the API
-- roles (anon = the public key, authenticated = signed-in logins, service_role) the moment it is created, and
-- a dump re-creates everything. Its own grant lines only ever add, so without this step a restored copy lets
-- the public key run every function and read 36 tables/views, and lets every login run the server-only
-- helpers, empty tables and rewrite the household record. Only the dump knows which rights a login really
-- has, so nothing can sort them out after the load. With the hand-out switched off for the loading login,
-- the dump's own grant lines (production's exact rights) are the only ones. tools/restore/relock.sql (step 6)
-- then restates the lockdown and checks the result.
--
-- It changes a setting of the loading login only. On the local stack the drill's last step
-- (`supabase db reset`) puts it back; on a hosted project the load runs as postgres, and the dump's own
-- default-privilege lines plus relock.sql leave postgres's setting exactly as the migrations made it.
\set ON_ERROR_STOP on
do $$
begin
  if exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm')) then
    raise exception 'before-load.sql is for a blank database, before the backup is loaded: public already has tables (reset the target first, docs/RESTORE.md step 3)';
  end if;
end $$;

-- the nightly check's own login (Bundle B, DECISIONS E37): the dump grants it two functions, so it must exist
-- before the load. It comes back with no password: after a real recovery, run the "Monitor login" workflow.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'bh_monitor') then
    create role bh_monitor nologin noinherit nocreatedb nocreaterole connection limit 3;
  end if;
end $$;

alter default privileges in schema public revoke all on tables    from public, anon, authenticated, service_role;
alter default privileges in schema public revoke all on sequences from public, anon, authenticated, service_role;
alter default privileges in schema public revoke all on functions from public, anon, authenticated, service_role;

select 'automatic grants off for ' || current_user || ': load the backup now, with this same login' as before_load;
