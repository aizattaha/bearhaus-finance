-- Card rules (v2 sprint 2): where cards are offered, default cards per person per context, archived cards
-- refused on purchases except through the Desk's reconciliation functions.

\set ON_ERROR_STOP on
begin;
insert into public.beta_invites (code, max_uses, used_count) values ('CI-CARD', 10, 0) on conflict do nothing;
insert into auth.users (id, email) values ('ffffffff-0000-4000-8000-000000000001', 'card-owner@test.local'),
                                          ('ffffffff-0000-4000-8000-000000000002', 'card-viewer@test.local');
set local role authenticated;
select set_config('request.jwt.claim.sub', 'ffffffff-0000-4000-8000-000000000001', true);
select public.create_household_setup('CI-CARD', 'Card household', array['Ana', 'Ben'], 'Joint', array['AU', 'SG']) as hh \gset
select set_config('ci.hh', :'hh', true);
select id as ana from public.profiles where household_id = :'hh' and display_name = 'Ana' \gset
select id as ben from public.profiles where household_id = :'hh' and display_name = 'Ben' \gset
select set_config('ci.ana', :'ana', true);
select set_config('ci.ben', :'ben', true);
insert into public.payment_methods (household_id, name, profile_id, kind, currency) values (:'hh', 'Visa — Ana', :'ana', 'credit_card', 'AUD') returning id as visa \gset
insert into public.payment_methods (household_id, name, profile_id, kind, currency, travel_only) values (:'hh', 'SG card — Ana', :'ana', 'credit_card', 'SGD', true) returning id as sgcard \gset
insert into public.payment_methods (household_id, name, profile_id, kind, currency) values (:'hh', 'Amex — Ben', :'ben', 'credit_card', 'AUD') returning id as amex \gset
insert into public.payment_methods (household_id, name, profile_id, kind, currency) values (:'hh', 'Old card — Ana', :'ana', 'credit_card', 'AUD') returning id as old \gset
select set_config('ci.visa', :'visa', true);
select set_config('ci.sgcard', :'sgcard', true);
select set_config('ci.amex', :'amex', true);
select set_config('ci.old', :'old', true);

-- ── flags: travel_only and show_* stay in step ───────────────────────────
do $$
declare r record;
begin
  select * into r from public.payment_methods where id = current_setting('ci.sgcard')::uuid;
  assert not r.show_daily and r.show_trip and r.show_fund, 'a travel-only card is offered for trips and funds, not daily';
  update public.payment_methods set show_daily = true where id = current_setting('ci.sgcard')::uuid;
  select * into r from public.payment_methods where id = current_setting('ci.sgcard')::uuid;
  assert not r.travel_only, 'switching Daily on clears travel_only';
  update public.payment_methods set travel_only = true where id = current_setting('ci.sgcard')::uuid;   -- an older app flips the old flag
  select * into r from public.payment_methods where id = current_setting('ci.sgcard')::uuid;
  assert not r.show_daily, 'the old flag still hides the card from daily';
end $$;

-- ── defaults ──────────────────────────────────────────────────────────────
do $$
declare ok boolean := false; n int;
begin
  insert into public.card_defaults (household_id, profile_id, context, payment_method_id)
  values (current_setting('ci.hh')::uuid, current_setting('ci.ana')::uuid, 'daily', current_setting('ci.visa')::uuid),
         (current_setting('ci.hh')::uuid, current_setting('ci.ana')::uuid, 'trip',  current_setting('ci.sgcard')::uuid),
         (current_setting('ci.hh')::uuid, current_setting('ci.ben')::uuid, 'daily', current_setting('ci.amex')::uuid);
  select count(*) into n from public.card_defaults where household_id = current_setting('ci.hh')::uuid; assert n = 3, 'three defaults saved';
  -- one per person per context
  begin insert into public.card_defaults (household_id, profile_id, context, payment_method_id) values (current_setting('ci.hh')::uuid, current_setting('ci.ana')::uuid, 'daily', current_setting('ci.old')::uuid);
  exception when unique_violation then ok := true; end;
  assert ok, 'two daily defaults for one person';
  -- a card hidden from daily can't be the daily default
  ok := false;
  begin insert into public.card_defaults (household_id, profile_id, context, payment_method_id) values (current_setting('ci.hh')::uuid, null, 'daily', current_setting('ci.sgcard')::uuid);
  exception when raise_exception then ok := true; end;
  assert ok, 'a travel-only card became a daily default';
  -- someone else's personal card can't be my default
  ok := false;
  begin insert into public.card_defaults (household_id, profile_id, context, payment_method_id) values (current_setting('ci.hh')::uuid, current_setting('ci.ben')::uuid, 'trip', current_setting('ci.visa')::uuid);
  exception when raise_exception then ok := true; end;
  assert ok, 'Ana''s card became Ben''s default';
  -- archiving a card, or hiding it from a context, drops the defaults that pointed at it
  update public.payment_methods set show_trip = false where id = current_setting('ci.sgcard')::uuid;
  select count(*) into n from public.card_defaults where payment_method_id = current_setting('ci.sgcard')::uuid; assert n = 0, 'hidden card still a trip default';
  update public.payment_methods set is_archived = true where id = current_setting('ci.amex')::uuid;
  select count(*) into n from public.card_defaults where payment_method_id = current_setting('ci.amex')::uuid; assert n = 0, 'archived card still a default';
  update public.payment_methods set is_archived = false where id = current_setting('ci.amex')::uuid;
end $$;

-- ── archived cards ────────────────────────────────────────────────────────
-- a purchase made before archiving stays editable; nothing new may land on the card
insert into public.daily_expenses (household_id, date, description, category, amount, currency, payment_method_id, paid_with)
values (:'hh', current_date - 3, 'old card purchase', 'Groceries', 40, 'AUD', :'old', 'Old card — Ana') returning id as olde \gset
select set_config('ci.olde', :'olde', true);
update public.payment_methods set is_archived = true where id = :'old';
do $$
declare ok boolean := false; n int; v_id uuid;
begin
  update public.expenses set description = 'old card purchase (edited)', comments = 'note' where id = current_setting('ci.olde')::uuid;
  get diagnostics n = row_count; assert n = 1, 'a row on an archived card can still be edited';
  begin
    insert into public.daily_expenses (household_id, date, description, category, amount, currency, payment_method_id, paid_with)
    values (current_setting('ci.hh')::uuid, current_date, 'new on old card', 'Groceries', 5, 'AUD', current_setting('ci.old')::uuid, 'Old card — Ana');
  exception when raise_exception then ok := true; end;
  assert ok, 'a new purchase landed on an archived card';
  ok := false;
  begin  -- by name, as an older app sends it
    insert into public.daily_expenses (household_id, date, description, category, amount, currency, paid_with)
    values (current_setting('ci.hh')::uuid, current_date, 'by name', 'Groceries', 5, 'AUD', 'Old card — Ana');
  exception when raise_exception then ok := true; end;
  assert ok, 'a purchase named an archived card by name';
  ok := false;
  insert into public.daily_expenses (household_id, date, description, category, amount, currency, payment_method_id, paid_with)
  values (current_setting('ci.hh')::uuid, current_date, 'move me', 'Groceries', 7, 'AUD', current_setting('ci.visa')::uuid, 'Visa — Ana') returning id into v_id;
  begin update public.expenses set payment_method_id = current_setting('ci.old')::uuid where id = v_id;
  exception when raise_exception then ok := true; end;
  assert ok, 'a row was moved onto an archived card';
  -- the Desk may, through its reconciliation functions
  v_id := public.desk_add_expense(jsonb_build_object('date', current_date - 2, 'description', 'statement line', 'category', 'Groceries',
          'amount', 12.5, 'currency', 'AUD', 'payment_method_id', current_setting('ci.old'), 'paid_with', 'Old card — Ana'));
  select count(*) into n from public.expenses where id = v_id and payment_method_id = current_setting('ci.old')::uuid and created_by = 'ffffffff-0000-4000-8000-000000000001';
  assert n = 1, 'the Desk adds a statement line on an archived card';
  select count(*) into n from public.audit_log where row_id = v_id and op = 'insert'; assert n = 1, 'the Desk addition is in the activity log';
  perform public.desk_set_card(array[(select id from public.expenses where description = 'move me')], current_setting('ci.old')::uuid);
  select count(*) into n from public.expenses where description = 'move me' and payment_method_id = current_setting('ci.old')::uuid; assert n = 1, 'the Desk moves a row onto an archived card';
  -- and the override doesn't leak into the rest of the transaction
  ok := false;
  begin
    insert into public.daily_expenses (household_id, date, description, category, amount, currency, payment_method_id, paid_with)
    values (current_setting('ci.hh')::uuid, current_date, 'after the desk call', 'Groceries', 5, 'AUD', current_setting('ci.old')::uuid, 'Old card — Ana');
  exception when raise_exception then ok := true; end;
  assert ok, 'the archived override leaked past the Desk function';
end $$;

-- ── a viewer can't use the Desk functions or change defaults ─────────────
select public.create_member_invite(null, 'viewer') as vcode \gset
select set_config('request.jwt.claim.sub', 'ffffffff-0000-4000-8000-000000000002', true);
select public.join_household(:'vcode');
do $$
declare ok boolean := false;
begin
  begin perform public.desk_add_expense(jsonb_build_object('date', current_date, 'description', 'x', 'category', 'Groceries', 'amount', 1, 'currency', 'AUD', 'payment_method_id', current_setting('ci.visa')));
  exception when insufficient_privilege then ok := true; end;
  assert ok, 'a viewer added a purchase through the Desk function';
  ok := false;
  begin insert into public.card_defaults (household_id, profile_id, context, payment_method_id) values (current_setting('ci.hh')::uuid, null, 'fund', current_setting('ci.visa')::uuid);
  exception when others then ok := true; end;
  assert ok, 'a viewer saved a default';
end $$;

rollback;
\echo card rules hold
