-- Minimal stand-in for the Supabase platform pieces the migrations lean on, so the whole
-- migration chain can be applied to a plain Postgres (CI, or a scratch database locally).
-- On the real Supabase image (the local stack, `supabase start`) the platform already provides
-- auth, roles and grants, and they belong to Supabase: everything below is skipped there.
-- Nothing here ships to production.
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;
create extension if not exists pg_stat_statements with schema extensions;

do $$
begin
  if to_regclass('auth.users') is not null then
    raise notice 'Supabase platform present — bootstrap stand-ins skipped';
    return;
  end if;
  create schema if not exists auth;
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
  create table auth.users (
    id uuid primary key default gen_random_uuid(),
    email text unique,
    created_at timestamptz not null default now()
  );
  -- auth.uid() / auth.role() read the JWT claims the way PostgREST sets them; tests set them with set_config
  create function auth.uid() returns uuid language sql stable as $f$
    select coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
                    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'))::uuid $f$;
  create function auth.role() returns text language sql stable as $f$
    select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''),
                    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role'))::text $f$;
  grant usage on schema auth to anon, authenticated, service_role;
  grant execute on function auth.uid(), auth.role() to anon, authenticated, service_role;
  grant usage on schema public, extensions to anon, authenticated, service_role;
  -- Supabase's legacy defaults, which the baseline also restates (the v2 lockdown migration revokes them)
  alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
  alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
  alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;
  -- the search_path Supabase gives its roles (extensions hold gen_random_uuid etc. before PG13; harmless after)
  execute format('alter database %I set search_path = public, extensions', current_database());
  -- the baseline dump adds tables to Supabase's realtime publication
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then create publication supabase_realtime; end if;
end $$;
