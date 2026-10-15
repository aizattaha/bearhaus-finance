-- Ids, not names (v2 sprint 3, chunk 5; E1-F12).
--
--  1 · save_expense takes the category and the card by id (p_category_id, p_payment_method_id). The name
--      arguments stay for one sprint so a phone still running last week's app keeps working.
--  2 · Changing a purchase's card by name moved only the name: the row kept the old card's id, so it stayed on
--      the old card's statement and in its owed. An edit that changes the name now moves the card too (and is
--      refused if no card has that name, rather than dropping the card). Rows already affected are counted
--      below — fixing them moves card numbers, so that is a data fix, not this migration.
--  3 · desk_add_expense takes category_id too.
--
-- No balance moves (asserted).
begin;
create temp table _b_fund as select fund_id, balance from public.fund_balances;
create temp table _b_card as select payment_method_id, owed from public.card_balances;

-- ── 2 · the name moves the card ─────────────────────────────────────────
create or replace function public.bh_expense_before_write()
returns trigger language plpgsql set search_path = public as $$
declare v_kind text; v_owner uuid;
begin
  -- keep the id in step with the name (older app builds only send the name)
  if new.payment_method_id is null and coalesce(new.paid_with, '') <> '' then
    select id into new.payment_method_id from payment_methods
     where household_id = new.household_id and name = new.paid_with limit 1;
  elsif tg_op = 'UPDATE' and new.paid_with is distinct from old.paid_with
        and new.payment_method_id is not distinct from old.payment_method_id then
    -- a new name with the same id: the card was changed by name — move the id with it
    if coalesce(new.paid_with, '') = '' then
      new.payment_method_id := null;
    else
      new.payment_method_id := (select id from payment_methods where household_id = new.household_id and name = new.paid_with limit 1);
      if new.payment_method_id is null then
        raise exception 'no card called “%” — reload the app and pick the card again', new.paid_with using errcode = 'P0001';
      end if;
    end if;
  end if;
  if new.payment_method_id is not null and (tg_op = 'INSERT' or new.payment_method_id is distinct from old.payment_method_id) then
    select name into new.paid_with from payment_methods where id = new.payment_method_id;
  end if;
  if new.paid_with is null then new.paid_with := ''; end if;   -- the column is not null; '' means no card
  select kind, profile_id into v_kind, v_owner from payment_methods where id = new.payment_method_id;
  -- a personal card names its owner as the payer: always when a row is moved onto the card,
  -- and when a new row arrives with nobody named (Aizat, 11 Oct 2026)
  if v_owner is not null and (
       (tg_op = 'UPDATE' and new.payment_method_id is distinct from old.payment_method_id)
    or (tg_op = 'INSERT' and new.payer_profile_id is null)) then
    new.payer_profile_id := v_owner;
  end if;
  -- cash ticks itself when the row is created or switched TO cash; moving off cash clears the automatic tick
  if v_kind = 'cash' and new.reconciled_at is null
     and (tg_op = 'INSERT' or new.payment_method_id is distinct from old.payment_method_id) then
    new.reconciled_at := now(); new.reconciled_by := 'auto'; new.reconciled_statement_id := null;
  elsif tg_op = 'UPDATE' and v_kind is distinct from 'cash' and old.reconciled_by = 'auto' and new.reconciled_by = 'auto'
        and new.payment_method_id is distinct from old.payment_method_id then
    new.reconciled_at := null; new.reconciled_by := null; new.reconciled_statement_id := null;
  end if;
  return new;
end $$;

-- ── 1 · save_expense by id ──────────────────────────────────────────────
drop function if exists public.save_expense(text, uuid, date, text, text, numeric, text, uuid, text, text, timestamptz, boolean, boolean, uuid);
create or replace function public.save_expense(p_kind text, p_id uuid, p_date date, p_description text, p_category text, p_amount numeric,
  p_currency text, p_payer uuid, p_paid_with text, p_comments text, p_seen_updated_at timestamptz default null,
  p_is_refund boolean default null, p_set_fund boolean default false, p_fund_id uuid default null,
  p_category_id uuid default null, p_payment_method_id uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_now timestamptz;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'amount must be positive'; end if;
  if p_payer is not null and not exists (select 1 from profiles where id = p_payer and household_id = v_hh) then
    raise exception 'payer not found';
  end if;
  if p_category_id is not null and not exists (select 1 from categories where id = p_category_id and household_id = v_hh) then
    raise exception 'category not found';
  end if;
  if p_payment_method_id is not null and not exists (select 1 from payment_methods where id = p_payment_method_id and household_id = v_hh) then
    raise exception 'card not found';
  end if;
  if p_kind not in ('daily', 'travel', 'expense') then raise exception 'unknown kind %', p_kind; end if;
  select updated_at into v_now from expenses where id = p_id and household_id = v_hh and deleted_at is null;
  if v_now is null then raise exception 'expense not found'; end if;
  if p_seen_updated_at is not null and v_now > p_seen_updated_at + interval '1 second' then
    raise exception 'this expense was changed elsewhere after you opened it — close and reopen it to see the latest' using errcode = 'P0001';
  end if;
  update expenses
     set date = p_date, description = p_description,
         category_id = coalesce(p_category_id, category_id),
         category = case when p_category_id is null then p_category else category end,   -- by id: the trigger copies the name
         amount = p_amount, currency = p_currency, payer_profile_id = p_payer,
         payment_method_id = coalesce(p_payment_method_id, payment_method_id),
         paid_with = case when p_payment_method_id is null then coalesce(p_paid_with, '') else paid_with end,
         comments = p_comments,
         is_refund = coalesce(p_is_refund, is_refund),
         fund_id = case when p_set_fund then p_fund_id else fund_id end
   where id = p_id and household_id = v_hh;
end $$;
revoke execute on function public.save_expense(text, uuid, date, text, text, numeric, text, uuid, text, text, timestamptz, boolean, boolean, uuid, uuid, uuid) from public, anon;
grant execute on function public.save_expense(text, uuid, date, text, text, numeric, text, uuid, text, text, timestamptz, boolean, boolean, uuid, uuid, uuid) to authenticated, service_role;

-- ── 3 · the Desk adds by id too ─────────────────────────────────────────
create or replace function public.desk_add_expense(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_id uuid;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  perform set_config('bh.allow_archived', 'on', true);
  insert into expenses (household_id, trip_id, date, description, category, category_id, amount, currency, payer_profile_id,
                        payment_method_id, paid_with, comments, fund_id, is_refund, created_by)
  values (v_hh, nullif(p->>'trip_id', '')::uuid, (p->>'date')::date, p->>'description',
          case when nullif(p->>'category_id', '') is null then p->>'category' end, nullif(p->>'category_id', '')::uuid,
          round((p->>'amount')::numeric, 2), p->>'currency', nullif(p->>'payer_profile_id', '')::uuid,
          (p->>'payment_method_id')::uuid, coalesce(p->>'paid_with', ''), coalesce(p->>'comments', ''),
          nullif(p->>'fund_id', '')::uuid, coalesce((p->>'is_refund')::boolean, false), auth.uid())
  returning id into v_id;
  perform set_config('bh.allow_archived', 'off', true);
  return v_id;
end $$;
revoke execute on function public.desk_add_expense(jsonb) from public, anon;
grant execute on function public.desk_add_expense(jsonb) to authenticated, service_role;

-- ── proof ────────────────────────────────────────────────────────────────
do $$
declare v_bad int; v_mismatch int;
begin
  select count(*) into v_bad from _b_fund b full join public.fund_balances a using (fund_id) where a.balance is distinct from b.balance;
  if v_bad > 0 then raise exception 'ids: % fund balances changed', v_bad; end if;
  select count(*) into v_bad from _b_card b full join public.card_balances a using (payment_method_id) where a.owed is distinct from b.owed;
  if v_bad > 0 then raise exception 'ids: % card balances changed', v_bad; end if;
  -- purchases whose card name and card id disagree (the bug in 2): counted, not changed
  select count(*) into v_mismatch from public.expenses e left join public.payment_methods pm on pm.id = e.payment_method_id
   where e.deleted_at is null and coalesce(pm.name, '') <> coalesce(e.paid_with, '');
  raise notice 'ids ok: balances unchanged; % purchases name a different card than they sit on', v_mismatch;
end $$;
drop table _b_fund; drop table _b_card;
notify pgrst, 'reload schema';
commit;
