-- Read models (v2 sprint 3): the database does the sums. A household with more than 1,000 purchases, two
-- currencies, a trip, transfers, a card payment, a card opening and a trip send:
--   · fund_money (and the three views over it) gives exactly what the sprint-2 views gave, fund by fund — with the
--     Bundle A cut (In the bank / Owed on cards count a card only from the start date, as the card does)
--   · what the cards owe = what the funds owe on cards, apart from the lines only one side counts (bh_owed_gaps)
--   · household_money / app_bootstrap / home_summary / budget_summary / trip_summary equal plain SQL sums over
--     every row (no 1,000-row cap), group by category id (an archived category stays in its group), and read
--     only the caller's household

\set ON_ERROR_STOP on
begin;

-- ── the rules as they were (sprint 2), kept here as the reference; the card cut as of Bundle A (A1) ──
create temp view old_fund_balances as
 select f.household_id, f.id as fund_id,
    coalesce(sum(case when t.date > (now() at time zone h.timezone)::date or t.kind = 'card_payment' then 0::numeric
                      when t.type = 'income' then t.amount else - t.amount end), 0::numeric)
    - coalesce((select sum(case when de.is_refund then - de.amount else de.amount end)
                  from public.expenses de
                 where de.trip_id is null and de.deleted_at is null and de.household_id = f.household_id and de.currency = f.currency
                   and de.category <> 'Payment' and de.date <= (now() at time zone h.timezone)::date and de.pot_fund_id = f.id
                   and (de.fund_id = f.id or f.is_spend_pot and h.pot_start is not null and de.date >= h.pot_start)), 0::numeric) as balance
   from public.funds f join public.households h on h.id = f.household_id
   left join public.fund_transactions t on t.fund_id = f.id
  group by f.id, h.pot_start, h.timezone;
create temp view old_fund_cleared as
 select f.id as fund_id,
    coalesce(sum(case when t.date > (now() at time zone h.timezone)::date or t.reconciled_at is null or t.kind = 'card_payment' then 0::numeric
                      when t.type = 'income' then t.amount else - t.amount end), 0::numeric)
    - coalesce((select sum(case when de.is_refund then - de.amount else de.amount end)
                  from public.expenses de
                 where de.trip_id is null and de.deleted_at is null and de.household_id = f.household_id and de.currency = f.currency
                   and de.category <> 'Payment' and de.date <= (now() at time zone h.timezone)::date and de.reconciled_at is not null and de.pot_fund_id = f.id
                   and (de.fund_id = f.id or f.is_spend_pot and h.pot_start is not null and de.date >= h.pot_start)), 0::numeric) as cleared_balance,
    coalesce((select sum(case when de.is_refund then - de.amount else de.amount end)
                from public.expenses de
               where de.trip_id is null and de.deleted_at is null and de.household_id = f.household_id and de.currency = f.currency
                 and de.category <> 'Payment' and de.date <= (now() at time zone h.timezone)::date and de.reconciled_at is null and de.pot_fund_id = f.id
                 and (de.fund_id = f.id or f.is_spend_pot and h.pot_start is not null and de.date >= h.pot_start)), 0::numeric) as pending_spend
   from public.funds f join public.households h on h.id = f.household_id
   left join public.fund_transactions t on t.fund_id = f.id
  group by f.id, h.pot_start, h.timezone;
create temp view old_fund_cash as
 select b.fund_id, b.balance, c.cash_balance, round(c.cash_balance - b.balance, 2) as owed_on_cards
   from old_fund_balances b
   join (select f.id as fund_id,
            coalesce(sum(case when t.date > (now() at time zone h.timezone)::date then 0::numeric
                              when t.kind = 'card_payment' and t.date < h.pot_start then 0::numeric
                              when t.type = 'expense' and t.kind <> 'card_payment' and public.bh_is_credit_card(t.account_payment_method_id)
                               and (h.pot_start is null or t.date >= h.pot_start) then 0::numeric
                              when t.type = 'income' then t.amount else - t.amount end), 0::numeric)
            - coalesce((select sum(case when de.is_refund then - de.amount else de.amount end)
                          from public.expenses de left join public.payment_methods pm on pm.id = de.payment_method_id
                         where de.trip_id is null and de.deleted_at is null and de.household_id = f.household_id and de.currency = f.currency
                           and de.category <> 'Payment' and de.date <= (now() at time zone h.timezone)::date and de.pot_fund_id = f.id
                           and (de.fund_id = f.id or f.is_spend_pot and h.pot_start is not null and de.date >= h.pot_start)
                           and (coalesce(pm.kind, 'cash') <> 'credit_card' or de.date < h.pot_start)), 0::numeric)
            + coalesce((select sum(o.amount) from public.card_openings o where o.fund_id = f.id), 0::numeric)
            + coalesce((select sum(round(a.amount * l.cards / l.total, 2))
                          from public.fund_transactions a
                          join lateral (select sum(case when e.is_refund then - e.amount else e.amount end) as total,
                                               sum(case when e.is_refund then - e.amount else e.amount end)
                                                 filter (where public.bh_is_credit_card(e.payment_method_id) and (h.pot_start is null or e.date >= h.pot_start)) as cards
                                          from public.expenses e where e.settlement_tx_id = a.id and e.deleted_at is null) l on true
                         where a.fund_id = f.id and a.type = 'expense' and a.kind = 'allocation' and a.date <= (now() at time zone h.timezone)::date
                           and l.total > 0::numeric and l.cards is not null), 0::numeric) as cash_balance
           from public.funds f join public.households h on h.id = f.household_id
           left join public.fund_transactions t on t.fund_id = f.id
          group by f.id, h.pot_start, h.timezone) c on c.fund_id = b.fund_id;

-- ── a busy household ────────────────────────────────────────────────────
insert into public.beta_invites (code, max_uses, used_count) values ('CI-RM', 10, 0) on conflict do nothing;
insert into auth.users (id, email) values ('ffffffff-0000-4000-8000-000000000001', 'rm-owner@test.local'),
                                          ('ffffffff-0000-4000-8000-000000000002', 'rm-viewer@test.local'),
                                          ('ffffffff-0000-4000-8000-000000000003', 'rm-outsider@test.local');
set local role authenticated;
select set_config('request.jwt.claim.sub', 'ffffffff-0000-4000-8000-000000000001', true) \gset x_
select public.create_household_setup('CI-RM', 'Busy house', array['Ana', 'Ben'], 'Joint', array['AU', 'SG']) as hh \gset
select set_config('ci.hh', :'hh', true) \gset x_
select public.bh_today(:'hh') as today \gset
select date_trunc('month', :'today'::date)::date as month \gset
select set_config('ci.today', :'today', true) \gset x_
select set_config('ci.month', :'month', true) \gset x_
select id as ana from public.profiles where household_id = :'hh' and display_name = 'Ana' \gset
select id as ben from public.profiles where household_id = :'hh' and display_name = 'Ben' \gset
select public.link_my_profile(:'ana') \gset x_
select set_config('ci.ana', :'ana', true) \gset x_
select set_config('ci.ben', :'ben', true) \gset x_
reset role;
update public.households set pot_start = (:'month'::date - interval '4 months')::date where id = :'hh';   -- some purchases before the start
set local role authenticated;
insert into public.funds (household_id, name, country, currency, group_name, sort_order) values (:'hh', 'Car Fund', 'AU', 'AUD', 'Car', 20);
insert into public.payment_methods (household_id, name, profile_id, kind, currency, sort_order)
values (:'hh', 'Visa Ana', :'ana', 'credit_card', 'AUD', 5), (:'hh', 'Amex Joint', null, 'credit_card', 'AUD', 6),
       (:'hh', 'SG Card', :'ana', 'credit_card', 'SGD', 7);
select id as visa from public.payment_methods where household_id = :'hh' and name = 'Visa Ana' \gset
select id as amex from public.payment_methods where household_id = :'hh' and name = 'Amex Joint' \gset
select id as sgcard from public.payment_methods where household_id = :'hh' and name = 'SG Card' \gset
select id as cash from public.payment_methods where household_id = :'hh' and kind = 'cash' \gset
select id as bank from public.payment_methods where household_id = :'hh' and name = 'Bank card — Ana' \gset
select id as floatau from public.funds where household_id = :'hh' and name = 'Float AU' \gset
select id as car from public.funds where household_id = :'hh' and name = 'Car Fund' \gset
select id as trav from public.funds where household_id = :'hh' and name = 'Travel fund AU' \gset
select id as emerg from public.funds where household_id = :'hh' and name = 'Emergency fund AU' \gset
select id as floatsg from public.funds where household_id = :'hh' and name = 'Float SG' \gset
select set_config('ci.floatau', :'floatau', true) \gset x_

-- money in, transfers, a movement charged to a card, a future-dated income
insert into public.fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin)
values (:'hh', :'floatau', 'income', 'movement', :'month'::date - interval '5 months', 20000, 'opening', 'manual'),
       (:'hh', :'car', 'income', 'movement', :'month'::date - interval '5 months', 3000, 'opening', 'manual'),
       (:'hh', :'trav', 'income', 'movement', :'month'::date - interval '5 months', 2500, 'opening', 'manual'),
       (:'hh', :'floatsg', 'income', 'movement', :'month'::date - interval '5 months', 4000, 'opening', 'manual'),
       (:'hh', :'floatau', 'income', 'movement', :'today'::date + 3, 999, 'next pay (scheduled)', 'manual');
insert into public.fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin, income_source)
values (:'hh', :'floatau', 'income', 'movement', :'month', 12.34, 'Interest', 'manual', 'Interest'),
       (:'hh', :'floatau', 'income', 'movement', :'today', 5.66, 'Interest', 'manual', 'Interest'),
       (:'hh', :'floatsg', 'income', 'movement', :'month', 300, 'Side job', 'manual', 'Side job');
insert into public.fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin, account_payment_method_id)
values (:'hh', :'car', 'expense', 'movement', :'month', 410, 'Rego (on the Visa)', 'manual', :'visa');
select public.record_transfer(:'floatau', :'emerg', :'today', 150, null, 'top-up') \gset x_
select public.record_transfer(:'floatau', :'floatsg', :'today', 100, 90) \gset x_
insert into public.card_openings (household_id, payment_method_id, fund_id, amount) values (:'hh', :'amex', :'floatau', 300);

-- 1,250 daily purchases over six months: ten categories, four cards, refunds, fund purchases, settle-ups,
-- a few after today (scheduled), some before the start date
insert into public.daily_expenses (household_id, date, description, category, amount, currency, payment_method_id, payer_profile_id, is_refund, fund_id)
select :'hh', ((:'month'::date - make_interval(months => i % 6))::date + (i * 7) % 28), 'purchase ' || i,
       case when i % 41 = 0 then 'Payment'
            else (array['Groceries', 'Dining out', 'Bus/train', 'Rent', 'Electricity', 'Childcare', 'Insurance', 'TV/Phone/Internet', 'Gas/fuel', 'Clothing'])[i % 10 + 1] end,
       round(((i * 37) % 9000) / 100.0 + 1, 2), 'AUD',
       (array[:'visa', :'amex', :'cash', :'bank']::uuid[])[i % 4 + 1],
       case when i % 4 = 1 then (case when i % 8 = 1 then :'ana'::uuid else :'ben'::uuid end) end,
       i % 17 = 0, case when i % 23 = 0 then :'car'::uuid end
  from generate_series(1, 1250) i;
-- sixty in S$
insert into public.daily_expenses (household_id, date, description, category, amount, currency, payment_method_id, is_refund)
select :'hh', ((:'month'::date - make_interval(months => i % 3))::date + (i * 5) % 27), 'hawker ' || i,
       (array['Dining out', 'Groceries', 'Taxi'])[i % 3 + 1], round(((i * 13) % 4000) / 100.0 + 1, 2), 'SGD',
       (array[:'sgcard', :'cash']::uuid[])[i % 2 + 1], i % 19 = 0
  from generate_series(1, 60) i;
-- some purchases checked off against a statement
select public.reconcile_rows('daily', array(select id from public.daily_expenses where household_id = :'hh' and payment_method_id = :'visa' and date < :'month' order by date limit 40), null) \gset x_
-- a card payment from Float AU
select public.record_card_payment(:'visa', :'today', jsonb_build_array(jsonb_build_object('fund_id', :'floatau', 'amount', 200)), null, 'Visa bill') \gset x_

-- a trip: A$ lines on the Visa and in cash (sent to the travel fund, part of it on the card), ¥ lines unsent
insert into public.trips (household_id, name, start_date, end_date, currency, currencies, countries)
values (:'hh', 'Tokyo test', :'month'::date - 40, :'month'::date - 30, 'JPY', '{JPY}', '{JP}');
select id as trip from public.trips where household_id = :'hh' and name = 'Tokyo test' \gset
insert into public.travel_expenses (household_id, trip_id, date, description, category, amount, currency, payment_method_id, payer_profile_id, is_refund)
select :'hh', :'trip', (:'month'::date - 40 + (i % 10))::date, 'trip line ' || i, (array['Dining out', 'Hotel', 'Shopping'])[i % 3 + 1],
       case when i % 2 = 0 then round(((i * 11) % 500) + 1, 2) else round(((i * 7) % 300) / 10.0 + 1, 2) end,
       case when i % 2 = 0 then 'JPY' else 'AUD' end,
       (array[:'visa', :'cash']::uuid[])[i % 2 + 1], case when i % 3 = 0 then :'ben'::uuid else :'ana'::uuid end, i % 13 = 0
  from generate_series(1, 30) i;
select public.send_trip(:'trip', :'today') \gset x_

-- this month's plan, applied (its Salary counts as income on Home)
select public.save_month_plan(:'month',
  '[{"source_name": "Salary", "currency": "AUD", "amount": 6000}]',
  '[{"category_group": "Daily Expenses", "currency": "AUD", "amount": 900}, {"category_group": "Transportation", "currency": "AUD", "amount": 250}, {"category_group": "Old line nobody renamed", "currency": "AUD", "amount": 40}]',
  jsonb_build_array(jsonb_build_object('fund_id', :'emerg', 'amount', 300)), null) \gset x_
select public.apply_month_plan(:'month') \gset x_
-- earlier months' budget lines
reset role;
insert into public.category_budgets (household_id, month, category_group, currency, amount)
select :'hh', (:'month'::date - make_interval(months => k))::date, g, 'AUD', 100 * k
  from generate_series(1, 3) k, unnest(array['Daily Expenses', 'Rent']) g;
set local role authenticated;
-- an archived category keeps its history in its group
update public.categories set is_active = false where household_id = :'hh' and kind = 'daily' and name = 'Clothing';

-- ── 1 · one pass = the old rules, fund by fund ──────────────────────────
reset role;
do $$
declare v_bad int; v_n int;
begin
  select count(*) into v_n from public.expenses where household_id = current_setting('ci.hh')::uuid and trip_id is null and deleted_at is null;
  assert v_n > 1000, 'the busy household has more than 1,000 purchases, got ' || v_n;
  select count(*) into v_bad from old_fund_balances o full join public.fund_balances n using (fund_id) where n.balance is distinct from o.balance;
  assert v_bad = 0, 'Available differs from the old rule for ' || v_bad || ' funds';
  select count(*) into v_bad from old_fund_cleared o full join public.fund_balances_cleared n using (fund_id)
   where n.cleared_balance is distinct from o.cleared_balance or n.pending_spend is distinct from o.pending_spend;
  assert v_bad = 0, 'cleared/pending differ from the old rule for ' || v_bad || ' funds';
  select count(*) into v_bad from old_fund_cash o full join public.fund_cash n using (fund_id)
   where n.cash_balance is distinct from o.cash_balance or n.owed_on_cards is distinct from o.owed_on_cards or n.balance is distinct from o.balance;
  assert v_bad = 0, 'in the bank / owed differ from the old rule for ' || v_bad || ' funds';
  -- the scenario actually exercises every part: cleared rows, card owed, a card opening, a trip send's card share
  select count(*) into v_n from public.fund_money where household_id = current_setting('ci.hh')::uuid
   and (cleared_balance <> balance or abs(owed_on_cards) > 0.005);
  assert v_n >= 3, 'the scenario should move cleared and owed numbers, got ' || v_n || ' funds';
  assert exists (select 1 from public.expenses where household_id = current_setting('ci.hh')::uuid and settlement_tx_id is not null), 'the trip send linked its purchases';
end $$;

-- ── 1b · cards and funds agree on what is owed (A1 / DH-01) ─────────────
do $$
declare hh uuid := current_setting('ci.hh')::uuid; g record; v_n int; v_old numeric; v_card numeric; v_fund numeric;
begin
  -- the scenario has fund purchases on cards from before the start date: the card ignores them, and so do the funds now
  select count(*) into v_n from public.expenses e join public.payment_methods p on p.id = e.payment_method_id and p.kind = 'credit_card'
   join public.households h on h.id = e.household_id
   where e.household_id = hh and e.fund_id is not null and e.trip_id is null and e.deleted_at is null and e.date < h.pot_start;
  assert v_n > 0, 'the scenario has pre-start fund purchases on cards';
  -- the Car Fund owes exactly its card purchases since the start date plus its card-charged rows, nothing older
  select owed_on_cards into v_fund from public.fund_money where fund_id = (select id from public.funds where household_id = hh and name = 'Car Fund');
  select coalesce(sum(case when e.is_refund then -e.amount else e.amount end), 0) into v_card
    from public.expenses e join public.payment_methods p on p.id = e.payment_method_id and p.kind = 'credit_card' join public.households h on h.id = e.household_id
   where e.fund_id = (select id from public.funds where household_id = hh and name = 'Car Fund') and e.deleted_at is null
     and e.date >= h.pot_start and e.counts_on <= current_setting('ci.today')::date;
  assert v_fund = v_card + 410, 'the Car Fund owes its card purchases since the start + the rego, got ' || v_fund || ' vs ' || (v_card + 410);
  -- every currency: cards = funds once the one-sided lines are set aside
  for g in select * from public.bh_owed_gaps() where household_id = hh loop
    assert g.gap = 0, g.currency || ': cards and funds disagree by ' || g.gap;
  end loop;
  select count(*) into v_n from public.bh_owed_gaps() where household_id = hh and currency in ('AUD', 'SGD');
  assert v_n = 2, 'both currencies are checked, got ' || v_n;
  -- one-sided lines here: the settle-ups ("Payment") on the AUD cards, which the card counts and no fund does
  select card_only into v_old from public.bh_owed_gaps() where household_id = hh and currency = 'AUD';
  assert v_old = (select -sum(e.amount) from public.expenses e join public.payment_methods p on p.id = e.payment_method_id and p.kind = 'credit_card' join public.households h on h.id = e.household_id
                   where e.household_id = hh and e.category = 'Payment' and e.deleted_at is null and e.date >= h.pot_start and e.date <= current_setting('ci.today')::date),
         'AUD card-only lines = the settle-ups on cards, got ' || v_old;
  -- the rule before Bundle A would have failed this check (DH-01): the pre-start card purchases count as owed for ever
  select sum(o.owed_on_cards) - (select funds_owe from public.bh_owed_gaps() where household_id = hh and currency = 'AUD') into v_old
    from public.fund_money o where o.household_id = hh and o.currency = 'AUD';
  assert v_old = 0, 'sanity: fund_money sums as bh_owed_gaps reads it';
  select coalesce(sum(case when e.is_refund then -e.amount else e.amount end), 0) into v_old
    from public.expenses e join public.payment_methods p on p.id = e.payment_method_id and p.kind = 'credit_card' join public.households h on h.id = e.household_id
   where e.household_id = hh and e.fund_id is not null and e.trip_id is null and e.deleted_at is null and e.date < h.pot_start and e.category <> 'Payment';
  assert v_old <> 0, 'the old rule would have put these pre-start card purchases on the funds as owed';
  assert (select bad from public.bh_money_check() where check_name = 'funds and cards that disagree on what is owed') = 0, 'the nightly check is clean';
end $$;
set local role authenticated;

-- ── 2 · household_money: the caller's funds, every number ───────────────
do $$
declare v_bad int; v_n int;
begin
  select count(*) into v_n from public.household_money();
  assert v_n = (select count(*) from public.funds where household_id = current_setting('ci.hh')::uuid), 'household_money lists every fund, got ' || v_n;
  select count(*) into v_bad from public.household_money() h join public.fund_money m using (fund_id)
   where (h.balance, h.cleared_balance, h.pending_spend, h.cash_balance, h.owed_on_cards)
         is distinct from (m.balance, m.cleared_balance, m.pending_spend, m.cash_balance, m.owed_on_cards);
  assert v_bad = 0, 'household_money differs from fund_money for ' || v_bad || ' funds';
end $$;

-- ── 3 · budget_summary = SQL over every row ─────────────────────────────
select public.budget_summary(:'month', 'AUD', 6) as bud \gset
select set_config('ci.bud', :'bud', true) \gset x_
do $$
declare b jsonb := current_setting('ci.bud')::jsonb; hh uuid := current_setting('ci.hh')::uuid; today date := current_setting('ci.today')::date;
        m0 date := current_setting('ci.month')::date; v_bad int; v_n int; s1 numeric; s2 numeric;
begin
  assert (b->>'from')::date = (m0 - interval '5 months')::date, 'six months back';
  -- spend per month and group = the plain sum (counted: to today, not paid from a fund, not settling up)
  select count(*) into v_bad from (
    select (x->>'month')::date as month, nullif(x->>'group_id', '')::uuid as gid, (x->>'amount')::numeric as amount from jsonb_array_elements(b->'spend') x) s
    full join (select date_trunc('month', e.date)::date as month, c.group_id as gid, sum(case when e.is_refund then -e.amount else e.amount end) as amount
                 from public.expenses e left join public.categories c on c.id = e.category_id
                where e.household_id = hh and e.trip_id is null and e.deleted_at is null and e.currency = 'AUD' and e.category <> 'Payment'
                  and e.fund_id is null and e.date >= m0 - interval '5 months' and e.date < m0 + interval '1 month' and e.date <= today
                group by 1, 2) q on q.month = s.month and q.gid is not distinct from s.gid
   where s.amount is distinct from q.amount;
  assert v_bad = 0, 'budget spend differs from SQL in ' || v_bad || ' month/group cells';
  select sum((x->>'amount')::numeric) into s1 from jsonb_array_elements(b->'spend') x;
  select sum(case when is_refund then -amount else amount end) into s2 from public.expenses
   where household_id = hh and trip_id is null and deleted_at is null and currency = 'AUD' and category <> 'Payment' and fund_id is null
     and date >= m0 - interval '5 months' and date <= today;
  assert s1 = s2, 'six months of spend: ' || s1 || ' vs ' || s2 || ' — rows were lost';
  select coalesce(sum((x->>'amount')::numeric), 0) into s1 from jsonb_array_elements(b->'scheduled') x;
  select coalesce(sum(case when is_refund then -amount else amount end), 0) into s2 from public.expenses
   where household_id = hh and trip_id is null and deleted_at is null and currency = 'AUD' and category <> 'Payment' and fund_id is null
     and date > today and date < m0 + interval '1 month';
  assert s1 = s2, 'scheduled: ' || s1 || ' vs ' || s2;
  select coalesce(sum((x->>'amount')::numeric), 0) into s1 from jsonb_array_elements(b->'from_funds') x;
  select coalesce(sum(case when is_refund then -amount else amount end), 0) into s2 from public.expenses
   where household_id = hh and trip_id is null and deleted_at is null and currency = 'AUD' and category <> 'Payment' and fund_id is not null
     and date >= m0 - interval '5 months' and date < m0 + interval '1 month';
  assert s1 = s2 and s1 <> 0, 'paid from funds: ' || s1 || ' vs ' || s2;
  -- budget lines: by group id, and the line no group matches keeps its label
  select sum((x->>'amount')::numeric) into s1 from jsonb_array_elements(b->'budget') x where (x->>'month')::date = m0;
  assert s1 = 1190, 'this month''s budget lines, got ' || s1;
  assert exists (select 1 from jsonb_array_elements(b->'budget') x where x->>'label' = 'Daily Expenses' and x->>'group_id' is not null), 'a line knows its group id';
  -- an archived category's history stays in its group: nothing falls into "Other", and a month with
  -- Clothing purchases lists them under Clothing's group
  assert not exists (select 1 from jsonb_array_elements(b->'spend') x where x->>'group_id' is null), 'nothing falls into Other';
  assert exists (select 1 from jsonb_array_elements(public.budget_summary((m0 - interval '3 months')::date, 'AUD')->'cats') x
                  where x->>'name' = 'Clothing'
                    and (x->>'group_id')::uuid = (select group_id from public.categories where household_id = hh and kind = 'daily' and name = 'Clothing')),
         'an archived category keeps its group';
  -- the month's categories add up to the month's spend
  select sum((x->>'amount')::numeric) into s1 from jsonb_array_elements(b->'cats') x;
  select sum((x->>'amount')::numeric) into s2 from jsonb_array_elements(b->'spend') x where (x->>'month')::date = m0;
  assert s1 = s2, 'categories ' || s1 || ' vs month ' || s2;
  -- the settle-up group is not a budget group; the pots are this currency's
  assert not exists (select 1 from jsonb_array_elements(b->'groups') x where x->>'name' = 'Transfers'), 'Transfers is not a budget group';
  select count(*) into v_n from jsonb_array_elements(b->'pots') x;
  assert v_n = 1 and (b->'pots'->0->>'name') = 'Float AU', 'the A$ pot';
  assert (b->'pots'->0->>'balance')::numeric = (select balance from public.fund_balances where fund_id = current_setting('ci.floatau')::uuid), 'the pot''s Available';
end $$;

-- ── 4 · home_summary ────────────────────────────────────────────────────
select public.home_summary() as home \gset
select set_config('ci.home', :'home', true) \gset x_
do $$
declare h jsonb := current_setting('ci.home')::jsonb; hh uuid := current_setting('ci.hh')::uuid; today date := current_setting('ci.today')::date;
        m0 date := current_setting('ci.month')::date; s1 numeric; s2 numeric; v_n int;
begin
  assert (h->>'today')::date = today, 'Home uses the household''s today';
  select coalesce(sum((x->>'amount')::numeric), 0) into s1 from jsonb_array_elements(h->'week') x where x->>'currency' = 'AUD';
  select coalesce(sum(case when is_refund then -amount else amount end), 0) into s2 from public.expenses
   where household_id = hh and trip_id is null and deleted_at is null and currency = 'AUD' and category <> 'Payment' and fund_id is null
     and date between today - 6 and today;
  assert s1 = s2, 'the week: ' || s1 || ' vs ' || s2;
  select coalesce(sum((x->>'amount')::numeric), 0) into s1 from jsonb_array_elements(h->'month_groups') x where x->>'currency' = 'AUD';
  select coalesce(sum(case when is_refund then -amount else amount end), 0) into s2 from public.expenses
   where household_id = hh and trip_id is null and deleted_at is null and currency = 'AUD' and category <> 'Payment' and fund_id is null
     and date between m0 and today;
  assert s1 = s2, 'the month: ' || s1 || ' vs ' || s2;
  select count(*) into v_n from jsonb_array_elements(h->'recent') x;
  assert v_n = 5, 'five recent purchases';
  assert not exists (select 1 from jsonb_array_elements(h->'recent') x where (x->>'date')::date > today), 'recent leaves out scheduled rows';
  assert (h->>'plan_applied')::boolean, 'the plan is applied';
  -- income: the applied plan's Salary + money logged as income (A$ Interest twice, S$ side job)
  assert (select (x->>'amount')::numeric from jsonb_array_elements(h->'income') x where x->>'source' = 'Salary') = 6000, 'Salary from the plan';
  assert (select (x->>'amount')::numeric from jsonb_array_elements(h->'income') x where x->>'source' = 'Interest') = 18.00, 'Interest summed';
  assert (select x->>'currency' from jsonb_array_elements(h->'income') x where x->>'source' = 'Side job') = 'SGD', 'income keeps its fund''s currency';
end $$;

-- ── 5 · app_bootstrap ───────────────────────────────────────────────────
select public.app_bootstrap() as boot \gset
select set_config('ci.boot', :'boot', true) \gset x_
do $$
declare b jsonb := current_setting('ci.boot')::jsonb; hh uuid := current_setting('ci.hh')::uuid;
begin
  assert (b->'household'->>'id')::uuid = hh, 'my household';
  assert b->'me'->>'role' = 'owner', 'I am the owner';
  assert (b->'me'->>'profile_id')::uuid = current_setting('ci.ana')::uuid, 'and I am Ana';
  assert jsonb_array_length(b->'profiles') = 2, 'two people';
  assert jsonb_array_length(b->'funds') = (select count(*) from public.funds where household_id = hh and is_active), 'every active fund';
  assert jsonb_array_length(b->'cards') = (select count(*) from public.payment_methods where household_id = hh and not is_archived), 'every active card';
  assert jsonb_array_length(b->'categories') = (select count(*) from public.categories where household_id = hh and is_active), 'every active category';
  assert not exists (select 1 from jsonb_array_elements(b->'categories') c where c->>'id' is null or c->>'group_id' is null), 'categories carry ids';
  assert jsonb_array_length(b->'recent_daily') = 300 and jsonb_array_length(b->'recent_travel') = 30, 'recent purchases';
  assert (b->>'first_month')::date = (select date_trunc('month', min(date))::date from public.expenses where household_id = hh and trip_id is null and deleted_at is null), 'first month';
  assert (b->'plan'->>'applied_on') is not null and (b->'plan'->>'fund_lines')::boolean, 'this month''s plan';
  assert (select count(*) from jsonb_array_elements_text(b->'income_sources') s where lower(s) = 'interest') = 1, 'each income source once';
  assert b->'income_sources'->>0 = 'Salary', 'the plan''s sources first';
end $$;

-- ── 6 · trip_summary ────────────────────────────────────────────────────
select public.trip_summary() as trips \gset
select set_config('ci.trips', :'trips', true) \gset x_
do $$
declare t jsonb; hh uuid := current_setting('ci.hh')::uuid; s numeric; v_bad int;
begin
  select x into t from jsonb_array_elements(current_setting('ci.trips')::jsonb) x where x->>'trip_id' = (select id::text from public.trips where household_id = hh and name = 'Tokyo test');
  assert (t->>'n')::int = 30, 'thirty trip lines';
  assert not (t->>'all_sent')::boolean, 'the ¥ lines are not sent';
  select sum(case when is_refund then -amount else amount end) into s from public.expenses where household_id = hh and trip_id is not null and deleted_at is null and currency = 'JPY';
  assert (t->'totals'->>'JPY')::numeric = s, 'the ¥ total';
  -- what each person fronted on unsent lines = their split lines
  select count(*) into v_bad from jsonb_array_elements(t->'fronted') f
   where (f->>'amount')::numeric is distinct from (
     select sum(sp.amount) from public.expenses e join public.expense_splits sp on sp.expense_id = e.id
      where e.household_id = hh and e.trip_id is not null and e.deleted_at is null and not e.sent_to_fund
        and sp.profile_id = (f->>'profile_id')::uuid and e.currency = f->>'currency');
  assert v_bad = 0 and jsonb_array_length(t->'fronted') >= 2, 'who fronted what';
  assert not exists (select 1 from jsonb_array_elements(t->'fronted') f where f->>'currency' = 'AUD'), 'the sent A$ lines are settled';
end $$;

-- ── 6b · fund_explain (Bundle C): its parts add up to fund_money for every fund of the big household ──
do $$
declare f record; x jsonb;
begin
  for f in select fund_id, balance from public.fund_money where household_id = current_setting('ci.hh')::uuid loop
    x := public.fund_explain(f.fund_id);
    assert (x->'all'->>'money_in')::numeric - (x->'all'->>'moved_out')::numeric - (x->'all'->>'purchases')::numeric = f.balance,
           'fund_explain all-time parts for ' || f.fund_id;
    assert (x->'month'->>'opening')::numeric + (x->'month'->>'money_in')::numeric - (x->'month'->>'moved_out')::numeric
           - (x->'month'->>'purchases')::numeric = f.balance, 'fund_explain this month''s parts for ' || f.fund_id;
  end loop;
end $$;

-- ── 7 · a viewer reads; an outsider reads nothing ───────────────────────
reset role;
insert into public.household_members (household_id, user_id, role) values (:'hh', 'ffffffff-0000-4000-8000-000000000002', 'viewer');
set local role authenticated;
select set_config('request.jwt.claim.sub', 'ffffffff-0000-4000-8000-000000000002', true) \gset x_
do $$
begin
  assert public.app_bootstrap()->'me'->>'role' = 'viewer', 'a viewer is told so';
  assert (select count(*) from public.household_money()) > 0, 'a viewer reads the funds';
  assert jsonb_array_length(public.budget_summary(current_setting('ci.month')::date, 'AUD')->'spend') > 0, 'a viewer reads the budget';
end $$;
select set_config('request.jwt.claim.sub', 'ffffffff-0000-4000-8000-000000000003', true) \gset x_
do $$
begin
  assert public.app_bootstrap()->'household' = 'null'::jsonb, 'an outsider has no household';
  assert (select count(*) from public.household_money()) = 0, 'an outsider reads no funds';
  assert public.home_summary() is null and public.budget_summary(current_setting('ci.month')::date, 'AUD') is null, 'an outsider reads no summary';
  assert public.trip_summary() = '[]'::jsonb, 'an outsider reads no trips';
  assert (select count(*) from public.fund_money) = 0, 'fund_money obeys RLS';
end $$;

rollback;
\echo read models hold
