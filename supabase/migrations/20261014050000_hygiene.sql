-- Hygiene (14 Oct 2026) — architecture review §1.4, §1.5, §1.8, §1.9.
--
--  statements          opening_balance · closing_balance · payment_due — the Desk can check
--                      opening + spend − credits = closing and chain one statement to the next
--  expenses.is_refund  a credit on a card or a refund: amount stays positive, every view counts it
--                      negative (spend, pots, cards, statements). 'Payment' remains the settle-up
--  expense_splits      derived, not written: a trigger keeps the two rows (payer +, joint −) in step
--                      with the expense; clients can only read them. Rebuilt for every row — the
--                      131 rows whose splits disagreed with their payer now agree.
--  deleted_at          soft delete on expenses and fund rows: delete = hide for 30 days, restorable.
--                      fund_transactions becomes a view over fund_transactions_all (live rows only),
--                      the expense views already hide; soft_delete_rows / restore_rows / purge_deleted
--
-- Balances asserted unchanged (no refunds or deletions exist yet, so by construction).

begin;

create temp table _before as select fund_id, balance from public.fund_balances;

-- ── 1 · statement balances ───────────────────────────────────────────────
alter table public.statements
  add column if not exists opening_balance numeric(12,2),
  add column if not exists closing_balance numeric(12,2),
  add column if not exists payment_due date;

-- ── 2 · refunds ──────────────────────────────────────────────────────────
alter table public.expenses add column if not exists is_refund boolean not null default false;

-- ── 3 · soft delete ──────────────────────────────────────────────────────
alter table public.expenses add column if not exists deleted_at timestamptz;
create index if not exists expenses_deleted on public.expenses (household_id, deleted_at) where deleted_at is not null;

alter table public.fund_transactions add column if not exists deleted_at timestamptz;
alter table public.fund_transactions rename to fund_transactions_all;
alter index if exists public.fund_transactions_pkey rename to fund_transactions_all_pkey;
create index if not exists fund_transactions_deleted on public.fund_transactions_all (household_id, deleted_at) where deleted_at is not null;
-- the name every client and RPC uses is now the live view (plain select → updatable; base triggers fire)
create view public.fund_transactions with (security_invoker = true) as
  select * from public.fund_transactions_all where deleted_at is null;
grant select, insert, update, delete on public.fund_transactions to authenticated, service_role;

-- a soft delete may not touch a row that is ticked on a statement (same rule as a hard delete)
create or replace function public.bh_soft_delete_guard()
returns trigger language plpgsql as $$
begin
  if new.deleted_at is not null and old.deleted_at is null then
    if old.reconciled_at is not null and coalesce(old.reconciled_by, '') = 'manual' then
      raise exception 'locked: this row is reconciled — un-reconcile it first' using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists expenses_soft_delete on public.expenses;
create trigger expenses_soft_delete before update on public.expenses for each row execute function public.bh_soft_delete_guard();
drop trigger if exists fund_transactions_soft_delete on public.fund_transactions_all;
create trigger fund_transactions_soft_delete before update on public.fund_transactions_all for each row execute function public.bh_soft_delete_guard();

-- a hard delete of a reconciled row is only ever the bin emptying itself (purge runs with the RPC flag)
create or replace function public.bh_expense_lock()
returns trigger language plpgsql as $$
declare
  v_via_rpc boolean := coalesce(current_setting('bh.via_rpc', true), '') = 'on';
  v_auto_set boolean; v_auto_clear boolean;
begin
  if tg_op = 'DELETE' then
    if old.reconciled_at is not null and not (v_via_rpc and coalesce(old.reconciled_by, '') <> 'manual') then
      raise exception 'locked: this row is reconciled — un-reconcile it first' using errcode = 'P0001';
    end if;
    return old;
  end if;
  v_auto_set   := old.reconciled_at is null and new.reconciled_by = 'auto' and new.reconciled_at is not null;
  v_auto_clear := old.reconciled_by = 'auto' and new.reconciled_at is null and new.payment_method_id is distinct from old.payment_method_id;
  if not v_via_rpc and not v_auto_set and not v_auto_clear
     and (new.reconciled_at is distinct from old.reconciled_at
          or new.reconciled_by is distinct from old.reconciled_by
          or new.reconciled_statement_id is distinct from old.reconciled_statement_id) then
    raise exception 'locked: use un-reconcile to change the reconciliation of this row' using errcode = 'P0001';
  end if;
  if old.reconciled_at is not null and not v_auto_clear
     and (new.amount is distinct from old.amount or new.date is distinct from old.date
          or new.currency is distinct from old.currency
          or new.payment_method_id is distinct from old.payment_method_id
          or new.payer_profile_id is distinct from old.payer_profile_id
          or new.is_refund is distinct from old.is_refund) then
    raise exception 'locked: this row is reconciled — un-reconcile it to change amount, date, currency, card or payer' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

-- the audit log keeps the familiar table name
create or replace function public.bh_audit()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_old jsonb; v_new jsonb; v_hh uuid; v_id uuid; v_keys text[]; v_b jsonb := '{}'; v_a jsonb := '{}'; k text; v_label text;
  v_skip text[] := array['updated_at', 'updated_by', 'created_at'];
  v_table text := regexp_replace(tg_table_name, '_all$', '');
begin
  if tg_op = 'DELETE' then
    v_old := to_jsonb(old);
    v_hh := case when tg_table_name = 'households' then old.id else (v_old->>'household_id')::uuid end;
    v_label := coalesce(v_old->>'description', v_old->>'remarks', v_old->>'income_source', v_old->>'display_name', v_old->>'name', v_old->>'label', v_old->>'source_name', v_old->>'category_group');
    insert into audit_log (household_id, table_name, row_id, op, by_user, label, before)
    values (v_hh, v_table, (v_old->>'id')::uuid, 'delete', auth.uid(), v_label, v_old - v_skip);
    return old;
  end if;
  v_new := to_jsonb(new);
  v_hh := case when tg_table_name = 'households' then new.id else (v_new->>'household_id')::uuid end;
  v_id := (v_new->>'id')::uuid;
  v_label := coalesce(v_new->>'description', v_new->>'remarks', v_new->>'income_source', v_new->>'display_name', v_new->>'name', v_new->>'label', v_new->>'source_name', v_new->>'category_group');
  if tg_op = 'INSERT' then
    insert into audit_log (household_id, table_name, row_id, op, by_user, label, after)
    values (v_hh, v_table, v_id, 'insert', auth.uid(), v_label, v_new - v_skip);
    return new;
  end if;
  v_old := to_jsonb(old);
  for k in select jsonb_object_keys(v_new) loop
    if k = any(v_skip) then continue; end if;
    if v_new->k is distinct from v_old->k then
      v_keys := array_append(v_keys, k);
      v_b := v_b || jsonb_build_object(k, v_old->k);
      v_a := v_a || jsonb_build_object(k, v_new->k);
    end if;
  end loop;
  if v_keys is null then return new; end if;
  insert into audit_log (household_id, table_name, row_id, op, by_user, label, changed, before, after)
  values (v_hh, v_table, v_id, 'update', auth.uid(), v_label, v_keys, v_b, v_a);
  return new;
end $$;

-- soft delete / restore / purge
create or replace function public.soft_delete_rows(p_kind text, p_ids uuid[])
returns integer language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_n int := 0; v_closed int;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  if p_kind in ('daily', 'travel', 'expense') then
    select count(*) into v_closed from expenses d join statements s on s.id = d.reconciled_statement_id
     where d.household_id = v_hh and d.id = any(p_ids) and s.closed_at is not null;
    if v_closed > 0 then raise exception 'this row is on a closed statement — reopen the statement on the Desk first' using errcode = 'P0001'; end if;
    update expenses set deleted_at = now() where household_id = v_hh and id = any(p_ids) and deleted_at is null;
    get diagnostics v_n = row_count;
  elsif p_kind = 'fund' then
    select count(*) into v_closed from fund_transactions_all d join statements s on s.id = d.reconciled_statement_id
     where d.household_id = v_hh and d.id = any(p_ids) and s.closed_at is not null;
    if v_closed > 0 then raise exception 'this row is on a closed statement — reopen the statement on the Desk first' using errcode = 'P0001'; end if;
    -- a transfer or a card payment goes as a unit
    update fund_transactions_all set deleted_at = now()
     where household_id = v_hh and deleted_at is null
       and (id = any(p_ids) or transfer_group_id in (select transfer_group_id from fund_transactions_all where household_id = v_hh and id = any(p_ids) and transfer_group_id is not null));
    get diagnostics v_n = row_count;
  else
    raise exception 'unknown kind %', p_kind;
  end if;
  return v_n;
end $$;
revoke all on function public.soft_delete_rows(text, uuid[]) from public;
grant execute on function public.soft_delete_rows(text, uuid[]) to authenticated, service_role;

create or replace function public.restore_rows(p_kind text, p_ids uuid[])
returns integer language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_n int := 0;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  if p_kind in ('daily', 'travel', 'expense') then
    update expenses set deleted_at = null where household_id = v_hh and id = any(p_ids) and deleted_at is not null;
  elsif p_kind = 'fund' then
    update fund_transactions_all set deleted_at = null
     where household_id = v_hh and deleted_at is not null
       and (id = any(p_ids) or transfer_group_id in (select transfer_group_id from fund_transactions_all where household_id = v_hh and id = any(p_ids) and transfer_group_id is not null));
  else
    raise exception 'unknown kind %', p_kind;
  end if;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke all on function public.restore_rows(text, uuid[]) from public;
grant execute on function public.restore_rows(text, uuid[]) to authenticated, service_role;

-- what is in the bin (last 30 days), newest first
create or replace view public.recently_deleted with (security_invoker = true) as
  select 'expense'::text as kind, e.id, e.household_id, e.deleted_at, e.date, e.description as label, e.amount, e.currency,
         e.category as detail, e.updated_by as deleted_by, (e.is_refund or e.category = 'Payment') as is_credit
    from public.expenses e where e.deleted_at is not null
  union all
  select 'fund', t.id, t.household_id, t.deleted_at, t.date, coalesce(nullif(t.remarks, ''), t.income_source, case when t.type = 'income' then 'money in' else 'money out' end),
         case when t.type = 'income' then t.amount else -t.amount end, f.currency, f.name, t.updated_by, t.type = 'income'
    from public.fund_transactions_all t join public.funds f on f.id = t.fund_id where t.deleted_at is not null;
grant select on public.recently_deleted to authenticated, service_role;

-- the bin empties itself: anything deleted more than p_days ago goes for good (the app calls this at start-up)
create or replace function public.purge_deleted(p_days integer default 30)
returns integer language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_n int := 0; v_m int := 0;
begin
  v_hh := bh_current_household(false); if v_hh is null then return 0; end if;
  perform set_config('bh.via_rpc', 'on', true);
  delete from expenses where household_id = v_hh and deleted_at < now() - make_interval(days => greatest(p_days, 1)) and (reconciled_at is null or coalesce(reconciled_by, '') <> 'manual');
  get diagnostics v_n = row_count;
  delete from fund_transactions_all where household_id = v_hh and deleted_at < now() - make_interval(days => greatest(p_days, 1)) and (reconciled_at is null or coalesce(reconciled_by, '') <> 'manual');
  get diagnostics v_m = row_count;
  return v_n + v_m;
end $$;
revoke all on function public.purge_deleted(integer) from public;
grant execute on function public.purge_deleted(integer) to authenticated, service_role;

-- ── 4 · splits are derived ───────────────────────────────────────────────
-- clients lose write access; a trigger on expenses owns the rows
drop policy if exists "hh: insert" on public.expense_splits;
drop policy if exists "hh: update" on public.expense_splits;
drop policy if exists "hh: delete" on public.expense_splits;
revoke insert, update, delete on public.expense_splits from authenticated, anon;
grant select on public.expense_splits to authenticated, service_role;

create or replace function public.bh_expense_splits_sync()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_amt numeric;
begin
  if tg_op = 'DELETE' then return old; end if;   -- the FK cascade removes the rows
  if tg_op = 'UPDATE' and new.payer_profile_id is not distinct from old.payer_profile_id
     and new.amount = old.amount and new.is_refund = old.is_refund and new.deleted_at is not distinct from old.deleted_at
     and new.household_id = old.household_id then
    return new;
  end if;
  delete from expense_splits where expense_id = new.id;
  if new.deleted_at is not null then return new; end if;
  v_amt := case when new.is_refund then -new.amount else new.amount end;
  if new.payer_profile_id is not null then
    insert into expense_splits (household_id, expense_id, profile_id, amount) values (new.household_id, new.id, new.payer_profile_id, v_amt);
  end if;
  insert into expense_splits (household_id, expense_id, profile_id, amount) values (new.household_id, new.id, null, -v_amt);
  return new;
end $$;
drop trigger if exists zza_expenses_splits on public.expenses;
create trigger zza_expenses_splits after insert or update on public.expenses for each row execute function public.bh_expense_splits_sync();

-- rebuild every row once from its payer (the split rows were a copy of exactly that)
delete from public.expense_splits;
insert into public.expense_splits (household_id, expense_id, profile_id, amount)
select e.household_id, e.id, e.payer_profile_id, case when e.is_refund then -e.amount else e.amount end
  from public.expenses e where e.payer_profile_id is not null and e.deleted_at is null;
insert into public.expense_splits (household_id, expense_id, profile_id, amount)
select e.household_id, e.id, null, case when e.is_refund then e.amount else -e.amount end
  from public.expenses e where e.deleted_at is null;

-- save_expense: no split writes, optional refund flag
drop function if exists public.save_expense(text, uuid, date, text, text, numeric, text, uuid, text, text, timestamptz);
create or replace function public.save_expense(
  p_kind text, p_id uuid, p_date date, p_description text, p_category text,
  p_amount numeric, p_currency text, p_payer uuid, p_paid_with text, p_comments text,
  p_seen_updated_at timestamptz default null, p_is_refund boolean default null
) returns void
language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_now timestamptz;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount must be positive'; end if;
  if p_payer is not null and not exists (select 1 from profiles where id = p_payer and household_id = v_hh) then
    raise exception 'payer not found';
  end if;
  if p_kind not in ('daily', 'travel', 'expense') then raise exception 'unknown kind %', p_kind; end if;
  select updated_at into v_now from expenses where id = p_id and household_id = v_hh and deleted_at is null;
  if v_now is null then raise exception 'expense not found'; end if;
  if p_seen_updated_at is not null and v_now > p_seen_updated_at + interval '1 second' then
    raise exception 'this expense was changed elsewhere after you opened it — close and reopen it to see the latest' using errcode = 'P0001';
  end if;
  update expenses
     set date = p_date, description = p_description, category = p_category,
         amount = p_amount, currency = p_currency, payer_profile_id = p_payer,
         paid_with = p_paid_with, comments = p_comments,
         is_refund = coalesce(p_is_refund, is_refund)
   where id = p_id and household_id = v_hh;
end;
$$;
revoke all on function public.save_expense(text, uuid, date, text, text, numeric, text, uuid, text, text, timestamptz, boolean) from public;
grant execute on function public.save_expense(text, uuid, date, text, text, numeric, text, uuid, text, text, timestamptz, boolean) to authenticated, service_role;

-- ── 5 · the views: refunds negative, deleted rows gone ────────────────────
create or replace view public.daily_expenses with (security_invoker = true) as
  select id, household_id, date, description, category, amount, currency, payer_profile_id, paid_with, comments,
         legacy_sync_id, created_at, payment_method_id, reconciled_at, reconciled_statement_id, reconciled_by, pot_swap_id, updated_at,
         pot_fund_id, created_by, updated_by, category_id, is_refund
    from public.expenses where trip_id is null and deleted_at is null
  with cascaded check option;
create or replace view public.travel_expenses with (security_invoker = true) as
  select id, household_id, trip_id, date, description, category, amount, currency, payer_profile_id, paid_with, comments,
         sent_to_fund, legacy_sync_id, created_at, payment_method_id, reconciled_at, reconciled_statement_id, reconciled_by, pot_swap_id, updated_at,
         pot_fund_id, created_by, updated_by, category_id, is_refund
    from public.expenses where trip_id is not null and deleted_at is null
  with cascaded check option;

create or replace view public.fund_balances with (security_invoker = true) as
 SELECT f.household_id, f.id AS fund_id, f.name, f.country, f.currency, f.is_active, f.sort_order, f.group_name, f.is_leftover_target, f.is_spend_pot,
    COALESCE(sum(CASE WHEN t.date > CURRENT_DATE OR t.kind = 'card_payment' THEN 0::numeric WHEN t.type = 'income' THEN t.amount ELSE - t.amount END), 0::numeric) -
    CASE WHEN f.is_spend_pot AND h.pot_start IS NOT NULL THEN COALESCE((
         SELECT sum(CASE WHEN de.is_refund THEN -de.amount ELSE de.amount END) FROM expenses de
          WHERE de.trip_id IS NULL AND de.deleted_at IS NULL AND de.household_id = f.household_id AND de.currency = f.currency AND de.category <> 'Payment'
            AND de.date >= h.pot_start AND de.date <= CURRENT_DATE AND de.pot_fund_id = f.id), 0::numeric)
         ELSE 0::numeric END AS balance
   FROM funds f
   JOIN households h ON h.id = f.household_id
   LEFT JOIN fund_transactions t ON t.fund_id = f.id
  GROUP BY f.id, h.pot_start;

create or replace view public.fund_balances_cleared with (security_invoker = true) as
 SELECT f.household_id, f.id AS fund_id, f.name, f.country, f.currency, f.is_active, f.sort_order, f.group_name, f.is_leftover_target, f.is_spend_pot,
    COALESCE(sum(CASE WHEN t.date > CURRENT_DATE OR t.reconciled_at IS NULL OR t.kind = 'card_payment' THEN 0::numeric WHEN t.type = 'income' THEN t.amount ELSE - t.amount END), 0::numeric) -
    CASE WHEN f.is_spend_pot AND h.pot_start IS NOT NULL THEN COALESCE((
         SELECT sum(CASE WHEN de.is_refund THEN -de.amount ELSE de.amount END) FROM expenses de
          WHERE de.trip_id IS NULL AND de.deleted_at IS NULL AND de.household_id = f.household_id AND de.currency = f.currency AND de.category <> 'Payment'
            AND de.date >= h.pot_start AND de.date <= CURRENT_DATE AND de.reconciled_at IS NOT NULL AND de.pot_fund_id = f.id), 0::numeric)
         ELSE 0::numeric END AS cleared_balance,
    CASE WHEN f.is_spend_pot AND h.pot_start IS NOT NULL THEN COALESCE((
         SELECT sum(CASE WHEN de.is_refund THEN -de.amount ELSE de.amount END) FROM expenses de
          WHERE de.trip_id IS NULL AND de.deleted_at IS NULL AND de.household_id = f.household_id AND de.currency = f.currency AND de.category <> 'Payment'
            AND de.date >= h.pot_start AND de.date <= CURRENT_DATE AND de.reconciled_at IS NULL AND de.pot_fund_id = f.id), 0::numeric)
         ELSE 0::numeric END AS pending_spend
   FROM funds f
   JOIN households h ON h.id = f.household_id
   LEFT JOIN fund_transactions t ON t.fund_id = f.id
  GROUP BY f.id, h.pot_start;

create or replace view public.fund_cash with (security_invoker = true) as
 SELECT b.household_id, b.fund_id, b.name, b.currency, b.is_active, b.is_spend_pot, b.balance,
        c.cash_balance, round(c.cash_balance - b.balance, 2) AS owed_on_cards
   FROM public.fund_balances b
   JOIN (
     SELECT f.id AS fund_id,
            COALESCE(sum(CASE WHEN t.date > CURRENT_DATE THEN 0::numeric
                              WHEN t.type = 'expense' AND t.kind = 'movement' AND bh_is_credit_card(t.account_payment_method_id) THEN 0::numeric
                              WHEN t.type = 'income' THEN t.amount ELSE - t.amount END), 0::numeric) -
            CASE WHEN f.is_spend_pot AND h.pot_start IS NOT NULL THEN COALESCE((
                 SELECT sum(CASE WHEN de.is_refund THEN -de.amount ELSE de.amount END) FROM expenses de
                 LEFT JOIN payment_methods pm ON pm.id = de.payment_method_id
                  WHERE de.trip_id IS NULL AND de.deleted_at IS NULL AND de.household_id = f.household_id AND de.currency = f.currency
                    AND de.category <> 'Payment' AND de.date >= h.pot_start AND de.date <= CURRENT_DATE
                    AND de.pot_fund_id = f.id AND coalesce(pm.kind, 'cash') <> 'credit_card'), 0::numeric)
                 ELSE 0::numeric END AS cash_balance
       FROM funds f
       JOIN households h ON h.id = f.household_id
       LEFT JOIN fund_transactions t ON t.fund_id = f.id
      GROUP BY f.id, h.pot_start
   ) c ON c.fund_id = b.fund_id;

create or replace view public.card_balances with (security_invoker = true) as
 SELECT pm.household_id, pm.id AS payment_method_id, pm.name, pm.currency, pm.closing_day, pm.is_archived,
        COALESCE(ch.charges, 0) AS charges, COALESCE(ch.credits, 0) AS credits,
        COALESCE(fr.charges, 0) AS fund_charges, COALESCE(py.paid, 0) AS payments,
        round(COALESCE(ch.charges, 0) - COALESCE(ch.credits, 0) + COALESCE(fr.charges, 0) - COALESCE(py.paid, 0), 2) AS owed,
        py.last_paid
   FROM payment_methods pm
   JOIN households h ON h.id = pm.household_id
   LEFT JOIN LATERAL (
     SELECT sum(e.amount) FILTER (WHERE e.category <> 'Payment' AND NOT e.is_refund) AS charges,
            sum(e.amount) FILTER (WHERE e.category = 'Payment' OR e.is_refund) AS credits
       FROM expenses e
      WHERE e.payment_method_id = pm.id AND e.deleted_at IS NULL AND e.date <= CURRENT_DATE AND (h.pot_start IS NULL OR e.date >= h.pot_start)
   ) ch ON true
   LEFT JOIN LATERAL (
     SELECT sum(CASE WHEN t.type = 'expense' THEN t.amount ELSE -t.amount END) AS charges
       FROM fund_transactions t
      WHERE t.account_payment_method_id = pm.id AND t.kind = 'movement' AND t.date <= CURRENT_DATE AND (h.pot_start IS NULL OR t.date >= h.pot_start)
   ) fr ON true
   LEFT JOIN LATERAL (
     SELECT sum(t.amount) AS paid, max(t.date) AS last_paid
       FROM fund_transactions t
      WHERE t.settles_payment_method_id = pm.id AND t.kind = 'card_payment' AND t.date <= CURRENT_DATE
   ) py ON true
  WHERE pm.kind = 'credit_card';

create or replace view public.statement_balances with (security_invoker = true) as
 SELECT s.id AS statement_id, s.household_id, s.payment_method_id, s.period_start, s.period_end, s.label,
        s.statement_total, s.closed_at,
        round(COALESCE(rx.total, 0) + COALESCE(rf.total, 0), 2) AS reconciled_total,
        round(COALESCE(s.statement_total, COALESCE(rx.total, 0) + COALESCE(rf.total, 0)), 2) AS due,
        round(COALESCE(py.paid, 0), 2) AS paid,
        py.last_paid, py.n_payments,
        CASE WHEN COALESCE(py.paid, 0) <= 0 THEN 'unpaid'
             WHEN COALESCE(py.paid, 0) + 0.005 >= COALESCE(s.statement_total, COALESCE(rx.total, 0) + COALESCE(rf.total, 0)) THEN 'paid'
             ELSE 'part' END AS status,
        s.opening_balance, s.closing_balance, s.payment_due
   FROM statements s
   LEFT JOIN LATERAL (
     SELECT sum(CASE WHEN e.category = 'Payment' OR e.is_refund THEN -e.amount ELSE e.amount END) AS total
       FROM expenses e WHERE e.reconciled_statement_id = s.id AND e.deleted_at IS NULL
   ) rx ON true
   LEFT JOIN LATERAL (
     SELECT sum(CASE WHEN t.type = 'expense' THEN t.amount ELSE -t.amount END) AS total
       FROM fund_transactions t WHERE t.reconciled_statement_id = s.id
   ) rf ON true
   LEFT JOIN LATERAL (
     SELECT sum(t.amount) AS paid, max(t.date) AS last_paid, count(*)::int AS n_payments
       FROM fund_transactions t WHERE t.settles_statement_id = s.id AND t.kind = 'card_payment'
   ) py ON true;

create or replace function public.pot_month_spend(p_fund uuid)
 RETURNS TABLE(month date, amount numeric, n integer, last_date date)
 LANGUAGE sql STABLE SET search_path TO 'public'
AS $function$
  select date_trunc('month', de.date)::date as month,
         sum(case when de.is_refund then -de.amount else de.amount end) as amount,
         count(*)::int as n, max(de.date) as last_date
    from expenses de
    join funds f on f.id = p_fund and f.household_id = de.household_id
    join households h on h.id = f.household_id
   where de.trip_id is null and de.deleted_at is null and f.is_spend_pot and h.pot_start is not null
     and de.currency = f.currency and de.category <> 'Payment'
     and de.date >= h.pot_start and de.date <= current_date
     and de.pot_fund_id = f.id
   group by 1 order by 1 desc
$function$;

grant all on table public.fund_balances, public.fund_balances_cleared, public.fund_cash, public.card_balances, public.statement_balances to anon, authenticated, service_role;

-- the trip send nets refunds and skips the bin
create or replace function public.send_trip_to_fund(p_trip uuid, p_fund uuid, p_date date)
 RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_hh uuid; v_cur text; v_name text; v_total numeric;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  select currency into v_cur from funds where id = p_fund and household_id = v_hh;
  if v_cur is null then raise exception 'fund not found'; end if;
  select name into v_name from trips where id = p_trip and household_id = v_hh;
  if v_name is null then raise exception 'trip not found'; end if;
  select coalesce(sum(case when is_refund then -amount else amount end), 0) into v_total
    from expenses where trip_id = p_trip and household_id = v_hh and not sent_to_fund and currency = v_cur and deleted_at is null;
  if v_total <= 0 then raise exception 'nothing unsent in this currency'; end if;
  insert into fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin)
  values (v_hh, p_fund, 'expense', 'allocation', p_date, v_total, 'Travel: ' || v_name, 'manual');
  update expenses set sent_to_fund = true
   where trip_id = p_trip and household_id = v_hh and not sent_to_fund and currency = v_cur and deleted_at is null;
  return v_total;
end;
$function$;
create or replace function public.send_foreign_to_fund(p_trip uuid, p_fund uuid, p_date date, p_ids uuid[], p_amount numeric)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
declare v_hh uuid; v_cur text; v_name text; v_n integer;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  select currency into v_cur from funds where id = p_fund and household_id = v_hh;
  if v_cur is null then raise exception 'fund not found'; end if;
  select name into v_name from trips where id = p_trip and household_id = v_hh;
  if v_name is null then raise exception 'trip not found'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'enter the converted amount'; end if;
  update expenses set sent_to_fund = true
   where trip_id = p_trip and household_id = v_hh and not sent_to_fund and currency <> v_cur and id = any(p_ids) and deleted_at is null;
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'nothing unsent to send'; end if;
  insert into fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin)
  values (v_hh, p_fund, 'expense', 'allocation', p_date, p_amount, 'Travel: ' || v_name || ' (converted)', 'manual');
end;
$function$;

-- ── proof ────────────────────────────────────────────────────────────────
do $$
declare v_bad int; v_n int; v_m int;
begin
  select count(*) into v_bad from _before b join public.fund_balances a using (fund_id) where abs(a.balance - b.balance) > 0.005;
  if v_bad > 0 then raise exception 'hygiene: % fund balances changed', v_bad; end if;
  select count(*) into v_n from public.expenses e where e.deleted_at is null and not exists
    (select 1 from public.expense_splits s where s.expense_id = e.id and s.profile_id is null and abs(s.amount + case when e.is_refund then -e.amount else e.amount end) < 0.005);
  if v_n > 0 then raise exception 'hygiene: % rows without a joint split', v_n; end if;
  select count(*) into v_m from public.fund_transactions;
  raise notice 'hygiene ok: balances unchanged · splits rebuilt · % live fund rows', v_m;
end $$;
drop table _before;

notify pgrst, 'reload schema';
commit;
