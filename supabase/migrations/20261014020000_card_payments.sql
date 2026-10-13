-- Card payments without double counting (14 Oct 2026) — architecture review §1.1 + Part 2.
--
-- A credit card is a liability: the purchase is the BUDGET event (the pot's Available drops the
-- day it happens — unchanged), paying the card is the CASH event (money leaves the bank). Each is
-- recorded once, on different accounts, so nothing is counted twice.
--
--  fund_transactions.kind      movement | allocation | card_payment  (was a convention, now a column)
--  settles_payment_method_id   which card a card_payment row pays
--  settles_statement_id        which bill it pays (optional; part payments allowed)
--  fund_balances (Available)   excludes card_payment rows — the whole double-count fix
--  fund_cash (In the bank)     allocations + movements incl. card payments − cash/debit spending only
--                              owed_on_cards = cash − available
--  card_balances               per card: charges − credits − payments since pot_start
--  statement_balances          per statement: due · paid · status (unpaid / part / paid)
--  record_card_payment(...)    one payment, split over the pots whose charges it covers
--  delete_card_payment(group)  undo (all legs)
--
-- Available is unchanged by construction (no card_payment rows exist yet); asserted at the end.

begin;

create temp table _before as select fund_id, balance from public.fund_balances;

-- ── kind + settles_* ─────────────────────────────────────────────────────
alter table public.fund_transactions
  add column if not exists kind text not null default 'movement',
  add column if not exists settles_payment_method_id uuid references public.payment_methods(id) on delete restrict,
  add column if not exists settles_statement_id uuid references public.statements(id) on delete set null;

-- backfill from the conventions the views used to pattern-match
update public.fund_transactions set kind = 'allocation'
 where kind = 'movement'
   and (origin = 'planned' or transfer_group_id is not null
        or remarks ~ '^Transfer [→←] ' or remarks like '%Pot swap · %' or remarks like 'Travel: %');

alter table public.fund_transactions drop constraint if exists fund_transactions_kind_check;
alter table public.fund_transactions add constraint fund_transactions_kind_check
  check (kind in ('movement', 'allocation', 'card_payment'));
alter table public.fund_transactions drop constraint if exists fund_transactions_card_payment_shape;
alter table public.fund_transactions add constraint fund_transactions_card_payment_shape
  check (case when kind = 'card_payment' then type = 'expense' and settles_payment_method_id is not null
              else settles_payment_method_id is null and settles_statement_id is null end);

create index if not exists fund_transactions_settles on public.fund_transactions (settles_payment_method_id, date) where kind = 'card_payment';
create index if not exists fund_transactions_settles_stmt on public.fund_transactions (settles_statement_id) where settles_statement_id is not null;
create index if not exists fund_transactions_fund_date on public.fund_transactions (fund_id, date);

-- the app and older RPCs don't send kind yet: derive it from the same conventions on insert
create or replace function public.bh_fund_before_write()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.kind = 'movement' and (new.origin = 'planned' or new.transfer_group_id is not null
         or new.remarks ~ '^Transfer [→←] ' or new.remarks like '%Pot swap · %' or new.remarks like 'Travel: %') then
      new.kind := 'allocation';
    end if;
    -- internal rows never appear on a bank statement: plan writes and transfers tick themselves
    if new.reconciled_at is null and (new.origin = 'planned' or new.remarks ~ '^Transfer [→←] ') then
      new.reconciled_at := now(); new.reconciled_by := 'auto'; new.reconciled_statement_id := null;
    end if;
  end if;
  if new.kind = 'card_payment' and not exists
     (select 1 from payment_methods where id = new.settles_payment_method_id and kind = 'credit_card') then
    raise exception 'a card payment must name a credit card' using errcode = 'P0001';
  end if;
  if new.settles_statement_id is not null and not exists
     (select 1 from statements where id = new.settles_statement_id and payment_method_id = new.settles_payment_method_id) then
    raise exception 'that statement belongs to another card' using errcode = 'P0001';
  end if;
  return new;
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
  if tg_table_name = 'households' then
    perform bh_assert_hh('public.funds', new.travel_fund_id, new.id, 'travel fund');
  end if;
  return new;
end $$;

-- ── a fund row charged to a credit card ─────────────────────────────────
-- fund_transactions.account_payment_method_id already names the bank account a movement cleared
-- through. Pointing it at a CREDIT CARD means "this fund spend was charged to that card": it stays a
-- budget event (Available) and becomes a cash event only when the card is paid. The pot-swap
-- "paid from bank pot" row now carries the purchase's card for exactly that reason.
create or replace function public.bh_is_credit_card(p_pm uuid)
returns boolean language sql stable set search_path = public as $$
  select coalesce((select kind = 'credit_card' from payment_methods where id = p_pm), false)
$$;

-- ── compatibility views learn the stamped pot (added after they were built) ──
create or replace view public.daily_expenses with (security_invoker = true) as
  select id, household_id, date, description, category, amount, currency, payer_profile_id, paid_with, comments,
         legacy_sync_id, created_at, payment_method_id, reconciled_at, reconciled_statement_id, reconciled_by, pot_swap_id, updated_at,
         pot_fund_id
    from public.expenses where trip_id is null
  with cascaded check option;
create or replace view public.travel_expenses with (security_invoker = true) as
  select id, household_id, trip_id, date, description, category, amount, currency, payer_profile_id, paid_with, comments,
         sent_to_fund, legacy_sync_id, created_at, payment_method_id, reconciled_at, reconciled_statement_id, reconciled_by, pot_swap_id, updated_at,
         pot_fund_id
    from public.expenses where trip_id is not null
  with cascaded check option;

-- ── Available: unchanged, minus card payments ────────────────────────────
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
            WHEN t.date > CURRENT_DATE OR t.kind = 'card_payment' THEN 0::numeric
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
            WHEN t.date > CURRENT_DATE OR t.reconciled_at IS NULL OR t.kind = 'card_payment' THEN 0::numeric
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

-- ── In the bank + Owed on cards ──────────────────────────────────────────
-- cash = every fund row incl. card payments, except fund spends charged to a credit card
--        − (pots) the pot's spending paid by cash / debit / bank / no card
-- owed_on_cards = cash − available  (credit-card charges not yet covered by a card payment;
--        negative = this pot paid a card on behalf of other pots — move it back with a transfer)
create or replace view public.fund_cash with (security_invoker = true) as
 SELECT b.household_id, b.fund_id, b.name, b.currency, b.is_active, b.is_spend_pot, b.balance,
        c.cash_balance,
        round(c.cash_balance - b.balance, 2) AS owed_on_cards
   FROM public.fund_balances b
   JOIN (
     SELECT f.id AS fund_id,
            COALESCE(sum(
                CASE
                    WHEN t.date > CURRENT_DATE THEN 0::numeric
                    WHEN t.type = 'expense' AND t.kind = 'movement' AND bh_is_credit_card(t.account_payment_method_id) THEN 0::numeric
                    WHEN t.type = 'income'::text THEN t.amount
                    ELSE - t.amount
                END), 0::numeric) -
            CASE
                WHEN f.is_spend_pot AND h.pot_start IS NOT NULL THEN COALESCE(( SELECT sum(de.amount)
                   FROM expenses de
                   LEFT JOIN payment_methods pm ON pm.id = de.payment_method_id
                  WHERE de.trip_id IS NULL AND de.household_id = f.household_id AND de.currency = f.currency
                    AND de.category <> 'Payment'::text AND de.date >= h.pot_start AND de.date <= CURRENT_DATE
                    AND de.pot_fund_id = f.id AND coalesce(pm.kind, 'cash') <> 'credit_card'), 0::numeric)
                ELSE 0::numeric
            END AS cash_balance
       FROM funds f
       JOIN households h ON h.id = f.household_id
       LEFT JOIN fund_transactions t ON t.fund_id = f.id
      GROUP BY f.id, h.pot_start
   ) c ON c.fund_id = b.fund_id;

-- ── per card: what is owed ───────────────────────────────────────────────
create or replace view public.card_balances with (security_invoker = true) as
 SELECT pm.household_id, pm.id AS payment_method_id, pm.name, pm.currency, pm.closing_day, pm.is_archived,
        COALESCE(ch.charges, 0) AS charges, COALESCE(ch.credits, 0) AS credits,
        COALESCE(fr.charges, 0) AS fund_charges,
        COALESCE(py.paid, 0) AS payments,
        round(COALESCE(ch.charges, 0) - COALESCE(ch.credits, 0) + COALESCE(fr.charges, 0) - COALESCE(py.paid, 0), 2) AS owed,
        py.last_paid
   FROM payment_methods pm
   JOIN households h ON h.id = pm.household_id
   LEFT JOIN LATERAL (
     SELECT sum(e.amount) FILTER (WHERE e.category <> 'Payment') AS charges,
            sum(e.amount) FILTER (WHERE e.category = 'Payment') AS credits
       FROM expenses e
      WHERE e.payment_method_id = pm.id AND e.date <= CURRENT_DATE AND (h.pot_start IS NULL OR e.date >= h.pot_start)
   ) ch ON true
   LEFT JOIN LATERAL (
     SELECT sum(CASE WHEN t.type = 'expense' THEN t.amount ELSE -t.amount END) AS charges
       FROM fund_transactions t
      WHERE t.account_payment_method_id = pm.id AND t.kind = 'movement'
        AND t.date <= CURRENT_DATE AND (h.pot_start IS NULL OR t.date >= h.pot_start)
   ) fr ON true
   LEFT JOIN LATERAL (
     SELECT sum(t.amount) AS paid, max(t.date) AS last_paid
       FROM fund_transactions t
      WHERE t.settles_payment_method_id = pm.id AND t.kind = 'card_payment' AND t.date <= CURRENT_DATE
   ) py ON true
  WHERE pm.kind = 'credit_card';

-- ── per statement: due · paid · status ───────────────────────────────────
create or replace view public.statement_balances with (security_invoker = true) as
 SELECT s.id AS statement_id, s.household_id, s.payment_method_id, s.period_start, s.period_end, s.label,
        s.statement_total, s.closed_at,
        round(COALESCE(rx.total, 0) + COALESCE(rf.total, 0), 2) AS reconciled_total,
        round(COALESCE(s.statement_total, COALESCE(rx.total, 0) + COALESCE(rf.total, 0)), 2) AS due,
        round(COALESCE(py.paid, 0), 2) AS paid,
        py.last_paid, py.n_payments,
        CASE WHEN COALESCE(py.paid, 0) <= 0 THEN 'unpaid'
             WHEN COALESCE(py.paid, 0) + 0.005 >= COALESCE(s.statement_total, COALESCE(rx.total, 0) + COALESCE(rf.total, 0)) THEN 'paid'
             ELSE 'part' END AS status
   FROM statements s
   LEFT JOIN LATERAL (
     SELECT sum(CASE WHEN e.category = 'Payment' THEN -e.amount ELSE e.amount END) AS total
       FROM expenses e WHERE e.reconciled_statement_id = s.id
   ) rx ON true
   LEFT JOIN LATERAL (
     SELECT sum(CASE WHEN t.type = 'expense' THEN t.amount ELSE -t.amount END) AS total
       FROM fund_transactions t WHERE t.reconciled_statement_id = s.id
   ) rf ON true
   LEFT JOIN LATERAL (
     SELECT sum(t.amount) AS paid, max(t.date) AS last_paid, count(*)::int AS n_payments
       FROM fund_transactions t WHERE t.settles_statement_id = s.id AND t.kind = 'card_payment'
   ) py ON true;

grant all on table public.fund_balances, public.fund_balances_cleared, public.fund_cash, public.card_balances, public.statement_balances
  to anon, authenticated, service_role;

-- ── record / undo a card payment ─────────────────────────────────────────
-- p_legs: [{"fund_id": uuid, "amount": numeric}, ...] — one leg per pot that pays its share.
-- Legs share a transfer_group_id so they are undone together (the pair-delete trigger removes
-- the rest of the group). Returns the group id.
create or replace function public.record_card_payment(
  p_card uuid, p_date date, p_legs jsonb, p_statement uuid default null, p_remarks text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_hh uuid; v_card payment_methods%rowtype; v_stmt statements%rowtype;
  v_group uuid := gen_random_uuid(); v_leg record; v_fund funds%rowtype; v_n int := 0; v_total numeric := 0;
  v_tag text;
begin
  select id into v_hh from households where owner_user_id = auth.uid();
  if v_hh is null then raise exception 'no household'; end if;
  select * into v_card from payment_methods where id = p_card and household_id = v_hh;
  if v_card.id is null then raise exception 'card not found'; end if;
  if v_card.kind <> 'credit_card' then raise exception '% is not a credit card', v_card.name; end if;
  if p_statement is not null then
    select * into v_stmt from statements where id = p_statement and household_id = v_hh;
    if v_stmt.id is null then raise exception 'statement not found'; end if;
    if v_stmt.payment_method_id <> p_card then raise exception 'that statement belongs to another card'; end if;
  end if;
  if p_date is null then raise exception 'enter the payment date'; end if;
  if jsonb_typeof(p_legs) <> 'array' or jsonb_array_length(p_legs) = 0 then raise exception 'say which fund pays'; end if;

  -- the remark always starts with "Paid <card>" so every list reads the same; a note or the statement follows
  v_tag := 'Paid ' || v_card.name || case
             when nullif(trim(p_remarks), '') is not null then ' · ' || trim(p_remarks)
             when v_stmt.id is not null then ' · statement ' || to_char(v_stmt.period_start, 'DD Mon') || ' – ' || to_char(v_stmt.period_end, 'DD Mon YYYY')
             else '' end;

  for v_leg in select (x->>'fund_id')::uuid as fund_id, (x->>'amount')::numeric as amount from jsonb_array_elements(p_legs) x loop
    if v_leg.amount is null or v_leg.amount <= 0 then raise exception 'each amount must be positive'; end if;
    select * into v_fund from funds where id = v_leg.fund_id and household_id = v_hh and is_active;
    if v_fund.id is null then raise exception 'fund not found'; end if;
    if v_card.currency is not null and v_fund.currency <> v_card.currency then
      raise exception '% is in %, the card is in % — pay it from a fund in %', v_fund.name, v_fund.currency, v_card.currency, v_card.currency;
    end if;
    insert into fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin,
                                   transfer_group_id, settles_payment_method_id, settles_statement_id)
    values (v_hh, v_fund.id, 'expense', 'card_payment', p_date, round(v_leg.amount, 2), v_tag, 'manual',
            v_group, p_card, p_statement);
    v_n := v_n + 1; v_total := v_total + v_leg.amount;
  end loop;
  return v_group;
end;
$$;
revoke all on function public.record_card_payment(uuid, date, jsonb, uuid, text) from public;
grant execute on function public.record_card_payment(uuid, date, jsonb, uuid, text) to authenticated, service_role;

create or replace function public.delete_card_payment(p_group uuid)
returns integer
language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_n int;
begin
  select id into v_hh from households where owner_user_id = auth.uid();
  if v_hh is null then raise exception 'no household'; end if;
  if exists (select 1 from fund_transactions where household_id = v_hh and transfer_group_id = p_group
              and kind = 'card_payment' and reconciled_at is not null and reconciled_by = 'manual') then
    raise exception 'this payment is ticked off on a bank statement — un-reconcile it first' using errcode = 'P0001';
  end if;
  delete from fund_transactions where household_id = v_hh and transfer_group_id = p_group and kind = 'card_payment';
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'payment not found'; end if;
  return v_n;
end;
$$;
revoke all on function public.delete_card_payment(uuid) from public;
grant execute on function public.delete_card_payment(uuid) to authenticated, service_role;

-- the pair-delete trigger removes the rest of a group when one leg goes — it already does, for any group

-- ── pot swap: the bank-pot spend row is charged to the purchase's card ───
create or replace function public.record_pot_swap(p_kind text, p_expense uuid, p_rate numeric, p_cover uuid, p_land uuid, p_bank_from uuid, p_bank_to uuid, p_rate_source text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_hh uuid; v_date date; v_desc text; v_amt numeric; v_cur text; v_pm uuid;
  v_cover funds%rowtype; v_land funds%rowtype; v_from funds%rowtype; v_to funds%rowtype;
  v_dst numeric; v_tag text; v_swap uuid := gen_random_uuid();
  v_g_dst uuid := gen_random_uuid(); v_g_src uuid := gen_random_uuid();
  v_spend uuid; v_marked boolean := false; v_n integer;
begin
  select id into v_hh from households where owner_user_id = auth.uid();
  if v_hh is null then raise exception 'no household'; end if;
  if p_kind not in ('daily', 'travel') then raise exception 'kind must be daily or travel'; end if;
  if p_rate is null or p_rate <= 0 then raise exception 'enter the exchange rate'; end if;

  select date, description, amount, currency, case when trip_id is null then 'daily' else 'travel' end, payment_method_id
    into v_date, v_desc, v_amt, v_cur, p_kind, v_pm
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

  insert into fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin, transfer_group_id)
  values (v_hh, v_cover.id, 'expense', 'allocation', v_date, v_dst, 'Transfer → ' || v_land.name  || ' · ' || v_tag, 'manual', v_g_dst),
         (v_hh, v_land.id,  'income',  'allocation', v_date, v_dst, 'Transfer ← ' || v_cover.name || ' · ' || v_tag, 'manual', v_g_dst);
  insert into fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin, transfer_group_id)
  values (v_hh, v_from.id, 'expense', 'allocation', v_date, v_amt, 'Transfer → ' || v_to.name   || ' · ' || v_tag, 'manual', v_g_src),
         (v_hh, v_to.id,   'income',  'allocation', v_date, v_amt, 'Transfer ← ' || v_from.name || ' · ' || v_tag, 'manual', v_g_src);

  if p_kind = 'travel' then
    update expenses set sent_to_fund = true where id = p_expense and not sent_to_fund;
    get diagnostics v_n = row_count;
    v_marked := v_n > 0;
    -- the bank pot pays for the trip line: a spend row. If the line was on a credit card the row
    -- carries that card, so the pot's cash only moves when the card is paid.
    insert into fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin, reconciled_at, reconciled_by, account_payment_method_id)
    values (v_hh, v_to.id, 'expense', 'movement', v_date, v_amt, v_tag || ' · paid from bank pot', 'manual', now(), 'auto',
            case when bh_is_credit_card(v_pm) then v_pm end)
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

-- ── proof: Available did not move ────────────────────────────────────────
do $$
declare v_bad int; v_n int;
begin
  select count(*) into v_bad from _before b join public.fund_balances a using (fund_id) where abs(a.balance - b.balance) > 0.005;
  if v_bad > 0 then raise exception 'card payments: % fund balances changed', v_bad; end if;
  select count(*) into v_n from public.fund_transactions where kind = 'allocation';
  raise notice 'card payments ok: balances unchanged · % rows classed as allocation', v_n;
end $$;
drop table _before;

notify pgrst, 'reload schema';
commit;
