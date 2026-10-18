-- The whole ledger in one list (18 Oct 2026, E41): every live row of both ledgers appears in money_lines exactly once,
-- with its amount as stored; a transfer's sides, a card payment's legs, a pot swap's rows and a month's plan each make
-- one event; ledger_page returns every event once across its pages, filters by kind / fund / category, and adds up
-- what matched; another household sees none of it; binned rows don't show.

\set ON_ERROR_STOP on
begin;
insert into public.beta_invites (code, max_uses, used_count) values ('CI-ML', 10, 0) on conflict do nothing;
insert into auth.users (id, email) values ('7e7e7e7e-0000-4000-8000-000000000001', 'ml-owner@test.local'),
                                          ('7e7e7e7e-0000-4000-8000-000000000002', 'ml-other@test.local');
set local role authenticated;
select set_config('request.jwt.claim.sub', '7e7e7e7e-0000-4000-8000-000000000002', true) \gset x_
select public.create_household_setup('CI-ML', 'Other house', array['Zed'], null, array['AU']) as hh2 \gset
insert into public.fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin)
select :'hh2', id, 'income', 'movement', public.bh_today(:'hh2'), 77, 'other house income', 'manual' from public.funds where household_id = :'hh2' limit 1;
select set_config('request.jwt.claim.sub', '7e7e7e7e-0000-4000-8000-000000000001', true) \gset x_
select public.create_household_setup('CI-ML', 'Ledger house', array['Ana', 'Ben'], 'Joint', array['AU', 'SG']) as hh \gset
select public.bh_today(:'hh') as today \gset
select id as ana from public.profiles where household_id = :'hh' and display_name = 'Ana' \gset
select id as floatau from public.funds where household_id = :'hh' and name = 'Float AU' \gset
select id as savau from public.funds where household_id = :'hh' and name = 'Savings AU' \gset
select id as floatsg from public.funds where household_id = :'hh' and name = 'Float SG' \gset
select id as savsg from public.funds where household_id = :'hh' and name = 'Savings SG' \gset
select id as cash from public.payment_methods where household_id = :'hh' and kind = 'cash' limit 1 \gset
insert into public.payment_methods (household_id, name, profile_id, kind, currency) values (:'hh', 'Visa — Ana', :'ana', 'credit_card', 'AUD') returning id as visa \gset
select id as groc from public.categories where household_id = :'hh' and kind = 'daily' and name = 'Groceries' \gset
-- incomes, a money-out row, a transfer, a card payment, purchases, a refund, a settle-up, a trip line, a binned purchase
insert into public.fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin)
values (:'hh', :'floatau', 'income', 'movement', :'today', 3000, 'salary', 'manual'),
       (:'hh', :'savau',   'income', 'movement', :'today', 1000, 'opening', 'manual'),
       (:'hh', :'floatsg', 'income', 'movement', :'today', 900, 'opening', 'manual'),
       (:'hh', :'savau',   'expense', 'movement', :'today'::date - 400, 25, 'old money out of a fund', 'manual');
select public.record_transfer(:'floatau', :'savau', :'today', 120, null, 'top-up') as g1 \gset
insert into public.daily_expenses (household_id, date, description, category_id, amount, currency, payment_method_id, payer_profile_id)
values (:'hh', :'today', 'weekly shop', :'groc', 80, 'AUD', :'visa', :'ana') returning id as shop \gset
insert into public.daily_expenses (household_id, date, description, category_id, amount, currency, payment_method_id, payer_profile_id)
values (:'hh', :'today', 'market', :'groc', 30, 'AUD', :'cash', :'ana') returning id as market \gset
insert into public.daily_expenses (household_id, date, description, category, amount, currency, payment_method_id, payer_profile_id)
values (:'hh', :'today', 'binned', 'Groceries', 5, 'AUD', :'cash', :'ana') returning id as binned \gset
insert into public.daily_expenses (household_id, date, description, category, amount, currency, payment_method_id, payer_profile_id)
values (:'hh', :'today', 'Ana pays Ben back', 'Payment', 15, 'AUD', :'cash', :'ana');
insert into public.daily_expenses (household_id, date, description, category, amount, currency, payment_method_id)
values (:'hh', :'today', 'hawker lunch', 'Groceries', 12, 'SGD', :'cash') returning id as lunch \gset
select public.refund_purchases(jsonb_build_array(jsonb_build_object('id', :'shop', 'amount', 10)), :'today', 'card', null) \gset x_
select public.soft_delete_rows('expense', array[:'binned'::uuid]) \gset x_
select public.record_card_payment(:'visa', :'today', jsonb_build_array(jsonb_build_object('fund_id', :'floatau', 'amount', 40),
                                                                      jsonb_build_object('fund_id', :'savau', 'amount', 30)), null, 'Visa') as gcp \gset
select public.record_pot_swap('daily', :'lunch', 1.1, :'floatau', :'savau', :'savsg', :'floatsg') as swap \gset
insert into public.trips (household_id, name, start_date, end_date, currency, currencies, countries)
values (:'hh', 'Weekend', :'today', :'today', 'AUD', '{AUD}', '{AU}') returning id as trip \gset
insert into public.travel_expenses (household_id, trip_id, date, description, category, amount, currency, payment_method_id, paid_with)
values (:'hh', :'trip', :'today', 'ferry', 'Ferry/Train', 20, 'AUD', :'cash', 'Cash');
reset role;
-- a month's plan and a trip send are the server's rows (written here as it writes them)
insert into public.fund_transactions_all (household_id, fund_id, type, kind, date, amount, remarks, origin)
values (:'hh', :'floatau', 'income', 'allocation', date_trunc('month', :'today'::date), 500, 'plan — spending budget', 'planned'),
       (:'hh', :'savau',   'income', 'allocation', date_trunc('month', :'today'::date), 200, 'plan — savings', 'planned');
insert into public.fund_transactions_all (household_id, fund_id, type, kind, date, amount, remarks, origin, trip_id)
values (:'hh', :'savau', 'expense', 'allocation', :'today', 20, 'Travel: Weekend', 'manual', :'trip');
select set_config('ci.hh', :'hh', true) \gset x_
select set_config('ci.hh2', :'hh2', true) \gset x_
select set_config('ci.g1', :'g1', true) \gset x_
select set_config('ci.gcp', :'gcp', true) \gset x_
select set_config('ci.swap', :'swap', true) \gset x_

-- ── 1 · every live row exactly once, amounts as stored ──────────────────
do $$
declare hh uuid := current_setting('ci.hh')::uuid; n_exp int; n_fund int; d int;
begin
  select count(*) into n_exp from public.expenses where household_id = hh and deleted_at is null;
  select count(*) into n_fund from public.fund_transactions_all where household_id = hh and deleted_at is null;
  assert (select count(*) from public.money_lines where household_id = hh) = n_exp + n_fund, 'money_lines has every live row';
  select count(*) into d from (select src, id from public.money_lines where household_id = hh group by 1, 2 having count(*) > 1) x;
  assert d = 0, 'a row appears twice';
  assert not exists (select 1 from public.money_lines l where l.src = 'expense' and l.description = 'binned'), 'a binned row shows';
  assert (select sum(amount) from public.money_lines where household_id = hh and src = 'expense')
       = (select sum(amount) from public.expenses where household_id = hh and deleted_at is null), 'purchase amounts as stored';
  assert (select sum(amount) from public.money_lines where household_id = hh and src = 'fund')
       = (select sum(amount) from public.fund_transactions_all where household_id = hh and deleted_at is null), 'fund amounts as stored';
  assert not exists (select 1 from public.money_lines l join public.expenses e on e.id = l.id where l.src = 'expense' and l.amount <> e.amount)
     and not exists (select 1 from public.money_lines l join public.fund_transactions_all t on t.id = l.id where l.src = 'fund' and (l.amount <> t.amount or l.date <> t.date)),
         'each row keeps its own amount and date';
end $$;

-- ── 2 · kinds and pairs ─────────────────────────────────────────────────
do $$
declare hh uuid := current_setting('ci.hh')::uuid; k text;
begin
  select string_agg(distinct kind, ',' order by kind) into k from public.money_lines where household_id = hh;
  assert k = 'card_payment,income,money_out,plan,pot_swap,purchase,refund,settle_up,transfer,trip,trip_send', 'every kind is named: ' || k;
  -- a transfer = one event of two rows that nets to zero
  assert (select count(*) from public.money_lines where event_key = 'g:' || current_setting('ci.g1') and kind = 'transfer') = 2, 'transfer sides paired';
  assert (select sum(signed) from public.money_lines where event_key = 'g:' || current_setting('ci.g1')) = 0, 'a transfer nets to zero';
  assert (select count(*) from public.money_lines where event_key = 'g:' || current_setting('ci.gcp') and kind = 'card_payment') = 2, 'card payment legs together';
  -- a pot swap: the AU pair + the SG pair under one key, nothing else of the swap elsewhere
  assert (select count(*) from public.money_lines where event_key = 's:' || current_setting('ci.swap')) = 4, 'pot swap rows together';
  assert not exists (select 1 from public.money_lines l join public.pot_swaps s on s.id = current_setting('ci.swap')::uuid
                      where l.src = 'fund' and l.transfer_group_id in (s.dst_group_id, s.src_group_id) and l.event_key <> 's:' || s.id), 'no swap row outside its event';
  assert (select count(*) from public.money_lines where household_id = hh and kind = 'plan' and event_key = 'p:' || to_char(public.bh_today(hh), 'YYYY-MM')) = 2, 'a month''s plan is one event';
  -- every grouped row of the fund ledger sits in an event with all of its group
  assert not exists (select 1 from public.fund_transactions_all t join public.money_lines l on l.id = t.id and l.src = 'fund'
                      where t.household_id = hh and t.deleted_at is null and t.transfer_group_id is not null
                        and exists (select 1 from public.fund_transactions_all t2 join public.money_lines l2 on l2.id = t2.id and l2.src = 'fund'
                                     where t2.transfer_group_id = t.transfer_group_id and t2.deleted_at is null and l2.event_key <> l.event_key)),
         'a group is split over two events';
end $$;

-- ── 3 · the Desk's list: every event once over the pages, filters, sums ──
set local role authenticated;
select set_config('request.jwt.claim.sub', '7e7e7e7e-0000-4000-8000-000000000001', true) \gset x_
do $$
declare hh uuid := current_setting('ci.hh')::uuid; j jsonb; keys text[] := '{}'; p int := 0; n_ev int; s jsonb;
begin
  select count(distinct event_key) into n_ev from public.money_lines where household_id = hh;
  loop
    j := public.ledger_page(p_limit => 4, p_offset => p * 4);
    exit when jsonb_array_length(j->'events') = 0;
    keys := keys || array(select e->>'key' from jsonb_array_elements(j->'events') e);
    p := p + 1;
  end loop;
  assert (j->>'total')::int = n_ev, 'total = events: ' || (j->>'total');
  assert cardinality(keys) = n_ev and (select count(distinct k) from unnest(keys) k) = n_ev, 'every event once over the pages';
  -- legs come whole: the transfer's event carries both sides even when only one side matches the fund filter
  j := public.ledger_page(p_fund => (select id::text from public.funds where household_id = hh and name = 'Float AU'), p_kinds => array['transfer']);
  assert jsonb_array_length(j->'events') = 1 and jsonb_array_length(j->'events'->0->'legs') = 2, 'transfer comes with both sides';
  assert (j->'events'->0->'amounts'->0->>'amount')::numeric = 120 and (j->'events'->0->'amounts'->0->>'net')::numeric = 0, 'transfer moved 120, nets 0';
  j := public.ledger_page(p_kinds => array['card_payment']);
  assert (j->'events'->0->'amounts'->0->>'amount')::numeric = 70, 'card payment = its legs';
  j := public.ledger_page(p_kinds => array['plan']);
  assert jsonb_array_length(j->'events') = 1 and (j->'events'->0->'amounts'->0->>'amount')::numeric = 700, 'one plan line, 700';
  -- a category: the shop and its refund; budget only; sums from what matched
  j := public.ledger_page(p_cat => 'c:' || (select id from public.categories where household_id = hh and kind = 'daily' and name = 'Groceries'), p_fund => 'budget');
  s := (select x from jsonb_array_elements(j->'sums') x where x->>'currency' = 'AUD');
  assert (s->>'spent')::numeric = 100, 'groceries spent = 80 + 30 − 10, got ' || (s->>'spent');
  j := public.ledger_page(p_kinds => array['income']);
  s := (select x from jsonb_array_elements(j->'sums') x where x->>'currency' = 'AUD');
  assert (s->>'income')::numeric = 4000, 'AUD income 3000 + 1000, got ' || (s->>'income');
  j := public.ledger_page(p_card => 'none');
  assert jsonb_array_length(j->'events') = 0, 'every purchase here has a card';
  j := public.ledger_page(p_search => 'old money');
  assert jsonb_array_length(j->'events') = 1 and j->'events'->0->>'kind' = 'money_out', 'old fund rows show (before the start date)';
  assert not exists (select 1 from public.money_lines where household_id = current_setting('ci.hh2')::uuid), 'another household''s rows are hidden';
end $$;
select set_config('request.jwt.claim.sub', '7e7e7e7e-0000-4000-8000-000000000002', true) \gset x_
do $$ begin
  assert (select count(*) from public.money_lines) = 1, 'the other house sees only its own row';
  assert (public.ledger_page()->>'total')::int = 1, 'and its own list';
end $$;
reset role;
do $$ begin
  assert not has_table_privilege('anon', 'public.money_lines', 'select'), 'anon can read money_lines';
  assert not has_function_privilege('anon', 'public.ledger_page(date, text[], text, text, text, text, integer, integer)', 'execute'), 'anon can run ledger_page';
  assert (select coalesce(reloptions @> array['security_invoker=true'], false) from pg_class where oid = 'public.money_lines'::regclass), 'money_lines runs with the reader''s rights';
end $$;
rollback;
