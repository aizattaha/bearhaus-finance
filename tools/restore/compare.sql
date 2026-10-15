-- Compare every money number with the snapshot taken by tools/restore/snapshot.sql, by id. Counts only.
-- A row means "this many differ"; a sprint whose migrations are meant to move nothing wants every count at 0.
select 'funds: Available differs' as check_name, count(*) as n
  from bh_cmp.fund s full join public.fund_balances a using (fund_id) where a.balance is distinct from s.balance
union all
select 'funds: cleared / pending differ', count(*)
  from bh_cmp.fund s full join public.fund_balances_cleared a using (fund_id)
 where a.cleared_balance is distinct from s.cleared_balance or a.pending_spend is distinct from s.pending_spend
union all
select 'funds: in the bank / owed on cards differ', count(*)
  from bh_cmp.fund s full join public.fund_cash a using (fund_id)
 where a.cash_balance is distinct from s.cash_balance or a.owed_on_cards is distinct from s.owed_on_cards
union all
select 'cards: owed / charges / payments differ', count(*)
  from bh_cmp.card s full join public.card_balances a using (payment_method_id)
 where (a.charges, a.credits, a.fund_charges, a.payments, a.owed, a.unsettled)
       is distinct from (s.charges, s.credits, s.fund_charges, s.payments, s.owed, s.unsettled)
union all
select 'statements: totals / status differ', count(*)
  from bh_cmp.stmt s full join public.statement_balances a using (statement_id)
 where (a.reconciled_total, a.due, a.paid, a.status, a.scheduled) is distinct from (s.reconciled_total, s.due, s.paid, s.status, s.scheduled)
union all
select 'purchases: pot changed', count(*)
  from bh_cmp.stamp s join public.expenses e using (id) where e.pot_fund_id is distinct from s.pot_fund_id
union all
select 'purchases: marked as edited (updated_at/by moved)', count(*)
  from bh_cmp.stamp s join public.expenses e using (id) where e.updated_at is distinct from s.updated_at or e.updated_by is distinct from s.updated_by
union all
select 'Activity lines added by the migrations', (select count(*) from public.audit_log) - (select n from bh_cmp.audit);
