-- Money moves as a whole (v2 sprint 3, chunk 2).
--
--  1 · The transfer / card-payment group check refuses (D1-F7). Sprint 2 ran it log-only for a release: at commit
--      it noted any group of fund rows sharing a transfer_group_id that no longer held together (one out and one
--      in, same date, same amount in one currency; card-payment legs on one card, date and statement) in
--      integrity_issues. Now the same check rolls the whole change back. A group that was already broken can
--      still be deleted as a unit (the bin keeps it 30 days) — any other change to it is refused until it is.
--  2 · The bin empties a transfer or card payment as a unit (D2-17): a grouped row is purged only when every row
--      of its group is binned, old enough and not checked off by hand. The purge window can't be shortened below
--      30 days by a caller any more (any member could empty the bin after a day).
--
-- No row is written and no balance moves (asserted).
begin;
create temp table _b_fund as select fund_id, balance from public.fund_balances;

-- ── 1 · refuse ──────────────────────────────────────────────────────────
-- checked at commit, once per row event; bh_group_problem (sprint 2) says what is wrong in words — never amounts
create or replace function public.bh_group_check()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_g uuid; v_p text;
begin
  foreach v_g in array array_remove(array[case when tg_op <> 'DELETE' then new.transfer_group_id end,
                                          case when tg_op <> 'INSERT' then old.transfer_group_id end], null) loop
    v_p := bh_group_problem(v_g);
    if v_p is not null then
      raise exception 'money has to move as a whole: % — nothing was saved', v_p
        using errcode = '23514', hint = 'delete both sides and enter it again';
    end if;
  end loop;
  return null;
end $$;
revoke execute on function public.bh_group_check() from public, anon, authenticated;

-- ── 2 · the bin, group by group ─────────────────────────────────────────
create or replace function public.purge_deleted(p_days integer default 30)
returns integer language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_n int := 0; v_m int := 0; v_cut timestamptz;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  v_cut := now() - make_interval(days => greatest(coalesce(p_days, 30), 30));
  perform set_config('bh.via_rpc', 'on', true);
  delete from expenses where household_id = v_hh and deleted_at < v_cut and (reconciled_at is null or coalesce(reconciled_by, '') <> 'manual');
  get diagnostics v_n = row_count;
  delete from fund_transactions_all t
   where t.household_id = v_hh and t.deleted_at < v_cut and (t.reconciled_at is null or coalesce(t.reconciled_by, '') <> 'manual')
     and (t.transfer_group_id is null or not exists (
            select 1 from fund_transactions_all x
             where x.transfer_group_id = t.transfer_group_id
               and (x.deleted_at is null or x.deleted_at >= v_cut or coalesce(x.reconciled_by, '') = 'manual')));
  get diagnostics v_m = row_count;
  return v_n + v_m;
end $$;
revoke execute on function public.purge_deleted(integer) from public, anon;
grant execute on function public.purge_deleted(integer) to authenticated, service_role;

-- ── proof ────────────────────────────────────────────────────────────────
do $$
declare v_bad int; v_groups int;
begin
  select count(*) into v_bad from _b_fund b full join public.fund_balances a using (fund_id) where a.balance is distinct from b.balance;
  if v_bad > 0 then raise exception 'group check: % fund balances changed', v_bad; end if;
  select count(*) into v_groups from (select distinct transfer_group_id from public.fund_transactions_all where transfer_group_id is not null) g
   where public.bh_group_problem(g.transfer_group_id) is not null;
  raise notice 'group check refuses from now on; % groups were already broken (they can only be deleted as a unit)', v_groups;
end $$;
drop table _b_fund;
notify pgrst, 'reload schema';
commit;
