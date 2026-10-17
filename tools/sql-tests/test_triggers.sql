-- Calmer triggers and ids, not names (v2 sprint 3; D2-11, E1-F12):
--   · re-filing moves exactly the purchases whose pot changes, from this month on, and the set-based re-file
--     agrees with the per-row rule; a non-pot fund change re-files nothing
--   · a re-file or a rename copied into rows writes no Activity line and leaves updated_at/updated_by alone, so
--     an edit open on the other phone still saves
--   · saving the plan touches only the lines that changed
--   · a card or category sent by id lands; changing a card by name moves the card (it used to move only the name)

\set ON_ERROR_STOP on
begin;
insert into public.beta_invites (code, max_uses, used_count) values ('CI-TRG', 10, 0) on conflict do nothing;
insert into auth.users (id, email) values ('cdcdcdcd-0000-4000-8000-000000000001', 'trg-owner@test.local'),
                                          ('cdcdcdcd-0000-4000-8000-000000000002', 'trg-other@test.local');
set local role authenticated;
select set_config('request.jwt.claim.sub', 'cdcdcdcd-0000-4000-8000-000000000002', true) \gset x_
select public.create_household_setup('CI-TRG', 'Other house', array['Zed'], null, array['AU']) as otherhh \gset
select id as othercat from public.categories where household_id = :'otherhh' and kind = 'daily' and name = 'Groceries' \gset
select id as othercard from public.payment_methods where household_id = :'otherhh' and kind = 'cash' \gset
select set_config('request.jwt.claim.sub', 'cdcdcdcd-0000-4000-8000-000000000001', true) \gset x_
select public.create_household_setup('CI-TRG', 'Trigger house', array['Ana', 'Ben'], 'Joint', array['AU']) as hh \gset
select set_config('ci.hh', :'hh', true) \gset x_
select public.bh_today(:'hh') as today \gset
select date_trunc('month', :'today'::date)::date as month \gset
select set_config('ci.month', :'month', true) \gset x_
select id as floatau from public.funds where household_id = :'hh' and is_spend_pot and currency = 'AUD' \gset
select id as savau from public.funds where household_id = :'hh' and is_leftover_target and currency = 'AUD' \gset
select set_config('ci.floatau', :'floatau', true) \gset x_
insert into public.funds (household_id, name, country, currency, group_name, sort_order, is_spend_pot)
values (:'hh', 'Groceries pot', 'AU', 'AUD', '', 9, true) returning id as grocpot \gset
select set_config('ci.grocpot', :'grocpot', true) \gset x_
select id as ana from public.profiles where household_id = :'hh' and display_name = 'Ana' \gset
insert into public.payment_methods (household_id, name, profile_id, kind, currency) values (:'hh', 'Card A', :'ana', 'credit_card', 'AUD') returning id as carda \gset
insert into public.payment_methods (household_id, name, profile_id, kind, currency) values (:'hh', 'Card B', :'ana', 'credit_card', 'AUD') returning id as cardb \gset
select id as groc from public.categories where household_id = :'hh' and kind = 'daily' and name = 'Groceries' \gset
select id as dining from public.categories where household_id = :'hh' and kind = 'daily' and name = 'Dining out' \gset
select id as bus from public.categories where household_id = :'hh' and kind = 'daily' and name = 'Bus/train' \gset
reset role;
update public.households set pot_start = (:'month'::date - interval '2 months')::date where id = :'hh';
set local role authenticated;

-- ── ids, not names ──────────────────────────────────────────────────────
-- a new purchase sent by id only: the names are filled in by the server
insert into public.daily_expenses (household_id, date, description, category_id, amount, currency, payment_method_id)
values (:'hh', :'today', 'by id', :'groc', 20, 'AUD', :'carda') returning id as e1 \gset
-- this month and last month, a few categories
insert into public.daily_expenses (household_id, date, description, category_id, amount, currency, payment_method_id)
select :'hh', case when i % 2 = 0 then :'month'::date else (:'month'::date - interval '1 month')::date end, 'row ' || i,
       (array[:'groc', :'dining', :'bus']::uuid[])[i % 3 + 1], 10 + i, 'AUD', :'carda'
  from generate_series(1, 30) i;
select set_config('ci.e1', :'e1', true) \gset x_
select set_config('ci.carda', :'carda', true) \gset x_
select set_config('ci.cardb', :'cardb', true) \gset x_
select set_config('ci.groc', :'groc', true) \gset x_
select set_config('ci.dining', :'dining', true) \gset x_
do $$
declare r record;
begin
  select category, paid_with, payer_profile_id, pot_fund_id into r from public.expenses where id = current_setting('ci.e1')::uuid;
  assert r.category = 'Groceries' and r.paid_with = 'Card A', 'names follow the ids, got ' || r.category || ' / ' || r.paid_with;
  assert r.payer_profile_id is not null, 'the card''s owner pays';
  assert r.pot_fund_id = current_setting('ci.floatau')::uuid, 'filed to the A$ pot';
end $$;

-- save_expense by id: the card and the category move, and their names follow
select public.save_expense('daily', :'e1', :'today', 'by id', null, 20, 'AUD', null, null, '', null, null, false, null, :'dining', :'cardb') \gset x_
do $$
declare r record;
begin
  select category, category_id, paid_with, payment_method_id into r from public.expenses where id = current_setting('ci.e1')::uuid;
  assert r.category_id = current_setting('ci.dining')::uuid and r.category = 'Dining out', 'category by id';
  assert r.payment_method_id = current_setting('ci.cardb')::uuid and r.paid_with = 'Card B', 'card by id';
end $$;
-- changing the card BY NAME moves the card, not just its name (the sprint-3 fix)
select public.save_expense('daily', :'e1', :'today', 'by name', 'Dining out', 20, 'AUD', null, 'Card A', '') \gset x_
do $$
declare ok boolean := false;
begin
  assert (select payment_method_id from public.expenses where id = current_setting('ci.e1')::uuid) = current_setting('ci.carda')::uuid,
         'a card changed by name moved the card';
  begin perform public.save_expense('daily', current_setting('ci.e1')::uuid, current_setting('ci.month')::date, 'x', 'Dining out', 20, 'AUD', null, 'No such card', '');
  exception when raise_exception then ok := true; end;
  assert ok, 'an unknown card name dropped the card instead of refusing';
  assert (select payment_method_id from public.expenses where id = current_setting('ci.e1')::uuid) = current_setting('ci.carda')::uuid, 'still on Card A';
end $$;
-- another household's category or card is refused
select set_config('ci.othercat', :'othercat', true) \gset x_
select set_config('ci.othercard', :'othercard', true) \gset x_
do $$
declare ok boolean := false;
begin
  begin perform public.save_expense('daily', current_setting('ci.e1')::uuid, current_setting('ci.month')::date, 'x', null, 20, 'AUD', null, null, '',
                                    null, null, false, null, current_setting('ci.othercat')::uuid, null);
  exception when raise_exception then ok := true; end;
  assert ok, 'another household''s category was accepted';
  ok := false;
  begin perform public.save_expense('daily', current_setting('ci.e1')::uuid, current_setting('ci.month')::date, 'x', null, 20, 'AUD', null, null, '',
                                    null, null, false, null, null, current_setting('ci.othercard')::uuid);
  exception when raise_exception then ok := true; end;
  assert ok, 'another household''s card was accepted';
end $$;
-- the Desk adds by id too
select public.desk_add_expense(jsonb_build_object('date', :'today', 'description', 'desk by id', 'category_id', :'groc', 'amount', 7.5,
                                                  'currency', 'AUD', 'payment_method_id', :'carda')) as e2 \gset
select set_config('ci.e2', :'e2', true) \gset x_
do $$ begin
  assert (select category from public.expenses where id = current_setting('ci.e2')::uuid) = 'Groceries', 'the Desk''s category by id';
end $$;

-- ── a re-file is not an edit ────────────────────────────────────────────
reset role;
select set_config('ci.audit0', (select count(*) from public.audit_log where household_id = :'hh' and table_name = 'expenses' and op = 'update')::text, true) \gset x_
-- every row here was written in this one transaction, so "now" never moves: date them an hour back first, or a
-- re-file that stamps them as edited would go unseen (it did, sprint 3 → 17 Oct)
alter table public.expenses disable trigger zz_expenses_touch;
update public.expenses set updated_at = updated_at - interval '1 hour' where household_id = :'hh';
alter table public.expenses enable trigger zz_expenses_touch;
create temp table _seen as select id, updated_at, updated_by, pot_fund_id, date from public.expenses where household_id = :'hh';
grant select on _seen to authenticated;
set local role authenticated;
-- the plan names the Groceries pot for Daily Expenses: this month's Daily Expenses purchases move there, last month's stay
select version as v0 from public.plan_status(:'month') \gset
select public.save_month_plan(:'month', '[]',
  jsonb_build_array(jsonb_build_object('category_group', 'Daily Expenses', 'currency', 'AUD', 'amount', 500, 'pot_fund_id', :'grocpot'),
                    jsonb_build_object('category_group', 'Transportation', 'currency', 'AUD', 'amount', 100)),
  '[]', :'v0') \gset x_
reset role;
do $$
declare v_moved int; v_wrong int; v_past int; v_audit int; v_touched int;
begin
  select count(*) into v_moved from public.expenses e join _seen s using (id)
   where e.pot_fund_id is distinct from s.pot_fund_id;
  select count(*) into v_wrong from public.expenses e join public.categories c on c.id = e.category_id
   where e.household_id = current_setting('ci.hh')::uuid and e.date >= current_setting('ci.month')::date and e.deleted_at is null
     and c.group_name = 'Daily Expenses' and e.pot_fund_id is distinct from current_setting('ci.grocpot')::uuid;
  assert v_moved > 0 and v_wrong = 0, 'this month''s Daily Expenses moved to the Groceries pot (moved ' || v_moved || ', wrong ' || v_wrong || ')';
  select count(*) into v_past from public.expenses e join _seen s using (id) where e.date < current_setting('ci.month')::date and e.pot_fund_id is distinct from s.pot_fund_id;
  assert v_past = 0, 'last month''s purchases stayed put, moved ' || v_past;
  select count(*) into v_audit from public.audit_log where household_id = current_setting('ci.hh')::uuid and table_name = 'expenses' and op = 'update';
  assert v_audit = current_setting('ci.audit0')::int, 'the re-file wrote ' || (v_audit - current_setting('ci.audit0')::int) || ' Activity lines';
  select count(*) into v_touched from public.expenses e join _seen s using (id) where e.updated_at <> s.updated_at or e.updated_by is distinct from s.updated_by;
  assert v_touched = 0, 'the re-file stamped ' || v_touched || ' purchases as edited';
end $$;
-- the set-based re-file agrees with the per-row rule
do $$
declare v_bad int;
begin
  perform public.restamp_pots(current_setting('ci.hh')::uuid);
  select count(*) into v_bad from public.expenses e
   where e.household_id = current_setting('ci.hh')::uuid and e.trip_id is null
     and e.pot_fund_id is distinct from coalesce(e.fund_id, public.expense_pot_for(e.household_id, e.trip_id, e.category_id, e.category, e.currency, e.date));
  assert v_bad = 0, 'the set-based re-file disagrees with expense_pot_for on ' || v_bad || ' rows';
end $$;
set local role authenticated;
-- an edit opened before the re-file still saves (its updated_at didn't move)
select updated_at as seen from _seen where id = :'e1' \gset
select public.save_expense('daily', :'e1', :'today', 'edited after the re-file', 'Dining out', 21, 'AUD', null, 'Card A', '', :'seen') \gset x_

-- ── saving the plan changes only what changed ───────────────────────────
reset role;
select set_config('ci.cb0', (select count(*) from public.audit_log where household_id = :'hh' and table_name = 'category_budgets')::text, true) \gset x_
select set_config('ci.ids0', (select string_agg(id::text, ',' order by id) from public.category_budgets where household_id = :'hh' and month = :'month'), true) \gset x_
set local role authenticated;
select version as v1 from public.plan_status(:'month') \gset
-- the same plan again: nothing written
select public.save_month_plan(:'month', '[]',
  jsonb_build_array(jsonb_build_object('category_group', 'Daily Expenses', 'currency', 'AUD', 'amount', 500, 'pot_fund_id', :'grocpot'),
                    jsonb_build_object('category_group', 'Transportation', 'currency', 'AUD', 'amount', 100)),
  '[]', :'v1') \gset x_
reset role;
select set_config('ci.cb1', (select count(*) from public.audit_log where household_id = :'hh' and table_name = 'category_budgets')::text, true) \gset x_
set local role authenticated;
select version as v2 from public.plan_status(:'month') \gset
-- one amount changes: one line updated, the same lines kept
select public.save_month_plan(:'month', '[]',
  jsonb_build_array(jsonb_build_object('category_group', 'Daily Expenses', 'currency', 'AUD', 'amount', 550, 'pot_fund_id', :'grocpot'),
                    jsonb_build_object('category_group', 'Transportation', 'currency', 'AUD', 'amount', 100)),
  '[]', :'v2') \gset x_
reset role;
select set_config('ci.cb2', (select count(*) from public.audit_log where household_id = :'hh' and table_name = 'category_budgets')::text, true) \gset x_
select set_config('ci.ids2', (select string_agg(id::text, ',' order by id) from public.category_budgets where household_id = :'hh' and month = :'month'), true) \gset x_
do $$
begin
  assert current_setting('ci.cb1')::int = current_setting('ci.cb0')::int,
         'saving the same plan wrote ' || (current_setting('ci.cb1')::int - current_setting('ci.cb0')::int) || ' Activity lines';
  assert current_setting('ci.cb2')::int = current_setting('ci.cb0')::int + 1,
         'changing one amount wrote ' || (current_setting('ci.cb2')::int - current_setting('ci.cb0')::int) || ' Activity lines, want 1';
  assert current_setting('ci.ids2') = current_setting('ci.ids0'), 'the plan''s lines were deleted and rewritten';
end $$;
set local role authenticated;
select version as v3 from public.plan_status(:'month') \gset
-- a line dropped from the plan is deleted; its pot goes, so this month's Daily Expenses go back to Float AU
select public.save_month_plan(:'month', '[]',
  jsonb_build_array(jsonb_build_object('category_group', 'Transportation', 'currency', 'AUD', 'amount', 100)), '[]', :'v3') \gset x_
do $$
begin
  assert not exists (select 1 from public.category_budgets where household_id = current_setting('ci.hh')::uuid and month = current_setting('ci.month')::date
                      and category_group = 'Daily Expenses'), 'the dropped line is gone';
  assert not exists (select 1 from public.expenses where household_id = current_setting('ci.hh')::uuid and pot_fund_id = current_setting('ci.grocpot')::uuid
                      and deleted_at is null), 'purchases left the Groceries pot with its line';
end $$;

-- ── a fund change re-files only for a spending pot ──────────────────────
reset role;
delete from _seen; insert into _seen select id, updated_at, updated_by, pot_fund_id, date from public.expenses where household_id = :'hh';
set local role authenticated;
update public.funds set sort_order = 99 where id = :'savau';                       -- not a pot: nothing moves
update public.funds set sort_order = -1 where id = :'grocpot';                     -- the Groceries pot becomes the A$ default pot
reset role;
do $$
declare v_moved int; v_past int;
begin
  select count(*) into v_moved from public.expenses e join _seen s using (id) where e.pot_fund_id is distinct from s.pot_fund_id;
  select count(*) into v_past from public.expenses e join _seen s using (id) where e.date < current_setting('ci.month')::date and e.pot_fund_id is distinct from s.pot_fund_id;
  assert v_moved > 0 and v_past = 0, 'a reordered pot re-files this month only (moved ' || v_moved || ', past ' || v_past || ')';
  assert not exists (select 1 from public.audit_log where household_id = current_setting('ci.hh')::uuid and table_name = 'expenses' and op = 'update'
                      and at >= now() and changed = array['pot_fund_id']), 'a re-file wrote an Activity line';
end $$;

-- ── a rename copied into rows is not an edit ────────────────────────────
delete from _seen; insert into _seen select id, updated_at, updated_by, pot_fund_id, date from public.expenses where household_id = :'hh';
select set_config('ci.a0', (select count(*) from public.audit_log where household_id = :'hh' and table_name in ('expenses', 'categories', 'category_budgets') and op = 'update')::text, true) \gset x_
set local role authenticated;
update public.categories set name = 'Food shop' where id = :'groc';
update public.category_groups set name = 'Getting around' where household_id = :'hh' and kind = 'daily' and name = 'Transportation';
reset role;
select set_config('ci.a1', (select count(*) from public.audit_log where household_id = :'hh' and table_name in ('expenses', 'categories', 'category_budgets') and op = 'update')::text, true) \gset x_
do $$
declare v_touched int;
begin
  assert (select count(*) from public.expenses where household_id = current_setting('ci.hh')::uuid and category = 'Food shop') > 0, 'the new name reached the purchases';
  select count(*) into v_touched from public.expenses e join _seen s using (id) where e.updated_at <> s.updated_at or e.updated_by is distinct from s.updated_by;
  assert v_touched = 0, 'a rename stamped ' || v_touched || ' purchases as edited';
  assert current_setting('ci.a1')::int = current_setting('ci.a0')::int + 1,
         'a rename wrote ' || (current_setting('ci.a1')::int - current_setting('ci.a0')::int) || ' update lines (want 1: the category itself)';
end $$;

rollback;
\echo triggers hold
