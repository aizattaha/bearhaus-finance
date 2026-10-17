-- Money guards (Review Board round 1, Bundle A — DECISIONS E36). Each round-1 probe becomes a test:
--   A1 · a card counts as owed only from the start date, on the fund as on the card; the cross-check sees a drift;
--        the Sort moves assert In the bank and Owed
--   A2 · a purchase with refunds can't become a refund (save_expense, a direct write); the nightly check counts one
--   A3 · a phone payment settles the card's oldest unpaid statement; the Desk links / unlinks
--   A4 · a card with history keeps its type and currency
--   A5 · a retapped card payment or refund saves once
--   A6 · a sent purchase can't be deleted, even by a server path; a send deleted outright is seen by the nightly check

\set ON_ERROR_STOP on
begin;
insert into public.beta_invites (code, max_uses, used_count) values ('CI-GUARD', 10, 0) on conflict do nothing;
insert into auth.users (id, email) values ('abababab-0000-4000-8000-000000000001', 'guard-owner@test.local');
set local role authenticated;
select set_config('request.jwt.claim.sub', 'abababab-0000-4000-8000-000000000001', true) \gset x_
select public.create_household_setup('CI-GUARD', 'Guard house', array['Ana', 'Ben'], 'Joint', array['AU']) as hh \gset
select public.bh_today(:'hh') as today \gset
select (date_trunc('month', :'today'::date) - interval '1 month')::date as start \gset
reset role;
update public.households set pot_start = :'start' where id = :'hh';
set local role authenticated;
select set_config('ci.hh', :'hh', true) \gset x_
select set_config('ci.today', :'today', true) \gset x_
select set_config('ci.start', :'start', true) \gset x_
select id as ana from public.profiles where household_id = :'hh' and display_name = 'Ana' \gset
select id as pot from public.funds where household_id = :'hh' and is_spend_pot \gset
select id as tf from public.funds where household_id = :'hh' and name = 'Travel fund' \gset
select id as sav from public.funds where household_id = :'hh' and name = 'Savings' \gset
select id as cash from public.payment_methods where household_id = :'hh' and kind = 'cash' \gset
insert into public.payment_methods (household_id, name, profile_id, kind, currency) values (:'hh', 'Visa — Ana', :'ana', 'credit_card', 'AUD') returning id as visa \gset
insert into public.payment_methods (household_id, name, profile_id, kind, currency) values (:'hh', 'Amex — Ana', :'ana', 'credit_card', 'AUD') returning id as amex \gset
insert into public.payment_methods (household_id, name, profile_id, kind, currency) values (:'hh', 'Spare card', :'ana', 'credit_card', 'AUD') returning id as spare \gset
select id as dining from public.categories where household_id = :'hh' and kind = 'daily' and name = 'Dining out' \gset
select id as tcat from public.categories where household_id = :'hh' and kind = 'travel' order by sort_order limit 1 \gset
select set_config('ci.pot', :'pot', true) \gset x_
select set_config('ci.sav', :'sav', true) \gset x_
select set_config('ci.tf', :'tf', true) \gset x_
select set_config('ci.visa', :'visa', true) \gset x_
select set_config('ci.amex', :'amex', true) \gset x_
select set_config('ci.spare', :'spare', true) \gset x_
select set_config('ci.dining', :'dining', true) \gset x_
select set_config('ci.ana', :'ana', true) \gset x_
insert into public.fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin)
values (:'hh', :'pot', 'income', 'movement', :'start'::date - 60, 2000, 'opening', 'manual'),
       (:'hh', :'sav', 'income', 'movement', :'start'::date - 60, 2000, 'opening', 'manual'),
       (:'hh', :'tf',  'income', 'movement', :'start'::date - 60, 2000, 'opening', 'manual');

-- ── A1 · before the start date, card spending left the bank when it happened ──
-- a Savings purchase on the Visa from before the start (the card's opening holds what was still owed then), and a
-- card payment from before the start: the card ignores both, and so do the funds now
insert into public.daily_expenses (household_id, date, description, category_id, amount, currency, payer_profile_id, payment_method_id, fund_id)
values (:'hh', :'start'::date - 10, 'old sofa', :'dining', 300, 'AUD', :'ana', :'visa', :'sav');
insert into public.card_openings (household_id, payment_method_id, fund_id, amount) values (:'hh', :'visa', :'pot', 120);
select public.record_card_payment(:'visa', :'start'::date - 5, jsonb_build_array(jsonb_build_object('fund_id', :'pot', 'amount', 50))) \gset x_
-- and since the start: a Savings purchase on the Visa, a Savings money-out row on the Amex
insert into public.daily_expenses (household_id, date, description, category_id, amount, currency, payer_profile_id, payment_method_id, fund_id)
values (:'hh', :'start'::date + 2, 'new desk', :'dining', 200, 'AUD', :'ana', :'visa', :'sav');
insert into public.fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin, account_payment_method_id)
values (:'hh', :'sav', 'expense', 'movement', :'start'::date + 3, 40, 'parking (on the Amex)', 'manual', :'amex');
reset role;
do $$
declare m record; v numeric;
begin
  select * into m from public.fund_money where fund_id = current_setting('ci.sav')::uuid;
  assert m.balance = 2000 - 300 - 200 - 40, 'Savings Available counts everything it paid for, got ' || m.balance;
  assert m.owed_on_cards = 240, 'Savings owes only what its cards owe since the start (200 + 40), got ' || m.owed_on_cards;
  assert m.cash_balance = 2000 - 300, 'Savings In the bank: the old sofa left the bank when it was bought, got ' || m.cash_balance;
  select * into m from public.fund_money where fund_id = current_setting('ci.pot')::uuid;
  assert m.owed_on_cards = 120 and m.cash_balance = 2120, 'the pot holds the Visa''s opening; the pre-start payment is outside the era, got ' || m.owed_on_cards || ' / ' || m.cash_balance;
  select owed into v from public.card_balances where payment_method_id = current_setting('ci.visa')::uuid;
  assert v = 120 + 200, 'the Visa owes its opening and the desk, got ' || v;
  select owed into v from public.card_balances where payment_method_id = current_setting('ci.amex')::uuid;
  assert v = 40, 'the Amex owes the parking, got ' || v;
  assert (select gap from public.bh_owed_gaps() where household_id = current_setting('ci.hh')::uuid and currency = 'AUD') = 0, 'cards and funds agree';
  assert (select card_only + fund_only from public.bh_owed_gaps() where household_id = current_setting('ci.hh')::uuid and currency = 'AUD') = 0, 'nothing one-sided here';
end $$;

-- the Sort moves: a pre-start card row moves without touching In the bank; one since the start keeps owing
set local role authenticated;
insert into public.fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin, account_payment_method_id)
values (:'hh', :'sav', 'expense', 'movement', :'start'::date - 20, 70, 'old rug (on the Visa)', 'manual', :'visa') returning id as rug \gset
insert into public.fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin)
values (:'hh', :'sav', 'expense', 'movement', :'start'::date + 4, 25, 'cash for the window cleaner', 'manual') returning id as win \gset
select set_config('ci.rug', :'rug', true) \gset x_
select set_config('ci.window', :'win', true) \gset x_
do $$
declare b record; a record;
begin
  select * into b from public.fund_money where fund_id = current_setting('ci.sav')::uuid;
  perform public.move_fund_spend_to_expenses(array[current_setting('ci.rug')::uuid], 'Dining out', current_setting('ci.visa')::uuid);
  select * into a from public.fund_money where fund_id = current_setting('ci.sav')::uuid;
  assert (a.balance, a.cash_balance, a.owed_on_cards) = (b.balance, b.cash_balance, b.owed_on_cards), 'a pre-start card row moved without a number moving';
  -- and back again, card kept
  perform public.move_expense_to_fund_spend(array[current_setting('ci.rug')::uuid]);
  select * into a from public.fund_money where fund_id = current_setting('ci.sav')::uuid;
  assert (a.balance, a.cash_balance, a.owed_on_cards) = (b.balance, b.cash_balance, b.owed_on_cards), 'the way back moved nothing either';
  -- a cash row since the start, moved onto the Visa: the card now owes it, so In the bank rises by it (and Owed), Available stays
  perform public.move_fund_spend_to_expenses(array[current_setting('ci.window')::uuid], 'Dining out', current_setting('ci.visa')::uuid);
  select * into a from public.fund_money where fund_id = current_setting('ci.sav')::uuid;
  assert a.balance = b.balance and a.cash_balance = b.cash_balance + 25 and a.owed_on_cards = b.owed_on_cards + 25,
         'moving a cash row onto a card moves In the bank and Owed by exactly its amount';
end $$;
reset role;
-- the assert itself refuses a fund whose In the bank moved the wrong way
do $$
declare b public.fund_money; ok boolean := false;
begin
  select * into b from public.fund_money where fund_id = current_setting('ci.sav')::uuid;
  b.cash_balance := b.cash_balance + 5;
  begin
    perform public.bh_assert_move(current_setting('ci.hh')::uuid, current_setting('ci.sav')::uuid, current_setting('ci.today')::date, 10,
                                  null, null, b, 'a test row');
  exception when raise_exception then ok := true; end;
  assert ok, 'a move that shifted In the bank the wrong way was let through';
end $$;
-- the cross-check sees a drift: a sent trip line whose stored share no longer equals what the card charged
set local role authenticated;
insert into public.trips (household_id, name, start_date, end_date, currency) values (:'hh', 'Hobart', :'today', :'today', 'AUD') returning id as trip \gset
insert into public.travel_expenses (household_id, trip_id, date, description, category_id, amount, currency, payer_profile_id, payment_method_id)
values (:'hh', :'trip', :'today', 'hotel', :'tcat', 300, 'AUD', :'ana', :'visa') returning id as hotel \gset
select public.send_trip(:'trip', :'today') \gset x_
select set_config('ci.hotel', :'hotel', true) \gset x_
reset role;
do $$
declare n int;
begin
  assert (select gap from public.bh_owed_gaps() where household_id = current_setting('ci.hh')::uuid and currency = 'AUD') = 0, 'a sent trip line: card and travel fund agree';
  alter table public.expenses disable trigger user;
  update public.expenses set sent_amount = 290 where id = current_setting('ci.hotel')::uuid;
  alter table public.expenses enable trigger user;
  assert (select gap from public.bh_owed_gaps() where household_id = current_setting('ci.hh')::uuid and currency = 'AUD') = 10, 'the drift shows as a gap';
  select bad into n from public.bh_money_check() where check_name = 'funds and cards that disagree on what is owed';
  assert n >= 1, 'the nightly check fails on it';
  alter table public.expenses disable trigger user;
  update public.expenses set sent_amount = 300 where id = current_setting('ci.hotel')::uuid;
  alter table public.expenses enable trigger user;
end $$;

-- ── A2 · a purchase with refunds stays a purchase ───────────────────────
set local role authenticated;
insert into public.daily_expenses (household_id, date, description, category_id, amount, currency, payer_profile_id, payment_method_id)
values (:'hh', :'today'::date - 1, 'dinner for six', :'dining', 200, 'AUD', :'ana', :'amex') returning id as dinner \gset
select set_config('ci.dinner', :'dinner', true) \gset x_
select public.refund_purchases(jsonb_build_array(jsonb_build_object('id', :'dinner', 'amount', 40)), :'today', 'card') \gset x_
do $$
declare ok boolean := false; d uuid := current_setting('ci.dinner')::uuid;
begin
  begin
    perform public.save_expense('daily', d, current_setting('ci.today')::date - 1, 'dinner for six', null, 200, 'AUD', current_setting('ci.ana')::uuid, null, '', null,
                                true, false, null, current_setting('ci.dining')::uuid, current_setting('ci.amex')::uuid);
  exception when raise_exception then ok := true; end;
  assert ok, 'save_expense turned a refunded purchase into a refund';
  ok := false;
  begin update public.daily_expenses set is_refund = true where id = d; exception when raise_exception then ok := true; end;
  assert ok, 'a direct write turned a refunded purchase into a refund';
  assert not (select is_refund from public.expenses where id = d), 'still a purchase';
  -- the other way stays refused too: a linked refund can't become a purchase
  ok := false;
  begin update public.daily_expenses set is_refund = false where refund_of = d; exception when raise_exception then ok := true; end;
  assert ok, 'a linked refund became a purchase';
end $$;
reset role;
do $$
declare n int;
begin
  assert (select bad from public.bh_money_check() where check_name = 'purchases with refunds that are themselves refunds') = 0, 'none today';
  alter table public.expenses disable trigger user;   -- plant one, as a broken old client might have
  update public.expenses set is_refund = true where id = current_setting('ci.dinner')::uuid;
  alter table public.expenses enable trigger user;
  select bad into n from public.bh_money_check() where check_name = 'purchases with refunds that are themselves refunds';
  assert n = 1, 'the nightly check counts it, got ' || n;
  alter table public.expenses disable trigger user;
  update public.expenses set is_refund = false where id = current_setting('ci.dinner')::uuid;
  alter table public.expenses enable trigger user;
end $$;
-- the way back to fund movements refuses a purchase with a refund, even one in the bin (it would delete the refund)
set local role authenticated;
insert into public.daily_expenses (household_id, date, description, category_id, amount, currency, payer_profile_id, payment_method_id, fund_id)
values (:'hh', :'today', 'car service', :'dining', 400, 'AUD', :'ana', :'visa', :'sav') returning id as service \gset
select public.refund_purchases(jsonb_build_array(jsonb_build_object('id', :'service', 'amount', 30)), :'today', 'card') as r6 \gset
select public.soft_delete_rows('expense', array[(select id from public.expenses where refund_of = :'service')]) \gset x_
select set_config('ci.service', :'service', true) \gset x_
do $$
declare ok boolean := false;
begin
  begin perform public.move_expense_to_fund_spend(array[current_setting('ci.service')::uuid]); exception when raise_exception then ok := true; end;
  assert ok, 'a purchase with a binned refund went back to fund movements';
  assert (select count(*) from public.expenses where refund_of = current_setting('ci.service')::uuid) = 1, 'its refund is still there';
end $$;

-- ── A3 · a payment from the phone settles its statement ─────────────────
-- the Amex statement for the start month, with the dinner ticked on it, saved on the Desk
insert into public.statements (household_id, payment_method_id, period_start, period_end, label)
values (:'hh', :'amex', :'start', (:'today'::date - 1), 'first') returning id as st1 \gset
select public.reconcile_rows('expense', array[:'dinner']::uuid[], :'st1') \gset x_
select set_config('ci.st1', :'st1', true) \gset x_
-- the phone pays the Amex (no statement named): it lands on that statement
select public.record_card_payment(:'amex', :'today', jsonb_build_array(jsonb_build_object('fund_id', :'pot', 'amount', 200))) as pay1 \gset
select set_config('ci.pay1', :'pay1', true) \gset x_
do $$
declare s record;
begin
  assert (select count(*) from public.fund_transactions where transfer_group_id = current_setting('ci.pay1')::uuid
           and settles_statement_id = current_setting('ci.st1')::uuid) = 1, 'the phone''s payment settles the statement';
  select * into s from public.statement_balances where statement_id = current_setting('ci.st1')::uuid;
  assert s.status = 'paid', 'the statement reads paid, got ' || s.status;
  assert (select remarks from public.fund_transactions where transfer_group_id = current_setting('ci.pay1')::uuid) like 'Paid Amex — Ana · statement %', 'the remark names the statement';
end $$;
-- a second payment with nothing left unpaid stays unlinked; the Desk can link it, unlink it, but not to another card
select public.record_card_payment(:'amex', :'today', jsonb_build_array(jsonb_build_object('fund_id', :'pot', 'amount', 15))) as pay2 \gset
select set_config('ci.pay2', :'pay2', true) \gset x_
insert into public.statements (household_id, payment_method_id, period_start, period_end, label)
values (:'hh', :'visa', :'start', (:'today'::date - 1), 'visa first') returning id as stv \gset
select set_config('ci.stv', :'stv', true) \gset x_
do $$
declare ok boolean := false; n int;
begin
  assert (select settles_statement_id from public.fund_transactions where transfer_group_id = current_setting('ci.pay2')::uuid) is null, 'nothing unpaid: unlinked';
  n := public.link_card_payment(current_setting('ci.pay2')::uuid, current_setting('ci.st1')::uuid);
  assert n = 1, 'the Desk links it';
  assert (select paid from public.statement_balances where statement_id = current_setting('ci.st1')::uuid) = 215, 'the statement counts both';
  n := public.link_card_payment(current_setting('ci.pay2')::uuid, null);
  assert n = 1 and (select paid from public.statement_balances where statement_id = current_setting('ci.st1')::uuid) = 200, 'and unlinks it';
  begin perform public.link_card_payment(current_setting('ci.pay2')::uuid, current_setting('ci.stv')::uuid); exception when raise_exception then ok := true; end;
  assert ok, 'a payment was linked to another card''s statement';
end $$;
reset role;
do $$ begin
  assert (select bad from public.bh_money_check() where check_name = 'card payments not linked to a statement') >= 1, 'the nightly check counts unlinked payments (info)';
end $$;
set local role authenticated;

-- ── A4 · a card with history keeps its type and currency ────────────────
do $$
declare ok boolean := false; n int;
begin
  assert current_setting('ci.visa')::uuid in (select public.cards_in_use()), 'the Visa is in use';
  assert current_setting('ci.spare')::uuid not in (select public.cards_in_use()), 'the spare card isn''t';
  begin update public.payment_methods set kind = 'debit_card', closing_day = null where id = current_setting('ci.visa')::uuid; exception when raise_exception then ok := true; end;
  assert ok, 'a card with history changed type';
  ok := false;
  begin update public.payment_methods set currency = 'SGD' where id = current_setting('ci.visa')::uuid; exception when raise_exception then ok := true; end;
  assert ok, 'a card with history changed currency';
  ok := false;
  begin update public.payment_methods set currency = null where id = current_setting('ci.visa')::uuid; exception when raise_exception then ok := true; end;
  assert ok, 'a card with history became multi-currency';
  -- the rest of its settings stay free
  update public.payment_methods set closing_day = 14, name = 'Visa — Ana (gold)' where id = current_setting('ci.visa')::uuid;
  get diagnostics n = row_count; assert n = 1, 'closing day and name still change';
  -- a card with nothing on it can still be set up
  update public.payment_methods set kind = 'debit_card', currency = 'SGD' where id = current_setting('ci.spare')::uuid;
  get diagnostics n = row_count; assert n = 1, 'an unused card changes type and currency';
end $$;
reset role;
do $$ declare n int; begin
  -- a deliberate server-side re-derivation may (E32), with the switch on
  perform set_config('bh.card_change', 'on', true);
  update public.payment_methods set currency = 'SGD' where id = current_setting('ci.amex')::uuid;
  update public.payment_methods set currency = 'AUD' where id = current_setting('ci.amex')::uuid;
  get diagnostics n = row_count; assert n = 1, 'the server switch lets a re-derivation through';
  perform set_config('bh.card_change', '', true);
end $$;
set local role authenticated;

-- ── A5 · a retap saves once ─────────────────────────────────────────────
do $$
declare g1 uuid; g2 uuid; r1 jsonb; r2 jsonb; p uuid := 'abababab-0000-4000-8000-0000000000a1'; q uuid := 'abababab-0000-4000-8000-0000000000a2'; d2 uuid;
begin
  g1 := public.record_card_payment(current_setting('ci.visa')::uuid, current_setting('ci.today')::date,
                                   jsonb_build_array(jsonb_build_object('fund_id', current_setting('ci.pot')::uuid, 'amount', 20)), null, 'retap test', p);
  g2 := public.record_card_payment(current_setting('ci.visa')::uuid, current_setting('ci.today')::date,
                                   jsonb_build_array(jsonb_build_object('fund_id', current_setting('ci.pot')::uuid, 'amount', 20)), null, 'retap test', p);
  assert g1 = p and g2 = p, 'the payment keeps the form''s id';
  assert (select count(*) from public.fund_transactions where transfer_group_id = p) = 1, 'the second tap saved nothing';
  -- a part refund of two purchases, tapped twice
  insert into public.daily_expenses (household_id, date, description, category_id, amount, currency, payer_profile_id, payment_method_id)
  values (current_setting('ci.hh')::uuid, current_setting('ci.today')::date, 'big shop', current_setting('ci.dining')::uuid, 300, 'AUD', current_setting('ci.ana')::uuid, current_setting('ci.visa')::uuid)
  returning id into d2;
  r1 := public.refund_purchases(jsonb_build_array(jsonb_build_object('id', d2, 'amount', 50), jsonb_build_object('id', current_setting('ci.dinner')::uuid, 'amount', 10)),
                                current_setting('ci.today')::date, 'card', null, q);
  r2 := public.refund_purchases(jsonb_build_array(jsonb_build_object('id', d2, 'amount', 50), jsonb_build_object('id', current_setting('ci.dinner')::uuid, 'amount', 10)),
                                current_setting('ci.today')::date, 'card', null, q);
  assert r1 = r2, 'the retap answers what the first tap saved: ' || r1::text || ' vs ' || r2::text;
  assert jsonb_array_length(r1) = 2 and (r1->0->>'id')::uuid = q, 'two refunds, the first with the form''s id';
  assert (select refunded from public.expenses where id = d2) = 50, 'the big shop refunded once';
  assert (select refunded from public.expenses where id = current_setting('ci.dinner')::uuid) = 50, 'the dinner refunded once more (40 + 10)';
end $$;

-- ── A6 · a sent purchase isn't deleted, by anyone ───────────────────────
reset role;
do $$
declare ok boolean := false; n int; v_send uuid;
begin
  -- a server path that forgot the lock (here: the database owner) still can't delete it
  begin delete from public.expenses where id = current_setting('ci.hotel')::uuid; exception when raise_exception then ok := true; end;
  assert ok, 'a sent purchase was deleted';
  -- a send deleted outright leaves its purchase marked with what it took: the nightly check sees it
  select settlement_tx_id into v_send from public.expenses where id = current_setting('ci.hotel')::uuid;
  assert (select bad from public.bh_money_check() where check_name = 'sent purchases out of step with their send') = 0, 'in step before';
  delete from public.fund_transactions_all where id = v_send;
  select bad into n from public.bh_money_check() where check_name = 'sent purchases out of step with their send';
  assert n = 1, 'a deleted send is seen, got ' || n;
end $$;

rollback;
\echo money guards hold
