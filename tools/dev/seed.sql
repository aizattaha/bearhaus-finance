-- Synthetic household for the local stack (tools/dev/seed.sh). Made-up names and amounts only.
-- A two-country couple shaped like the real one: AU + SG funds, personal and shared cards, a travel-only SG
-- card, an archived card, a transfer, a trip, purchases either side of the start date — and, since v2 sprint 3,
-- six months of everyday purchases (well over 1,000 rows: the screens must not lose any to the row cap) and a
-- saved, applied plan for this month.
begin;
insert into public.beta_invites (code, max_uses, used_count) values ('LOCAL-SEED', 50, 0) on conflict do nothing;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'uid', true) \gset seedtmp_
select public.create_household_setup('LOCAL-SEED', 'Local Test House', array['Alex', 'Jo'], 'Joint', array['AU', 'SG']) as hh \gset
reset role;
select set_config('seed.hh', :'hh', true) \gset seedtmp_

-- pot_start a month back, so there is a "before the app counted cards" period
update public.households set pot_start = (date_trunc('month', current_date) - interval '1 month')::date where id = :'hh'::uuid;
insert into public.funds (household_id, name, country, currency, group_name, sort_order)
values (:'hh'::uuid, 'Car Fund', 'AU', 'AUD', 'Car', 20);

with p as (select id, display_name from public.profiles where household_id = :'hh'::uuid)
insert into public.payment_methods (household_id, name, profile_id, kind, currency, closing_day, travel_only, sort_order)
select :'hh'::uuid, v.name, (select id from p where display_name = v.who), v.kind, v.cur, v.cd, v.travel, v.ord
from (values ('Macquarie - Alex', 'Alex', 'credit_card', 'AUD', 2, false, 2),
             ('UOB PPV', 'Alex', 'credit_card', 'SGD', 15, true, 3),
             ('HSBC Star - Jo', 'Jo', 'credit_card', 'AUD', 2, false, 4),
             ('Bank - Joint', null, 'bank', 'AUD', null, false, 5),
             ('Old Visa - Alex', 'Alex', 'credit_card', 'AUD', 20, false, 6)) v(name, who, kind, cur, cd, travel, ord);
update public.payment_methods set is_archived = true where household_id = :'hh'::uuid and name = 'Old Visa - Alex';

-- money in
insert into public.fund_transactions (household_id, fund_id, type, date, amount, remarks, origin)
select :'hh'::uuid, f.id, 'income', (select pot_start from public.households where id = :'hh'::uuid), v.amt, 'opening (synthetic)', 'manual'
from public.funds f join (values ('Float AU', 2000), ('Car Fund', 900), ('Float SG', 1500), ('Savings SG', 3000), ('Travel fund AU', 1200)) v(n, amt) on v.n = f.name
where f.household_id = :'hh'::uuid;

-- a transfer Float SG → Savings SG
insert into public.fund_transactions (household_id, fund_id, type, date, amount, remarks, origin, transfer_group_id)
select :'hh'::uuid, (select id from public.funds where household_id = :'hh'::uuid and name = 'Float SG'), 'expense', current_date - 5, 200, 'Transfer → Savings SG', 'manual', '11111111-0000-4000-8000-0000000000aa'::uuid
union all
select :'hh'::uuid, (select id from public.funds where household_id = :'hh'::uuid and name = 'Savings SG'), 'income', current_date - 5, 200, 'Transfer ← Float SG', 'manual', '11111111-0000-4000-8000-0000000000aa'::uuid;

-- purchases on cards, one before pot_start
insert into public.expenses (household_id, date, description, category, amount, currency, payer_profile_id, payment_method_id, paid_with)
select :'hh'::uuid, v.d, v.descr, v.cat, v.amt, v.cur,
       (select id from public.profiles where household_id = :'hh'::uuid and display_name = v.who),
       (select id from public.payment_methods where household_id = :'hh'::uuid and name = v.card), v.card
from (values ((select pot_start from public.households where id = :'hh'::uuid) - 2, 'Grocer (before start)', 'Groceries', 60.00, 'AUD', 'Alex', 'Macquarie - Alex'),
             (current_date - 9, 'Cafe', 'Dining out', 12.50, 'AUD', 'Alex', 'Macquarie - Alex'),
             (current_date - 7, 'Grocer', 'Groceries', 45.20, 'AUD', 'Jo', 'HSBC Star - Jo'),
             (current_date - 4, 'Fuel', 'Gas/fuel', 70.00, 'AUD', 'Alex', 'Macquarie - Alex'),
             (current_date - 3, 'Hawker lunch', 'Dining out', 9.80, 'SGD', 'Alex', 'UOB PPV')) v(d, descr, cat, amt, cur, who, card);

-- a trip with a purchase in a third currency on the SG card
insert into public.trips (household_id, name, start_date, end_date, currency, currencies, countries)
values (:'hh'::uuid, 'Test trip', current_date - 20, current_date - 14, 'JPY', '{JPY,SGD}', '{JP}');
insert into public.expenses (household_id, trip_id, date, description, category, amount, currency, payer_profile_id, payment_method_id, paid_with)
select :'hh'::uuid, t.id, current_date - 18, 'Ramen', 'Dining out', 1800, 'JPY',
       (select id from public.profiles where household_id = :'hh'::uuid and display_name = 'Alex'),
       (select id from public.payment_methods where household_id = :'hh'::uuid and name = 'UOB PPV'), 'UOB PPV'
from public.trips t where t.household_id = :'hh'::uuid and t.name = 'Test trip';

-- six months of everyday purchases, ~1,200 rows: several categories and cards, a few refunds, a few paid from the
-- Car Fund, a few dated later this month (scheduled)
insert into public.expenses (household_id, date, description, category, amount, currency, payer_profile_id, payment_method_id, paid_with, is_refund, fund_id)
select :'hh'::uuid, (date_trunc('month', current_date) - make_interval(months => i % 6))::date + (i * 7) % 28,
       (array['Grocer', 'Cafe', 'Train fare', 'Power bill', 'Chemist', 'Bakery', 'Hardware', 'Takeaway'])[i % 8 + 1] || ' #' || i,
       (array['Groceries', 'Dining out', 'Bus/train', 'Electricity', 'Health', 'Groceries', 'Home - Other', 'Dining out'])[i % 8 + 1],
       round(((i * 37) % 6000) / 100.0 + 2, 2), 'AUD',
       (select id from public.profiles where household_id = :'hh'::uuid and display_name = (case when i % 3 = 0 then 'Jo' else 'Alex' end)),
       pm.id, pm.name, i % 29 = 0, case when i % 31 = 0 then (select id from public.funds where household_id = :'hh'::uuid and name = 'Car Fund') end
  from generate_series(1, 1200) i
  join public.payment_methods pm on pm.household_id = :'hh'::uuid
   and pm.name = (array['Macquarie - Alex', 'Macquarie - Alex', 'HSBC Star - Jo', 'Bank - Joint'])[i % 4 + 1];
commit;

-- this month's plan, saved and applied (as Alex)
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'uid', true) \gset seedtmp_
select public.save_month_plan(date_trunc('month', current_date)::date,
  '[{"source_name": "Salary (synthetic)", "currency": "AUD", "amount": 7000}]',
  '[{"category_group": "Daily Expenses", "currency": "AUD", "amount": 1500}, {"category_group": "Transportation", "currency": "AUD", "amount": 300}, {"category_group": "Utilities", "currency": "AUD", "amount": 250}]',
  jsonb_build_array(jsonb_build_object('fund_id', (select id from public.funds where household_id = :'hh'::uuid and name = 'Car Fund'), 'amount', 200)),
  null) \gset seedtmp_
select public.apply_month_plan(date_trunc('month', current_date)::date) \gset seedtmp_
commit;
