-- What the card charged (v2 sprint 2, chunk 4): a purchase in another currency on a card counts at its settled
-- amount, or waits; the nightly money check runs clean on a fresh chain; sign-up needs a valid invite code.

\set ON_ERROR_STOP on
begin;
insert into public.beta_invites (code, max_uses, used_count) values ('CI-SET', 10, 0) on conflict do nothing;
insert into auth.users (id, email) values ('abababab-0000-4000-8000-000000000001', 'set-owner@test.local');
set local role authenticated;
select set_config('request.jwt.claim.sub', 'abababab-0000-4000-8000-000000000001', true);
select public.create_household_setup('CI-SET', 'Settled household', array['Ana'], null, array['AU', 'SG']) as hh \gset
select set_config('ci.hh', :'hh', true);
select public.bh_today(:'hh') as today \gset
select id as ana from public.profiles where household_id = :'hh' and display_name = 'Ana' \gset
insert into public.payment_methods (household_id, name, profile_id, kind, currency) values (:'hh', 'SG card', :'ana', 'credit_card', 'SGD') returning id as sgc \gset
select set_config('ci.sgc', :'sgc', true);
insert into public.trips (household_id, name, start_date, end_date, currency, currencies, countries)
values (:'hh', 'Tokyo', :'today', :'today', 'JPY', '{JPY}', '{JP}') returning id as trip \gset
insert into public.travel_expenses (household_id, trip_id, date, description, category, amount, currency, payer_profile_id, payment_method_id, paid_with)
values (:'hh', :'trip', :'today', 'ramen', 'Street Food', 2500, 'JPY', :'ana', :'sgc', 'SG card') returning id as ramen \gset
insert into public.travel_expenses (household_id, trip_id, date, description, category, amount, currency, payer_profile_id, payment_method_id, paid_with)
values (:'hh', :'trip', :'today', 'airport bus', 'Public Transport', 12, 'SGD', :'ana', :'sgc', 'SG card') returning id as bus \gset
select set_config('ci.ramen', :'ramen', true);
select set_config('ci.bus', :'bus', true);
insert into public.statements (household_id, payment_method_id, period_start, period_end)
values (:'hh', :'sgc', (:'today'::date) - 30, (:'today'::date) + 1) returning id as st \gset
select set_config('ci.st', :'st', true);

do $$
declare r record; ok boolean := false; v numeric;
begin
  -- yen are never added to dollars: the purchase waits for what the card charged
  select owed, unsettled into r from public.card_balances where payment_method_id = current_setting('ci.sgc')::uuid;
  assert r.owed = 12 and r.unsettled = 1, 'owed 12 with 1 waiting, got ' || r.owed || ' / ' || r.unsettled;
  -- a client can't write it directly
  update public.expenses set settled_amount = 999 where id = current_setting('ci.ramen')::uuid;
  select settled_amount into v from public.expenses where id = current_setting('ci.ramen')::uuid;
  assert v is null, 'a client wrote the settled amount directly';
  -- the Desk types it from the statement
  perform public.set_settled_amount(current_setting('ci.ramen')::uuid, 25.30);
  select owed, unsettled into r from public.card_balances where payment_method_id = current_setting('ci.sgc')::uuid;
  assert r.owed = 37.30 and r.unsettled = 0, 'owed 12 + 25.30 once settled, got ' || r.owed || ' / ' || r.unsettled;
  begin perform public.set_settled_amount(current_setting('ci.bus')::uuid, 12); exception when raise_exception then ok := true; end;
  assert ok, 'a settled amount on a purchase already in the card''s currency';
  ok := false;
  begin perform public.set_settled_amount(current_setting('ci.ramen')::uuid, -1); exception when raise_exception then ok := true; end;
  assert ok, 'a negative settled amount';
end $$;

-- ticked on the card's statement, it counts at the settled amount
select public.reconcile_rows('expense', array[:'ramen', :'bus']::uuid[], :'st');
do $$
declare v numeric; ok boolean := false;
begin
  select reconciled_total into v from public.statement_balances where statement_id = current_setting('ci.st')::uuid;
  assert v = 37.30, 'statement ticks 25.30 + 12, got ' || v;
  update public.statements set closed_at = now() where id = current_setting('ci.st')::uuid;
  begin perform public.set_settled_amount(current_setting('ci.ramen')::uuid, 26); exception when raise_exception then ok := true; end;
  assert ok, 'a settled amount changed on a closed statement';
end $$;

-- ── the nightly check runs clean on a fresh chain ───────────────────────
reset role;
do $$
declare v text; n int;
begin
  select count(*) into n from public.bh_money_check();
  assert n >= 10, 'the money check lists its checks, got ' || n;
  select string_agg(check_name || ' = ' || bad, '; ') into v from public.bh_money_check() where severity = 'fail' and bad > 0;
  assert v is null, 'failing money checks: ' || coalesce(v, '');
  assert not has_function_privilege('authenticated', 'public.bh_money_check()', 'execute'), 'a login can run the money check';
end $$;

-- ── sign-up needs a valid invite code ───────────────────────────────────
do $$
begin
  assert public.hook_before_user_created('{"user": {"email": "x@test.local", "user_metadata": {"invite": "ci-set"}}}') = '{}'::jsonb,
    'a valid invite code is let through';
  assert (public.hook_before_user_created('{"user": {"email": "x@test.local", "user_metadata": {"invite": "nope"}}}')->'error'->>'http_code') = '403',
    'a made-up code is refused';
  assert (public.hook_before_user_created('{"user": {"email": "x@test.local", "user_metadata": {}}}')->'error'->>'http_code') = '403',
    'no code is refused';
  assert not has_function_privilege('anon', 'public.hook_before_user_created(jsonb)', 'execute'), 'the public key can run the sign-up hook';
end $$;

rollback;
\echo what the card charged
