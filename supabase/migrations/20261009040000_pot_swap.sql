-- Pot swap (Aizat, 9 Oct 2026) — "paid with Singapore money for an Australian pot".
--
-- The flow: something that belongs to an AU fund (a trip item, a business payment) is bought
-- on an SG card because the SGD price is better. The app then:
--   1. converts the SGD amount to AUD at the day's mid-market rate (fetched once, stored on the
--      swap, editable);
--   2. moves that AUD from the fund that covers it (Travel Fund AU, Investment Fund AU (Aizat),
--      Monthly Expenses (Paige)…) to BearHaus Rainy Day AU — the AUD stays in Australia;
--   3. moves the SGD from Future DreamHouse SG to the person's SG bank pot (Float SG (Aizat) /
--      Float SG (Paige)) — the money that will pay the SG card when the statement comes.
-- Money only moves between pots within a country; nothing crosses the border.
--
-- One swap = one row in pot_swaps + two transfer pairs in fund_transactions (same remark
-- convention as manual transfers, so the app shows them as ⇄ rows and they reconcile
-- automatically). A travel row is also flagged sent_to_fund so "Send to Travel Fund" and
-- settle-up skip it, and gets a matching spend row on the bank pot (daily rows count the bank
-- pot down through their category already, so they don't).

begin;

create table if not exists public.pot_swaps (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  expense_kind text not null check (expense_kind in ('daily', 'travel')),
  expense_id uuid not null,
  date date not null,
  src_amount numeric(12,2) not null,
  src_currency text not null,
  rate numeric(12,6) not null check (rate > 0),          -- dst per 1 src (AUD per 1 SGD)
  dst_amount numeric(12,2) not null,
  dst_currency text not null,
  cover_fund_id uuid not null references public.funds(id),      -- AU fund the item really belongs to
  land_fund_id uuid not null references public.funds(id),       -- AU fund the AUD lands in (Rainy Day)
  bank_from_fund_id uuid not null references public.funds(id),  -- SG fund the SGD comes from (DreamHouse)
  bank_to_fund_id uuid not null references public.funds(id),    -- SG bank pot that will pay the card
  dst_group_id uuid not null,   -- transfer_group_id of the AU pair
  src_group_id uuid not null,   -- transfer_group_id of the SG pair
  spend_tx_id uuid,             -- travel only: the spend row on the bank pot
  marked_sent boolean not null default false,
  rate_source text,
  note text,
  created_at timestamptz not null default now(),
  unique (expense_kind, expense_id)
);
alter table public.pot_swaps enable row level security;
drop policy if exists pot_swaps_own on public.pot_swaps;
create policy pot_swaps_own on public.pot_swaps for all
  using (household_id in (select id from public.households where owner_user_id = auth.uid()))
  with check (household_id in (select id from public.households where owner_user_id = auth.uid()));
grant all on table public.pot_swaps to authenticated, service_role;

alter table public.daily_expenses  add column if not exists pot_swap_id uuid references public.pot_swaps(id) on delete set null;
alter table public.travel_expenses add column if not exists pot_swap_id uuid references public.pot_swaps(id) on delete set null;
create index if not exists daily_expenses_pot_swap  on public.daily_expenses (pot_swap_id) where pot_swap_id is not null;
create index if not exists travel_expenses_pot_swap on public.travel_expenses (pot_swap_id) where pot_swap_id is not null;

-- ── record ───────────────────────────────────────────────────────────────
create or replace function public.record_pot_swap(
  p_kind text, p_expense uuid, p_rate numeric,
  p_cover uuid, p_land uuid, p_bank_from uuid, p_bank_to uuid,
  p_rate_source text default null, p_note text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_hh uuid; v_date date; v_desc text; v_amt numeric; v_cur text;
  v_cover funds%rowtype; v_land funds%rowtype; v_from funds%rowtype; v_to funds%rowtype;
  v_dst numeric; v_tag text; v_swap uuid := gen_random_uuid();
  v_g_dst uuid := gen_random_uuid(); v_g_src uuid := gen_random_uuid();
  v_spend uuid; v_marked boolean := false; v_n integer;
begin
  select id into v_hh from households where owner_user_id = auth.uid();
  if v_hh is null then raise exception 'no household'; end if;
  if p_kind not in ('daily', 'travel') then raise exception 'kind must be daily or travel'; end if;
  if p_rate is null or p_rate <= 0 then raise exception 'enter the exchange rate'; end if;

  if p_kind = 'daily' then
    select date, description, amount, currency into v_date, v_desc, v_amt, v_cur
      from daily_expenses where id = p_expense and household_id = v_hh and pot_swap_id is null;
  else
    select date, description, amount, currency into v_date, v_desc, v_amt, v_cur
      from travel_expenses where id = p_expense and household_id = v_hh and pot_swap_id is null;
  end if;
  if v_date is null then raise exception 'expense not found (or already swapped)'; end if;

  select * into v_cover from funds where id = p_cover     and household_id = v_hh and is_active;
  select * into v_land  from funds where id = p_land      and household_id = v_hh and is_active;
  select * into v_from  from funds where id = p_bank_from and household_id = v_hh and is_active;
  select * into v_to    from funds where id = p_bank_to   and household_id = v_hh and is_active;
  if v_cover.id is null or v_land.id is null or v_from.id is null or v_to.id is null then raise exception 'fund not found'; end if;
  if v_cover.currency <> v_land.currency then raise exception 'the two % funds must share a currency', 'landing'; end if;
  if v_from.currency <> v_to.currency then raise exception 'the two bank-side funds must share a currency'; end if;
  if v_from.currency <> v_cur then raise exception 'the bank-side funds must be in the purchase currency (%)', v_cur; end if;
  if v_cover.id = v_land.id or v_from.id = v_to.id then raise exception 'pick two different funds on each side'; end if;

  v_dst := round(v_amt * p_rate, 2);
  v_tag := 'Pot swap · ' || v_desc || ' · ' || v_cur || ' ' || to_char(v_amt, 'FM999999990.00') || ' @ ' || to_char(p_rate, 'FM990.0000');

  -- AU side: cover fund → landing fund, in the landing currency
  insert into fund_transactions (household_id, fund_id, type, date, amount, remarks, origin, transfer_group_id)
  values (v_hh, v_cover.id, 'expense', v_date, v_dst, 'Transfer → ' || v_land.name  || ' · ' || v_tag, 'manual', v_g_dst),
         (v_hh, v_land.id,  'income',  v_date, v_dst, 'Transfer ← ' || v_cover.name || ' · ' || v_tag, 'manual', v_g_dst);
  -- SG side: DreamHouse → bank pot, in the purchase currency
  insert into fund_transactions (household_id, fund_id, type, date, amount, remarks, origin, transfer_group_id)
  values (v_hh, v_from.id, 'expense', v_date, v_amt, 'Transfer → ' || v_to.name   || ' · ' || v_tag, 'manual', v_g_src),
         (v_hh, v_to.id,   'income',  v_date, v_amt, 'Transfer ← ' || v_from.name || ' · ' || v_tag, 'manual', v_g_src);

  if p_kind = 'travel' then
    -- the trip line is covered by the swap: Send-to-fund and settle-up must skip it
    update travel_expenses set sent_to_fund = true where id = p_expense and not sent_to_fund;
    get diagnostics v_n = row_count;  -- 1 row → we set it (and undo clears it)
    v_marked := v_n > 0;
    -- and the bank pot pays the card: a spend row (daily rows do this through their category)
    insert into fund_transactions (household_id, fund_id, type, date, amount, remarks, origin, reconciled_at, reconciled_by)
    values (v_hh, v_to.id, 'expense', v_date, v_amt, v_tag || ' · paid from bank pot', 'manual', now(), 'auto')
    returning id into v_spend;
  end if;

  insert into pot_swaps (id, household_id, expense_kind, expense_id, date, src_amount, src_currency, rate, dst_amount, dst_currency,
                         cover_fund_id, land_fund_id, bank_from_fund_id, bank_to_fund_id, dst_group_id, src_group_id, spend_tx_id, marked_sent, rate_source, note)
  values (v_swap, v_hh, p_kind, p_expense, v_date, v_amt, v_cur, p_rate, v_dst, v_land.currency,
          v_cover.id, v_land.id, v_from.id, v_to.id, v_g_dst, v_g_src, v_spend, v_marked, p_rate_source, p_note);

  if p_kind = 'daily' then update daily_expenses set pot_swap_id = v_swap where id = p_expense;
  else update travel_expenses set pot_swap_id = v_swap where id = p_expense; end if;
  return v_swap;
end;
$$;

-- ── change the rate later (the AUD pair follows) ─────────────────────────
create or replace function public.update_pot_swap_rate(p_swap uuid, p_rate numeric, p_rate_source text default 'manual')
returns numeric
language plpgsql security definer set search_path = public as $$
declare
  v_hh uuid; s pot_swaps%rowtype; v_dst numeric; v_tag_old text; v_tag_new text;
begin
  select id into v_hh from households where owner_user_id = auth.uid();
  if v_hh is null then raise exception 'no household'; end if;
  if p_rate is null or p_rate <= 0 then raise exception 'enter the exchange rate'; end if;
  select * into s from pot_swaps where id = p_swap and household_id = v_hh;
  if s.id is null then raise exception 'swap not found'; end if;
  v_dst := round(s.src_amount * p_rate, 2);
  v_tag_old := ' @ ' || to_char(s.rate, 'FM990.0000');
  v_tag_new := ' @ ' || to_char(p_rate, 'FM990.0000');
  update fund_transactions set amount = v_dst, remarks = replace(remarks, v_tag_old, v_tag_new)
   where transfer_group_id = s.dst_group_id and household_id = v_hh;
  update fund_transactions set remarks = replace(remarks, v_tag_old, v_tag_new)
   where household_id = v_hh and (transfer_group_id = s.src_group_id or id = s.spend_tx_id);
  update pot_swaps set rate = p_rate, dst_amount = v_dst, rate_source = p_rate_source where id = s.id;
  return v_dst;
end;
$$;

-- ── undo ─────────────────────────────────────────────────────────────────
create or replace function public.delete_pot_swap(p_swap uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_hh uuid; s pot_swaps%rowtype;
begin
  select id into v_hh from households where owner_user_id = auth.uid();
  if v_hh is null then raise exception 'no household'; end if;
  select * into s from pot_swaps where id = p_swap and household_id = v_hh;
  if s.id is null then raise exception 'swap not found'; end if;
  if exists (select 1 from fund_transactions where household_id = v_hh and reconciled_by = 'manual'
              and (transfer_group_id in (s.dst_group_id, s.src_group_id) or id = s.spend_tx_id)) then
    raise exception 'locked: a row of this swap was reconciled against a statement — un-reconcile it first' using errcode = 'P0001';
  end if;
  delete from fund_transactions where household_id = v_hh
     and (transfer_group_id in (s.dst_group_id, s.src_group_id) or id = s.spend_tx_id);
  if s.expense_kind = 'daily' then update daily_expenses set pot_swap_id = null where id = s.expense_id;
  else
    update travel_expenses set pot_swap_id = null, sent_to_fund = case when s.marked_sent then false else sent_to_fund end
     where id = s.expense_id;
  end if;
  delete from pot_swaps where id = s.id;
end;
$$;

revoke all on function public.record_pot_swap(text, uuid, numeric, uuid, uuid, uuid, uuid, text, text) from public;
revoke all on function public.update_pot_swap_rate(uuid, numeric, text) from public;
revoke all on function public.delete_pot_swap(uuid) from public;
grant execute on function public.record_pot_swap(text, uuid, numeric, uuid, uuid, uuid, uuid, text, text) to authenticated, service_role;
grant execute on function public.update_pot_swap_rate(uuid, numeric, text) to authenticated, service_role;
grant execute on function public.delete_pot_swap(uuid) to authenticated, service_role;

commit;
