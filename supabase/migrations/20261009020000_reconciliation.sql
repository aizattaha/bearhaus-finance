-- Reconciliation groundwork (Aizat, 9 Oct 2026) — sprint 3.
--
-- 1. Payment methods get a kind (credit_card · debit_card · bank · prepaid · cash), a statement
--    closing day (credit cards), a currency and, optionally, the pot they are settled from.
-- 2. Expenses link to their payment method by id (backfilled from the stored name; the name
--    column stays for now and the trigger below keeps the id in step with it).
-- 3. statements: one row per card per statement period; a transaction is reconciled by being
--    ticked against a statement (reconciled_at + reconciled_statement_id + reconciled_by).
-- 4. Cash rows and internal fund rows (plan writes, transfers) reconcile themselves ('auto');
--    changing a cash row to another card clears that auto tick.
-- 5. A reconciled row is LOCKED in the database: amount, date, currency, card, payer (and for
--    fund rows: fund, type) cannot change and the row cannot be deleted until it is un-reconciled.
--    Description, category, comments and remarks stay editable.
-- 6. Transfer halves share transfer_group_id so they lock and unlock together.
-- 7. reconcile_rows / unreconcile_rows RPCs do the ticking atomically, household-scoped.

begin;

-- ── 1. payment methods ──────────────────────────────────────────────────────
alter table public.payment_methods
  add column if not exists kind text not null default 'bank',
  add column if not exists closing_day integer,
  add column if not exists currency text,
  add column if not exists pot_fund_id uuid references public.funds(id) on delete set null;
alter table public.payment_methods drop constraint if exists payment_methods_kind_check;
alter table public.payment_methods add constraint payment_methods_kind_check
  check (kind in ('credit_card','debit_card','bank','prepaid','cash'));
alter table public.payment_methods drop constraint if exists payment_methods_closing_day_check;
alter table public.payment_methods add constraint payment_methods_closing_day_check
  check (closing_day is null or closing_day between 1 and 31);

update public.payment_methods set kind = 'cash' where lower(trim(name)) = 'cash';
update public.payment_methods set kind = 'prepaid' where name ilike 'YouTrip%' or name ilike 'Wise%';
-- BearHaus: first-guess kinds and currencies — Aizat corrects any in Settings → Payment cards
update public.payment_methods set kind = 'credit_card'
 where household_id = '82f25ed0-bd15-4089-a184-833137120d7f'
   and (name ilike 'Macquarie%' or name ilike 'HSBC Star Alliance%' or name ilike 'ComBank%'
        or name ilike 'UOB%' or name ilike 'DBS%');
update public.payment_methods set currency = 'SGD'
 where household_id = '82f25ed0-bd15-4089-a184-833137120d7f' and currency is null
   and (name ilike 'UOB%' or name ilike 'DBS%');
update public.payment_methods set currency = 'AUD'
 where household_id = '82f25ed0-bd15-4089-a184-833137120d7f' and currency is null
   and (name ilike 'Macquarie%' or name ilike 'HSBC Star Alliance%' or name ilike 'ComBank%'
        or name ilike 'uBank%' or name ilike 'Bank - %');

-- ── 2. links + reconciliation columns ───────────────────────────────────────
alter table public.daily_expenses
  add column if not exists payment_method_id uuid references public.payment_methods(id) on delete set null,
  add column if not exists reconciled_at timestamptz,
  add column if not exists reconciled_statement_id uuid,
  add column if not exists reconciled_by text;
alter table public.travel_expenses
  add column if not exists payment_method_id uuid references public.payment_methods(id) on delete set null,
  add column if not exists reconciled_at timestamptz,
  add column if not exists reconciled_statement_id uuid,
  add column if not exists reconciled_by text;
alter table public.fund_transactions
  add column if not exists account_payment_method_id uuid references public.payment_methods(id) on delete set null,
  add column if not exists transfer_group_id uuid,
  add column if not exists reconciled_at timestamptz,
  add column if not exists reconciled_statement_id uuid,
  add column if not exists reconciled_by text;
alter table public.daily_expenses  drop constraint if exists daily_expenses_reconciled_by_check;
alter table public.daily_expenses  add constraint daily_expenses_reconciled_by_check  check (reconciled_by is null or reconciled_by in ('manual','auto'));
alter table public.travel_expenses drop constraint if exists travel_expenses_reconciled_by_check;
alter table public.travel_expenses add constraint travel_expenses_reconciled_by_check check (reconciled_by is null or reconciled_by in ('manual','auto'));
alter table public.fund_transactions drop constraint if exists fund_transactions_reconciled_by_check;
alter table public.fund_transactions add constraint fund_transactions_reconciled_by_check check (reconciled_by is null or reconciled_by in ('manual','auto'));

-- backfill the card link from the stored name (exact match within the household)
update public.daily_expenses de set payment_method_id = pm.id
  from public.payment_methods pm
 where de.payment_method_id is null and de.paid_with <> ''
   and pm.household_id = de.household_id and pm.name = de.paid_with;
update public.travel_expenses te set payment_method_id = pm.id
  from public.payment_methods pm
 where te.payment_method_id is null and te.paid_with <> ''
   and pm.household_id = te.household_id and pm.name = te.paid_with;

create index if not exists daily_expenses_pm_date on public.daily_expenses (payment_method_id, date);
create index if not exists travel_expenses_pm_date on public.travel_expenses (payment_method_id, date);
create index if not exists daily_expenses_unreconciled on public.daily_expenses (household_id, date) where reconciled_at is null;
create index if not exists travel_expenses_unreconciled on public.travel_expenses (household_id, date) where reconciled_at is null;
create index if not exists fund_transactions_group on public.fund_transactions (transfer_group_id) where transfer_group_id is not null;

-- ── 3. statements ───────────────────────────────────────────────────────────
create table if not exists public.statements (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  payment_method_id uuid not null references public.payment_methods(id) on delete cascade,
  period_start date not null,
  period_end date not null,
  label text,
  statement_total numeric(12,2),
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint statements_period_check check (period_end >= period_start),
  constraint statements_one_per_period unique (payment_method_id, period_end)
);
alter table public.statements enable row level security;
drop policy if exists "own household only" on public.statements;
create policy "own household only" on public.statements for all
  using (household_id in (select id from public.households where owner_user_id = (select auth.uid())))
  with check (household_id in (select id from public.households where owner_user_id = (select auth.uid())));
grant all on table public.statements to anon, authenticated, service_role;

alter table public.daily_expenses  drop constraint if exists daily_expenses_reconciled_statement_fk;
alter table public.daily_expenses  add constraint daily_expenses_reconciled_statement_fk  foreign key (reconciled_statement_id) references public.statements(id) on delete set null;
alter table public.travel_expenses drop constraint if exists travel_expenses_reconciled_statement_fk;
alter table public.travel_expenses add constraint travel_expenses_reconciled_statement_fk foreign key (reconciled_statement_id) references public.statements(id) on delete set null;
alter table public.fund_transactions drop constraint if exists fund_transactions_reconciled_statement_fk;
alter table public.fund_transactions add constraint fund_transactions_reconciled_statement_fk foreign key (reconciled_statement_id) references public.statements(id) on delete set null;

-- ── 6. transfer halves: best-effort pairing of existing rows ────────────────
with outs as (
  select t.id, t.household_id, t.date, t.fund_id, f.name as from_name,
         split_part(substr(t.remarks, 12), ' · ', 1) as to_name
    from public.fund_transactions t join public.funds f on f.id = t.fund_id
   where t.type = 'expense' and t.remarks like 'Transfer → %' and t.transfer_group_id is null
), pairs as (
  select distinct on (o.id) o.id as out_id, i.id as in_id, gen_random_uuid() as gid
    from outs o
    join public.fund_transactions i on i.household_id = o.household_id and i.type = 'income'
         and i.date = o.date and i.transfer_group_id is null
         and i.remarks like 'Transfer ← %'
         and split_part(substr(i.remarks, 12), ' · ', 1) = o.from_name
    join public.funds fi on fi.id = i.fund_id and (fi.name = o.to_name or o.to_name like fi.name || '%')
   order by o.id, i.created_at
)
update public.fund_transactions t set transfer_group_id = p.gid
  from pairs p where t.id in (p.out_id, p.in_id);

-- ── 4. auto-reconcile + name↔id sync (expenses) ─────────────────────────────
create or replace function public.bh_expense_before_write() returns trigger
language plpgsql set search_path = public as $$
declare v_kind text;
begin
  -- keep the id in step with the name (older app builds only send the name)
  if new.payment_method_id is null and coalesce(new.paid_with, '') <> '' then
    select id into new.payment_method_id from payment_methods
     where household_id = new.household_id and name = new.paid_with limit 1;
  end if;
  if new.payment_method_id is not null and (tg_op = 'INSERT' or new.payment_method_id is distinct from old.payment_method_id) then
    select name into new.paid_with from payment_methods where id = new.payment_method_id;
  end if;
  select kind into v_kind from payment_methods where id = new.payment_method_id;
  -- cash ticks itself when the row is created or switched TO cash; an explicit un-tick
  -- (reconciled_at set to null on an unchanged card) is respected, so a mistake can be fixed
  if v_kind = 'cash' and new.reconciled_at is null
     and (tg_op = 'INSERT' or new.payment_method_id is distinct from old.payment_method_id) then
    new.reconciled_at := now(); new.reconciled_by := 'auto'; new.reconciled_statement_id := null;
  elsif tg_op = 'UPDATE' and v_kind is distinct from 'cash' and old.reconciled_by = 'auto' and new.reconciled_by = 'auto'
        and new.payment_method_id is distinct from old.payment_method_id then
    -- was cash, now a real card: the automatic tick no longer applies
    new.reconciled_at := null; new.reconciled_by := null; new.reconciled_statement_id := null;
  end if;
  return new;
end $$;

-- ── 5. the lock ─────────────────────────────────────────────────────────────
create or replace function public.bh_expense_lock() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    if old.reconciled_at is not null then
      raise exception 'locked: this row is reconciled — un-reconcile it first' using errcode = 'P0001';
    end if;
    return old;
  end if;
  if old.reconciled_at is not null and new.reconciled_at is not null
     and (new.amount is distinct from old.amount or new.date is distinct from old.date
          or new.currency is distinct from old.currency
          or new.payment_method_id is distinct from old.payment_method_id
          or new.payer_profile_id is distinct from old.payer_profile_id) then
    raise exception 'locked: this row is reconciled — un-reconcile it to change amount, date, currency, card or payer' using errcode = 'P0001';
  end if;
  return new;
end $$;

create or replace function public.bh_fund_before_write() returns trigger
language plpgsql set search_path = public as $$
begin
  -- internal rows never appear on a bank statement: plan writes and transfers tick themselves
  if tg_op = 'INSERT' and new.reconciled_at is null and (new.origin = 'planned' or new.remarks ~ '^Transfer [→←] ') then
    new.reconciled_at := now(); new.reconciled_by := 'auto'; new.reconciled_statement_id := null;
  end if;
  return new;
end $$;

create or replace function public.bh_fund_lock() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    if old.reconciled_at is not null and coalesce(old.reconciled_by, '') = 'manual' then
      raise exception 'locked: this row is reconciled — un-reconcile it first' using errcode = 'P0001';
    end if;
    return old;
  end if;
  if old.reconciled_at is not null and new.reconciled_at is not null and coalesce(old.reconciled_by, '') = 'manual'
     and (new.amount is distinct from old.amount or new.date is distinct from old.date
          or new.type is distinct from old.type or new.fund_id is distinct from old.fund_id) then
    raise exception 'locked: this row is reconciled — un-reconcile it to change amount, date, type or fund' using errcode = 'P0001';
  end if;
  return new;
end $$;

drop trigger if exists daily_expenses_before_write on public.daily_expenses;
create trigger daily_expenses_before_write before insert or update on public.daily_expenses
  for each row execute function public.bh_expense_before_write();
drop trigger if exists daily_expenses_lock on public.daily_expenses;
create trigger daily_expenses_lock before update or delete on public.daily_expenses
  for each row execute function public.bh_expense_lock();
drop trigger if exists travel_expenses_before_write on public.travel_expenses;
create trigger travel_expenses_before_write before insert or update on public.travel_expenses
  for each row execute function public.bh_expense_before_write();
drop trigger if exists travel_expenses_lock on public.travel_expenses;
create trigger travel_expenses_lock before update or delete on public.travel_expenses
  for each row execute function public.bh_expense_lock();
drop trigger if exists fund_transactions_before_write on public.fund_transactions;
create trigger fund_transactions_before_write before insert or update on public.fund_transactions
  for each row execute function public.bh_fund_before_write();
drop trigger if exists fund_transactions_lock on public.fund_transactions;
create trigger fund_transactions_lock before update or delete on public.fund_transactions
  for each row execute function public.bh_fund_lock();

-- backfill the automatic ticks on what is already there
update public.daily_expenses de set reconciled_at = now(), reconciled_by = 'auto'
  from public.payment_methods pm
 where de.reconciled_at is null and pm.id = de.payment_method_id and pm.kind = 'cash';
update public.travel_expenses te set reconciled_at = now(), reconciled_by = 'auto'
  from public.payment_methods pm
 where te.reconciled_at is null and pm.id = te.payment_method_id and pm.kind = 'cash';
update public.fund_transactions set reconciled_at = now(), reconciled_by = 'auto'
 where reconciled_at is null and (origin = 'planned' or remarks ~ '^Transfer [→←] ');

-- ── 7. RPCs ─────────────────────────────────────────────────────────────────
create or replace function public.reconcile_rows(p_kind text, p_ids uuid[], p_statement uuid default null)
returns integer language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_n integer;
begin
  select id into v_hh from households where owner_user_id = auth.uid();
  if v_hh is null then raise exception 'no household'; end if;
  if p_statement is not null and not exists (select 1 from statements s where s.id = p_statement and s.household_id = v_hh) then
    raise exception 'statement not found';
  end if;
  if p_kind = 'daily' then
    update daily_expenses set reconciled_at = now(), reconciled_by = 'manual', reconciled_statement_id = p_statement
     where household_id = v_hh and id = any(p_ids) and reconciled_at is null;
  elsif p_kind = 'travel' then
    update travel_expenses set reconciled_at = now(), reconciled_by = 'manual', reconciled_statement_id = p_statement
     where household_id = v_hh and id = any(p_ids) and reconciled_at is null;
  elsif p_kind = 'fund' then
    update fund_transactions set reconciled_at = now(), reconciled_by = 'manual', reconciled_statement_id = p_statement
     where household_id = v_hh and reconciled_at is null
       and (id = any(p_ids) or transfer_group_id in (select transfer_group_id from fund_transactions where id = any(p_ids) and transfer_group_id is not null));
  else raise exception 'unknown kind %', p_kind; end if;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

create or replace function public.unreconcile_rows(p_kind text, p_ids uuid[])
returns integer language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_n integer;
begin
  select id into v_hh from households where owner_user_id = auth.uid();
  if v_hh is null then raise exception 'no household'; end if;
  if p_kind = 'daily' then
    update daily_expenses set reconciled_at = null, reconciled_by = null, reconciled_statement_id = null
     where household_id = v_hh and id = any(p_ids) and reconciled_at is not null;
  elsif p_kind = 'travel' then
    update travel_expenses set reconciled_at = null, reconciled_by = null, reconciled_statement_id = null
     where household_id = v_hh and id = any(p_ids) and reconciled_at is not null;
  elsif p_kind = 'fund' then
    update fund_transactions set reconciled_at = null, reconciled_by = null, reconciled_statement_id = null
     where household_id = v_hh and reconciled_at is not null
       and (id = any(p_ids) or transfer_group_id in (select transfer_group_id from fund_transactions where id = any(p_ids) and transfer_group_id is not null));
  else raise exception 'unknown kind %', p_kind; end if;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

grant execute on function public.reconcile_rows(text, uuid[], uuid) to authenticated, service_role;
grant execute on function public.unreconcile_rows(text, uuid[]) to authenticated, service_role;

commit;
