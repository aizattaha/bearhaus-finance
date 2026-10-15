-- The server keeps the rules (v2 sprint 2, chunk 3): transfers written whole and checked at commit; the month
-- plan applied once, on the server; past months left alone; "Payment" locked as the settle-up category; a fund
-- row's kind as the app says. Invariants 1, 7–9, 19 (DB-1 §5).

\set ON_ERROR_STOP on
begin;
insert into public.beta_invites (code, max_uses, used_count) values ('CI-SRV', 10, 0) on conflict do nothing;
insert into auth.users (id, email) values ('eeeeeeee-0000-4000-8000-000000000001', 'srv-owner@test.local'),
                                          ('eeeeeeee-0000-4000-8000-000000000002', 'srv-viewer@test.local');
set local role authenticated;
select set_config('request.jwt.claim.sub', 'eeeeeeee-0000-4000-8000-000000000001', true);
select public.create_household_setup('CI-SRV', 'Rules household', array['Ana', 'Ben'], 'Joint', array['AU', 'SG']) as hh \gset
select set_config('ci.hh', :'hh', true);
select public.bh_today(:'hh') as today \gset
select date_trunc('month', :'today'::date)::date as month \gset
select set_config('ci.today', :'today', true);
select set_config('ci.month', :'month', true);
select id as floatau from public.funds where household_id = :'hh' and name = 'Float AU' \gset
select id as savau from public.funds where household_id = :'hh' and name = 'Savings AU' \gset
select id as emerg from public.funds where household_id = :'hh' and name = 'Emergency fund AU' \gset
select id as trav from public.funds where household_id = :'hh' and name = 'Travel fund AU' \gset
select id as floatsg from public.funds where household_id = :'hh' and name = 'Float SG' \gset
select set_config('ci.floatau', :'floatau', true);
select set_config('ci.savau', :'savau', true);
select set_config('ci.emerg', :'emerg', true);
select set_config('ci.trav', :'trav', true);
select set_config('ci.floatsg', :'floatsg', true);
insert into public.fund_transactions (household_id, fund_id, type, date, amount, remarks, origin)
values (:'hh', :'floatau', 'income', :'today', 1000, 'opening', 'manual');

-- ── 1 · transfers are written whole ──────────────────────────────────────
select public.record_transfer(:'floatau', :'emerg', :'today', 100, null, 'top-up', 'eeeeeeee-0000-4000-8000-0000000000a1') as g1 \gset
select set_config('ci.g1', :'g1', true);
do $$
declare v numeric; n int; ok boolean := false;
begin
  select count(*) into n from public.fund_transactions where transfer_group_id = current_setting('ci.g1')::uuid;
  assert n = 2, 'a transfer is two rows, got ' || n;
  select balance into v from public.fund_balances where fund_id = current_setting('ci.floatau')::uuid; assert v = 900, 'Float AU 900, got ' || v;
  select balance into v from public.fund_balances where fund_id = current_setting('ci.emerg')::uuid;   assert v = 100, 'Emergency 100, got ' || v;
  -- a retap with the same id is the same transfer, not a second one
  assert public.record_transfer(current_setting('ci.floatau')::uuid, current_setting('ci.emerg')::uuid, current_setting('ci.today')::date, 100, null, 'top-up',
                                'eeeeeeee-0000-4000-8000-0000000000a1') = current_setting('ci.g1')::uuid, 'a retap returns the saved transfer';
  select count(*) into n from public.fund_transactions where transfer_group_id = current_setting('ci.g1')::uuid;
  assert n = 2, 'a retap wrote again, got ' || n || ' rows';
  -- across currencies: the received amount stands
  perform public.record_transfer(current_setting('ci.floatau')::uuid, current_setting('ci.floatsg')::uuid, current_setting('ci.today')::date, 100, 90);
  select balance into v from public.fund_balances where fund_id = current_setting('ci.floatsg')::uuid; assert v = 90, 'Float SG received 90, got ' || v;
  -- the same currency moves the same amount
  begin perform public.record_transfer(current_setting('ci.floatau')::uuid, current_setting('ci.emerg')::uuid, current_setting('ci.today')::date, 100, 90);
  exception when raise_exception then ok := true; end;
  assert ok, 'an A$ → A$ transfer with two amounts was saved';
  ok := false;
  begin perform public.record_transfer(current_setting('ci.floatau')::uuid, current_setting('ci.floatau')::uuid, current_setting('ci.today')::date, 5);
  exception when raise_exception then ok := true; end;
  assert ok, 'a transfer to the same fund was saved';
end $$;

-- the commit-time check notes a group that stops balancing (log-only this release)
reset role;
set constraints public.zz_fund_group_check immediate;   -- check at each statement: this test never commits
update public.fund_transactions_all set amount = 99 where transfer_group_id = :'g1' and type = 'income';
do $$
declare s text;
begin
  select detail into s from public.integrity_issues where ref_id = current_setting('ci.g1')::uuid;
  assert s = 'transfer sides differ', 'the broken transfer was noted, got ' || coalesce(s, 'nothing');
end $$;
update public.fund_transactions_all set amount = 100 where transfer_group_id = :'g1' and type = 'income';
set constraints public.zz_fund_group_check deferred;
set local role authenticated;

-- ── 2 · the month plan: applied once, on the server ─────────────────────
select version as v0 from public.plan_status(:'month') \gset
select public.save_month_plan(:'month',
  '[{"source_name": "Salary", "currency": "AUD", "amount": 5000}]',
  '[{"category_group": "Daily Expenses", "currency": "AUD", "amount": 800}]',
  jsonb_build_array(jsonb_build_object('fund_id', :'emerg', 'amount', 300), jsonb_build_object('fund_id', :'trav', 'amount', 200)),
  :'v0');
select set_config('ci.v0', :'v0', true);
do $$
declare r record; ok boolean := false; j jsonb; v numeric; n int;
begin
  -- a save over a version it didn't start from is refused
  begin perform public.save_month_plan(current_setting('ci.month')::date, '[]', '[]', '[]', current_setting('ci.v0'));
  exception when raise_exception then ok := true; end;
  assert ok, 'a stale plan save overwrote the newer plan';
  select * into r from public.plan_status(current_setting('ci.month')::date);
  assert r.saved and r.applied_on is null, 'saved, not applied yet';
  -- apply, skipping the travel fund this month
  j := public.apply_month_plan(current_setting('ci.month')::date, array[current_setting('ci.trav')::uuid]);
  assert (j->>'contributions')::int = 1 and (j->>'leftover')::boolean and j->>'pots' = 'Float AU', 'apply summary: ' || j::text;
  select count(*) into n from public.fund_transactions where household_id = current_setting('ci.hh')::uuid and origin = 'planned';
  assert n = 3, 'three plan rows (contribution, leftover, budget), got ' || n;
  select amount into v from public.fund_transactions where fund_id = current_setting('ci.emerg')::uuid and origin = 'planned'; assert v = 300, 'Emergency +300, got ' || v;
  select amount into v from public.fund_transactions where fund_id = current_setting('ci.savau')::uuid and origin = 'planned';  assert v = 3900, 'leftover 5000 − 800 − 300 = 3900, got ' || v;
  select amount into v from public.fund_transactions where fund_id = current_setting('ci.floatau')::uuid and origin = 'planned'; assert v = 800, 'spending budget 800 in Float AU, got ' || v;
  select count(*) into n from public.fund_transactions where fund_id = current_setting('ci.trav')::uuid and origin = 'planned'; assert n = 0, 'the skipped fund got nothing';
  select * into r from public.plan_status(current_setting('ci.month')::date);
  assert r.applied_on = current_setting('ci.today')::date, 'plan_status says applied today';
  -- once only
  ok := false;
  begin perform public.apply_month_plan(current_setting('ci.month')::date); exception when raise_exception then ok := true; end;
  assert ok, 'the plan was applied twice';
  -- not before the month starts
  ok := false;
  begin perform public.apply_month_plan((current_setting('ci.month')::date + interval '1 month')::date); exception when raise_exception then ok := true; end;
  assert ok, 'next month''s plan was applied early';
  -- and not by an app writing plan rows itself
  ok := false;
  begin
    insert into public.fund_transactions (household_id, fund_id, type, date, amount, remarks, origin)
    values (current_setting('ci.hh')::uuid, current_setting('ci.emerg')::uuid, 'income', current_date, 1, 'October plan', 'planned');
  exception when raise_exception then ok := true; end;
  assert ok, 'an app wrote a plan row';
end $$;

-- ── 3 · past months stay put ─────────────────────────────────────────────
reset role;
update public.households set pot_start = (:'month'::date - interval '2 months')::date where id = :'hh';
set local role authenticated;
insert into public.daily_expenses (household_id, date, description, category, amount, currency, paid_with)
values (:'hh', (:'month'::date) - 10, 'old lunch', 'Dining out', 20, 'AUD', ''),
       (:'hh', :'today', 'new lunch', 'Dining out', 30, 'AUD', '');
insert into public.funds (household_id, name, country, currency, is_spend_pot, sort_order) values (:'hh', 'Float 2', 'AU', 'AUD', true, -1) returning id as float2 \gset
select set_config('ci.float2', :'float2', true);
do $$
declare v uuid; ok boolean := false;
begin
  select pot_fund_id into v from public.expenses where description = 'old lunch' and household_id = current_setting('ci.hh')::uuid;
  assert v = current_setting('ci.floatau')::uuid, 'a new first pot left last month''s purchase where it was';
  select pot_fund_id into v from public.expenses where description = 'new lunch' and household_id = current_setting('ci.hh')::uuid;
  assert v = current_setting('ci.float2')::uuid, 'this month''s purchase moved to the new first pot';
  begin update public.funds set is_spend_pot = false where id = current_setting('ci.floatau')::uuid; exception when raise_exception then ok := true; end;
  assert ok, 'a pot holding past purchases stopped being a pot';
  ok := false;
  begin update public.funds set currency = 'SGD' where id = current_setting('ci.floatau')::uuid; exception when raise_exception then ok := true; end;
  assert ok, 'a fund with money in it changed currency';
  ok := false;
  begin perform public.save_month_plan(current_setting('ci.month')::date, '[]',
          jsonb_build_array(jsonb_build_object('category_group', 'Daily Expenses', 'currency', 'AUD', 'amount', 10, 'pot_fund_id', current_setting('ci.emerg'))), '[]');
  exception when raise_exception then ok := true; end;
  assert ok, 'a budget line landed in a fund that isn''t a spending pot';
  ok := false;
  begin update public.households set pot_start = current_date where id = current_setting('ci.hh')::uuid;
  exception when raise_exception or insufficient_privilege then ok := true; end;   -- the column isn't granted; the trigger is the second lock
  assert ok, 'the start date moved';
end $$;

-- ── 4 · "Payment" is the settle-up category ─────────────────────────────
do $$
declare ok boolean := false; n int;
begin
  select count(*) into n from public.categories where household_id = current_setting('ci.hh')::uuid and name = 'Payment' and role = 'settle_up';
  assert n = 1, 'a new household''s Payment category is the settle-up one';
  begin update public.categories set name = 'Settle up' where household_id = current_setting('ci.hh')::uuid and role = 'settle_up'; exception when raise_exception then ok := true; end;
  assert ok, 'Payment was renamed';
  ok := false;
  begin update public.categories set is_active = false where household_id = current_setting('ci.hh')::uuid and role = 'settle_up'; exception when raise_exception then ok := true; end;
  assert ok, 'Payment was hidden';
  ok := false;
  begin delete from public.categories where household_id = current_setting('ci.hh')::uuid and role = 'settle_up'; exception when raise_exception then ok := true; end;
  assert ok, 'Payment was deleted';
end $$;

-- ── 5 · a fund row's kind is what the app says ──────────────────────────
do $$
declare k text; ok boolean := false;
begin
  insert into public.fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin, income_source)
  values (current_setting('ci.hh')::uuid, current_setting('ci.trav')::uuid, 'income', 'movement', current_date, 40, 'Travel: refund', 'manual', 'Travel: refund')
  returning kind into k;
  assert k = 'movement', 'an income called "Travel: refund" stays a movement, got ' || k;
  insert into public.fund_transactions (household_id, fund_id, type, date, amount, remarks, origin)
  values (current_setting('ci.hh')::uuid, current_setting('ci.trav')::uuid, 'expense', current_date, 1, 'Transfer → somewhere', 'manual')
  returning kind into k;
  assert k = 'allocation', 'an older app''s transfer row is still worked out from its remark, got ' || k;
  begin
    insert into public.fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin)
    values (current_setting('ci.hh')::uuid, current_setting('ci.trav')::uuid, 'expense', 'card_payment', current_date, 1, 'x', 'manual');
  exception when raise_exception then ok := true; end;
  assert ok, 'an app wrote a card payment row directly';
  perform updated_at from public.fund_transactions limit 1;   -- edits can check it
end $$;

-- ── a viewer can't move money or apply a plan ───────────────────────────
select public.create_member_invite(null, 'viewer') as vcode \gset
select set_config('request.jwt.claim.sub', 'eeeeeeee-0000-4000-8000-000000000002', true);
select public.join_household(:'vcode');
do $$
declare ok boolean := false;
begin
  begin perform public.record_transfer(current_setting('ci.floatau')::uuid, current_setting('ci.emerg')::uuid, current_date, 1); exception when insufficient_privilege then ok := true; end;
  assert ok, 'a viewer made a transfer';
  ok := false;
  begin perform public.apply_month_plan(current_setting('ci.month')::date); exception when insufficient_privilege then ok := true; end;
  assert ok, 'a viewer applied a plan';
end $$;

rollback;
\echo the server keeps the rules
