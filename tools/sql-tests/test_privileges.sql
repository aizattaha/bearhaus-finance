-- Privileges and client-write guards (v2 sprint 1): what the public app key, an outsider, a member and a
-- viewer can and cannot do, checked against the catalog and by trying it. Runs after the full chain.

\set ON_ERROR_STOP on
begin;
insert into public.beta_invites (code, max_uses, used_count) values ('CI-PRIV', 10, 0) on conflict do nothing;
insert into auth.users (id, email) values ('cccccccc-0000-4000-8000-000000000001', 'priv-owner@test.local'),
                                          ('cccccccc-0000-4000-8000-000000000002', 'priv-member@test.local'),
                                          ('cccccccc-0000-4000-8000-000000000003', 'priv-outsider@test.local');

-- ── catalog: the public key runs nothing but the sign-up checks, and owns no table rights ──
do $$
declare v text;
begin
  select string_agg(p.oid::regprocedure::text, ', ') into v from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not in ('check_invite', 'invite_info', 'bh_member_of', 'bh_writer_of');
  assert v is null, 'anon can execute: ' || coalesce(v, '');
  select string_agg(c.relname, ', ') into v from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'v', 'p')
     and (has_table_privilege('anon', c.oid, 'select') or has_table_privilege('anon', c.oid, 'insert')
       or has_table_privilege('anon', c.oid, 'update') or has_table_privilege('anon', c.oid, 'delete'));
  assert v is null, 'anon has table rights on: ' || coalesce(v, '');
  select string_agg(c.relname, ', ') into v from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and has_table_privilege('authenticated', c.oid, 'truncate');
  assert v is null, 'authenticated may truncate: ' || coalesce(v, '');
  -- every table in public has RLS on
  select string_agg(c.relname, ', ') into v from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
  assert v is null, 'RLS is off on: ' || coalesce(v, '');
  -- every view runs with the reader's own rights, so RLS applies (CREATE OR REPLACE VIEW drops the option if it isn't restated)
  select string_agg(c.relname, ', ') into v from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'v' and not coalesce(c.reloptions @> array['security_invoker=true'], false);
  assert v is null, 'views that bypass RLS: ' || coalesce(v, '');
  -- internal helpers are not callable by a signed-in login
  assert not has_function_privilege('authenticated', 'public.restamp_pots(uuid, date, date, text)', 'execute'), 'restamp_pots is callable by a login';
  assert not has_function_privilege('authenticated', 'public.seed_default_categories(uuid)', 'execute'), 'seed_default_categories is callable by a login';
  assert not has_function_privilege('authenticated', 'public.bh_rederive_trip_sends(uuid)', 'execute'), 'bh_rederive_trip_sends is callable by a login';
  assert not has_function_privilege('authenticated', 'public.bh_undo_send(uuid)', 'execute'), 'bh_undo_send is callable by a login';
  assert not has_function_privilege('authenticated', 'public.bh_send_resum(uuid)', 'execute'), 'bh_send_resum is callable by a login';
  assert not has_function_privilege('authenticated', 'public.bh_trip_send_lines(uuid, uuid, jsonb)', 'execute'), 'bh_trip_send_lines is callable by a login';
  assert not has_function_privilege('anon', 'public.send_trip(uuid, date, jsonb)', 'execute'), 'anon could send a trip';
  assert not has_function_privilege('anon', 'public.refund_purchases(jsonb, date, text, text, uuid)', 'execute'), 'anon could refund a purchase';
  assert not has_function_privilege('authenticated', 'public.bh_expense_refunds_sync()', 'execute'), 'the refunds trigger is callable by a login';
  assert not has_function_privilege('anon', 'public.trip_send_plan(uuid)', 'execute'), 'anon could read a trip plan';
  -- Bundle A: the cross-check and the card/move helpers are the server's
  assert not has_function_privilege('authenticated', 'public.bh_owed_gaps()', 'execute'), 'bh_owed_gaps is callable by a login';
  assert not has_function_privilege('authenticated', 'public.bh_card_in_use(uuid)', 'execute'), 'bh_card_in_use is callable by a login';
  assert not has_function_privilege('authenticated', 'public.bh_card_guard()', 'execute'), 'the card guard is callable by a login';
  assert not has_function_privilege('authenticated', 'public.bh_on_card_owed(uuid, uuid, date)', 'execute'), 'bh_on_card_owed is callable by a login';
  assert not has_function_privilege('authenticated', 'public.bh_assert_move(uuid, uuid, date, numeric, uuid, uuid, public.fund_money, text)', 'execute'), 'bh_assert_move is callable by a login';
  assert not has_function_privilege('anon', 'public.record_card_payment(uuid, date, jsonb, uuid, text, uuid)', 'execute'), 'anon could pay a card';
  assert not has_function_privilege('anon', 'public.link_card_payment(uuid, uuid)', 'execute'), 'anon could link a payment';
  -- Bundle A6: no hard deletes from the app login on the money tables (the bin is the way out); the two settings tables keep theirs
  select string_agg(t, ', ') into v from unnest(array['expenses', 'daily_expenses', 'travel_expenses', 'fund_transactions', 'fund_transactions_all']) t
   where has_table_privilege('authenticated', 'public.' || t, 'delete');
  assert v is null, 'a login can hard-delete from: ' || coalesce(v, '');
  assert not exists (select 1 from pg_policies where schemaname = 'public' and tablename in ('expenses', 'fund_transactions_all') and cmd = 'DELETE'),
         'a delete policy is left on a money table';
  assert has_table_privilege('authenticated', 'public.card_defaults', 'delete') and has_table_privilege('authenticated', 'public.card_openings', 'delete'),
         'card defaults and openings can still be removed';
  assert exists (select 1 from pg_trigger where tgname = 'expenses_sent_lock' and tgrelid = 'public.expenses'::regclass and (tgtype & 8) = 8),
         'the sent lock fires on DELETE too';
end $$;

-- every server function and table/view the two apps use is still reachable by a signed-in login
do $$
declare v text;
begin
  select string_agg(f, ', ') into v from unnest(array[
    'check_invite','create_household_setup','create_member_invite','delete_card_payment','delete_pot_swap','invite_info',
    'join_household','keep_fund_spend','link_my_profile','move_expense_to_fund_spend','move_fund_spend_to_expenses',
    'pot_month_spend','purge_deleted','reconcile_rows','record_card_payment','record_pot_swap','remove_member','restore_rows',
    'revoke_member_invite','save_expense','save_month_plan','send_trip','undo_trip_send','trip_send_plan','set_trip_fund','refund_purchases','soft_delete_rows',
    'unreconcile_rows','update_pot_swap_rate','desk_add_expense','desk_set_card','record_transfer','apply_month_plan','plan_status','set_settled_amount','fund_history',
    'app_bootstrap','home_summary','budget_summary','household_money','trip_summary','link_card_payment','cards_in_use','ops_heartbeat']) f
   where not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                      where n.nspname = 'public' and p.proname = f and has_function_privilege('authenticated', p.oid, 'execute'));
  assert v is null, 'a login can no longer run: ' || coalesce(v, '');
  select string_agg(t, ', ') into v from unnest(array[
    'audit_log','card_balances','categories','category_budgets','category_groups','daily_expenses','fund_balances',
    'fund_balances_cleared','fund_budgets','fund_cash','fund_spend_sort','fund_transactions','funds','household_members',
    'households','income_budgets','member_invites','payment_methods','pot_swaps','profiles','recently_deleted',
    'statement_balances','statements','travel_expenses','trips','card_openings','card_defaults','plan_applications','fund_money']) t
   where not has_table_privilege('authenticated', 'public.' || t, 'select');
  assert v is null, 'a login can no longer read: ' || coalesce(v, '');
end $$;

-- a function a future migration creates without a grant is not callable by anyone but the owner
create function public._ci_new_fn() returns int language sql as 'select 1';
do $$ begin
  assert not has_function_privilege('anon', 'public._ci_new_fn()', 'execute'), 'a new function is callable by anon by default';
  assert not has_function_privilege('authenticated', 'public._ci_new_fn()', 'execute'), 'a new function is callable by a login by default';
end $$;
drop function public._ci_new_fn();

-- ── the public key can't reach the helpers ───────────────────────────────
set local role anon;
do $$
declare ok boolean := false;
begin
  begin perform public.bh_category_for(gen_random_uuid(), 'daily', 'spam'); exception when insufficient_privilege then ok := true; end;
  assert ok, 'anon could call bh_category_for';
  ok := false;
  begin perform public.restamp_pots(gen_random_uuid()); exception when insufficient_privilege then ok := true; end;
  assert ok, 'anon could call restamp_pots';
  ok := false;
  begin perform count(*) from public.expenses; exception when insufficient_privilege then ok := true; end;
  assert ok, 'anon could select from expenses';
  perform public.check_invite('nope');   -- the sign-up checks still work
end $$;
reset role;

-- ── a household, a member, an outsider ───────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claim.sub', 'cccccccc-0000-4000-8000-000000000001', true);
select public.create_household_setup('CI-PRIV', 'Priv household', array['Pat', 'Sam'], 'Joint', array['AU']) as hh \gset
select set_config('ci.hh', :'hh', true);
select public.create_member_invite((select id from public.profiles where household_id = :'hh' and display_name = 'Sam')) as code \gset
select id as pot from public.funds where household_id = :'hh' and is_spend_pot \gset
select id as sav from public.funds where household_id = :'hh' and is_leftover_target \gset
select set_config('ci.pot', :'pot', true);
select set_config('ci.sav', :'sav', true);
select id as cash from public.payment_methods where household_id = :'hh' and kind = 'cash' \gset
insert into public.payment_methods (household_id, name, kind, currency) values (:'hh', 'Visa — Pat', 'credit_card', 'AUD') returning id as visa \gset
insert into public.statements (household_id, payment_method_id, period_start, period_end) values (:'hh', :'visa', current_date - 30, current_date) returning id as stmt \gset
select set_config('ci.visa', :'visa', true);
select set_config('ci.stmt', :'stmt', true);

-- an outsider can't create categories in someone else's household through the helper
select set_config('request.jwt.claim.sub', 'cccccccc-0000-4000-8000-000000000003', true);
do $$
declare ok boolean := false;
begin
  begin perform public.bh_category_for(current_setting('ci.hh')::uuid, 'daily', 'spam'); exception when insufficient_privilege then ok := true; end;
  assert ok, 'an outsider could create a category in another household';
end $$;

-- the member joins; it may rename the household but not take it over or delete it
select set_config('request.jwt.claim.sub', 'cccccccc-0000-4000-8000-000000000002', true);
select public.join_household(:'code');
do $$
declare ok boolean := false; n int;
begin
  update public.households set name = 'Renamed by member' where id = current_setting('ci.hh')::uuid;
  get diagnostics n = row_count; assert n = 1, 'a member can rename the household';
  begin
    update public.households set owner_user_id = 'cccccccc-0000-4000-8000-000000000002' where id = current_setting('ci.hh')::uuid;
  exception when insufficient_privilege then ok := true; end;
  assert ok, 'a member could change the household owner';
  ok := false;
  begin update public.households set pot_start = '2020-01-01' where id = current_setting('ci.hh')::uuid; exception when insufficient_privilege then ok := true; end;
  assert ok, 'a member could move pot_start';
  ok := false;
  begin delete from public.households where id = current_setting('ci.hh')::uuid; exception when insufficient_privilege then ok := true; end;
  assert ok, 'a member could delete the household';
end $$;

-- ── a direct write can't forge server-owned columns ──────────────────────
insert into public.daily_expenses (household_id, date, description, category, amount, currency, paid_with, payment_method_id,
                                   reconciled_at, reconciled_by, reconciled_statement_id)
values (:'hh', current_date, 'forged tick', 'Groceries', 10, 'AUD', 'Visa — Pat', :'visa', now(), 'manual', :'stmt') returning id as e1 \gset
select set_config('ci.e1', :'e1', true);
insert into public.daily_expenses (household_id, date, description, category, amount, currency, paid_with, payment_method_id)
values (:'hh', current_date, 'cash still ticks', 'Groceries', 3, 'AUD', 'Cash', :'cash') returning id as e2 \gset
select set_config('ci.e2', :'e2', true);
do $$
declare r record;
begin
  select * into r from public.expenses where id = current_setting('ci.e1')::uuid;
  assert r.reconciled_at is null and r.reconciled_statement_id is null, 'a client inserted a row already reconciled';
  assert r.created_by = 'cccccccc-0000-4000-8000-000000000002', 'created_by is the signed-in login';
  assert r.pot_fund_id = current_setting('ci.pot')::uuid, 'the pot is stamped by the server';
  select * into r from public.expenses where id = current_setting('ci.e2')::uuid;
  assert r.reconciled_by = 'auto', 'cash still reconciles itself';
  -- and it can't be hard-deleted: through the view, or the table
  begin delete from public.daily_expenses where id = current_setting('ci.e2')::uuid; assert false, 'a member hard-deleted a purchase';
  exception when insufficient_privilege then null; end;
  begin delete from public.expenses where id = current_setting('ci.e2')::uuid; assert false, 'a member hard-deleted from expenses';
  exception when insufficient_privilege then null; end;
  -- created_by, the bin date and the pot stamp ignore a direct update
  update public.expenses set created_by = 'cccccccc-0000-4000-8000-000000000001', deleted_at = now(), pot_fund_id = current_setting('ci.sav')::uuid
   where id = current_setting('ci.e1')::uuid;
  select * into r from public.expenses where id = current_setting('ci.e1')::uuid;
  assert r.created_by = 'cccccccc-0000-4000-8000-000000000002', 'created_by was rewritten by a client';
  assert r.deleted_at is null, 'a client soft-deleted by writing deleted_at';
  assert r.pot_fund_id = current_setting('ci.pot')::uuid, 'a client re-filed a purchase by writing pot_fund_id';
end $$;

-- ── one side of a transfer can't be edited on its own ────────────────────
insert into public.fund_transactions (household_id, fund_id, type, date, amount, remarks, origin, transfer_group_id)
values (:'hh', :'pot', 'expense', current_date, 25, 'Transfer → Savings', 'manual', 'dddddddd-0000-4000-8000-000000000001'),
       (:'hh', :'sav', 'income',  current_date, 25, 'Transfer ← Float',   'manual', 'dddddddd-0000-4000-8000-000000000001');
do $$
declare ok boolean := false; n int;
begin
  begin update public.fund_transactions set amount = 99 where remarks = 'Transfer → Savings'; exception when raise_exception then ok := true; end;
  assert ok, 'one side of a transfer was edited on its own (amount)';
  ok := false;
  begin update public.fund_transactions set date = current_date - 3 where remarks = 'Transfer ← Float'; exception when raise_exception then ok := true; end;
  assert ok, 'one side of a transfer was edited on its own (date)';
  ok := false;
  begin update public.fund_transactions set fund_id = current_setting('ci.pot')::uuid where remarks = 'Transfer ← Float'; exception when raise_exception then ok := true; end;
  assert ok, 'one side of a transfer was moved to another fund';
  update public.fund_transactions set remarks = 'Transfer → Savings · note' where remarks = 'Transfer → Savings';
  get diagnostics n = row_count; assert n = 1, 'the note on a transfer can still change';
  -- an ungrouped row can't be paired up by an edit
  insert into public.fund_transactions (household_id, fund_id, type, date, amount, remarks, origin)
  values (current_setting('ci.hh')::uuid, current_setting('ci.pot')::uuid, 'income', current_date, 5, 'interest', 'manual');
  ok := false;
  begin update public.fund_transactions set transfer_group_id = 'dddddddd-0000-4000-8000-000000000001' where remarks = 'interest'; exception when raise_exception then ok := true; end;
  assert ok, 'a row was paired into a transfer by an edit';
  -- deleting one side still removes both (the unit rule is unchanged)
  perform public.soft_delete_rows('fund', array[(select id from public.fund_transactions where remarks = 'Transfer → Savings · note')]::uuid[]);
  select count(*) into n from public.fund_transactions where transfer_group_id = 'dddddddd-0000-4000-8000-000000000001';
  assert n = 0, 'both sides go to the bin together';
end $$;

rollback;
\echo privileges and client guards hold
