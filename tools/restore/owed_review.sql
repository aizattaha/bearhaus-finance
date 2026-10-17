-- Bundle A1 (DH-01) review on a RESTORED copy of production: which funds' In the bank / Owed on cards move with the
-- start-date cut, and why. By fund name, counts only — never amounts. Run on the local stack after
-- tools/restore/snapshot.sql (before) and the new migrations (after):
--   psql "<local db url>" -At -F ' · ' -f tools/restore/owed_review.sql
-- Copy the output to Drive (Reports/), not into the repo: fund names with counts are fine, but the output is
-- production's.
\set ON_ERROR_STOP on

\echo '── what must not move (each want 0)'
select 'funds whose Available, cleared or pending moved' as check_name, count(*) as n
  from bh_cmp.fund s join public.fund_money m using (fund_id)
 where (m.balance, m.cleared_balance, m.pending_spend) is distinct from (s.balance, s.cleared_balance, s.pending_spend)
union all
select 'funds whose In the bank and Owed moved by different amounts', count(*)
  from bh_cmp.fund s join public.fund_money m using (fund_id)
 where abs((m.cash_balance - s.cash_balance) - (m.owed_on_cards - s.owed_on_cards)) > 0.005
union all
select 'cards whose owed moved', count(*)
  from bh_cmp.card s join public.card_balances a using (payment_method_id) where a.owed is distinct from s.owed;

\echo '── funds that move (In the bank and Owed on cards move together; Available stays)'
select h.name as household, f.name as fund, f.currency,
       case when m.cash_balance > s.cash_balance then 'In the bank up' else 'In the bank down' end as direction,
       (select count(*) from public.expenses e join public.payment_methods p on p.id = e.payment_method_id and p.kind = 'credit_card'
         where e.pot_fund_id = f.id and e.trip_id is null and e.deleted_at is null and e.category <> 'Payment'
           and e.date < h.pot_start) as card_purchases_before_start,
       (select count(*) from public.fund_transactions t join public.payment_methods p on p.id = t.account_payment_method_id and p.kind = 'credit_card'
         where t.fund_id = f.id and t.type = 'expense' and t.kind <> 'card_payment' and t.date < h.pot_start) as card_rows_before_start,
       (select count(*) from public.fund_transactions t
         where t.fund_id = f.id and t.kind = 'card_payment' and t.date < h.pot_start) as card_payments_before_start,
       exists (select 1 from public.card_openings o where o.fund_id = f.id) as backs_a_card_opening
  from bh_cmp.fund s
  join public.fund_money m using (fund_id)
  join public.funds f on f.id = s.fund_id
  join public.households h on h.id = f.household_id
 where m.cash_balance is distinct from s.cash_balance
 order by h.name, f.currency, f.name;

\echo '── funds owing less than zero on cards: before → after (counts)'
select (select count(*) from bh_cmp.fund where owed_on_cards < -0.005) as before,
       (select count(*) from public.fund_money where owed_on_cards < -0.005) as after;

\echo '── cards vs funds, per household and currency (the new nightly fail line)'
select h.name as household, g.currency,
       case when abs(g.gap) < 0.005 then 'agree' else 'DISAGREE' end as cards_vs_funds,
       case when abs(g.card_only) >= 0.005 then 'yes' else 'no' end as lines_only_cards_count,
       case when abs(g.fund_only) >= 0.005 then 'yes' else 'no' end as lines_only_funds_count
  from public.bh_owed_gaps() g join public.households h on h.id = g.household_id
 order by h.name, g.currency;

\echo '── the nightly check after (lines with something to report)'
select severity, bad, check_name from public.bh_money_check() where bad > 0 order by severity, check_name;
