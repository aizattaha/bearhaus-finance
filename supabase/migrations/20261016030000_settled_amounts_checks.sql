-- What the card charged, a nightly money check, and invite-only sign-up on the server (v2 sprint 2, chunk 4).
--
--  1 · expenses.settled_amount (D1-F4, pulled forward for trips)
--        A purchase in another currency on a card (¥ on UOB PPV, a US$ subscription on an A$ card) now waits for
--        what the card actually charged, in the card's currency — typed on the Desk when the statement is
--        checked. Card owed and statement totals use that amount; until it's typed the purchase is counted as
--        "waiting" (card_balances.unsettled), never as yen added to dollars. set_settled_amount() is the one
--        way to write it. The compat views carry the column for the Desk.
--  2 · bh_money_check() — read-only counts for the nightly check (.github/workflows/money-check.yml).
--        Never amounts: the Actions log is public.
--  3 · hook_before_user_created() — when switched on in Supabase (Authentication → Hooks), a sign-up must carry
--        a valid invite code, checked on the server, not only in the app.
--
-- Card owed and statement totals change only for cards holding foreign-currency purchases (asserted);
-- Available and In the bank don't move.
begin;
create temp table _b_fund as select fund_id, balance from public.fund_balances;
create temp table _b_cash as select fund_id, cash_balance from public.fund_cash;
create temp table _b_card as select payment_method_id, owed from public.card_balances;

-- ── 1 · what the card charged ───────────────────────────────────────────
alter table public.expenses add column if not exists settled_amount numeric(12,2) check (settled_amount is null or settled_amount >= 0);

create or replace view public.travel_expenses with (security_invoker = true) as
  select id, household_id, trip_id, date, description, category, amount, currency, payer_profile_id, paid_with, comments,
         sent_to_fund, legacy_sync_id, created_at, payment_method_id, reconciled_at, reconciled_statement_id, reconciled_by, pot_swap_id, updated_at,
         pot_fund_id, created_by, updated_by, category_id, is_refund, fund_id, settled_amount
    from public.expenses where trip_id is not null and deleted_at is null
  with cascaded check option;
create or replace view public.daily_expenses with (security_invoker = true) as
  select id, household_id, date, description, category, amount, currency, payer_profile_id, paid_with, comments,
         legacy_sync_id, created_at, payment_method_id, reconciled_at, reconciled_statement_id, reconciled_by, pot_swap_id, updated_at,
         pot_fund_id, created_by, updated_by, category_id, is_refund, fund_id, settled_amount
    from public.expenses where trip_id is null and deleted_at is null
  with cascaded check option;

-- server-owned like the other stamps: the Desk writes it through set_settled_amount
create or replace function public.bh_expense_client_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if tg_op = 'INSERT' then
    new.reconciled_at := null; new.reconciled_by := null; new.reconciled_statement_id := null;   -- cash re-ticks itself next
    new.deleted_at := null;
    new.pot_fund_id := null;                                                                     -- stamped by the server
    new.settlement_tx_id := null;                                                                -- set by the trip send
    new.settled_amount := null;                                                                  -- set from the statement
    new.created_by := auth.uid();
  else
    new.created_by := old.created_by;
    new.deleted_at := old.deleted_at;
    new.pot_fund_id := old.pot_fund_id;                                                          -- re-stamped when its inputs change
    new.settlement_tx_id := old.settlement_tx_id;
    new.settled_amount := old.settled_amount;
  end if;
  return new;
end $$;

create or replace function public.set_settled_amount(p_id uuid, p_amount numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_cur text; v_card_cur text; v_closed timestamptz;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  select e.currency, pm.currency, s.closed_at into v_cur, v_card_cur, v_closed
    from expenses e join payment_methods pm on pm.id = e.payment_method_id
    left join statements s on s.id = e.reconciled_statement_id
   where e.id = p_id and e.household_id = v_hh and e.deleted_at is null;
  if not found then raise exception 'purchase not found'; end if;
  if v_card_cur is null or v_cur = v_card_cur then raise exception 'this purchase is already in the card''s currency' using errcode = 'P0001'; end if;
  if p_amount is not null and p_amount < 0 then raise exception 'enter what the card charged — a refund is still a positive amount' using errcode = 'P0001'; end if;
  if v_closed is not null then raise exception 'this purchase is on a closed statement — reopen it first' using errcode = 'P0001'; end if;
  perform set_config('bh.via_rpc', 'on', true);
  update expenses set settled_amount = round(p_amount, 2) where id = p_id;
  perform set_config('bh.via_rpc', 'off', true);
end $$;
revoke execute on function public.set_settled_amount(uuid, numeric) from public, anon;
grant execute on function public.set_settled_amount(uuid, numeric) to authenticated, service_role;

-- card owed: a purchase in another currency counts at what the card charged, or waits (unsettled)
create or replace view public.card_balances with (security_invoker = true) as
 SELECT pm.household_id, pm.id AS payment_method_id, pm.name, pm.currency, pm.closing_day, pm.is_archived,
        COALESCE(ch.charges, 0) AS charges, COALESCE(ch.credits, 0) AS credits,
        COALESCE(fr.charges, 0) AS fund_charges, COALESCE(py.paid, 0) AS payments,
        round(COALESCE(op.amount, 0) + COALESCE(ch.charges, 0) - COALESCE(ch.credits, 0) + COALESCE(fr.charges, 0) - COALESCE(py.paid, 0), 2) AS owed,
        py.last_paid,
        COALESCE(op.amount, 0) AS opening,
        COALESCE(ch.unsettled, 0) AS unsettled
   FROM payment_methods pm
   JOIN households h ON h.id = pm.household_id
   LEFT JOIN card_openings op ON op.payment_method_id = pm.id
   LEFT JOIN LATERAL (
     SELECT sum(CASE WHEN pm.currency IS NULL OR e.currency = pm.currency THEN e.amount ELSE e.settled_amount END)
              FILTER (WHERE e.category <> 'Payment' AND NOT e.is_refund) AS charges,
            sum(CASE WHEN pm.currency IS NULL OR e.currency = pm.currency THEN e.amount ELSE e.settled_amount END)
              FILTER (WHERE e.category = 'Payment' OR e.is_refund) AS credits,
            count(*) FILTER (WHERE pm.currency IS NOT NULL AND e.currency <> pm.currency AND e.settled_amount IS NULL)::int AS unsettled
       FROM expenses e
      WHERE e.payment_method_id = pm.id AND e.deleted_at IS NULL AND e.date <= (now() AT TIME ZONE h.timezone)::date
        AND (h.pot_start IS NULL OR e.date >= h.pot_start)
   ) ch ON true
   LEFT JOIN LATERAL (
     SELECT sum(CASE WHEN t.type = 'expense' THEN t.amount ELSE -t.amount END) AS charges
       FROM fund_transactions t
      WHERE t.account_payment_method_id = pm.id AND t.kind = 'movement' AND t.date <= (now() AT TIME ZONE h.timezone)::date
        AND (h.pot_start IS NULL OR t.date >= h.pot_start)
        AND NOT EXISTS (SELECT 1 FROM pot_swaps ps WHERE ps.spend_tx_id = t.id)
   ) fr ON true
   LEFT JOIN LATERAL (
     SELECT sum(t.amount) AS paid, max(t.date) AS last_paid
       FROM fund_transactions t
      WHERE t.settles_payment_method_id = pm.id AND t.kind = 'card_payment' AND t.date <= (now() AT TIME ZONE h.timezone)::date
        AND (h.pot_start IS NULL OR t.date >= h.pot_start)
   ) py ON true
  WHERE pm.kind = 'credit_card';

-- statements: a ticked purchase in another currency counts at what the card charged
create or replace view public.statement_balances with (security_invoker = true) as
 SELECT s.id AS statement_id, s.household_id, s.payment_method_id, s.period_start, s.period_end, s.label,
        s.statement_total, s.closed_at,
        round(COALESCE(rx.total, 0) + COALESCE(rf.total, 0), 2) AS reconciled_total,
        round(COALESCE(s.statement_total, COALESCE(rx.total, 0) + COALESCE(rf.total, 0)), 2) AS due,
        round(COALESCE(py.paid, 0), 2) AS paid,
        py.last_paid, py.n_payments,
        CASE WHEN COALESCE(py.paid, 0) <= 0 AND COALESCE(py.scheduled, 0) <= 0 THEN 'unpaid'
             WHEN COALESCE(py.paid, 0) + 0.005 >= COALESCE(s.statement_total, COALESCE(rx.total, 0) + COALESCE(rf.total, 0)) THEN 'paid'
             WHEN COALESCE(py.paid, 0) + COALESCE(py.scheduled, 0) + 0.005 >= COALESCE(s.statement_total, COALESCE(rx.total, 0) + COALESCE(rf.total, 0)) THEN 'scheduled'
             ELSE 'part' END AS status,
        s.opening_balance, s.closing_balance, s.payment_due,
        round(COALESCE(py.scheduled, 0), 2) AS scheduled,
        py.next_payment
   FROM statements s
   JOIN households h ON h.id = s.household_id
   JOIN payment_methods pm ON pm.id = s.payment_method_id
   LEFT JOIN LATERAL (
     SELECT sum(CASE WHEN e.category = 'Payment' OR e.is_refund THEN -1 ELSE 1 END
                * CASE WHEN pm.currency IS NULL OR e.currency = pm.currency THEN e.amount ELSE e.settled_amount END) AS total
       FROM expenses e WHERE e.reconciled_statement_id = s.id AND e.deleted_at IS NULL
   ) rx ON true
   LEFT JOIN LATERAL (
     SELECT sum(CASE WHEN t.kind = 'card_payment' AND t.settles_payment_method_id = s.payment_method_id THEN -t.amount
                     WHEN t.type = 'expense' THEN t.amount ELSE -t.amount END) AS total
       FROM fund_transactions t WHERE t.reconciled_statement_id = s.id
   ) rf ON true
   LEFT JOIN LATERAL (
     SELECT sum(t.amount) FILTER (WHERE t.date <= (now() AT TIME ZONE h.timezone)::date) AS paid,
            max(t.date) FILTER (WHERE t.date <= (now() AT TIME ZONE h.timezone)::date) AS last_paid,
            count(*)::int AS n_payments,
            sum(t.amount) FILTER (WHERE t.date > (now() AT TIME ZONE h.timezone)::date) AS scheduled,
            min(t.date) FILTER (WHERE t.date > (now() AT TIME ZONE h.timezone)::date) AS next_payment
       FROM fund_transactions t WHERE t.settles_statement_id = s.id AND t.kind = 'card_payment'
   ) py ON true;

-- ── 2 · the nightly money check: counts only ────────────────────────────
-- severity: fail = something broke (the nightly job fails and GitHub emails); warn = worth a look; info = a to-do count
create or replace function public.bh_money_check()
returns table (check_name text, severity text, bad integer)
language sql stable security definer set search_path = public as $$
  select 'integrity issues noted in the last day', 'fail',
         (select count(*)::int from integrity_issues where noted_at > now() - interval '26 hours')
  union all
  select 'fund purchases in another currency or on a trip', 'fail',
         (select count(*)::int from expenses e join funds f on f.id = e.fund_id
           where e.deleted_at is null and (e.currency <> f.currency or e.trip_id is not null))
  union all
  select 'months with plan rows but no apply record', 'fail',
         (select count(*)::int from (select distinct household_id, date_trunc('month', date)::date as m from fund_transactions where origin = 'planned') x
           where not exists (select 1 from plan_applications a where a.household_id = x.household_id and a.month = x.m))
  union all
  select 'transfer and card-payment groups that don''t hold together', 'warn',
         (select count(*)::int from (select distinct transfer_group_id as g from fund_transactions_all where transfer_group_id is not null) x
           where bh_group_problem(x.g) is not null)
  union all
  select 'purchases since the start date not filed to a pot', 'warn',
         (select count(*)::int from expenses e join households h on h.id = e.household_id
           where e.trip_id is null and e.deleted_at is null and e.category <> 'Payment' and h.pot_start is not null and e.date >= h.pot_start
             and not exists (select 1 from funds f where f.id = e.pot_fund_id and f.currency = e.currency and (f.is_spend_pot or f.id = e.fund_id)))
  union all
  select 'purchases whose who-paid lines don''t match the amount', 'warn',
         (select count(*)::int from expenses e
           where e.deleted_at is null and (
                 coalesce((select sum(s.amount) from expense_splits s where s.expense_id = e.id and s.profile_id is null), 0)
                   <> -(case when e.is_refund then -e.amount else e.amount end)
              or coalesce((select sum(s.amount) from expense_splits s where s.expense_id = e.id and s.profile_id is not null), 0)
                   <> case when e.payer_profile_id is null then 0 else (case when e.is_refund then -e.amount else e.amount end) end))
  union all
  select 'rows with a negative amount', 'warn',
         (select count(*)::int from expenses where amount < 0 and deleted_at is null)
       + (select count(*)::int from fund_transactions where amount < 0)
  union all
  select 'statements that overlap on one card', 'warn',
         (select count(*)::int from statements a join statements b
             on a.payment_method_id = b.payment_method_id and a.id < b.id and a.period_start <= b.period_end and b.period_start <= a.period_end)
  union all
  select 'cards owed less than zero', 'warn', (select count(*)::int from card_balances where owed < -0.005)
  union all
  select 'funds owing less than zero on cards', 'warn', (select count(*)::int from fund_cash where owed_on_cards < -0.005)
  union all
  select 'foreign purchases on cards waiting for the charged amount', 'info', (select coalesce(sum(unsettled), 0)::int from card_balances)
$$;
revoke execute on function public.bh_money_check() from public, anon, authenticated;
grant execute on function public.bh_money_check() to service_role;

-- ── 3 · invite-only sign-up, checked by the server ──────────────────────
-- Supabase calls this before creating a login, once it is switched on (Authentication → Hooks → Before User
-- Created → Postgres → public.hook_before_user_created). The app sends the invite code in the sign-up data.
create or replace function public.hook_before_user_created(event jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_code text := nullif(trim(coalesce(event->'user'->'user_metadata'->>'invite', '')), '');
begin
  if v_code is not null and (
       exists (select 1 from beta_invites where lower(code) = lower(v_code) and used_count < max_uses)
    or exists (select 1 from member_invites where lower(code) = lower(v_code) and used_at is null and expires_at > now())) then
    return '{}'::jsonb;
  end if;
  return jsonb_build_object('error', jsonb_build_object('http_code', 403,
    'message', 'BearHaus is invite-only for now — enter the invite code from your invite message'));
end $$;
revoke execute on function public.hook_before_user_created(jsonb) from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    execute 'grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin';
  end if;
end $$;

-- ── proof ────────────────────────────────────────────────────────────────
do $$
declare v_bad int; v_cards int; v_wait int;
begin
  select count(*) into v_bad from _b_fund b join public.fund_balances a using (fund_id) where abs(a.balance - b.balance) > 0.005;
  if v_bad > 0 then raise exception 'settled amounts: % fund balances changed', v_bad; end if;
  select count(*) into v_bad from _b_cash b join public.fund_cash a using (fund_id) where abs(a.cash_balance - b.cash_balance) > 0.005;
  if v_bad > 0 then raise exception 'settled amounts: % funds'' cash changed', v_bad; end if;
  -- card owed moves only for cards holding purchases in another currency
  select count(*) into v_bad from _b_card b join public.card_balances a using (payment_method_id)
   where abs(a.owed - b.owed) > 0.005
     and not exists (select 1 from public.expenses e join public.payment_methods pm on pm.id = e.payment_method_id
                      where e.payment_method_id = a.payment_method_id and e.deleted_at is null and pm.currency is not null and e.currency <> pm.currency);
  if v_bad > 0 then raise exception 'settled amounts: % card balances changed without a reason', v_bad; end if;
  select count(*) into v_cards from _b_card b join public.card_balances a using (payment_method_id) where abs(a.owed - b.owed) > 0.005;
  select coalesce(sum(unsettled), 0) into v_wait from public.card_balances;
  raise notice 'settled amounts ok: % cards'' owed changed; % foreign purchases on cards now wait for their charged amount', v_cards, v_wait;
end $$;
drop table _b_fund; drop table _b_cash; drop table _b_card;
notify pgrst, 'reload schema';
commit;
