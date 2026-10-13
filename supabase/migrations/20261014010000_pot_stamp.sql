-- Pot decided at write time (14 Oct 2026) — architecture review §1.7.
--
-- Every daily expense now carries pot_fund_id: the spending pot it counts against, computed
-- once by the before-write trigger (same expense_pot rule) instead of on every read of
-- fund_balances. Re-stamped when the inputs to that rule change: the month's budget lines
-- (save_month_plan) or the household's pots (funds trigger). Balance views become plain
-- indexed sums; the assertion at the end proves every balance is unchanged.

begin;

create temp table _before as select fund_id, balance from public.fund_balances;

alter table public.expenses add column if not exists pot_fund_id uuid references public.funds(id) on delete set null;
create index if not exists expenses_pot_date on public.expenses (pot_fund_id, date) where pot_fund_id is not null;

-- the rule, in one place: daily rows that aren't card payments map to a pot; trip rows never do
create or replace function public.expense_pot_for(p_hh uuid, p_trip uuid, p_category text, p_cur text, p_date date)
returns uuid language sql stable set search_path = public as $$
  select case when p_trip is null and p_category <> 'Payment' then expense_pot(p_hh, p_category, p_cur, p_date) end
$$;

create or replace function public.bh_expense_stamp_pot()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' or new.category is distinct from old.category or new.currency is distinct from old.currency
     or new.date is distinct from old.date or new.trip_id is distinct from old.trip_id or new.household_id is distinct from old.household_id then
    new.pot_fund_id := expense_pot_for(new.household_id, new.trip_id, new.category, new.currency, new.date);
  end if;
  return new;
end $$;
drop trigger if exists expenses_stamp_pot on public.expenses;
-- "zy_" so it runs after the before_write trigger (which may still change the card) and before the touch
create trigger zy_expenses_stamp_pot before insert or update on public.expenses for each row execute function public.bh_expense_stamp_pot();

-- re-stamp a household's rows (a date window, or everything)
create or replace function public.restamp_pots(p_hh uuid, p_from date default null, p_to date default null)
returns integer language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  update expenses e set pot_fund_id = expense_pot_for(e.household_id, e.trip_id, e.category, e.currency, e.date)
   where e.household_id = p_hh and e.trip_id is null
     and (p_from is null or e.date >= p_from) and (p_to is null or e.date < p_to)
     and pot_fund_id is distinct from expense_pot_for(e.household_id, e.trip_id, e.category, e.currency, e.date);
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function public.restamp_pots(uuid, date, date) from public;
grant execute on function public.restamp_pots(uuid, date, date) to service_role;

-- backfill every row once
update public.expenses e set pot_fund_id = expense_pot_for(e.household_id, e.trip_id, e.category, e.currency, e.date) where e.trip_id is null;

-- pots themselves can change (a fund becomes/stops being a pot, is archived, reordered, changes currency):
-- re-stamp that household — rare, and now the only expensive path
create or replace function public.bh_funds_restamp()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then perform restamp_pots(old.household_id); return old; end if;
  if tg_op = 'INSERT' and new.is_spend_pot then perform restamp_pots(new.household_id); end if;
  if tg_op = 'UPDATE' and (new.is_spend_pot is distinct from old.is_spend_pot or new.is_active is distinct from old.is_active
     or new.sort_order is distinct from old.sort_order or new.currency is distinct from old.currency) then
    perform restamp_pots(new.household_id);
  end if;
  return new;
end $$;
drop trigger if exists funds_restamp on public.funds;
create trigger funds_restamp after insert or update or delete on public.funds for each row execute function public.bh_funds_restamp();

-- budget lines changing a category group's pot: category_budgets written by save_month_plan (below);
-- direct edits to category_budgets are covered too
create or replace function public.bh_cb_restamp()
returns trigger language plpgsql security definer set search_path = public as $$
declare r record;
begin
  r := coalesce(new, old);
  perform restamp_pots(r.household_id, r.month, (r.month + interval '1 month')::date);
  return coalesce(new, old);
end $$;
drop trigger if exists category_budgets_restamp on public.category_budgets;
create trigger category_budgets_restamp after insert or update or delete on public.category_budgets for each row execute function public.bh_cb_restamp();

create or replace function public.save_month_plan(p_month date, p_inc jsonb, p_cat jsonb, p_fb jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- budget lines decide which pot a category counts against: re-stamp this month's rows
  perform restamp_pots(v_hh, p_month, (p_month + interval '1 month')::date);
end;
$function$;

-- the pot's own household check
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
  if tg_table_name = 'households' then
    perform bh_assert_hh('public.funds', new.travel_fund_id, new.id, 'travel fund');
  end if;
  return new;
end $$;

-- balances: plain sums on the stamped column
create or replace view public.fund_balances with (security_invoker = true) as
 SELECT f.household_id,
    f.id AS fund_id,
    f.name,
    f.country,
    f.currency,
    f.is_active,
    f.sort_order,
    f.group_name,
    f.is_leftover_target,
    f.is_spend_pot,
    COALESCE(sum(
        CASE
            WHEN t.date > CURRENT_DATE THEN 0::numeric
            WHEN t.type = 'income'::text THEN t.amount
            ELSE - t.amount
        END), 0::numeric) -
        CASE
            WHEN f.is_spend_pot AND h.pot_start IS NOT NULL THEN COALESCE(( SELECT sum(de.amount) AS sum
               FROM expenses de
              WHERE de.trip_id IS NULL AND de.household_id = f.household_id AND de.currency = f.currency AND de.category <> 'Payment'::text AND de.date >= h.pot_start AND de.date <= CURRENT_DATE AND de.pot_fund_id = f.id), 0::numeric)
            ELSE 0::numeric
        END AS balance
   FROM funds f
     JOIN households h ON h.id = f.household_id
     LEFT JOIN fund_transactions t ON t.fund_id = f.id
  GROUP BY f.id, h.pot_start;
create or replace view public.fund_balances_cleared with (security_invoker = true) as
 SELECT f.household_id,
    f.id AS fund_id,
    f.name,
    f.country,
    f.currency,
    f.is_active,
    f.sort_order,
    f.group_name,
    f.is_leftover_target,
    f.is_spend_pot,
    COALESCE(sum(
        CASE
            WHEN t.date > CURRENT_DATE OR t.reconciled_at IS NULL THEN 0::numeric
            WHEN t.type = 'income'::text THEN t.amount
            ELSE - t.amount
        END), 0::numeric) -
        CASE
            WHEN f.is_spend_pot AND h.pot_start IS NOT NULL THEN COALESCE(( SELECT sum(de.amount) AS sum
               FROM expenses de
              WHERE de.trip_id IS NULL AND de.household_id = f.household_id AND de.currency = f.currency AND de.category <> 'Payment'::text AND de.date >= h.pot_start AND de.date <= CURRENT_DATE AND de.reconciled_at IS NOT NULL AND de.pot_fund_id = f.id), 0::numeric)
            ELSE 0::numeric
        END AS cleared_balance,
        CASE
            WHEN f.is_spend_pot AND h.pot_start IS NOT NULL THEN COALESCE(( SELECT sum(de.amount) AS sum
               FROM expenses de
              WHERE de.trip_id IS NULL AND de.household_id = f.household_id AND de.currency = f.currency AND de.category <> 'Payment'::text AND de.date >= h.pot_start AND de.date <= CURRENT_DATE AND de.reconciled_at IS NULL AND de.pot_fund_id = f.id), 0::numeric)
            ELSE 0::numeric
        END AS pending_spend
   FROM funds f
     JOIN households h ON h.id = f.household_id
     LEFT JOIN fund_transactions t ON t.fund_id = f.id
  GROUP BY f.id, h.pot_start;
grant all on table public.fund_balances, public.fund_balances_cleared to anon, authenticated, service_role;
create or replace function public.pot_month_spend(p_fund uuid)
 RETURNS TABLE(month date, amount numeric, n integer, last_date date)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  select date_trunc('month', de.date)::date as month,
         sum(de.amount) as amount,
         count(*)::int as n,
         max(de.date) as last_date
    from expenses de
    join funds f on f.id = p_fund and f.household_id = de.household_id
    join households h on h.id = f.household_id
   where de.trip_id is null and f.is_spend_pot and h.pot_start is not null
     and de.currency = f.currency and de.category <> 'Payment'
     and de.date >= h.pot_start and de.date <= current_date
     and de.pot_fund_id = f.id
   group by 1
   order by 1 desc
$function$;

do $$
declare v_bad int;
begin
  select count(*) into v_bad from _before b join public.fund_balances a using (fund_id) where abs(a.balance - b.balance) > 0.005;
  if v_bad > 0 then raise exception 'pot stamping: % fund balances changed', v_bad; end if;
  raise notice 'pot stamping ok: balances unchanged';
end $$;
drop table _before;

notify pgrst, 'reload schema';
commit;
