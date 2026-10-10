-- local auth emulation for bh-local
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text unique not null,
  password text not null,
  created_at timestamptz not null default now()
);
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
create or replace function auth.role() returns text language sql stable as $$
  select nullif(current_setting('request.jwt.claim.role', true), '')
$$;
grant usage on schema public to anon, authenticated;
grant all on all tables in schema public to anon, authenticated;
grant all on all sequences in schema public to anon, authenticated;
grant execute on all functions in schema public to anon, authenticated;
-- a seeded login that owns the BearHaus copy (uid is the one the data was exported with)
insert into auth.users (id, email, password) values ('6a09f1b4-5863-465e-b015-3af50adb7524', 'bearhaus-copy@test.local', 'copy-pass-2026')
  on conflict (id) do nothing;
insert into beta_invites (code, max_uses, used_count) values ('QA-TEST', 50, 0) on conflict do nothing;
