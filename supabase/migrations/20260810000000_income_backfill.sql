-- Income backfill (10 Aug 2026): label BearHaus's historical deposits that are
-- clearly income (interest, gifts/angbao, government credits) so they appear in
-- the income views. Sheet-era mechanics stay unlabelled on purpose:
--   'Last known amount', 'Roll over from previous month', '202609 SGCN Trip
--   Expenses', 'For Serious Business …' — balances/plumbing, not money earned.
update public.fund_transactions
   set income_source = remarks
 where household_id = '82f25ed0-bd15-4089-a184-833137120d7f'
   and type = 'income'
   and origin = 'manual'
   and income_source is null
   and (   remarks ilike 'Interest%'
        or remarks ilike '%angbao%'
        or remarks ilike 'LifeSG%'
        or remarks ilike 'Joyful%');
