-- ============================================================
-- One-off (Aizat, 22 Jul 2026): surface the 202609 SGCN pre-trip
-- spends inside the trip card. The originals remain fund
-- transactions (Future DreamHouse SG); these mirrors are marked
-- sent_to_fund = true so settle-up and Send-to-fund ignore them,
-- and they touch no fund balances. Joint payer (single joint split).
-- The 3 AUD Travel Fund AU → BearHaus Rainy Day AU pairs on the same
-- dates are internal fund settlement and are deliberately NOT mirrored.
-- Idempotent: safe to run twice.
-- ============================================================

insert into travel_expenses
  (household_id, trip_id, date, description, category, amount, currency,
   payer_profile_id, paid_with, comments, sent_to_fund)
select
  '82f25ed0-bd15-4089-a184-833137120d7f',
  '127802a5-8433-402e-91b1-05a778b111c6',   -- 202609 SGCN
  v.d::date, v.descr, 'Other', v.amt, 'SGD',
  null, '', 'migrated from fund transactions (pre-trip)', true
from (values
  ('2026-02-09', 'Pre-trip expenses (Feb)', 1692.92),
  ('2026-02-10', 'Pre-trip expenses (Feb)', 195.60),
  ('2026-04-07', 'Pre-trip expenses (Apr)', 1781.12)
) as v(d, descr, amt)
where not exists (
  select 1 from travel_expenses t
  where t.trip_id = '127802a5-8433-402e-91b1-05a778b111c6'
    and t.date = v.d::date and t.amount = v.amt and t.sent_to_fund
);

insert into travel_expense_splits (household_id, expense_id, profile_id, amount)
select t.household_id, t.id, null, -t.amount
from travel_expenses t
where t.trip_id = '127802a5-8433-402e-91b1-05a778b111c6'
  and t.comments = 'migrated from fund transactions (pre-trip)'
  and not exists (select 1 from travel_expense_splits s where s.expense_id = t.id);
