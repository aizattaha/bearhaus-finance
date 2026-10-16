-- The Desk's settings and dashboard (16 Oct 2026, after v2 sprint 3).
--
--  1 · fund_money_asof(date) — the one money rule (fund_money, sprint 3) answerable "as of" any day: the same query,
--        with "today" replaced by the given date (null = each household's own today). fund_money becomes a view over
--        it, so there is still exactly one rule; every fund's numbers are asserted unchanged below.
--  2 · fund_history(months) — each of the caller's funds at the end of each month (the current month as of today):
--        Available, In the bank, Owed on cards. Feeds the Desk dashboard (growth, decline, net worth per country).
--  3 · households.timezone can be changed by a writer (Settings → Time zone, both apps); the sprint-2 trigger still
--        refuses a name that isn't a time zone.
--  4 · a card that changes owner drops the defaults that no longer fit (a default is that person's own card, a shared
--        card or cash — card rules, sprint 2).
--
-- No number moves (asserted).
begin;
create temp table _b on commit drop as select * from public.fund_money;

-- ── 1 · the rule, as of a date ──────────────────────────────────────────
-- plain SQL, no SET clause, every name qualified: Postgres can inline it, and it reads with the caller's rights (RLS)
create or replace function public.fund_money_asof(p_asof date)
returns table (household_id uuid, fund_id uuid, name text, country text, currency text, is_active boolean, sort_order integer,
               group_name text, is_leftover_target boolean, is_spend_pot boolean, icon text, balance numeric, cleared_balance numeric,
               pending_spend numeric, cash_balance numeric, owed_on_cards numeric)
language sql stable as $$
with fg as (
  select t.fund_id, t.account_payment_method_id as pm_id, t.type, t.kind,
         t.date > coalesce(p_asof, (now() at time zone h.timezone)::date) as later, t.reconciled_at is not null as ticked, sum(t.amount) as amount
    from public.fund_transactions t
    join public.funds f on f.id = t.fund_id
    join public.households h on h.id = f.household_id
   group by 1, 2, 3, 4, 5, 6
), fr as (
  select fg.fund_id,
         sum(case when fg.later or fg.kind = 'card_payment' then 0 when fg.type = 'income' then fg.amount else -fg.amount end) as avail,
         sum(case when fg.later or not fg.ticked or fg.kind = 'card_payment' then 0 when fg.type = 'income' then fg.amount else -fg.amount end) as cleared,
         sum(case when fg.later then 0 when fg.type = 'expense' and fg.kind <> 'card_payment' and pm.kind = 'credit_card' then 0
                  when fg.type = 'income' then fg.amount else -fg.amount end) as cash
    from fg left join public.payment_methods pm on pm.id = fg.pm_id
   group by fg.fund_id
), eg as (
  select de.pot_fund_id as fund_id, de.payment_method_id as pm_id, de.reconciled_at is not null as ticked,
         sum(case when de.is_refund then -de.amount else de.amount end) as amount
    from public.expenses de
    join public.funds f on f.id = de.pot_fund_id and f.household_id = de.household_id and f.currency = de.currency
    join public.households h on h.id = f.household_id
   where de.trip_id is null and de.deleted_at is null and de.category <> 'Payment'
     and de.date <= coalesce(p_asof, (now() at time zone h.timezone)::date)
     and (de.fund_id = f.id or (f.is_spend_pot and h.pot_start is not null and de.date >= h.pot_start))
   group by 1, 2, 3
), ex as (
  select eg.fund_id, sum(eg.amount) as spend,
         sum(eg.amount) filter (where eg.ticked) as spend_cleared,
         sum(eg.amount) filter (where not eg.ticked) as spend_pending,
         sum(eg.amount) filter (where coalesce(pm.kind, 'cash') <> 'credit_card') as spend_cash
    from eg left join public.payment_methods pm on pm.id = eg.pm_id
   group by eg.fund_id
), op as (
  select o.fund_id, sum(o.amount) as amount from public.card_openings o group by o.fund_id
), sl as (
  select e.settlement_tx_id as tx,
         sum(case when e.is_refund then -e.amount else e.amount end) as total,
         sum(case when e.is_refund then -e.amount else e.amount end)
           filter (where pm.kind = 'credit_card' and (h.pot_start is null or e.date >= h.pot_start)) as cards
    from public.expenses e
    join public.households h on h.id = e.household_id
    left join public.payment_methods pm on pm.id = e.payment_method_id
   where e.settlement_tx_id is not null and e.deleted_at is null
   group by e.settlement_tx_id
), st as (
  select a.fund_id, sum(round(a.amount * l.cards / l.total, 2)) as share
    from sl l
    join public.fund_transactions a on a.id = l.tx
    join public.funds f on f.id = a.fund_id
    join public.households h on h.id = f.household_id
   where a.type = 'expense' and a.kind = 'allocation' and a.date <= coalesce(p_asof, (now() at time zone h.timezone)::date)
     and l.total > 0 and l.cards is not null
   group by a.fund_id
)
select f.household_id, f.id as fund_id, f.name, f.country, f.currency, f.is_active, f.sort_order, f.group_name,
       f.is_leftover_target, f.is_spend_pot, f.icon,
       coalesce(fr.avail, 0) - coalesce(ex.spend, 0) as balance,
       coalesce(fr.cleared, 0) - coalesce(ex.spend_cleared, 0) as cleared_balance,
       coalesce(ex.spend_pending, 0) as pending_spend,
       coalesce(fr.cash, 0) - coalesce(ex.spend_cash, 0) + coalesce(op.amount, 0) + coalesce(st.share, 0) as cash_balance,
       round(coalesce(fr.cash, 0) - coalesce(ex.spend_cash, 0) + coalesce(op.amount, 0) + coalesce(st.share, 0)
             - (coalesce(fr.avail, 0) - coalesce(ex.spend, 0)), 2) as owed_on_cards
  from public.funds f
  left join fr on fr.fund_id = f.id
  left join ex on ex.fund_id = f.id
  left join op on op.fund_id = f.id
  left join st on st.fund_id = f.id
$$;
revoke execute on function public.fund_money_asof(date) from public, anon;
grant execute on function public.fund_money_asof(date) to authenticated, service_role;

create or replace view public.fund_money with (security_invoker = true) as
  select * from public.fund_money_asof(null);

-- ── 2 · month by month ──────────────────────────────────────────────────
create or replace function public.fund_history(p_months integer default 12)
returns table (fund_id uuid, month date, as_of date, balance numeric, cash_balance numeric, owed_on_cards numeric)
language plpgsql stable set search_path = public as $$
declare v_hh uuid; v_today date; v_m date; v_d date; i int;
begin
  v_hh := bh_current_household(false);
  if v_hh is null then return; end if;
  v_today := bh_today(v_hh);
  for i in reverse greatest(least(coalesce(p_months, 12), 36), 1) - 1 .. 0 loop
    v_m := (date_trunc('month', v_today) - make_interval(months => i))::date;
    v_d := least((v_m + interval '1 month - 1 day')::date, v_today);
    return query
      select m.fund_id, v_m, v_d, m.balance, m.cash_balance, m.owed_on_cards
        from fund_money_asof(v_d) m where m.household_id = v_hh;
  end loop;
end $$;
revoke execute on function public.fund_history(integer) from public, anon;
grant execute on function public.fund_history(integer) to authenticated, service_role;

-- ── 3 · the time zone is a household setting ────────────────────────────
grant update (timezone) on public.households to authenticated;

-- ── 4 · a new owner, defaults that still fit ────────────────────────────
create or replace function public.bh_card_defaults_prune()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from card_defaults d where d.payment_method_id = new.id and (
       new.is_archived
    or (d.context = 'daily' and not new.show_daily)
    or (d.context = 'trip'  and not new.show_trip)
    or (d.context = 'fund'  and not new.show_fund)
    or (new.profile_id is not null and new.kind <> 'cash' and d.profile_id is distinct from new.profile_id));
  return null;
end $$;
revoke execute on function public.bh_card_defaults_prune() from public, anon, authenticated;

-- ── proof ────────────────────────────────────────────────────────────────
do $$
declare v_bad int; v_n int;
begin
  select count(*) into v_n from _b;
  select count(*) into v_bad from _b b full join public.fund_money a using (fund_id)
   where a.fund_id is null or b.fund_id is null
      or a.balance is distinct from b.balance or a.cleared_balance is distinct from b.cleared_balance
      or a.pending_spend is distinct from b.pending_spend or a.cash_balance is distinct from b.cash_balance
      or a.owed_on_cards is distinct from b.owed_on_cards;
  if v_bad > 0 then raise exception 'desk dashboard: % funds'' numbers changed', v_bad; end if;
  raise notice 'desk dashboard ok: % funds, every number unchanged', v_n;
end $$;
notify pgrst, 'reload schema';
commit;
