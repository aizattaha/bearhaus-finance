-- QA-6 (Aug 2026 sprint 1.5): send foreign-currency trip lines to the travel fund
-- at a user-entered converted amount — flags + fund debit in ONE transaction.
create or replace function public.send_foreign_to_fund(
  p_trip uuid, p_fund uuid, p_date date, p_ids uuid[], p_amount numeric
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_hh uuid; v_cur text; v_name text; v_n integer;
begin
  select id into v_hh from households where owner_user_id = auth.uid();
  if v_hh is null then raise exception 'no household'; end if;
  select currency into v_cur from funds where id = p_fund and household_id = v_hh;
  if v_cur is null then raise exception 'fund not found'; end if;
  select name into v_name from trips where id = p_trip and household_id = v_hh;
  if v_name is null then raise exception 'trip not found'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'enter the converted amount'; end if;

  update travel_expenses set sent_to_fund = true
  where trip_id = p_trip and household_id = v_hh and not sent_to_fund
    and currency <> v_cur and id = any(p_ids);
  get diagnostics v_n = row_count;
  if v_n = 0 then raise exception 'nothing unsent to send'; end if;

  insert into fund_transactions (household_id, fund_id, type, date, amount, remarks, origin)
  values (v_hh, p_fund, 'expense', p_date, p_amount, 'Travel: ' || v_name || ' (converted)', 'manual');
end;
$$;
