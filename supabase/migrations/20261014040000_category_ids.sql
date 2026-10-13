-- Categories by id (14 Oct 2026) — architecture review §1.2.
--
--  category_groups                 groups are rows now (per household + kind), not just a text on each category
--  categories.group_id             → category_groups
--  expenses.category_id            → categories
--  category_budgets.category_group_id → category_groups  (a budget line IS a group — custom lines create one)
--
-- The text columns (categories.group_name, expenses.category, category_budgets.category_group) stay as
-- display copies, kept in sync by triggers in both directions: a client that still writes the name gets
-- the id resolved; renaming a category or group rewrites the copies. The pot mapping now joins on ids,
-- so a rename can never orphan history or a budget line again. Balances are asserted unchanged.

begin;

create temp table _before as select fund_id, balance from public.fund_balances;

-- ── 1 · category_groups ──────────────────────────────────────────────────
create table if not exists public.category_groups (
  id            uuid primary key default gen_random_uuid(),
  household_id  uuid not null references public.households(id) on delete cascade,
  kind          text not null default 'daily' check (kind in ('daily', 'travel')),
  name          text not null check (length(trim(name)) between 1 and 60),
  sort_order    integer not null default 0,
  created_at    timestamptz not null default now(),
  unique (household_id, kind, name)
);
alter table public.category_groups enable row level security;
drop policy if exists "hh: read"   on public.category_groups;
drop policy if exists "hh: insert" on public.category_groups;
drop policy if exists "hh: update" on public.category_groups;
drop policy if exists "hh: delete" on public.category_groups;
create policy "hh: read"   on public.category_groups for select using (household_id in (select bh_member_of()));
create policy "hh: insert" on public.category_groups for insert with check (household_id in (select bh_writer_of()));
create policy "hh: update" on public.category_groups for update using (household_id in (select bh_writer_of())) with check (household_id in (select bh_writer_of()));
create policy "hh: delete" on public.category_groups for delete using (household_id in (select bh_writer_of()));
grant all on public.category_groups to authenticated, service_role;

insert into public.category_groups (household_id, kind, name, sort_order)
select household_id, kind, group_name, min(sort_order) from public.categories group by 1, 2, 3
on conflict do nothing;
-- budget lines that never had a category behind them ("Aviva SAF", "Phone Bill (Aizat)"…) become groups too
insert into public.category_groups (household_id, kind, name, sort_order)
select distinct cb.household_id, 'daily', cb.category_group, 900 from public.category_budgets cb
 where not exists (select 1 from public.category_groups g where g.household_id = cb.household_id and g.kind = 'daily' and g.name = cb.category_group)
on conflict do nothing;

-- find-or-create a group / a category by name (writers only reach these through the triggers)
create or replace function public.bh_group_for(p_hh uuid, p_kind text, p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_name text := trim(coalesce(p_name, ''));
begin
  if v_name = '' then raise exception 'a category needs a group'; end if;
  select id into v_id from category_groups where household_id = p_hh and kind = p_kind and name = v_name;
  if v_id is null then
    insert into category_groups (household_id, kind, name, sort_order)
    values (p_hh, p_kind, v_name, coalesce((select max(sort_order) + 1 from category_groups where household_id = p_hh and kind = p_kind), 0))
    on conflict (household_id, kind, name) do update set name = excluded.name
    returning id into v_id;
  end if;
  return v_id;
end $$;
create or replace function public.bh_category_for(p_hh uuid, p_kind text, p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_name text := trim(coalesce(p_name, ''));
begin
  if v_name = '' then raise exception 'pick a category'; end if;
  select id into v_id from categories where household_id = p_hh and kind = p_kind and name = v_name;
  if v_id is null then
    -- an unknown name (an import, an old client) gets a real row under "Other" rather than a dangling text
    insert into categories (household_id, kind, name, group_name, icon, sort_order)
    values (p_hh, p_kind, v_name, case when p_kind = 'travel' then '🗂️ Other' else 'Other' end,
            case when p_kind = 'travel' then '🗂️' else '🛍️' end,
            coalesce((select max(sort_order) + 1 from categories where household_id = p_hh and kind = p_kind), 0))
    returning id into v_id;
  end if;
  return v_id;
end $$;

-- ── 2 · categories.group_id ──────────────────────────────────────────────
alter table public.categories add column if not exists group_id uuid references public.category_groups(id) on delete restrict;
update public.categories c set group_id = g.id from public.category_groups g
 where g.household_id = c.household_id and g.kind = c.kind and g.name = c.group_name and c.group_id is null;
alter table public.categories alter column group_id set not null;
create unique index if not exists categories_hh_kind_name on public.categories (household_id, kind, name);
create index if not exists categories_group on public.categories (group_id);

create or replace function public.bh_category_before_write()
returns trigger language plpgsql as $$
declare v_g category_groups%rowtype;
begin
  if tg_op = 'INSERT' then
    if new.group_id is null then new.group_id := bh_group_for(new.household_id, new.kind, new.group_name);
    else select * into v_g from category_groups where id = new.group_id; new.group_name := v_g.name; end if;
  else
    if new.group_id is distinct from old.group_id then
      select * into v_g from category_groups where id = new.group_id; new.group_name := v_g.name;
    elsif new.group_name is distinct from old.group_name or new.kind is distinct from old.kind then
      new.group_id := bh_group_for(new.household_id, new.kind, new.group_name);
    end if;
  end if;
  select * into v_g from category_groups where id = new.group_id;
  if v_g.id is null then raise exception 'group not found'; end if;
  if v_g.household_id <> new.household_id then raise exception 'group belongs to another household' using errcode = '42501'; end if;
  if v_g.kind <> new.kind then raise exception 'a % category can''t sit in a % group', new.kind, v_g.kind; end if;
  new.group_name := v_g.name;
  return new;
end $$;
drop trigger if exists bx_categories_group on public.categories;
create trigger bx_categories_group before insert or update on public.categories for each row execute function public.bh_category_before_write();

-- a renamed category: history follows (the review's whole point)
create or replace function public.bh_category_after_write()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.name is distinct from old.name then
    update expenses set category = new.name where category_id = new.id and category is distinct from new.name;
  end if;
  return null;
end $$;
drop trigger if exists zy_categories_rename on public.categories;
create trigger zy_categories_rename after update on public.categories for each row execute function public.bh_category_after_write();

-- a renamed group: its categories and the month's budget lines follow
create or replace function public.bh_group_after_write()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.name is distinct from old.name then
    update categories set group_name = new.name where group_id = new.id and group_name is distinct from new.name;
    if new.kind = 'daily' then
      update category_budgets set category_group = new.name where category_group_id = new.id and category_group is distinct from new.name;
    end if;
  end if;
  return null;
end $$;
drop trigger if exists zy_category_groups_rename on public.category_groups;
create trigger zy_category_groups_rename after update on public.category_groups for each row execute function public.bh_group_after_write();
drop trigger if exists zzz_category_groups_audit on public.category_groups;
create trigger zzz_category_groups_audit after insert or update or delete on public.category_groups for each row execute function public.bh_audit();

-- ── 3 · expenses.category_id ─────────────────────────────────────────────
alter table public.expenses add column if not exists category_id uuid references public.categories(id) on delete restrict;
update public.expenses e set category_id = c.id from public.categories c
 where c.household_id = e.household_id and c.name = e.category
   and c.kind = case when e.trip_id is null then 'daily' else 'travel' end and e.category_id is null;
-- anything left (none on the real data) gets a row under Other
update public.expenses e set category_id = bh_category_for(e.household_id, case when e.trip_id is null then 'daily' else 'travel' end, e.category)
 where e.category_id is null;
alter table public.expenses alter column category_id set not null;
create index if not exists expenses_category on public.expenses (category_id, date);

create or replace function public.bh_expense_category()
returns trigger language plpgsql as $$
declare v_kind text := case when new.trip_id is null then 'daily' else 'travel' end; v_c categories%rowtype;
begin
  if tg_op = 'INSERT' then
    if new.category_id is not null and coalesce(trim(new.category), '') = '' then
      select * into v_c from categories where id = new.category_id; new.category := v_c.name;
    else
      new.category_id := bh_category_for(new.household_id, v_kind, new.category);
    end if;
  else
    if new.category_id is distinct from old.category_id then
      select * into v_c from categories where id = new.category_id; new.category := v_c.name;
    elsif new.category is distinct from old.category or new.trip_id is distinct from old.trip_id then
      new.category_id := bh_category_for(new.household_id, v_kind, new.category);
    end if;
  end if;
  select * into v_c from categories where id = new.category_id;
  if v_c.id is null then raise exception 'category not found'; end if;
  if v_c.household_id <> new.household_id then raise exception 'category belongs to another household' using errcode = '42501'; end if;
  if v_c.kind <> v_kind then new.category_id := bh_category_for(new.household_id, v_kind, v_c.name); end if;   -- daily ↔ trip conversion keeps the name
  new.category := (select name from categories where id = new.category_id);
  return new;
end $$;
drop trigger if exists bx_expenses_category on public.expenses;
create trigger bx_expenses_category before insert or update on public.expenses for each row execute function public.bh_expense_category();

-- ── 4 · category_budgets.category_group_id ───────────────────────────────
alter table public.category_budgets add column if not exists category_group_id uuid references public.category_groups(id) on delete restrict;
update public.category_budgets cb set category_group_id = g.id from public.category_groups g
 where g.household_id = cb.household_id and g.kind = 'daily' and g.name = cb.category_group and cb.category_group_id is null;
alter table public.category_budgets alter column category_group_id set not null;
create index if not exists category_budgets_group on public.category_budgets (category_group_id, month);

create or replace function public.bh_cb_before_write()
returns trigger language plpgsql as $$
declare v_g category_groups%rowtype;
begin
  if tg_op = 'INSERT' then
    if new.category_group_id is null then new.category_group_id := bh_group_for(new.household_id, 'daily', new.category_group);
    else select * into v_g from category_groups where id = new.category_group_id; new.category_group := v_g.name; end if;
  else
    if new.category_group_id is distinct from old.category_group_id then
      select * into v_g from category_groups where id = new.category_group_id; new.category_group := v_g.name;
    elsif new.category_group is distinct from old.category_group then
      new.category_group_id := bh_group_for(new.household_id, 'daily', new.category_group);
    end if;
  end if;
  select * into v_g from category_groups where id = new.category_group_id;
  if v_g.id is null then raise exception 'budget group not found'; end if;
  if v_g.household_id <> new.household_id then raise exception 'budget group belongs to another household' using errcode = '42501'; end if;
  new.category_group := v_g.name;
  return new;
end $$;
drop trigger if exists bx_category_budgets_group on public.category_budgets;
create trigger bx_category_budgets_group before insert or update on public.category_budgets for each row execute function public.bh_cb_before_write();

-- ── 5 · the pot mapping joins on ids ─────────────────────────────────────
create or replace function public.expense_pot_by_cat(p_hh uuid, p_category_id uuid, p_cur text, p_date date)
returns uuid language sql stable set search_path = public as $$
  select coalesce(
    (select cb.pot_fund_id
       from category_budgets cb
       join categories c on c.group_id = cb.category_group_id
      where c.id = p_category_id and cb.household_id = p_hh and cb.currency = p_cur
        and cb.month = date_trunc('month', p_date)::date and cb.pot_fund_id is not null
      limit 1),
    default_spend_pot(p_hh, p_cur))
$$;
-- same rule as before, by id: trip rows and 'Payment' never map to a pot
drop function if exists public.expense_pot_for(uuid, uuid, text, text, date);
create or replace function public.expense_pot_for(p_hh uuid, p_trip uuid, p_category_id uuid, p_category text, p_cur text, p_date date)
returns uuid language sql stable set search_path = public as $$
  select case when p_trip is null and p_category <> 'Payment' then expense_pot_by_cat(p_hh, p_category_id, p_cur, p_date) end
$$;
create or replace function public.bh_expense_stamp_pot()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' or new.category_id is distinct from old.category_id or new.category is distinct from old.category
     or new.currency is distinct from old.currency or new.date is distinct from old.date
     or new.trip_id is distinct from old.trip_id or new.household_id is distinct from old.household_id then
    new.pot_fund_id := expense_pot_for(new.household_id, new.trip_id, new.category_id, new.category, new.currency, new.date);
  end if;
  return new;
end $$;
create or replace function public.restamp_pots(p_hh uuid, p_from date default null, p_to date default null)
returns integer language plpgsql security definer set search_path = public as $$
declare v_n integer;
begin
  update expenses e set pot_fund_id = expense_pot_for(e.household_id, e.trip_id, e.category_id, e.category, e.currency, e.date)
   where e.household_id = p_hh and e.trip_id is null
     and (p_from is null or e.date >= p_from) and (p_to is null or e.date < p_to)
     and pot_fund_id is distinct from expense_pot_for(e.household_id, e.trip_id, e.category_id, e.category, e.currency, e.date);
  get diagnostics v_n = row_count;
  return v_n;
end $$;
-- the old name-based helper keeps working for anything that still calls it
create or replace function public.expense_pot(p_hh uuid, p_category text, p_cur text, p_date date)
returns uuid language sql stable set search_path = public as $$
  select expense_pot_by_cat(p_hh, (select id from categories where household_id = p_hh and kind = 'daily' and name = p_category limit 1), p_cur, p_date)
$$;

-- ── 6 · same-household checks + views ────────────────────────────────────
create or replace function public.bh_check_refs()
returns trigger language plpgsql as $$
begin
  if tg_table_name = 'expenses' then
    perform bh_assert_hh('public.profiles', new.payer_profile_id, new.household_id, 'payer');
    perform bh_assert_hh('public.payment_methods', new.payment_method_id, new.household_id, 'card');
    perform bh_assert_hh('public.statements', new.reconciled_statement_id, new.household_id, 'statement');
    perform bh_assert_hh('public.pot_swaps', new.pot_swap_id, new.household_id, 'pot swap');
    perform bh_assert_hh('public.funds', new.pot_fund_id, new.household_id, 'pot');
    perform bh_assert_hh('public.categories', new.category_id, new.household_id, 'category');
    if new.trip_id is not null then perform bh_assert_hh('public.trips', new.trip_id, new.household_id, 'trip'); end if;
  end if;
  if tg_table_name = 'fund_transactions' then
    perform bh_assert_hh('public.funds', new.fund_id, new.household_id, 'fund');
    perform bh_assert_hh('public.payment_methods', new.account_payment_method_id, new.household_id, 'account');
    perform bh_assert_hh('public.statements', new.reconciled_statement_id, new.household_id, 'statement');
    perform bh_assert_hh('public.payment_methods', new.settles_payment_method_id, new.household_id, 'card');
    perform bh_assert_hh('public.statements', new.settles_statement_id, new.household_id, 'statement');
  end if;
  if tg_table_name = 'statements' then
    perform bh_assert_hh('public.payment_methods', new.payment_method_id, new.household_id, 'card');
  end if;
  if tg_table_name = 'category_budgets' then
    perform bh_assert_hh('public.funds', new.pot_fund_id, new.household_id, 'pot');
    perform bh_assert_hh('public.category_groups', new.category_group_id, new.household_id, 'budget group');
  end if;
  if tg_table_name = 'categories' then
    perform bh_assert_hh('public.category_groups', new.group_id, new.household_id, 'group');
  end if;
  if tg_table_name = 'fund_budgets' then
    perform bh_assert_hh('public.funds', new.fund_id, new.household_id, 'fund');
  end if;
  if tg_table_name = 'expense_splits' then
    perform bh_assert_hh('public.profiles', new.profile_id, new.household_id, 'person');
  end if;
  if tg_table_name = 'payment_methods' then
    perform bh_assert_hh('public.profiles', new.profile_id, new.household_id, 'owner');
    perform bh_assert_hh('public.funds', new.pot_fund_id, new.household_id, 'pot');
  end if;
  if tg_table_name = 'pot_swaps' then
    perform bh_assert_hh('public.funds', new.cover_fund_id, new.household_id, 'cover fund');
    perform bh_assert_hh('public.funds', new.land_fund_id, new.household_id, 'landing fund');
    perform bh_assert_hh('public.funds', new.bank_from_fund_id, new.household_id, 'bank-side fund');
    perform bh_assert_hh('public.funds', new.bank_to_fund_id, new.household_id, 'bank pot');
  end if;
  if tg_table_name = 'household_members' or tg_table_name = 'member_invites' then
    perform bh_assert_hh('public.profiles', new.profile_id, new.household_id, 'person');
  end if;
  if tg_table_name = 'households' then
    perform bh_assert_hh('public.funds', new.travel_fund_id, new.id, 'travel fund');
  end if;
  return new;
end $$;
drop trigger if exists categories_check_refs on public.categories;
create trigger categories_check_refs before insert or update on public.categories for each row execute function public.bh_check_refs();

create or replace view public.daily_expenses with (security_invoker = true) as
  select id, household_id, date, description, category, amount, currency, payer_profile_id, paid_with, comments,
         legacy_sync_id, created_at, payment_method_id, reconciled_at, reconciled_statement_id, reconciled_by, pot_swap_id, updated_at,
         pot_fund_id, created_by, updated_by, category_id
    from public.expenses where trip_id is null
  with cascaded check option;
create or replace view public.travel_expenses with (security_invoker = true) as
  select id, household_id, trip_id, date, description, category, amount, currency, payer_profile_id, paid_with, comments,
         sent_to_fund, legacy_sync_id, created_at, payment_method_id, reconciled_at, reconciled_statement_id, reconciled_by, pot_swap_id, updated_at,
         pot_fund_id, created_by, updated_by, category_id
    from public.expenses where trip_id is not null
  with cascaded check option;

-- ── proof ────────────────────────────────────────────────────────────────
do $$
declare v_bad int; v_n int;
begin
  select count(*) into v_bad from _before b join public.fund_balances a using (fund_id) where abs(a.balance - b.balance) > 0.005;
  if v_bad > 0 then raise exception 'category ids: % fund balances changed', v_bad; end if;
  select count(*) into v_n from public.expenses e join public.categories c on c.id = e.category_id where c.name <> e.category;
  if v_n > 0 then raise exception 'category ids: % rows disagree with their category', v_n; end if;
  select count(*) into v_n from public.category_groups;
  raise notice 'category ids ok: balances unchanged · % groups', v_n;
end $$;
drop table _before;

notify pgrst, 'reload schema';
commit;
