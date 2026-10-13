-- Identity + history (14 Oct 2026) — architecture review §1.6 and §1.9.
--
--  household_members     who can sign in to a household: (household, login, person, role)
--                        role: owner · member (full) · viewer (read only)
--                        backfilled from households.owner_user_id; one household per login
--  RLS                   every "own household only" policy now reads household_members:
--                        read for any member, write for owner/member
--  RPCs                  v_hh comes from bh_current_household() (members, not just the owner)
--  member_invites        a code the owner shares; the invitee signs up, enters it, joins as a
--                        named person (profiles.auth_user_id links the two)
--  created_by/updated_by on expenses, fund_transactions, statements, pot_swaps (set by trigger)
--  audit_log             one generic AFTER trigger on the ledger + settings tables: who changed
--                        what, before/after of the changed columns. Members can read it.

begin;

-- ── 1 · household_members ────────────────────────────────────────────────
create table if not exists public.household_members (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references public.households(id) on delete cascade,
  user_id       uuid not null,
  profile_id    uuid references public.profiles(id) on delete set null,
  role          text not null default 'member' check (role in ('owner', 'member', 'viewer')),
  created_at    timestamptz not null default now(),
  unique (user_id)                                   -- one household per login (for now)
);
create unique index if not exists household_members_one_owner on public.household_members (household_id) where role = 'owner';
create index if not exists household_members_hh on public.household_members (household_id);

insert into public.household_members (household_id, user_id, role, profile_id)
select h.id, h.owner_user_id, 'owner',
       (select p.id from profiles p where p.household_id = h.id and p.auth_user_id = h.owner_user_id limit 1)
  from public.households h
on conflict (user_id) do nothing;

-- who am I, cheaply (security definer so the policies don't recurse into household_members' own RLS)
create or replace function public.bh_member_of()
returns setof uuid language sql stable security definer set search_path = public as $$
  select household_id from household_members where user_id = auth.uid()
$$;
create or replace function public.bh_writer_of()
returns setof uuid language sql stable security definer set search_path = public as $$
  select household_id from household_members where user_id = auth.uid() and role in ('owner', 'member')
$$;
create or replace function public.bh_current_household(p_write boolean default true)
returns uuid language sql stable security definer set search_path = public as $$
  select household_id from household_members
   where user_id = auth.uid() and (not p_write or role in ('owner', 'member'))
   order by role = 'owner' desc limit 1
$$;
revoke all on function public.bh_member_of(), public.bh_writer_of(), public.bh_current_household(boolean) from public;
grant execute on function public.bh_member_of(), public.bh_writer_of(), public.bh_current_household(boolean) to authenticated, service_role;

alter table public.household_members enable row level security;
drop policy if exists "members: read own household" on public.household_members;
create policy "members: read own household" on public.household_members for select using (household_id in (select bh_member_of()));
-- no insert/update/delete policies: membership changes go through the RPCs below
grant select on public.household_members to authenticated, service_role;

-- ── 2 · RLS: read for members, write for owner/member ────────────────────
do $$
declare t text;
begin
  foreach t in array array['categories','category_budgets','expense_splits','expenses','fund_budgets','fund_transactions',
                           'funds','income_budgets','payment_methods','profiles','statements','trips','pot_swaps'] loop
    execute format('drop policy if exists "own household only" on public.%I', t);
    execute format('drop policy if exists "pot_swaps_own" on public.%I', t);
    execute format('drop policy if exists "hh: read" on public.%I', t);
    execute format('drop policy if exists "hh: insert" on public.%I', t);
    execute format('drop policy if exists "hh: update" on public.%I', t);
    execute format('drop policy if exists "hh: delete" on public.%I', t);
    execute format('create policy "hh: read"   on public.%I for select using (household_id in (select bh_member_of()))', t);
    execute format('create policy "hh: insert" on public.%I for insert with check (household_id in (select bh_writer_of()))', t);
    execute format('create policy "hh: update" on public.%I for update using (household_id in (select bh_writer_of())) with check (household_id in (select bh_writer_of()))', t);
    execute format('create policy "hh: delete" on public.%I for delete using (household_id in (select bh_writer_of()))', t);
  end loop;
end $$;
drop policy if exists "household: read own"   on public.households;
drop policy if exists "household: update own" on public.households;
drop policy if exists "household: delete own" on public.households;
create policy "household: read own"   on public.households for select using (id in (select bh_member_of()));
create policy "household: update own" on public.households for update using (id in (select bh_writer_of())) with check (id in (select bh_writer_of()));
create policy "household: delete own" on public.households for delete using (owner_user_id = (select auth.uid()));

-- ── 3 · RPCs resolve the household through membership ────────────────────
-- the eleven write RPCs all start with the same line; rewrite it in place and prove none is left
do $$
declare r record; v_src text; v_new text;
begin
  for r in select p.oid, p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prokind = 'f'
              and pg_get_functiondef(p.oid) ~ 'from households where owner_user_id = auth\.uid\(\);' loop
    v_src := pg_get_functiondef(r.oid);
    v_new := regexp_replace(v_src, 'select id into (strict )?v_hh from households where owner_user_id = auth\.uid\(\);',
                            'v_hh := bh_current_household(); if v_hh is null then raise exception ''no household — or your login is view-only'' using errcode = ''42501''; end if;', 'g');
    execute v_new;
    raise notice 'rewrote %', r.sig;
  end loop;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.prokind = 'f' and p.proname <> 'create_household_setup'
                and pg_get_functiondef(p.oid) ~ 'owner_user_id = auth\.uid\(\)') then
    raise exception 'an RPC still resolves the household by owner';
  end if;
end $$;

-- ── 4 · onboarding writes the owner's membership ─────────────────────────
create or replace function public.create_household_setup(p_code text, p_household text, p_people text[], p_joint_label text, p_countries text[], p_currencies text[] DEFAULT NULL::text[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid     uuid := auth.uid();
  v_hh      uuid;
  v_person  text;
  v_cc      text;
  v_cur     text;
  v_i       int;
  v_sort    int  := 0;
  v_psort   int  := 0;
  v_fund    uuid;
  v_travel  uuid := null;
  v_primary boolean := true;
  v_sfx     text := '';
  v_first   uuid := null;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if exists (select 1 from household_members where user_id = v_uid) then raise exception 'this login already belongs to a household'; end if;
  if coalesce(array_length(p_people, 1), 0) = 0 then raise exception 'add at least one person'; end if;
  if coalesce(array_length(p_people, 1), 0) > 6 then raise exception 'six people max for now'; end if;
  if coalesce(array_length(p_countries, 1), 0) = 0 then raise exception 'pick at least one country'; end if;
  if coalesce(array_length(p_countries, 1), 0) > 4 then raise exception 'four countries max for now'; end if;
  if p_currencies is not null
     and coalesce(array_length(p_currencies, 1), 0) <> coalesce(array_length(p_countries, 1), 0) then
    raise exception 'countries and currencies don''t line up';
  end if;
  if exists (select 1 from member_invites where lower(code) = lower(trim(p_code)) and used_at is null and expires_at > now()) then
    raise exception 'that code joins an existing household — use "join" instead of creating a new one';
  end if;

  update beta_invites set used_count = used_count + 1
   where lower(code) = lower(trim(p_code)) and used_count < max_uses;
  if not found then raise exception 'invite code not recognised — or already used'; end if;

  insert into households (name, owner_user_id, joint_label, pot_start)
  values (coalesce(nullif(trim(p_household), ''), 'My household'), v_uid,
          nullif(trim(coalesce(p_joint_label, '')), ''), date_trunc('month', now())::date)
  returning id into v_hh;

  foreach v_person in array p_people loop
    if trim(v_person) <> '' then
      insert into profiles (household_id, display_name, sort_order, auth_user_id)
      values (v_hh, trim(v_person), v_psort, case when v_psort = 0 then v_uid end)
      returning id into v_fund;
      if v_psort = 0 then v_first := v_fund; end if;
      v_psort := v_psort + 1;
    end if;
  end loop;
  -- the first name is the person signing up
  insert into household_members (household_id, user_id, role, profile_id) values (v_hh, v_uid, 'owner', v_first);

  for v_i in 1 .. array_length(p_countries, 1) loop
    v_cc := upper(trim(p_countries[v_i]));
    if v_cc !~ '^[A-Z]{2}$' then raise exception 'country codes are two letters — got %', v_cc; end if;
    v_cur := case when p_currencies is not null then upper(trim(p_currencies[v_i]))
                  when v_cc = 'SG' then 'SGD' when v_cc = 'AU' then 'AUD' else null end;
    if v_cur is null or v_cur !~ '^[A-Z]{3}$' then raise exception 'missing or invalid currency for %', v_cc; end if;
    v_sfx := case when array_length(p_countries, 1) > 1 then ' ' || v_cc else '' end;
    insert into funds (household_id, name, country, currency, group_name, sort_order, is_spend_pot)
    values (v_hh, 'Float' || v_sfx, v_cc, v_cur, 'Savings & buffers', v_sort, true);
    v_sort := v_sort + 1;
    insert into funds (household_id, name, country, currency, group_name, sort_order, is_leftover_target)
    values (v_hh, 'Savings' || v_sfx, v_cc, v_cur, 'Savings & buffers', v_sort, true);
    v_sort := v_sort + 1;
    insert into funds (household_id, name, country, currency, group_name, sort_order)
    values (v_hh, 'Emergency fund' || v_sfx, v_cc, v_cur, 'Savings & buffers', v_sort);
    v_sort := v_sort + 1;
    insert into funds (household_id, name, country, currency, group_name, sort_order)
    values (v_hh, 'Travel fund' || v_sfx, v_cc, v_cur, 'Savings & buffers', v_sort)
    returning id into v_fund;
    v_sort := v_sort + 1;
    if v_primary then v_travel := v_fund; end if;
    v_primary := false;
  end loop;

  update households set travel_fund_id = v_travel where id = v_hh;

  insert into payment_methods (household_id, name, profile_id, sort_order, kind, currency)
  values (v_hh, 'Cash', null, 0, 'cash', null);
  insert into payment_methods (household_id, name, profile_id, sort_order, kind, currency)
  select v_hh, 'Bank card — ' || display_name, id, 1 + sort_order, 'debit_card', null
  from profiles where household_id = v_hh;

  perform seed_default_categories(v_hh);
  return v_hh;
end;
$function$;

-- ── 5 · member invites: a second login joins as a named person ───────────
create table if not exists public.member_invites (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references public.households(id) on delete cascade,
  code          text not null unique,
  profile_id    uuid references public.profiles(id) on delete set null,
  role          text not null default 'member' check (role in ('member', 'viewer')),
  created_by    uuid,
  created_at    timestamptz not null default now(),
  expires_at    timestamptz not null default now() + interval '14 days',
  used_at       timestamptz,
  used_by       uuid
);
alter table public.member_invites enable row level security;
drop policy if exists "invites: read own household" on public.member_invites;
create policy "invites: read own household" on public.member_invites for select using (household_id in (select bh_member_of()));
grant select on public.member_invites to authenticated, service_role;

-- JOIN-XXXX-XXXX from an unambiguous alphabet
create or replace function public.bh_new_code()
returns text language sql volatile as $$
  select 'JOIN-' || string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '')
       || '-' || (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '') from generate_series(1, 4))
    from generate_series(1, 4)
$$;

create or replace function public.create_member_invite(p_profile uuid default null, p_role text default 'member')
returns text language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_code text;
begin
  v_hh := bh_current_household();
  if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  if p_role not in ('member', 'viewer') then raise exception 'role must be member or viewer'; end if;
  if p_profile is not null then
    if not exists (select 1 from profiles where id = p_profile and household_id = v_hh) then raise exception 'person not found'; end if;
    if exists (select 1 from household_members where profile_id = p_profile) then raise exception 'that person already has a login'; end if;
    -- one live code per person: hand the same one back
    select code into v_code from member_invites where household_id = v_hh and profile_id = p_profile and used_at is null and expires_at > now() limit 1;
    if v_code is not null then return v_code; end if;
  end if;
  loop
    v_code := bh_new_code();
    exit when not exists (select 1 from member_invites where code = v_code) and not exists (select 1 from beta_invites where code = v_code);
  end loop;
  insert into member_invites (household_id, code, profile_id, role, created_by) values (v_hh, v_code, p_profile, p_role, auth.uid());
  return v_code;
end $$;
revoke all on function public.create_member_invite(uuid, text) from public;
grant execute on function public.create_member_invite(uuid, text) to authenticated, service_role;

create or replace function public.revoke_member_invite(p_code text)
returns void language plpgsql security definer set search_path = public as $$
declare v_hh uuid;
begin
  v_hh := bh_current_household();
  if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  delete from member_invites where household_id = v_hh and code = upper(trim(p_code)) and used_at is null;
end $$;
revoke all on function public.revoke_member_invite(text) from public;
grant execute on function public.revoke_member_invite(text) to authenticated, service_role;

-- what a code is, before signing up (anon-callable, throttled like check_invite)
create or replace function public.invite_info(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v record;
begin
  perform pg_sleep(0.3);
  select mi.code, mi.role, h.name as household, p.display_name as person
    into v
    from member_invites mi join households h on h.id = mi.household_id
    left join profiles p on p.id = mi.profile_id
   where lower(mi.code) = lower(trim(p_code)) and mi.used_at is null and mi.expires_at > now();
  if v.code is not null then
    return jsonb_build_object('kind', 'member', 'household', v.household, 'person', v.person, 'role', v.role);
  end if;
  if exists (select 1 from beta_invites where lower(code) = lower(trim(p_code)) and used_count < max_uses) then
    return jsonb_build_object('kind', 'beta');
  end if;
  return null;
end $$;
revoke all on function public.invite_info(text) from public;
grant execute on function public.invite_info(text) to anon, authenticated, service_role;

create or replace function public.check_invite(p_code text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  perform pg_sleep(0.4);
  return exists (select 1 from beta_invites where lower(code) = lower(trim(p_code)) and used_count < max_uses)
      or exists (select 1 from member_invites where lower(code) = lower(trim(p_code)) and used_at is null and expires_at > now());
end $$;

create or replace function public.join_household(p_code text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v record;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if exists (select 1 from household_members where user_id = v_uid) then raise exception 'this login already belongs to a household'; end if;
  select * into v from member_invites where lower(code) = lower(trim(p_code)) and used_at is null and expires_at > now() for update;
  if v.id is null then raise exception 'that code isn''t valid any more — ask for a new one'; end if;
  insert into household_members (household_id, user_id, role, profile_id) values (v.household_id, v_uid, v.role, v.profile_id);
  if v.profile_id is not null then update profiles set auth_user_id = v_uid where id = v.profile_id; end if;
  update member_invites set used_at = now(), used_by = v_uid where id = v.id;
  return v.household_id;
end $$;
revoke all on function public.join_household(text) from public;
grant execute on function public.join_household(text) to authenticated, service_role;

-- "that's me": tie my login to one of the household's people
create or replace function public.link_my_profile(p_profile uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_hh uuid;
begin
  v_hh := bh_current_household(false);
  if v_hh is null then raise exception 'no household'; end if;
  if p_profile is not null then
    if not exists (select 1 from profiles where id = p_profile and household_id = v_hh) then raise exception 'person not found'; end if;
    if exists (select 1 from household_members where profile_id = p_profile and user_id <> auth.uid()) then raise exception 'that person is already linked to another login'; end if;
  end if;
  update profiles set auth_user_id = null where household_id = v_hh and auth_user_id = auth.uid();
  update household_members set profile_id = p_profile where user_id = auth.uid();
  if p_profile is not null then update profiles set auth_user_id = auth.uid() where id = p_profile; end if;
end $$;
revoke all on function public.link_my_profile(uuid) from public;
grant execute on function public.link_my_profile(uuid) to authenticated, service_role;

-- the owner can remove a login (never their own)
create or replace function public.remove_member(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_hh uuid;
begin
  select household_id into v_hh from household_members where user_id = auth.uid() and role = 'owner';
  if v_hh is null then raise exception 'only the owner can remove a login' using errcode = '42501'; end if;
  if p_user = auth.uid() then raise exception 'you can''t remove yourself'; end if;
  update profiles set auth_user_id = null where household_id = v_hh and auth_user_id = p_user;
  delete from household_members where household_id = v_hh and user_id = p_user and role <> 'owner';
  if not found then raise exception 'login not found'; end if;
end $$;
revoke all on function public.remove_member(uuid) from public;
grant execute on function public.remove_member(uuid) to authenticated, service_role;

-- ── 6 · created_by / updated_by ──────────────────────────────────────────
alter table public.expenses          add column if not exists created_by uuid, add column if not exists updated_by uuid;
alter table public.fund_transactions add column if not exists created_by uuid, add column if not exists updated_by uuid;
alter table public.statements        add column if not exists created_by uuid, add column if not exists updated_by uuid;
alter table public.pot_swaps         add column if not exists created_by uuid, add column if not exists updated_by uuid;
create or replace function public.bh_stamp_by()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then new.created_by := coalesce(new.created_by, auth.uid()); new.updated_by := coalesce(auth.uid(), new.updated_by);
  else new.updated_by := coalesce(auth.uid(), new.updated_by); end if;
  return new;
end $$;
do $$
declare t text;
begin
  foreach t in array array['expenses','fund_transactions','statements','pot_swaps'] loop
    execute format('drop trigger if exists zx_%s_by on public.%I', t, t);
    execute format('create trigger zx_%s_by before insert or update on public.%I for each row execute function public.bh_stamp_by()', t, t);
  end loop;
end $$;
-- backfill: everything so far was the owner
update public.expenses e set created_by = h.owner_user_id from households h where h.id = e.household_id and e.created_by is null;
update public.fund_transactions e set created_by = h.owner_user_id from households h where h.id = e.household_id and e.created_by is null;
update public.statements e set created_by = h.owner_user_id from households h where h.id = e.household_id and e.created_by is null;
update public.pot_swaps e set created_by = h.owner_user_id from households h where h.id = e.household_id and e.created_by is null;

-- the compatibility views expose the new columns
create or replace view public.daily_expenses with (security_invoker = true) as
  select id, household_id, date, description, category, amount, currency, payer_profile_id, paid_with, comments,
         legacy_sync_id, created_at, payment_method_id, reconciled_at, reconciled_statement_id, reconciled_by, pot_swap_id, updated_at,
         pot_fund_id, created_by, updated_by
    from public.expenses where trip_id is null
  with cascaded check option;
create or replace view public.travel_expenses with (security_invoker = true) as
  select id, household_id, trip_id, date, description, category, amount, currency, payer_profile_id, paid_with, comments,
         sent_to_fund, legacy_sync_id, created_at, payment_method_id, reconciled_at, reconciled_statement_id, reconciled_by, pot_swap_id, updated_at,
         pot_fund_id, created_by, updated_by
    from public.expenses where trip_id is not null
  with cascaded check option;

-- ── 7 · audit log ────────────────────────────────────────────────────────
create table if not exists public.audit_log (
  id            bigserial primary key,
  household_id  uuid not null,
  table_name    text not null,
  row_id        uuid,
  op            text not null check (op in ('insert', 'update', 'delete')),
  at            timestamptz not null default now(),
  by_user       uuid,
  label         text,              -- what the row is, in words (description / remarks / name) at the time
  changed       text[],            -- columns that changed (update only)
  before        jsonb,             -- changed columns' old values (update) · the whole row (delete)
  after         jsonb              -- changed columns' new values (update) · the whole row (insert)
);
create index if not exists audit_log_hh_at on public.audit_log (household_id, at desc);
create index if not exists audit_log_row on public.audit_log (table_name, row_id);
alter table public.audit_log enable row level security;
drop policy if exists "audit: read own household" on public.audit_log;
create policy "audit: read own household" on public.audit_log for select using (household_id in (select bh_member_of()));
grant select on public.audit_log to authenticated, service_role;
grant usage, select on sequence public.audit_log_id_seq to authenticated, service_role;

create or replace function public.bh_audit()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_old jsonb; v_new jsonb; v_hh uuid; v_id uuid; v_keys text[]; v_b jsonb := '{}'; v_a jsonb := '{}'; k text; v_label text;
  v_skip text[] := array['updated_at', 'updated_by', 'created_at'];
  lbl jsonb;
begin
  if tg_op = 'DELETE' then
    v_old := to_jsonb(old);
    v_hh := case when tg_table_name = 'households' then old.id else (v_old->>'household_id')::uuid end;
    v_label := coalesce(v_old->>'description', v_old->>'remarks', v_old->>'income_source', v_old->>'display_name', v_old->>'name', v_old->>'label', v_old->>'source_name', v_old->>'category_group');
    insert into audit_log (household_id, table_name, row_id, op, by_user, label, before)
    values (v_hh, tg_table_name, (v_old->>'id')::uuid, 'delete', auth.uid(), v_label, v_old - v_skip);
    return old;
  end if;
  v_new := to_jsonb(new);
  v_hh := case when tg_table_name = 'households' then new.id else (v_new->>'household_id')::uuid end;
  v_id := (v_new->>'id')::uuid;
  v_label := coalesce(v_new->>'description', v_new->>'remarks', v_new->>'income_source', v_new->>'display_name', v_new->>'name', v_new->>'label', v_new->>'source_name', v_new->>'category_group');
  if tg_op = 'INSERT' then
    insert into audit_log (household_id, table_name, row_id, op, by_user, label, after)
    values (v_hh, tg_table_name, v_id, 'insert', auth.uid(), v_label, v_new - v_skip);
    return new;
  end if;
  v_old := to_jsonb(old);
  for k in select jsonb_object_keys(v_new) loop
    if k = any(v_skip) then continue; end if;
    if v_new->k is distinct from v_old->k then
      v_keys := array_append(v_keys, k);
      v_b := v_b || jsonb_build_object(k, v_old->k);
      v_a := v_a || jsonb_build_object(k, v_new->k);
    end if;
  end loop;
  if v_keys is null then return new; end if;      -- nothing visible changed
  insert into audit_log (household_id, table_name, row_id, op, by_user, label, changed, before, after)
  values (v_hh, tg_table_name, v_id, 'update', auth.uid(), v_label, v_keys, v_b, v_a);
  return new;
end $$;
do $$
declare t text;
begin
  -- (expense_splits are derived from the expense row — logging them would only add noise)
  foreach t in array array['expenses','fund_transactions','statements','pot_swaps','funds','payment_methods',
                           'categories','category_budgets','fund_budgets','income_budgets','trips','profiles','households','household_members'] loop
    execute format('drop trigger if exists zzz_%s_audit on public.%I', t, t);
    execute format('create trigger zzz_%s_audit after insert or update or delete on public.%I for each row execute function public.bh_audit()', t, t);
  end loop;
end $$;

-- same-household checks for the new references
create or replace function public.bh_check_refs()
returns trigger language plpgsql as $$
begin
  if tg_table_name = 'expenses' then
    perform bh_assert_hh('public.profiles', new.payer_profile_id, new.household_id, 'payer');
    perform bh_assert_hh('public.payment_methods', new.payment_method_id, new.household_id, 'card');
    perform bh_assert_hh('public.statements', new.reconciled_statement_id, new.household_id, 'statement');
    perform bh_assert_hh('public.pot_swaps', new.pot_swap_id, new.household_id, 'pot swap');
    perform bh_assert_hh('public.funds', new.pot_fund_id, new.household_id, 'pot');
    if new.trip_id is not null then perform bh_assert_hh('public.trips', new.trip_id, new.household_id, 'trip'); end if;
  end if;
  if tg_table_name = 'fund_transactions' then
    perform bh_assert_hh('public.funds', new.fund_id, new.household_id, 'fund');
    perform bh_assert_hh('public.payment_methods', new.account_payment_method_id, new.household_id, 'account');
    perform bh_assert_hh('public.statements', new.reconciled_statement_id, new.household_id, 'statement');
    perform bh_assert_hh('public.payment_methods', new.settles_payment_method_id, new.household_id, 'card');
    perform bh_assert_hh('public.statements', new.settles_statement_id, new.household_id, 'statement');
  end if;
  if tg_table_name = 'statements' then
    perform bh_assert_hh('public.payment_methods', new.payment_method_id, new.household_id, 'card');
  end if;
  if tg_table_name = 'category_budgets' then
    perform bh_assert_hh('public.funds', new.pot_fund_id, new.household_id, 'pot');
  end if;
  if tg_table_name = 'fund_budgets' then
    perform bh_assert_hh('public.funds', new.fund_id, new.household_id, 'fund');
  end if;
  if tg_table_name = 'expense_splits' then
    perform bh_assert_hh('public.profiles', new.profile_id, new.household_id, 'person');
  end if;
  if tg_table_name = 'payment_methods' then
    perform bh_assert_hh('public.profiles', new.profile_id, new.household_id, 'owner');
    perform bh_assert_hh('public.funds', new.pot_fund_id, new.household_id, 'pot');
  end if;
  if tg_table_name = 'pot_swaps' then
    perform bh_assert_hh('public.funds', new.cover_fund_id, new.household_id, 'cover fund');
    perform bh_assert_hh('public.funds', new.land_fund_id, new.household_id, 'landing fund');
    perform bh_assert_hh('public.funds', new.bank_from_fund_id, new.household_id, 'bank-side fund');
    perform bh_assert_hh('public.funds', new.bank_to_fund_id, new.household_id, 'bank pot');
  end if;
  if tg_table_name = 'household_members' or tg_table_name = 'member_invites' then
    perform bh_assert_hh('public.profiles', new.profile_id, new.household_id, 'person');
  end if;
  if tg_table_name = 'households' then
    perform bh_assert_hh('public.funds', new.travel_fund_id, new.id, 'travel fund');
  end if;
  return new;
end $$;
drop trigger if exists household_members_check_refs on public.household_members;
create trigger household_members_check_refs before insert or update on public.household_members for each row execute function public.bh_check_refs();
drop trigger if exists member_invites_check_refs on public.member_invites;
create trigger member_invites_check_refs before insert or update on public.member_invites for each row execute function public.bh_check_refs();

-- ── proof ────────────────────────────────────────────────────────────────
do $$
declare v_h int; v_m int;
begin
  select count(*) into v_h from households; select count(*) into v_m from household_members where role = 'owner';
  if v_h <> v_m then raise exception 'members: % households but % owner rows', v_h, v_m; end if;
  raise notice 'members ok: % households, each with an owner login', v_h;
end $$;

notify pgrst, 'reload schema';
commit;
