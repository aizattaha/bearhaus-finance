-- Core invariants, run after the full migration chain on a scratch database.
-- Each block raises on failure; psql -v ON_ERROR_STOP=1 turns that into a non-zero exit.
-- A fresh household is created through the real onboarding RPC, as the app does it.

\set ON_ERROR_STOP on
begin;

-- the beta code the sign-up needs
insert into public.beta_invites (code, max_uses, used_count) values ('CI-TEST', 50, 0) on conflict do nothing;

-- ── sign up as a new owner ───────────────────────────────────────────────
insert into auth.users (id, email) values ('aaaaaaaa-0000-4000-8000-000000000001', 'ci-owner@test.local'),
                                          ('aaaaaaaa-0000-4000-8000-000000000002', 'ci-member@test.local'),
                                          ('aaaaaaaa-0000-4000-8000-000000000003', 'ci-outsider@test.local');
set local role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-4000-8000-000000000001', true);
select public.create_household_setup('CI-TEST', 'CI household', array['Owen', 'Mia'], 'Joint', array['AU', 'SG']) as hh \gset
select set_config('ci.hh', :'hh', true);

do $$
declare v_hh uuid := current_setting('ci.hh')::uuid; n int;
begin
  select count(*) into n from public.household_members where household_id = v_hh and role = 'owner';
  assert n = 1, 'onboarding writes the owner membership';
  select count(*) into n from public.funds where household_id = v_hh and is_spend_pot;
  assert n = 2, 'one spending pot per currency, got ' || n;
  select count(*) into n from public.categories where household_id = v_hh and group_id is null;
  assert n = 0, 'every seeded category has a group id';
  select count(*) into n from public.payment_methods where household_id = v_hh and kind = 'cash';
  assert n = 1, 'a Cash card is seeded';
end $$;

-- ── expenses: category ids, pot stamp, derived splits, refunds ───────────
select id as cash from public.payment_methods where household_id = :'hh' and kind = 'cash' \gset
select set_config('ci.cash', :'cash', true);
insert into public.payment_methods (household_id, name, kind, currency, profile_id)
values (:'hh', 'Visa — Owen', 'credit_card', 'AUD', (select id from public.profiles where household_id = :'hh' and display_name = 'Owen'))
returning id as visa \gset
select set_config('ci.visa', :'visa', true);
select id as pot from public.funds where household_id = :'hh' and currency = 'AUD' and is_spend_pot \gset
select set_config('ci.pot', :'pot', true);
select id as owen from public.profiles where household_id = :'hh' and display_name = 'Owen' \gset
select set_config('ci.owen', :'owen', true);

insert into public.daily_expenses (household_id, date, description, category, amount, currency, paid_with, payment_method_id)
values (:'hh', current_date, 'groceries', 'Groceries', 50, 'AUD', 'Visa — Owen', :'visa') returning id as e1 \gset
select set_config('ci.e1', :'e1', true);
insert into public.daily_expenses (household_id, date, description, category, amount, currency, paid_with, payment_method_id, payer_profile_id)
values (:'hh', current_date, 'cash coffee', 'Dining out', 4.5, 'AUD', 'Cash', :'cash', :'owen') returning id as e2 \gset
select set_config('ci.e2', :'e2', true);
insert into public.daily_expenses (household_id, date, description, category, amount, currency, paid_with, payment_method_id, is_refund)
values (:'hh', current_date, 'returned shoes', 'Clothing', 20, 'AUD', 'Visa — Owen', :'visa', true) returning id as e3 \gset
select set_config('ci.e3', :'e3', true);

do $$
declare v_hh uuid := current_setting('ci.hh')::uuid; v_pot uuid := current_setting('ci.pot')::uuid; r record; n int; v numeric;
begin
  select * into r from public.expenses where id = current_setting('ci.e1')::uuid;
  assert r.category_id is not null, 'category resolved from its name';
  assert r.pot_fund_id = v_pot, 'daily row stamped with the currency''s default pot';
  assert r.payer_profile_id is not null, 'a personal card names its owner as payer';
  assert r.created_by = 'aaaaaaaa-0000-4000-8000-000000000001', 'created_by is the signed-in user';
  select * into r from public.expenses where id = current_setting('ci.e2')::uuid;
  assert r.reconciled_by = 'auto' and r.reconciled_at is not null, 'cash rows tick themselves';
  select count(*) into n from public.expense_splits where expense_id = current_setting('ci.e2')::uuid;
  assert n = 2, 'payer + joint split rows are derived (got ' || n || ')';
  select sum(amount) into v from public.expense_splits where expense_id = current_setting('ci.e2')::uuid;
  assert v = 0, 'split rows net to zero';
  -- Available: 50 + 4.5 − 20 refund = 34.50 spent
  select balance into v from public.fund_balances where fund_id = v_pot;
  assert v = -34.50, 'pot Available counts the refund negative, got ' || v;
  select owed_on_cards into v from public.fund_cash where fund_id = v_pot;
  assert v = 30.00, 'owed on cards = card charges 50 − refund 20, got ' || v;
  select owed into v from public.card_balances where payment_method_id = current_setting('ci.visa')::uuid;
  assert v = 30.00, 'card owed 30, got ' || v;
end $$;

-- ── clients cannot write splits ──────────────────────────────────────────
do $$
begin
  begin
    insert into public.expense_splits (household_id, expense_id, profile_id, amount) values (current_setting('ci.hh')::uuid, current_setting('ci.e1')::uuid, null, 1);
    raise exception 'split insert should have been refused';
  exception when insufficient_privilege then null; end;
end $$;

-- ── renames carry history ────────────────────────────────────────────────
update public.categories set name = 'Supermarket' where household_id = :'hh' and kind = 'daily' and name = 'Groceries';
do $$
declare t text;
begin
  select category into t from public.expenses where id = current_setting('ci.e1')::uuid;
  assert t = 'Supermarket', 'renaming a category rewrites the expense text copy, got ' || t;
end $$;
update public.category_groups set name = 'Everyday' where household_id = :'hh' and kind = 'daily' and name = 'Daily Expenses';
do $$
declare n int;
begin
  select count(*) into n from public.categories where household_id = current_setting('ci.hh')::uuid and group_name = 'Daily Expenses';
  assert n = 0, 'renaming a group rewrites its categories';
end $$;

-- ── reconciliation locks ─────────────────────────────────────────────────
insert into public.statements (household_id, payment_method_id, period_start, period_end, statement_total)
values (:'hh', :'visa', date_trunc('month', current_date)::date, (date_trunc('month', current_date) + interval '1 month - 1 day')::date, 30) returning id as st \gset
select set_config('ci.st', :'st', true);
select public.reconcile_rows('expense', array[:'e1', :'e3']::uuid[], :'st');
do $$
declare ok boolean := false; v numeric; s text;
begin
  begin update public.expenses set amount = 1 where id = current_setting('ci.e1')::uuid; exception when others then ok := true; end;
  assert ok, 'a reconciled row refuses an amount change';
  ok := false;
  begin update public.expenses set amount = 1, reconciled_at = null, reconciled_by = null where id = current_setting('ci.e1')::uuid; exception when others then ok := true; end;
  assert ok, 'clearing the lock in the same update is refused';
  ok := false;
  begin delete from public.expenses where id = current_setting('ci.e1')::uuid; exception when others then ok := true; end;
  assert ok, 'a reconciled row refuses a delete';
  ok := false;
  begin perform public.soft_delete_rows('daily', array[current_setting('ci.e1')::uuid]::uuid[]); exception when others then ok := true; end;
  assert ok, 'a reconciled row refuses a soft delete';
  update public.expenses set comments = 'still editable' where id = current_setting('ci.e1')::uuid;   -- comments stay open
  select due, status into v, s from public.statement_balances where statement_id = current_setting('ci.st')::uuid;
  assert v = 30 and s = 'unpaid', 'statement due 30 unpaid, got ' || v || ' ' || s;
end $$;

-- ── card payment: Available unchanged, owed and cash move ────────────────
select public.record_card_payment(:'visa', current_date, jsonb_build_array(jsonb_build_object('fund_id', :'pot', 'amount', 30)), :'st') as grp \gset
select set_config('ci.grp', :'grp', true);
do $$
declare v numeric; s text; ok boolean := false;
begin
  select balance into v from public.fund_balances where fund_id = current_setting('ci.pot')::uuid;
  assert v = -34.50, 'Available does not move on a card payment, got ' || v;
  select owed_on_cards into v from public.fund_cash where fund_id = current_setting('ci.pot')::uuid;
  assert v = 0, 'owed on cards cleared by the payment, got ' || v;
  select status into s from public.statement_balances where statement_id = current_setting('ci.st')::uuid;
  assert s = 'paid', 'statement paid, got ' || s;
  begin perform public.record_card_payment(current_setting('ci.cash')::uuid, current_date, jsonb_build_array(jsonb_build_object('fund_id', current_setting('ci.pot')::uuid, 'amount', 1))); exception when others then ok := true; end;
  assert ok, 'paying a non-card is refused';
end $$;
select public.delete_card_payment(:'grp');

-- ── closed statement is read-only ────────────────────────────────────────
update public.statements set closed_at = now() where id = :'st';
do $$
declare ok boolean := false;
begin
  begin perform public.unreconcile_rows('expense', array[current_setting('ci.e1')::uuid]::uuid[]); exception when others then ok := true; end;
  assert ok, 'un-reconciling a row on a closed statement is refused';
end $$;
update public.statements set closed_at = null where id = :'st';
select public.unreconcile_rows('expense', array[:'e1', :'e3']::uuid[]);

-- ── transfers are a unit; soft delete + restore + bin ────────────────────
select id as sav from public.funds where household_id = :'hh' and currency = 'AUD' and is_leftover_target \gset
select set_config('ci.sav', :'sav', true);
insert into public.fund_transactions (household_id, fund_id, type, date, amount, remarks, origin, transfer_group_id)
values (:'hh', :'pot', 'expense', current_date, 10, 'Transfer → Savings', 'manual', 'bbbbbbbb-0000-4000-8000-000000000001'),
       (:'hh', :'sav', 'income',  current_date, 10, 'Transfer ← Float',   'manual', 'bbbbbbbb-0000-4000-8000-000000000001');
do $$
declare n int; k text;
begin
  select kind into k from public.fund_transactions where remarks = 'Transfer → Savings';
  assert k = 'allocation', 'a transfer is classed as an allocation, got ' || k;
  perform public.soft_delete_rows('fund', array[(select id from public.fund_transactions where remarks = 'Transfer → Savings')]::uuid[]);
  select count(*) into n from public.fund_transactions where transfer_group_id = 'bbbbbbbb-0000-4000-8000-000000000001';
  assert n = 0, 'both halves leave the live view together';
  select count(*) into n from public.recently_deleted where household_id = current_setting('ci.hh')::uuid and kind = 'fund';
  assert n = 2, 'both halves are in the bin';
  perform public.restore_rows('fund', array[(select id from public.fund_transactions_all where remarks = 'Transfer → Savings')]::uuid[]);
  select count(*) into n from public.fund_transactions where transfer_group_id = 'bbbbbbbb-0000-4000-8000-000000000001';
  assert n = 2, 'both halves come back';
  -- the app login can't hard-delete fund rows (Bundle A6); the bin above is the way out
  begin delete from public.fund_transactions where remarks = 'Transfer → Savings'; n := -1; exception when insufficient_privilege then n := 2; end;
  assert n = 2, 'the app login hard-deleted a fund row';
end $$;

-- ── members: a joined login works, a viewer can only read, outsiders see nothing ──
select public.create_member_invite((select id from public.profiles where household_id = :'hh' and display_name = 'Mia')) as code \gset
select set_config('ci.code', :'code', true);
select public.create_member_invite(null, 'viewer') as vcode \gset
select set_config('ci.vcode', :'vcode', true);
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-4000-8000-000000000002', true);
do $$
declare n int;
begin
  select count(*) into n from public.households; assert n = 0, 'before joining, nothing is visible';
  perform public.join_household(current_setting('ci.code'));
  select count(*) into n from public.households; assert n = 1, 'after joining, the household is visible';
  insert into public.daily_expenses (household_id, date, description, category, amount, currency, paid_with, payment_method_id)
  values (current_setting('ci.hh')::uuid, current_date, 'member adds', 'Supermarket', 3, 'AUD', 'Visa — Owen', current_setting('ci.visa')::uuid);
  select count(*) into n from public.audit_log where household_id = current_setting('ci.hh')::uuid and by_user = 'aaaaaaaa-0000-4000-8000-000000000002' and table_name = 'expenses';
  assert n = 1, 'the audit log names the member';
end $$;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-4000-8000-000000000003', true);
do $$
declare n int; ok boolean := false;
begin
  select count(*) into n from public.expenses; assert n = 0, 'an outsider reads nothing';
  perform public.join_household(current_setting('ci.vcode'));
  select count(*) into n from public.expenses; assert n > 0, 'a viewer reads';
  begin
    insert into public.daily_expenses (household_id, date, description, category, amount, currency, paid_with, payment_method_id)
    values (current_setting('ci.hh')::uuid, current_date, 'viewer adds', 'Supermarket', 3, 'AUD', 'Visa — Owen', current_setting('ci.visa')::uuid);
  exception when others then ok := true; end;
  assert ok, 'a viewer cannot write';
  -- QA round 2 (C-B1, C-B2): a viewer sees no invite codes and cannot purge the bin
  select count(*) into n from public.member_invites; assert n = 0, 'a viewer reads no invite codes, got ' || n;
  ok := false;
  begin perform public.purge_deleted(0); exception when others then ok := true; end;
  assert ok, 'a viewer cannot purge';
end $$;
-- a writer still sees the household's invites (it can make them)
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-4000-8000-000000000002', true);
do $$ declare n int; begin select count(*) into n from public.member_invites; assert n >= 1, 'a member reads invites'; end $$;

-- ── one household per login ──────────────────────────────────────────────
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-4000-8000-000000000001', true);
do $$
declare ok boolean := false;
begin
  begin perform public.create_household_setup('CI-TEST', 'Second', array['X'], null, array['AU']); exception when others then ok := true; end;
  assert ok, 'a login cannot own two households';
end $$;

rollback;
\echo core invariants hold
