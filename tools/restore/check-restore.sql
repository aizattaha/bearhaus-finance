-- Restore check (v2 sprint 1, first drill 15 Oct 2026). Run against a database you have just restored a
-- backup into. Prints counts and pass/fail only — never an amount — so the output can be shared.
--   psql "<restored database url>" -At -F ' · ' -f tools/restore/check-restore.sql
-- Every line marked "(want 0)" must be 0; "(want 4)" must be 4. See docs/RESTORE.md.

-- what came back
select 'tables in public', count(*) from pg_tables where schemaname = 'public';
select 'households / logins / members', (select count(*) from public.households) || ' / ' || (select count(*) from auth.users) || ' / ' || (select count(*) from public.household_members);
select 'purchases / fund rows / split rows', (select count(*) from public.expenses) || ' / ' || (select count(*) from public.fund_transactions_all) || ' / ' || (select count(*) from public.expense_splits);

-- the money rules
select 'purchases without a valid category (want 0)', count(*) from public.expenses e left join public.categories c on c.id = e.category_id where c.id is null or c.name <> e.category;
select 'paid-by-a-person purchases whose splits do not net to zero (want 0)', count(*) from (select e.id from public.expenses e join public.expense_splits s on s.expense_id = e.id where e.deleted_at is null and e.payer_profile_id is not null group by e.id having abs(sum(s.amount)) > 0.005) x;
select 'joint purchases whose split is not minus the amount (want 0)', count(*) from public.expenses e join public.expense_splits s on s.expense_id = e.id and s.profile_id is null where e.deleted_at is null and e.payer_profile_id is null and abs(s.amount + case when e.is_refund then -e.amount else e.amount end) > 0.005;
select 'live purchases with no joint split row (want 0)', count(*) from public.expenses e where e.deleted_at is null and not exists (select 1 from public.expense_splits s where s.expense_id = e.id and s.profile_id is null);
select 'same-currency transfers whose sides differ (want 0; known: 1 old row in a QA test household)', count(*) from (select t.transfer_group_id from public.fund_transactions_all t join public.funds f on f.id = t.fund_id where t.transfer_group_id is not null and t.kind = 'allocation' and t.deleted_at is null group by t.transfer_group_id having count(distinct f.currency) = 1 and abs(sum(case when t.type = 'income' then t.amount else -t.amount end)) > 0.005) x;
select 'half-deleted transfer groups (want 0)', count(*) from (select transfer_group_id from public.fund_transactions_all where transfer_group_id is not null group by transfer_group_id having bool_or(deleted_at is null) and bool_or(deleted_at is not null)) x;
select 'rows pointing at another household (want 0)', count(*) from public.expenses e left join public.payment_methods pm on pm.id = e.payment_method_id left join public.profiles p on p.id = e.payer_profile_id left join public.funds f on f.id = e.pot_fund_id where (pm.id is not null and pm.household_id <> e.household_id) or (p.id is not null and p.household_id <> e.household_id) or (f.id is not null and f.household_id <> e.household_id);
select 'purchases filed to a different pot than the rule (want 0)', count(*) from public.expenses e where e.trip_id is null and e.deleted_at is null and e.pot_fund_id is distinct from coalesce(e.fund_id, public.expense_pot_for(e.household_id, e.trip_id, e.category_id, e.category, e.currency, e.date));
select 'households or members whose login is missing (want 0)', (select count(*) from public.households h left join auth.users u on u.id = h.owner_user_id where u.id is null) + (select count(*) from public.household_members m left join auth.users u on u.id = m.user_id where u.id is null);
select 'money views computed (funds / cash / cards / statements)', (select count(*) from public.fund_balances) || ' / ' || (select count(*) from public.fund_cash) || ' / ' || (select count(*) from public.card_balances) || ' / ' || (select count(*) from public.statement_balances);

-- the doors (loading a dump re-grants the public key: tools/restore/before-load.sql before the load and
-- tools/restore/relock.sql after it, docs/RESTORE.md steps 4 and 6)
select 'functions the public key can run (want 4)', count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute');
select 'tables/views the public key can read (want 0)', count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind in ('r', 'v') and has_table_privilege('anon', c.oid, 'select');
select 'logins can run every function, so the load kept the automatic grants (want 0; redo from step 3 with before-load.sql)', (not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and not has_function_privilege('authenticated', p.oid, 'execute')))::int;
select 'tables with RLS off (want 0)', count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
