-- Pot model v4 — "budget lines land in pots, spending follows its category" (Aizat, 9 Oct 2026).
--
-- 1. A spending-budget line (category_budgets) can name the pot it lands in (pot_fund_id).
--    Null = the currency's default pot (its first spending pot in fund order) — exactly v3.
-- 2. Several spending pots per currency are allowed (Float SG (Aizat) + Float SG (Paige)):
--    the one-pot-per-currency index goes.
-- 3. A daily expense counts down the pot that ITS CATEGORY GROUP's budget landed in that
--    month (expense_pot). Unbudgeted groups fall back to the currency's default pot.
--    Cards do not matter — a card can be used across pots.
-- 4. pot_month_spend(fund) gives the per-month spending lines the app shows in a pot's
--    history, from the same mapping — one source of truth.
-- 5. save_month_plan accepts pot_fund_id on each spending line (older callers still work).

begin;

alter table public.category_budgets
  add column if not exists pot_fund_id uuid references public.funds(id) on delete set null;

drop index if exists public.funds_one_pot_per_currency;

-- a budget group may now exist once PER CURRENCY per month (AU "Daily Expenses" and
-- SG "Daily Expenses" side by side) — the old key ignored currency
alter table public.category_budgets drop constraint if exists category_budgets_household_id_month_category_group_key;
alter table public.category_budgets add constraint category_budgets_hh_month_group_cur_key
  unique (household_id, month, category_group, currency);

-- BearHaus: both SG floats are spending pots (Paige's was blocked by the old index)
update public.funds set is_spend_pot = true
 where household_id = '82f25ed0-bd15-4089-a184-833137120d7f'
   and name = 'Float SG (Paige)' and is_active;

create index if not exists categories_hh_kind_name on public.categories (household_id, kind, name);
create index if not exists category_budgets_hh_month_group_cur on public.category_budgets (household_id, month, category_group, currency);
create index if not exists daily_expenses_hh_date on public.daily_expenses (household_id, date);

-- the currency's default pot: first active spending pot in fund order
create or replace function public.default_spend_pot(p_hh uuid, p_cur text)
returns uuid language sql stable set search_path = public as $$
  select id from funds
   where household_id = p_hh and currency = p_cur and is_spend_pot and is_active
   order by sort_order limit 1
$$;

-- which pot a daily expense counts down: the pot its category group's budget landed in
-- that month, else the currency's default pot
create or replace function public.expense_pot(p_hh uuid, p_category text, p_cur text, p_date date)
returns uuid language sql stable set search_path = public as $$
  select coalesce(
    (select cb.pot_fund_id
       from category_budgets cb
       join categories c on c.household_id = cb.household_id and c.kind = 'daily'
                        and c.group_name = cb.category_group
      where cb.household_id = p_hh and c.name = p_category and cb.currency = p_cur
        and cb.month = date_trunc('month', p_date)::date
        and cb.pot_fund_id is not null
      limit 1),
    default_spend_pot(p_hh, p_cur))
$$;

-- live balances: future-dated rows ignored (Scheduled); a spending pot counts down the
-- daily spending that maps to it, from the household's pot_start onward
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
       coalesce(sum(case when t.date > current_date then 0
                         when t.type = 'income' then t.amount else (- t.amount) end), 0)
       - case when f.is_spend_pot and h.pot_start is not null then
           coalesce((select sum(de.amount) from public.daily_expenses de
                      where de.household_id = f.household_id
                        and de.currency = f.currency
                        and de.category <> 'Payment'
                        and de.date >= h.pot_start
                        and de.date <= current_date
                        and public.expense_pot(de.household_id, de.category, de.currency, de.date) = f.id), 0)
         else 0 end as balance
from public.funds f
join public.households h on h.id = f.household_id
left join public.fund_transactions t on t.fund_id = f.id
group by f.id, h.pot_start;

grant all on table public.fund_balances to anon, authenticated, service_role;

-- a pot's spending by month (what the app shows as "October 2026 spending − A$x")
create or replace function public.pot_month_spend(p_fund uuid)
returns table (month date, amount numeric, n integer, last_date date)
language sql stable set search_path = public as $$
  select date_trunc('month', de.date)::date as month,
         sum(de.amount) as amount,
         count(*)::int as n,
         max(de.date) as last_date
    from daily_expenses de
    join funds f on f.id = p_fund and f.household_id = de.household_id
    join households h on h.id = f.household_id
   where f.is_spend_pot and h.pot_start is not null
     and de.currency = f.currency and de.category <> 'Payment'
     and de.date >= h.pot_start and de.date <= current_date
     and expense_pot(de.household_id, de.category, de.currency, de.date) = f.id
   group by 1
   order by 1 desc
$$;

grant execute on function public.default_spend_pot(uuid, text) to authenticated, service_role;
grant execute on function public.expense_pot(uuid, text, text, date) to authenticated, service_role;
grant execute on function public.pot_month_spend(uuid) to authenticated, service_role;

-- save the plan with per-line pots (pot must be one of the household's own funds)
create or replace function public.save_month_plan(p_month date, p_inc jsonb, p_cat jsonb, p_fb jsonb)
returns void language plpgsql security definer set search_path = public as $$
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
  insert into category_budgets (household_id, month, category_group, currency, amount, pot_fund_id)
  select v_hh, p_month, x.category_group, x.currency, x.amount,
         case when exists (select 1 from funds f where f.id = x.pot_fund_id and f.household_id = v_hh)
              then x.pot_fund_id else null end
  from jsonb_to_recordset(coalesce(p_cat, '[]'::jsonb)) as x(category_group text, currency text, amount numeric, pot_fund_id uuid)
  where x.amount > 0;

  delete from fund_budgets where household_id = v_hh and month = p_month;
  insert into fund_budgets (household_id, month, fund_id, amount)
  select v_hh, p_month, x.fund_id, x.amount
  from jsonb_to_recordset(coalesce(p_fb, '[]'::jsonb)) as x(fund_id uuid, amount numeric)
  where x.amount > 0
    and exists (select 1 from funds f where f.id = x.fund_id and f.household_id = v_hh);
end;
$$;

commit;
