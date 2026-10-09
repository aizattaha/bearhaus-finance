-- ============================================================
-- QA hardening (qa-report-2026-07-23.md)
--  QA-3  save_month_plan   — plan wipe-and-rewrite in ONE transaction
--  QA-4  send_trip_to_fund — fund debit + sent flags in ONE transaction
--  QA-5  save_expense      — expense update + split rebuild in ONE transaction
--  QA-13 format constraints on currency / category icons (new rows only)
--  QA-18 starter funds get a real group name (new households; BearHaus untouched)
-- ============================================================

-- QA-3 ─ the whole month's plan, atomically -------------------
create or replace function public.save_month_plan(
  p_month date, p_inc jsonb, p_cat jsonb, p_fb jsonb
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_hh uuid;
begin
  select id into v_hh from households where owner_user_id = auth.uid();
  if v_hh is null then raise exception 'no household'; end if;

  delete from income_budgets where household_id = v_hh and month = p_month;
  insert into income_budgets (household_id, month, source_name, currency, amount)
  select v_hh, p_month, x.source_name, x.currency, x.amount
  from jsonb_to_recordset(coalesce(p_inc, '[]'::jsonb)) as x(source_name text, currency text, amount numeric)
  where x.amount > 0;

  delete from category_budgets where household_id = v_hh and month = p_month;
  insert into category_budgets (household_id, month, category_group, currency, amount)
  select v_hh, p_month, x.category_group, x.currency, x.amount
  from jsonb_to_recordset(coalesce(p_cat, '[]'::jsonb)) as x(category_group text, currency text, amount numeric)
  where x.amount > 0;

  delete from fund_budgets where household_id = v_hh and month = p_month;
  insert into fund_budgets (household_id, month, fund_id, amount)
  select v_hh, p_month, x.fund_id, x.amount
  from jsonb_to_recordset(coalesce(p_fb, '[]'::jsonb)) as x(fund_id uuid, amount numeric)
  where x.amount > 0
    and exists (select 1 from funds f where f.id = x.fund_id and f.household_id = v_hh);
end;
$$;
revoke all on function public.save_month_plan(date, jsonb, jsonb, jsonb) from public;
grant execute on function public.save_month_plan(date, jsonb, jsonb, jsonb) to authenticated;

-- QA-4 ─ settle a trip into its fund, atomically --------------
create or replace function public.send_trip_to_fund(
  p_trip uuid, p_fund uuid, p_date date
) returns numeric
language plpgsql security definer set search_path = public as $$
declare
  v_hh uuid; v_cur text; v_name text; v_total numeric;
begin
  select id into v_hh from households where owner_user_id = auth.uid();
  if v_hh is null then raise exception 'no household'; end if;
  select currency into v_cur from funds where id = p_fund and household_id = v_hh;
  if v_cur is null then raise exception 'fund not found'; end if;
  select name into v_name from trips where id = p_trip and household_id = v_hh;
  if v_name is null then raise exception 'trip not found'; end if;

  select coalesce(sum(amount), 0) into v_total
  from travel_expenses
  where trip_id = p_trip and household_id = v_hh and not sent_to_fund and currency = v_cur;
  if v_total <= 0 then raise exception 'nothing unsent in this currency'; end if;

  insert into fund_transactions (household_id, fund_id, type, date, amount, remarks, origin)
  values (v_hh, p_fund, 'expense', p_date, v_total, 'Travel: ' || v_name, 'manual');

  update travel_expenses set sent_to_fund = true
  where trip_id = p_trip and household_id = v_hh and not sent_to_fund and currency = v_cur;

  return v_total;
end;
$$;
revoke all on function public.send_trip_to_fund(uuid, uuid, date) from public;
grant execute on function public.send_trip_to_fund(uuid, uuid, date) to authenticated;

-- QA-5 ─ edit an expense and rebuild its splits, atomically ---
create or replace function public.save_expense(
  p_kind text, p_id uuid, p_date date, p_description text, p_category text,
  p_amount numeric, p_currency text, p_payer uuid, p_paid_with text, p_comments text
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_hh uuid;
begin
  select id into v_hh from households where owner_user_id = auth.uid();
  if v_hh is null then raise exception 'no household'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount must be positive'; end if;
  if p_payer is not null and not exists
     (select 1 from profiles where id = p_payer and household_id = v_hh) then
    raise exception 'payer not found';
  end if;

  if p_kind = 'daily' then
    update daily_expenses
       set date = p_date, description = p_description, category = p_category,
           amount = p_amount, currency = p_currency, payer_profile_id = p_payer,
           paid_with = p_paid_with, comments = p_comments
     where id = p_id and household_id = v_hh;
    if not found then raise exception 'expense not found'; end if;
    delete from daily_expense_splits where expense_id = p_id;
    if p_payer is not null then
      insert into daily_expense_splits (household_id, expense_id, profile_id, amount)
      values (v_hh, p_id, p_payer, p_amount);
    end if;
    insert into daily_expense_splits (household_id, expense_id, profile_id, amount)
    values (v_hh, p_id, null, -p_amount);
  elsif p_kind = 'travel' then
    update travel_expenses
       set date = p_date, description = p_description, category = p_category,
           amount = p_amount, currency = p_currency, payer_profile_id = p_payer,
           paid_with = p_paid_with, comments = p_comments
     where id = p_id and household_id = v_hh;
    if not found then raise exception 'expense not found'; end if;
    delete from travel_expense_splits where expense_id = p_id;
    if p_payer is not null then
      insert into travel_expense_splits (household_id, expense_id, profile_id, amount)
      values (v_hh, p_id, p_payer, p_amount);
    end if;
    insert into travel_expense_splits (household_id, expense_id, profile_id, amount)
    values (v_hh, p_id, null, -p_amount);
  else
    raise exception 'unknown kind %', p_kind;
  end if;
end;
$$;
revoke all on function public.save_expense(text, uuid, date, text, text, numeric, text, uuid, text, text) from public;
grant execute on function public.save_expense(text, uuid, date, text, text, numeric, text, uuid, text, text) to authenticated;

-- QA-13 ─ format guards for free-text-ish columns (new rows only)
alter table public.funds
  add constraint funds_currency_format check (currency ~ '^[A-Z]{3}$') not valid;
alter table public.categories
  add constraint categories_icon_length check (char_length(icon) <= 16) not valid;

-- QA-18 ─ starter funds deserve a real group (not BearHaus's own rows)
update public.funds
   set group_name = 'Savings & buffers'
 where coalesce(group_name, '') = ''
   and household_id <> '82f25ed0-bd15-4089-a184-833137120d7f'
   and name in ('Float', 'Savings', 'Emergency fund', 'Travel fund');

-- …and future households get the group at onboarding
create or replace function public.create_household_setup(
  p_code       text,
  p_household  text,
  p_people     text[],
  p_joint_label text,
  p_countries  text[]
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
  v_sort    int  := 0;
  v_psort   int  := 0;
  v_fund    uuid;
  v_travel  uuid := null;
  v_primary boolean := true;
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;
  if exists (select 1 from households where owner_user_id = v_uid) then
    raise exception 'this login already has a household';
  end if;
  if coalesce(array_length(p_people, 1), 0) = 0 then
    raise exception 'add at least one person';
  end if;
  if coalesce(array_length(p_people, 1), 0) > 6 then
    raise exception 'six people max for now';
  end if;
  if coalesce(array_length(p_countries, 1), 0) = 0 then
    raise exception 'pick at least one country';
  end if;

  update beta_invites
     set used_count = used_count + 1
   where lower(code) = lower(trim(p_code))
     and used_count < max_uses;
  if not found then
    raise exception 'invite code not recognised — or already used';
  end if;

  insert into households (name, owner_user_id, joint_label)
  values (
    coalesce(nullif(trim(p_household), ''), 'My household'),
    v_uid,
    nullif(trim(coalesce(p_joint_label, '')), '')
  )
  returning id into v_hh;

  foreach v_person in array p_people loop
    if trim(v_person) <> '' then
      insert into profiles (household_id, display_name, sort_order)
      values (v_hh, trim(v_person), v_psort);
      v_psort := v_psort + 1;
    end if;
  end loop;

  foreach v_cc in array p_countries loop
    if v_cc not in ('AU', 'SG') then
      raise exception 'unsupported country % — the beta supports AU and SG', v_cc;
    end if;
    v_cur := case v_cc when 'SG' then 'SGD' else 'AUD' end;
    if v_primary then
      insert into funds (household_id, name, country, currency, group_name, sort_order)
      values (v_hh, 'Float', v_cc, v_cur, 'Savings & buffers', v_sort);
      v_sort := v_sort + 1;
    end if;
    insert into funds (household_id, name, country, currency, group_name, sort_order, is_leftover_target)
    values (v_hh, 'Savings', v_cc, v_cur, 'Savings & buffers', v_sort, true);
    v_sort := v_sort + 1;
    insert into funds (household_id, name, country, currency, group_name, sort_order)
    values (v_hh, 'Emergency fund', v_cc, v_cur, 'Savings & buffers', v_sort);
    v_sort := v_sort + 1;
    insert into funds (household_id, name, country, currency, group_name, sort_order)
    values (v_hh, 'Travel fund', v_cc, v_cur, 'Savings & buffers', v_sort)
    returning id into v_fund;
    v_sort := v_sort + 1;
    if v_primary then
      v_travel := v_fund;
    end if;
    v_primary := false;
  end loop;

  update households set travel_fund_id = v_travel where id = v_hh;

  insert into payment_methods (household_id, name, profile_id, sort_order)
  values (v_hh, 'Cash', null, 0);
  insert into payment_methods (household_id, name, profile_id, sort_order)
  select v_hh, 'Bank card — ' || display_name, id, 1
  from profiles where household_id = v_hh;

  perform seed_default_categories(v_hh);

  return v_hh;
end;
$$;
revoke all on function public.create_household_setup(text, text, text[], text, text[]) from public;
grant execute on function public.create_household_setup(text, text, text[], text, text[]) to authenticated;
