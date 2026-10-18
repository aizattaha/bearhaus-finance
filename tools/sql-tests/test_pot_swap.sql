-- Pot swap, a country where nothing needs to move (18 Oct 2026): the same fund twice in a country skips that
-- country's transfer; one country at least must move; re-rate and undo work with a missing pair; every fund moves
-- by exactly what the swap says (Available and In the bank), and the check refuses anything else.

\set ON_ERROR_STOP on
begin;
insert into public.beta_invites (code, max_uses, used_count) values ('CI-SWAP', 10, 0) on conflict do nothing;
insert into auth.users (id, email) values ('5a5a5a5a-0000-4000-8000-000000000001', 'swap-owner@test.local');
set local role authenticated;
select set_config('request.jwt.claim.sub', '5a5a5a5a-0000-4000-8000-000000000001', true) \gset x_
select public.create_household_setup('CI-SWAP', 'Swap house', array['Ana', 'Ben'], 'Joint', array['AU', 'SG']) as hh \gset
select public.bh_today(:'hh') as today \gset
select id as ana from public.profiles where household_id = :'hh' and display_name = 'Ana' \gset
select id as floatau from public.funds where household_id = :'hh' and name = 'Float AU' \gset
select id as savau from public.funds where household_id = :'hh' and name = 'Savings AU' \gset
select id as floatsg from public.funds where household_id = :'hh' and name = 'Float SG' \gset
select id as savsg from public.funds where household_id = :'hh' and name = 'Savings SG' \gset
select id as cash from public.payment_methods where household_id = :'hh' and kind = 'cash' limit 1 \gset
insert into public.payment_methods (household_id, name, profile_id, kind, currency) values (:'hh', 'UOB — Ana', :'ana', 'credit_card', 'SGD') returning id as uob \gset
insert into public.fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin)
values (:'hh', :'floatau', 'income', 'movement', :'today', 1000, 'opening', 'manual'),
       (:'hh', :'savau',   'income', 'movement', :'today', 1000, 'opening', 'manual'),
       (:'hh', :'floatsg', 'income', 'movement', :'today', 1000, 'opening', 'manual'),
       (:'hh', :'savsg',   'income', 'movement', :'today', 1000, 'opening', 'manual');
insert into public.daily_expenses (household_id, date, description, category, amount, currency, payment_method_id)
values (:'hh', :'today', 'bought in S$ for an A$ fund', 'Groceries', 100, 'SGD', :'cash') returning id as buy \gset
reset role;
create temp table _m0 as select fund_id, balance, cash_balance from public.fund_money where household_id = :'hh';
select set_config('ci.hh', :'hh', true) \gset x_

-- ── 1 · SG same fund: only the AU pair is written; SG funds don't move ──
set local role authenticated;
select public.record_pot_swap('daily', :'buy', 0.9, :'floatau', :'savau', :'floatsg', :'floatsg') as swap \gset
reset role;
select set_config('ci.swap', :'swap', true) \gset x_
do $$
declare s public.pot_swaps%rowtype; v_bad int;
begin
  select * into s from public.pot_swaps where id = current_setting('ci.swap')::uuid;
  assert s.dst_group_id is not null and s.src_group_id is null and s.spend_tx_id is null, 'SG same fund: no SG pair';
  assert (select count(*) from public.fund_transactions where transfer_group_id = s.dst_group_id) = 2, 'the AU pair is two rows';
  assert (select count(*) from public.fund_transactions where remarks like '%Pot swap · %' and household_id = s.household_id) = 2, 'nothing else written';
  select count(*) into v_bad from _m0 b join public.fund_money a using (fund_id)
   where abs(a.balance - b.balance - case a.fund_id when s.cover_fund_id then -90 when s.land_fund_id then 90 else 0 end) > 0.005
      or abs(a.cash_balance - b.cash_balance - case a.fund_id when s.cover_fund_id then -90 when s.land_fund_id then 90 else 0 end) > 0.005;
  assert v_bad = 0, 'Float AU −90, Savings AU +90, nothing else moved (' || v_bad || ' funds off)';
end $$;

-- ── 2 · a new rate: the AU pair follows; still nothing in SG ─────────────
set local role authenticated;
select public.update_pot_swap_rate(:'swap', 0.95) as dst \gset
reset role;
do $$
declare s public.pot_swaps%rowtype;
begin
  select * into s from public.pot_swaps where id = current_setting('ci.swap')::uuid;
  assert s.dst_amount = 95, 'dst follows the rate';
  assert (select sum(amount) from public.fund_transactions where transfer_group_id = s.dst_group_id) = 190, 'both AU rows at 95';
  assert (select balance from public.fund_money where fund_id = s.cover_fund_id) - (select balance from _m0 where fund_id = s.cover_fund_id) = -95, 'Float AU −95';
end $$;

-- ── 3 · undo: every fund back where it was ──────────────────────────────
set local role authenticated;
select public.delete_pot_swap(:'swap') \gset x_
reset role;
do $$
begin
  assert (select count(*) from _m0 b join public.fund_money a using (fund_id) where abs(a.balance - b.balance) > 0.005 or abs(a.cash_balance - b.cash_balance) > 0.005) = 0, 'undo puts every fund back';
  assert not exists (select 1 from public.fund_transactions where household_id = current_setting('ci.hh')::uuid and remarks like '%Pot swap · %'), 'no swap rows left';
end $$;

-- ── 4 · both countries the same fund: refused, nothing written ──────────
set local role authenticated;
do $$
declare ok boolean := false;
begin
  begin
    perform public.record_pot_swap('daily', (select id from public.expenses where description = 'bought in S$ for an A$ fund' and household_id = current_setting('ci.hh')::uuid),
                                   0.9, (select id from public.funds where household_id = current_setting('ci.hh')::uuid and name = 'Float AU'),
                                   (select id from public.funds where household_id = current_setting('ci.hh')::uuid and name = 'Float AU'),
                                   (select id from public.funds where household_id = current_setting('ci.hh')::uuid and name = 'Float SG'),
                                   (select id from public.funds where household_id = current_setting('ci.hh')::uuid and name = 'Float SG'));
  exception when others then ok := sqlerrm like 'nothing would move%';
  end;
  assert ok, 'a swap that moves nothing is refused';
end $$;
reset role;

-- ── 5 · a trip line on an SG card, SG same fund, AU two funds: the bank pot pays it, owed on the card ──
set local role authenticated;
insert into public.trips (household_id, name, start_date, end_date, currency, currencies, countries)
values (:'hh', 'SG weekend', :'today', :'today', 'SGD', '{SGD}', '{SG}') returning id as trip \gset
insert into public.travel_expenses (household_id, trip_id, date, description, category, amount, currency, payer_profile_id, payment_method_id, paid_with)
values (:'hh', :'trip', :'today', 'hotel', 'Accommodation', 200, 'SGD', :'ana', :'uob', 'UOB — Ana') returning id as hotel \gset
select public.record_pot_swap('travel', :'hotel', 0.9, :'savau', :'floatau', :'floatsg', :'floatsg') as swap2 \gset
reset role;
select set_config('ci.swap2', :'swap2', true) \gset x_
do $$
declare s public.pot_swaps%rowtype; e public.expenses%rowtype; b numeric; c numeric;
begin
  select * into s from public.pot_swaps where id = current_setting('ci.swap2')::uuid;
  select * into e from public.expenses where id = s.expense_id;
  assert s.src_group_id is null and s.dst_group_id is not null and s.spend_tx_id is not null and e.sent_to_fund and s.marked_sent, 'trip line: AU pair + spend row, marked sent';
  select a.balance - m.balance, a.cash_balance - m.cash_balance into b, c from public.fund_money a join _m0 m using (fund_id) where a.fund_id = s.bank_to_fund_id;
  assert b = -200 and c = 0, 'Float SG pays the hotel: Available −200, still in the bank until the UOB is paid — got ' || b || ' / ' || c;
end $$;
set local role authenticated;
select public.delete_pot_swap(:'swap2') \gset x_
reset role;
do $$
begin
  assert (select count(*) from _m0 b join public.fund_money a using (fund_id) where abs(a.balance - b.balance) > 0.005 or abs(a.cash_balance - b.cash_balance) > 0.005) = 0, 'undo of the trip swap puts every fund back';
  assert not (select sent_to_fund from public.expenses where description = 'hotel' and household_id = current_setting('ci.hh')::uuid), 'the hotel is unsent again';
end $$;

-- ── 6 · AU same fund, SG two funds (the old two-sided SG move) still works ──
set local role authenticated;
select public.record_pot_swap('daily', :'buy', 0.9, :'floatau', :'floatau', :'savsg', :'floatsg') as swap3 \gset
reset role;
select set_config('ci.swap3', :'swap3', true) \gset x_
do $$
declare s public.pot_swaps%rowtype;
begin
  select * into s from public.pot_swaps where id = current_setting('ci.swap3')::uuid;
  assert s.dst_group_id is null and s.src_group_id is not null, 'AU same fund: only the SG pair';
  assert (select count(*) from _m0 b join public.fund_money a using (fund_id)
           where abs(a.balance - b.balance - case a.fund_id when s.bank_from_fund_id then -100 when s.bank_to_fund_id then 100 else 0 end) > 0.005) = 0,
         'Savings SG −100, Float SG +100, AU untouched';
end $$;
set local role authenticated;
select public.update_pot_swap_rate(:'swap3', 1.0) \gset x_
select public.delete_pot_swap(:'swap3') \gset x_
reset role;
set constraints public.zz_fund_group_check immediate;

-- ── 7 · the check refuses a fund that moves by anything else; the helpers are the server's ──
do $$
declare ok boolean := false;
begin
  begin
    perform public.bh_pot_swap_check(current_setting('ci.hh')::uuid, public.bh_pot_swap_snapshot(current_setting('ci.hh')::uuid),
                                     jsonb_build_object((select id from public.funds where household_id = current_setting('ci.hh')::uuid and name = 'Float AU')::text, jsonb_build_array(1, 1)),
                                     '{}'::jsonb, 'test');
  exception when others then ok := sqlerrm like 'pot swap (test): 1 fund(s)%';
  end;
  assert ok, 'the check names a count when a fund is off';
  assert not has_function_privilege('authenticated', 'public.bh_pot_swap_check(uuid, jsonb, jsonb, jsonb, text)', 'execute'), 'the check is the server''s';
  assert not has_function_privilege('authenticated', 'public.bh_pot_swap_effect(uuid)', 'execute'), 'the effect helper is the server''s';
  assert not has_function_privilege('authenticated', 'public.bh_pot_swap_snapshot(uuid)', 'execute'), 'the snapshot helper is the server''s';
end $$;

rollback;
