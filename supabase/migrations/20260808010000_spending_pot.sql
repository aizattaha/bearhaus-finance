-- Money model v3 — "the spending pot" (Aizat's decision, 8 Aug 2026).
-- The month's spending budget is real cash: on Apply it lands in the currency's
-- pot fund (Float), and daily spending counts it down LIVE — computed in the
-- balance view, never written as shadow rows. Unspent budget simply stays put.
-- Starts 1 Sep 2026 for existing households; new households start immediately.

alter table public.funds add column if not exists is_spend_pot boolean not null default false;
alter table public.households add column if not exists pot_start date;

-- every household's starter/main 'Float' becomes its pot (BearHaus AU included)
update public.funds set is_spend_pot = true where name = 'Float' and is_active;

-- BearHaus gets a Float SG as the S$ pot (idempotent)
insert into public.funds (household_id, name, country, currency, group_name, sort_order, is_spend_pot)
select '82f25ed0-bd15-4089-a184-833137120d7f', 'Float SG', 'SG', 'SGD', '',
       coalesce((select max(sort_order) + 1 from public.funds
                 where household_id = '82f25ed0-bd15-4089-a184-833137120d7f'), 0),
       true
where not exists (select 1 from public.funds
                  where household_id = '82f25ed0-bd15-4089-a184-833137120d7f'
                    and name = 'Float SG');

-- v3 begins with September's plan for everyone already signed up
update public.households set pot_start = date '2026-09-01' where pot_start is null;

-- at most one active pot per currency per household
create unique index if not exists funds_one_pot_per_currency
  on public.funds (household_id, currency) where (is_spend_pot and is_active);

-- the view: a pot also counts down with daily spending in its currency
-- (settle-up 'Payment' excluded; trips excluded — travel has its own flow)
drop view if exists public.fund_balances;
create view public.fund_balances with (security_invoker = 'true') as
select f.household_id,
       f.id as fund_id,
       f.name,
       f.country,
       f.currency,
       f.is_active,
       f.sort_order,
       f.group_name,
       f.is_leftover_target,
       f.is_spend_pot,
       coalesce(sum(case when t.type = 'income' then t.amount else (- t.amount) end), 0)
       - case when f.is_spend_pot and h.pot_start is not null then
           coalesce((select sum(de.amount) from public.daily_expenses de
                      where de.household_id = f.household_id
                        and de.currency = f.currency
                        and de.category <> 'Payment'
                        and de.date >= h.pot_start), 0)
         else 0 end as balance
from public.funds f
join public.households h on h.id = f.household_id
left join public.fund_transactions t on t.fund_id = f.id
group by f.id, h.pot_start;

grant all on table public.fund_balances to anon, authenticated, service_role;

-- new households: pot on from day one (their primary Float, their signup month)
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
  if coalesce(array_length(p_countries, 1), 0) > 4 then
    raise exception 'four countries max for now';
  end if;
  if p_currencies is not null
     and coalesce(array_length(p_currencies, 1), 0) <> coalesce(array_length(p_countries, 1), 0) then
    raise exception 'countries and currencies don''t line up';
  end if;

  update beta_invites
     set used_count = used_count + 1
   where lower(code) = lower(trim(p_code))
     and used_count < max_uses;
  if not found then
    raise exception 'invite code not recognised — or already used';
  end if;

  insert into households (name, owner_user_id, joint_label, pot_start)
  values (
    coalesce(nullif(trim(p_household), ''), 'My household'),
    v_uid,
    nullif(trim(coalesce(p_joint_label, '')), ''),
    date_trunc('month', now())::date
  )
  returning id into v_hh;

  foreach v_person in array p_people loop
    if trim(v_person) <> '' then
      insert into profiles (household_id, display_name, sort_order)
      values (v_hh, trim(v_person), v_psort);
      v_psort := v_psort + 1;
    end if;
  end loop;

  for v_i in 1 .. array_length(p_countries, 1) loop
    v_cc := upper(trim(p_countries[v_i]));
    if v_cc !~ '^[A-Z]{2}$' then
      raise exception 'country codes are two letters — got %', v_cc;
    end if;
    v_cur := case
      when p_currencies is not null then upper(trim(p_currencies[v_i]))
      when v_cc = 'SG' then 'SGD'
      when v_cc = 'AU' then 'AUD'
      else null
    end;
    if v_cur is null or v_cur !~ '^[A-Z]{3}$' then
      raise exception 'missing or invalid currency for %', v_cc;
    end if;
    if v_primary then
      insert into funds (household_id, name, country, currency, group_name, sort_order, is_spend_pot)
      values (v_hh, 'Float', v_cc, v_cur, 'Savings & buffers', v_sort, true);
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
