-- Speed with many households (v2 sprint 3; D2-9/D2-10): row-level security that uses an index, and each screen's
-- query inside its budget. CI runs a small copy (20 households × 2,500 purchases); the plan's full budget run
-- (100 households × 50,000 purchases) is the same file with three settings, on a scratch database (keep=true leaves
-- the seed in place and vacuums it, the steady state of a live database):
--   psql <scratch-db-url> -v households=100 -v purchases=50000 -v keep=true -f tools/sql-tests/test_perf.sql
-- Times are printed (NOTICE) and asserted; every money number here is made up.

\set ON_ERROR_STOP on
\if :{?households}
\else
  \set households 20
\endif
\if :{?purchases}
\else
  \set purchases 2500
\endif
\if :{?keep}
\else
  \set keep false
\endif
set client_min_messages = notice;
begin;
select set_config('ci.n_hh', :'households', true) \gset x_
select set_config('ci.n_exp', :'purchases', true) \gset x_

-- ── many households, made the normal way ────────────────────────────────
insert into public.beta_invites (code, max_uses, used_count) values ('CI-PERF', 100000, 0) on conflict do nothing;
insert into auth.users (id, email)
select format('%s-0000-4000-8000-0000000000fe', lpad(to_hex(i), 8, '0'))::uuid, 'perf' || i || '@test.local' from generate_series(1, :households) i;
do $$
declare i int;
begin
  for i in 1 .. current_setting('ci.n_hh')::int loop
    perform set_config('request.jwt.claim.sub', format('%s-0000-4000-8000-0000000000fe', lpad(to_hex(i), 8, '0')), true);
    perform public.create_household_setup('CI-PERF', 'Perf house ' || i, array['Ana', 'Ben'], 'Joint', array['AU', 'SG']);
  end loop;
end $$;
-- each household gets a credit card and a statement
insert into public.payment_methods (household_id, name, kind, currency, closing_day)
select id, 'Perf Visa', 'credit_card', 'AUD', 2 from public.households where name like 'Perf house %';
insert into public.statements (household_id, payment_method_id, period_start, period_end, label)
select pm.household_id, pm.id, current_date - 60, current_date - 30, 'perf' from public.payment_methods pm where pm.name = 'Perf Visa';

-- purchases and fund rows in bulk (triggers off: the stamps are filled in here the way the triggers would)
set session_replication_role = replica;
create temp table _hh on commit drop as
select h.id,
       (select array_agg(c.id order by c.sort_order) from public.categories c where c.household_id = h.id and c.kind = 'daily' and c.role is null) as cats,
       (select array_agg(c.name order by c.sort_order) from public.categories c where c.household_id = h.id and c.kind = 'daily' and c.role is null) as names,
       (select pm.id from public.payment_methods pm where pm.household_id = h.id and pm.name = 'Perf Visa') as visa,
       (select pm.id from public.payment_methods pm where pm.household_id = h.id and pm.kind = 'cash') as cash,
       (select s.id from public.statements s where s.household_id = h.id) as stmt,
       (select f.id from public.funds f where f.household_id = h.id and f.is_spend_pot and f.currency = 'AUD') as pot,
       (select f.id from public.funds f where f.household_id = h.id and f.is_leftover_target and f.currency = 'AUD') as sav
  from public.households h where h.name like 'Perf house %';
update public.households set pot_start = current_date - 400 where name like 'Perf house %';
insert into public.expenses (household_id, date, description, category, category_id, amount, currency, payment_method_id, paid_with,
                             pot_fund_id, created_at, updated_at, reconciled_at, reconciled_by, reconciled_statement_id)
select h.id, current_date - (i % 400), 'purchase ' || i,
       h.names[1 + i % array_length(h.cats, 1)], h.cats[1 + i % array_length(h.cats, 1)],
       ((i * 37) % 9000) / 100.0 + 1, 'AUD',
       case when i % 3 = 0 then h.cash else h.visa end, case when i % 3 = 0 then 'Cash' else 'Perf Visa' end,
       h.pot, now(), now(),
       case when i % 3 <> 0 and i % 400 between 30 and 60 then now() end,
       case when i % 3 <> 0 and i % 400 between 30 and 60 then 'manual' end,
       case when i % 3 <> 0 and i % 400 between 30 and 60 then h.stmt end
  from _hh h cross join generate_series(1, :purchases) i;
insert into public.fund_transactions_all (household_id, fund_id, type, kind, date, amount, remarks, origin, account_payment_method_id, created_at, updated_at)
select h.id, case when i % 2 = 0 then h.pot else h.sav end, case when i % 5 = 0 then 'expense' else 'income' end, 'movement',
       current_date - (i % 400), ((i * 53) % 50000) / 100.0 + 1, 'perf row ' || i, 'manual',
       case when i % 10 = 5 then h.visa end, now(), now()
  from _hh h cross join generate_series(1, greatest(:purchases / 5, 10)) i;
set session_replication_role = origin;
analyze public.expenses; analyze public.fund_transactions_all; analyze public.funds; analyze public.households;
analyze public.payment_methods; analyze public.categories; analyze public.audit_log; analyze public.statements; analyze public.household_members;
\if :keep
commit;
vacuum analyze public.expenses;
vacuum analyze public.fund_transactions_all;
begin;
select set_config('ci.n_hh', :'households', true) \gset x_
select set_config('ci.n_exp', :'purchases', true) \gset x_
create temp table _hh as
select h.id,
       (select array_agg(c.id order by c.sort_order) from public.categories c where c.household_id = h.id and c.kind = 'daily' and c.role is null) as cats,
       (select pm.id from public.payment_methods pm where pm.household_id = h.id and pm.name = 'Perf Visa') as visa,
       (select s.id from public.statements s where s.household_id = h.id) as stmt
  from public.households h where h.name like 'Perf house %';
\endif

-- ── the screens, as the first household's owner ─────────────────────────
select id as hh1 from public.households where name = 'Perf house 1' \gset
select set_config('ci.hh1', :'hh1', true) \gset x_
select set_config('ci.stmt1', (select stmt::text from _hh where id = :'hh1'), true) \gset x_
grant select on _hh to authenticated;
set local role authenticated;
select set_config('request.jwt.claim.sub', '00000001-0000-4000-8000-0000000000fe', true) \gset x_
do $$
declare
  s text := ''; r record; t numeric; j json; v_month date := date_trunc('month', public.bh_today(current_setting('ci.hh1')::uuid))::date;
  q text; budget numeric; ok boolean := true; report text := '';
begin
  -- row-level security becomes an index condition, not a filter over every household's rows
  for r in execute 'explain select id from public.expenses order by date desc limit 300' loop s := s || r."QUERY PLAN" || E'\n'; end loop;
  assert s ~ 'Index Cond: \(household_id = ANY', 'the history query does not use the household index:' || E'\n' || s;
  s := '';
  -- the Desk's Activity page names its household (an explicit filter keeps the newest-first order in the index)
  for r in execute format('explain select id from public.audit_log where household_id = %L order by id desc limit 50', current_setting('ci.hh1'))
  loop s := s || r."QUERY PLAN" || E'\n'; end loop;
  assert s ~ 'on audit_log_hh_(id|at)', 'Activity does not use a household index:' || E'\n' || s;

  -- budgets (ms) from the v2 plan; each query runs twice and the second (warm) run counts
  for q, budget in values
      ('select * from public.household_money()', 100),
      ('select * from public.fund_cash', 100),
      ('select public.budget_summary(''' || v_month || ''', ''AUD'', 6)', 150),
      ('select public.home_summary()', 100),
      ('select public.app_bootstrap()', 150),
      ('select * from public.statement_balances where statement_id = ''' || current_setting('ci.stmt1') || '''', 150),
      ('select * from public.card_balances', 150),
      ('select id from public.expenses order by date desc limit 300', 100),
      ('select id from public.audit_log where household_id = ''' || current_setting('ci.hh1') || ''' order by id desc limit 50', 100)
  loop
    execute 'explain (analyze, format json) ' || q into j;
    execute 'explain (analyze, format json) ' || q into j;
    t := round((j->0->>'Execution Time')::numeric, 1);
    report := report || format(E'\n  %s ms (budget %s) — %s', t, budget, left(q, 70));
    if t >= budget then ok := false; end if;
  end loop;
  raise notice 'screens at % households × % purchases:%', current_setting('ci.n_hh'), current_setting('ci.n_exp'), report;
  assert ok, 'a screen is over its budget:' || report;
end $$;

-- a purchase through every trigger, twice (the second counts)
do $$
declare t0 timestamptz; t numeric; h record;
begin
  select * into h from _hh where id = current_setting('ci.hh1')::uuid;
  for i in 1 .. 2 loop
    t0 := clock_timestamp();
    insert into public.daily_expenses (household_id, date, description, category_id, amount, currency, payment_method_id)
    values (h.id, current_date, 'timed purchase', h.cats[1], 12.5, 'AUD', h.visa);
    t := round(extract(epoch from clock_timestamp() - t0) * 1000, 1);
  end loop;
  raise notice 'a purchase through every trigger: % ms (budget 15)', t;
  assert t < 15, 'inserting a purchase took ' || t || ' ms';
end $$;
reset role;

-- re-filing a whole household (nothing to move, the usual case) and a month that does move
do $$
declare t0 timestamptz; t1 numeric; t2 numeric; n int; v_from date := date_trunc('month', current_date)::date;
begin
  t0 := clock_timestamp();
  perform public.restamp_pots(current_setting('ci.hh1')::uuid);
  t1 := round(extract(epoch from clock_timestamp() - t0) * 1000, 1);
  update public.expenses set pot_fund_id = null where household_id = current_setting('ci.hh1')::uuid and date >= v_from;
  t0 := clock_timestamp();
  n := public.restamp_pots(current_setting('ci.hh1')::uuid, v_from);
  t2 := round(extract(epoch from clock_timestamp() - t0) * 1000, 1);
  raise notice 're-filing: whole household % ms (budget 1000) · this month, % purchases moved, % ms', t1, n, t2;
  assert t1 < 1000, 're-filing a whole household took ' || t1 || ' ms';
  assert n > 0, 'the month re-filed nothing';
end $$;

rollback;
\echo speed holds
