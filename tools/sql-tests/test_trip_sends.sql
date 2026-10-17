-- Trips across currencies (17 Oct 2026, DECISIONS E33): one rule for every trip send, past and future.
--   A · a ¥ trip on an S$ card, sent and the card paid: every fund's owed on cards is 0
--   B · undo send restores the trip; sending again gives the same numbers
--   C · a sent purchase stays as sent; what the card charged can still be corrected and the send follows
--   D · a send made the old way (before sprint 2), re-derived, matches one made today; a second re-derive changes nothing
--   E · the Send card's split (ready, convert, waiting, no trip fund); Settings picks the trip fund per currency
--   F · the old send functions ask for a reload; the nightly check finds nothing out of step

\set ON_ERROR_STOP on
begin;
insert into public.beta_invites (code, max_uses, used_count) values ('CI-TRIP', 10, 0) on conflict do nothing;
insert into auth.users (id, email) values ('abababab-0000-4000-8000-000000000001', 'trip-owner@test.local'),
                                          ('abababab-0000-4000-8000-000000000002', 'trip-outsider@test.local');
set local role authenticated;
select set_config('request.jwt.claim.sub', 'abababab-0000-4000-8000-000000000001', true) \gset x_
select public.create_household_setup('CI-TRIP', 'Trip house', array['Ana', 'Ben'], 'Joint', array['AU', 'SG']) as hh \gset
select set_config('ci.hh', :'hh', true) \gset x_
select public.bh_today(:'hh') as today \gset
select set_config('ci.today', :'today', true) \gset x_
select id as ana from public.profiles where household_id = :'hh' and display_name = 'Ana' \gset
select id as tfau from public.funds where household_id = :'hh' and name = 'Travel fund AU' \gset
select id as tfsg from public.funds where household_id = :'hh' and name = 'Travel fund SG' \gset
select id as floatsg from public.funds where household_id = :'hh' and name = 'Float SG' \gset
select id as savau from public.funds where household_id = :'hh' and name = 'Savings AU' \gset
select set_config('ci.tfau', :'tfau', true) \gset x_
select set_config('ci.tfsg', :'tfsg', true) \gset x_
insert into public.payment_methods (household_id, name, profile_id, kind, currency) values (:'hh', 'UOB PPV — Ana', :'ana', 'credit_card', 'SGD') returning id as uob \gset
insert into public.payment_methods (household_id, name, profile_id, kind, currency) values (:'hh', 'Visa — Ana', :'ana', 'credit_card', 'AUD') returning id as visa \gset
insert into public.payment_methods (household_id, name, profile_id, kind, currency) values (:'hh', 'US Card — Ana', :'ana', 'credit_card', 'USD') returning id as usd \gset
select id as cash from public.payment_methods where household_id = :'hh' and kind = 'cash' \gset
select set_config('ci.uob', :'uob', true) \gset x_
select set_config('ci.visa', :'visa', true) \gset x_
insert into public.fund_transactions (household_id, fund_id, type, date, amount, remarks, origin)
values (:'hh', :'tfau', 'income', :'today', 1000, 'opening', 'manual'),
       (:'hh', :'tfsg', 'income', :'today', 1000, 'opening', 'manual'),
       (:'hh', :'floatsg', 'income', :'today', 500, 'opening', 'manual');

-- a new household: each country's travel fund pays its own currency's trips; the first is the main one
do $$ begin
  assert public.bh_trip_fund(current_setting('ci.hh')::uuid, 'AUD') = current_setting('ci.tfau')::uuid, 'A$ trips → Travel fund AU';
  assert public.bh_trip_fund(current_setting('ci.hh')::uuid, 'SGD') = current_setting('ci.tfsg')::uuid, 'S$ trips → Travel fund SG';
  assert public.bh_trip_fund(current_setting('ci.hh')::uuid, 'JPY') is null, 'no ¥ trip fund';
  assert (select travel_fund_id from public.households where id = current_setting('ci.hh')::uuid) = current_setting('ci.tfau')::uuid, 'the main travel fund is AU''s';
end $$;

-- ── A · a ¥ trip on an S$ card ──────────────────────────────────────────
insert into public.trips (household_id, name, start_date, end_date, currency, currencies, countries)
values (:'hh', 'Tokyo', :'today', :'today', 'JPY', '{JPY}', '{JP}') returning id as trip \gset
select set_config('ci.trip', :'trip', true) \gset x_
insert into public.travel_expenses (household_id, trip_id, date, description, category, amount, currency, payer_profile_id, payment_method_id, paid_with, is_refund)
values (:'hh', :'trip', :'today', 'ramen', 'Dining out', 3000, 'JPY', :'ana', :'uob', 'UOB PPV — Ana', false),
       (:'hh', :'trip', :'today', 'hotel', 'Hotel', 20000, 'JPY', :'ana', :'uob', 'UOB PPV — Ana', false),
       (:'hh', :'trip', :'today', 'returned scarf', 'Shopping', 1000, 'JPY', :'ana', :'uob', 'UOB PPV — Ana', true),
       (:'hh', :'trip', :'today', 'airport bus', 'Taxi/Grab', 30, 'SGD', :'ana', :'uob', 'UOB PPV — Ana', false),
       (:'hh', :'trip', :'today', 'taxi', 'Taxi/Grab', 2000, 'JPY', :'ana', :'cash', 'Cash', false),
       (:'hh', :'trip', :'today', 'souvenir', 'Shopping', 12, 'USD', :'ana', :'usd', 'US Card — Ana', false);
select id as ramen from public.expenses where trip_id = :'trip' and description = 'ramen' \gset
select id as hotel from public.expenses where trip_id = :'trip' and description = 'hotel' \gset
select id as scarf from public.expenses where trip_id = :'trip' and description = 'returned scarf' \gset
select set_config('ci.hotel', :'hotel', true) \gset x_

-- before the card amounts are typed: S$ 30 ready, ¥ on UOB waiting, ¥ cash to convert, US$ with no trip fund
do $$
declare p jsonb;
begin
  p := public.trip_send_plan(current_setting('ci.trip')::uuid);
  assert jsonb_array_length(p -> 'ready') = 1 and (p -> 'ready' -> 0 ->> 'fund_id')::uuid = current_setting('ci.tfsg')::uuid
     and (p -> 'ready' -> 0 ->> 'amount')::numeric = 30, 'ready: S$ 30 to Travel fund SG, got ' || (p -> 'ready')::text;
  assert jsonb_array_length(p -> 'waiting') = 1 and (p -> 'waiting' -> 0 ->> 'n')::int = 3 and (p -> 'waiting' -> 0 ->> 'foreign')::numeric = 22000,
    'waiting: three ¥ lines on UOB (¥22,000 net of the refund), got ' || (p -> 'waiting')::text;
  assert jsonb_array_length(p -> 'convert') = 1 and p -> 'convert' -> 0 ->> 'currency' = 'JPY'
     and (p -> 'convert' -> 0 ->> 'fund_id')::uuid = current_setting('ci.tfau')::uuid, 'convert: ¥ cash into the main fund, got ' || (p -> 'convert')::text;
  assert jsonb_array_length(p -> 'no_fund') = 1 and p -> 'no_fund' -> 0 ->> 'currency' = 'USD', 'no trip fund for US$, got ' || (p -> 'no_fund')::text;
end $$;

select public.set_settled_amount(:'ramen', 27.50) \gset x_
select public.set_settled_amount(:'hotel', 180) \gset x_
select public.set_settled_amount(:'scarf', 9) \gset x_
select public.send_trip(:'trip', :'today', '{"JPY": 20}') as sent \gset
do $$
declare v numeric; c numeric; o numeric; n int; r record;
begin
  -- S$: 30 + 27.50 + 180 − 9 = 228.50 on UOB, into the S$ trip fund; ¥ cash: the typed 20 into the main fund
  select balance, cash_balance, owed_on_cards into v, c, o from public.fund_cash where fund_id = current_setting('ci.tfsg')::uuid;
  assert v = 771.50 and c = 1000 and o = 228.50, 'Travel fund SG: Available 771.50, in the bank 1000, owed 228.50 — got ' || v || ' / ' || c || ' / ' || o;
  select balance, cash_balance, owed_on_cards into v, c, o from public.fund_cash where fund_id = current_setting('ci.tfau')::uuid;
  assert v = 980 and c = 980 and o = 0, 'Travel fund AU: the cash part only, nothing owed — got ' || v || ' / ' || c || ' / ' || o;
  select owed into v from public.card_balances where payment_method_id = current_setting('ci.uob')::uuid;
  assert v = 228.50, 'UOB owes what it charged, got ' || v;
  select count(*) into n from public.expenses where trip_id = current_setting('ci.trip')::uuid and sent_to_fund;
  assert n = 5, 'five lines sent (the US$ one waits for a trip fund), got ' || n;
  assert (select sent_amount from public.expenses where id = current_setting('ci.hotel')::uuid) = 180, 'the hotel took what the card charged';
end $$;
select set_config('ci.sent', :'sent', true) \gset x_

-- pay UOB from the S$ trip fund: nothing is owed on cards anywhere
select public.record_card_payment(:'uob', :'today', jsonb_build_array(jsonb_build_object('fund_id', :'tfsg', 'amount', 228.50)), null) \gset x_
do $$
declare n int; v numeric;
begin
  select count(*) into n from public.fund_cash where household_id = current_setting('ci.hh')::uuid and abs(owed_on_cards) > 0.005;
  assert n = 0, 'after paying the card, every fund''s owed on cards is 0 — ' || n || ' funds are not';
  select owed into v from public.card_balances where payment_method_id = current_setting('ci.uob')::uuid;
  assert v = 0, 'UOB is paid off, got ' || v;
end $$;

-- ── B · undo send restores the trip; sending again gives the same numbers ──
select tx_id as sgsend from jsonb_to_recordset(:'sent'::jsonb) as x(tx_id uuid, fund_id uuid) where fund_id = :'tfsg' \gset
select set_config('ci.sgsend', :'sgsend', true) \gset x_
select public.undo_trip_send(:'sgsend') as undone \gset
do $$
declare v numeric; n int; p jsonb; ok boolean := false;
begin
  select count(*) into n from public.expenses where trip_id = current_setting('ci.trip')::uuid and settlement_tx_id = current_setting('ci.sgsend')::uuid;
  assert n = 0, 'undo clears the links';
  select count(*) into n from public.expenses where trip_id = current_setting('ci.trip')::uuid and not sent_to_fund and sent_amount is null
     and payment_method_id = current_setting('ci.uob')::uuid;
  assert n = 4, 'the four UOB lines are unsent again, got ' || n;
  select balance into v from public.fund_balances where fund_id = current_setting('ci.tfsg')::uuid;
  assert v = 1000, 'Travel fund SG has its money back, got ' || v;
  p := public.trip_send_plan(current_setting('ci.trip')::uuid);
  assert (p -> 'ready' -> 0 ->> 'amount')::numeric = 228.50, 'the trip offers the same S$ 228.50 again, got ' || (p -> 'ready')::text;
  assert not exists (select 1 from public.recently_deleted where id = current_setting('ci.sgsend')::uuid), 'an undone send is not in the bin';
  begin perform public.restore_rows('fund', array[current_setting('ci.sgsend')::uuid]); exception when raise_exception then ok := true; end;
  assert ok, 'a send came back from the bin';
end $$;
select public.send_trip(:'trip', :'today') \gset x_
do $$
declare n int;
begin
  select count(*) into n from public.fund_cash where household_id = current_setting('ci.hh')::uuid and abs(owed_on_cards) > 0.005;
  assert n = 0, 'sent again: every fund''s owed on cards is 0 again — ' || n || ' funds are not';
end $$;

-- ── C · a sent purchase stays as sent ───────────────────────────────────
do $$
declare ok boolean; v0 numeric; v numeric; o numeric; tx uuid;
begin
  ok := false;
  begin update public.travel_expenses set amount = 25000 where id = current_setting('ci.hotel')::uuid; exception when raise_exception then ok := true; end;
  assert ok, 'the amount of a sent purchase changed';
  ok := false;
  begin update public.travel_expenses set payment_method_id = current_setting('ci.visa')::uuid where id = current_setting('ci.hotel')::uuid; exception when raise_exception then ok := true; end;
  assert ok, 'the card of a sent purchase changed';
  ok := false;
  begin update public.travel_expenses set sent_to_fund = false where id = current_setting('ci.hotel')::uuid; exception when raise_exception then ok := true; end;
  assert ok, 'a sent purchase was marked unsent by hand';
  ok := false;
  begin perform public.soft_delete_rows('travel', array[current_setting('ci.hotel')::uuid]); exception when raise_exception then ok := true; end;
  assert ok, 'a sent purchase went to the bin';
  update public.travel_expenses set description = 'hotel (2 nights)' where id = current_setting('ci.hotel')::uuid;   -- words are free
  -- a send's fund row can't be edited on its own
  select settlement_tx_id into tx from public.expenses where id = current_setting('ci.hotel')::uuid;
  ok := false;
  begin update public.fund_transactions set amount = 1 where id = tx; exception when raise_exception then ok := true; end;
  assert ok, 'a send''s amount was edited on its own';
  -- the card's charge corrected after sending: the send follows, owed stays what the card owes
  select balance into v0 from public.fund_balances where fund_id = current_setting('ci.tfsg')::uuid;
  perform public.set_settled_amount(current_setting('ci.hotel')::uuid, 182.40);
  select balance, owed_on_cards into v, o from public.fund_cash where fund_id = current_setting('ci.tfsg')::uuid;
  assert v0 - v = 2.40, 'the S$ trip fund pays the extra 2.40, got ' || (v0 - v);
  assert o = 2.40, 'and owes it on the card until the next payment, got ' || o;
  assert (select amount from public.fund_transactions where id = tx) = 230.90, 'the send is the sum of its purchases';
end $$;

-- binning a send is the same as undoing it
select settlement_tx_id as tx2 from public.expenses where id = :'hotel' \gset
select public.soft_delete_rows('fund', array[:'tx2']::uuid[]) \gset x_
do $$ begin
  assert not exists (select 1 from public.expenses where trip_id = current_setting('ci.trip')::uuid and payment_method_id = current_setting('ci.uob')::uuid and sent_to_fund),
    'binning the send unsent its purchases';
end $$;
select public.send_trip(:'trip', :'today') \gset x_

-- ── D · a send made the old way, re-derived, matches one made today ─────
-- two identical trips: ¥10,000 hotel on UOB (S$ 100 charged), ¥1,000 meal on the Visa (A$ 10 charged), ¥5,000 cash,
-- S$ 20 cash, A$ 15 cash
insert into public.trips (household_id, name, start_date, end_date, currency, currencies, countries)
values (:'hh', 'Old way', :'today', :'today', 'JPY', '{JPY}', '{JP}') returning id as oldtrip \gset
insert into public.trips (household_id, name, start_date, end_date, currency, currencies, countries)
values (:'hh', 'New way', :'today', :'today', 'JPY', '{JPY}', '{JP}') returning id as newtrip \gset
select set_config('ci.oldtrip', :'oldtrip', true) \gset x_
select set_config('ci.newtrip', :'newtrip', true) \gset x_
insert into public.travel_expenses (household_id, trip_id, date, description, category, amount, currency, payer_profile_id, payment_method_id, paid_with)
select :'hh', t, :'today', d, 'Hotel', a, c, :'ana', pm, ''
  from unnest(array[:'oldtrip', :'newtrip']::uuid[]) t,
       (values ('hotel', 10000, 'JPY', :'uob'::uuid), ('meal', 1000, 'JPY', :'visa'::uuid), ('yen cash', 5000, 'JPY', :'cash'::uuid),
               ('sgd cash', 20, 'SGD', :'cash'::uuid), ('aud cash', 15, 'AUD', :'cash'::uuid)) v(d, a, c, pm);
do $$ declare r record; begin
  for r in select id, description from public.expenses
            where trip_id in (current_setting('ci.oldtrip')::uuid, current_setting('ci.newtrip')::uuid) and description in ('hotel', 'meal') loop
    perform public.set_settled_amount(r.id, case when r.description = 'hotel' then 100 else 10 end);
  end loop;
end $$;
-- today's way
select public.send_trip(:'newtrip', :'today', '{"JPY": 50}') \gset x_
-- the old way (the phone before sprint 2): three sends by remark, purchases flagged but never linked —
-- S$ lines straight into the S$ fund, A$ lines into the main fund, every ¥ line converted into the main fund at 160
reset role;
update public.expenses set created_at = now() - interval '3 days', sent_to_fund = true where trip_id = :'oldtrip';
insert into public.fund_transactions_all (household_id, fund_id, type, kind, date, amount, remarks, origin, created_at)
values (:'hh', :'tfsg', 'expense', 'allocation', :'today', 20, 'Travel: Old way', 'manual', now() - interval '2 days'),
       (:'hh', :'tfau', 'expense', 'allocation', :'today', 15, 'Travel: Old way', 'manual', now() - interval '2 days'),
       (:'hh', :'tfau', 'expense', 'allocation', :'today', 160, 'Travel: Old way (converted)', 'manual', now() - interval '1 day');
alter table public.expenses disable trigger zz_expenses_touch;   -- an hour back, so a stamp would show
update public.expenses set updated_at = updated_at - interval '1 hour' where trip_id = :'oldtrip';
alter table public.expenses enable trigger zz_expenses_touch;
create temp table _old_seen as select id, updated_at from public.expenses where trip_id = :'oldtrip';
select public.bh_rederive_trip_sends(:'hh') as rd \gset
select public.bh_rederive_trip_sends(:'hh') as rd2 \gset
select set_config('ci.rd', :'rd', true) \gset x_
select set_config('ci.rd2', :'rd2', true) \gset x_
do $$
declare v_bad int; r jsonb := current_setting('ci.rd')::jsonb; r2 jsonb := current_setting('ci.rd2')::jsonb;
begin
  assert (r ->> 'matched_old')::int = 3, 'the three old sends found their purchases, got ' || r::text;
  assert not exists (select 1 from public.expenses e join _old_seen s using (id) where e.updated_at <> s.updated_at),
    're-linking stamped purchases as edited';
  assert (r ->> 'new_sends')::int = 1 and (r ->> 'moved')::int = 1, 'the UOB hotel moved to the S$ trip fund, got ' || r::text;
  assert (r2 ->> 'changed')::int + (r2 ->> 'new_sends')::int + (r2 ->> 'removed')::int + (r2 ->> 'waiting')::int + (r2 ->> 'matched_old')::int = 0,
    'a second re-derive changes nothing, got ' || r2::text;
  -- line by line: the same fund and the same amount taken
  select count(*) into v_bad
    from public.expenses o
    join public.expenses n on n.trip_id = current_setting('ci.newtrip')::uuid and n.description = o.description
    left join public.fund_transactions ao on ao.id = o.settlement_tx_id
    left join public.fund_transactions an on an.id = n.settlement_tx_id
   where o.trip_id = current_setting('ci.oldtrip')::uuid
     and (o.sent_to_fund is distinct from n.sent_to_fund or o.sent_amount is distinct from n.sent_amount or ao.fund_id is distinct from an.fund_id);
  assert v_bad = 0, v_bad || ' purchases differ between the re-derived old send and today''s';
  -- fund by fund: the same totals
  select count(*) into v_bad from (
    select a.fund_id, sum(case when a.type = 'income' then -a.amount else a.amount end) filter (where a.trip_id = current_setting('ci.oldtrip')::uuid) as o,
                      sum(case when a.type = 'income' then -a.amount else a.amount end) filter (where a.trip_id = current_setting('ci.newtrip')::uuid) as n
      from public.fund_transactions a where a.trip_id in (current_setting('ci.oldtrip')::uuid, current_setting('ci.newtrip')::uuid) group by a.fund_id) x
   where x.o is distinct from x.n;
  assert v_bad = 0, v_bad || ' funds hold different totals for the two trips';
  assert (select sum(amount) from public.fund_transactions where trip_id = current_setting('ci.oldtrip')::uuid and fund_id = current_setting('ci.tfau')::uuid) = 75,
    'A$: 15 cash + 10 on the Visa + ¥5,000 cash at the old rate (50)';
end $$;
-- a send nothing explains is left as it is
insert into public.fund_transactions_all (household_id, fund_id, type, kind, date, amount, remarks, origin)
values (:'hh', :'tfsg', 'expense', 'allocation', :'today', 33, 'Travel: Old way', 'manual') returning id as stray \gset
select public.bh_rederive_trip_sends(:'hh') as rd3 \gset
select set_config('ci.rd3', :'rd3', true) \gset x_
select set_config('ci.stray', :'stray', true) \gset x_
do $$ begin
  assert (current_setting('ci.rd3')::jsonb ->> 'unexplained')::int = 1, 'the stray send is counted, got ' || current_setting('ci.rd3');
  assert (select amount from public.fund_transactions where id = current_setting('ci.stray')::uuid) = 33, 'and left as it is';
  assert (select trip_id from public.fund_transactions where id = current_setting('ci.stray')::uuid) = current_setting('ci.oldtrip')::uuid, 'named to its trip';
  assert (select bad from public.bh_money_check() where check_name like 'trip sends left for a person%') >= 1, 'the nightly check lists it';
end $$;
delete from public.fund_transactions_all where id = :'stray';
set local role authenticated;

-- ── E · Settings: the trip fund per currency ────────────────────────────
select public.set_trip_fund('SGD', :'floatsg') \gset x_
do $$ begin
  assert public.bh_trip_fund(current_setting('ci.hh')::uuid, 'SGD') = (select id from public.funds where household_id = current_setting('ci.hh')::uuid and name = 'Float SG'), 'S$ trips → Float SG';
  assert (select count(*) from public.funds where household_id = current_setting('ci.hh')::uuid and currency = 'SGD' and pays_trips) = 1, 'one S$ trip fund';
  assert (select travel_fund_id from public.households where id = current_setting('ci.hh')::uuid) = current_setting('ci.tfau')::uuid, 'the main fund stays';
end $$;
select public.set_trip_fund('AUD', :'savau') \gset x_
do $$ declare ok boolean := false; begin
  assert (select travel_fund_id from public.households where id = current_setting('ci.hh')::uuid)
       = (select id from public.funds where household_id = current_setting('ci.hh')::uuid and name = 'Savings AU'), 'the main fund follows its currency';
  begin perform public.set_trip_fund('SGD', current_setting('ci.tfau')::uuid); exception when raise_exception then ok := true; end;
  assert ok, 'an A$ fund became the S$ trip fund';
end $$;
select public.set_trip_fund('AUD', :'tfau') \gset x_

-- an outsider sees nothing and can't send
select set_config('request.jwt.claim.sub', 'abababab-0000-4000-8000-000000000002', true) \gset x_
do $$ declare ok boolean := false; begin
  assert public.trip_send_plan(current_setting('ci.trip')::uuid) is null, 'an outsider read the trip';
  begin perform public.send_trip(current_setting('ci.trip')::uuid, current_setting('ci.today')::date); exception when others then ok := true; end;
  assert ok, 'an outsider sent the trip';
end $$;
select set_config('request.jwt.claim.sub', 'abababab-0000-4000-8000-000000000001', true) \gset x_

-- ── F · the old functions ask for a reload; nothing out of step ─────────
do $$ declare ok boolean := false; begin
  begin perform public.send_trip_to_fund(current_setting('ci.trip')::uuid, current_setting('ci.tfau')::uuid, current_setting('ci.today')::date);
  exception when raise_exception then ok := sqlerrm like '%reload%'; end;
  assert ok, 'the old send didn''t ask for a reload';
end $$;
reset role;
do $$
declare v text;
begin
  select string_agg(check_name || ' ' || bad, ', ') into v from public.bh_money_check()
   where severity = 'fail' and bad > 0 and check_name <> 'integrity issues noted in the last day';
  assert v is null, 'the nightly check fails: ' || v;
end $$;

rollback;
\echo trips across currencies
