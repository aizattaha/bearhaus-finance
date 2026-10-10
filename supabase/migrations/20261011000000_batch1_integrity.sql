-- QA round 1 · batch 1 (11 Oct 2026) — integrity & security, plus three Desk rules from Aizat.
-- See docs/qa/2026-10-10-round-1.md (F2–F8) and the handbook.
--
--  F2  one household per login (unique index + no direct INSERT through RLS)
--  F3  reconciled_* can only change through reconcile_rows / unreconcile_rows
--  F4  a transfer is a unit: deleting one half deletes the other
--  F5  a row may only point at its own household's profile / fund / card / trip / statement
--  F6  check_invite slowed down (it is called by the sign-up form, so it stays callable)
--  F7  closed statements are read-only (reconcile/unreconcile refuse rows on a closed statement)
--  F8  onboarding: a spending pot per currency, Cash/bank cards multi-currency, starter funds
--      suffixed by country when there are several countries, starter cards with kind
--  +   payer follows the card: moving a row onto a personal card makes its owner the payer

begin;

-- ── F2 · one household per login ─────────────────────────────────────────
create unique index if not exists households_one_per_owner on public.households (owner_user_id) where owner_user_id is not null;
drop policy if exists "own household only" on public.households;
create policy "household: read own" on public.households for select using (owner_user_id = (select auth.uid()));
create policy "household: update own" on public.households for update using (owner_user_id = (select auth.uid())) with check (owner_user_id = (select auth.uid()));
create policy "household: delete own" on public.households for delete using (owner_user_id = (select auth.uid()));
-- no INSERT policy: households are created by create_household_setup (security definer) only

-- ── F5 · same-household references (one trigger, every referencing table) ──
create or replace function public.bh_assert_hh(p_table regclass, p_id uuid, p_hh uuid, p_what text)
returns void language plpgsql stable as $$
declare v_hh uuid;
begin
  if p_id is null then return; end if;
  execute format('select household_id from %s where id = $1', p_table) into v_hh using p_id;
  if v_hh is null then raise exception '% not found', p_what using errcode = '23503'; end if;
  if v_hh <> p_hh then raise exception '% belongs to another household', p_what using errcode = '42501'; end if;
end $$;

create or replace function public.bh_check_refs()
returns trigger language plpgsql as $$
begin
  if tg_table_name in ('daily_expenses', 'travel_expenses') then
    perform bh_assert_hh('public.profiles', new.payer_profile_id, new.household_id, 'payer');
    perform bh_assert_hh('public.payment_methods', new.payment_method_id, new.household_id, 'card');
    perform bh_assert_hh('public.statements', new.reconciled_statement_id, new.household_id, 'statement');
    perform bh_assert_hh('public.pot_swaps', new.pot_swap_id, new.household_id, 'pot swap');
  end if;
  if tg_table_name = 'travel_expenses' then
    perform bh_assert_hh('public.trips', new.trip_id, new.household_id, 'trip');
  end if;
  if tg_table_name = 'fund_transactions' then
    perform bh_assert_hh('public.funds', new.fund_id, new.household_id, 'fund');
    perform bh_assert_hh('public.payment_methods', new.account_payment_method_id, new.household_id, 'account');
    perform bh_assert_hh('public.statements', new.reconciled_statement_id, new.household_id, 'statement');
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
  if tg_table_name in ('daily_expense_splits', 'travel_expense_splits') then
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
  if tg_table_name = 'households' then
    perform bh_assert_hh('public.funds', new.travel_fund_id, new.id, 'travel fund');
  end if;
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['daily_expenses','travel_expenses','fund_transactions','statements','category_budgets','fund_budgets','daily_expense_splits','travel_expense_splits','payment_methods','pot_swaps','households'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_check_refs', t);
    execute format('create trigger %I before insert or update on public.%I for each row execute function public.bh_check_refs()', t || '_check_refs', t);
  end loop;
end $$;

-- ── F3 + payer-follows-card · expense triggers ───────────────────────────
create or replace function public.bh_expense_before_write()
returns trigger language plpgsql as $$
declare v_kind text; v_owner uuid;
begin
  -- keep the id in step with the name (older app builds only send the name)
  if new.payment_method_id is null and coalesce(new.paid_with, '') <> '' then
    select id into new.payment_method_id from payment_methods
     where household_id = new.household_id and name = new.paid_with limit 1;
  end if;
  if new.payment_method_id is not null and (tg_op = 'INSERT' or new.payment_method_id is distinct from old.payment_method_id) then
    select name into new.paid_with from payment_methods where id = new.payment_method_id;
  end if;
  if new.paid_with is null then new.paid_with := ''; end if;   -- the column is not null; '' means no card
  select kind, profile_id into v_kind, v_owner from payment_methods where id = new.payment_method_id;
  -- a personal card names its owner as the payer: always when a row is moved onto the card,
  -- and when a new row arrives with nobody named (Aizat, 11 Oct 2026)
  if v_owner is not null and (
       (tg_op = 'UPDATE' and new.payment_method_id is distinct from old.payment_method_id)
    or (tg_op = 'INSERT' and new.payer_profile_id is null)) then
    new.payer_profile_id := v_owner;
  end if;
  -- cash ticks itself when the row is created or switched TO cash; moving off cash clears the automatic tick
  if v_kind = 'cash' and new.reconciled_at is null
     and (tg_op = 'INSERT' or new.payment_method_id is distinct from old.payment_method_id) then
    new.reconciled_at := now(); new.reconciled_by := 'auto'; new.reconciled_statement_id := null;
  elsif tg_op = 'UPDATE' and v_kind is distinct from 'cash' and old.reconciled_by = 'auto' and new.reconciled_by = 'auto'
        and new.payment_method_id is distinct from old.payment_method_id then
    new.reconciled_at := null; new.reconciled_by := null; new.reconciled_statement_id := null;
  end if;
  return new;
end;
$$;

create or replace function public.bh_expense_lock()
returns trigger language plpgsql as $$
declare
  v_via_rpc boolean := coalesce(current_setting('bh.via_rpc', true), '') = 'on';
  v_auto_set boolean; v_auto_clear boolean;
begin
  if tg_op = 'DELETE' then
    if old.reconciled_at is not null then
      raise exception 'locked: this row is reconciled — un-reconcile it first' using errcode = 'P0001';
    end if;
    return old;
  end if;
  -- the two moves bh_expense_before_write makes on its own: the cash tick, and its removal when a row leaves cash
  v_auto_set   := old.reconciled_at is null and new.reconciled_by = 'auto' and new.reconciled_at is not null;
  v_auto_clear := old.reconciled_by = 'auto' and new.reconciled_at is null and new.payment_method_id is distinct from old.payment_method_id;
  -- otherwise the reconciliation marks only move through reconcile_rows / unreconcile_rows
  if not v_via_rpc and not v_auto_set and not v_auto_clear
     and (new.reconciled_at is distinct from old.reconciled_at
          or new.reconciled_by is distinct from old.reconciled_by
          or new.reconciled_statement_id is distinct from old.reconciled_statement_id) then
    raise exception 'locked: use un-reconcile to change the reconciliation of this row' using errcode = 'P0001';
  end if;
  if old.reconciled_at is not null and not v_auto_clear
     and (new.amount is distinct from old.amount or new.date is distinct from old.date
          or new.currency is distinct from old.currency
          or new.payment_method_id is distinct from old.payment_method_id
          or new.payer_profile_id is distinct from old.payer_profile_id) then
    raise exception 'locked: this row is reconciled — un-reconcile it to change amount, date, currency, card or payer' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

-- ── F3 + F4 · fund triggers ──────────────────────────────────────────────
create or replace function public.bh_fund_lock()
returns trigger language plpgsql as $$
declare v_via_rpc boolean := coalesce(current_setting('bh.via_rpc', true), '') = 'on';
begin
  if tg_op = 'DELETE' then
    if old.reconciled_at is not null and coalesce(old.reconciled_by, '') = 'manual' then
      raise exception 'locked: this row is reconciled — un-reconcile it first' using errcode = 'P0001';
    end if;
    return old;
  end if;
  if not v_via_rpc
     and (new.reconciled_at is distinct from old.reconciled_at
          or new.reconciled_by is distinct from old.reconciled_by
          or new.reconciled_statement_id is distinct from old.reconciled_statement_id) then
    raise exception 'locked: use un-reconcile to change the reconciliation of this row' using errcode = 'P0001';
  end if;
  if old.reconciled_at is not null and coalesce(old.reconciled_by, '') = 'manual'
     and (new.amount is distinct from old.amount or new.date is distinct from old.date
          or new.type is distinct from old.type or new.fund_id is distinct from old.fund_id) then
    raise exception 'locked: this row is reconciled — un-reconcile it to change amount, date, type or fund' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

-- a transfer is one movement written as two rows: when one half goes, the other goes too
-- (AFTER trigger, so a statement that deletes both halves itself doesn't trip over its own work)
create or replace function public.bh_fund_pair_delete()
returns trigger language plpgsql as $$
begin
  if old.transfer_group_id is not null then
    delete from fund_transactions where transfer_group_id = old.transfer_group_id and id <> old.id;
  end if;
  return old;
end $$;
drop trigger if exists fund_transactions_pair on public.fund_transactions;
create trigger fund_transactions_pair after delete on public.fund_transactions for each row execute function public.bh_fund_pair_delete();

-- ── F3 + F7 · the RPCs set the flag and respect closed statements ────────
create or replace function public.reconcile_rows(p_kind text, p_ids uuid[], p_statement uuid default null)
returns integer language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_n integer; v_closed timestamptz;
begin
  select id into strict v_hh from households where owner_user_id = auth.uid();
  if p_statement is not null then
    select closed_at into v_closed from statements s where s.id = p_statement and s.household_id = v_hh;
    if not found then raise exception 'statement not found'; end if;
    if v_closed is not null then raise exception 'this statement is closed — reopen it first' using errcode = 'P0001'; end if;
  end if;
  perform set_config('bh.via_rpc', 'on', true);
  if p_kind = 'daily' then
    update daily_expenses set reconciled_at = now(), reconciled_by = 'manual', reconciled_statement_id = p_statement
     where household_id = v_hh and id = any(p_ids) and reconciled_at is null;
  elsif p_kind = 'travel' then
    update travel_expenses set reconciled_at = now(), reconciled_by = 'manual', reconciled_statement_id = p_statement
     where household_id = v_hh and id = any(p_ids) and reconciled_at is null;
  elsif p_kind = 'fund' then
    update fund_transactions set reconciled_at = now(), reconciled_by = 'manual', reconciled_statement_id = p_statement
     where household_id = v_hh and reconciled_at is null
       and (id = any(p_ids) or transfer_group_id in (select transfer_group_id from fund_transactions where id = any(p_ids) and transfer_group_id is not null));
  else raise exception 'unknown kind %', p_kind; end if;
  get diagnostics v_n = row_count;
  perform set_config('bh.via_rpc', 'off', true);
  return v_n;
exception when no_data_found then raise exception 'no household';
end $$;

create or replace function public.unreconcile_rows(p_kind text, p_ids uuid[])
returns integer language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_n integer; v_closed int;
begin
  select id into strict v_hh from households where owner_user_id = auth.uid();
  -- rows ticked on a closed statement stay put until the statement is reopened on the Desk
  if p_kind = 'daily' then
    select count(*) into v_closed from daily_expenses d join statements s on s.id = d.reconciled_statement_id where d.household_id = v_hh and d.id = any(p_ids) and s.closed_at is not null;
  elsif p_kind = 'travel' then
    select count(*) into v_closed from travel_expenses d join statements s on s.id = d.reconciled_statement_id where d.household_id = v_hh and d.id = any(p_ids) and s.closed_at is not null;
  elsif p_kind = 'fund' then
    select count(*) into v_closed from fund_transactions d join statements s on s.id = d.reconciled_statement_id where d.household_id = v_hh and d.id = any(p_ids) and s.closed_at is not null;
  else raise exception 'unknown kind %', p_kind; end if;
  if v_closed > 0 then raise exception 'this row is on a closed statement — reopen the statement on the Desk first' using errcode = 'P0001'; end if;
  perform set_config('bh.via_rpc', 'on', true);
  if p_kind = 'daily' then
    update daily_expenses set reconciled_at = null, reconciled_by = null, reconciled_statement_id = null
     where household_id = v_hh and id = any(p_ids) and reconciled_at is not null;
  elsif p_kind = 'travel' then
    update travel_expenses set reconciled_at = null, reconciled_by = null, reconciled_statement_id = null
     where household_id = v_hh and id = any(p_ids) and reconciled_at is not null;
  else
    update fund_transactions set reconciled_at = null, reconciled_by = null, reconciled_statement_id = null
     where household_id = v_hh and reconciled_at is not null
       and (id = any(p_ids) or transfer_group_id in (select transfer_group_id from fund_transactions where id = any(p_ids) and transfer_group_id is not null));
  end if;
  get diagnostics v_n = row_count;
  perform set_config('bh.via_rpc', 'off', true);
  return v_n;
exception when no_data_found then raise exception 'no household';
end $$;

-- ── F6 · check_invite: still callable before sign-up, no longer free to brute-force ──
create or replace function public.check_invite(p_code text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  perform pg_sleep(0.4);
  return exists (select 1 from beta_invites where lower(code) = lower(trim(p_code)) and used_count < max_uses);
end $$;

-- ── F8 · onboarding defaults ─────────────────────────────────────────────
create or replace function public.create_household_setup(
  p_code        text,
  p_household   text,
  p_people      text[],
  p_joint_label text,
  p_countries   text[],
  p_currencies  text[] default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
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
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if exists (select 1 from households where owner_user_id = v_uid) then raise exception 'this login already has a household'; end if;
  if coalesce(array_length(p_people, 1), 0) = 0 then raise exception 'add at least one person'; end if;
  if coalesce(array_length(p_people, 1), 0) > 6 then raise exception 'six people max for now'; end if;
  if coalesce(array_length(p_countries, 1), 0) = 0 then raise exception 'pick at least one country'; end if;
  if coalesce(array_length(p_countries, 1), 0) > 4 then raise exception 'four countries max for now'; end if;
  if p_currencies is not null
     and coalesce(array_length(p_currencies, 1), 0) <> coalesce(array_length(p_countries, 1), 0) then
    raise exception 'countries and currencies don''t line up';
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
      insert into profiles (household_id, display_name, sort_order) values (v_hh, trim(v_person), v_psort);
      v_psort := v_psort + 1;
    end if;
  end loop;

  for v_i in 1 .. array_length(p_countries, 1) loop
    v_cc := upper(trim(p_countries[v_i]));
    if v_cc !~ '^[A-Z]{2}$' then raise exception 'country codes are two letters — got %', v_cc; end if;
    v_cur := case when p_currencies is not null then upper(trim(p_currencies[v_i]))
                  when v_cc = 'SG' then 'SGD' when v_cc = 'AU' then 'AUD' else null end;
    if v_cur is null or v_cur !~ '^[A-Z]{3}$' then raise exception 'missing or invalid currency for %', v_cc; end if;
    -- fund names are unique per household: several countries → suffix the country
    v_sfx := case when array_length(p_countries, 1) > 1 then ' ' || v_cc else '' end;
    -- every currency gets its own spending pot (QA-B1)
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

  -- starter cards: Cash (auto-reconciles) and one bank card per person; both usable in any currency
  insert into payment_methods (household_id, name, profile_id, sort_order, kind, currency)
  values (v_hh, 'Cash', null, 0, 'cash', null);
  insert into payment_methods (household_id, name, profile_id, sort_order, kind, currency)
  select v_hh, 'Bank card — ' || display_name, id, 1 + sort_order, 'debit_card', null
  from profiles where household_id = v_hh;

  perform seed_default_categories(v_hh);
  return v_hh;
end;
$$;

commit;
