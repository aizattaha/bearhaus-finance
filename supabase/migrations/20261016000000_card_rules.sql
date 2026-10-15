-- Card rules (v2 sprint 2, chunk 1 — Aizat's request, 15 Oct 2026).
--
--  payment_methods.show_daily / show_trip / show_fund
--        where a card is offered: Daily expenses, Trip expenses, purchases From a fund. Replaces the single
--        "travel only" flag; travel_only is kept in step both ways for one sprint so an older app still works.
--  payment_methods.archived_at
--        when a card was archived (set by trigger).
--  card_defaults(household, person | shared, context, card)
--        the card each person's form starts on, per kind of expense. The card must belong to the household,
--        not be archived, be offered in that context, and be that person's own card, a shared card or cash.
--  archived cards are refused on a purchase
--        a new purchase, or a change of card, may not name an archived card. Editing other fields of an old
--        row that already sits on an archived card is fine. The Desk reconciles closed cards through two
--        server functions that allow it (desk_add_expense, desk_set_card) — every use is in the activity log.
--
-- No balance can move (asserted): only card visibility, defaults and a guard.
begin;
create temp table _before as select fund_id, balance from public.fund_balances;

-- ── 1 · where a card is offered ─────────────────────────────────────────
alter table public.payment_methods
  add column if not exists show_daily boolean not null default true,
  add column if not exists show_trip  boolean not null default true,
  add column if not exists show_fund  boolean not null default true,
  add column if not exists archived_at timestamptz;
update public.payment_methods set show_daily = false where travel_only and show_daily;
update public.payment_methods set archived_at = now() where is_archived and archived_at is null;

-- travel_only <-> show_* stay in step; archived_at follows is_archived
create or replace function public.bh_card_flags()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.travel_only and new.show_daily then new.show_daily := false; end if;
  elsif new.show_daily is distinct from old.show_daily or new.show_trip is distinct from old.show_trip then
    new.travel_only := (not new.show_daily) and new.show_trip;
  elsif new.travel_only is distinct from old.travel_only then
    new.show_daily := not new.travel_only;
    if new.travel_only then new.show_trip := true; end if;
  end if;
  if new.is_archived and (tg_op = 'INSERT' or not old.is_archived) then new.archived_at := now(); end if;
  if not new.is_archived then new.archived_at := null; end if;
  return new;
end $$;
revoke execute on function public.bh_card_flags() from public, anon, authenticated;
drop trigger if exists b1_payment_methods_flags on public.payment_methods;
create trigger b1_payment_methods_flags before insert or update on public.payment_methods
  for each row execute function public.bh_card_flags();

-- ── 2 · default card per person per context ─────────────────────────────
create table if not exists public.card_defaults (
  id                uuid primary key default gen_random_uuid(),   -- the activity log keys rows by id
  household_id      uuid not null references public.households(id) on delete cascade,
  profile_id        uuid references public.profiles(id) on delete cascade,      -- null = shared (joint)
  context           text not null check (context in ('daily', 'trip', 'fund')),
  payment_method_id uuid not null references public.payment_methods(id) on delete cascade,
  created_at        timestamptz not null default now(),
  unique nulls not distinct (household_id, profile_id, context)
);
create index if not exists card_defaults_card on public.card_defaults (payment_method_id);
alter table public.card_defaults enable row level security;
create policy "hh: read"   on public.card_defaults for select using (household_id in (select bh_member_of()));
create policy "hh: insert" on public.card_defaults for insert with check (household_id in (select bh_writer_of()));
create policy "hh: update" on public.card_defaults for update using (household_id in (select bh_writer_of())) with check (household_id in (select bh_writer_of()));
create policy "hh: delete" on public.card_defaults for delete using (household_id in (select bh_writer_of()));
revoke all on public.card_defaults from public, anon;
grant select, insert, update, delete on public.card_defaults to authenticated;
grant all on public.card_defaults to service_role;

create or replace function public.bh_card_default_check()
returns trigger language plpgsql set search_path = public as $$
declare c payment_methods%rowtype; v_hh uuid;
begin
  select * into c from payment_methods where id = new.payment_method_id;
  if c.id is null or c.household_id <> new.household_id then raise exception 'card not found' using errcode = '42501'; end if;
  if new.profile_id is not null then
    select household_id into v_hh from profiles where id = new.profile_id;
    if v_hh is distinct from new.household_id then raise exception 'person not found' using errcode = '42501'; end if;
  end if;
  if c.is_archived then raise exception '% is archived — pick an active card', c.name using errcode = 'P0001'; end if;
  if (new.context = 'daily' and not c.show_daily) or (new.context = 'trip' and not c.show_trip) or (new.context = 'fund' and not c.show_fund) then
    raise exception '% isn''t offered for % expenses — switch it on in Settings → Payment cards first', c.name, new.context using errcode = 'P0001';
  end if;
  if c.profile_id is not null and c.kind <> 'cash' and c.profile_id is distinct from new.profile_id then
    raise exception '% belongs to someone else — a default must be that person''s own card, a shared card or cash', c.name using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke execute on function public.bh_card_default_check() from public, anon, authenticated;
drop trigger if exists card_defaults_check on public.card_defaults;
create trigger card_defaults_check before insert or update on public.card_defaults
  for each row execute function public.bh_card_default_check();
drop trigger if exists zzz_card_defaults_audit on public.card_defaults;
create trigger zzz_card_defaults_audit after insert or update or delete on public.card_defaults
  for each row execute function public.bh_audit();

-- a card that stops being offered somewhere, or is archived, drops out of the defaults that pointed at it
create or replace function public.bh_card_defaults_prune()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from card_defaults d where d.payment_method_id = new.id and (
       new.is_archived
    or (d.context = 'daily' and not new.show_daily)
    or (d.context = 'trip'  and not new.show_trip)
    or (d.context = 'fund'  and not new.show_fund));
  return null;
end $$;
revoke execute on function public.bh_card_defaults_prune() from public, anon, authenticated;
drop trigger if exists zy_payment_methods_prune_defaults on public.payment_methods;
create trigger zy_payment_methods_prune_defaults after update on public.payment_methods
  for each row execute function public.bh_card_defaults_prune();

-- ── 3 · archived cards are refused on a purchase ─────────────────────────
-- runs after expenses_before_write (which resolves the card from its name) and before the lock
create or replace function public.bh_expense_card_usable()
returns trigger language plpgsql set search_path = public as $$
declare v_name text; v_arch boolean;
begin
  if new.payment_method_id is null then return new; end if;
  if tg_op = 'UPDATE' and new.payment_method_id is not distinct from old.payment_method_id then return new; end if;
  select name, is_archived into v_name, v_arch from payment_methods where id = new.payment_method_id;
  if v_arch and coalesce(current_setting('bh.allow_archived', true), '') <> 'on' then
    raise exception '% is archived — pick another card (the Desk can still reconcile it)', v_name using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke execute on function public.bh_expense_card_usable() from public, anon, authenticated;
drop trigger if exists expenses_card_usable on public.expenses;
create trigger expenses_card_usable before insert or update on public.expenses
  for each row execute function public.bh_expense_card_usable();

-- the Desk adds a missing statement line, possibly on an archived card
create or replace function public.desk_add_expense(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_id uuid;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  perform set_config('bh.allow_archived', 'on', true);
  insert into expenses (household_id, trip_id, date, description, category, amount, currency, payer_profile_id,
                        payment_method_id, paid_with, comments, fund_id, is_refund, created_by)
  values (v_hh, nullif(p->>'trip_id', '')::uuid, (p->>'date')::date, p->>'description', p->>'category',
          round((p->>'amount')::numeric, 2), p->>'currency', nullif(p->>'payer_profile_id', '')::uuid,
          (p->>'payment_method_id')::uuid, coalesce(p->>'paid_with', ''), coalesce(p->>'comments', ''),
          nullif(p->>'fund_id', '')::uuid, coalesce((p->>'is_refund')::boolean, false), auth.uid())
  returning id into v_id;
  perform set_config('bh.allow_archived', 'off', true);
  return v_id;
end $$;
revoke execute on function public.desk_add_expense(jsonb) from public, anon;
grant execute on function public.desk_add_expense(jsonb) to authenticated, service_role;

-- the Desk moves rows onto a card (open rows only — the lock refuses reconciled ones), possibly archived
create or replace function public.desk_set_card(p_ids uuid[], p_card uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_n int;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  if not exists (select 1 from payment_methods where id = p_card and household_id = v_hh) then raise exception 'card not found'; end if;
  perform set_config('bh.allow_archived', 'on', true);
  update expenses set payment_method_id = p_card where household_id = v_hh and id = any(p_ids) and deleted_at is null;
  get diagnostics v_n = row_count;
  perform set_config('bh.allow_archived', 'off', true);
  return v_n;
end $$;
revoke execute on function public.desk_set_card(uuid[], uuid) from public, anon;
grant execute on function public.desk_set_card(uuid[], uuid) to authenticated, service_role;

-- ── proof ────────────────────────────────────────────────────────────────
do $$
declare v_bad int;
begin
  select count(*) into v_bad from _before b join public.fund_balances a using (fund_id) where abs(a.balance - b.balance) > 0.005;
  if v_bad > 0 then raise exception 'card rules: % fund balances changed', v_bad; end if;
  select count(*) into v_bad from public.payment_methods where travel_only and show_daily;
  if v_bad > 0 then raise exception 'card rules: % travel-only cards still offered for daily', v_bad; end if;
  raise notice 'card rules ok: balances unchanged';
end $$;
drop table _before;
notify pgrst, 'reload schema';
commit;
