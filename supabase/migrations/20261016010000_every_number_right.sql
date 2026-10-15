-- Every number right (v2 sprint 2, chunk 2).
--
--  1 · One "today" per household (D1-F13)
--        households.timezone (Australia/Melbourne unless set) and bh_today(household). Every money view and
--        pot_month_spend count a row once it is dated today in the household's own time zone, not in UTC —
--        before this, a purchase made before 10–11 am in Melbourne sat in "Scheduled". A new household's
--        pot_start is its own month.
--  2 · A trip paid on a credit card left the bank twice (D1-F1)
--        Sending a trip to the travel fund now records which purchases it settled (expenses.settlement_tx_id).
--        The part of the trip charged to credit cards since the start date stays "in the bank" (owed on cards)
--        until the card is paid, so paying the card no longer takes it out a second time. Available is
--        unchanged. Existing trip sends are linked only where the match is exact (one send for the trip and
--        currency, amount equal to the sent purchases).
--  3 · A trip pot swap on a credit card also left the bank twice (D1-F2, corrected)
--        The swap's "paid from bank pot" row is charged to the card, but the remark rule files it as an
--        allocation, so In the bank dropped when the swap was recorded and again when the card was paid. Any
--        row charged to a credit card now stays in the bank until the card is paid, whatever its kind. (The
--        card's owed was not double-counted after all — the same rule kept the row out of it; that view now
--        leaves swap rows out explicitly.)
--  4 · Statements (D1-F10, invariant 20)
--        A card payment ticked on its own card's statement now reduces the ticked total (it was added).
--        A payment dated after today is "scheduled", not "paid" (new columns scheduled, next_payment).
--
-- Proof at the end: Available moves only for funds with rows dated inside today's time-zone gap; card owed
-- and fund cash move only where fixes 2–3 or that gap explain it. Counts only — never amounts.
begin;
create temp table _b_fund as select fund_id, balance from public.fund_balances;
create temp table _b_cash as select fund_id, cash_balance from public.fund_cash;
create temp table _b_card as select payment_method_id, owed from public.card_balances;

-- ── 1 · the household's own today ───────────────────────────────────────
alter table public.households add column if not exists timezone text not null default 'Australia/Melbourne';

create or replace function public.bh_household_tz_check()
returns trigger language plpgsql set search_path = public as $$
begin
  new.timezone := trim(new.timezone);
  perform now() at time zone new.timezone;
  return new;
exception when invalid_parameter_value then
  raise exception '% isn''t a time zone — use a name like Australia/Melbourne or Asia/Singapore', new.timezone using errcode = '22023';
end $$;
revoke execute on function public.bh_household_tz_check() from public, anon, authenticated;
drop trigger if exists b2_households_timezone on public.households;
create trigger b2_households_timezone before insert or update of timezone on public.households
  for each row execute function public.bh_household_tz_check();

create or replace function public.bh_today(p_hh uuid)
returns date language sql stable set search_path = public as $$
  select (now() at time zone coalesce((select timezone from households where id = p_hh), 'Australia/Melbourne'))::date
$$;
revoke execute on function public.bh_today(uuid) from public, anon;
grant execute on function public.bh_today(uuid) to authenticated, service_role;

-- ── 2 · which purchases a trip send settled ─────────────────────────────
alter table public.expenses add column if not exists settlement_tx_id uuid references public.fund_transactions_all(id) on delete set null;
create index if not exists expenses_settlement on public.expenses (settlement_tx_id) where settlement_tx_id is not null;

-- server-owned, like pot_fund_id: a client can't set or change it
create or replace function public.bh_expense_client_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if tg_op = 'INSERT' then
    new.reconciled_at := null; new.reconciled_by := null; new.reconciled_statement_id := null;   -- cash re-ticks itself next
    new.deleted_at := null;
    new.pot_fund_id := null;                                                                     -- stamped by the server
    new.settlement_tx_id := null;                                                                -- set by the trip send
    new.created_by := auth.uid();
  else
    new.created_by := old.created_by;
    new.deleted_at := old.deleted_at;
    new.pot_fund_id := old.pot_fund_id;                                                          -- re-stamped when its inputs change
    new.settlement_tx_id := old.settlement_tx_id;
  end if;
  return new;
end $$;

create or replace function public.send_trip_to_fund(p_trip uuid, p_fund uuid, p_date date)
returns numeric language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_cur text; v_name text; v_total numeric; v_tx uuid;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  select currency into v_cur from funds where id = p_fund and household_id = v_hh;
  if v_cur is null then raise exception 'fund not found'; end if;
  select name into v_name from trips where id = p_trip and household_id = v_hh;
  if v_name is null then raise exception 'trip not found'; end if;
  select coalesce(sum(case when is_refund then -amount else amount end), 0) into v_total
    from expenses where trip_id = p_trip and household_id = v_hh and not sent_to_fund and currency = v_cur and deleted_at is null;
  if v_total <= 0 then raise exception 'nothing unsent in this currency'; end if;
  insert into fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin)
  values (v_hh, p_fund, 'expense', 'allocation', p_date, v_total, 'Travel: ' || v_name, 'manual')
  returning id into v_tx;
  update expenses set sent_to_fund = true, settlement_tx_id = v_tx
   where trip_id = p_trip and household_id = v_hh and not sent_to_fund and currency = v_cur and deleted_at is null;
  return v_total;
end $$;

create or replace function public.send_foreign_to_fund(p_trip uuid, p_fund uuid, p_date date, p_ids uuid[], p_amount numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_cur text; v_name text; v_n integer; v_tx uuid;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  select currency into v_cur from funds where id = p_fund and household_id = v_hh;
  if v_cur is null then raise exception 'fund not found'; end if;
  select name into v_name from trips where id = p_trip and household_id = v_hh;
  if v_name is null then raise exception 'trip not found'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'enter the converted amount'; end if;
  insert into fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin)
  values (v_hh, p_fund, 'expense', 'allocation', p_date, p_amount, 'Travel: ' || v_name || ' (converted)', 'manual')
  returning id into v_tx;
  update expenses set sent_to_fund = true, settlement_tx_id = v_tx
   where trip_id = p_trip and household_id = v_hh and not sent_to_fund and currency <> v_cur and id = any(p_ids) and deleted_at is null;
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'nothing unsent to send'; end if;
end $$;

-- link the trip sends already made, where the match is exact. A plain data link: no activity entries,
-- no "changed" stamps, so the triggers are paused for this one statement.
do $$
declare v_off int;
begin
  select count(*) into v_off from pg_trigger where tgrelid = 'public.expenses'::regclass and not tgisinternal and tgenabled = 'D';
  if v_off > 0 then raise exception 'every number right: % triggers on expenses are already disabled — stopping', v_off; end if;
end $$;
alter table public.expenses disable trigger user;
with sends as (
  select a.id, a.household_id, a.amount, f.currency, t.id as trip_id
    from public.fund_transactions a
    join public.funds f on f.id = a.fund_id
    join public.trips t on t.household_id = a.household_id and a.remarks = 'Travel: ' || t.name
   where a.kind = 'allocation' and a.type = 'expense'
     and (select count(*) from public.trips t2 where t2.household_id = t.household_id and t2.name = t.name) = 1
), one_each as (
  select s.* from sends s
   where (select count(*) from sends s2 where s2.trip_id = s.trip_id and s2.currency = s.currency) = 1
), exact as (
  select o.* from one_each o
   where abs(o.amount - (select coalesce(sum(case when e.is_refund then -e.amount else e.amount end), 0)
                           from public.expenses e
                          where e.trip_id = o.trip_id and e.sent_to_fund and e.currency = o.currency and e.deleted_at is null
                            and e.pot_swap_id is null and e.settlement_tx_id is null)) < 0.005
)
update public.expenses e set settlement_tx_id = x.id
  from exact x
 where e.trip_id = x.trip_id and e.sent_to_fund and e.currency = x.currency and e.deleted_at is null
   and e.pot_swap_id is null and e.settlement_tx_id is null;
alter table public.expenses enable trigger user;

-- ── the money views: household today; trip card share; swap counted once; statement sign ──
create or replace view public.fund_balances with (security_invoker = true) as
 SELECT f.household_id, f.id AS fund_id, f.name, f.country, f.currency, f.is_active, f.sort_order, f.group_name, f.is_leftover_target, f.is_spend_pot,
    COALESCE(sum(CASE WHEN t.date > (now() AT TIME ZONE h.timezone)::date OR t.kind = 'card_payment' THEN 0::numeric WHEN t.type = 'income' THEN t.amount ELSE - t.amount END), 0::numeric) -
    COALESCE((SELECT sum(CASE WHEN de.is_refund THEN -de.amount ELSE de.amount END) FROM expenses de
               WHERE de.trip_id IS NULL AND de.deleted_at IS NULL AND de.household_id = f.household_id AND de.currency = f.currency AND de.category <> 'Payment'
                 AND de.date <= (now() AT TIME ZONE h.timezone)::date AND de.pot_fund_id = f.id
                 AND (de.fund_id = f.id OR (f.is_spend_pot AND h.pot_start IS NOT NULL AND de.date >= h.pot_start))), 0::numeric) AS balance
   FROM funds f
   JOIN households h ON h.id = f.household_id
   LEFT JOIN fund_transactions t ON t.fund_id = f.id
  GROUP BY f.id, h.pot_start, h.timezone;

create or replace view public.fund_balances_cleared with (security_invoker = true) as
 SELECT f.household_id, f.id AS fund_id, f.name, f.country, f.currency, f.is_active, f.sort_order, f.group_name, f.is_leftover_target, f.is_spend_pot,
    COALESCE(sum(CASE WHEN t.date > (now() AT TIME ZONE h.timezone)::date OR t.reconciled_at IS NULL OR t.kind = 'card_payment' THEN 0::numeric WHEN t.type = 'income' THEN t.amount ELSE - t.amount END), 0::numeric) -
    COALESCE((SELECT sum(CASE WHEN de.is_refund THEN -de.amount ELSE de.amount END) FROM expenses de
               WHERE de.trip_id IS NULL AND de.deleted_at IS NULL AND de.household_id = f.household_id AND de.currency = f.currency AND de.category <> 'Payment'
                 AND de.date <= (now() AT TIME ZONE h.timezone)::date AND de.reconciled_at IS NOT NULL AND de.pot_fund_id = f.id
                 AND (de.fund_id = f.id OR (f.is_spend_pot AND h.pot_start IS NOT NULL AND de.date >= h.pot_start))), 0::numeric) AS cleared_balance,
    COALESCE((SELECT sum(CASE WHEN de.is_refund THEN -de.amount ELSE de.amount END) FROM expenses de
               WHERE de.trip_id IS NULL AND de.deleted_at IS NULL AND de.household_id = f.household_id AND de.currency = f.currency AND de.category <> 'Payment'
                 AND de.date <= (now() AT TIME ZONE h.timezone)::date AND de.reconciled_at IS NULL AND de.pot_fund_id = f.id
                 AND (de.fund_id = f.id OR (f.is_spend_pot AND h.pot_start IS NOT NULL AND de.date >= h.pot_start))), 0::numeric) AS pending_spend
   FROM funds f
   JOIN households h ON h.id = f.household_id
   LEFT JOIN fund_transactions t ON t.fund_id = f.id
  GROUP BY f.id, h.pot_start, h.timezone;

-- In the bank: a row charged to a credit card (a movement, or a pot swap's bank-pot row) is not cash yet;
-- + the card share of each trip sent to this fund (charged to credit cards since the start date; it leaves
-- when the card is paid). A converted send splits its amount in proportion.
create or replace view public.fund_cash with (security_invoker = true) as
 SELECT b.household_id, b.fund_id, b.name, b.currency, b.is_active, b.is_spend_pot, b.balance,
        c.cash_balance, round(c.cash_balance - b.balance, 2) AS owed_on_cards
   FROM public.fund_balances b
   JOIN (
     SELECT f.id AS fund_id,
            COALESCE(sum(CASE WHEN t.date > (now() AT TIME ZONE h.timezone)::date THEN 0::numeric
                              WHEN t.type = 'expense' AND t.kind <> 'card_payment' AND bh_is_credit_card(t.account_payment_method_id) THEN 0::numeric
                              WHEN t.type = 'income' THEN t.amount ELSE - t.amount END), 0::numeric) -
            COALESCE((SELECT sum(CASE WHEN de.is_refund THEN -de.amount ELSE de.amount END) FROM expenses de
                       LEFT JOIN payment_methods pm ON pm.id = de.payment_method_id
                      WHERE de.trip_id IS NULL AND de.deleted_at IS NULL AND de.household_id = f.household_id AND de.currency = f.currency
                        AND de.category <> 'Payment' AND de.date <= (now() AT TIME ZONE h.timezone)::date AND de.pot_fund_id = f.id
                        AND (de.fund_id = f.id OR (f.is_spend_pot AND h.pot_start IS NOT NULL AND de.date >= h.pot_start))
                        AND coalesce(pm.kind, 'cash') <> 'credit_card'), 0::numeric) +
            COALESCE((SELECT sum(o.amount) FROM card_openings o WHERE o.fund_id = f.id), 0::numeric) +
            COALESCE((SELECT sum(round(a.amount * l.cards / l.total, 2))
                        FROM fund_transactions a
                        JOIN LATERAL (
                          SELECT sum(CASE WHEN e.is_refund THEN -e.amount ELSE e.amount END) AS total,
                                 sum(CASE WHEN e.is_refund THEN -e.amount ELSE e.amount END)
                                   FILTER (WHERE bh_is_credit_card(e.payment_method_id) AND (h.pot_start IS NULL OR e.date >= h.pot_start)) AS cards
                            FROM expenses e WHERE e.settlement_tx_id = a.id AND e.deleted_at IS NULL
                        ) l ON true
                       WHERE a.fund_id = f.id AND a.type = 'expense' AND a.kind = 'allocation'
                         AND a.date <= (now() AT TIME ZONE h.timezone)::date AND l.total > 0 AND l.cards IS NOT NULL), 0::numeric) AS cash_balance
       FROM funds f
       JOIN households h ON h.id = f.household_id
       LEFT JOIN fund_transactions t ON t.fund_id = f.id
      GROUP BY f.id, h.pot_start, h.timezone
   ) c ON c.fund_id = b.fund_id;

-- card owed: a pot swap's "paid from bank pot" row is never a second charge (the purchase is on the card)
create or replace view public.card_balances with (security_invoker = true) as
 SELECT pm.household_id, pm.id AS payment_method_id, pm.name, pm.currency, pm.closing_day, pm.is_archived,
        COALESCE(ch.charges, 0) AS charges, COALESCE(ch.credits, 0) AS credits,
        COALESCE(fr.charges, 0) AS fund_charges, COALESCE(py.paid, 0) AS payments,
        round(COALESCE(op.amount, 0) + COALESCE(ch.charges, 0) - COALESCE(ch.credits, 0) + COALESCE(fr.charges, 0) - COALESCE(py.paid, 0), 2) AS owed,
        py.last_paid,
        COALESCE(op.amount, 0) AS opening
   FROM payment_methods pm
   JOIN households h ON h.id = pm.household_id
   LEFT JOIN card_openings op ON op.payment_method_id = pm.id
   LEFT JOIN LATERAL (
     SELECT sum(e.amount) FILTER (WHERE e.category <> 'Payment' AND NOT e.is_refund) AS charges,
            sum(e.amount) FILTER (WHERE e.category = 'Payment' OR e.is_refund) AS credits
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

-- statements: a payment on the card's own statement is a credit; future payments are "scheduled"
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
   LEFT JOIN LATERAL (
     SELECT sum(CASE WHEN e.category = 'Payment' OR e.is_refund THEN -e.amount ELSE e.amount END) AS total
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
     and de.date <= (now() at time zone h.timezone)::date and de.pot_fund_id = f.id
     and (de.fund_id = f.id or (f.is_spend_pot and h.pot_start is not null and de.date >= h.pot_start))
   group by 1 order by 1 desc
$function$;

-- a new household starts counting from its own month
CREATE OR REPLACE FUNCTION public.create_household_setup(p_code text, p_household text, p_people text[], p_joint_label text, p_countries text[], p_currencies text[] DEFAULT NULL::text[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_first   uuid := null;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  if exists (select 1 from household_members where user_id = v_uid) then raise exception 'this login already belongs to a household'; end if;
  if coalesce(array_length(p_people, 1), 0) = 0 then raise exception 'add at least one person'; end if;
  if coalesce(array_length(p_people, 1), 0) > 6 then raise exception 'six people max for now'; end if;
  if coalesce(array_length(p_countries, 1), 0) = 0 then raise exception 'pick at least one country'; end if;
  if coalesce(array_length(p_countries, 1), 0) > 4 then raise exception 'four countries max for now'; end if;
  if p_currencies is not null
     and coalesce(array_length(p_currencies, 1), 0) <> coalesce(array_length(p_countries, 1), 0) then
    raise exception 'countries and currencies don''t line up';
  end if;
  if exists (select 1 from member_invites where lower(code) = lower(trim(p_code)) and used_at is null and expires_at > now()) then
    raise exception 'that code joins an existing household — use "join" instead of creating a new one';
  end if;

  update beta_invites set used_count = used_count + 1
   where lower(code) = lower(trim(p_code)) and used_count < max_uses;
  if not found then raise exception 'invite code not recognised — or already used'; end if;

  insert into households (name, owner_user_id, joint_label, pot_start)
  values (coalesce(nullif(trim(p_household), ''), 'My household'), v_uid,
          nullif(trim(coalesce(p_joint_label, '')), ''), date_trunc('month', now() at time zone 'Australia/Melbourne')::date)   -- the households.timezone default
  returning id into v_hh;

  foreach v_person in array p_people loop
    if trim(v_person) <> '' then
      insert into profiles (household_id, display_name, sort_order, auth_user_id)
      values (v_hh, trim(v_person), v_psort, case when v_psort = 0 then v_uid end)
      returning id into v_fund;
      if v_psort = 0 then v_first := v_fund; end if;
      v_psort := v_psort + 1;
    end if;
  end loop;
  -- the first name is the person signing up
  insert into household_members (household_id, user_id, role, profile_id) values (v_hh, v_uid, 'owner', v_first);

  for v_i in 1 .. array_length(p_countries, 1) loop
    v_cc := upper(trim(p_countries[v_i]));
    if v_cc !~ '^[A-Z]{2}$' then raise exception 'country codes are two letters — got %', v_cc; end if;
    v_cur := case when p_currencies is not null then upper(trim(p_currencies[v_i]))
                  when v_cc = 'SG' then 'SGD' when v_cc = 'AU' then 'AUD' else null end;
    if v_cur is null or v_cur !~ '^[A-Z]{3}$' then raise exception 'missing or invalid currency for %', v_cc; end if;
    v_sfx := case when array_length(p_countries, 1) > 1 then ' ' || v_cc else '' end;
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

  insert into payment_methods (household_id, name, profile_id, sort_order, kind, currency)
  values (v_hh, 'Cash', null, 0, 'cash', null);
  insert into payment_methods (household_id, name, profile_id, sort_order, kind, currency)
  select v_hh, 'Bank card — ' || display_name, id, 1 + sort_order, 'debit_card', null
  from profiles where household_id = v_hh;

  perform seed_default_categories(v_hh);
  return v_hh;
end;
$function$;

-- ── proof ────────────────────────────────────────────────────────────────
-- the time-zone gap: rows dated after the server's date but not after the household's own today
create temp table _gap as
  select h.id as household_id, current_date as utc_today, (now() at time zone h.timezone)::date as hh_today from public.households h;
do $$
declare v_bad int; v_fund int; v_cash int; v_card int; v_linked int; v_sends int;
begin
  -- Available: moves only for a fund with a row dated inside the gap
  select count(*) into v_bad
    from _b_fund b join public.fund_balances a using (fund_id) join _gap g on g.household_id = a.household_id
   where abs(a.balance - b.balance) > 0.005
     and not exists (select 1 from public.fund_transactions t where t.fund_id = a.fund_id and t.date > g.utc_today and t.date <= g.hh_today)
     and not exists (select 1 from public.expenses e where e.pot_fund_id = a.fund_id and e.deleted_at is null and e.date > g.utc_today and e.date <= g.hh_today);
  if v_bad > 0 then raise exception 'every number right: % fund balances changed without a reason', v_bad; end if;
  select count(*) into v_fund from _b_fund b join public.fund_balances a using (fund_id) where abs(a.balance - b.balance) > 0.005;

  -- In the bank: moves only for a fund with a linked trip send, a pot-swap row on a card, or a row inside the gap
  select count(*) into v_bad
    from _b_cash b join public.fund_cash a using (fund_id) join _gap g on g.household_id = a.household_id
   where abs(a.cash_balance - b.cash_balance) > 0.005
     and not exists (select 1 from public.fund_transactions t join public.expenses e on e.settlement_tx_id = t.id where t.fund_id = a.fund_id)
     and not exists (select 1 from public.fund_transactions t where t.fund_id = a.fund_id and t.type = 'expense' and t.kind = 'allocation'
                                                                and public.bh_is_credit_card(t.account_payment_method_id))
     and not exists (select 1 from public.fund_transactions t where t.fund_id = a.fund_id and t.date > g.utc_today and t.date <= g.hh_today)
     and not exists (select 1 from public.expenses e where e.pot_fund_id = a.fund_id and e.deleted_at is null and e.date > g.utc_today and e.date <= g.hh_today);
  if v_bad > 0 then raise exception 'every number right: % funds'' cash changed without a reason', v_bad; end if;
  select count(*) into v_cash from _b_cash b join public.fund_cash a using (fund_id) where abs(a.cash_balance - b.cash_balance) > 0.005;

  -- card owed: moves only for a card with a pot-swap spend row, or a row inside the gap
  select count(*) into v_bad
    from _b_card b join public.card_balances a using (payment_method_id) join _gap g on g.household_id = a.household_id
   where abs(a.owed - b.owed) > 0.005
     and not exists (select 1 from public.pot_swaps ps join public.fund_transactions t on t.id = ps.spend_tx_id where t.account_payment_method_id = a.payment_method_id)
     and not exists (select 1 from public.expenses e where e.payment_method_id = a.payment_method_id and e.deleted_at is null and e.date > g.utc_today and e.date <= g.hh_today)
     and not exists (select 1 from public.fund_transactions t where (t.account_payment_method_id = a.payment_method_id or t.settles_payment_method_id = a.payment_method_id)
                                                                and t.date > g.utc_today and t.date <= g.hh_today);
  if v_bad > 0 then raise exception 'every number right: % card balances changed without a reason', v_bad; end if;
  select count(*) into v_card from _b_card b join public.card_balances a using (payment_method_id) where abs(a.owed - b.owed) > 0.005;

  select count(distinct settlement_tx_id), count(*) into v_sends, v_linked from public.expenses where settlement_tx_id is not null;
  raise notice 'every number right ok: % trip sends linked (% purchases); changed — Available: % funds, In the bank: % funds, card owed: % cards',
    v_sends, v_linked, v_fund, v_cash, v_card;
end $$;
drop table _b_fund; drop table _b_cash; drop table _b_card; drop table _gap;
notify pgrst, 'reload schema';
commit;
