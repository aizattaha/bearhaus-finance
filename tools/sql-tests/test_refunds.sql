-- Refunds against the purchase (17 Oct 2026, DECISIONS E35):
--   A · part of a card purchase comes back on the card: the purchase keeps its full amount, the card owes less,
--       budget and the pot count only what was used, the statement ticks both lines
--   B · a purchase refunded as a bank transfer while the card still owes it: the pot's bank money goes up, the card
--       still owes the full charge until it is paid; then nothing is owed
--   C · a refund counts in its purchase's month, category and pot, not the month it came back
--   D · the guards: never more than the purchase, nothing that would leave a refund on its own; a refund follows its
--       purchase; deleting a refund undoes it; the purchase gets no Activity line for its refunded total
--   E · a refund on a trip purchase already sent goes back to the travel fund on the next send
--   F · the nightly check finds nothing out of step

\set ON_ERROR_STOP on
begin;
insert into public.beta_invites (code, max_uses, used_count) values ('CI-REF', 10, 0) on conflict do nothing;
insert into auth.users (id, email) values ('cdcdcdcd-0000-4000-8000-000000000001', 'refund-owner@test.local');
set local role authenticated;
select set_config('request.jwt.claim.sub', 'cdcdcdcd-0000-4000-8000-000000000001', true) \gset x_
select public.create_household_setup('CI-REF', 'Refund house', array['Ana', 'Ben'], 'Joint', array['AU']) as hh \gset
select set_config('ci.hh', :'hh', true) \gset x_
select public.bh_today(:'hh') as today \gset
select date_trunc('month', :'today'::date)::date as month \gset
select (date_trunc('month', :'today'::date) - interval '1 month')::date as lastmonth \gset
select set_config('ci.today', :'today', true) \gset x_
select set_config('ci.month', :'month', true) \gset x_
select set_config('ci.lastmonth', :'lastmonth', true) \gset x_
reset role;
update public.households set pot_start = :'lastmonth' where id = :'hh';
set local role authenticated;
select id as ana from public.profiles where household_id = :'hh' and display_name = 'Ana' \gset
select id as pot from public.funds where household_id = :'hh' and is_spend_pot \gset
select id as tf from public.funds where household_id = :'hh' and name = 'Travel fund' \gset
select set_config('ci.pot', :'pot', true) \gset x_
select set_config('ci.tf', :'tf', true) \gset x_
insert into public.payment_methods (household_id, name, profile_id, kind, currency) values (:'hh', 'Visa — Ana', :'ana', 'credit_card', 'AUD') returning id as visa \gset
select set_config('ci.visa', :'visa', true) \gset x_
select id as cash from public.payment_methods where household_id = :'hh' and kind = 'cash' \gset
select id as dining from public.categories where household_id = :'hh' and kind = 'daily' and name = 'Dining out' \gset
select id as groc from public.categories where household_id = :'hh' and kind = 'daily' and name = 'Groceries' \gset
select set_config('ci.dining', :'dining', true) \gset x_
select set_config('ci.groc', :'groc', true) \gset x_
insert into public.fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin)
values (:'hh', :'pot', 'income', 'movement', :'lastmonth', 1000, 'opening', 'manual'),
       (:'hh', :'tf', 'income', 'movement', :'lastmonth', 500, 'opening', 'manual');

-- ── A · part of a card purchase back on the card ────────────────────────
insert into public.daily_expenses (household_id, date, description, category_id, amount, currency, payer_profile_id, payment_method_id)
values (:'hh', :'today', 'group dinner', :'dining', 200, 'AUD', :'ana', :'visa') returning id as dinner \gset
select set_config('ci.dinner', :'dinner', true) \gset x_
select count(*) as audit0 from public.audit_log where row_id = :'dinner' \gset
select set_config('ci.audit0', :'audit0', true) \gset x_
select public.refund_purchases(jsonb_build_array(jsonb_build_object('id', :'dinner', 'amount', 40)), :'today', 'card', 'two couldn''t come') as r1 \gset
do $$
declare v numeric; r record; b jsonb;
begin
  select * into r from public.expenses where refund_of = current_setting('ci.dinner')::uuid;
  assert r.is_refund and r.amount = 40 and r.payment_method_id = current_setting('ci.visa')::uuid, 'the refund is a 40 credit on the Visa';
  assert r.category_id = current_setting('ci.dining')::uuid and r.pot_fund_id = current_setting('ci.pot')::uuid, 'it counts where the dinner counts';
  assert (select amount from public.expenses where id = current_setting('ci.dinner')::uuid) = 200, 'the dinner keeps its full 200 (the statement shows 200)';
  assert (select refunded from public.expenses where id = current_setting('ci.dinner')::uuid) = 40, 'the dinner shows 40 refunded';
  select owed into v from public.card_balances where payment_method_id = current_setting('ci.visa')::uuid;
  assert v = 160, 'the Visa owes 200 − 40, got ' || v;
  select balance into v from public.fund_balances where fund_id = current_setting('ci.pot')::uuid;
  assert v = 840, 'the pot counts only what was used (1000 − 160), got ' || v;
  b := public.budget_summary(current_setting('ci.month')::date, 'AUD', 1);
  select sum((x->>'amount')::numeric) into v from jsonb_array_elements(b->'spend') x where x->>'month' = current_setting('ci.month');
  assert v = 160, 'the month''s budget spent 160, got ' || v;
  assert (select count(*) from public.audit_log where row_id = current_setting('ci.dinner')::uuid) = current_setting('ci.audit0')::int,
    'the refunded total wrote an Activity line on the dinner';
end $$;
-- the card statement: both lines tick, 200 − 40
insert into public.statements (household_id, payment_method_id, period_start, period_end)
values (:'hh', :'visa', (:'today'::date) - 30, (:'today'::date) + 30) returning id as stv \gset
select set_config('ci.stv', :'stv', true) \gset x_
select public.reconcile_rows('daily', array(select id from public.expenses where household_id = :'hh' and payment_method_id = :'visa'), :'stv') \gset x_
do $$ begin
  assert (select reconciled_total from public.statement_balances where statement_id = current_setting('ci.stv')::uuid) = 160, 'the statement ticks to 160';
end $$;

-- ── B · refunded as a bank transfer, the card still owes the charge ─────
insert into public.daily_expenses (household_id, date, description, category_id, amount, currency, payer_profile_id, payment_method_id)
values (:'hh', :'today', 'concert tickets', :'dining', 100, 'AUD', :'ana', :'visa') returning id as tix \gset
select set_config('ci.tix', :'tix', true) \gset x_
select public.refund_purchases(jsonb_build_array(jsonb_build_object('id', :'tix')), :'today', 'cash') \gset x_
do $$
declare v numeric; c numeric; o numeric; r record;
begin
  select * into r from public.expenses where refund_of = current_setting('ci.tix')::uuid;
  assert r.amount = 100 and r.payer_profile_id is null and (select kind from public.payment_methods where id = r.payment_method_id) = 'cash',
    'all of it came back as cash into the household''s fund';
  assert (select refunded from public.expenses where id = current_setting('ci.tix')::uuid) = 100, 'fully refunded';
  select owed into v from public.card_balances where payment_method_id = current_setting('ci.visa')::uuid;
  assert v = 260, 'the Visa still owes the tickets (160 + 100), got ' || v;
  select balance, cash_balance, owed_on_cards into v, c, o from public.fund_cash where fund_id = current_setting('ci.pot')::uuid;
  assert v = 840 and c = 1100 and o = 260, 'pot: Available 840, in the bank 1100 (the transfer arrived), owed 260 — got ' || v || ' / ' || c || ' / ' || o;
  -- paying the card in full leaves nothing owed
  perform public.record_card_payment(current_setting('ci.visa')::uuid, current_setting('ci.today')::date,
          jsonb_build_array(jsonb_build_object('fund_id', current_setting('ci.pot')::uuid, 'amount', 260)), null);
  select balance, cash_balance, owed_on_cards into v, c, o from public.fund_cash where fund_id = current_setting('ci.pot')::uuid;
  assert v = 840 and c = 840 and o = 0, 'after paying the Visa: 840 / 840 / 0 — got ' || v || ' / ' || c || ' / ' || o;
end $$;

-- ── C · a refund counts in its purchase's month ─────────────────────────
insert into public.daily_expenses (household_id, date, description, category_id, amount, currency, payer_profile_id, payment_method_id)
values (:'hh', (:'lastmonth'::date) + 3, 'faulty kettle', :'groc', 50, 'AUD', :'ana', :'cash') returning id as kettle \gset
select set_config('ci.kettle', :'kettle', true) \gset x_
select public.budget_summary(:'lastmonth', 'AUD', 2) as b0 \gset
select public.home_summary() as h0 \gset
select set_config('ci.b0', :'b0', true) \gset x_
select set_config('ci.h0', :'h0', true) \gset x_
select public.refund_purchases(jsonb_build_array(jsonb_build_object('id', :'kettle')), :'today', 'cash') \gset x_
do $$
declare b0 jsonb := current_setting('ci.b0')::jsonb; b1 jsonb; h0 jsonb := current_setting('ci.h0')::jsonb; h1 jsonb; v0 numeric; v1 numeric;
begin
  assert (select counts_on from public.expenses where refund_of = current_setting('ci.kettle')::uuid) = current_setting('ci.lastmonth')::date + 3,
    'the kettle''s refund counts on the kettle''s day';
  b1 := public.budget_summary(current_setting('ci.lastmonth')::date, 'AUD', 2);
  select coalesce(sum((x->>'amount')::numeric), 0) into v0 from jsonb_array_elements(b0->'spend') x where x->>'month' = current_setting('ci.lastmonth');
  select coalesce(sum((x->>'amount')::numeric), 0) into v1 from jsonb_array_elements(b1->'spend') x where x->>'month' = current_setting('ci.lastmonth');
  assert v0 - v1 = 50, 'last month''s spending drops by the kettle, got ' || (v0 - v1);
  h1 := public.home_summary();
  assert (h1->'month_groups') = (h0->'month_groups') and (h1->'week') = (h0->'week'), 'this month and this week don''t move';
end $$;

-- ── D · guards ──────────────────────────────────────────────────────────
-- untick the dinner and its refund first, so the statement lock isn't what refuses below
select public.unreconcile_rows('daily', array(select id from public.expenses where id = :'dinner' or refund_of = :'dinner')) \gset x_
do $$
declare ok boolean; v numeric; rid uuid;
begin
  ok := false;
  begin perform public.refund_purchases(jsonb_build_array(jsonb_build_object('id', current_setting('ci.dinner')::uuid, 'amount', 170)), current_setting('ci.today')::date, 'card');
  exception when raise_exception then ok := sqlerrm like '%only 160.00%'; end;
  assert ok, 'more than what is left could be refunded';
  ok := false;
  begin perform public.refund_purchases(jsonb_build_array(jsonb_build_object('id', current_setting('ci.tix')::uuid)), current_setting('ci.today')::date, 'card');
  exception when raise_exception then ok := true; end;
  assert ok, 'a fully refunded purchase was refunded again';
  ok := false;
  begin perform public.refund_purchases(jsonb_build_array(jsonb_build_object('id', current_setting('ci.dinner')::uuid, 'amount', 1)), current_setting('ci.today')::date - 400, 'card');
  exception when raise_exception then ok := true; end;
  assert ok, 'a refund came back before the purchase';
  ok := false;
  begin perform public.refund_purchases(jsonb_build_array(jsonb_build_object('id', current_setting('ci.kettle')::uuid, 'amount', 1)), current_setting('ci.today')::date, 'cash');
  exception when raise_exception then ok := true; end;
  assert ok, 'the kettle''s refund was refunded again';
  -- the refund row itself: not more than the purchase, and it stays a refund
  select id into rid from public.expenses where refund_of = current_setting('ci.dinner')::uuid;
  ok := false;
  begin update public.daily_expenses set amount = 250 where id = rid; exception when raise_exception then ok := true; end;
  assert ok, 'a refund was raised past its purchase';
  update public.daily_expenses set amount = 50 where id = rid;                                             -- within: fine
  assert (select refunded from public.expenses where id = current_setting('ci.dinner')::uuid) = 50, 'the refunded total follows';
  ok := false;
  begin update public.daily_expenses set is_refund = false where id = rid; exception when raise_exception then ok := true; end;
  assert ok, 'a linked refund became a purchase';
  -- the purchase: not below its refunds, not to the bin before them
  ok := false;
  begin update public.daily_expenses set amount = 30 where id = current_setting('ci.dinner')::uuid; exception when raise_exception then ok := true; end;
  assert ok, 'the dinner went below its refunds';
  ok := false;
  begin perform public.soft_delete_rows('daily', array[current_setting('ci.dinner')::uuid]); exception when raise_exception then ok := true; end;
  assert ok, 'the dinner went to the bin before its refund';
  -- a client can't link a refund itself
  insert into public.daily_expenses (household_id, date, description, category_id, amount, currency, is_refund, refund_of)
  values (current_setting('ci.hh')::uuid, current_setting('ci.today')::date, 'sneaky', current_setting('ci.dining')::uuid, 5, 'AUD', true, current_setting('ci.dinner')::uuid)
  returning id into rid;
  assert (select refund_of from public.expenses where id = rid) is null, 'a client linked a refund';
  delete from public.daily_expenses where id = rid;
end $$;
-- the refund follows its purchase: a new category moves it too
update public.daily_expenses set category_id = :'groc' where id = :'dinner';
do $$ begin
  assert (select category_id from public.expenses where refund_of = current_setting('ci.dinner')::uuid) = current_setting('ci.groc')::uuid, 'the refund follows the new category';
end $$;
-- deleting the refund undoes it; restoring brings it back
select id as rdin from public.expenses where refund_of = :'dinner' \gset
select public.soft_delete_rows('daily', array[:'rdin']::uuid[]) \gset x_
do $$ declare v numeric; begin
  assert (select refunded from public.expenses where id = current_setting('ci.dinner')::uuid) = 0, 'deleting the refund undoes it';
  select balance into v from public.fund_balances where fund_id = current_setting('ci.pot')::uuid;
  assert v = 800, 'the pot pays the whole dinner again (1000 − 200), got ' || v;
end $$;
select public.restore_rows('daily', array[:'rdin']::uuid[]) \gset x_
do $$ begin
  assert (select refunded from public.expenses where id = current_setting('ci.dinner')::uuid) = 50, 'restoring brings it back';
end $$;

-- ── E · a refund on a trip purchase already sent ────────────────────────
insert into public.trips (household_id, name, start_date, end_date, currency, currencies, countries)
values (:'hh', 'Hobart', :'today', :'today', 'AUD', '{AUD}', '{AU}') returning id as trip \gset
insert into public.travel_expenses (household_id, trip_id, date, description, category, amount, currency, payer_profile_id, payment_method_id)
values (:'hh', :'trip', :'today', 'hotel', 'Hotel', 300, 'AUD', :'ana', :'visa') returning id as hotel \gset
select public.send_trip(:'trip', :'today') \gset x_
select public.refund_purchases(jsonb_build_array(jsonb_build_object('id', :'hotel', 'amount', 30)), :'today', 'card') \gset x_
select public.send_trip(:'trip', :'today') \gset x_
do $$ declare v numeric; o numeric; begin
  select balance, owed_on_cards into v, o from public.fund_cash where fund_id = current_setting('ci.tf')::uuid;
  assert v = 230, 'the travel fund paid only what was used (500 − 270), got ' || v;
  assert o = 270, 'and owes 270 on the Visa, got ' || o;
end $$;

-- ── F · nothing out of step ─────────────────────────────────────────────
reset role;
do $$
declare v text;
begin
  select string_agg(check_name || ' ' || bad, ', ') into v from public.bh_money_check()
   where severity = 'fail' and bad > 0 and check_name <> 'integrity issues noted in the last day';
  assert v is null, 'the nightly check fails: ' || v;
end $$;

rollback;
\echo refunds against the purchase
