-- Every number right (v2 sprint 2, chunk 2): the household's own "today"; a trip on a credit card leaves the
-- bank once; so does a pot swap on a card; a payment ticked on its card's statement is a credit; a
-- payment dated after today is scheduled, not paid. Invariants 14, 16, 17, 20 (DB-1 §5).

\set ON_ERROR_STOP on
begin;
set local timezone = 'UTC';   -- current_date is the server's UTC date, as on production
insert into public.beta_invites (code, max_uses, used_count) values ('CI-NUM', 10, 0) on conflict do nothing;
insert into auth.users (id, email) values ('dddddddd-0000-4000-8000-000000000001', 'num-owner@test.local');
set local role authenticated;
select set_config('request.jwt.claim.sub', 'dddddddd-0000-4000-8000-000000000001', true);
select public.create_household_setup('CI-NUM', 'Numbers household', array['Ana', 'Ben'], 'Joint', array['AU', 'SG']) as hh \gset
select set_config('ci.hh', :'hh', true);
select public.bh_today(:'hh') as today \gset
select set_config('ci.today', :'today', true);
select id as ana from public.profiles where household_id = :'hh' and display_name = 'Ana' \gset
select id as tf from public.funds where household_id = :'hh' and name = 'Travel fund AU' \gset
select id as floatau from public.funds where household_id = :'hh' and name = 'Float AU' \gset
select id as savau from public.funds where household_id = :'hh' and name = 'Savings AU' \gset
select id as floatsg from public.funds where household_id = :'hh' and name = 'Float SG' \gset
select id as savsg from public.funds where household_id = :'hh' and name = 'Savings SG' \gset
select set_config('ci.tf', :'tf', true);
select set_config('ci.floatau', :'floatau', true);
insert into public.payment_methods (household_id, name, profile_id, kind, currency) values (:'hh', 'Visa — Ana', :'ana', 'credit_card', 'AUD') returning id as visa \gset
insert into public.payment_methods (household_id, name, profile_id, kind, currency) values (:'hh', 'Amex — Ana', :'ana', 'credit_card', 'AUD') returning id as amex \gset
select set_config('ci.visa', :'visa', true);
select set_config('ci.amex', :'amex', true);
insert into public.fund_transactions (household_id, fund_id, type, date, amount, remarks, origin)
values (:'hh', :'tf', 'income', :'today', 1000, 'opening', 'manual'),
       (:'hh', :'floatau', 'income', :'today', 500, 'opening', 'manual'),
       (:'hh', :'savau', 'income', :'today', 500, 'opening', 'manual'),
       (:'hh', :'floatsg', 'income', :'today', 500, 'opening', 'manual');

-- ── a new household lives in its own time zone and month ─────────────────
do $$ begin
  assert public.bh_today(current_setting('ci.hh')::uuid) = (now() at time zone 'Australia/Melbourne')::date, 'today is Melbourne''s by default';
  assert (select pot_start from public.households where id = current_setting('ci.hh')::uuid) = date_trunc('month', now() at time zone 'Australia/Melbourne')::date,
    'a new household starts counting from its own month';
end $$;

-- ── 16 · a trip on a credit card, sent and paid, leaves the bank once ────
insert into public.trips (household_id, name, start_date, end_date, currency, currencies, countries)
values (:'hh', 'Card trip', :'today', :'today', 'AUD', '{AUD}', '{AU}') returning id as trip \gset
insert into public.travel_expenses (household_id, trip_id, date, description, category, amount, currency, payer_profile_id, payment_method_id, paid_with)
values (:'hh', :'trip', :'today', 'hotel', 'Hotel', 100, 'AUD', :'ana', :'visa', 'Visa — Ana'),
       (:'hh', :'trip', :'today', 'taxi', 'Taxi/Grab', 30, 'AUD', :'ana', null, '');
select public.send_trip(:'trip', :'today');
insert into public.statements (household_id, payment_method_id, period_start, period_end)
values (:'hh', :'visa', (:'today'::date) - 30, (:'today'::date) + 30) returning id as stv \gset
select set_config('ci.stv', :'stv', true);
do $$
declare v numeric; c numeric; o numeric; n int;
begin
  select count(*) into n from public.expenses where household_id = current_setting('ci.hh')::uuid and settlement_tx_id is not null and sent_to_fund;
  assert n = 2, 'the send records the two purchases it settled, got ' || n;
  select balance, cash_balance, owed_on_cards into v, c, o from public.fund_cash where fund_id = current_setting('ci.tf')::uuid;
  assert v = 870, 'Available drops by the whole trip, got ' || v;
  assert c = 970, 'In the bank drops by the cash part only, got ' || c;
  assert o = 100, 'the card part is owed on cards, got ' || o;
  select owed into v from public.card_balances where payment_method_id = current_setting('ci.visa')::uuid;
  assert v = 100, 'the Visa owes the hotel, got ' || v;
  -- a client can't move the link
  update public.expenses set settlement_tx_id = null where description = 'hotel' and household_id = current_setting('ci.hh')::uuid;
  select count(*) into n from public.expenses where description = 'hotel' and household_id = current_setting('ci.hh')::uuid and settlement_tx_id is not null;
  assert n = 1, 'a client cleared the settlement link';
  -- paying the Visa from the travel fund: cash leaves now, once
  perform public.record_card_payment(current_setting('ci.visa')::uuid, current_setting('ci.today')::date,
          jsonb_build_array(jsonb_build_object('fund_id', current_setting('ci.tf')::uuid, 'amount', 100)), current_setting('ci.stv')::uuid);
  select balance, cash_balance, owed_on_cards into v, c, o from public.fund_cash where fund_id = current_setting('ci.tf')::uuid;
  assert v = 870 and c = 870 and o = 0, 'after paying: Available 870, In the bank 870, owed 0 — got ' || v || ' / ' || c || ' / ' || o;
  select owed into v from public.card_balances where payment_method_id = current_setting('ci.visa')::uuid;
  assert v = 0, 'the Visa is paid off, got ' || v;
end $$;

-- ── 14 · a payment ticked on its own card's statement is a credit ─────────
select id as hotel from public.expenses where household_id = :'hh' and description = 'hotel' \gset
select id as pay from public.fund_transactions where household_id = :'hh' and kind = 'card_payment' and settles_payment_method_id = :'visa' \gset
select public.reconcile_rows('expense', array[:'hotel']::uuid[], :'stv');
select public.reconcile_rows('fund', array[:'pay']::uuid[], :'stv');
do $$
declare v numeric; s text;
begin
  select reconciled_total, status into v, s from public.statement_balances where statement_id = current_setting('ci.stv')::uuid;
  assert v = 0, 'hotel 100 less the 100 payment ticks to 0, got ' || v;
  assert s = 'paid', 'and the statement is paid, got ' || s;
end $$;

-- ── a trip pot swap on a credit card: owed once, and the cash leaves once ──
insert into public.trips (household_id, name, start_date, end_date, currency, currencies, countries)
values (:'hh', 'Swap trip', :'today', :'today', 'AUD', '{AUD}', '{AU}') returning id as trip2 \gset
insert into public.travel_expenses (household_id, trip_id, date, description, category, amount, currency, payer_profile_id, payment_method_id, paid_with)
values (:'hh', :'trip2', :'today', 'ferry', 'Ferry/Train', 50, 'AUD', :'ana', :'amex', 'Amex — Ana') returning id as ferry \gset
select public.record_pot_swap('travel', :'ferry', 0.9, :'floatsg', :'savsg', :'savau', :'floatau');
do $$
declare v numeric; o numeric;
begin
  select owed into v from public.card_balances where payment_method_id = current_setting('ci.amex')::uuid;
  assert v = 50, 'the Amex owes the ferry once, got ' || v;
  select balance, owed_on_cards into v, o from public.fund_cash where fund_id = current_setting('ci.floatau')::uuid;
  assert v = 500 and o = 50, 'the bank pot got 50 in and paid the ferry on the card: Available 500, owed 50 — got ' || v || ' / ' || o;
end $$;

-- ── 20 · a payment dated after today is scheduled, not paid ─────────────
insert into public.statements (household_id, payment_method_id, period_start, period_end, statement_total)
values (:'hh', :'amex', (:'today'::date) - 30, :'today', 50) returning id as sta \gset
select set_config('ci.sta', :'sta', true);
select public.record_card_payment(:'amex', (:'today'::date) + 5, jsonb_build_array(jsonb_build_object('fund_id', :'floatau', 'amount', 50)), :'sta');
do $$
declare r record; v numeric;
begin
  select * into r from public.statement_balances where statement_id = current_setting('ci.sta')::uuid;
  assert r.status = 'scheduled' and r.paid = 0 and r.scheduled = 50 and r.next_payment = current_setting('ci.today')::date + 5,
    'a future payment is scheduled: got ' || r.status || ' paid ' || r.paid || ' scheduled ' || r.scheduled;
  select owed into v from public.card_balances where payment_method_id = current_setting('ci.amex')::uuid;
  assert v = 50, 'the card still owes until the payment date, got ' || v;
  select cash_balance into v from public.fund_cash where fund_id = current_setting('ci.floatau')::uuid;
  assert v = 550, 'the cash is still in the bank, got ' || v;
end $$;
-- paid today instead: the swap's card debt leaves the bank once
select public.record_card_payment(:'amex', :'today', jsonb_build_array(jsonb_build_object('fund_id', :'floatau', 'amount', 50)), :'sta');
do $$
declare v numeric; c numeric; o numeric; s text;
begin
  select balance, cash_balance, owed_on_cards into v, c, o from public.fund_cash where fund_id = current_setting('ci.floatau')::uuid;
  assert v = 500 and c = 500 and o = 0, 'after paying the Amex: Available 500, In the bank 500, owed 0 — got ' || v || ' / ' || c || ' / ' || o;
  select status into s from public.statement_balances where statement_id = current_setting('ci.sta')::uuid;
  assert s = 'paid', 'the statement is paid, got ' || s;
end $$;

-- ── a ¥ trip: the card part at what the A$ card charged, the cash part converted ──
insert into public.trips (household_id, name, start_date, end_date, currency, currencies, countries)
values (:'hh', 'Yen trip', :'today', :'today', 'JPY', '{JPY}', '{JP}') returning id as trip3 \gset
insert into public.travel_expenses (household_id, trip_id, date, description, category, amount, currency, payer_profile_id, payment_method_id, paid_with)
values (:'hh', :'trip3', :'today', 'ryokan', 'Hotel', 6000, 'JPY', :'ana', :'visa', 'Visa — Ana'),
       (:'hh', :'trip3', :'today', 'noodles', 'Street Food', 4000, 'JPY', :'ana', null, '');
select public.set_settled_amount((select id from public.expenses where trip_id = :'trip3' and description = 'ryokan'), 60);
select public.send_trip(:'trip3', :'today', '{"JPY": 40}');
do $$
declare v numeric; c numeric;
begin
  select balance, cash_balance into v, c from public.fund_cash where fund_id = current_setting('ci.tf')::uuid;
  assert v = 770, 'Available drops by the converted 100, got ' || v;
  assert c = 830, 'In the bank drops by the cash 40 only (60 of it went on the card), got ' || c;
end $$;

-- ── 17 · "today" is the household's, whatever the server's clock says ─────
reset role;
do $$ declare ok boolean := false; begin
  begin update public.households set timezone = 'Mars/Olympus' where id = current_setting('ci.hh')::uuid; exception when invalid_parameter_value then ok := true; end;
  assert ok, 'a made-up time zone was saved';
end $$;
-- a zone whose date differs from UTC's right now: 14 h ahead after noon UTC, 12 h behind before
select case when extract(hour from now() at time zone 'UTC') >= 12 then 'Pacific/Kiritimati' else 'Etc/GMT+12' end as tz \gset
update public.households set timezone = :'tz', pot_start = current_date - 40 where id = :'hh';
set local role authenticated;
select public.bh_today(:'hh') as hhtoday \gset
select balance as b0 from public.fund_balances where fund_id = :'floatau' \gset
insert into public.daily_expenses (household_id, date, description, category, amount, currency, payer_profile_id, paid_with)
values (:'hh', :'hhtoday', 'local today', 'Groceries', 7, 'AUD', :'ana', ''),
       (:'hh', (:'hhtoday'::date) + 1, 'local tomorrow', 'Groceries', 11, 'AUD', :'ana', '');
select set_config('ci.b0', :'b0', true);
select set_config('ci.hhtoday', :'hhtoday', true);
do $$
declare v numeric; k int;
begin
  assert current_setting('ci.hhtoday')::date <> current_date, 'the test zone must disagree with UTC';
  select balance into v from public.fund_balances where fund_id = current_setting('ci.floatau')::uuid;
  assert v = current_setting('ci.b0')::numeric - 7, 'a purchase dated the household''s today counts, tomorrow''s doesn''t — got ' || v;
  select p.n into k from public.pot_month_spend(current_setting('ci.floatau')::uuid) p where p.month = date_trunc('month', current_setting('ci.hhtoday')::date);
  assert k >= 1, 'the month view counts it too';
end $$;

rollback;
\echo every number right
