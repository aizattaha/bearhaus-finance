-- Income events (Aug 2026 sprint, phase 2)
-- A labelled fund deposit = money that actually arrived (the quick-add Income tab).
-- Planned contributions, transfers, adjustments and old manual deposits keep NULL
-- and never count as income on Home.
alter table public.fund_transactions
  add column if not exists income_source text;

comment on column public.fund_transactions.income_source is
  'Source name for real income events (e.g. "Salary — Aizat"); set only by the quick-add Income tab. NULL = not an income event (contribution, transfer, adjustment).';
