-- tools/restore/relock.sql, the re-lock after a restore (docs/RESTORE.md step 6): on a database built from the
-- migrations it changes no right at all, and after the over-grants a restore brings it puts every one back.
-- Runs after the full chain. relock.sql commits, so this test leaves the database exactly as it found it or fails.

\set ON_ERROR_STOP on
-- every right in public, one row per (object, grantee, privilege), plus the default privileges
create temp view _acl as
with objs as (
  select 'function ' || p.oid::regprocedure::text as obj, coalesce(p.proacl, acldefault('f', p.proowner)) as acl
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public'
  union all
  select 'relation ' || c.relname, coalesce(c.relacl, acldefault(case when c.relkind = 'S' then 's' else 'r' end::"char", c.relowner))
    from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm', 'S')
  union all
  select 'column ' || c.relname || '.' || a.attname, a.attacl
    from pg_attribute a join pg_class c on c.oid = a.attrelid join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and a.attacl is not null and not a.attisdropped
  union all
  select 'default ' || pg_get_userbyid(d.defaclrole) || ' ' || coalesce(dn.nspname, '*') || ' ' || d.defaclobjtype::text, d.defaclacl
    from pg_default_acl d left join pg_namespace dn on dn.oid = d.defaclnamespace
)
select o.obj, x.grantee, x.privilege_type, x.is_grantable from objs o cross join lateral aclexplode(o.acl) x;
create temp table _built as select * from _acl;

-- 1 · on a correct database, nothing moves
\i tools/restore/relock.sql
do $$
declare v text;
begin
  select string_agg(obj || ' ' || privilege_type, ', ') into v from ((select * from _acl except select * from _built) union all (select * from _built except select * from _acl)) d;
  assert v is null, 'relock.sql changed rights on a freshly built database: ' || coalesce(v, '');
end $$;

-- 2 · what loading a dump into a fresh Supabase database adds on top of the dump's own grants (the part
--     relock.sql can undo; a login holding every function is refused instead: see relock.sql part 4)
grant execute on all routines in schema public to public, anon;
grant all on all tables in schema public to anon;
grant update (name) on public.households to anon;
grant select on all tables in schema public to public;
grant all on all sequences in schema public to anon;
grant truncate, references, trigger on all tables in schema public to authenticated;
revoke execute on function public.check_invite(text) from anon;     -- a sign-up check that lost its grant
revoke all on all tables in schema public from service_role;          -- and a server key that lost its rights
alter default privileges for role postgres in schema public grant all on tables to anon, authenticated;
alter default privileges for role postgres in schema public grant all on sequences to anon, authenticated;
alter default privileges for role postgres in schema public grant execute on functions to anon, authenticated;
\i tools/restore/relock.sql
do $$
declare v text;
begin
  select string_agg(obj || ' ' || privilege_type, ', ') into v
    from ((select * from _acl except select * from _built) union all (select * from _built except select * from _acl)) d;
  assert v is null, 'after a restore-style over-grant relock.sql did not bring back the built rights: ' || coalesce(v, '');
end $$;
\echo relock restores the doors and changes nothing on a built database
