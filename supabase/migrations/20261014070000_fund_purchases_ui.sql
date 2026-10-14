-- Ledger plan, phase 2 (14 Oct 2026): the apps speak the new language.
-- save_expense learns the fund a purchase counts against (p_set_fund true → fund_id := p_fund_id, null clears).

begin;

drop function if exists public.save_expense(text, uuid, date, text, text, numeric, text, uuid, text, text, timestamptz, boolean);
create or replace function public.save_expense(
  p_kind text, p_id uuid, p_date date, p_description text, p_category text,
  p_amount numeric, p_currency text, p_payer uuid, p_paid_with text, p_comments text,
  p_seen_updated_at timestamptz default null, p_is_refund boolean default null,
  p_set_fund boolean default false, p_fund_id uuid default null
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
         is_refund = coalesce(p_is_refund, is_refund),
         fund_id = case when p_set_fund then p_fund_id else fund_id end
   where id = p_id and household_id = v_hh;
end;
$$;
revoke all on function public.save_expense(text, uuid, date, text, text, numeric, text, uuid, text, text, timestamptz, boolean, boolean, uuid) from public;
grant execute on function public.save_expense(text, uuid, date, text, text, numeric, text, uuid, text, text, timestamptz, boolean, boolean, uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
commit;
