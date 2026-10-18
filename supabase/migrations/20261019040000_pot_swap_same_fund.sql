-- Pot swap: a country where nothing needs to move (Aizat, 18 Oct 2026).
--
-- A swap had to name two different funds in each country: the fund the purchase belongs to → where its money waits
-- (Travel Fund AU → Rainy Day AU), and where the purchase currency's money comes from → the bank pot that pays the
-- card (Future DreamHouse SG → Float SG). With no bank-account pots yet, the SG money comes from the same pot that
-- pays, so Aizat had to pick a second fund just to get past the check.
--
-- Aizat's pick (18 Oct): the same fund in both boxes of a country = nothing moves in that country; the swap skips
-- that country's transfer pair (pot_swaps.dst_group_id / src_group_id stay empty). At least one country must still
-- move money — a swap that moves nothing is refused. A trip line's spend row on the bank pot is unchanged.
-- Undo and a new rate handle a missing pair.
--
-- Money invariant (CLAUDE.md rule 5), new: record, re-rate and undo each compare every fund of the household before
-- and after — Available and In the bank — with what the swap says it does (bh_pot_swap_effect), and refuse otherwise.
-- No existing row changes: this only widens what a new swap may name.

begin;

alter table public.pot_swaps alter column dst_group_id drop not null;
alter table public.pot_swaps alter column src_group_id drop not null;

-- ── what a swap does to each fund, as of the household's today ─────────
-- {fund_id: [Available, In the bank]}; a swap dated after today moves nothing yet (as fund_money counts it).
-- Transfers move both numbers; a trip line's bank-pot spend row on a credit card (from the start date) is owed on
-- the card, not cash yet. Read from the swap row and its spend row, so call it while they exist.
create or replace function public.bh_pot_swap_effect(p_swap uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s pot_swaps%rowtype; v_pm uuid; v_owes boolean; v_out jsonb := '{}'::jsonb; v_start date;
begin
  select * into s from pot_swaps where id = p_swap;
  if s.id is null or s.date > bh_today(s.household_id) then return v_out; end if;
  select pot_start into v_start from households where id = s.household_id;
  if s.dst_group_id is not null then
    v_out := jsonb_set(v_out, array[s.cover_fund_id::text], jsonb_build_array(-s.dst_amount, -s.dst_amount));
    v_out := jsonb_set(v_out, array[s.land_fund_id::text],  jsonb_build_array( s.dst_amount,  s.dst_amount));
  end if;
  if s.src_group_id is not null then
    v_out := jsonb_set(v_out, array[s.bank_from_fund_id::text], jsonb_build_array(-s.src_amount, -s.src_amount));
    v_out := jsonb_set(v_out, array[s.bank_to_fund_id::text],   jsonb_build_array( s.src_amount,  s.src_amount));
  end if;
  if s.spend_tx_id is not null then
    select account_payment_method_id into v_pm from fund_transactions where id = s.spend_tx_id;
    v_owes := v_pm is not null and bh_is_credit_card(v_pm) and (v_start is null or s.date >= v_start);
    v_out := jsonb_set(v_out, array[s.bank_to_fund_id::text], jsonb_build_array(
      coalesce((v_out -> s.bank_to_fund_id::text ->> 0)::numeric, 0) - s.src_amount,
      coalesce((v_out -> s.bank_to_fund_id::text ->> 1)::numeric, 0) - case when v_owes then 0 else s.src_amount end));
  end if;
  return v_out;
end;
$$;

-- every fund's [Available, In the bank] now
create or replace function public.bh_pot_swap_snapshot(p_hh uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(fund_id::text, jsonb_build_array(balance, cash_balance)), '{}'::jsonb)
    from fund_money where household_id = p_hh;
$$;

-- after − before must equal plus − minus for every fund; anything else refuses (counts only — CI logs are public)
create or replace function public.bh_pot_swap_check(p_hh uuid, p_before jsonb, p_plus jsonb, p_minus jsonb, p_what text)
returns void
language plpgsql stable security definer set search_path = public as $$
declare v_bad int;
begin
  with a as (select fund_id::text as k, balance, cash_balance from fund_money where household_id = p_hh)
  select count(*) into v_bad from a
   where abs(a.balance - coalesce((p_before -> a.k ->> 0)::numeric, 0)
             - coalesce((p_plus -> a.k ->> 0)::numeric, 0) + coalesce((p_minus -> a.k ->> 0)::numeric, 0)) > 0.005
      or abs(a.cash_balance - coalesce((p_before -> a.k ->> 1)::numeric, 0)
             - coalesce((p_plus -> a.k ->> 1)::numeric, 0) + coalesce((p_minus -> a.k ->> 1)::numeric, 0)) > 0.005;
  if v_bad > 0 then
    raise exception 'pot swap (%): % fund(s) would move by more or less than the swap says — nothing saved', p_what, v_bad using errcode = 'P0001';
  end if;
end;
$$;

-- ── record ───────────────────────────────────────────────────────────────
create or replace function public.record_pot_swap(p_kind text, p_expense uuid, p_rate numeric, p_cover uuid, p_land uuid, p_bank_from uuid, p_bank_to uuid, p_rate_source text DEFAULT NULL::text, p_note text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_hh uuid; v_date date; v_desc text; v_amt numeric; v_cur text; v_pm uuid;
  v_cover funds%rowtype; v_land funds%rowtype; v_from funds%rowtype; v_to funds%rowtype;
  v_dst numeric; v_tag text; v_swap uuid := gen_random_uuid();
  v_g_dst uuid; v_g_src uuid;
  v_spend uuid; v_marked boolean := false; v_n integer; v_before jsonb;
begin
  select id into v_hh from households where owner_user_id = auth.uid();
  if v_hh is null then raise exception 'no household'; end if;
  if p_kind not in ('daily', 'travel') then raise exception 'kind must be daily or travel'; end if;
  if p_rate is null or p_rate <= 0 then raise exception 'enter the exchange rate'; end if;

  select date, description, amount, currency, case when trip_id is null then 'daily' else 'travel' end, payment_method_id
    into v_date, v_desc, v_amt, v_cur, p_kind, v_pm
    from expenses where id = p_expense and household_id = v_hh and pot_swap_id is null and deleted_at is null;
  if v_date is null then raise exception 'expense not found (or already swapped)'; end if;

  select * into v_cover from funds where id = p_cover     and household_id = v_hh and is_active;
  select * into v_land  from funds where id = p_land      and household_id = v_hh and is_active;
  select * into v_from  from funds where id = p_bank_from and household_id = v_hh and is_active;
  select * into v_to    from funds where id = p_bank_to   and household_id = v_hh and is_active;
  if v_cover.id is null or v_land.id is null or v_from.id is null or v_to.id is null then raise exception 'fund not found'; end if;
  if v_cover.currency <> v_land.currency then raise exception 'the two % funds must share a currency', 'landing'; end if;
  if v_from.currency <> v_to.currency then raise exception 'the two bank-side funds must share a currency'; end if;
  if v_from.currency <> v_cur then raise exception 'the bank-side funds must be in the purchase currency (%)', v_cur; end if;
  -- the same fund twice in a country = nothing moves there (18 Oct); one country at least must move
  if v_cover.id = v_land.id and v_from.id = v_to.id then
    raise exception 'nothing would move — pick two different funds in at least one country' using errcode = 'P0001';
  end if;
  if v_cover.id <> v_land.id then v_g_dst := gen_random_uuid(); end if;
  if v_from.id <> v_to.id then v_g_src := gen_random_uuid(); end if;

  v_before := bh_pot_swap_snapshot(v_hh);
  v_dst := round(v_amt * p_rate, 2);
  v_tag := 'Pot swap · ' || v_desc || ' · ' || v_cur || ' ' || to_char(v_amt, 'FM999999990.00') || ' @ ' || to_char(p_rate, 'FM990.0000');

  if v_g_dst is not null then
    insert into fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin, transfer_group_id)
    values (v_hh, v_cover.id, 'expense', 'allocation', v_date, v_dst, 'Transfer → ' || v_land.name  || ' · ' || v_tag, 'manual', v_g_dst),
           (v_hh, v_land.id,  'income',  'allocation', v_date, v_dst, 'Transfer ← ' || v_cover.name || ' · ' || v_tag, 'manual', v_g_dst);
  end if;
  if v_g_src is not null then
    insert into fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin, transfer_group_id)
    values (v_hh, v_from.id, 'expense', 'allocation', v_date, v_amt, 'Transfer → ' || v_to.name   || ' · ' || v_tag, 'manual', v_g_src),
           (v_hh, v_to.id,   'income',  'allocation', v_date, v_amt, 'Transfer ← ' || v_from.name || ' · ' || v_tag, 'manual', v_g_src);
  end if;

  if p_kind = 'travel' then
    update expenses set sent_to_fund = true where id = p_expense and not sent_to_fund;
    get diagnostics v_n = row_count;
    v_marked := v_n > 0;
    -- the bank pot pays for the trip line: a spend row. If the line was on a credit card the row
    -- carries that card, so the pot's cash only moves when the card is paid.
    insert into fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin, reconciled_at, reconciled_by, account_payment_method_id)
    values (v_hh, v_to.id, 'expense', 'movement', v_date, v_amt, v_tag || ' · paid from bank pot', 'manual', now(), 'auto',
            case when bh_is_credit_card(v_pm) then v_pm end)
    returning id into v_spend;
  end if;

  insert into pot_swaps (id, household_id, expense_kind, expense_id, date, src_amount, src_currency, rate, dst_amount, dst_currency,
                         cover_fund_id, land_fund_id, bank_from_fund_id, bank_to_fund_id, dst_group_id, src_group_id, spend_tx_id, marked_sent, rate_source, note)
  values (v_swap, v_hh, p_kind, p_expense, v_date, v_amt, v_cur, p_rate, v_dst, v_land.currency,
          v_cover.id, v_land.id, v_from.id, v_to.id, v_g_dst, v_g_src, v_spend, v_marked, p_rate_source, p_note);

  update expenses set pot_swap_id = v_swap where id = p_expense;
  perform bh_pot_swap_check(v_hh, v_before, bh_pot_swap_effect(v_swap), '{}'::jsonb, 'record');
  return v_swap;
end;
$function$;

-- ── change the rate later (the pair in the other country follows; nothing to follow when it moved nothing) ──
create or replace function public.update_pot_swap_rate(p_swap uuid, p_rate numeric, p_rate_source text default 'manual')
returns numeric
language plpgsql security definer set search_path = public as $$
declare
  v_hh uuid; s pot_swaps%rowtype; v_dst numeric; v_tag_old text; v_tag_new text; v_before jsonb; v_old jsonb;
begin
  select id into v_hh from households where owner_user_id = auth.uid();
  if v_hh is null then raise exception 'no household'; end if;
  if p_rate is null or p_rate <= 0 then raise exception 'enter the exchange rate'; end if;
  select * into s from pot_swaps where id = p_swap and household_id = v_hh;
  if s.id is null then raise exception 'swap not found'; end if;
  v_before := bh_pot_swap_snapshot(v_hh); v_old := bh_pot_swap_effect(s.id);
  v_dst := round(s.src_amount * p_rate, 2);
  v_tag_old := ' @ ' || to_char(s.rate, 'FM990.0000');
  v_tag_new := ' @ ' || to_char(p_rate, 'FM990.0000');
  if s.dst_group_id is not null then
    update fund_transactions set amount = v_dst, remarks = replace(remarks, v_tag_old, v_tag_new)
     where transfer_group_id = s.dst_group_id and household_id = v_hh;
  end if;
  update fund_transactions set remarks = replace(remarks, v_tag_old, v_tag_new)
   where household_id = v_hh and ((s.src_group_id is not null and transfer_group_id = s.src_group_id) or id = s.spend_tx_id);
  update pot_swaps set rate = p_rate, dst_amount = v_dst, rate_source = p_rate_source where id = s.id;
  perform bh_pot_swap_check(v_hh, v_before, bh_pot_swap_effect(s.id), v_old, 'new rate');
  return v_dst;
end;
$$;

-- ── undo ─────────────────────────────────────────────────────────────────
create or replace function public.delete_pot_swap(p_swap uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_hh uuid; s pot_swaps%rowtype; v_before jsonb; v_old jsonb;
begin
  select id into v_hh from households where owner_user_id = auth.uid();
  if v_hh is null then raise exception 'no household'; end if;
  select * into s from pot_swaps where id = p_swap and household_id = v_hh;
  if s.id is null then raise exception 'swap not found'; end if;
  if exists (select 1 from fund_transactions where household_id = v_hh and reconciled_by = 'manual'
              and (transfer_group_id = s.dst_group_id or transfer_group_id = s.src_group_id or id = s.spend_tx_id)) then
    raise exception 'locked: a row of this swap was reconciled against a statement — un-reconcile it first' using errcode = 'P0001';
  end if;
  v_before := bh_pot_swap_snapshot(v_hh); v_old := bh_pot_swap_effect(s.id);
  delete from fund_transactions where household_id = v_hh
     and (transfer_group_id = s.dst_group_id or transfer_group_id = s.src_group_id or id = s.spend_tx_id);
  update expenses set pot_swap_id = null, sent_to_fund = case when s.marked_sent then false else sent_to_fund end
   where id = s.expense_id;
  delete from pot_swaps where id = s.id;
  perform bh_pot_swap_check(v_hh, v_before, '{}'::jsonb, v_old, 'undo');
end;
$function$;

-- ── grants (rule 7): the three RPCs for a signed-in login as before; the helpers are the server's ──
revoke all on function public.record_pot_swap(text, uuid, numeric, uuid, uuid, uuid, uuid, text, text) from public, anon;
revoke all on function public.update_pot_swap_rate(uuid, numeric, text) from public, anon;
revoke all on function public.delete_pot_swap(uuid) from public, anon;
grant execute on function public.record_pot_swap(text, uuid, numeric, uuid, uuid, uuid, uuid, text, text) to authenticated, service_role;
grant execute on function public.update_pot_swap_rate(uuid, numeric, text) to authenticated, service_role;
grant execute on function public.delete_pot_swap(uuid) to authenticated, service_role;
revoke all on function public.bh_pot_swap_effect(uuid) from public, anon, authenticated;
revoke all on function public.bh_pot_swap_snapshot(uuid) from public, anon, authenticated;
revoke all on function public.bh_pot_swap_check(uuid, jsonb, jsonb, jsonb, text) from public, anon, authenticated;
grant execute on function public.bh_pot_swap_effect(uuid) to service_role;
grant execute on function public.bh_pot_swap_snapshot(uuid) to service_role;
grant execute on function public.bh_pot_swap_check(uuid, jsonb, jsonb, jsonb, text) to service_role;

notify pgrst, 'reload schema';
commit;
