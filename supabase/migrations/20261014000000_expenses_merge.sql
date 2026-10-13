-- One expenses table (14 Oct 2026) — architecture review §1.3.
--
-- daily_expenses and travel_expenses were the same table twice (travel adds trip_id and
-- sent_to_fund); every feature was written twice. They become ONE table, public.expenses,
-- with trip_id null = a daily expense. The two old names live on as updatable views over it,
-- so the current phone app and Desk keep working unchanged; new code uses `expenses`.
-- The two splits tables merge into expense_splits the same way (old names = views).
-- Row ids are preserved, so pot_swaps.expense_id and every reconciliation mark still point
-- at the same rows. Balances must not move: checked by the assertion at the end.

begin;

-- ── 0 · remember the balances so the end of the migration can prove nothing moved ──
create temp table _before as select fund_id, balance from public.fund_balances;

-- ── 1 · the table ────────────────────────────────────────────────────────
create table public.expenses (
  id                      uuid primary key default gen_random_uuid(),
  household_id            uuid not null references public.households(id) on delete cascade,
  trip_id                 uuid references public.trips(id) on delete restrict,      -- null = daily expense
  date                    date not null,
  description             text not null,
  category                text not null,
  amount                  numeric not null check (amount >= 0),
  currency                text not null default 'AUD',
  payer_profile_id        uuid references public.profiles(id),
  payment_method_id       uuid references public.payment_methods(id) on delete set null,
  paid_with               text not null default '',
  comments                text not null default '',
  sent_to_fund            boolean not null default false,
  legacy_sync_id          text,
  reconciled_at           timestamptz,
  reconciled_by           text check (reconciled_by is null or reconciled_by in ('manual', 'auto')),
  reconciled_statement_id uuid references public.statements(id) on delete set null,
  pot_swap_id             uuid references public.pot_swaps(id) on delete set null,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  kind                    text generated always as (case when trip_id is null then 'daily' else 'travel' end) stored,
  constraint expenses_description_len check (length(description) <= 200)
);
insert into public.expenses (id, household_id, trip_id, date, description, category, amount, currency, payer_profile_id, payment_method_id, paid_with, comments, sent_to_fund, legacy_sync_id, reconciled_at, reconciled_by, reconciled_statement_id, pot_swap_id, created_at, updated_at)
select id, household_id, null, date, description, category, amount, currency, payer_profile_id, payment_method_id, paid_with, comments, false, legacy_sync_id, reconciled_at, reconciled_by, reconciled_statement_id, pot_swap_id, created_at, updated_at from public.daily_expenses;
insert into public.expenses (id, household_id, trip_id, date, description, category, amount, currency, payer_profile_id, payment_method_id, paid_with, comments, sent_to_fund, legacy_sync_id, reconciled_at, reconciled_by, reconciled_statement_id, pot_swap_id, created_at, updated_at)
select id, household_id, trip_id, date, description, category, amount, currency, payer_profile_id, payment_method_id, paid_with, comments, sent_to_fund, legacy_sync_id, reconciled_at, reconciled_by, reconciled_statement_id, pot_swap_id, created_at, updated_at from public.travel_expenses;

create table public.expense_splits (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  expense_id   uuid not null references public.expenses(id) on delete cascade,
  profile_id   uuid references public.profiles(id),
  amount       numeric not null,
  unique nulls not distinct (expense_id, profile_id)
);
insert into public.expense_splits (id, household_id, expense_id, profile_id, amount) select id, household_id, expense_id, profile_id, amount from public.daily_expense_splits;
insert into public.expense_splits (id, household_id, expense_id, profile_id, amount) select id, household_id, expense_id, profile_id, amount from public.travel_expense_splits;

create index expenses_hh_date          on public.expenses (household_id, date);
create index expenses_pm_date          on public.expenses (payment_method_id, date);
create index expenses_trip             on public.expenses (trip_id) where trip_id is not null;
create index expenses_unreconciled     on public.expenses (household_id, date) where reconciled_at is null;
create index expenses_pot_swap         on public.expenses (pot_swap_id) where pot_swap_id is not null;
create index expenses_hh_cat           on public.expenses (household_id, category);
create index expense_splits_expense    on public.expense_splits (expense_id);

alter table public.expenses enable row level security;
alter table public.expense_splits enable row level security;
create policy "own household only" on public.expenses for all
  using (household_id in (select id from public.households where owner_user_id = (select auth.uid())))
  with check (household_id in (select id from public.households where owner_user_id = (select auth.uid())));
create policy "own household only" on public.expense_splits for all
  using (household_id in (select id from public.households where owner_user_id = (select auth.uid())))
  with check (household_id in (select id from public.households where owner_user_id = (select auth.uid())));
grant all on table public.expenses, public.expense_splits to anon, authenticated, service_role;

-- the same triggers the two tables had, once
create trigger expenses_before_write before insert or update on public.expenses for each row execute function public.bh_expense_before_write();
create trigger expenses_check_refs   before insert or update on public.expenses for each row execute function public.bh_check_refs();
create trigger expenses_lock         before update or delete on public.expenses for each row execute function public.bh_expense_lock();
create trigger zz_expenses_touch     before update on public.expenses for each row execute function public.bh_touch_updated_at();
create trigger expense_splits_check_refs before insert or update on public.expense_splits for each row execute function public.bh_check_refs();

-- ── 2 · retire the old tables (the views below take their names) ─────────
drop view public.fund_balances_cleared;
drop view public.fund_balances;
drop table public.daily_expense_splits;
drop table public.travel_expense_splits;
drop table public.daily_expenses;
drop table public.travel_expenses;

-- ── 3 · compatibility views: same names, same columns, updatable ─────────
create view public.daily_expenses with (security_invoker = true) as
  select id, household_id, date, description, category, amount, currency, payer_profile_id, paid_with, comments,
         legacy_sync_id, created_at, payment_method_id, reconciled_at, reconciled_statement_id, reconciled_by, pot_swap_id, updated_at
    from public.expenses where trip_id is null
  with cascaded check option;
create view public.travel_expenses with (security_invoker = true) as
  select id, household_id, trip_id, date, description, category, amount, currency, payer_profile_id, paid_with, comments,
         sent_to_fund, legacy_sync_id, created_at, payment_method_id, reconciled_at, reconciled_statement_id, reconciled_by, pot_swap_id, updated_at
    from public.expenses where trip_id is not null
  with cascaded check option;
create view public.daily_expense_splits  with (security_invoker = true) as select id, household_id, expense_id, profile_id, amount from public.expense_splits;
create view public.travel_expense_splits with (security_invoker = true) as select id, household_id, expense_id, profile_id, amount from public.expense_splits;
grant all on table public.daily_expenses, public.travel_expenses, public.daily_expense_splits, public.travel_expense_splits to anon, authenticated, service_role;

-- ── 4 · balances, on the one table (trip rows never count against pots — unchanged) ──
create view public.fund_balances with (security_invoker = true) as
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
              WHERE de.trip_id IS NULL AND de.household_id = f.household_id AND de.currency = f.currency AND de.category <> 'Payment'::text AND de.date >= h.pot_start AND de.date <= CURRENT_DATE AND expense_pot(de.household_id, de.category, de.currency, de.date) = f.id), 0::numeric)
            ELSE 0::numeric
        END AS balance
   FROM funds f
     JOIN households h ON h.id = f.household_id
     LEFT JOIN fund_transactions t ON t.fund_id = f.id
  GROUP BY f.id, h.pot_start;
create view public.fund_balances_cleared with (security_invoker = true) as
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
              WHERE de.trip_id IS NULL AND de.household_id = f.household_id AND de.currency = f.currency AND de.category <> 'Payment'::text AND de.date >= h.pot_start AND de.date <= CURRENT_DATE AND de.reconciled_at IS NOT NULL AND expense_pot(de.household_id, de.category, de.currency, de.date) = f.id), 0::numeric)
            ELSE 0::numeric
        END AS cleared_balance,
        CASE
            WHEN f.is_spend_pot AND h.pot_start IS NOT NULL THEN COALESCE(( SELECT sum(de.amount) AS sum
               FROM expenses de
              WHERE de.trip_id IS NULL AND de.household_id = f.household_id AND de.currency = f.currency AND de.category <> 'Payment'::text AND de.date >= h.pot_start AND de.date <= CURRENT_DATE AND de.reconciled_at IS NULL AND expense_pot(de.household_id, de.category, de.currency, de.date) = f.id), 0::numeric)
            ELSE 0::numeric
        END AS pending_spend
   FROM funds f
     JOIN households h ON h.id = f.household_id
     LEFT JOIN fund_transactions t ON t.fund_id = f.id
  GROUP BY f.id, h.pot_start;
grant all on table public.fund_balances, public.fund_balances_cleared to anon, authenticated, service_role;

-- ── 5 · functions that named the old tables ──────────────────────────────
create or replace function public.bh_check_refs()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if tg_table_name = 'expenses' then
    perform bh_assert_hh('public.profiles', new.payer_profile_id, new.household_id, 'payer');
    perform bh_assert_hh('public.payment_methods', new.payment_method_id, new.household_id, 'card');
    perform bh_assert_hh('public.statements', new.reconciled_statement_id, new.household_id, 'statement');
    perform bh_assert_hh('public.pot_swaps', new.pot_swap_id, new.household_id, 'pot swap');
  end if;
  if tg_table_name = 'expenses' then   -- nested: other tables have no trip_id and PL/pgSQL resolves fields eagerly
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
end $function$;

create or replace function public.record_pot_swap(p_kind text, p_expense uuid, p_rate numeric, p_cover uuid, p_land uuid, p_bank_from uuid, p_bank_to uuid, p_rate_source text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_hh uuid; v_date date; v_desc text; v_amt numeric; v_cur text;
  v_cover funds%rowtype; v_land funds%rowtype; v_from funds%rowtype; v_to funds%rowtype;
  v_dst numeric; v_tag text; v_swap uuid := gen_random_uuid();
  v_g_dst uuid := gen_random_uuid(); v_g_src uuid := gen_random_uuid();
  v_spend uuid; v_marked boolean := false; v_n integer;
begin
  select id into v_hh from households where owner_user_id = auth.uid();
  if v_hh is null then raise exception 'no household'; end if;
  if p_kind not in ('daily', 'travel') then raise exception 'kind must be daily or travel'; end if;
  if p_rate is null or p_rate <= 0 then raise exception 'enter the exchange rate'; end if;

  select date, description, amount, currency, case when trip_id is null then 'daily' else 'travel' end
    into v_date, v_desc, v_amt, v_cur, p_kind
    from expenses where id = p_expense and household_id = v_hh and pot_swap_id is null;
  if v_date is null then raise exception 'expense not found (or already swapped)'; end if;

  select * into v_cover from funds where id = p_cover     and household_id = v_hh and is_active;
  select * into v_land  from funds where id = p_land      and household_id = v_hh and is_active;
  select * into v_from  from funds where id = p_bank_from and household_id = v_hh and is_active;
  select * into v_to    from funds where id = p_bank_to   and household_id = v_hh and is_active;
  if v_cover.id is null or v_land.id is null or v_from.id is null or v_to.id is null then raise exception 'fund not found'; end if;
  if v_cover.currency <> v_land.currency then raise exception 'the two % funds must share a currency', 'landing'; end if;
  if v_from.currency <> v_to.currency then raise exception 'the two bank-side funds must share a currency'; end if;
  if v_from.currency <> v_cur then raise exception 'the bank-side funds must be in the purchase currency (%)', v_cur; end if;
  if v_cover.id = v_land.id or v_from.id = v_to.id then raise exception 'pick two different funds on each side'; end if;

  v_dst := round(v_amt * p_rate, 2);
  v_tag := 'Pot swap · ' || v_desc || ' · ' || v_cur || ' ' || to_char(v_amt, 'FM999999990.00') || ' @ ' || to_char(p_rate, 'FM990.0000');

  -- AU side: cover fund → landing fund, in the landing currency
  insert into fund_transactions (household_id, fund_id, type, date, amount, remarks, origin, transfer_group_id)
  values (v_hh, v_cover.id, 'expense', v_date, v_dst, 'Transfer → ' || v_land.name  || ' · ' || v_tag, 'manual', v_g_dst),
         (v_hh, v_land.id,  'income',  v_date, v_dst, 'Transfer ← ' || v_cover.name || ' · ' || v_tag, 'manual', v_g_dst);
  -- SG side: DreamHouse → bank pot, in the purchase currency
  insert into fund_transactions (household_id, fund_id, type, date, amount, remarks, origin, transfer_group_id)
  values (v_hh, v_from.id, 'expense', v_date, v_amt, 'Transfer → ' || v_to.name   || ' · ' || v_tag, 'manual', v_g_src),
         (v_hh, v_to.id,   'income',  v_date, v_amt, 'Transfer ← ' || v_from.name || ' · ' || v_tag, 'manual', v_g_src);

  if p_kind = 'travel' then
    -- the trip line is covered by the swap: Send-to-fund and settle-up must skip it
    update expenses set sent_to_fund = true where id = p_expense and not sent_to_fund;
    get diagnostics v_n = row_count;  -- 1 row → we set it (and undo clears it)
    v_marked := v_n > 0;
    -- and the bank pot pays the card: a spend row (daily rows do this through their category)
    insert into fund_transactions (household_id, fund_id, type, date, amount, remarks, origin, reconciled_at, reconciled_by)
    values (v_hh, v_to.id, 'expense', v_date, v_amt, v_tag || ' · paid from bank pot', 'manual', now(), 'auto')
    returning id into v_spend;
  end if;

  insert into pot_swaps (id, household_id, expense_kind, expense_id, date, src_amount, src_currency, rate, dst_amount, dst_currency,
                         cover_fund_id, land_fund_id, bank_from_fund_id, bank_to_fund_id, dst_group_id, src_group_id, spend_tx_id, marked_sent, rate_source, note)
  values (v_swap, v_hh, p_kind, p_expense, v_date, v_amt, v_cur, p_rate, v_dst, v_land.currency,
          v_cover.id, v_land.id, v_from.id, v_to.id, v_g_dst, v_g_src, v_spend, v_marked, p_rate_source, p_note);

  update expenses set pot_swap_id = v_swap where id = p_expense;
  return v_swap;
end;
$function$;

create or replace function public.delete_pot_swap(p_swap uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_hh uuid; s pot_swaps%rowtype;
begin
  select id into v_hh from households where owner_user_id = auth.uid();
  if v_hh is null then raise exception 'no household'; end if;
  select * into s from pot_swaps where id = p_swap and household_id = v_hh;
  if s.id is null then raise exception 'swap not found'; end if;
  if exists (select 1 from fund_transactions where household_id = v_hh and reconciled_by = 'manual'
              and (transfer_group_id in (s.dst_group_id, s.src_group_id) or id = s.spend_tx_id)) then
    raise exception 'locked: a row of this swap was reconciled against a statement — un-reconcile it first' using errcode = 'P0001';
  end if;
  delete from fund_transactions where household_id = v_hh
     and (transfer_group_id in (s.dst_group_id, s.src_group_id) or id = s.spend_tx_id);
  update expenses set pot_swap_id = null, sent_to_fund = case when s.marked_sent then false else sent_to_fund end
   where id = s.expense_id;
  delete from pot_swaps where id = s.id;
end;
$function$;

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
     and expense_pot(de.household_id, de.category, de.currency, de.date) = f.id
   group by 1
   order by 1 desc
$function$;

create or replace function public.send_trip_to_fund(p_trip uuid, p_fund uuid, p_date date)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  from expenses
  where trip_id = p_trip and household_id = v_hh and not sent_to_fund and currency = v_cur;
  if v_total <= 0 then raise exception 'nothing unsent in this currency'; end if;

  insert into fund_transactions (household_id, fund_id, type, date, amount, remarks, origin)
  values (v_hh, p_fund, 'expense', p_date, v_total, 'Travel: ' || v_name, 'manual');

  update expenses set sent_to_fund = true
  where trip_id = p_trip and household_id = v_hh and not sent_to_fund and currency = v_cur;

  return v_total;
end;
$function$;

create or replace function public.send_foreign_to_fund(p_trip uuid, p_fund uuid, p_date date, p_ids uuid[], p_amount numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_hh uuid; v_cur text; v_name text; v_n integer;
begin
  select id into v_hh from households where owner_user_id = auth.uid();
  if v_hh is null then raise exception 'no household'; end if;
  select currency into v_cur from funds where id = p_fund and household_id = v_hh;
  if v_cur is null then raise exception 'fund not found'; end if;
  select name into v_name from trips where id = p_trip and household_id = v_hh;
  if v_name is null then raise exception 'trip not found'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'enter the converted amount'; end if;

  update expenses set sent_to_fund = true
  where trip_id = p_trip and household_id = v_hh and not sent_to_fund
    and currency <> v_cur and id = any(p_ids);
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'nothing unsent to send'; end if;

  insert into fund_transactions (household_id, fund_id, type, date, amount, remarks, origin)
  values (v_hh, p_fund, 'expense', p_date, p_amount, 'Travel: ' || v_name || ' (converted)', 'manual');
end;
$function$;

create or replace function public.reconcile_rows(p_kind text, p_ids uuid[], p_statement uuid DEFAULT NULL::uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_hh uuid; v_n integer; v_closed timestamptz;
begin
  select id into strict v_hh from households where owner_user_id = auth.uid();
  if p_statement is not null then
    select closed_at into v_closed from statements s where s.id = p_statement and s.household_id = v_hh;
    if not found then raise exception 'statement not found'; end if;
    if v_closed is not null then raise exception 'this statement is closed — reopen it first' using errcode = 'P0001'; end if;
  end if;
  perform set_config('bh.via_rpc', 'on', true);
  if p_kind in ('daily', 'travel', 'expense') then
    update expenses set reconciled_at = now(), reconciled_by = 'manual', reconciled_statement_id = p_statement
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
end $function$;

create or replace function public.unreconcile_rows(p_kind text, p_ids uuid[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_hh uuid; v_n integer; v_closed int;
begin
  select id into strict v_hh from households where owner_user_id = auth.uid();
  -- rows ticked on a closed statement stay put until the statement is reopened on the Desk
  if p_kind in ('daily', 'travel', 'expense') then
    select count(*) into v_closed from expenses d join statements s on s.id = d.reconciled_statement_id where d.household_id = v_hh and d.id = any(p_ids) and s.closed_at is not null;
  elsif p_kind = 'fund' then
    select count(*) into v_closed from fund_transactions d join statements s on s.id = d.reconciled_statement_id where d.household_id = v_hh and d.id = any(p_ids) and s.closed_at is not null;
  else raise exception 'unknown kind %', p_kind; end if;
  if v_closed > 0 then raise exception 'this row is on a closed statement — reopen the statement on the Desk first' using errcode = 'P0001'; end if;
  perform set_config('bh.via_rpc', 'on', true);
  if p_kind in ('daily', 'travel', 'expense') then
    update expenses set reconciled_at = null, reconciled_by = null, reconciled_statement_id = null
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
end $function$;

create or replace function public.save_expense(p_kind text, p_id uuid, p_date date, p_description text, p_category text, p_amount numeric, p_currency text, p_payer uuid, p_paid_with text, p_comments text, p_seen_updated_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_hh uuid; v_now timestamptz;
begin
  select id into v_hh from households where owner_user_id = auth.uid();
  if v_hh is null then raise exception 'no household'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount must be positive'; end if;
  if p_payer is not null and not exists
     (select 1 from profiles where id = p_payer and household_id = v_hh) then
    raise exception 'payer not found';
  end if;

  if p_kind not in ('daily', 'travel', 'expense') then raise exception 'unknown kind %', p_kind; end if;
  select updated_at into v_now from expenses where id = p_id and household_id = v_hh;
  if v_now is null then raise exception 'expense not found'; end if;
  if p_seen_updated_at is not null and v_now > p_seen_updated_at + interval '1 second' then
    raise exception 'this expense was changed elsewhere after you opened it — close and reopen it to see the latest' using errcode = 'P0001';
  end if;
  update expenses
     set date = p_date, description = p_description, category = p_category,
         amount = p_amount, currency = p_currency, payer_profile_id = p_payer,
         paid_with = p_paid_with, comments = p_comments
   where id = p_id and household_id = v_hh;
  delete from expense_splits where expense_id = p_id;
  if p_payer is not null then
    insert into expense_splits (household_id, expense_id, profile_id, amount) values (v_hh, p_id, p_payer, p_amount);
  end if;
  insert into expense_splits (household_id, expense_id, profile_id, amount) values (v_hh, p_id, null, -p_amount);
end;
$function$;


-- ── 6 · prove nothing moved ──────────────────────────────────────────────
do $$
declare v_bad int; v_rows int;
begin
  select count(*) into v_bad from _before b join public.fund_balances a using (fund_id) where abs(a.balance - b.balance) > 0.005;
  if v_bad > 0 then raise exception 'expenses merge: % fund balances changed', v_bad; end if;
  select count(*) into v_rows from public.expenses;
  raise notice 'expenses merge ok: % rows, balances unchanged', v_rows;
end $$;
drop table _before;

notify pgrst, 'reload schema';
commit;
