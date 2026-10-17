-- Trips across currencies, by one rule for all time (Aizat, 17 Oct 2026 — DECISIONS E32, E33).
--
--  1 · A trip fund per currency. funds.pays_trips marks the fund that pays trip spending in its currency;
--        households.travel_fund_id stays the main one (spending in a currency with no trip fund is converted into
--        it). bh_trip_fund(household, currency); set_trip_fund(currency, fund) for Settings. Starting point: the
--        main travel fund pays its own currency, and each other currency is paid by the fund this household's
--        latest trip send in that currency went to. A new household: each country's travel fund.
--  2 · The rule, for every trip purchase (bh_trip_lines):
--        on a credit card → the trip fund in the CARD's currency, at what the card charged (the amount when the
--          purchase is in the card's currency, else settled_amount — the purchase waits until that is typed on the
--          Desk);
--        anything else (cash, bank, prepaid) → by the currency it was spent in: face value into that currency's trip
--          fund; a currency with no trip fund is converted into the main travel fund at an amount typed when
--          sending, shared over its purchases in proportion.
--  3 · What a purchase took from its fund is kept on it (expenses.sent_amount, positive; a refund counts negative),
--        a send is a fund row that names its trip (fund_transactions_all.trip_id), and a send always equals the sum
--        of its purchases. trip_send_plan(trip) is the split the phone shows; send_trip(trip, date, converted) sends
--        everything ready in one go, one fund row per fund; undo_trip_send(send) takes one back. The old
--        send_trip_to_fund / send_foreign_to_fund ask for a reload.
--  4 · A sent purchase keeps its amount, currency, card, refund flag, trip and bin state until its send is undone;
--        what the card charged can still be corrected on the Desk and the send follows it. A send can't be edited or
--        restored on its own; binning one is the same as undoing it.
--  5 · fund_money: the part of a send owed on cards (until the card is paid) is exactly what its card purchases
--        took, in the fund's own currency — not a proportion, and never a card in another currency.
--  6 · Every past send is re-derived by the rule (bh_rederive_trip_sends — server-only, and safe to run again: a
--        second run changes nothing). A send keeps the fund it used where the currency matches; card purchases on a
--        card in another currency move to that currency's trip fund; converted cash keeps the rate the send used; a
--        purchase that now needs the card's charged amount goes back to "to send". Sends made before sprint 2 are
--        first matched to their purchases by the old send's own rule (that trip's unsent purchases in its currency —
--        another currency for a converted send — made before it). A send no purchase explains is left as it is and
--        counted; the before/after on a restored copy lists it for Aizat.
--
-- Proof at the end: card owed and statements don't move; Available and In the bank move only for funds that hold a
-- trip send; afterwards every send equals its purchases. Counts only, never amounts.
begin;
create temp table _b_money on commit drop as select fund_id, balance, cash_balance from public.fund_money;
create temp table _b_card on commit drop as select payment_method_id, owed, unsettled from public.card_balances;
create temp table _b_stmt on commit drop as select statement_id, reconciled_total, due, paid, status from public.statement_balances;

-- ── 1 · the columns ─────────────────────────────────────────────────────
alter table public.funds add column if not exists pays_trips boolean not null default false;
create unique index if not exists funds_one_trip_fund on public.funds (household_id, currency) where pays_trips and is_active;
alter table public.expenses add column if not exists sent_amount numeric(12,2) check (sent_amount is null or sent_amount >= 0);
alter table public.fund_transactions_all add column if not exists trip_id uuid references public.trips(id);
create index if not exists fund_transactions_trip on public.fund_transactions_all (trip_id) where trip_id is not null;

-- the compat views carry the new columns (appended)
create or replace view public.fund_transactions with (security_invoker = true) as
 SELECT id, household_id, fund_id, type, date, amount, remarks, origin, legacy_sync_id, created_at, income_source,
        account_payment_method_id, transfer_group_id, reconciled_at, reconciled_statement_id, reconciled_by, kind,
        settles_payment_method_id, settles_statement_id, created_by, updated_by, deleted_at, updated_at, trip_id
   FROM fund_transactions_all
  WHERE deleted_at IS NULL;
create or replace view public.travel_expenses with (security_invoker = true) as
  select id, household_id, trip_id, date, description, category, amount, currency, payer_profile_id, paid_with, comments,
         sent_to_fund, legacy_sync_id, created_at, payment_method_id, reconciled_at, reconciled_statement_id, reconciled_by, pot_swap_id, updated_at,
         pot_fund_id, created_by, updated_by, category_id, is_refund, fund_id, settled_amount, settlement_tx_id, sent_amount
    from public.expenses where trip_id is not null and deleted_at is null
  with cascaded check option;

-- a re-link or a re-derived amount is the server keeping copies in step: no Activity line, no "changed" stamp.
-- Found on the way: expenses.kind is a generated column, which a BEFORE trigger sees as null, so every server re-file
-- since sprint 3 stamped purchases as edited (updated_at moved) — the generated column is never an edit.
create or replace function public.bh_derived_only(p_table text, p_old jsonb, p_new jsonb)
returns boolean language sql immutable set search_path = public as $$
  select (p_old - s.k) = (p_new - s.k)
    from (select array['updated_at', 'updated_by', 'created_at'] || case p_table
                   when 'expenses'              then array['kind', 'pot_fund_id', 'category', 'paid_with', 'settlement_tx_id', 'sent_amount']
                   when 'categories'            then array['group_name']
                   when 'category_budgets'      then array['category_group']
                   when 'fund_transactions_all' then array['trip_id']
                   else array[]::text[] end as k) s
$$;
revoke execute on function public.bh_derived_only(text, jsonb, jsonb) from public, anon;
grant execute on function public.bh_derived_only(text, jsonb, jsonb) to authenticated, service_role;

-- ── 2 · a trip fund per currency ────────────────────────────────────────
create or replace function public.bh_trip_fund(p_hh uuid, p_cur text)
returns uuid language sql stable set search_path = public as $$
  select coalesce(
    (select f.id from households h join funds f on f.id = h.travel_fund_id
      where h.id = p_hh and f.currency = p_cur and f.is_active),
    (select f.id from funds f
      where f.household_id = p_hh and f.currency = p_cur and f.pays_trips and f.is_active
      order by f.sort_order, f.id limit 1))
$$;
revoke execute on function public.bh_trip_fund(uuid, text) from public, anon;
grant execute on function public.bh_trip_fund(uuid, text) to authenticated, service_role;

-- Settings: the fund that pays trips in a currency (null = none). The main travel fund follows when it is in that
-- currency (or there is none yet).
create or replace function public.set_trip_fund(p_currency text, p_fund uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_f funds%rowtype; v_main_cur text; v_main uuid;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  p_currency := upper(trim(coalesce(p_currency, '')));
  if p_currency !~ '^[A-Z]{3}$' then raise exception 'pick a currency' using errcode = 'P0001'; end if;
  if p_fund is not null then
    select * into v_f from funds where id = p_fund and household_id = v_hh and is_active;
    if v_f.id is null then raise exception 'fund not found'; end if;
    if v_f.currency <> p_currency then
      raise exception '% is in %, not %', v_f.name, v_f.currency, p_currency using errcode = 'P0001';
    end if;
  end if;
  select h.travel_fund_id, f.currency into v_main, v_main_cur from households h left join funds f on f.id = h.travel_fund_id where h.id = v_hh;
  update funds set pays_trips = false where household_id = v_hh and currency = p_currency and pays_trips and id is distinct from p_fund;
  if p_fund is not null then update funds set pays_trips = true where id = p_fund and not pays_trips; end if;
  if v_main is null or v_main_cur = p_currency then
    update households set travel_fund_id = p_fund where id = v_hh and travel_fund_id is distinct from p_fund;
  end if;
end $$;
revoke execute on function public.set_trip_fund(text, uuid) from public, anon;
grant execute on function public.set_trip_fund(text, uuid) to authenticated, service_role;

-- starting point: the main travel fund; for each other currency, where this household's latest trip send in it went
update public.funds f set pays_trips = true
  from public.households h
 where h.travel_fund_id = f.id and f.is_active and not f.pays_trips;
with latest as (
  select distinct on (a.household_id, f.currency) a.household_id, f.currency, f.id as fund_id
    from public.fund_transactions a join public.funds f on f.id = a.fund_id
   where a.kind = 'allocation' and a.transfer_group_id is null and a.remarks ~ '^Travel: ' and f.is_active
   order by a.household_id, f.currency, a.date desc, a.created_at desc, a.id
)
update public.funds f set pays_trips = true
  from latest l
 where f.id = l.fund_id and not f.pays_trips
   and not exists (select 1 from public.funds g where g.household_id = l.household_id and g.currency = l.currency and g.pays_trips and g.is_active);

-- ── 3 · the rule ────────────────────────────────────────────────────────
-- every live trip purchase that isn't pot-swapped: where the rule sends it (fund_id; null = no trip fund for it),
-- how (card · face · convert) and what it takes from that fund (value; null = waits for the card's charge, or is
-- converted when sending). sign: −1 for a refund.
create or replace function public.bh_trip_lines(p_hh uuid, p_trip uuid)
returns table (expense_id uuid, sent boolean, settlement_tx_id uuid, sign integer, currency text, amount numeric,
               card_id uuid, card_currency text, fund_id uuid, mode text, value numeric)
language sql stable set search_path = public as $$
  select e.id, e.sent_to_fund, e.settlement_tx_id, case when e.is_refund then -1 else 1 end, e.currency, e.amount,
         c.id, c.currency, x.fund_id, x.mode,
         case x.mode when 'card' then case when e.currency = c.currency then e.amount else e.settled_amount end
                     when 'face' then e.amount end
    from expenses e
    left join payment_methods c on c.id = e.payment_method_id and c.kind = 'credit_card' and c.currency is not null
    cross join lateral (
      select case when c.id is not null then bh_trip_fund(p_hh, c.currency)
                  else coalesce(bh_trip_fund(p_hh, e.currency),
                                (select f.id from households h join funds f on f.id = h.travel_fund_id where h.id = p_hh and f.is_active)) end as fund_id,
             case when c.id is not null then 'card'
                  when bh_trip_fund(p_hh, e.currency) is not null then 'face'
                  else 'convert' end as mode
    ) x
   where e.household_id = p_hh and e.trip_id = p_trip and e.deleted_at is null and e.pot_swap_id is null
$$;
revoke execute on function public.bh_trip_lines(uuid, uuid) from public, anon;
grant execute on function public.bh_trip_lines(uuid, uuid) to authenticated, service_role;

-- what a send would do now: every unsent purchase that is ready, with the value it takes. Converted purchases share
-- the typed amount for their currency (p_converted: {"JPY": <amount>}) in proportion; the running total is rounded,
-- so the shares add up to exactly what was typed.
create or replace function public.bh_trip_send_lines(p_hh uuid, p_trip uuid, p_converted jsonb)
returns table (expense_id uuid, fund_id uuid, value numeric, sign integer)
language sql stable set search_path = public as $$
  with l as (select * from bh_trip_lines(p_hh, p_trip) l where not l.sent and l.fund_id is not null)
  select l.expense_id, l.fund_id, l.value, l.sign from l where l.mode in ('card', 'face') and l.value is not null
  union all
  select c.expense_id, c.fund_id,
         c.sign * (round(c.t * c.cum / c.f, 2) - round(c.t * (c.cum - c.sign * c.amount) / c.f, 2)), c.sign
    from (select l.*, case when jsonb_typeof(p_converted -> l.currency) = 'number' then (p_converted ->> l.currency)::numeric end as t,
                 sum(l.sign * l.amount) over (partition by l.currency) as f,
                 sum(l.sign * l.amount) over (partition by l.currency order by l.amount desc, l.expense_id rows unbounded preceding) as cum
            from l where l.mode = 'convert') c
   where c.t > 0 and c.f > 0
$$;
revoke execute on function public.bh_trip_send_lines(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.bh_trip_send_lines(uuid, uuid, jsonb) to service_role;

-- ── 4 · the phone's Send card ───────────────────────────────────────────
create or replace function public.trip_send_plan(p_trip uuid)
returns jsonb language plpgsql stable set search_path = public as $$
declare v_hh uuid;
begin
  v_hh := bh_current_household(false);
  if v_hh is null or not exists (select 1 from trips where id = p_trip and household_id = v_hh) then return null; end if;
  return (
    with l as (select * from bh_trip_lines(v_hh, p_trip) x where not x.sent)
    select jsonb_build_object(
      -- ready now: one row per fund (card purchases at what the card charged, the rest at face value)
      'ready', coalesce((select jsonb_agg(jsonb_build_object('fund_id', g.fund_id, 'fund', f.name, 'currency', f.currency,
                                                             'amount', g.amount, 'n', g.n, 'cards', g.cards) order by f.sort_order, f.name)
                           from (select x.fund_id, sum(x.sign * x.value) as amount, count(*)::int as n, count(*) filter (where x.mode = 'card')::int as cards
                                   from l x where x.mode in ('card', 'face') and x.fund_id is not null and x.value is not null group by x.fund_id) g
                           join funds f on f.id = g.fund_id), '[]'),
      -- spent in a currency with no trip fund: type what it cost in the main travel fund's currency
      'convert', coalesce((select jsonb_agg(jsonb_build_object('currency', c.currency, 'foreign', c.foreign, 'n', c.n,
                                                               'fund_id', c.fund_id, 'fund', f.name, 'fund_currency', f.currency) order by c.currency)
                             from (select x.currency, x.fund_id, sum(x.sign * x.amount) as foreign, count(*)::int as n
                                     from l x where x.mode = 'convert' and x.fund_id is not null group by x.currency, x.fund_id) c
                             join funds f on f.id = c.fund_id), '[]'),
      -- on a card in another currency, waiting for what the card charged (typed on the Desk)
      'waiting', coalesce((select jsonb_agg(jsonb_build_object('card_id', w.card_id, 'card', pm.name, 'card_currency', w.card_currency,
                                                               'currency', w.currency, 'foreign', w.foreign, 'n', w.n) order by pm.name, w.currency)
                             from (select x.card_id, x.card_currency, x.currency, sum(x.sign * x.amount) as foreign, count(*)::int as n
                                     from l x where x.mode = 'card' and x.fund_id is not null and x.value is null group by 1, 2, 3) w
                             join payment_methods pm on pm.id = w.card_id), '[]'),
      -- no trip fund for the currency they need: Settings → Funds
      'no_fund', coalesce((select jsonb_agg(jsonb_build_object('currency', n.cur, 'n', n.n) order by n.cur)
                             from (select coalesce(x.card_currency, x.currency) as cur, count(*)::int as n
                                     from l x where x.fund_id is null group by 1) n), '[]'),
      -- what has gone already, newest first (amount: money out of the fund; negative = money back)
      'sends', coalesce((select jsonb_agg(jsonb_build_object('tx_id', a.id, 'fund_id', a.fund_id, 'fund', f.name, 'currency', f.currency,
                                                             'date', a.date, 'amount', case when a.type = 'income' then -a.amount else a.amount end,
                                                             'n', (select count(*) from expenses e where e.settlement_tx_id = a.id and e.deleted_at is null))
                                          order by a.date desc, a.created_at desc)
                           from fund_transactions a join funds f on f.id = a.fund_id
                          where a.household_id = v_hh and a.trip_id = p_trip and a.kind = 'allocation'), '[]'),
      'settled_without_fund', (select count(*)::int from expenses e
                                where e.household_id = v_hh and e.trip_id = p_trip and e.deleted_at is null
                                  and e.sent_to_fund and e.settlement_tx_id is null and e.pot_swap_id is null),
      'swapped', (select count(*)::int from expenses e where e.household_id = v_hh and e.trip_id = p_trip and e.deleted_at is null and e.pot_swap_id is not null)
    ));
end $$;
revoke execute on function public.trip_send_plan(uuid) from public, anon;
grant execute on function public.trip_send_plan(uuid) to authenticated, service_role;

-- a send's fund row follows its purchases: amount = the sum of what they took (a negative sum is money back).
-- Asserts the fund's Available moved by exactly the change; returns the change.
create or replace function public.bh_send_resum(p_tx uuid)
returns numeric language plpgsql security definer set search_path = public as $$
declare v_t fund_transactions_all%rowtype; v_sum numeric; v_old numeric; v_before numeric; v_after numeric; v_hh_today date;
begin
  select * into v_t from fund_transactions_all where id = p_tx and deleted_at is null;
  if v_t.id is null then return 0; end if;
  select coalesce(sum(case when is_refund then -sent_amount else sent_amount end), 0) into v_sum
    from expenses where settlement_tx_id = p_tx and deleted_at is null;
  v_old := case when v_t.type = 'income' then -v_t.amount else v_t.amount end;
  if abs(v_sum - v_old) < 0.005 then return 0; end if;
  v_hh_today := bh_today(v_t.household_id);
  select balance into v_before from fund_balances where fund_id = v_t.fund_id;
  update fund_transactions_all set amount = abs(v_sum), type = case when v_sum < 0 then 'income' else 'expense' end where id = p_tx;
  select balance into v_after from fund_balances where fund_id = v_t.fund_id;
  if v_t.date <= v_hh_today and abs((v_before - v_after) - (v_sum - v_old)) > 0.005 then
    raise exception 'trip send: the fund moved by the wrong amount — nothing changed';
  end if;
  return v_sum - v_old;
end $$;
revoke execute on function public.bh_send_resum(uuid) from public, anon, authenticated;
grant execute on function public.bh_send_resum(uuid) to service_role;

-- ── 5 · send, undo ──────────────────────────────────────────────────────
create or replace function public.send_trip(p_trip uuid, p_date date, p_converted jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_hh uuid; v_name text; v_out jsonb := '[]'; r record; v_tx uuid; v_before numeric; v_after numeric; v_n int; v_want numeric;
  v_prev text := coalesce(current_setting('bh.via_rpc', true), '');
  v_conv jsonb := case when jsonb_typeof(p_converted) = 'object' then p_converted else '{}'::jsonb end;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  select name into v_name from trips where id = p_trip and household_id = v_hh for update;   -- one send at a time per trip
  if v_name is null then raise exception 'trip not found'; end if;
  if p_date is null then raise exception 'pick a date' using errcode = 'P0001'; end if;
  if exists (select 1 from jsonb_each(v_conv) c where case when jsonb_typeof(c.value) <> 'number' then true else (c.value)::text::numeric <= 0 end) then
    raise exception 'enter what it cost as a positive amount' using errcode = 'P0001';
  end if;
  perform set_config('bh.via_rpc', 'on', true);
  for r in select s.fund_id, sum(s.sign * s.value) as total, count(*)::int as n
             from bh_trip_send_lines(v_hh, p_trip, v_conv) s group by s.fund_id order by s.fund_id loop
    select balance into v_before from fund_balances where fund_id = r.fund_id;
    insert into fund_transactions_all (household_id, fund_id, type, kind, date, amount, remarks, origin, trip_id)
    values (v_hh, r.fund_id, case when r.total < 0 then 'income' else 'expense' end, 'allocation', p_date, abs(r.total),
            'Travel: ' || v_name || case when r.total < 0 then ' · refund' else '' end, 'manual', p_trip)
    returning id into v_tx;
    update expenses e set sent_to_fund = true, settlement_tx_id = v_tx, sent_amount = s.value
      from bh_trip_send_lines(v_hh, p_trip, v_conv) s
     where s.fund_id = r.fund_id and e.id = s.expense_id;
    get diagnostics v_n = row_count;
    if v_n <> r.n then raise exception 'trip send: % purchases moved, expected % — nothing sent', v_n, r.n; end if;
    select balance into v_after from fund_balances where fund_id = r.fund_id;
    v_want := case when p_date <= bh_today(v_hh) then r.total else 0 end;
    if abs((v_before - v_after) - v_want) > 0.005 then raise exception 'trip send: a fund moved by the wrong amount — nothing sent'; end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object('tx_id', v_tx, 'fund_id', r.fund_id, 'amount', r.total, 'n', r.n));
  end loop;
  perform set_config('bh.via_rpc', v_prev, true);
  if jsonb_array_length(v_out) = 0 then raise exception 'nothing on this trip is ready to send' using errcode = 'P0001'; end if;
  return v_out;
end $$;
revoke execute on function public.send_trip(uuid, date, jsonb) from public, anon;
grant execute on function public.send_trip(uuid, date, jsonb) to authenticated, service_role;

-- takes a send back: its purchases are unsent again, its fund row goes (not to the bin: send the trip again instead)
create or replace function public.bh_undo_send(p_tx uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare v_t fund_transactions_all%rowtype; v_before numeric; v_after numeric; v_n int; v_want numeric;
        v_prev text := coalesce(current_setting('bh.via_rpc', true), '');
begin
  select * into v_t from fund_transactions_all where id = p_tx and deleted_at is null for update;
  if v_t.id is null or v_t.trip_id is null or v_t.kind <> 'allocation' then raise exception 'that isn''t a trip send' using errcode = 'P0001'; end if;
  select balance into v_before from fund_balances where fund_id = v_t.fund_id;
  perform set_config('bh.via_rpc', 'on', true);
  update expenses set sent_to_fund = false, settlement_tx_id = null, sent_amount = null where settlement_tx_id = p_tx;
  get diagnostics v_n = row_count;
  update fund_transactions_all set deleted_at = now() where id = p_tx;
  perform set_config('bh.via_rpc', v_prev, true);
  select balance into v_after from fund_balances where fund_id = v_t.fund_id;
  v_want := case when v_t.date > bh_today(v_t.household_id) then 0 when v_t.type = 'income' then -v_t.amount else v_t.amount end;
  if abs((v_after - v_before) - v_want) > 0.005 then raise exception 'undo send: the fund moved by the wrong amount — nothing undone'; end if;
  return v_n;
end $$;
revoke execute on function public.bh_undo_send(uuid) from public, anon, authenticated;
grant execute on function public.bh_undo_send(uuid) to service_role;

create or replace function public.undo_trip_send(p_tx uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare v_hh uuid;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  if not exists (select 1 from fund_transactions_all where id = p_tx and household_id = v_hh and deleted_at is null) then
    raise exception 'that send is already undone — pull down to refresh' using errcode = 'P0001';
  end if;
  return bh_undo_send(p_tx);
end $$;
revoke execute on function public.undo_trip_send(uuid) from public, anon;
grant execute on function public.undo_trip_send(uuid) to authenticated, service_role;

-- the old way in: an app from before this change asks for a reload rather than sending by the old rule
create or replace function public.send_trip_to_fund(p_trip uuid, p_fund uuid, p_date date)
returns numeric language plpgsql security definer set search_path = public as $$
begin
  raise exception 'this copy of the app is out of date — reload it, then send the trip again' using errcode = 'P0001';
end $$;
create or replace function public.send_foreign_to_fund(p_trip uuid, p_fund uuid, p_date date, p_ids uuid[], p_amount numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  raise exception 'this copy of the app is out of date — reload it, then send the trip again' using errcode = 'P0001';
end $$;

-- ── 6 · what the card charged, after the send ───────────────────────────
create or replace function public.set_settled_amount(p_id uuid, p_amount numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_cur text; v_card_cur text; v_closed timestamptz; v_tx uuid; v_fcur text;
        v_prev text := coalesce(current_setting('bh.via_rpc', true), '');
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  select e.currency, pm.currency, s.closed_at, e.settlement_tx_id into v_cur, v_card_cur, v_closed, v_tx
    from expenses e join payment_methods pm on pm.id = e.payment_method_id
    left join statements s on s.id = e.reconciled_statement_id
   where e.id = p_id and e.household_id = v_hh and e.deleted_at is null;
  if not found then raise exception 'purchase not found'; end if;
  if v_card_cur is null or v_cur = v_card_cur then raise exception 'this purchase is already in the card''s currency' using errcode = 'P0001'; end if;
  if p_amount is not null and p_amount < 0 then raise exception 'enter what the card charged — a refund is still a positive amount' using errcode = 'P0001'; end if;
  if v_closed is not null then raise exception 'this purchase is on a closed statement — reopen it first' using errcode = 'P0001'; end if;
  if v_tx is not null then
    select f.currency into v_fcur from fund_transactions_all a join funds f on f.id = a.fund_id where a.id = v_tx;
    if p_amount is null then
      raise exception 'this purchase was sent to a trip fund at what the card charged — undo that send on the trip to clear it' using errcode = 'P0001';
    end if;
  end if;
  perform set_config('bh.via_rpc', 'on', true);
  update expenses set settled_amount = round(p_amount, 2),
                      sent_amount = case when v_tx is not null and v_fcur = v_card_cur then round(p_amount, 2) else sent_amount end
   where id = p_id;
  if v_tx is not null then perform bh_send_resum(v_tx); end if;   -- the send follows what the card charged
  perform set_config('bh.via_rpc', v_prev, true);
end $$;
revoke execute on function public.set_settled_amount(uuid, numeric) from public, anon;
grant execute on function public.set_settled_amount(uuid, numeric) to authenticated, service_role;

-- ── 7 · guards ──────────────────────────────────────────────────────────
-- server-owned, like the other stamps
create or replace function public.bh_expense_client_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if tg_op = 'INSERT' then
    new.reconciled_at := null; new.reconciled_by := null; new.reconciled_statement_id := null;   -- cash re-ticks itself next
    new.deleted_at := null;
    new.pot_fund_id := null;                                                                     -- stamped by the server
    new.settlement_tx_id := null; new.sent_amount := null;                                       -- set by the trip send
    new.settled_amount := null;                                                                  -- set from the statement
    new.created_by := auth.uid();
  else
    new.created_by := old.created_by;
    new.deleted_at := old.deleted_at;
    new.pot_fund_id := old.pot_fund_id;                                                          -- re-stamped when its inputs change
    new.settlement_tx_id := old.settlement_tx_id;
    new.sent_amount := old.sent_amount;
    new.settled_amount := old.settled_amount;
  end if;
  return new;
end $$;

-- a sent purchase stays as it was sent until the send is undone (after expenses_before_write, so a card changed by
-- name is caught too); a pot-swapped trip line's "sent" belongs to the swap
create or replace function public.bh_expense_sent_lock()
returns trigger language plpgsql set search_path = public as $$
declare v_fund text;
begin
  if coalesce(current_setting('bh.via_rpc', true), '') = 'on' then return new; end if;
  if old.settlement_tx_id is not null and (
       new.amount is distinct from old.amount or new.currency is distinct from old.currency
    or new.payment_method_id is distinct from old.payment_method_id or new.is_refund is distinct from old.is_refund
    or new.trip_id is distinct from old.trip_id or new.household_id is distinct from old.household_id
    or new.deleted_at is distinct from old.deleted_at or new.sent_to_fund is distinct from old.sent_to_fund
    or new.settled_amount is distinct from old.settled_amount or new.pot_swap_id is distinct from old.pot_swap_id) then
    select f.name into v_fund from fund_transactions_all a join funds f on f.id = a.fund_id where a.id = old.settlement_tx_id;
    raise exception 'this purchase was sent to % — undo that send on the trip first', coalesce(v_fund, 'a trip fund') using errcode = 'P0001';
  end if;
  if old.pot_swap_id is not null and new.pot_swap_id is not distinct from old.pot_swap_id and new.sent_to_fund is distinct from old.sent_to_fund then
    raise exception 'this purchase is settled by a pot swap — undo the swap first' using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke execute on function public.bh_expense_sent_lock() from public, anon, authenticated;
drop trigger if exists expenses_sent_lock on public.expenses;
create trigger expenses_sent_lock before update on public.expenses for each row execute function public.bh_expense_sent_lock();

-- a send's fund row changes only on its trip (send, undo, what the card charged)
create or replace function public.bh_fund_client_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if tg_op = 'INSERT' then
    if new.origin = 'planned' then
      raise exception 'this copy of the app is out of date — reload it, then apply the plan again' using errcode = 'P0001';
    end if;
    if new.kind is not null and new.kind <> 'movement' then
      raise exception 'that kind of row is recorded by the server' using errcode = 'P0001';
    end if;
    new.reconciled_at := null; new.reconciled_by := null; new.reconciled_statement_id := null;   -- transfers re-tick themselves next
    new.deleted_at := null; new.reviewed_at := null; new.trip_id := null;
    new.created_by := auth.uid();
    return new;
  end if;
  new.created_by := old.created_by;
  new.deleted_at := old.deleted_at;
  new.trip_id := old.trip_id;
  if old.transfer_group_id is not null and (
       new.amount is distinct from old.amount or new.date is distinct from old.date
    or new.fund_id is distinct from old.fund_id or new.type is distinct from old.type
    or new.kind is distinct from old.kind or new.transfer_group_id is distinct from old.transfer_group_id) then
    raise exception 'one side of a transfer can''t be changed on its own — delete both sides and enter it again' using errcode = 'P0001';
  end if;
  if old.transfer_group_id is null and new.transfer_group_id is not null then
    raise exception 'rows are paired by the server, not by an edit' using errcode = 'P0001';
  end if;
  if old.trip_id is not null and (
       new.amount is distinct from old.amount or new.date is distinct from old.date
    or new.fund_id is distinct from old.fund_id or new.type is distinct from old.type or new.kind is distinct from old.kind) then
    raise exception 'a trip send is the sum of its purchases — undo it on the trip and send again' using errcode = 'P0001';
  end if;
  return new;
end $$;

-- the bin: binning a send undoes it; a send never comes back from the bin (send the trip again)
create or replace function public.soft_delete_rows(p_kind text, p_ids uuid[])
returns integer language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_n int := 0; v_closed int; v_tx uuid;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  if p_kind in ('daily', 'travel', 'expense') then
    select count(*) into v_closed from expenses d join statements s on s.id = d.reconciled_statement_id
     where d.household_id = v_hh and d.id = any(p_ids) and s.closed_at is not null;
    if v_closed > 0 then raise exception 'this row is on a closed statement — reopen the statement on the Desk first' using errcode = 'P0001'; end if;
    update expenses set deleted_at = now() where household_id = v_hh and id = any(p_ids) and deleted_at is null;
    get diagnostics v_n = row_count;
  elsif p_kind = 'fund' then
    select count(*) into v_closed from fund_transactions_all d join statements s on s.id = d.reconciled_statement_id
     where d.household_id = v_hh and d.id = any(p_ids) and s.closed_at is not null;
    if v_closed > 0 then raise exception 'this row is on a closed statement — reopen the statement on the Desk first' using errcode = 'P0001'; end if;
    for v_tx in select id from fund_transactions_all
                 where household_id = v_hh and id = any(p_ids) and deleted_at is null and trip_id is not null and kind = 'allocation' loop
      perform bh_undo_send(v_tx); v_n := v_n + 1;
    end loop;
    -- a transfer or a card payment goes as a unit
    update fund_transactions_all set deleted_at = now()
     where household_id = v_hh and deleted_at is null
       and (id = any(p_ids) or transfer_group_id in (select transfer_group_id from fund_transactions_all where household_id = v_hh and id = any(p_ids) and transfer_group_id is not null));
    get diagnostics v_closed = row_count;
    v_n := v_n + v_closed;
  else
    raise exception 'unknown kind %', p_kind;
  end if;
  return v_n;
end $$;
revoke all on function public.soft_delete_rows(text, uuid[]) from public;
grant execute on function public.soft_delete_rows(text, uuid[]) to authenticated, service_role;

create or replace function public.restore_rows(p_kind text, p_ids uuid[])
returns integer language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_n int := 0;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  if p_kind in ('daily', 'travel', 'expense') then
    update expenses set deleted_at = null where household_id = v_hh and id = any(p_ids) and deleted_at is not null;
  elsif p_kind = 'fund' then
    if exists (select 1 from fund_transactions_all where household_id = v_hh and id = any(p_ids) and trip_id is not null and kind = 'allocation') then
      raise exception 'a trip send comes back by sending the trip again' using errcode = 'P0001';
    end if;
    update fund_transactions_all set deleted_at = null
     where household_id = v_hh and deleted_at is not null
       and (id = any(p_ids) or transfer_group_id in (select transfer_group_id from fund_transactions_all where household_id = v_hh and id = any(p_ids) and transfer_group_id is not null));
  else
    raise exception 'unknown kind %', p_kind;
  end if;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function public.restore_rows(text, uuid[]) from public;
grant execute on function public.restore_rows(text, uuid[]) to authenticated, service_role;

-- an undone send isn't in the bin (it can't be restored on its own)
create or replace view public.recently_deleted with (security_invoker = true) as
  select 'expense'::text as kind, e.id, e.household_id, e.deleted_at, e.date, e.description as label, e.amount, e.currency,
         e.category as detail, e.updated_by as deleted_by, (e.is_refund or e.category = 'Payment') as is_credit
    from public.expenses e where e.deleted_at is not null
  union all
  select 'fund', t.id, t.household_id, t.deleted_at, t.date, coalesce(nullif(t.remarks, ''), t.income_source, case when t.type = 'income' then 'money in' else 'money out' end),
         case when t.type = 'income' then t.amount else -t.amount end, f.currency, f.name, t.updated_by, t.type = 'income'
    from public.fund_transactions_all t join public.funds f on f.id = t.fund_id where t.deleted_at is not null and t.trip_id is null;
grant select on public.recently_deleted to authenticated, service_role;

-- ── 8 · the money rule: a send's part owed on cards is what its card purchases took ──
-- (fund_money_asof as in 20261018000000, with sl/st replaced; plain SQL, no SET clause, every name qualified)
create or replace function public.fund_money_asof(p_asof date)
returns table (household_id uuid, fund_id uuid, name text, country text, currency text, is_active boolean, sort_order integer,
               group_name text, is_leftover_target boolean, is_spend_pot boolean, icon text, balance numeric, cleared_balance numeric,
               pending_spend numeric, cash_balance numeric, owed_on_cards numeric)
language sql stable as $$
with fg as (
  select t.fund_id, t.account_payment_method_id as pm_id, t.type, t.kind,
         t.date > coalesce(p_asof, (now() at time zone h.timezone)::date) as later, t.reconciled_at is not null as ticked, sum(t.amount) as amount
    from public.fund_transactions t
    join public.funds f on f.id = t.fund_id
    join public.households h on h.id = f.household_id
   group by 1, 2, 3, 4, 5, 6
), fr as (
  select fg.fund_id,
         sum(case when fg.later or fg.kind = 'card_payment' then 0 when fg.type = 'income' then fg.amount else -fg.amount end) as avail,
         sum(case when fg.later or not fg.ticked or fg.kind = 'card_payment' then 0 when fg.type = 'income' then fg.amount else -fg.amount end) as cleared,
         sum(case when fg.later then 0 when fg.type = 'expense' and fg.kind <> 'card_payment' and pm.kind = 'credit_card' then 0
                  when fg.type = 'income' then fg.amount else -fg.amount end) as cash
    from fg left join public.payment_methods pm on pm.id = fg.pm_id
   group by fg.fund_id
), eg as (
  select de.pot_fund_id as fund_id, de.payment_method_id as pm_id, de.reconciled_at is not null as ticked,
         sum(case when de.is_refund then -de.amount else de.amount end) as amount
    from public.expenses de
    join public.funds f on f.id = de.pot_fund_id and f.household_id = de.household_id and f.currency = de.currency
    join public.households h on h.id = f.household_id
   where de.trip_id is null and de.deleted_at is null and de.category <> 'Payment'
     and de.date <= coalesce(p_asof, (now() at time zone h.timezone)::date)
     and (de.fund_id = f.id or (f.is_spend_pot and h.pot_start is not null and de.date >= h.pot_start))
   group by 1, 2, 3
), ex as (
  select eg.fund_id, sum(eg.amount) as spend,
         sum(eg.amount) filter (where eg.ticked) as spend_cleared,
         sum(eg.amount) filter (where not eg.ticked) as spend_pending,
         sum(eg.amount) filter (where coalesce(pm.kind, 'cash') <> 'credit_card') as spend_cash
    from eg left join public.payment_methods pm on pm.id = eg.pm_id
   group by eg.fund_id
), op as (
  select o.fund_id, sum(o.amount) as amount from public.card_openings o group by o.fund_id
), st as (   -- trip sends: what their purchases on credit cards in the fund's currency took, since the start date
  select a.fund_id, sum(case when e.is_refund then -e.sent_amount else e.sent_amount end) as share
    from public.fund_transactions a
    join public.funds f on f.id = a.fund_id
    join public.households h on h.id = f.household_id
    join public.expenses e on e.settlement_tx_id = a.id and e.deleted_at is null and e.sent_amount is not null
    join public.payment_methods pm on pm.id = e.payment_method_id and pm.kind = 'credit_card' and pm.currency = f.currency
   where a.kind = 'allocation' and a.date <= coalesce(p_asof, (now() at time zone h.timezone)::date)
     and (h.pot_start is null or e.date >= h.pot_start)
   group by a.fund_id
)
select f.household_id, f.id as fund_id, f.name, f.country, f.currency, f.is_active, f.sort_order, f.group_name,
       f.is_leftover_target, f.is_spend_pot, f.icon,
       coalesce(fr.avail, 0) - coalesce(ex.spend, 0) as balance,
       coalesce(fr.cleared, 0) - coalesce(ex.spend_cleared, 0) as cleared_balance,
       coalesce(ex.spend_pending, 0) as pending_spend,
       coalesce(fr.cash, 0) - coalesce(ex.spend_cash, 0) + coalesce(op.amount, 0) + coalesce(st.share, 0) as cash_balance,
       round(coalesce(fr.cash, 0) - coalesce(ex.spend_cash, 0) + coalesce(op.amount, 0) + coalesce(st.share, 0)
             - (coalesce(fr.avail, 0) - coalesce(ex.spend, 0)), 2) as owed_on_cards
  from public.funds f
  left join fr on fr.fund_id = f.id
  left join ex on ex.fund_id = f.id
  left join op on op.fund_id = f.id
  left join st on st.fund_id = f.id
$$;
revoke execute on function public.fund_money_asof(date) from public, anon;
grant execute on function public.fund_money_asof(date) to authenticated, service_role;

-- ── 9 · new households: each country's travel fund pays its trips ───────
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
    insert into funds (household_id, name, country, currency, group_name, sort_order, pays_trips)
    values (v_hh, 'Travel fund' || v_sfx, v_cc, v_cur, 'Savings & buffers', v_sort, true)
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
revoke execute on function public.create_household_setup(text, text, text[], text, text[], text[]) from public, anon;
grant execute on function public.create_household_setup(text, text, text[], text, text[], text[]) to authenticated, service_role;

-- ── 10 · re-derive every send by the rule ───────────────────────────────
create or replace function public.bh_rederive_trip_sends(p_hh uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_prev text := coalesce(current_setting('bh.via_rpc', true), '');
  s record; g record; v_new uuid; v_total numeric; v_rate numeric; v_n int; v_bad int;
  c_sends int := 0; c_matched int := 0; c_changed int := 0; c_removed int := 0; c_new int := 0;
  c_moved int := 0; c_waiting int := 0; c_orphan int := 0; c_unclear int := 0;
begin
  perform set_config('bh.via_rpc', 'on', true);
  if to_regclass('pg_temp._rd') is null then
    create temp table _rd (expense_id uuid, fund_id uuid, value numeric, sign int) on commit drop;
  end if;

  -- a · sends from before trip_id: the trip they name (or the one their purchases are on)
  update fund_transactions_all a set trip_id = coalesce(
           (select e.trip_id from expenses e where e.settlement_tx_id = a.id and e.trip_id is not null limit 1),
           (select t.id from trips t
             where t.household_id = a.household_id
               and t.name = regexp_replace(substr(a.remarks, 9), ' \(converted\)$| · refund$', '')
               and (select count(*) from trips t2 where t2.household_id = t.household_id and t2.name = t.name) = 1))
   where a.household_id = p_hh and a.trip_id is null and a.deleted_at is null and a.kind = 'allocation'
     and a.transfer_group_id is null and a.remarks ~ '^Travel: ';

  -- b · sends from before sprint 2 that were never linked: the purchases the old send took — that trip's unsent
  --     purchases in its currency (another currency for a converted send) made before it — oldest send first
  for s in select a.id, a.trip_id, a.created_at, f.currency, a.remarks ~ ' \(converted\)$' as conv
             from fund_transactions_all a join funds f on f.id = a.fund_id
            where a.household_id = p_hh and a.trip_id is not null and a.deleted_at is null and a.kind = 'allocation'
              and not exists (select 1 from expenses e where e.settlement_tx_id = a.id)
            order by a.created_at, a.id loop
    update expenses e set settlement_tx_id = s.id
     where e.household_id = p_hh and e.trip_id = s.trip_id and e.sent_to_fund and e.settlement_tx_id is null
       and e.pot_swap_id is null and e.deleted_at is null and e.created_at <= s.created_at
       and case when s.conv then e.currency <> s.currency else e.currency = s.currency end;
    get diagnostics v_n = row_count;
    if v_n > 0 then c_matched := c_matched + 1; end if;
  end loop;

  -- c · every send with purchases, by the rule
  for s in select a.*, f.currency as fcur
             from fund_transactions_all a join funds f on f.id = a.fund_id
            where a.household_id = p_hh and a.trip_id is not null and a.deleted_at is null and a.kind = 'allocation'
            order by a.date, a.created_at, a.id loop
    c_sends := c_sends + 1;
    -- a binned purchase isn't part of a send
    update expenses set settlement_tx_id = null, sent_amount = null where settlement_tx_id = s.id and deleted_at is not null;
    if not exists (select 1 from expenses e where e.settlement_tx_id = s.id) then c_orphan := c_orphan + 1; continue; end if;

    -- converted cash in an older send keeps the rate that send used: its amount over its purchases' total
    -- (readable only when all of them share one currency); without it, the send is left for a person
    select case when count(distinct e.currency) = 1 and min(e.currency) <> s.fcur
                     and sum(case when e.is_refund then -e.amount else e.amount end) > 0
                then (case when s.type = 'income' then -s.amount else s.amount end) / sum(case when e.is_refund then -e.amount else e.amount end) end
      into v_rate
      from expenses e where e.settlement_tx_id = s.id;
    if v_rate is null and exists (
         select 1 from expenses e left join payment_methods c on c.id = e.payment_method_id and c.kind = 'credit_card' and c.currency is not null
          where e.settlement_tx_id = s.id and c.id is null and e.currency <> s.fcur and e.sent_amount is null
            and bh_trip_fund(p_hh, e.currency) is null) then
      c_unclear := c_unclear + 1; continue;
    end if;

    truncate _rd;
    insert into _rd (expense_id, fund_id, value, sign)
    with l as (
      select e.id, e.currency, e.amount, e.settled_amount, e.sent_amount, case when e.is_refund then -1 else 1 end as sign, c.currency as ccur
        from expenses e left join payment_methods c on c.id = e.payment_method_id and c.kind = 'credit_card' and c.currency is not null
       where e.settlement_tx_id = s.id
    ), t as (
      select l.*,
             case when l.ccur is not null then case when l.ccur = s.fcur then s.fund_id else bh_trip_fund(p_hh, l.ccur) end
                  when l.currency = s.fcur then s.fund_id
                  else coalesce(bh_trip_fund(p_hh, l.currency), s.fund_id) end as fund_id,
             case when l.ccur is not null then 'card'
                  when l.currency = s.fcur or bh_trip_fund(p_hh, l.currency) is not null then 'face'
                  else 'convert' end as mode
        from l
    ), cv as (   -- converted cash: its stored share, or the old send's rate shared over its purchases (running total rounded)
      select t.id, t.fund_id, t.sign,
             coalesce(t.sent_amount,
                      t.sign * (round(v_rate * sum(t.sign * t.amount) over w, 2) - round(v_rate * (sum(t.sign * t.amount) over w - t.sign * t.amount), 2))) as value
        from t where t.mode = 'convert'
      window w as (order by t.amount desc, t.id rows unbounded preceding)
    )
    select t.id, t.fund_id,
           case t.mode when 'card' then case when t.currency = t.ccur then t.amount else t.settled_amount end else t.amount end, t.sign
      from t where t.mode <> 'convert'
    union all
    select cv.id, cv.fund_id, cv.value, cv.sign from cv;

    -- purchases that now wait (no trip fund for their currency, or the card's charge not typed): back to "to send"
    update expenses e set sent_to_fund = false, settlement_tx_id = null, sent_amount = null
      from _rd r where r.expense_id = e.id and (r.fund_id is null or r.value is null);
    get diagnostics v_n = row_count; c_waiting := c_waiting + v_n;
    -- purchases that stay: what they take
    update expenses e set sent_amount = r.value
      from _rd r where r.expense_id = e.id and r.fund_id = s.fund_id and r.value is not null and e.sent_amount is distinct from r.value;
    -- purchases another fund pays: a send there, same trip and date
    for g in select r.fund_id, sum(r.sign * r.value) as total, count(*)::int as n
               from _rd r where r.fund_id is not null and r.value is not null and r.fund_id <> s.fund_id group by r.fund_id order by r.fund_id loop
      insert into fund_transactions_all (household_id, fund_id, type, kind, date, amount, remarks, origin, trip_id, created_at)
      values (p_hh, g.fund_id, case when g.total < 0 then 'income' else 'expense' end, 'allocation', s.date, abs(g.total),
              'Travel: ' || (select name from trips where id = s.trip_id) || case when g.total < 0 then ' · refund' else '' end,
              'manual', s.trip_id, s.created_at)
      returning id into v_new;
      update expenses e set settlement_tx_id = v_new, sent_amount = r.value
        from _rd r where r.expense_id = e.id and r.fund_id = g.fund_id and r.value is not null;
      c_new := c_new + 1; c_moved := c_moved + g.n;
    end loop;
    -- the send itself: the sum of what stays, or gone when nothing stays
    select sum(r.sign * r.value) into v_total from _rd r where r.fund_id = s.fund_id and r.value is not null;
    if v_total is null then
      update fund_transactions_all set deleted_at = now() where id = s.id;
      c_removed := c_removed + 1;
    elsif abs(v_total - (case when s.type = 'income' then -s.amount else s.amount end)) >= 0.005 then
      update fund_transactions_all set amount = abs(v_total), type = case when v_total < 0 then 'income' else 'expense' end where id = s.id;
      c_changed := c_changed + 1;
    end if;
  end loop;
  perform set_config('bh.via_rpc', v_prev, true);

  -- every send this rule touched equals its purchases
  select count(*) into v_bad from fund_transactions_all a
   where a.household_id = p_hh and a.trip_id is not null and a.deleted_at is null and a.kind = 'allocation'
     and exists (select 1 from expenses e where e.settlement_tx_id = a.id)
     and abs((case when a.type = 'income' then -a.amount else a.amount end)
             - (select coalesce(sum(case when e.is_refund then -e.sent_amount else e.sent_amount end), 0) from expenses e where e.settlement_tx_id = a.id)) >= 0.005
     and not (select bool_or(e.sent_amount is null) from expenses e where e.settlement_tx_id = a.id);
  if v_bad > 0 then raise exception 're-derive: % trip sends don''t equal their purchases', v_bad; end if;

  return jsonb_build_object('sends', c_sends, 'matched_old', c_matched, 'changed', c_changed, 'removed', c_removed,
                            'new_sends', c_new, 'moved', c_moved, 'waiting', c_waiting, 'unexplained', c_orphan, 'unclear', c_unclear);
end $$;
revoke execute on function public.bh_rederive_trip_sends(uuid) from public, anon, authenticated;
grant execute on function public.bh_rederive_trip_sends(uuid) to service_role;

-- ── 11 · the nightly check knows sends ──────────────────────────────────
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
  select 'trip sends that don''t equal their purchases', 'fail',
         (select count(*)::int from fund_transactions a
           where a.trip_id is not null and a.kind = 'allocation'
             and exists (select 1 from expenses e where e.settlement_tx_id = a.id and e.deleted_at is null)
             and not exists (select 1 from expenses e where e.settlement_tx_id = a.id and e.deleted_at is null and e.sent_amount is null)
             and abs((case when a.type = 'income' then -a.amount else a.amount end)
                     - (select coalesce(sum(case when e.is_refund then -e.sent_amount else e.sent_amount end), 0)
                          from expenses e where e.settlement_tx_id = a.id and e.deleted_at is null)) >= 0.005)
  union all
  select 'sent purchases out of step with their send', 'fail',
         (select count(*)::int from expenses e
           where e.settlement_tx_id is not null and e.deleted_at is null
             and (not e.sent_to_fund
                  or not exists (select 1 from fund_transactions a where a.id = e.settlement_tx_id)
                  or e.sent_amount is not null and exists (select 1 from payment_methods c join fund_transactions a on a.id = e.settlement_tx_id join funds f on f.id = a.fund_id
                              where c.id = e.payment_method_id and c.kind = 'credit_card' and c.currency is not null and c.currency <> f.currency)))
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
  select 'trip sends left for a person (no purchase explains them, or an old rate can''t be read)', 'warn',
         (select count(*)::int from fund_transactions a
           where a.trip_id is not null and a.kind = 'allocation'
             and (not exists (select 1 from expenses e where e.settlement_tx_id = a.id and e.deleted_at is null)
                  or exists (select 1 from expenses e where e.settlement_tx_id = a.id and e.deleted_at is null and e.sent_amount is null)))
  union all
  select 'foreign purchases on cards waiting for the charged amount', 'info', (select coalesce(sum(unsettled), 0)::int from card_balances)
$$;
revoke execute on function public.bh_money_check() from public, anon, authenticated;
grant execute on function public.bh_money_check() to service_role;

-- ── re-derive, and the proof ────────────────────────────────────────────
create temp table _rd_sends on commit drop as
  select a.id, a.fund_id from public.fund_transactions_all a
   where a.deleted_at is null and a.kind = 'allocation' and a.transfer_group_id is null and a.remarks ~ '^Travel: ';
do $$
declare h record; v jsonb; t jsonb := '{}'; k text; v_bad int; v_avail int; v_cash int; v_hh int := 0;
begin
  for h in select id from public.households order by id loop
    v := public.bh_rederive_trip_sends(h.id);
    v_hh := v_hh + 1;
    for k in select jsonb_object_keys(v) loop
      t := t || jsonb_build_object(k, coalesce((t ->> k)::int, 0) + (v ->> k)::int);
    end loop;
  end loop;

  -- a second run changes nothing
  for h in select id from public.households order by id loop
    v := public.bh_rederive_trip_sends(h.id);
    if (v ->> 'changed')::int + (v ->> 'removed')::int + (v ->> 'new_sends')::int + (v ->> 'waiting')::int + (v ->> 'matched_old')::int > 0 then
      raise exception 'trips across currencies: a second re-derive still changed something (%)', v;
    end if;
  end loop;

  -- card owed and statements: untouched
  select count(*) into v_bad from _b_card b full join public.card_balances a using (payment_method_id)
   where a.owed is distinct from b.owed or a.unsettled is distinct from b.unsettled;
  if v_bad > 0 then raise exception 'trips across currencies: % cards changed', v_bad; end if;
  select count(*) into v_bad from _b_stmt b full join public.statement_balances a using (statement_id)
   where a.reconciled_total is distinct from b.reconciled_total or a.due is distinct from b.due
      or a.paid is distinct from b.paid or a.status is distinct from b.status;
  if v_bad > 0 then raise exception 'trips across currencies: % statements changed', v_bad; end if;

  -- Available and In the bank: only for funds that hold (or held) a trip send
  select count(*) into v_bad from _b_money b join public.fund_money a using (fund_id)
   where (abs(a.balance - b.balance) > 0.005 or abs(a.cash_balance - b.cash_balance) > 0.005)
     and not exists (select 1 from _rd_sends s where s.fund_id = a.fund_id)
     and not exists (select 1 from public.fund_transactions_all x where x.fund_id = a.fund_id and x.trip_id is not null);
  if v_bad > 0 then raise exception 'trips across currencies: % funds changed without a trip send', v_bad; end if;
  select count(*) into v_avail from _b_money b join public.fund_money a using (fund_id) where abs(a.balance - b.balance) > 0.005;
  select count(*) into v_cash from _b_money b join public.fund_money a using (fund_id) where abs(a.cash_balance - b.cash_balance) > 0.005;

  -- every live send with purchases equals them; every sent purchase is in step
  select count(*) into v_bad from public.bh_money_check() c
   where c.check_name in ('trip sends that don''t equal their purchases', 'sent purchases out of step with their send') and c.bad > 0;
  if v_bad > 0 then raise exception 'trips across currencies: sends and purchases out of step after the re-derive'; end if;

  raise notice 'trips across currencies ok: % households; sends % (older ones matched %), changed %, removed %, new %; purchases moved %, back to "to send" %; sends no purchase explains %, left for a person %; Available changed for % funds, In the bank for % funds; cards and statements unchanged; a second run changes nothing',
    v_hh, t ->> 'sends', t ->> 'matched_old', t ->> 'changed', t ->> 'removed', t ->> 'new_sends', t ->> 'moved', t ->> 'waiting',
    t ->> 'unexplained', t ->> 'unclear', v_avail, v_cash;
end $$;
notify pgrst, 'reload schema';
commit;
