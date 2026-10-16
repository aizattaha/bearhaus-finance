-- The Desk's settings and dashboard: the money rule as of any date equals today's numbers today; fund_history gives
-- each month-end; the time zone is a household setting; a card's new owner drops defaults that no longer fit.

\set ON_ERROR_STOP on
begin;
set local timezone = 'UTC';
insert into public.beta_invites (code, max_uses, used_count) values ('CI-DASH', 10, 0) on conflict do nothing;
insert into auth.users (id, email) values ('dadadada-0000-4000-8000-000000000001', 'dash-owner@test.local'),
                                          ('dadadada-0000-4000-8000-000000000002', 'dash-viewer@test.local');
set local role authenticated;
select set_config('request.jwt.claim.sub', 'dadadada-0000-4000-8000-000000000001', true);
select public.create_household_setup('CI-DASH', 'Dashboard household', array['Ana', 'Ben'], 'Joint', array['AU']) as hh \gset
select set_config('ci.hh', :'hh', true);
select public.bh_today(:'hh') as today \gset
select date_trunc('month', :'today'::date)::date as m0 \gset
select set_config('ci.m0', :'m0', true);
select id as savau from public.funds where household_id = :'hh' and is_leftover_target limit 1 \gset
select id as floatau from public.funds where household_id = :'hh' and is_spend_pot limit 1 \gset
select set_config('ci.savau', :'savau', true);
select set_config('ci.floatau', :'floatau', true);
-- two months ago 1000 in, last month 200 out, this month 50 in
insert into public.fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin)
values (:'hh', :'savau', 'income', 'movement', (:'m0'::date - interval '2 months')::date + 3, 1000, 'opening', 'manual'),
       (:'hh', :'savau', 'expense', 'movement', (:'m0'::date - interval '1 month')::date + 5, 200, 'out', 'manual'),
       (:'hh', :'savau', 'income', 'movement', :'m0', 50, 'in', 'manual');

do $$
declare v numeric; n int; bad int;
begin
  -- the rule as of today is today's numbers, every column, every fund
  select count(*) into bad from public.fund_money a
    join public.fund_money_asof(public.bh_today(current_setting('ci.hh')::uuid)) b using (fund_id)
   where a.household_id = current_setting('ci.hh')::uuid
     and (a.balance, a.cleared_balance, a.pending_spend, a.cash_balance, a.owed_on_cards)
         is distinct from (b.balance, b.cleared_balance, b.pending_spend, b.cash_balance, b.owed_on_cards);
  assert bad = 0, 'fund_money_asof(today) differs from fund_money for ' || bad || ' funds';
  -- month by month
  select count(distinct month) into n from public.fund_history(3);
  assert n = 3, 'three months of history, got ' || n;
  select balance into v from public.fund_history(3) where fund_id = current_setting('ci.savau')::uuid and month = (current_setting('ci.m0')::date - interval '2 months')::date;
  assert v = 1000, 'two months ago: 1000, got ' || v;
  select balance into v from public.fund_history(3) where fund_id = current_setting('ci.savau')::uuid and month = (current_setting('ci.m0')::date - interval '1 month')::date;
  assert v = 800, 'last month-end: 800, got ' || v;
  select balance into v from public.fund_history(3) where fund_id = current_setting('ci.savau')::uuid and month = current_setting('ci.m0')::date;
  assert v = 850, 'this month so far: 850, got ' || v;
  select balance into v from public.fund_money where fund_id = current_setting('ci.savau')::uuid;
  assert v = 850, 'and that is today''s Available, got ' || v;
end $$;

-- the time zone is a household setting; a made-up one is refused
update public.households set timezone = 'Asia/Singapore' where id = :'hh';
do $$
declare ok boolean := false;
begin
  assert (select timezone from public.households where id = current_setting('ci.hh')::uuid) = 'Asia/Singapore', 'the owner changed the time zone';
  begin update public.households set timezone = 'Mars/Olympus' where id = current_setting('ci.hh')::uuid; exception when invalid_parameter_value then ok := true; end;
  assert ok, 'a made-up time zone was saved';
end $$;

-- a card that changes owner drops the defaults that no longer fit
select id as ana from public.profiles where household_id = :'hh' and display_name = 'Ana' \gset
select id as ben from public.profiles where household_id = :'hh' and display_name = 'Ben' \gset
insert into public.payment_methods (household_id, name, profile_id, kind, currency) values (:'hh', 'Visa', :'ana', 'credit_card', 'AUD') returning id as visa \gset
insert into public.card_defaults (household_id, profile_id, context, payment_method_id) values (:'hh', :'ana', 'daily', :'visa');
update public.payment_methods set profile_id = :'ben' where id = :'visa';
do $$ begin
  assert not exists (select 1 from public.card_defaults where household_id = current_setting('ci.hh')::uuid), 'Ana''s default stayed on a card that is now Ben''s';
end $$;

-- a viewer reads the history but can't change the time zone
select public.create_member_invite(null, 'viewer') as vcode \gset
select set_config('request.jwt.claim.sub', 'dadadada-0000-4000-8000-000000000002', true);
select public.join_household(:'vcode');
do $$
declare n int; m int;
begin
  select count(*) into n from public.fund_history(2);
  assert n > 0, 'a viewer sees the history';
  update public.households set timezone = 'Australia/Perth' where id = current_setting('ci.hh')::uuid;
  get diagnostics m = row_count;
  assert m = 0, 'a viewer changed the time zone';
end $$;

rollback;
\echo dashboard numbers hold
