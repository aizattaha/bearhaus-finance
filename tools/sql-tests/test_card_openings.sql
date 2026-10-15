-- Card opening positions (v2 sprint 1): a card that owed money when the app started counting it can be
-- paid without pushing the card or the paying pot below zero, and Available never moves.

\set ON_ERROR_STOP on
begin;
insert into public.beta_invites (code, max_uses, used_count) values ('CI-OPEN', 10, 0) on conflict do nothing;
insert into auth.users (id, email) values ('eeeeeeee-0000-4000-8000-000000000001', 'open-owner@test.local'),
                                          ('eeeeeeee-0000-4000-8000-000000000002', 'open-outsider@test.local');
set local role authenticated;
select set_config('request.jwt.claim.sub', 'eeeeeeee-0000-4000-8000-000000000001', true);
select public.create_household_setup('CI-OPEN', 'Opening household', array['Lee'], null, array['AU', 'SG']) as hh \gset
select set_config('ci.hh', :'hh', true);
select pot_start from public.households where id = :'hh' \gset
select set_config('ci.start', :'pot_start', true);
select id as pot from public.funds where household_id = :'hh' and currency = 'AUD' and is_spend_pot \gset
select id as potsg from public.funds where household_id = :'hh' and currency = 'SGD' and is_spend_pot \gset
select set_config('ci.pot', :'pot', true);
select set_config('ci.potsg', :'potsg', true);
insert into public.payment_methods (household_id, name, kind, currency) values (:'hh', 'Amex — Lee', 'credit_card', 'AUD') returning id as amex \gset
select set_config('ci.amex', :'amex', true);
select id as cash from public.payment_methods where household_id = :'hh' and kind = 'cash' \gset
select set_config('ci.cash', :'cash', true);
-- money in the pot, and a purchase from BEFORE the app counted the card (it is on the first statement)
insert into public.fund_transactions (household_id, fund_id, type, date, amount, remarks, origin)
values (:'hh', :'pot', 'income', (:'pot_start'::date), 1000, 'opening', 'manual');
insert into public.daily_expenses (household_id, date, description, category, amount, currency, paid_with, payment_method_id)
values (:'hh', (:'pot_start'::date) - 3, 'before the app counted cards', 'Groceries', 80, 'AUD', 'Amex — Lee', :'amex');

do $$
declare v numeric; a0 numeric; ok boolean := false;
begin
  select balance into a0 from public.fund_balances where fund_id = current_setting('ci.pot')::uuid;
  perform set_config('ci.a0', a0::text, true);
  select owed into v from public.card_balances where payment_method_id = current_setting('ci.amex')::uuid;
  assert v = 0, 'the pre-app purchase is not counted on the card, got ' || v;
  -- the card owed 80 on pot_start, backed by the AUD pot
  insert into public.card_openings (payment_method_id, household_id, fund_id, amount)
  values (current_setting('ci.amex')::uuid, current_setting('ci.hh')::uuid, current_setting('ci.pot')::uuid, 80);
  select owed, opening into v, a0 from public.card_balances where payment_method_id = current_setting('ci.amex')::uuid;
  assert v = 80 and a0 = 80, 'the card owes its opening, got ' || v;
  select owed_on_cards into v from public.fund_cash where fund_id = current_setting('ci.pot')::uuid;
  assert v = 80, 'the pot shows the opening as owed on cards, got ' || v;
  select balance into v from public.fund_balances where fund_id = current_setting('ci.pot')::uuid;
  assert v = current_setting('ci.a0')::numeric, 'Available does not move for an opening';
  -- an SGD fund can't back an AUD card; a cash card has no opening
  begin
    update public.card_openings set fund_id = current_setting('ci.potsg')::uuid where payment_method_id = current_setting('ci.amex')::uuid;
  exception when others then ok := true; end;
  assert ok, 'an SGD fund backed an AUD card';
  ok := false;
  begin
    insert into public.card_openings (payment_method_id, household_id, fund_id, amount)
    values (current_setting('ci.cash')::uuid, current_setting('ci.hh')::uuid, current_setting('ci.pot')::uuid, 5);
  exception when others then ok := true; end;
  assert ok, 'a cash card got an opening';
end $$;

-- paying the first statement in full brings everything back to zero, never below
select public.record_card_payment(:'amex', current_date, jsonb_build_array(jsonb_build_object('fund_id', :'pot', 'amount', 80)));
do $$
declare v numeric;
begin
  select owed into v from public.card_balances where payment_method_id = current_setting('ci.amex')::uuid;
  assert v = 0, 'card owed after paying the opening, got ' || v;
  select owed_on_cards into v from public.fund_cash where fund_id = current_setting('ci.pot')::uuid;
  assert v = 0, 'pot owed on cards after paying the opening, got ' || v;
  select balance into v from public.fund_balances where fund_id = current_setting('ci.pot')::uuid;
  assert v = current_setting('ci.a0')::numeric, 'Available unchanged by the payment, got ' || v;
end $$;

-- a payment dated before pot_start is outside the app's era, like the purchases
select public.record_card_payment(:'amex', (:'pot_start'::date) - 1, jsonb_build_array(jsonb_build_object('fund_id', :'pot', 'amount', 15)));
do $$
declare v numeric;
begin
  select owed into v from public.card_balances where payment_method_id = current_setting('ci.amex')::uuid;
  assert v = 0, 'a pre-era payment changed the card, got ' || v;
end $$;

-- an outsider can neither see nor write openings
select set_config('request.jwt.claim.sub', 'eeeeeeee-0000-4000-8000-000000000002', true);
do $$
declare n int; ok boolean := false;
begin
  select count(*) into n from public.card_openings; assert n = 0, 'an outsider reads openings';
  begin
    insert into public.card_openings (payment_method_id, household_id, fund_id, amount)
    values (current_setting('ci.amex')::uuid, current_setting('ci.hh')::uuid, current_setting('ci.pot')::uuid, 1);
  exception when others then ok := true; end;
  assert ok, 'an outsider wrote an opening';
end $$;

rollback;
\echo card openings hold
