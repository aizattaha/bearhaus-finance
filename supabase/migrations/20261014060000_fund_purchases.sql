-- Purchases can name their fund (14 Oct 2026) — docs/architecture-review-2026-10-ledger.md, option C, phase 1.
--
--  expenses.fund_id        "count this purchase against THAT fund" instead of the pot rule
--                          (a car service from the Car Fund; a premium from the Insurance fund). The
--                          stamp becomes coalesce(fund_id, pot rule); every fund now gets the pot
--                          treatment in the views: Available · owed on cards · in the bank.
--  fund_spend_sort         the 356 "money out of a fund" rows with a suggested answer each:
--                          purchase (→ expenses) or movement (stays). Nothing moves until confirmed.
--  move_fund_spend_to_expenses / move_expense_to_fund_spend / keep_fund_spend
--                          id-preserving, reconciliation-preserving, balance-asserted, audit-logged.
--
-- Additive: no row changes shape today; balances asserted unchanged.

begin;

create temp table _before as select fund_id, balance from public.fund_balances;

-- ── 1 · the column + the rule ────────────────────────────────────────────
alter table public.expenses add column if not exists fund_id uuid references public.funds(id) on delete restrict;
create index if not exists expenses_fund_date on public.expenses (fund_id, date) where fund_id is not null;
alter table public.fund_transactions_all add column if not exists reviewed_at timestamptz;   -- "keep as movement" decision

create or replace function public.bh_expense_stamp_pot()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' or new.fund_id is distinct from old.fund_id or new.category_id is distinct from old.category_id
     or new.category is distinct from old.category or new.currency is distinct from old.currency
     or new.date is distinct from old.date or new.trip_id is distinct from old.trip_id or new.household_id is distinct from old.household_id then
    new.pot_fund_id := coalesce(new.fund_id, expense_pot_for(new.household_id, new.trip_id, new.category_id, new.category, new.currency, new.date));
  end if;
  return new;
end $$;
create or replace function public.restamp_pots(p_hh uuid, p_from date default null, p_to date default null)
returns integer language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  update expenses e set pot_fund_id = coalesce(e.fund_id, expense_pot_for(e.household_id, e.trip_id, e.category_id, e.category, e.currency, e.date))
   where e.household_id = p_hh and e.trip_id is null
     and (p_from is null or e.date >= p_from) and (p_to is null or e.date < p_to)
     and pot_fund_id is distinct from coalesce(e.fund_id, expense_pot_for(e.household_id, e.trip_id, e.category_id, e.category, e.currency, e.date));
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- a fund-funded purchase must be in the fund's currency, and the fund must be the household's
create or replace function public.bh_expense_fund_guard()
returns trigger language plpgsql as $$
declare v_cur text; v_hh uuid;
begin
  if new.fund_id is null then return new; end if;
  select currency, household_id into v_cur, v_hh from funds where id = new.fund_id;
  if v_hh is null then raise exception 'fund not found'; end if;
  if v_hh <> new.household_id then raise exception 'fund belongs to another household' using errcode = '42501'; end if;
  if v_cur <> new.currency then raise exception 'this purchase is in % but the fund holds % — pick a fund in % or change the currency', new.currency, v_cur, new.currency; end if;
  if new.trip_id is not null then raise exception 'a trip expense is settled through the trip, not a fund'; end if;
  return new;
end $$;
drop trigger if exists bz_expenses_fund on public.expenses;
create trigger bz_expenses_fund before insert or update on public.expenses for each row execute function public.bh_expense_fund_guard();

-- ── 2 · the views: every fund counts its own purchases ──────────────────
-- a purchase counts against fund f when it is stamped to f AND either it names f explicitly
-- (any date) or f is a spending pot inside the pot era (the existing rule)
create or replace view public.fund_balances with (security_invoker = true) as
 SELECT f.household_id, f.id AS fund_id, f.name, f.country, f.currency, f.is_active, f.sort_order, f.group_name, f.is_leftover_target, f.is_spend_pot,
    COALESCE(sum(CASE WHEN t.date > CURRENT_DATE OR t.kind = 'card_payment' THEN 0::numeric WHEN t.type = 'income' THEN t.amount ELSE - t.amount END), 0::numeric) -
    COALESCE((SELECT sum(CASE WHEN de.is_refund THEN -de.amount ELSE de.amount END) FROM expenses de
               WHERE de.trip_id IS NULL AND de.deleted_at IS NULL AND de.household_id = f.household_id AND de.currency = f.currency AND de.category <> 'Payment'
                 AND de.date <= CURRENT_DATE AND de.pot_fund_id = f.id
                 AND (de.fund_id = f.id OR (f.is_spend_pot AND h.pot_start IS NOT NULL AND de.date >= h.pot_start))), 0::numeric) AS balance
   FROM funds f
   JOIN households h ON h.id = f.household_id
   LEFT JOIN fund_transactions t ON t.fund_id = f.id
  GROUP BY f.id, h.pot_start;

create or replace view public.fund_balances_cleared with (security_invoker = true) as
 SELECT f.household_id, f.id AS fund_id, f.name, f.country, f.currency, f.is_active, f.sort_order, f.group_name, f.is_leftover_target, f.is_spend_pot,
    COALESCE(sum(CASE WHEN t.date > CURRENT_DATE OR t.reconciled_at IS NULL OR t.kind = 'card_payment' THEN 0::numeric WHEN t.type = 'income' THEN t.amount ELSE - t.amount END), 0::numeric) -
    COALESCE((SELECT sum(CASE WHEN de.is_refund THEN -de.amount ELSE de.amount END) FROM expenses de
               WHERE de.trip_id IS NULL AND de.deleted_at IS NULL AND de.household_id = f.household_id AND de.currency = f.currency AND de.category <> 'Payment'
                 AND de.date <= CURRENT_DATE AND de.reconciled_at IS NOT NULL AND de.pot_fund_id = f.id
                 AND (de.fund_id = f.id OR (f.is_spend_pot AND h.pot_start IS NOT NULL AND de.date >= h.pot_start))), 0::numeric) AS cleared_balance,
    COALESCE((SELECT sum(CASE WHEN de.is_refund THEN -de.amount ELSE de.amount END) FROM expenses de
               WHERE de.trip_id IS NULL AND de.deleted_at IS NULL AND de.household_id = f.household_id AND de.currency = f.currency AND de.category <> 'Payment'
                 AND de.date <= CURRENT_DATE AND de.reconciled_at IS NULL AND de.pot_fund_id = f.id
                 AND (de.fund_id = f.id OR (f.is_spend_pot AND h.pot_start IS NOT NULL AND de.date >= h.pot_start))), 0::numeric) AS pending_spend
   FROM funds f
   JOIN households h ON h.id = f.household_id
   LEFT JOIN fund_transactions t ON t.fund_id = f.id
  GROUP BY f.id, h.pot_start;

create or replace view public.fund_cash with (security_invoker = true) as
 SELECT b.household_id, b.fund_id, b.name, b.currency, b.is_active, b.is_spend_pot, b.balance,
        c.cash_balance, round(c.cash_balance - b.balance, 2) AS owed_on_cards
   FROM public.fund_balances b
   JOIN (
     SELECT f.id AS fund_id,
            COALESCE(sum(CASE WHEN t.date > CURRENT_DATE THEN 0::numeric
                              WHEN t.type = 'expense' AND t.kind = 'movement' AND bh_is_credit_card(t.account_payment_method_id) THEN 0::numeric
                              WHEN t.type = 'income' THEN t.amount ELSE - t.amount END), 0::numeric) -
            COALESCE((SELECT sum(CASE WHEN de.is_refund THEN -de.amount ELSE de.amount END) FROM expenses de
                       LEFT JOIN payment_methods pm ON pm.id = de.payment_method_id
                      WHERE de.trip_id IS NULL AND de.deleted_at IS NULL AND de.household_id = f.household_id AND de.currency = f.currency
                        AND de.category <> 'Payment' AND de.date <= CURRENT_DATE AND de.pot_fund_id = f.id
                        AND (de.fund_id = f.id OR (f.is_spend_pot AND h.pot_start IS NOT NULL AND de.date >= h.pot_start))
                        AND coalesce(pm.kind, 'cash') <> 'credit_card'), 0::numeric) AS cash_balance
       FROM funds f
       JOIN households h ON h.id = f.household_id
       LEFT JOIN fund_transactions t ON t.fund_id = f.id
      GROUP BY f.id, h.pot_start
   ) c ON c.fund_id = b.fund_id;

create or replace function public.pot_month_spend(p_fund uuid)
 RETURNS TABLE(month date, amount numeric, n integer, last_date date)
 LANGUAGE sql STABLE SET search_path TO 'public'
AS $function$
  select date_trunc('month', de.date)::date as month,
         sum(case when de.is_refund then -de.amount else de.amount end) as amount,
         count(*)::int as n, max(de.date) as last_date
    from expenses de
    join funds f on f.id = p_fund and f.household_id = de.household_id
    join households h on h.id = f.household_id
   where de.trip_id is null and de.deleted_at is null
     and de.currency = f.currency and de.category <> 'Payment'
     and de.date <= current_date and de.pot_fund_id = f.id
     and (de.fund_id = f.id or (f.is_spend_pot and h.pot_start is not null and de.date >= h.pot_start))
   group by 1 order by 1 desc
$function$;

grant all on table public.fund_balances, public.fund_balances_cleared, public.fund_cash to anon, authenticated, service_role;

-- the compatibility views expose fund_id (always null on a trip row — the guard refuses it — but the column keeps the shapes alike)
create or replace view public.travel_expenses with (security_invoker = true) as
  select id, household_id, trip_id, date, description, category, amount, currency, payer_profile_id, paid_with, comments,
         sent_to_fund, legacy_sync_id, created_at, payment_method_id, reconciled_at, reconciled_statement_id, reconciled_by, pot_swap_id, updated_at,
         pot_fund_id, created_by, updated_by, category_id, is_refund, fund_id
    from public.expenses where trip_id is not null and deleted_at is null
  with cascaded check option;
create or replace view public.daily_expenses with (security_invoker = true) as
  select id, household_id, date, description, category, amount, currency, payer_profile_id, paid_with, comments,
         legacy_sync_id, created_at, payment_method_id, reconciled_at, reconciled_statement_id, reconciled_by, pot_swap_id, updated_at,
         pot_fund_id, created_by, updated_by, category_id, is_refund, fund_id
    from public.expenses where trip_id is null and deleted_at is null
  with cascaded check option;

-- bh_check_refs: the fund must be the household's (also covered by the guard above; kept for the pattern)
create or replace function public.bh_check_refs()
returns trigger language plpgsql as $$
begin
  if tg_table_name = 'expenses' then
    perform bh_assert_hh('public.profiles', new.payer_profile_id, new.household_id, 'payer');
    perform bh_assert_hh('public.payment_methods', new.payment_method_id, new.household_id, 'card');
    perform bh_assert_hh('public.statements', new.reconciled_statement_id, new.household_id, 'statement');
    perform bh_assert_hh('public.pot_swaps', new.pot_swap_id, new.household_id, 'pot swap');
    perform bh_assert_hh('public.funds', new.pot_fund_id, new.household_id, 'pot');
    perform bh_assert_hh('public.funds', new.fund_id, new.household_id, 'fund');
    perform bh_assert_hh('public.categories', new.category_id, new.household_id, 'category');
    if new.trip_id is not null then perform bh_assert_hh('public.trips', new.trip_id, new.household_id, 'trip'); end if;
  end if;
  if tg_table_name = 'fund_transactions' or tg_table_name = 'fund_transactions_all' then
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
    perform bh_assert_hh('public.category_groups', new.category_group_id, new.household_id, 'budget group');
  end if;
  if tg_table_name = 'categories' then
    perform bh_assert_hh('public.category_groups', new.group_id, new.household_id, 'group');
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

-- ── 3 · the sort: what is still to decide, with a suggestion ─────────────
create or replace view public.fund_spend_sort with (security_invoker = true) as
  select t.id, t.household_id, t.date, t.remarks, t.amount, t.fund_id, f.name as fund_name, f.currency,
         t.account_payment_method_id, t.reconciled_at, t.reconciled_by, t.reconciled_statement_id,
         case
           when t.remarks ~* '(stashaway|pruwealth|endowus|syfe|transfer|for serious business|reimburs|shortfall|top.?up|withdraw|invest|deposit|loan|repay|last known|opening)' then 'movement'
           when f.name ~* '(investment|taxes|stashaway|dry powder|endowus|savings sg)' then 'movement'
           else 'purchase'
         end as suggestion
    from public.fund_transactions_all t
    join public.funds f on f.id = t.fund_id
   where t.kind = 'movement' and t.type = 'expense' and t.deleted_at is null and t.reviewed_at is null
     and not exists (select 1 from public.pot_swaps ps where ps.spend_tx_id = t.id);   -- a swap's bank-pot spend row belongs to the swap
grant select on public.fund_spend_sort to authenticated, service_role;

-- "this one stays a movement" — it leaves the sort list
create or replace function public.keep_fund_spend(p_ids uuid[])
returns integer language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_n int;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  update fund_transactions_all set reviewed_at = now() where household_id = v_hh and id = any(p_ids) and kind = 'movement' and type = 'expense' and reviewed_at is null;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function public.keep_fund_spend(uuid[]) from public;
grant execute on function public.keep_fund_spend(uuid[]) to authenticated, service_role;

-- fund movement → purchase (same id, same date/amount, reconciliation marks carried, balance proven equal)
create or replace function public.move_fund_spend_to_expenses(p_ids uuid[], p_category text, p_payment_method uuid default null)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_hh uuid; r record; v_n int := 0; v_before numeric; v_after numeric; v_card payment_methods%rowtype;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  if coalesce(trim(p_category), '') = '' then raise exception 'pick a category'; end if;
  if p_payment_method is not null then
    select * into v_card from payment_methods where id = p_payment_method and household_id = v_hh;
    if v_card.id is null then raise exception 'card not found'; end if;
  end if;
  perform set_config('bh.via_rpc', 'on', true);
  for r in select t.*, f.currency as fund_currency from fund_transactions_all t join funds f on f.id = t.fund_id
            where t.household_id = v_hh and t.id = any(p_ids) and t.kind = 'movement' and t.type = 'expense' and t.deleted_at is null
              and not exists (select 1 from pot_swaps ps where ps.spend_tx_id = t.id) loop
    if v_card.id is not null and v_card.currency is not null and v_card.currency <> r.fund_currency then
      raise exception '% is in %, % is in % — pick a card in the fund''s currency or no card', v_card.name, v_card.currency, (select name from funds where id = r.fund_id), r.fund_currency;
    end if;
    select balance into v_before from fund_balances where fund_id = r.fund_id;
    -- the movement row goes (its reconciliation marks travel with the purchase)
    update fund_transactions_all set reconciled_at = null, reconciled_by = null, reconciled_statement_id = null where id = r.id;
    delete from fund_transactions_all where id = r.id;
    insert into expenses (id, household_id, date, description, category, amount, currency, payer_profile_id, payment_method_id, paid_with, comments,
                          fund_id, created_at, created_by, reconciled_at, reconciled_by, reconciled_statement_id, is_refund)
    values (r.id, v_hh, r.date, coalesce(nullif(r.remarks, ''), 'Fund spend'), p_category, r.amount, r.fund_currency, null, p_payment_method,
            coalesce(v_card.name, ''), 'moved from ' || (select name from funds where id = r.fund_id) || ' movements on ' || to_char(now(), 'DD Mon YYYY'),
            r.fund_id, r.created_at, r.created_by,
            -- a cash card ticks itself; a reconciled movement keeps its tick (only when it had a statement or stays manual)
            case when r.reconciled_by = 'manual' then r.reconciled_at end, case when r.reconciled_by = 'manual' then 'manual' end, r.reconciled_statement_id, false);
    select balance into v_after from fund_balances where fund_id = r.fund_id;
    if abs(v_after - v_before) > 0.005 then
      raise exception 'moving % would change the fund balance (% → %) — stopped, nothing changed', coalesce(r.remarks, r.id::text), v_before, v_after;
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke all on function public.move_fund_spend_to_expenses(uuid[], text, uuid) from public;
grant execute on function public.move_fund_spend_to_expenses(uuid[], text, uuid) to authenticated, service_role;

-- purchase → fund movement (the way back; only for rows that name a fund)
create or replace function public.move_expense_to_fund_spend(p_ids uuid[])
returns integer language plpgsql security definer set search_path = public as $$
declare v_hh uuid; r record; v_n int := 0; v_before numeric; v_after numeric;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  perform set_config('bh.via_rpc', 'on', true);
  for r in select * from expenses where household_id = v_hh and id = any(p_ids) and fund_id is not null and deleted_at is null loop
    if r.reconciled_statement_id is not null and exists (select 1 from statements where id = r.reconciled_statement_id and closed_at is not null) then
      raise exception '% is on a closed statement — reopen it first', r.description;
    end if;
    select balance into v_before from fund_balances where fund_id = r.fund_id;
    update expenses set reconciled_at = null, reconciled_by = null, reconciled_statement_id = null where id = r.id;
    delete from expenses where id = r.id;
    insert into fund_transactions_all (id, household_id, fund_id, type, kind, date, amount, remarks, origin, created_at, created_by,
                                       account_payment_method_id, reconciled_at, reconciled_by, reconciled_statement_id)
    values (r.id, v_hh, r.fund_id, 'expense', 'movement', r.date, r.amount, r.description, 'manual', r.created_at, r.created_by,
            r.payment_method_id, case when r.reconciled_by = 'manual' then r.reconciled_at end, case when r.reconciled_by = 'manual' then 'manual' end, r.reconciled_statement_id);
    select balance into v_after from fund_balances where fund_id = r.fund_id;
    if abs(v_after - v_before) > 0.005 then
      raise exception 'moving % back would change the fund balance (% → %) — stopped', r.description, v_before, v_after;
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke all on function public.move_expense_to_fund_spend(uuid[]) from public;
grant execute on function public.move_expense_to_fund_spend(uuid[]) to authenticated, service_role;

-- ── proof ────────────────────────────────────────────────────────────────
do $$
declare v_bad int; v_n int;
begin
  select count(*) into v_bad from _before b join public.fund_balances a using (fund_id) where abs(a.balance - b.balance) > 0.005;
  if v_bad > 0 then raise exception 'fund purchases: % fund balances changed', v_bad; end if;
  select count(*) into v_n from public.fund_spend_sort;
  raise notice 'fund purchases ok: balances unchanged · % fund-spend rows to sort', v_n;
end $$;
drop table _before;

notify pgrst, 'reload schema';
commit;
