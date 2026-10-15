-- Privilege lockdown (v2 sprint 1, 15 Oct 2026). v2 review: DB-2 #1–3, Eng-2 F2/F8/F11, Eng-1 F1.
--
--  1  Nothing new is executable by the API roles unless a migration grants it. Supabase's legacy
--     default privileges granted EXECUTE on every new public function straight to anon and
--     authenticated, and "revoke … from public" never removed those grants. From now on every
--     migration states its own grants — functions, tables, views, sequences (CLAUDE.md), which also
--     covers Supabase's 30 Oct change.
--  2  anon (the public app key, not signed in) may run only the two sign-up checks and the two
--     membership helpers that RLS evaluates. It holds no table rights at all.
--  3  Internal helpers: restamp_pots and seed_default_categories are reachable only from server
--     functions; bh_category_for / bh_group_for (called by write triggers) refuse a household the
--     caller doesn't write to.
--  4  households: a member can rename the household and set the joint label and travel fund. Owner,
--     pot start and deletion are not client-writable. No client may TRUNCATE any table.
--  5  Direct client writes (PostgREST roles) can't forge server-owned columns: on insert the
--     reconciliation marks, bin date and pot stamp are cleared and created_by is the signed-in
--     login; on update created_by, the bin date and the pot stamp keep their value (soft delete and
--     restore go through soft_delete_rows / restore_rows). Server functions run as their owner and
--     are unaffected.
--  6  One side of a transfer (or a card-payment leg, or a swap leg) can't be changed on its own:
--     amount, date, fund, type, kind and group are frozen for direct client writes on grouped rows.
--
-- No balance can move: this migration touches privileges and guards only (asserted at the end).
begin;
create temp table _before as select fund_id, balance from public.fund_balances;

-- ── 1 · no implicit grants on anything created from now on ───────────────
alter default privileges for role postgres in schema public revoke execute on functions from public, anon, authenticated;
-- Postgres grants EXECUTE to PUBLIC globally, which a per-schema rule can't take back
alter default privileges for role postgres revoke execute on functions from public;
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;

-- ── 2 · anon: the sign-up checks only ────────────────────────────────────
revoke execute on all functions in schema public from public, anon;
grant execute on function public.check_invite(text), public.invite_info(text) to anon;
grant execute on function public.bh_member_of(), public.bh_writer_of() to anon;   -- RLS evaluates them; both return nothing without a login
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
revoke truncate, references, trigger on all tables in schema public from authenticated;

-- ── 3 · internal helpers ─────────────────────────────────────────────────
revoke execute on function public.restamp_pots(uuid, date, date) from authenticated;
revoke execute on function public.seed_default_categories(uuid) from authenticated;

-- writers reach these through the category triggers on their own rows; a signed-in caller may only
-- touch a household it writes to (no login = a migration or the service role)
create or replace function public.bh_assert_writer(p_hh uuid)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is not null and not exists
     (select 1 from household_members where user_id = auth.uid() and household_id = p_hh and role in ('owner', 'member')) then
    raise exception 'not your household — or your login is view-only' using errcode = '42501';
  end if;
end $$;
revoke execute on function public.bh_assert_writer(uuid) from public, anon;
grant execute on function public.bh_assert_writer(uuid) to authenticated, service_role;

create or replace function public.bh_group_for(p_hh uuid, p_kind text, p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_name text := trim(coalesce(p_name, ''));
begin
  perform bh_assert_writer(p_hh);
  if v_name = '' then raise exception 'a category needs a group'; end if;
  select id into v_id from category_groups where household_id = p_hh and kind = p_kind and name = v_name;
  if v_id is null then
    insert into category_groups (household_id, kind, name, sort_order)
    values (p_hh, p_kind, v_name, coalesce((select max(sort_order) + 1 from category_groups where household_id = p_hh and kind = p_kind), 0))
    on conflict (household_id, kind, name) do update set name = excluded.name
    returning id into v_id;
  end if;
  return v_id;
end $$;
create or replace function public.bh_category_for(p_hh uuid, p_kind text, p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_name text := trim(coalesce(p_name, ''));
begin
  perform bh_assert_writer(p_hh);
  if v_name = '' then raise exception 'pick a category'; end if;
  select id into v_id from categories where household_id = p_hh and kind = p_kind and name = v_name;
  if v_id is null then
    -- an unknown name (an import, an old client) gets a real row under "Other" rather than a dangling text
    insert into categories (household_id, kind, name, group_name, icon, sort_order)
    values (p_hh, p_kind, v_name, case when p_kind = 'travel' then '🗂️ Other' else 'Other' end,
            case when p_kind = 'travel' then '🗂️' else '🛍️' end,
            coalesce((select max(sort_order) + 1 from categories where household_id = p_hh and kind = p_kind), 0))
    returning id into v_id;
  end if;
  return v_id;
end $$;
revoke execute on function public.bh_group_for(uuid, text, text), public.bh_category_for(uuid, text, text) from public, anon;
grant execute on function public.bh_group_for(uuid, text, text), public.bh_category_for(uuid, text, text) to authenticated, service_role;

-- ── 4 · the household record ─────────────────────────────────────────────
revoke insert, update, delete on public.households from authenticated;
grant update (name, joint_label, travel_fund_id) on public.households to authenticated;
drop policy if exists "household: delete own" on public.households;

-- ── 5 + 6 · direct client writes can't forge server-owned columns or split a group ──
-- current_user is the API role for a direct write and the function owner inside a server function
create or replace function public.bh_expense_client_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if tg_op = 'INSERT' then
    new.reconciled_at := null; new.reconciled_by := null; new.reconciled_statement_id := null;   -- cash re-ticks itself next
    new.deleted_at := null;
    new.pot_fund_id := null;                                                                     -- stamped by the server
    new.created_by := auth.uid();
  else
    new.created_by := old.created_by;
    new.deleted_at := old.deleted_at;
    new.pot_fund_id := old.pot_fund_id;                                                          -- re-stamped when its inputs change
  end if;
  return new;
end $$;
drop trigger if exists b0_expenses_client_guard on public.expenses;
-- "b0_" fires first among the BEFORE triggers (they fire in name order)
create trigger b0_expenses_client_guard before insert or update on public.expenses
  for each row execute function public.bh_expense_client_guard();

create or replace function public.bh_fund_client_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if tg_op = 'INSERT' then
    new.reconciled_at := null; new.reconciled_by := null; new.reconciled_statement_id := null;   -- plan rows and transfers re-tick themselves next
    new.deleted_at := null; new.reviewed_at := null;
    new.created_by := auth.uid();
    return new;
  end if;
  new.created_by := old.created_by;
  new.deleted_at := old.deleted_at;
  if old.transfer_group_id is not null and (
       new.amount is distinct from old.amount or new.date is distinct from old.date
    or new.fund_id is distinct from old.fund_id or new.type is distinct from old.type
    or new.kind is distinct from old.kind or new.transfer_group_id is distinct from old.transfer_group_id) then
    raise exception 'one side of a transfer can''t be changed on its own — delete both sides and enter it again' using errcode = 'P0001';
  end if;
  if old.transfer_group_id is null and new.transfer_group_id is not null then
    raise exception 'rows are paired by the server, not by an edit' using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists b0_fund_client_guard on public.fund_transactions_all;
create trigger b0_fund_client_guard before insert or update on public.fund_transactions_all
  for each row execute function public.bh_fund_client_guard();

-- trigger functions are fired, not called; nobody needs EXECUTE on them
revoke execute on function public.bh_expense_client_guard(), public.bh_fund_client_guard() from public, anon, authenticated;

-- ── proof ────────────────────────────────────────────────────────────────
do $$
declare v_bad int; v_fn text;
begin
  select count(*) into v_bad from _before b join public.fund_balances a using (fund_id) where abs(a.balance - b.balance) > 0.005;
  if v_bad > 0 then raise exception 'privilege lockdown: % fund balances changed', v_bad; end if;
  select string_agg(p.proname, ', ') into v_fn from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not in ('check_invite', 'invite_info', 'bh_member_of', 'bh_writer_of');
  if v_fn is not null then raise exception 'privilege lockdown: anon can still run %', v_fn; end if;
  raise notice 'privilege lockdown ok: balances unchanged, anon runs only the sign-up checks';
end $$;
drop table _before;
notify pgrst, 'reload schema';
commit;
