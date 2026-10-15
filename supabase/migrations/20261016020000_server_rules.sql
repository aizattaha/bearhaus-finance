-- The server keeps the rules (v2 sprint 2, chunk 3).
--
--  1 · Transfers (D1-F7)
--        record_transfer() writes both sides in one go: same date, one out and one in, the same amount
--        when both funds share a currency. A retap with the same id returns the transfer already saved.
--        A deferred check looks at every transfer and card-payment group at commit and notes a broken one
--        in integrity_issues (log-only for one release; sprint 3 makes it refuse).
--  2 · The month plan is applied once, on the server (D1-F5)
--        apply_month_plan(month, skip) works out the same rows the phone did — contributions, the leftover
--        per currency, the spending budget per pot — and records the month in plan_applications. A second
--        Apply for the month is refused, including two phones at once. plan_status(month) answers
--        "applied? saved? which version?"; save_month_plan refuses a save over a newer version.
--        A client can no longer write plan rows itself.
--  3 · Past months stay put (D1-F6)
--        Reordering, archiving or re-tagging funds, and changing budget lines, re-file purchases from the
--        household's current month only. A pot that still holds past purchases can't stop being a pot; a fund
--        with money in it can't change currency; a budget line's pot must be an active spending pot in its
--        currency; pot_start is set once.
--  4 · "Payment" is a role, not just a name (D1-F9)
--        categories.role = 'settle_up' on each household's Payment category; the database refuses renaming,
--        hiding or deleting it, so every view that keys on the name stays right.
--  5 · A fund row's kind is what the app says (D1-F8)
--        kind has no default any more: an app may send 'movement' and it is kept (an income called
--        "Travel: refund" stays income); rows sent without a kind are worked out from the remark as before.
--        Allocations and card payments are written by the server only.
--  6 · fund_transactions.updated_at, so an edit can check the row hasn't changed on another phone.
--
-- No balance moves (asserted).
begin;
create temp table _b_fund as select fund_id, balance from public.fund_balances;
create temp table _b_cash as select fund_id, cash_balance from public.fund_cash;
create temp table _b_card as select payment_method_id, owed from public.card_balances;

-- ── 6 · fund rows carry updated_at ──────────────────────────────────────
alter table public.fund_transactions_all add column if not exists updated_at timestamptz not null default now();
drop trigger if exists zz_fund_transactions_touch on public.fund_transactions_all;
create trigger zz_fund_transactions_touch before update on public.fund_transactions_all
  for each row execute function public.bh_touch_updated_at();
create or replace view public.fund_transactions with (security_invoker = true) as
 SELECT id, household_id, fund_id, type, date, amount, remarks, origin, legacy_sync_id, created_at, income_source,
        account_payment_method_id, transfer_group_id, reconciled_at, reconciled_statement_id, reconciled_by, kind,
        settles_payment_method_id, settles_statement_id, created_by, updated_by, deleted_at, updated_at
   FROM fund_transactions_all
  WHERE deleted_at IS NULL;

-- ── 5 · kind: the app's word, else the remark rule ──────────────────────
alter table public.fund_transactions_all alter column kind drop default;

create or replace function public.bh_fund_before_write()
returns trigger language plpgsql set search_path = public as $$
declare v_internal boolean;
begin
  if tg_op = 'INSERT' then
    v_internal := new.origin = 'planned' or new.transfer_group_id is not null
               or new.remarks ~ '^Transfer [→←] ' or new.remarks like '%Pot swap · %' or new.remarks like 'Travel: %';
    if new.kind is null then
      new.kind := case when v_internal then 'allocation' else 'movement' end;
    elsif new.kind = 'movement' and v_internal and current_user not in ('authenticated', 'anon') then
      new.kind := 'allocation';   -- server functions keep the old rule; an app's explicit 'movement' stands
    end if;
    -- internal rows never appear on a bank statement: plan writes and transfers tick themselves
    if new.reconciled_at is null and (new.origin = 'planned' or new.remarks ~ '^Transfer [→←] ') then
      new.reconciled_at := now(); new.reconciled_by := 'auto'; new.reconciled_statement_id := null;
    end if;
  end if;
  if new.kind = 'card_payment' and not exists
     (select 1 from payment_methods where id = new.settles_payment_method_id and kind = 'credit_card') then
    raise exception 'a card payment must name a credit card' using errcode = 'P0001';
  end if;
  if new.settles_statement_id is not null and not exists
     (select 1 from statements where id = new.settles_statement_id and payment_method_id = new.settles_payment_method_id) then
    raise exception 'that statement belongs to another card' using errcode = 'P0001';
  end if;
  return new;
end $$;

-- an app writes money movements only; plan rows, transfers' allocations and card payments come from the server
create or replace function public.bh_fund_client_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if tg_op = 'INSERT' then
    if new.origin = 'planned' then
      raise exception 'this copy of the app is out of date — reload it, then apply the plan again' using errcode = 'P0001';
    end if;
    if new.kind is not null and new.kind <> 'movement' then
      raise exception 'that kind of row is recorded by the server' using errcode = 'P0001';
    end if;
    new.reconciled_at := null; new.reconciled_by := null; new.reconciled_statement_id := null;   -- transfers re-tick themselves next
    new.deleted_at := null; new.reviewed_at := null;
    new.created_by := auth.uid();
    return new;
  end if;
  new.created_by := old.created_by;
  new.deleted_at := old.deleted_at;
  if old.transfer_group_id is not null and (
       new.amount is distinct from old.amount or new.date is distinct from old.date
    or new.fund_id is distinct from old.fund_id or new.type is distinct from old.type
    or new.kind is distinct from old.kind or new.transfer_group_id is distinct from old.transfer_group_id) then
    raise exception 'one side of a transfer can''t be changed on its own — delete both sides and enter it again' using errcode = 'P0001';
  end if;
  if old.transfer_group_id is null and new.transfer_group_id is not null then
    raise exception 'rows are paired by the server, not by an edit' using errcode = 'P0001';
  end if;
  return new;
end $$;

-- ── 1 · transfers ───────────────────────────────────────────────────────
create table if not exists public.integrity_issues (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  check_name   text not null,
  ref_id       uuid,
  detail       text not null default '',          -- words, counts and ids only — never amounts
  noted_at     timestamptz not null default now()
);
create index if not exists integrity_issues_hh on public.integrity_issues (household_id, noted_at desc);
alter table public.integrity_issues enable row level security;   -- no app policy: the nightly check reads it
revoke all on public.integrity_issues from public, anon, authenticated;
grant all on public.integrity_issues to service_role;

-- what is wrong with a group of fund rows sharing a transfer_group_id, or null when it holds together
create or replace function public.bh_group_problem(p_group uuid)
returns text language sql stable set search_path = public as $$
  with r as (select * from fund_transactions_all where transfer_group_id = p_group),
       live as (select l.*, f.currency from r l join funds f on f.id = l.fund_id where l.deleted_at is null)
  select case
    when p_group is null or not exists (select 1 from live) then null
    when exists (select 1 from r where deleted_at is not null) then 'part of the group is deleted'
    when (select bool_and(kind = 'card_payment') from live) then
      case when (select count(distinct settles_payment_method_id) from live) > 1 then 'card payment legs name different cards'
           when (select count(distinct date) from live) > 1 then 'card payment legs on different dates'
           when (select count(distinct coalesce(settles_statement_id::text, '-')) from live) > 1 then 'card payment legs on different statements' end
    when (select bool_or(kind = 'card_payment') from live) then 'a card payment grouped with other rows'
    when (select count(*) from live) <> 2 then 'a transfer with ' || (select count(*) from live) || ' rows'
    when (select count(*) from live where type = 'expense') <> 1 then 'a transfer that isn''t one out and one in'
    when (select count(distinct date) from live) > 1 then 'transfer sides on different dates'
    when (select count(distinct currency) from live) = 1 and (select max(amount) - min(amount) from live) > 0.005 then 'transfer sides differ'
  end
$$;
revoke execute on function public.bh_group_problem(uuid) from public, anon, authenticated;

-- checked at commit, once per group per transaction. Log-only this release (v2 sprint 2).
create or replace function public.bh_group_check()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_g uuid; v_hh uuid; v_p text;
begin
  foreach v_g in array array_remove(array[case when tg_op <> 'DELETE' then new.transfer_group_id end,
                                          case when tg_op <> 'INSERT' then old.transfer_group_id end], null) loop
    v_p := bh_group_problem(v_g);
    if v_p is not null then
      v_hh := case when tg_op = 'DELETE' then old.household_id else new.household_id end;
      insert into integrity_issues (household_id, check_name, ref_id, detail)
      select v_hh, 'fund group', v_g, v_p
       where not exists (select 1 from integrity_issues where ref_id = v_g and noted_at = now());
    end if;
  end loop;
  return null;
end $$;
revoke execute on function public.bh_group_check() from public, anon, authenticated;
drop trigger if exists zz_fund_group_check on public.fund_transactions_all;
create constraint trigger zz_fund_group_check after insert or update or delete on public.fund_transactions_all
  deferrable initially deferred for each row execute function public.bh_group_check();

create or replace function public.record_transfer(p_from uuid, p_to uuid, p_date date, p_amount numeric,
  p_received numeric default null, p_note text default null, p_id uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_from funds%rowtype; v_to funds%rowtype; v_recv numeric; v_g uuid := coalesce(p_id, gen_random_uuid()); v_note text;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  if exists (select 1 from fund_transactions_all where transfer_group_id = v_g) then
    if exists (select 1 from fund_transactions_all where transfer_group_id = v_g and household_id = v_hh) then return v_g; end if;   -- a retap: already saved
    raise exception 'that transfer id is taken';
  end if;
  select * into v_from from funds where id = p_from and household_id = v_hh;
  select * into v_to from funds where id = p_to and household_id = v_hh;
  if v_from.id is null or v_to.id is null then raise exception 'fund not found'; end if;
  if v_from.id = v_to.id then raise exception 'pick two different funds' using errcode = 'P0001'; end if;
  if p_date is null then raise exception 'pick a date' using errcode = 'P0001'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'enter the amount' using errcode = 'P0001'; end if;
  v_recv := coalesce(p_received, p_amount);
  if v_recv <= 0 then raise exception 'enter the amount received in %', v_to.currency using errcode = 'P0001'; end if;
  if v_from.currency = v_to.currency and abs(v_recv - p_amount) > 0.005 then
    raise exception 'both funds hold % — a transfer between them moves the same amount', v_from.currency using errcode = 'P0001';
  end if;
  v_note := coalesce(' · ' || nullif(trim(p_note), ''), '');
  insert into fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin, transfer_group_id)
  values (v_hh, v_from.id, 'expense', 'allocation', p_date, round(p_amount, 2), 'Transfer → ' || v_to.name || v_note, 'manual', v_g),
         (v_hh, v_to.id,   'income',  'allocation', p_date, round(v_recv, 2),   'Transfer ← ' || v_from.name || v_note, 'manual', v_g);
  if bh_group_problem(v_g) is not null then raise exception 'the transfer didn''t balance: %', bh_group_problem(v_g); end if;
  return v_g;
end $$;
revoke execute on function public.record_transfer(uuid, uuid, date, numeric, numeric, text, uuid) from public, anon;
grant execute on function public.record_transfer(uuid, uuid, date, numeric, numeric, text, uuid) to authenticated, service_role;

-- ── 2 · the month plan ──────────────────────────────────────────────────
create table if not exists public.plan_applications (
  id           uuid primary key default gen_random_uuid(),   -- the activity log keys rows by id
  household_id uuid not null references public.households(id) on delete cascade,
  month        date not null check (month = date_trunc('month', month)::date),
  applied_on   date not null,
  applied_at   timestamptz not null default now(),
  applied_by   uuid,
  rows_written integer not null default 0,
  unique (household_id, month)
);
alter table public.plan_applications enable row level security;
create policy "hh: read" on public.plan_applications for select using (household_id in (select bh_member_of()));
revoke all on public.plan_applications from public, anon;
grant select on public.plan_applications to authenticated;
grant all on public.plan_applications to service_role;
drop trigger if exists zzz_plan_applications_audit on public.plan_applications;
create trigger zzz_plan_applications_audit after insert or update or delete on public.plan_applications
  for each row execute function public.bh_audit();
-- months applied the old way, by the phone writing plan rows
insert into public.plan_applications (household_id, month, applied_on, applied_at)
select household_id, date_trunc('month', date)::date, min(date), min(created_at)
  from public.fund_transactions where origin = 'planned'
 group by household_id, date_trunc('month', date)::date
on conflict (household_id, month) do nothing;

-- a fingerprint of a month's saved plan: a save names the version it started from
create or replace function public.bh_plan_version(p_hh uuid, p_month date)
returns text language sql stable set search_path = public as $$
  select md5(
       coalesce((select string_agg(source_name || '|' || currency || '|' || amount::text, ';' order by source_name, currency, amount)
                   from income_budgets where household_id = p_hh and month = p_month), '')
    || '#' || coalesce((select string_agg(category_group || '|' || currency || '|' || amount::text || '|' || coalesce(pot_fund_id::text, ''), ';' order by category_group, currency)
                   from category_budgets where household_id = p_hh and month = p_month), '')
    || '#' || coalesce((select string_agg(fund_id::text || '|' || amount::text, ';' order by fund_id)
                   from fund_budgets where household_id = p_hh and month = p_month), ''))
$$;
revoke execute on function public.bh_plan_version(uuid, date) from public, anon;
grant execute on function public.bh_plan_version(uuid, date) to authenticated, service_role;

-- applied? (on which day) · saved? · which version — one call instead of six queries
create or replace function public.plan_status(p_month date)
returns table (month date, applied_on date, saved boolean, version text)
language sql stable set search_path = public as $$
  with hh as (select household_id from household_members where user_id = auth.uid() limit 1)
  select p_month,
         coalesce((select a.applied_on from plan_applications a where a.household_id = (select household_id from hh) and a.month = p_month),
                  (select min(t.date) from fund_transactions t where t.household_id = (select household_id from hh) and t.origin = 'planned'
                      and t.date >= p_month and t.date < (p_month + interval '1 month')::date)),
         exists (select 1 from income_budgets   where household_id = (select household_id from hh) and month = p_month)
      or exists (select 1 from category_budgets where household_id = (select household_id from hh) and month = p_month)
      or exists (select 1 from fund_budgets     where household_id = (select household_id from hh) and month = p_month),
         bh_plan_version((select household_id from hh), p_month)
$$;
revoke execute on function public.plan_status(date) from public, anon;
grant execute on function public.plan_status(date) to authenticated, service_role;

-- Apply: the same rows the phone used to write, worked out here, once per month
create or replace function public.apply_month_plan(p_month date, p_skip uuid[] default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_today date; v_pot_start date; v_label text; v_contrib int; v_left int; v_pot int; v_pots text;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  if p_month is null or p_month <> date_trunc('month', p_month)::date then raise exception 'pick a month' using errcode = 'P0001'; end if;
  v_today := bh_today(v_hh);
  if p_month > date_trunc('month', v_today)::date then raise exception 'a month''s plan can be applied once the month starts' using errcode = 'P0001'; end if;
  -- the month's lock row first: a second Apply (or a second phone at the same moment) waits here, then finds it taken
  insert into plan_applications (household_id, month, applied_on, applied_by) values (v_hh, p_month, v_today, auth.uid())
  on conflict (household_id, month) do nothing;
  if not found or exists (select 1 from fund_transactions where household_id = v_hh and origin = 'planned'
                            and date >= p_month and date < (p_month + interval '1 month')::date) then
    raise exception '% plan is already applied', to_char(p_month, 'FMMonth') using errcode = 'P0001';
  end if;
  select pot_start into v_pot_start from households where id = v_hh;
  v_label := to_char(p_month, 'FMMonth YYYY') || ' plan';

  with fb as (       -- contributions: active funds, not the leftover funds, not skipped this month
    select b.fund_id, f.currency, b.amount
      from fund_budgets b join funds f on f.id = b.fund_id
     where b.household_id = v_hh and b.month = p_month and b.amount > 0 and f.is_active and not f.is_leftover_target
       and not (b.fund_id = any(coalesce(p_skip, '{}')))
  ), inc as (select currency, sum(amount) as amt from income_budgets where household_id = v_hh and month = p_month and amount > 0 group by currency),
     cat as (select currency, sum(amount) as amt from category_budgets where household_id = v_hh and month = p_month and amount > 0 group by currency),
     fbs as (select currency, sum(amount) as amt from fb group by currency),
     curs as (select currency from inc union select currency from cat union select currency from fbs),
  lft as (           -- leftover per currency = income − spending budget − contributions, to that currency's leftover fund
    select (select id from funds where household_id = v_hh and is_active and is_leftover_target and currency = c.currency order by sort_order limit 1) as fund_id,
           round(coalesce(i.amt, 0) - coalesce(k.amt, 0) - coalesce(s.amt, 0), 2) as amount
      from curs c left join inc i using (currency) left join cat k using (currency) left join fbs s using (currency)
  ), pots as (       -- the spending budget lands in each line's pot (else the currency's first pot), from pot_start on
    select coalesce((select f.id from funds f where f.id = cb.pot_fund_id and f.household_id = v_hh and f.is_active and f.is_spend_pot and f.currency = cb.currency),
                    default_spend_pot(v_hh, cb.currency)) as fund_id, cb.amount
      from category_budgets cb
     where cb.household_id = v_hh and cb.month = p_month and cb.amount > 0 and v_pot_start is not null and p_month >= v_pot_start
  ), plan_rows as (
    select fund_id, amount, '' as suffix from fb
    union all select fund_id, amount, ' — leftover' from lft where fund_id is not null and amount > 0.005
    union all select fund_id, round(sum(amount), 2), ' — spending budget' from pots where fund_id is not null group by fund_id having round(sum(amount), 2) > 0.005
  ), ins as (
    insert into fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin)
    select v_hh, fund_id, 'income', 'allocation', v_today, amount, v_label || suffix, 'planned' from plan_rows
    returning fund_id, remarks
  )
  select count(*) filter (where i.remarks = v_label), count(*) filter (where i.remarks like '% — leftover'),
         count(*) filter (where i.remarks like '% — spending budget'),
         string_agg(f.name, ' & ' order by f.sort_order) filter (where i.remarks like '% — spending budget')
    into v_contrib, v_left, v_pot, v_pots
    from ins i join funds f on f.id = i.fund_id;
  if v_contrib + v_left + v_pot = 0 then raise exception 'everything is skipped — nothing to apply' using errcode = 'P0001'; end if;
  update plan_applications set rows_written = v_contrib + v_left + v_pot where household_id = v_hh and month = p_month;
  return jsonb_build_object('applied_on', v_today, 'contributions', v_contrib, 'leftover', v_left > 0, 'pots', coalesce(v_pots, ''));
end $$;
revoke execute on function public.apply_month_plan(date, uuid[]) from public, anon;
grant execute on function public.apply_month_plan(date, uuid[]) to authenticated, service_role;

-- Save: refuses to overwrite a version it didn't start from; re-files from the current month only
drop function if exists public.save_month_plan(date, jsonb, jsonb, jsonb);
create or replace function public.save_month_plan(p_month date, p_inc jsonb, p_cat jsonb, p_fb jsonb, p_seen text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_hh uuid;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  if p_seen is not null and p_seen <> bh_plan_version(v_hh, p_month) then
    raise exception 'the plan was changed on another phone — close it and open it again to see the latest' using errcode = 'P0001';
  end if;

  delete from income_budgets where household_id = v_hh and month = p_month;
  insert into income_budgets (household_id, month, source_name, currency, amount)
  select v_hh, p_month, x.source_name, x.currency, x.amount
  from jsonb_to_recordset(coalesce(p_inc, '[]'::jsonb)) as x(source_name text, currency text, amount numeric)
  where x.amount > 0;

  delete from category_budgets where household_id = v_hh and month = p_month;
  insert into category_budgets (household_id, month, category_group, currency, amount, pot_fund_id)
  select v_hh, p_month, x.category_group, x.currency, x.amount,
         case when exists (select 1 from funds f where f.id = x.pot_fund_id and f.household_id = v_hh)
              then x.pot_fund_id else null end
  from jsonb_to_recordset(coalesce(p_cat, '[]'::jsonb)) as x(category_group text, currency text, amount numeric, pot_fund_id uuid)
  where x.amount > 0;

  delete from fund_budgets where household_id = v_hh and month = p_month;
  insert into fund_budgets (household_id, month, fund_id, amount)
  select v_hh, p_month, x.fund_id, x.amount
  from jsonb_to_recordset(coalesce(p_fb, '[]'::jsonb)) as x(fund_id uuid, amount numeric)
  where x.amount > 0
    and exists (select 1 from funds f where f.id = x.fund_id and f.household_id = v_hh);
  -- the budget-line trigger re-files this month's purchases (never a past month's)
end $$;
revoke execute on function public.save_month_plan(date, jsonb, jsonb, jsonb, text) from public, anon;
grant execute on function public.save_month_plan(date, jsonb, jsonb, jsonb, text) to authenticated, service_role;

-- ── 3 · past months stay put ────────────────────────────────────────────
create or replace function public.bh_funds_restamp()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_from date := date_trunc('month', bh_today(coalesce(new.household_id, old.household_id)))::date;
begin
  if tg_op = 'DELETE' then perform restamp_pots(old.household_id, v_from); return old; end if;
  if tg_op = 'INSERT' and new.is_spend_pot then perform restamp_pots(new.household_id, v_from); end if;
  if tg_op = 'UPDATE' and (new.is_spend_pot is distinct from old.is_spend_pot or new.is_active is distinct from old.is_active
     or new.sort_order is distinct from old.sort_order or new.currency is distinct from old.currency) then
    perform restamp_pots(new.household_id, v_from);
  end if;
  return new;
end $$;

create or replace function public.bh_cb_restamp()
returns trigger language plpgsql security definer set search_path = public as $$
declare r record; v_from date;
begin
  r := coalesce(new, old);
  v_from := greatest(r.month, date_trunc('month', bh_today(r.household_id))::date);
  perform restamp_pots(r.household_id, v_from, (r.month + interval '1 month')::date);
  return coalesce(new, old);
end $$;

create or replace function public.bh_funds_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_n int; v_month date := date_trunc('month', bh_today(old.household_id))::date;
begin
  if old.is_spend_pot and not new.is_spend_pot then
    select count(*) into v_n from expenses e
     where e.pot_fund_id = old.id and e.fund_id is null and e.trip_id is null and e.deleted_at is null and e.date < v_month;
    if v_n > 0 then
      raise exception '% holds % past purchases as a spending pot — it stays a pot (archive it to hide it)', old.name, v_n using errcode = 'P0001';
    end if;
  end if;
  if new.currency is distinct from old.currency and (
       exists (select 1 from fund_transactions_all t where t.fund_id = old.id)
    or exists (select 1 from expenses e where e.fund_id = old.id or e.pot_fund_id = old.id)
    or exists (select 1 from card_openings o where o.fund_id = old.id)) then
    raise exception '% already holds % — its currency can''t change (start a new fund instead)', old.name, old.currency using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke execute on function public.bh_funds_guard() from public, anon, authenticated;
drop trigger if exists b1_funds_guard on public.funds;
create trigger b1_funds_guard before update on public.funds for each row execute function public.bh_funds_guard();

-- a budget line's own pot counts only while it is a spending pot in the line's currency
create or replace function public.expense_pot_by_cat(p_hh uuid, p_category_id uuid, p_cur text, p_date date)
returns uuid language sql stable set search_path = public as $$
  select coalesce(
    (select cb.pot_fund_id
       from category_budgets cb
       join categories c on c.group_id = cb.category_group_id
       join funds f on f.id = cb.pot_fund_id and f.household_id = p_hh and f.is_spend_pot and f.currency = p_cur
      where c.id = p_category_id and cb.household_id = p_hh and cb.currency = p_cur
        and cb.month = date_trunc('month', p_date)::date and cb.pot_fund_id is not null
      limit 1),
    default_spend_pot(p_hh, p_cur))
$$;

create or replace function public.bh_budget_pot_check()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.pot_fund_id is not null and not exists (select 1 from funds f where f.id = new.pot_fund_id and f.household_id = new.household_id
                                                    and f.is_spend_pot and f.is_active and f.currency = new.currency) then
    raise exception 'the pot for % must be an active spending pot in %', new.category_group, new.currency using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke execute on function public.bh_budget_pot_check() from public, anon, authenticated;
drop trigger if exists c1_category_budgets_pot on public.category_budgets;
create trigger c1_category_budgets_pot before insert or update of pot_fund_id, currency on public.category_budgets
  for each row execute function public.bh_budget_pot_check();

create or replace function public.bh_pot_start_once()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user in ('authenticated', 'anon') and old.pot_start is not null and new.pot_start is distinct from old.pot_start then
    raise exception 'the start date is set once' using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke execute on function public.bh_pot_start_once() from public, anon, authenticated;
drop trigger if exists b3_households_pot_start on public.households;
create trigger b3_households_pot_start before update of pot_start on public.households
  for each row execute function public.bh_pot_start_once();

-- ── 4 · "Payment" is the settle-up role ─────────────────────────────────
alter table public.categories add column if not exists role text check (role in ('settle_up'));
create unique index if not exists categories_one_role on public.categories (household_id, role) where role is not null;
update public.categories set role = 'settle_up'
 where id in (select distinct on (household_id) id from public.categories
               where kind = 'daily' and name = 'Payment' order by household_id, is_active desc, sort_order)
   and role is null;

create or replace function public.bh_category_role_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.kind = 'daily' and new.name = 'Payment' and new.role is null
       and not exists (select 1 from categories where household_id = new.household_id and role = 'settle_up') then
      new.role := 'settle_up';
    end if;
    return new;
  end if;
  if tg_op = 'DELETE' then
    if old.role is not null and exists (select 1 from households where id = old.household_id) then
      raise exception '“%” settles up between you — it can''t be deleted', old.name using errcode = 'P0001';
    end if;
    return old;
  end if;
  if old.role is not null and (new.name is distinct from old.name or new.kind is distinct from old.kind
                               or not new.is_active or new.role is distinct from old.role) then
    raise exception '“%” settles up between you — it can''t be renamed or hidden', old.name using errcode = 'P0001';
  end if;
  if old.role is null and new.role is not null then raise exception 'roles are set by the server' using errcode = 'P0001'; end if;
  return new;
end $$;
revoke execute on function public.bh_category_role_guard() from public, anon, authenticated;
drop trigger if exists b1_categories_role on public.categories;
create trigger b1_categories_role before insert or update or delete on public.categories
  for each row execute function public.bh_category_role_guard();

-- ── proof ────────────────────────────────────────────────────────────────
do $$
declare v_bad int; v_groups int; v_apps int; v_roles int;
begin
  select count(*) into v_bad from _b_fund b join public.fund_balances a using (fund_id) where abs(a.balance - b.balance) > 0.005;
  if v_bad > 0 then raise exception 'server rules: % fund balances changed', v_bad; end if;
  select count(*) into v_bad from _b_cash b join public.fund_cash a using (fund_id) where abs(a.cash_balance - b.cash_balance) > 0.005;
  if v_bad > 0 then raise exception 'server rules: % funds'' cash changed', v_bad; end if;
  select count(*) into v_bad from _b_card b join public.card_balances a using (payment_method_id) where abs(a.owed - b.owed) > 0.005;
  if v_bad > 0 then raise exception 'server rules: % card balances changed', v_bad; end if;
  select count(*) into v_groups from (select distinct transfer_group_id from public.fund_transactions_all where transfer_group_id is not null) g
   where public.bh_group_problem(g.transfer_group_id) is not null;
  select count(*) into v_apps from public.plan_applications;
  select count(*) into v_roles from public.categories where role is not null;
  raise notice 'server rules ok: balances unchanged; % groups need a look; % months marked applied; % settle-up categories', v_groups, v_apps, v_roles;
end $$;
drop table _b_fund; drop table _b_cash; drop table _b_card;
notify pgrst, 'reload schema';
commit;
