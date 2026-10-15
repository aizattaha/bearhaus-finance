-- Money moves as a whole (v2 sprint 3): the transfer / card-payment group check refuses at commit (sprint 2 only
-- noted it), the server's own multi-step edits still pass, an already-broken group can only be deleted as a unit,
-- and the bin empties a group together. Invariant 1 (DB-1 §5).

\set ON_ERROR_STOP on
begin;
insert into public.beta_invites (code, max_uses, used_count) values ('CI-GRP', 10, 0) on conflict do nothing;
insert into auth.users (id, email) values ('abababab-0000-4000-8000-000000000001', 'grp-owner@test.local');
set local role authenticated;
select set_config('request.jwt.claim.sub', 'abababab-0000-4000-8000-000000000001', true) \gset x_
select public.create_household_setup('CI-GRP', 'Groups house', array['Ana', 'Ben'], 'Joint', array['AU', 'SG']) as hh \gset
select set_config('ci.hh', :'hh', true) \gset x_
select public.bh_today(:'hh') as today \gset
select set_config('ci.today', :'today', true) \gset x_
select id as floatau from public.funds where household_id = :'hh' and name = 'Float AU' \gset
select id as savau from public.funds where household_id = :'hh' and name = 'Savings AU' \gset
select id as emerg from public.funds where household_id = :'hh' and name = 'Emergency fund AU' \gset
select id as floatsg from public.funds where household_id = :'hh' and name = 'Float SG' \gset
select id as savsg from public.funds where household_id = :'hh' and name = 'Savings SG' \gset
insert into public.payment_methods (household_id, name, kind, currency) values (:'hh', 'Visa', 'credit_card', 'AUD') returning id as visa \gset
insert into public.fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin)
values (:'hh', :'floatau', 'income', 'movement', :'today', 5000, 'opening', 'manual'),
       (:'hh', :'savau', 'income', 'movement', :'today', 5000, 'opening', 'manual'),
       (:'hh', :'floatsg', 'income', 'movement', :'today', 5000, 'opening', 'manual');
select public.record_transfer(:'floatau', :'emerg', :'today', 120, null, 'top-up') as g1 \gset
select public.record_card_payment(:'visa', :'today', jsonb_build_array(jsonb_build_object('fund_id', :'floatau', 'amount', 60),
                                                                       jsonb_build_object('fund_id', :'savau', 'amount', 40)), null, 'Visa') as gcp \gset
select set_config('ci.g1', :'g1', true) \gset x_
select set_config('ci.gcp', :'gcp', true) \gset x_
reset role;

-- ── 1 · a change that breaks a group is refused at commit ───────────────
-- (SET CONSTRAINTS … IMMEDIATE runs the pending commit-time check now, as COMMIT would)
do $$
declare ok boolean;
begin
  ok := false;
  begin
    update public.fund_transactions_all set amount = 121 where transfer_group_id = current_setting('ci.g1')::uuid and type = 'income';
    set constraints public.zz_fund_group_check immediate;
  exception when check_violation then ok := true; end;
  assert ok, 'one side of a transfer changed on its own';
  ok := false;
  begin
    update public.fund_transactions_all set date = date - 1 where transfer_group_id = current_setting('ci.g1')::uuid and type = 'expense';
    set constraints public.zz_fund_group_check immediate;
  exception when check_violation then ok := true; end;
  assert ok, 'transfer sides on different dates';
  ok := false;
  begin
    update public.fund_transactions_all set date = date - 1 where id = (select id from public.fund_transactions_all where transfer_group_id = current_setting('ci.gcp')::uuid limit 1);
    set constraints public.zz_fund_group_check immediate;
  exception when check_violation then ok := true; end;
  assert ok, 'card-payment legs on different dates';
  ok := false;
  begin
    insert into public.fund_transactions_all (household_id, fund_id, type, kind, date, amount, remarks, origin, transfer_group_id)
    values (current_setting('ci.hh')::uuid, (select fund_id from public.fund_transactions_all where transfer_group_id = current_setting('ci.g1')::uuid limit 1),
            'income', 'allocation', current_setting('ci.today')::date, 5, 'a third side', 'manual', current_setting('ci.g1')::uuid);
    set constraints public.zz_fund_group_check immediate;
  exception when check_violation then ok := true; end;
  assert ok, 'a third row joined a transfer';
  ok := false;
  begin
    insert into public.fund_transactions_all (household_id, fund_id, type, kind, date, amount, remarks, origin, transfer_group_id)
    values (current_setting('ci.hh')::uuid, (select fund_id from public.fund_transactions_all where transfer_group_id = current_setting('ci.g1')::uuid limit 1),
            'expense', 'allocation', current_setting('ci.today')::date, 5, 'half a transfer', 'manual', gen_random_uuid());
    set constraints public.zz_fund_group_check immediate;
  exception when check_violation then ok := true; end;
  assert ok, 'half a transfer was saved';
  -- nothing above stuck
  assert (select count(*) from public.fund_transactions_all where transfer_group_id = current_setting('ci.g1')::uuid) = 2, 'the transfer is still two rows';
  assert public.bh_group_problem(current_setting('ci.g1')::uuid) is null and public.bh_group_problem(current_setting('ci.gcp')::uuid) is null, 'both groups hold';
end $$;
set constraints public.zz_fund_group_check deferred;

-- ── 2 · a fix in several steps passes, because the check runs at commit ─
do $$
begin
  update public.fund_transactions_all set amount = 125 where transfer_group_id = current_setting('ci.g1')::uuid and type = 'income';
  update public.fund_transactions_all set amount = 125 where transfer_group_id = current_setting('ci.g1')::uuid and type = 'expense';
end $$;
set constraints public.zz_fund_group_check immediate;
set constraints public.zz_fund_group_check deferred;

-- the server's own group edits: a swap is recorded, re-rated and deleted; a card payment deleted; a transfer binned and restored
set local role authenticated;
insert into public.daily_expenses (household_id, date, description, category, amount, currency, payment_method_id)
values (:'hh', :'today', 'bought in S$ for an A$ purpose', 'Groceries', 50, 'SGD', (select id from public.payment_methods where household_id = :'hh' and kind = 'cash'))
returning id as sgbuy \gset
select public.record_pot_swap('daily', :'sgbuy', 1.1, :'floatau', :'savau', :'floatsg', :'savsg') as swap \gset
select public.update_pot_swap_rate(:'swap', 1.2) \gset x_
set constraints public.zz_fund_group_check immediate;
set constraints public.zz_fund_group_check deferred;
select public.delete_pot_swap(:'swap') \gset x_
select public.delete_card_payment(:'gcp') \gset x_
select public.soft_delete_rows('fund', array[:'g1'::uuid]) \gset x_
select public.restore_rows('fund', array(select id from public.fund_transactions_all where transfer_group_id = :'g1')) \gset x_
set constraints public.zz_fund_group_check immediate;
set constraints public.zz_fund_group_check deferred;
do $$
begin
  assert (select count(*) from public.fund_transactions where transfer_group_id = current_setting('ci.g1')::uuid) = 2, 'the transfer came back whole';
end $$;
reset role;

-- ── 3 · a group broken before sprint 3 can only go as a unit ────────────
-- (built with triggers off, the way a sprint-2 log-only break would have been left)
set session_replication_role = replica;
insert into public.fund_transactions_all (household_id, fund_id, type, kind, date, amount, remarks, origin, transfer_group_id, reconciled_at, reconciled_by)
values (:'hh', :'floatau', 'expense', 'allocation', :'today', 70, 'Transfer → Savings AU', 'manual', 'abababab-0000-4000-8000-0000000000b1', now(), 'auto'),
       (:'hh', :'savau', 'income', 'allocation', :'today', 69, 'Transfer ← Float AU', 'manual', 'abababab-0000-4000-8000-0000000000b1', now(), 'auto');
set session_replication_role = origin;
do $$ begin assert public.bh_group_problem('abababab-0000-4000-8000-0000000000b1') = 'transfer sides differ', 'the legacy group is broken'; end $$;
set local role authenticated;
do $$
declare ok boolean := false;
begin
  begin
    update public.fund_transactions set remarks = 'Transfer → Savings AU · note' where transfer_group_id = 'abababab-0000-4000-8000-0000000000b1' and type = 'expense';
    set constraints public.zz_fund_group_check immediate;
  exception when check_violation then ok := true; end;
  assert ok, 'an edit to a broken group went through';
end $$;
set constraints public.zz_fund_group_check deferred;
select public.soft_delete_rows('fund', array(select id from public.fund_transactions where transfer_group_id = 'abababab-0000-4000-8000-0000000000b1' limit 1)) as n \gset
set constraints public.zz_fund_group_check immediate;   -- deleting it as a unit passes
set constraints public.zz_fund_group_check deferred;
do $$
declare ok boolean := false;
begin
  assert (select count(*) from public.fund_transactions_all where transfer_group_id = 'abababab-0000-4000-8000-0000000000b1' and deleted_at is not null) = 2, 'both sides went to the bin';
  begin
    perform public.restore_rows('fund', array(select id from public.fund_transactions_all where transfer_group_id = 'abababab-0000-4000-8000-0000000000b1'));
    set constraints public.zz_fund_group_check immediate;
  exception when check_violation then ok := true; end;
  assert ok, 'a broken group came back out of the bin';
end $$;
set constraints public.zz_fund_group_check deferred;
reset role;

-- ── 4 · the bin empties a group together, after 30 days ─────────────────
select public.record_transfer(:'floatau', :'savau', :'today', 10) as gold \gset
select public.record_transfer(:'floatau', :'savau', :'today', 11) as gmixed \gset
update public.fund_transactions_all set deleted_at = now() - interval '40 days' where transfer_group_id in (:'gold', :'gmixed');
update public.fund_transactions_all set deleted_at = now() - interval '40 days' where transfer_group_id = 'abababab-0000-4000-8000-0000000000b1';
-- one side of the second transfer binned recently: the pair waits for it
update public.fund_transactions_all set deleted_at = now() - interval '5 days' where transfer_group_id = :'gmixed' and type = 'income';
select set_config('ci.gold', :'gold', true) \gset x_
select set_config('ci.gmixed', :'gmixed', true) \gset x_
set local role authenticated;
select public.purge_deleted(1) as purged \gset
set constraints public.zz_fund_group_check immediate;
set constraints public.zz_fund_group_check deferred;
do $$
begin
  assert (select count(*) from public.fund_transactions_all where transfer_group_id = current_setting('ci.gold')::uuid) = 0, 'an old binned transfer is purged whole';
  assert (select count(*) from public.fund_transactions_all where transfer_group_id = 'abababab-0000-4000-8000-0000000000b1') = 0, 'the broken group is purged whole';
  assert (select count(*) from public.fund_transactions_all where transfer_group_id = current_setting('ci.gmixed')::uuid) = 2, 'a pair with a recent side waits';
end $$;
reset role;
-- a day's window is still 30 days: something binned 5 days ago stays
do $$ begin assert exists (select 1 from public.fund_transactions_all where deleted_at > now() - interval '6 days'), 'recent bin rows stay'; end $$;

-- the nightly check sees no broken group left
do $$ begin assert (select bad from public.bh_money_check() where check_name like 'transfer and card-payment groups%') = 0, 'no broken group left'; end $$;

rollback;
\echo groups hold
