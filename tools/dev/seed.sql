-- Synthetic household for the local stack (tools/dev/seed.sh). Made-up names and amounts only.
-- A two-country couple shaped like the real one: AU + SG funds, personal and shared cards, a travel-only SG
-- card, an archived card, a transfer, a trip, purchases either side of the start date.
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
commit;
