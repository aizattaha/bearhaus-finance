-- Before/after proof on a RESTORED copy of production (v2 sprint 3). Run on the local stack after loading a backup
-- (docs/RESTORE.md steps 1–5), BEFORE applying the new migrations:
--   psql "<local db url>" -q -f tools/restore/snapshot.sql
-- then apply the sprint's migrations one by one, then
--   psql "<local db url>" -At -F ' · ' -f tools/restore/compare.sql
-- Everything is keyed by id (the copy holds several households, some with the same fund names). The snapshot
-- stays inside the local database (schema bh_cmp); compare.sql prints counts only, never amounts.
\set ON_ERROR_STOP on
drop schema if exists bh_cmp cascade;
create schema bh_cmp;
create table bh_cmp.fund as
  select b.fund_id, b.household_id, b.balance, c.cleared_balance, c.pending_spend, k.cash_balance, k.owed_on_cards
    from public.fund_balances b
    left join public.fund_balances_cleared c using (fund_id)
    left join public.fund_cash k using (fund_id);
create table bh_cmp.card as
  select payment_method_id, household_id, charges, credits, fund_charges, payments, owed, unsettled from public.card_balances;
create table bh_cmp.stmt as
  select statement_id, household_id, reconciled_total, due, paid, status, scheduled from public.statement_balances;
create table bh_cmp.stamp as
  select id, household_id, pot_fund_id, updated_at, updated_by from public.expenses;
create table bh_cmp.audit as select count(*) as n from public.audit_log;
select 'snapshot taken' as status,
       (select count(*) from bh_cmp.fund) as funds, (select count(*) from bh_cmp.card) as cards,
       (select count(*) from bh_cmp.stmt) as statements, (select count(*) from bh_cmp.stamp) as purchases;
