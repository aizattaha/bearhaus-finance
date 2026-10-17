-- Safety net (Review Board round 1, Bundle B — DECISIONS E37):
--   B1 · each run leaves a heartbeat row; the owner's Dashboard line goes stale after 36 h (check) / 8 days (backup)
--   B2 · a 'warn' count that rises since the last stored run is flagged (the workflow fails on it); the new lines
--        see what they should (another card's statement, card payment to a non-credit card, settled trip card
--        lines with no send, the takeover signals)
--   B3 · bh_monitor runs exactly bh_money_check_run and bh_backup_done, and reads nothing

\set ON_ERROR_STOP on
begin;
insert into public.beta_invites (code, max_uses, used_count) values ('CI-SAFE', 10, 0) on conflict do nothing;
insert into auth.users (id, email) values ('dededede-0000-4000-8000-000000000001', 'safe-owner@test.local'),
                                          ('dededede-0000-4000-8000-000000000002', 'safe-member@test.local');
set local role authenticated;
select set_config('request.jwt.claim.sub', 'dededede-0000-4000-8000-000000000001', true) \gset x_
select public.create_household_setup('CI-SAFE', 'Safe house', array['Ana', 'Ben'], 'Joint', array['AU']) as hh \gset
select public.bh_today(:'hh') as today \gset
select id as ana from public.profiles where household_id = :'hh' and display_name = 'Ana' \gset
select id as pot from public.funds where household_id = :'hh' and is_spend_pot \gset
select id as cash from public.payment_methods where household_id = :'hh' and kind = 'cash' \gset
insert into public.payment_methods (household_id, name, profile_id, kind, currency) values (:'hh', 'Visa — Ana', :'ana', 'credit_card', 'AUD') returning id as visa \gset
select public.create_member_invite((select id from public.profiles where household_id = :'hh' and display_name = 'Ben')) as code \gset
select set_config('request.jwt.claim.sub', 'dededede-0000-4000-8000-000000000002', true) \gset x_
select public.join_household(:'code') \gset x_
reset role;
select set_config('ci.hh', :'hh', true) \gset x_

-- ── B3 · the catalog: what bh_monitor and the app logins may do ─────────
do $$
declare v text; r record;
begin
  select rolsuper, rolcreaterole, rolcreatedb, rolbypassrls, rolinherit into r from pg_roles where rolname = 'bh_monitor';
  assert found, 'bh_monitor is missing';
  assert not (r.rolsuper or r.rolcreaterole or r.rolcreatedb or r.rolbypassrls or r.rolinherit), 'bh_monitor has more than it needs';
  select string_agg(p.oid::regprocedure::text, ', ' order by p.proname) into v from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and has_function_privilege('bh_monitor', p.oid, 'execute');
  assert v = 'bh_backup_done(text,integer), bh_money_check_run(text)', 'bh_monitor runs: ' || coalesce(v, 'nothing');
  select string_agg(c.relname, ', ') into v from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm')
     and has_table_privilege('bh_monitor', c.oid, 'select, insert, update, delete, truncate');
  assert v is null, 'bh_monitor has rights on: ' || coalesce(v, '');
  assert not has_schema_privilege('bh_monitor', 'public', 'create'), 'bh_monitor can create in public';
  -- the run log and the fixes log are the server's; the Dashboard line is for logins (owners get a row)
  foreach v in array array['ops_runs', 'data_fixes_applied'] loop
    assert not has_table_privilege('authenticated', 'public.' || v, 'select, insert, update, delete'), 'a login can touch ' || v;
    assert not has_table_privilege('anon', 'public.' || v, 'select, insert, update, delete'), 'the public key can touch ' || v;
  end loop;
  assert has_function_privilege('authenticated', 'public.ops_heartbeat()', 'execute'), 'a login can''t read the heartbeat';
  assert not has_function_privilege('anon', 'public.ops_heartbeat()', 'execute'), 'the public key can read the heartbeat';
  assert not has_function_privilege('authenticated', 'public.bh_money_check_run(text)', 'execute'), 'a login can run the check';
  assert not has_function_privilege('authenticated', 'public.bh_backup_done(text, integer)', 'execute'), 'a login can fake a backup';
  -- the dead line is gone
  assert not exists (select 1 from public.bh_money_check() where check_name ilike '%integrity%'), 'the integrity_issues line is still there';
end $$;

-- ── B3 · as bh_monitor: a run is stored, nothing else is reachable ───────
-- (on Supabase postgres isn't a superuser: it may act as the role it made once it grants it to itself — undone below)
do $$ begin
  if not pg_has_role(current_user, 'bh_monitor', 'set') then execute format('grant bh_monitor to %I', current_user); end if;
end $$;
set local role bh_monitor;
select count(*) as lines1 from public.bh_money_check_run('test') \gset
select public.bh_backup_done('test', 700) \gset x_
do $$
declare ok boolean;
begin
  ok := false; begin perform count(*) from public.expenses; exception when insufficient_privilege then ok := true; end;
  assert ok, 'bh_monitor could read purchases';
  ok := false; begin perform count(*) from public.ops_runs; exception when insufficient_privilege then ok := true; end;
  assert ok, 'bh_monitor could read the run log';
  ok := false; begin perform count(*) from public.bh_money_check(); exception when insufficient_privilege then ok := true; end;
  assert ok, 'bh_monitor could run the bare check';
  ok := false; begin perform count(*) from public.ops_heartbeat(); exception when insufficient_privilege then ok := true; end;
  assert ok, 'bh_monitor could read the heartbeat';
  ok := false; begin perform count(*) from public.household_money(); exception when insufficient_privilege then ok := true; end;
  assert ok, 'bh_monitor could read the funds';
  ok := false; begin perform public.bh_money_check_run('nightly'); exception when invalid_parameter_value then ok := true; end;
  assert ok, 'an unknown source was stored';
  ok := false; begin perform public.bh_backup_done('manual', 0); exception when invalid_parameter_value then ok := true; end;
  assert ok, 'an empty backup was recorded';
end $$;
reset role;
do $$
declare r record;
begin
  select count(*) filter (where kind = 'money_check') as c, count(*) filter (where kind = 'backup') as b,
         max(kb) as kb, bool_and(source = 'test') as src into r from public.ops_runs;
  assert r.c = 1 and r.b = 1 and r.kb = 700 and r.src, format('run log: %s checks, %s backups', r.c, r.b);
  assert (select jsonb_array_length(lines) from public.ops_runs where kind = 'money_check') = (select count(*) from public.bh_money_check()),
         'the stored run has every line';
end $$;

-- ── B2 · the new lines see what they should ──────────────────────────────
-- a statement for the Visa, a cash purchase ticked onto it (a row on another card's statement)
insert into public.statements (household_id, payment_method_id, period_start, period_end)
values (:'hh', :'visa', :'today'::date - 30, :'today') returning id as stmt \gset
insert into public.daily_expenses (household_id, date, description, category, amount, currency, payer_profile_id, payment_method_id, paid_with)
values (:'hh', :'today', 'market', 'Groceries', 20, 'AUD', :'ana', :'cash', 'Cash') returning id as e1 \gset
-- a card payment "to" the cash card is refused at the door (the check's second half guards older rows)
do $$
declare ok boolean := false;
begin
  begin
    insert into public.fund_transactions_all (household_id, fund_id, date, type, amount, kind, settles_payment_method_id, transfer_group_id, remarks)
    select current_setting('ci.hh')::uuid, f.id, current_date, 'expense', 15, 'card_payment', pm.id, gen_random_uuid(), 'Card payment — test'
      from public.funds f, public.payment_methods pm
     where f.household_id = current_setting('ci.hh')::uuid and f.is_spend_pot and pm.household_id = f.household_id and pm.kind = 'cash';
  exception when others then ok := true; end;
  assert ok, 'a card payment to a cash card was saved';
end $$;
-- a trip purchase on the Visa, to be marked settled with no send
insert into public.trips (household_id, name, start_date, end_date, currency, currencies, countries)
values (:'hh', 'Hobart', :'today', :'today', 'AUD', '{AUD}', '{AU}') returning id as trip \gset
select id as tcat from public.categories where household_id = :'hh' and kind = 'travel' order by sort_order limit 1 \gset
insert into public.travel_expenses (household_id, trip_id, date, description, category_id, amount, currency, payer_profile_id, payment_method_id, paid_with)
values (:'hh', :'trip', :'today', 'ferry', :'tcat', 40, 'AUD', :'ana', :'visa', 'Visa — Ana') returning id as t1 \gset
create temp table _before on commit drop as select * from public.bh_money_check();
-- as a server path that forgot to check the card would
select set_config('bh.via_rpc', 'on', true) \gset x_
update public.daily_expenses set reconciled_at = now(), reconciled_by = 'manual', reconciled_statement_id = :'stmt' where id = :'e1';
select set_config('bh.via_rpc', 'off', true) \gset x_
update public.travel_expenses set sent_to_fund = true where id = :'t1';
-- takeover signals: a login, a password reset asked for, an owner change
insert into auth.users (id, email, created_at) values ('dededede-0000-4000-8000-000000000003', 'safe-new@test.local', now());   -- GoTrue stamps it
update auth.users set recovery_sent_at = now() where id = 'dededede-0000-4000-8000-000000000002';
update public.households set owner_user_id = 'dededede-0000-4000-8000-000000000002' where id = :'hh';
do $$
declare d record; msg text := '';
begin
  for d in select a.check_name, a.bad - b.bad as diff from public.bh_money_check() a join _before b using (check_name) loop
    if d.check_name like 'card rows on another card%' and d.diff <> 1 then msg := msg || ' another-card statement +' || d.diff; end if;
    if d.check_name like 'trip card lines marked settled%' and d.diff <> 1 then msg := msg || ' settled with no send +' || d.diff; end if;
    if d.check_name = 'takeover? logins created in the last day' and d.diff <> 1 then msg := msg || ' logins +' || d.diff; end if;
    if d.check_name like 'takeover? password resets%' and d.diff <> 1 then msg := msg || ' resets +' || d.diff; end if;
    if d.check_name like 'takeover? household owner changed%' and d.diff <> 1 then msg := msg || ' owner +' || d.diff; end if;
  end loop;
  assert msg = '', 'new lines miscounted:' || msg;
  -- the household made today: its members and its invite are counted
  assert (select bad from _before where check_name like 'takeover? household members%') >= 2, 'new members aren''t seen';
  assert (select bad from _before where check_name like 'takeover? invites%') >= 1, 'a new invite isn''t seen';
end $$;

-- ── B2 · a rise is flagged once; the next run with nothing new isn't ─────
create temp table _r2 on commit drop as select * from public.bh_money_check_run('test');
create temp table _r3 on commit drop as select * from public.bh_money_check_run('test');
do $$
declare v text;
begin
  assert (select rose from _r2 where check_name = 'takeover? logins created in the last day'), 'a new login didn''t rise';
  assert (select previous from _r2 where check_name = 'takeover? logins created in the last day')
         = (select bad from _r2 where check_name = 'takeover? logins created in the last day') - 1, 'previous isn''t the last run''s count';
  assert not exists (select 1 from _r2 where rose and severity <> 'warn'), 'a fail or info line was flagged as a rise';
  select string_agg(check_name, ', ') into v from _r3 where rose;
  assert v is null, 'unchanged lines flagged again: ' || coalesce(v, '');
  assert (select rises from public.ops_runs where kind = 'money_check' order by id desc offset 1 limit 1) = 4, 'the stored run lost its rises';
  assert (select rises from public.ops_runs where kind = 'money_check' order by id desc limit 1) = 0, 'the last stored run has rises';
end $$;

-- ── B1 · the Dashboard line ──────────────────────────────────────────────
set local role authenticated;
-- the owner by membership (the direct owner_user_id write above was the takeover drill)
select set_config('request.jwt.claim.sub', 'dededede-0000-4000-8000-000000000001', true) \gset x_
do $$
declare h record;
begin
  select * into h from public.ops_heartbeat();
  assert found, 'the owner gets no heartbeat';
  assert h.check_state = 'look' and h.check_warns > 0 and h.check_rises = 0 and h.check_fails = 0, 'check state ' || h.check_state;
  assert jsonb_array_length(h.check_lines) = h.check_warns, 'the lines to look at aren''t listed';
  assert h.backup_state = 'ok' and h.backup_kb = 700, 'backup state ' || h.backup_state;
end $$;
select set_config('request.jwt.claim.sub', 'dededede-0000-4000-8000-000000000002', true) \gset x_
do $$ begin assert not exists (select 1 from public.ops_heartbeat()), 'a member sees the heartbeat'; end $$;
reset role;

-- stale after 36 h (check); late after 50 h, stale after 8 days (backup); never when nothing ran
update public.ops_runs set ran_at = ran_at - interval '37 hours' where kind = 'money_check';
update public.ops_runs set ran_at = ran_at - interval '3 days' where kind = 'backup';
set local role authenticated;
select set_config('request.jwt.claim.sub', 'dededede-0000-4000-8000-000000000001', true) \gset x_
do $$ declare h record; begin
  select * into h from public.ops_heartbeat();
  assert h.check_state = 'stale' and h.backup_state = 'late', format('after 37 h / 3 days: %s / %s', h.check_state, h.backup_state);
end $$;
reset role;
update public.ops_runs set ran_at = ran_at - interval '6 days' where kind = 'backup';
insert into public.ops_runs (kind, source, fails, warns, rises, lines) values ('money_check', 'test', 1, 0, 0, '[]');
set local role authenticated;
do $$ declare h record; begin
  select * into h from public.ops_heartbeat();
  assert h.check_state = 'fail' and h.backup_state = 'stale', format('a failed run / 9 days: %s / %s', h.check_state, h.backup_state);
end $$;
reset role;
delete from public.ops_runs;
set local role authenticated;
do $$ declare h record; begin
  select * into h from public.ops_heartbeat();
  assert h.check_state = 'never' and h.backup_state = 'never' and h.check_lines = '[]'::jsonb, 'with nothing run: ' || h.check_state;
end $$;
reset role;

rollback;
\echo safety net holds
