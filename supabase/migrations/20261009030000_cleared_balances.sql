-- Spent vs Cleared (Aizat, 9 Oct 2026): a second balance per fund that counts only
-- RECONCILED rows — fund rows that are reconciled, and daily spending that is reconciled.
-- Spent (fund_balances) = everything entered; Cleared = what the bank has actually seen.
-- The gap between them is "entered but not yet paid/confirmed".

begin;

create or replace view public.fund_balances_cleared with (security_invoker = 'true') as
select f.household_id,
       f.id as fund_id,
       f.name,
       f.country,
       f.currency,
       f.is_active,
       f.sort_order,
       f.group_name,
       f.is_leftover_target,
       f.is_spend_pot,
       coalesce(sum(case when t.date > current_date or t.reconciled_at is null then 0
                         when t.type = 'income' then t.amount else (- t.amount) end), 0)
       - case when f.is_spend_pot and h.pot_start is not null then
           coalesce((select sum(de.amount) from public.daily_expenses de
                      where de.household_id = f.household_id
                        and de.currency = f.currency
                        and de.category <> 'Payment'
                        and de.date >= h.pot_start
                        and de.date <= current_date
                        and de.reconciled_at is not null
                        and public.expense_pot(de.household_id, de.category, de.currency, de.date) = f.id), 0)
         else 0 end as cleared_balance,
       -- spending entered against this pot that no statement has confirmed yet
       case when f.is_spend_pot and h.pot_start is not null then
           coalesce((select sum(de.amount) from public.daily_expenses de
                      where de.household_id = f.household_id
                        and de.currency = f.currency
                        and de.category <> 'Payment'
                        and de.date >= h.pot_start
                        and de.date <= current_date
                        and de.reconciled_at is null
                        and public.expense_pot(de.household_id, de.category, de.currency, de.date) = f.id), 0)
         else 0 end as pending_spend
from public.funds f
join public.households h on h.id = f.household_id
left join public.fund_transactions t on t.fund_id = f.id
group by f.id, h.pot_start;

grant all on table public.fund_balances_cleared to anon, authenticated, service_role;

commit;
