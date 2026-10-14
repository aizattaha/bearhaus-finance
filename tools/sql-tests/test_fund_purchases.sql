-- Purchases that name a fund (ledger plan, phase 1): the move is id-preserving and balance-neutral,
-- the fund gets the three numbers, the budget rule is enforceable, and the way back works.
\set ON_ERROR_STOP on
begin;
insert into public.beta_invites (code, max_uses, used_count) values ('CI-FP', 50, 0) on conflict do nothing;
insert into auth.users (id, email) values ('cccccccc-0000-4000-8000-000000000001', 'fp-owner@test.local');
set local role authenticated;
select set_config('request.jwt.claim.sub', 'cccccccc-0000-4000-8000-000000000001', true);
select public.create_household_setup('CI-FP', 'FP household', array['Ana'], null, array['AU']) as hh \gset
select set_config('ci.hh', :'hh', true);
insert into public.payment_methods (household_id, name, kind, currency) values (:'hh', 'Visa', 'credit_card', 'AUD') returning id as visa \gset
select set_config('ci.visa', :'visa', true);
insert into public.funds (household_id, name, country, currency) values (:'hh', 'Car Fund', 'AU', 'AUD') returning id as car \gset
select set_config('ci.car', :'car', true);
insert into public.funds (household_id, name, country, currency) values (:'hh', 'SG Savings', 'SG', 'SGD') returning id as sgfund \gset
select set_config('ci.sgfund', :'sgfund', true);
-- money in, then a "fund spend" the old way (a movement out)
insert into public.fund_transactions (household_id, fund_id, type, date, amount, remarks, origin) values (:'hh', :'car', 'income', current_date - 10, 1000, 'opening', 'manual');
insert into public.fund_transactions (household_id, fund_id, type, date, amount, remarks, origin) values (:'hh', :'car', 'expense', current_date - 5, 120.00, 'Car parts', 'manual') returning id as sc \gset
select set_config('ci.sc', :'sc', true);

do $$
declare v numeric; n int; s text;
begin
  select balance into v from public.fund_balances where fund_id = current_setting('ci.car')::uuid;
  assert v = 880.00, 'before: Car Fund 880.00, got ' || v;
  select count(*), max(suggestion) into n, s from public.fund_spend_sort where id = current_setting('ci.sc')::uuid;
  assert n = 1 and s = 'purchase', 'the movement is offered for sorting as a purchase';
  perform public.move_fund_spend_to_expenses(array[current_setting('ci.sc')::uuid], 'Car', current_setting('ci.visa')::uuid);
  select balance into v from public.fund_balances where fund_id = current_setting('ci.car')::uuid;
  assert v = 880.00, 'after the move: balance unchanged, got ' || v;
  select owed_on_cards into v from public.fund_cash where fund_id = current_setting('ci.car')::uuid;
  assert v = 120.00, 'the Car Fund now shows 120.00 owed on cards, got ' || v;
  select count(*) into n from public.expenses where id = current_setting('ci.sc')::uuid and fund_id = current_setting('ci.car')::uuid and pot_fund_id = current_setting('ci.car')::uuid and payment_method_id = current_setting('ci.visa')::uuid and category = 'Car';
  assert n = 1, 'same id, now a purchase on the Visa against the Car Fund';
  select count(*) into n from public.fund_transactions where id = current_setting('ci.sc')::uuid;
  assert n = 0, 'the movement row is gone';
  select count(*) into n from public.fund_spend_sort where id = current_setting('ci.sc')::uuid;
  assert n = 0, 'and it left the sort list';
  -- the pot (Float) is untouched by a fund purchase
  select balance into v from public.fund_balances b where b.household_id = current_setting('ci.hh')::uuid and b.is_spend_pot;
  assert v = 0, 'the spending pot never saw the car purchase, got ' || v;
  -- paying the Visa from the Car Fund: Available unchanged, owed 0
  perform public.record_card_payment(current_setting('ci.visa')::uuid, current_date, jsonb_build_array(jsonb_build_object('fund_id', current_setting('ci.car')::uuid, 'amount', 120.00)));
  select balance into v from public.fund_balances where fund_id = current_setting('ci.car')::uuid;
  assert v = 880.00, 'Available unchanged by the card payment, got ' || v;
  select owed_on_cards into v from public.fund_cash where fund_id = current_setting('ci.car')::uuid;
  assert v = 0, 'nothing owed after paying, got ' || v;
end $$;

-- a purchase in another currency cannot name this fund
do $$
declare ok boolean := false;
begin
  begin
    insert into public.daily_expenses (household_id, date, description, category, amount, currency, paid_with, fund_id)
    values (current_setting('ci.hh')::uuid, current_date, 'wrong money', 'Car', 5, 'SGD', '', current_setting('ci.car')::uuid);
  exception when others then ok := true; end;
  assert ok, 'currency mismatch refused';
end $$;

-- the way back
do $$
declare v numeric; n int;
begin
  delete from public.fund_transactions where kind = 'card_payment' and household_id = current_setting('ci.hh')::uuid;
  perform public.move_expense_to_fund_spend(array[current_setting('ci.sc')::uuid]);
  select count(*) into n from public.fund_transactions where id = current_setting('ci.sc')::uuid and remarks = 'Car parts' and account_payment_method_id = current_setting('ci.visa')::uuid;
  assert n = 1, 'back as a movement charged to the Visa';
  select balance into v from public.fund_balances where fund_id = current_setting('ci.car')::uuid;
  assert v = 880.00, 'balance still 880.00 after the round trip, got ' || v;
  perform public.keep_fund_spend(array[current_setting('ci.sc')::uuid]);
  select count(*) into n from public.fund_spend_sort where id = current_setting('ci.sc')::uuid;
  assert n = 0, '"keep" removes it from the sort list';
end $$;
-- phase 2: the phone's edit sheet sets or clears the fund through save_expense
do $$
declare v_id uuid; v_pot uuid; n int; v numeric;
begin
  insert into public.daily_expenses (household_id, date, description, category, amount, currency, paid_with, payment_method_id)
  values (current_setting('ci.hh')::uuid, current_date, 'Tyres', 'Car', 300, 'AUD', 'Visa', current_setting('ci.visa')::uuid) returning id into v_id;
  select pot_fund_id into v_pot from public.expenses where id = v_id;
  -- p_set_fund false: the fund is left alone (an old client, or a save that didn't touch the row)
  perform public.save_expense('daily', v_id, current_date, 'Tyres', 'Car', 300, 'AUD', null, 'Visa', '', null, null, false, current_setting('ci.car')::uuid);
  select count(*) into n from public.expenses where id = v_id and fund_id is null;
  assert n = 1, 'p_set_fund false leaves fund_id alone';
  -- p_set_fund true with a fund: counts against the Car Fund, stamped to it, pot untouched
  perform public.save_expense('daily', v_id, current_date, 'Tyres', 'Car', 300, 'AUD', null, 'Visa', '', null, null, true, current_setting('ci.car')::uuid);
  select count(*) into n from public.expenses where id = v_id and fund_id = current_setting('ci.car')::uuid and pot_fund_id = current_setting('ci.car')::uuid;
  assert n = 1, 'save_expense set the fund and the stamp followed';
  select balance into v from public.fund_balances where fund_id = current_setting('ci.car')::uuid;
  assert v = 580.00, 'Car Fund 880.00 − 300, got ' || v;
  -- p_set_fund true with null: back on the month's budget (its category's pot)
  perform public.save_expense('daily', v_id, current_date, 'Tyres', 'Car', 300, 'AUD', null, 'Visa', '', null, null, true, null);
  select count(*) into n from public.expenses where id = v_id and fund_id is null and pot_fund_id is not distinct from v_pot;
  assert n = 1, 'clearing the fund restores the pot rule';
  select balance into v from public.fund_balances where fund_id = current_setting('ci.car')::uuid;
  assert v = 880.00, 'Car Fund back to 880.00, got ' || v;
  -- another currency's fund is refused even through the RPC
  begin
    perform public.save_expense('daily', v_id, current_date, 'Tyres', 'Car', 300, 'AUD', null, 'Visa', '', null, null, true, current_setting('ci.sgfund')::uuid);
    assert false, 'an SGD fund took an AUD purchase';
  exception when assert_failure then raise; when others then null; end;
end $$;
rollback;
\echo fund purchases hold
