-- QA round 2 (14–15 Oct 2026) — the database-side fixes.
--  C-B1  a view-only login could read unused invite codes (and so mint itself a writer login):
--        invites are now readable by writers only.
--  C-B2  purge_deleted was the one write RPC without the writer guard.
--  B-B2  "undo last move" on the Sort page left the card on rows that never had one:
--        move_expense_to_fund_spend can be told which card (or none) each row goes back with.

begin;

-- C-B1 · invites: writers only
drop policy if exists "invites: read own household" on public.member_invites;
create policy "invites: read own household" on public.member_invites for select using (household_id in (select bh_writer_of()));

-- C-B2 · purge is a write
create or replace function public.purge_deleted(p_days integer default 30)
returns integer language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_n int := 0; v_m int := 0;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  perform set_config('bh.via_rpc', 'on', true);
  delete from expenses where household_id = v_hh and deleted_at < now() - make_interval(days => greatest(p_days, 1)) and (reconciled_at is null or coalesce(reconciled_by, '') <> 'manual');
  get diagnostics v_n = row_count;
  delete from fund_transactions_all where household_id = v_hh and deleted_at < now() - make_interval(days => greatest(p_days, 1)) and (reconciled_at is null or coalesce(reconciled_by, '') <> 'manual');
  get diagnostics v_m = row_count;
  return v_n + v_m;
end $$;

-- B-B2 · the way back can restore the original card (p_cards = {"<expense id>": "<card id>" | null});
--        without an entry the row keeps the card it was bought with (right for a real purchase sent back).
drop function if exists public.move_expense_to_fund_spend(uuid[]);
create or replace function public.move_expense_to_fund_spend(p_ids uuid[], p_cards jsonb default null)
returns integer language plpgsql security definer set search_path = public as $$
declare v_hh uuid; r record; v_n int := 0; v_before numeric; v_after numeric; v_card uuid;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  perform set_config('bh.via_rpc', 'on', true);
  for r in select * from expenses where household_id = v_hh and id = any(p_ids) and fund_id is not null and deleted_at is null loop
    if r.reconciled_statement_id is not null and exists (select 1 from statements where id = r.reconciled_statement_id and closed_at is not null) then
      raise exception '% is on a closed statement — reopen it first', r.description;
    end if;
    v_card := r.payment_method_id;
    if p_cards is not null and p_cards ? r.id::text then
      v_card := nullif(p_cards ->> r.id::text, '')::uuid;
      if v_card is not null and not exists (select 1 from payment_methods where id = v_card and household_id = v_hh) then
        raise exception 'card not found';
      end if;
    end if;
    select balance into v_before from fund_balances where fund_id = r.fund_id;
    update expenses set reconciled_at = null, reconciled_by = null, reconciled_statement_id = null where id = r.id;
    delete from expenses where id = r.id;
    insert into fund_transactions_all (id, household_id, fund_id, type, kind, date, amount, remarks, origin, created_at, created_by,
                                       account_payment_method_id, reconciled_at, reconciled_by, reconciled_statement_id)
    values (r.id, v_hh, r.fund_id, 'expense', 'movement', r.date, r.amount, r.description, 'manual', r.created_at, r.created_by,
            v_card, case when r.reconciled_by = 'manual' then r.reconciled_at end, case when r.reconciled_by = 'manual' then 'manual' end, r.reconciled_statement_id);
    select balance into v_after from fund_balances where fund_id = r.fund_id;
    if abs(v_after - v_before) > 0.005 then
      raise exception 'moving % back would change the fund balance (% → %) — stopped', r.description, v_before, v_after;
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke all on function public.move_expense_to_fund_spend(uuid[], jsonb) from public;
grant execute on function public.move_expense_to_fund_spend(uuid[], jsonb) to authenticated, service_role;

notify pgrst, 'reload schema';
commit;
