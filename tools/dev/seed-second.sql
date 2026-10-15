-- A second, unrelated login and household for the local stack (tools/dev/seed.sh, v2 sprint 3). Sign in as the
-- owner, sign out, sign in as this login: nothing of the first household may show. Made-up names and amounts only.
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', :'uid', true) \gset seedtmp_
select public.create_household_setup('LOCAL-SEED', 'Second Test House', array['Sam'], null, array['AU']) as hh \gset
reset role;
insert into public.fund_transactions (household_id, fund_id, type, date, amount, remarks, origin)
select :'hh'::uuid, f.id, 'income', current_date - 3, 500, 'opening (synthetic)', 'manual'
from public.funds f where f.household_id = :'hh'::uuid and f.name = 'Float AU';
insert into public.expenses (household_id, date, description, category, amount, currency, payer_profile_id)
select :'hh'::uuid, current_date - 1, 'Second-house bakery', 'Groceries', 7.40, 'AUD',
       (select id from public.profiles where household_id = :'hh'::uuid and display_name = 'Sam');
commit;
