-- PRIVATE OUTPUT — trip sends before and after the trips-across-currencies re-derive, with amounts, for Aizat to check
-- against his accounts. Run ONLY on a restored copy on this Mac, after snapshot.sql (before) and the migration (after):
--   psql "<local db url>" -q -f tools/restore/trip_sends_review.sql > "<Drive>/Reports/<date> trip sends review.txt"
-- The output quotes real amounts: it goes to Aizat's Drive, never into the repo, a commit message or a CI log.
\pset footer off
\echo '── 1 · each send: before → after (by household, trip, date)'
select h.name as household, coalesce(t.name, regexp_replace(substr(coalesce(a.remarks, s.remarks), 9), ' \(converted\)$| · refund$', '')) as trip,
       coalesce(a.date, s.date) as date, coalesce(f1.name, f0.name) as fund, coalesce(f1.currency, f0.currency) as cur,
       case when s.id is null then '' when s.gone then 'binned' else to_char(case when s.type = 'income' then -s.amount else s.amount end, 'FM999G999G990D00') end as before,
       case when a.id is null or a.deleted_at is not null then 'taken back' else to_char(case when a.type = 'income' then -a.amount else a.amount end, 'FM999G999G990D00') end as after,
       (select count(*) from bh_cmp.tripline l where l.settlement_tx_id = coalesce(a.id, s.id)) as lines_before,
       (select count(*) from public.expenses e where e.settlement_tx_id = coalesce(a.id, s.id) and e.deleted_at is null) as lines_after,
       case when s.id is null then 'new: card purchases moved here from another send'
            when a.deleted_at is not null and not s.gone then 'taken back: its purchases go elsewhere or wait'
            when not exists (select 1 from public.expenses e where e.settlement_tx_id = a.id) then 'NO PURCHASE EXPLAINS IT — decide: undo it on the trip, or keep it'
            when exists (select 1 from public.expenses e where e.settlement_tx_id = a.id and e.sent_amount is null) then 'LEFT FOR YOU — an old rate can''t be read'
            when (a.amount, a.type, a.fund_id) is distinct from (s.amount, s.type, s.fund_id) then 'changed'
            else 'same' end as what
  from bh_cmp.send s
  full join (select * from public.fund_transactions_all x
              where x.kind = 'allocation' and x.transfer_group_id is null and x.remarks ~ '^Travel: ') a using (id)
  left join public.trips t on t.id = a.trip_id
  left join public.funds f0 on f0.id = s.fund_id
  left join public.funds f1 on f1.id = a.fund_id
  join public.households h on h.id = coalesce(a.household_id, s.household_id)
 order by 1, 2, 3, 4;

\echo '── 2 · purchases whose send changed (moved to another fund, or back to "to send")'
select h.name as household, t.name as trip, e.date, e.description, e.currency || ' ' || to_char(e.amount, 'FM999G999G990D00') as spent,
       coalesce(pm.name, '(no card)') as paid_with, f0.name as fund_before, coalesce(f1.name, '—') as fund_after,
       coalesce(to_char(e.sent_amount, 'FM999G999G990D00'), '') as takes,
       case when s.sent_to_fund and not e.sent_to_fund then
              case when pm.kind = 'credit_card' and pm.currency <> e.currency and e.settled_amount is null
                   then 'to send — type what ' || pm.name || ' charged (Desk → Statements)'
                   else 'to send — no travel fund for its currency (Settings → Funds)' end
            else 'moved' end as why
  from bh_cmp.tripline s join public.expenses e using (id)
  join public.trips t on t.id = e.trip_id join public.households h on h.id = e.household_id
  left join public.payment_methods pm on pm.id = e.payment_method_id
  left join public.fund_transactions_all a0 on a0.id = s.settlement_tx_id left join public.funds f0 on f0.id = a0.fund_id
  left join public.fund_transactions_all a1 on a1.id = e.settlement_tx_id left join public.funds f1 on f1.id = a1.fund_id
 where (s.sent_to_fund and not e.sent_to_fund) or a0.fund_id is distinct from a1.fund_id and s.settlement_tx_id is not null
 order by 1, 2, 3, 4;

\echo '── 3 · funds whose numbers moved: Available and In the bank, before → after'
select h.name as household, a.name as fund, a.currency as cur,
       to_char(s.balance, 'FM999G999G990D00') as avail_before, to_char(a.balance, 'FM999G999G990D00') as avail_after,
       to_char(s.cash_balance, 'FM999G999G990D00') as bank_before, to_char(a.cash_balance, 'FM999G999G990D00') as bank_after,
       to_char(a.owed_on_cards, 'FM999G999G990D00') as owed_on_cards_now
  from bh_cmp.fund s join public.fund_money a using (fund_id) join public.households h on h.id = a.household_id
 where abs(a.balance - s.balance) > 0.005 or abs(a.cash_balance - s.cash_balance) > 0.005
 order by 1, 2;

\echo '── 4 · travel fund per currency, as the change set it'
select h.name as household, f.currency as cur, f.name as fund, (h.travel_fund_id = f.id) as main
  from public.funds f join public.households h on h.id = f.household_id where f.pays_trips and f.is_active order by 1, 2;
