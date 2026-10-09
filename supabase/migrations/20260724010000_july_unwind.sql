-- ============================================================
-- Unwind the accidental July 2026 apply (BearHaus only, 24 Jul 2026)
--
-- The cutover anchored fund balances to the sheet's FINAL Summary,
-- whose July column already contained every July planned contribution
-- and the July surplus flows into Float / Future DreamHouse SG
-- (verified against Migration/Summary.csv: Jun→Jul diffs equal the
-- planned amounts exactly). Applying July in the app therefore
-- double-counted all 23 rows written on 2026-07-24.
--
--  1. delete those 23 rows (scoped hard: household + origin + date + remark)
--  2. drop DreamHouse's July "contribution" budget row — it is the
--     sheet-era surplus line, now redundant with the computed leftover,
--     and would copy-forward into August and double there too
--  3. leave a 0.00 marker transaction so the app sees July as applied
--     and the button locks (the real application lives in the anchor)
-- Idempotent: safe to run twice.
-- ============================================================

delete from public.fund_transactions
 where household_id = '82f25ed0-bd15-4089-a184-833137120d7f'
   and origin = 'planned'
   and date = '2026-07-24'
   and remarks like 'July 2026 plan%';

delete from public.fund_budgets
 where household_id = '82f25ed0-bd15-4089-a184-833137120d7f'
   and month = '2026-07-01'
   and fund_id = '0192571a-a619-41ac-88ce-5b0c465227a2';   -- Future DreamHouse SG

insert into public.fund_transactions
  (household_id, fund_id, type, date, amount, remarks, origin)
select
  '82f25ed0-bd15-4089-a184-833137120d7f',
  '6854426f-f59e-4bd7-bbbc-6f4f953af16b',   -- Float
  'income', '2026-07-15', 0,
  'July 2026 plan — already in the migrated balances (marker)', 'planned'
where not exists (
  select 1 from public.fund_transactions
  where household_id = '82f25ed0-bd15-4089-a184-833137120d7f'
    and origin = 'planned'
    and date >= '2026-07-01' and date < '2026-08-01'
);
