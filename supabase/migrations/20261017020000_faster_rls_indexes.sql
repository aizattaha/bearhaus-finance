-- Fast with many households (v2 sprint 3, chunk 3; D2-9).
--
--  1 · Row-level security that can use an index. `household_id in (select bh_member_of())` is planned as a hashed
--      filter over every household's rows; `household_id = any (array(select bh_member_of()))` computes the
--      caller's household once and becomes an index condition. Same rule, same rows — only the plan changes.
--      Every policy is restated here, table by table (no rewriting of policy text).
--  2 · The five missing indexes: statement lookups on both ledgers, fund rows charged to a card, the Activity
--      page, splits by household.
--      bh_member_of() / bh_writer_of() are planned as one row (a login belongs to one household), not 1,000.
--      Two covering indexes let the money sums read an index instead of every purchase and fund row (100 households
--      × 50,000 purchases: Funds 375 → ~55 ms, Budget 236 → ~57 ms on this Mac; tools/sql-tests/test_perf.sql).
--  3 · Two duplicate indexes go: fund_transactions_fund_id_idx (covered by fund_transactions_fund_date) and
--      category_budgets_hh_month_group_cur (the unique constraint's index is the same).
--
-- Nothing is written; no balance moves (asserted).
begin;
create temp table _b_fund as select fund_id, balance from public.fund_balances;

-- ── 1 · policies ────────────────────────────────────────────────────────
alter function public.bh_member_of() rows 1;
alter function public.bh_writer_of() rows 1;
-- the fifteen household tables with the usual four: read for members, insert/update/delete for writers
do $$
declare t text;
begin
  foreach t in array array['card_defaults', 'card_openings', 'categories', 'category_budgets', 'category_groups', 'expenses',
                           'fund_budgets', 'fund_transactions_all', 'funds', 'income_budgets', 'payment_methods', 'pot_swaps',
                           'profiles', 'statements', 'trips'] loop
    execute format('drop policy if exists "hh: read" on public.%I', t);
    execute format('drop policy if exists "hh: insert" on public.%I', t);
    execute format('drop policy if exists "hh: update" on public.%I', t);
    execute format('drop policy if exists "hh: delete" on public.%I', t);
    execute format('create policy "hh: read" on public.%I for select using (household_id = any (array(select public.bh_member_of())))', t);
    execute format('create policy "hh: insert" on public.%I for insert with check (household_id = any (array(select public.bh_writer_of())))', t);
    execute format('create policy "hh: update" on public.%I for update using (household_id = any (array(select public.bh_writer_of()))) with check (household_id = any (array(select public.bh_writer_of())))', t);
    execute format('create policy "hh: delete" on public.%I for delete using (household_id = any (array(select public.bh_writer_of())))', t);
  end loop;
end $$;

drop policy if exists "hh: read" on public.expense_splits;
create policy "hh: read" on public.expense_splits for select using (household_id = any (array(select public.bh_member_of())));
drop policy if exists "hh: read" on public.plan_applications;
create policy "hh: read" on public.plan_applications for select using (household_id = any (array(select public.bh_member_of())));
drop policy if exists "audit: read own household" on public.audit_log;
create policy "audit: read own household" on public.audit_log for select using (household_id = any (array(select public.bh_member_of())));
drop policy if exists "members: read own household" on public.household_members;
create policy "members: read own household" on public.household_members for select using (household_id = any (array(select public.bh_member_of())));
drop policy if exists "invites: read own household" on public.member_invites;
create policy "invites: read own household" on public.member_invites for select using (household_id = any (array(select public.bh_writer_of())));
drop policy if exists "household: read own" on public.households;
create policy "household: read own" on public.households for select using (id = any (array(select public.bh_member_of())));
drop policy if exists "household: update own" on public.households;
create policy "household: update own" on public.households for update
  using (id = any (array(select public.bh_writer_of()))) with check (id = any (array(select public.bh_writer_of())));

-- ── 2 · the missing indexes ─────────────────────────────────────────────
create index if not exists expenses_statement on public.expenses (reconciled_statement_id) where reconciled_statement_id is not null;
create index if not exists fund_transactions_statement on public.fund_transactions_all (reconciled_statement_id) where reconciled_statement_id is not null;
create index if not exists fund_transactions_card on public.fund_transactions_all (account_payment_method_id, date) where account_payment_method_id is not null;
create index if not exists audit_log_hh_id on public.audit_log (household_id, id desc);
create index if not exists expense_splits_hh on public.expense_splits (household_id);
-- everything fund_money / budget_summary / home_summary read from a live daily purchase, and from a live fund row
create index if not exists expenses_hh_money on public.expenses (household_id, date)
  include (pot_fund_id, currency, category_id, category, amount, is_refund, fund_id, payment_method_id, reconciled_at)
  where trip_id is null and deleted_at is null;
create index if not exists fund_transactions_money on public.fund_transactions_all (fund_id)
  include (date, type, kind, amount, reconciled_at, account_payment_method_id, household_id)
  where deleted_at is null;

-- ── 3 · the duplicates ──────────────────────────────────────────────────
drop index if exists public.fund_transactions_fund_id_idx;
drop index if exists public.category_budgets_hh_month_group_cur;

-- ── proof ────────────────────────────────────────────────────────────────
do $$
declare v_bad int; v_old int;
begin
  select count(*) into v_bad from _b_fund b full join public.fund_balances a using (fund_id) where a.balance is distinct from b.balance;
  if v_bad > 0 then raise exception 'rls: % fund balances changed', v_bad; end if;
  -- no policy is left in the old form
  select count(*) into v_old from pg_policies where schemaname = 'public'
     and (coalesce(qual, '') ~ 'IN \( SELECT bh_(member|writer)_of' or coalesce(with_check, '') ~ 'IN \( SELECT bh_(member|writer)_of');
  if v_old > 0 then raise exception 'rls: % policies still in the old form', v_old; end if;
  raise notice 'rls ok: every policy indexable, balances unchanged';
end $$;
drop table _b_fund;
notify pgrst, 'reload schema';
commit;
