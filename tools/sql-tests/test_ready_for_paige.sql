-- Bundle C · ready for Paige (20261019060000): a login invited to join can't set up a second household; the owner's
-- setup list is worked out from the data and each item clears when its job is done; money_checks says which cards
-- and funds are checked against a closed statement; fund_explain's parts add up to fund_money, all time and this
-- month; the new functions are the owner's / a member's / nobody's as intended.

\set ON_ERROR_STOP on
begin;
insert into public.beta_invites (code, max_uses, used_count) values ('CI-RP', 10, 0) on conflict do nothing;
insert into auth.users (id, email) values ('5e5e5e5e-0000-4000-8000-000000000001', 'rp-owner@test.local'),
                                          ('5e5e5e5e-0000-4000-8000-000000000003', 'rp-outsider@test.local');
set local role authenticated;
select set_config('request.jwt.claim.sub', '5e5e5e5e-0000-4000-8000-000000000003', true) \gset x_
select public.create_household_setup('CI-RP', 'Outside house', array['Zed'], null, array['AU']) as hh2 \gset
select set_config('request.jwt.claim.sub', '5e5e5e5e-0000-4000-8000-000000000001', true) \gset x_
select public.create_household_setup('CI-RP', 'Paige house', array['Ana', 'Ben'], 'Joint', array['AU']) as hh \gset
reset role;
update public.households set pot_start = (public.bh_today(:'hh') - 75) where id = :'hh';
set local role authenticated;
select public.bh_today(:'hh') as today \gset
select (public.bh_today(:'hh') - 75) as start \gset
select id as ana from public.profiles where household_id = :'hh' and display_name = 'Ana' \gset
select id as ben from public.profiles where household_id = :'hh' and display_name = 'Ben' \gset
select id as floatau from public.funds where household_id = :'hh' and name = 'Float' \gset
select id as savau from public.funds where household_id = :'hh' and name = 'Savings' \gset
select id as cash from public.payment_methods where household_id = :'hh' and kind = 'cash' limit 1 \gset
select id as groc from public.categories where household_id = :'hh' and kind = 'daily' and name = 'Groceries' \gset
select set_config('ci.hh', :'hh', true) \gset x_
select set_config('ci.hh2', :'hh2', true) \gset x_

-- a helper to read one item of the list
create function pg_temp.todo(k text) returns jsonb language sql as $$ select e from jsonb_array_elements(public.setup_todo()) e where e ->> 'key' = k $$;

-- ── 1 · a fresh household: every item open that the data says is open ───
-- (a new household links its owner to the first person; an older one, like BearHaus, didn't — unlink to see the item)
select public.link_my_profile(null) \gset x_
do $$
declare t jsonb := public.setup_todo();
begin
  assert jsonb_array_length(t) = 10, 'ten setup items';
  assert (select string_agg(e ->> 'key', ',' order by o) from jsonb_array_elements(t) with ordinality x(e, o))
       = 'me,defaults,closing_days,old_refunds,sort,openings,statements,trips,invite,signup_check', 'items in the order to do them';
  assert not (pg_temp.todo('me') ->> 'done')::boolean, 'that''s me is open';
  assert (pg_temp.todo('defaults') ->> 'n')::int = 2, 'two people without a daily default';
  assert (pg_temp.todo('closing_days') ->> 'done')::boolean, 'no credit card yet: nothing to set';
  assert (pg_temp.todo('old_refunds') ->> 'done')::boolean and (pg_temp.todo('sort') ->> 'done')::boolean, 'nothing to redo or sort';
  assert (pg_temp.todo('invite') ->> 'n')::int = 2, 'two people without a login (the owner isn''t linked yet)';
  assert not (pg_temp.todo('signup_check') ->> 'done')::boolean, 'the sign-up check is open until ticked';
end $$;

-- ── 2 · each job clears its item ────────────────────────────────────────
select public.link_my_profile(:'ana') \gset x_
insert into public.card_defaults (household_id, profile_id, context, payment_method_id) values (:'hh', :'ana', 'daily', :'cash');
insert into public.payment_methods (household_id, name, profile_id, kind, currency) values (:'hh', 'Visa — Ana', :'ana', 'credit_card', 'AUD') returning id as visa \gset
select set_config('ci.visa', :'visa', true) \gset x_
do $$
begin
  assert (pg_temp.todo('me') ->> 'done')::boolean, 'linked: that''s me is done';
  assert (pg_temp.todo('defaults') ->> 'n')::int = 1 and pg_temp.todo('defaults') -> 'people' = '["Ben"]', 'Ben still has no default';
  assert (pg_temp.todo('closing_days') ->> 'n')::int = 1, 'the new credit card has no closing day';
  assert (pg_temp.todo('statements') ->> 'blocked')::boolean, 'statements wait for the closing days';
  assert (pg_temp.todo('statements') ->> 'to_close')::int = 0, 'no closing day, no periods counted yet';
  assert (pg_temp.todo('openings') ->> 'n')::int = 1, 'the card''s opening on the start date is open';
  assert (pg_temp.todo('invite') ->> 'n')::int = 1, 'only Ben has no login now';
end $$;
update public.payment_methods set closing_day = 15 where id = :'visa';
insert into public.card_openings (payment_method_id, household_id, fund_id, amount) values (:'visa', :'hh', :'floatau', 0);
-- purchases on the card across the periods, money in, an old-style refund, a money-out row for Sort
insert into public.fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin)
values (:'hh', :'floatau', 'income', 'movement', :'start', 3000, 'salary', 'manual'),
       (:'hh', :'floatau', 'income', 'movement', date_trunc('month', :'today'::date), 900, 'salary this month', 'manual'),
       (:'hh', :'savau',   'income', 'movement', :'start'::date - 20, 500, 'opening before the start', 'manual'),
       (:'hh', :'savau',   'expense', 'movement', :'start'::date + 3, 40, 'car service from savings', 'manual');
select public.record_transfer(:'floatau', :'savau', :'today', 120, null, 'top-up') \gset x_
insert into public.daily_expenses (household_id, date, description, category_id, amount, currency, payment_method_id, payer_profile_id)
select :'hh', d::date, 'shop ' || i, :'groc', 20 + i, 'AUD', :'visa', :'ana'
  from generate_series(0, 70, 7) with ordinality g(d0, i), lateral (select (:'start'::date + d0::int) as d) x;
insert into public.daily_expenses (household_id, date, description, category_id, amount, currency, payment_method_id, payer_profile_id, fund_id)
values (:'hh', :'today', 'savings buy', :'groc', 33, 'AUD', :'visa', :'ana', :'savau');
insert into public.daily_expenses (household_id, date, description, category, amount, currency, payment_method_id, is_refund)
values (:'hh', :'today', 'old refund', 'Groceries', 7, 'AUD', :'cash', true);
reset role;   -- bh_card_periods is the server's (the read models call it)
select count(*) as per from public.bh_card_periods(:'hh') where ended \gset
select period_start as p1s, period_end as p1e from public.bh_card_periods(:'hh') where ended order by period_end limit 1 \gset
set local role authenticated;
select set_config('ci.per', :'per', true) \gset x_
select set_config('ci.p1e', :'p1e', true) \gset x_
do $$
declare per int := current_setting('ci.per')::int;
begin
  assert per >= 2, 'at least two ended periods since the start: ' || per;
  assert (pg_temp.todo('closing_days') ->> 'done')::boolean and (pg_temp.todo('openings') ->> 'done')::boolean, 'closing day and opening set';
  assert not (pg_temp.todo('statements') ->> 'blocked')::boolean, 'statements no longer wait';
  assert (pg_temp.todo('statements') ->> 'to_close')::int = per, 'every ended period is still to close';
  assert (pg_temp.todo('old_refunds') ->> 'n')::int = 1, 'one old-style refund to redo';
  assert (pg_temp.todo('sort') ->> 'n')::int = (select count(*) from public.fund_spend_sort where household_id = current_setting('ci.hh')::uuid)
     and (pg_temp.todo('sort') ->> 'n')::int >= 1, 'the Sort backlog, counted as the Desk lists it';
  -- not checked yet: the card, and the funds whose money is on it
  assert (public.money_checks() ->> 'unchecked')::int = 1, 'the card is not checked yet';
  assert exists (select 1 from jsonb_array_elements(public.money_checks() -> 'funds') f
                  where f ->> 'fund_id' = (select id::text from public.funds where household_id = current_setting('ci.hh')::uuid and name = 'Float')
                    and f ->> 'checked_to' is null and f -> 'unchecked' = '["Visa — Ana"]'), 'the spending pot says which card is unchecked';
end $$;

-- close the first ended period, with a total to pay
insert into public.statements (household_id, payment_method_id, period_start, period_end, statement_total, closed_at)
values (:'hh', :'visa', :'p1s', :'p1e', 50, now()) returning id as s1 \gset
do $$
declare per int := current_setting('ci.per')::int;
begin
  assert (pg_temp.todo('statements') ->> 'to_close')::int = per - 1, 'one period closed';
  assert (pg_temp.todo('statements') ->> 'to_pay')::int = 1, 'the closed statement is still to pay';
  assert (select (c ->> 'checked_to')::date from jsonb_array_elements(public.money_checks() -> 'cards') c where c ->> 'name' = 'Visa — Ana')
       = current_setting('ci.p1e')::date, 'the card is checked to that statement''s end';
  assert (public.money_checks() ->> 'unchecked')::int = 0, 'no card left unchecked';
end $$;
select public.record_card_payment(:'visa', :'today', jsonb_build_array(jsonb_build_object('fund_id', :'floatau', 'amount', 50)), :'s1', 'Visa') \gset x_
do $$ begin assert (pg_temp.todo('statements') ->> 'to_pay')::int = 0, 'paid: nothing left to pay'; end $$;

-- a statement saved under an older closing day still covers its period (ENG-03)
reset role;
select period_start as p2s, period_end as p2e from public.bh_card_periods(:'hh') where ended and not covered order by period_end limit 1 \gset
insert into public.statements (household_id, payment_method_id, period_start, period_end, closed_at)
values (:'hh', :'visa', :'p2s'::date - 2, :'p2e'::date + 2, now());
select set_config('ci.p2e', :'p2e', true) \gset x_
do $$ begin
  assert (select covered from public.bh_card_periods(current_setting('ci.hh')::uuid) where period_end = current_setting('ci.p2e')::date), 'a statement with other dates still covers the period';
end $$;
set local role authenticated;

-- a finished trip: a cash line ready to send, a ¥ line on the A$ card waiting for what the card charged
insert into public.trips (household_id, name, start_date, end_date, currency, currencies, countries)
values (:'hh', 'Kyoto', :'today'::date - 20, :'today'::date - 10, 'JPY', '{JPY,AUD}', '{JP}') returning id as trip \gset
insert into public.travel_expenses (household_id, trip_id, date, description, category, amount, currency, payment_method_id)
values (:'hh', :'trip', :'today'::date - 15, 'ferry', 'Ferry/Train', 18, 'AUD', :'cash'),
       (:'hh', :'trip', :'today'::date - 14, 'train pass', 'Ferry/Train', 1500, 'JPY', :'visa');
do $$ begin
  assert (pg_temp.todo('trips') ->> 'waiting')::int = 1, 'one card line waits for what the card charged';
  assert (pg_temp.todo('trips') ->> 'to_send')::int = 1, 'one line ready to send';
end $$;

-- the two ticks the database can't see; only the owner keeps the list
select public.setup_mark('invite', true) \gset x_
select public.setup_mark('signup_check', true) \gset x_
do $$ begin
  assert (pg_temp.todo('invite') ->> 'done')::boolean and (pg_temp.todo('signup_check') ->> 'done')::boolean, 'ticked';
end $$;
select public.setup_mark('signup_check', false) \gset x_
do $$ begin assert not (pg_temp.todo('signup_check') ->> 'done')::boolean, 'unticked'; end $$;

-- ── 3 · fund_explain adds up to fund_money, fund by fund ─────────────────
do $$
declare f record; x jsonb; a jsonb; m jsonb;
begin
  for f in select fund_id, balance, cash_balance, owed_on_cards from public.fund_money where household_id = current_setting('ci.hh')::uuid loop
    x := public.fund_explain(f.fund_id); a := x -> 'all'; m := x -> 'month';
    assert (x ->> 'available')::numeric = f.balance and (x ->> 'in_bank')::numeric = f.cash_balance and (x ->> 'owed_on_cards')::numeric = f.owed_on_cards,
           'fund_explain repeats fund_money';
    assert (a ->> 'money_in')::numeric - (a ->> 'moved_out')::numeric - (a ->> 'purchases')::numeric = f.balance,
           'all time: in − out − purchases = Available for ' || f.fund_id;
    assert (m ->> 'opening')::numeric + (m ->> 'money_in')::numeric - (m ->> 'moved_out')::numeric - (m ->> 'purchases')::numeric = f.balance,
           'this month: opening + in − out − purchases = Available for ' || f.fund_id;
  end loop;
  assert (select count(*) from public.fund_money where household_id = current_setting('ci.hh')::uuid and balance <> 0) >= 2, 'the check covered funds with money';
end $$;

-- ── 4 · a login invited to join can't start a household by mistake ───────
select public.create_member_invite(:'ben') as code \gset
reset role;
insert into auth.users (id, email, raw_user_meta_data) values ('5e5e5e5e-0000-4000-8000-000000000002', 'rp-paige@test.local', jsonb_build_object('invite', :'code'));
set local role authenticated;
select set_config('request.jwt.claim.sub', '5e5e5e5e-0000-4000-8000-000000000002', true) \gset x_
do $$
begin
  begin
    perform public.create_household_setup('CI-RP', 'Second house', array['Paige'], null, array['AU']);
    assert false, 'an invited login set up a household of its own';
  exception when raise_exception then
    assert sqlerrm like '%invited to join a household%', sqlerrm;
  end;
end $$;
select public.join_household(:'code') \gset x_
do $$
begin
  assert (select household_id from public.household_members where user_id = auth.uid()) = current_setting('ci.hh')::uuid, 'she joined the household instead';
  -- a member: no setup list, no ticks
  assert public.setup_todo() = '[]'::jsonb, 'a member gets no setup list';
  begin perform public.setup_mark('invite', true); assert false, 'a member ticked the list'; exception when insufficient_privilege then null; end;
  -- but she reads the checks and a fund's explanation, as the owner does
  assert (public.money_checks() -> 'cards') is not null, 'a member reads money_checks';
  assert public.fund_explain((select id from public.funds where household_id = current_setting('ci.hh')::uuid and name = 'Float')) is not null, 'a member reads fund_explain';
end $$;

-- ── 5 · outsiders and the public key ─────────────────────────────────────
select set_config('request.jwt.claim.sub', '5e5e5e5e-0000-4000-8000-000000000003', true) \gset x_
do $$
begin
  assert public.fund_explain((select id from public.funds where household_id = current_setting('ci.hh')::uuid limit 1)) is null, 'an outsider explains another household''s fund';
  assert not exists (select 1 from jsonb_array_elements(public.money_checks() -> 'cards') c where c ->> 'name' = 'Visa — Ana'), 'an outsider sees another household''s cards';
  assert not exists (select 1 from jsonb_array_elements(public.setup_todo()) e where (e ->> 'n')::int > 0 and e ->> 'key' = 'trips'), 'an outsider sees another household''s list';
end $$;
reset role;
do $$
begin
  assert not has_function_privilege('anon', 'public.setup_todo()', 'execute'), 'anon runs setup_todo';
  assert not has_function_privilege('anon', 'public.money_checks()', 'execute'), 'anon runs money_checks';
  assert not has_function_privilege('anon', 'public.fund_explain(uuid)', 'execute'), 'anon runs fund_explain';
  assert not has_function_privilege('anon', 'public.setup_mark(text, boolean)', 'execute'), 'anon runs setup_mark';
  assert not has_function_privilege('authenticated', 'public.bh_card_periods(uuid)', 'execute'), 'bh_card_periods is callable by a login';
  assert not has_function_privilege('authenticated', 'public.bh_household_invited_guard()', 'execute'), 'the guard is callable by a login';
  assert not has_column_privilege('authenticated', 'public.households', 'setup_done', 'update'), 'a login writes setup_done directly';
end $$;
rollback;
