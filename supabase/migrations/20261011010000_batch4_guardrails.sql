-- QA round 1 · batch 4 (11 Oct 2026) — guard rails. See docs/qa/2026-10-10-round-1.md (F26–F29).
--
--  F26  descriptions capped at 200 characters (the app caps the input too)
--  F28  edits are optimistic: save_expense can be told which version the editor saw and refuses
--       to overwrite a newer one ("changed elsewhere — reload")
--  F29  a fund keeps its icon when renamed (stored on the fund; the app derives one from the
--       name only while none is stored)

begin;

-- ── F26 · description length ─────────────────────────────────────────────
update public.daily_expenses  set description = left(description, 200) where length(description) > 200;
update public.travel_expenses set description = left(description, 200) where length(description) > 200;
alter table public.daily_expenses  drop constraint if exists daily_expenses_description_len;
alter table public.travel_expenses drop constraint if exists travel_expenses_description_len;
alter table public.daily_expenses  add constraint daily_expenses_description_len  check (length(description) <= 200);
alter table public.travel_expenses add constraint travel_expenses_description_len check (length(description) <= 200);

-- ── F28 · updated_at on expenses + a version check in save_expense ───────
alter table public.daily_expenses  add column if not exists updated_at timestamptz not null default now();
alter table public.travel_expenses add column if not exists updated_at timestamptz not null default now();
create or replace function public.bh_touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists daily_expenses_touch on public.daily_expenses;
drop trigger if exists travel_expenses_touch on public.travel_expenses;
-- "zz_" so it runs last among the BEFORE UPDATE triggers (they fire in name order)
create trigger zz_daily_expenses_touch  before update on public.daily_expenses  for each row execute function public.bh_touch_updated_at();
create trigger zz_travel_expenses_touch before update on public.travel_expenses for each row execute function public.bh_touch_updated_at();

drop function if exists public.save_expense(text, uuid, date, text, text, numeric, text, uuid, text, text);
create or replace function public.save_expense(
  p_kind text, p_id uuid, p_date date, p_description text, p_category text,
  p_amount numeric, p_currency text, p_payer uuid, p_paid_with text, p_comments text,
  p_seen_updated_at timestamptz default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_hh uuid; v_now timestamptz;
begin
  select id into v_hh from households where owner_user_id = auth.uid();
  if v_hh is null then raise exception 'no household'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount must be positive'; end if;
  if p_payer is not null and not exists
     (select 1 from profiles where id = p_payer and household_id = v_hh) then
    raise exception 'payer not found';
  end if;

  if p_kind = 'daily' then
    select updated_at into v_now from daily_expenses where id = p_id and household_id = v_hh;
    if v_now is null then raise exception 'expense not found'; end if;
    if p_seen_updated_at is not null and v_now > p_seen_updated_at + interval '1 second' then
      raise exception 'this expense was changed elsewhere after you opened it — close and reopen it to see the latest' using errcode = 'P0001';
    end if;
    update daily_expenses
       set date = p_date, description = p_description, category = p_category,
           amount = p_amount, currency = p_currency, payer_profile_id = p_payer,
           paid_with = p_paid_with, comments = p_comments
     where id = p_id and household_id = v_hh;
    delete from daily_expense_splits where expense_id = p_id;
    if p_payer is not null then
      insert into daily_expense_splits (household_id, expense_id, profile_id, amount)
      values (v_hh, p_id, p_payer, p_amount);
    end if;
    insert into daily_expense_splits (household_id, expense_id, profile_id, amount)
    values (v_hh, p_id, null, -p_amount);
  elsif p_kind = 'travel' then
    select updated_at into v_now from travel_expenses where id = p_id and household_id = v_hh;
    if v_now is null then raise exception 'expense not found'; end if;
    if p_seen_updated_at is not null and v_now > p_seen_updated_at + interval '1 second' then
      raise exception 'this expense was changed elsewhere after you opened it — close and reopen it to see the latest' using errcode = 'P0001';
    end if;
    update travel_expenses
       set date = p_date, description = p_description, category = p_category,
           amount = p_amount, currency = p_currency, payer_profile_id = p_payer,
           paid_with = p_paid_with, comments = p_comments
     where id = p_id and household_id = v_hh;
    delete from travel_expense_splits where expense_id = p_id;
    if p_payer is not null then
      insert into travel_expense_splits (household_id, expense_id, profile_id, amount)
      values (v_hh, p_id, p_payer, p_amount);
    end if;
    insert into travel_expense_splits (household_id, expense_id, profile_id, amount)
    values (v_hh, p_id, null, -p_amount);
  else
    raise exception 'unknown kind %', p_kind;
  end if;
end;
$$;
revoke all on function public.save_expense(text, uuid, date, text, text, numeric, text, uuid, text, text, timestamptz) from public;
grant execute on function public.save_expense(text, uuid, date, text, text, numeric, text, uuid, text, text, timestamptz) to authenticated, service_role;

-- ── F29 · a fund's icon survives a rename ────────────────────────────────
alter table public.funds add column if not exists icon text;

commit;
