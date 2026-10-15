-- The database does the sums (v2 sprint 3, chunk 1): read models.
--
--  1 · fund_money — every number on a fund in one pass over the two ledgers, with no per-row function calls
--        (D2-10): Available, cleared, pending, in the bank, owed on cards. fund_balances, fund_balances_cleared
--        and fund_cash become thin views over it, so each number has one rule. Every fund's numbers are
--        asserted unchanged below.
--  2 · household_money() — the caller's funds with all their numbers in one call (phone Funds, Desk Pots).
--  3 · app_bootstrap() — everything the phone needs at launch in one call (E1-F8): household, role, who I am,
--        people, funds, cards, categories (with ids), trips, default cards, recent descriptions, income
--        sources, the first month, this month's plan. Replaces ~20 launch queries and the column probes.
--  4 · home_summary() — Home: the last seven days, the five latest purchases, this month by category group
--        (by id, not by name), income that arrived.
--  5 · budget_summary(month, currency, months) — Budget summed in SQL (no 1,000-row cap, E1-F2): spend per
--        group per month, scheduled, paid from funds, budget lines by group id, the month's categories, the pots.
--  6 · trip_summary() — each trip's totals per currency, what each person fronted (not yet sent), settled or not.
--
-- Everything reads with the caller's rights (RLS applies) and the household's "today". No balance moves (asserted).
begin;
create temp table _b_fund as select fund_id, balance from public.fund_balances;
create temp table _b_clr  as select fund_id, cleared_balance, pending_spend from public.fund_balances_cleared;
create temp table _b_cash as select fund_id, cash_balance, owed_on_cards from public.fund_cash;
create temp table _b_card as select payment_method_id, owed from public.card_balances;

-- ── 1 · one pass over the ledgers ───────────────────────────────────────
-- the same rules as the three views it replaces (every_number_right + settled_amounts), written once. Rows are
-- summed by what decides how they count (a few groups per fund) before the card table is consulted:
--   fr: fund rows — Available leaves out card payments; cleared counts ticked rows only; in the bank leaves out
--       a fund row charged to a credit card (it is owed, not paid yet)
--   ex: purchases counted against the fund — its own (fund_id) or, for a spending pot, its category's from pot_start
--   op: what a credit card owed on pot_start, carried by the fund that backs it
--   st: the card share of a trip send (from the purchases it settled), still owed on cards until the card is paid
create or replace view public.fund_money with (security_invoker = true) as
with fg as (
  select t.fund_id, t.account_payment_method_id as pm_id, t.type, t.kind,
         t.date > (now() at time zone h.timezone)::date as later, t.reconciled_at is not null as ticked, sum(t.amount) as amount
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
     and de.date <= (now() at time zone h.timezone)::date
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
   where a.type = 'expense' and a.kind = 'allocation' and a.date <= (now() at time zone h.timezone)::date
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
  left join st on st.fund_id = f.id;
revoke all on public.fund_money from public, anon;
grant select on public.fund_money to authenticated, service_role;

-- the three views every app and RPC already reads keep their names and columns; their numbers now come from fund_money
create or replace view public.fund_balances with (security_invoker = true) as
  select household_id, fund_id, name, country, currency, is_active, sort_order, group_name, is_leftover_target, is_spend_pot, balance
    from public.fund_money;
create or replace view public.fund_balances_cleared with (security_invoker = true) as
  select household_id, fund_id, name, country, currency, is_active, sort_order, group_name, is_leftover_target, is_spend_pot,
         cleared_balance, pending_spend
    from public.fund_money;
create or replace view public.fund_cash with (security_invoker = true) as
  select household_id, fund_id, name, currency, is_active, is_spend_pot, balance, cash_balance, owed_on_cards
    from public.fund_money;

-- each currency's first active spending pot; ties on sort_order go to the oldest id, the same way every time
create or replace function public.default_spend_pot(p_hh uuid, p_cur text)
returns uuid language sql stable set search_path = public as $$
  select id from funds
   where household_id = p_hh and currency = p_cur and is_spend_pot and is_active
   order by sort_order, id limit 1
$$;

-- ── 2 · the caller's funds, every number, one call ──────────────────────
create or replace function public.household_money()
returns setof public.fund_money language sql stable set search_path = public as $$
  select * from fund_money where household_id = bh_current_household(false) order by sort_order, name
$$;
revoke execute on function public.household_money() from public, anon;
grant execute on function public.household_money() to authenticated, service_role;

-- ── 3 · launch: one call ────────────────────────────────────────────────
create or replace function public.app_bootstrap()
returns jsonb language plpgsql stable set search_path = public as $$
declare v_hh uuid; v_today date; v_month date;
begin
  v_hh := bh_current_household(false);
  if v_hh is null then return jsonb_build_object('household', null); end if;   -- no household (or access removed)
  v_today := bh_today(v_hh);
  v_month := date_trunc('month', v_today)::date;
  return jsonb_build_object(
    'household', (select jsonb_build_object('id', h.id, 'name', h.name, 'travel_fund_id', h.travel_fund_id, 'joint_label', h.joint_label,
                                            'pot_start', h.pot_start, 'timezone', h.timezone)
                    from households h where h.id = v_hh),
    'today', v_today,
    'month', v_month,
    'me', (select jsonb_build_object('user_id', m.user_id, 'role', m.role,
                                     'profile_id', coalesce(m.profile_id, (select p.id from profiles p where p.household_id = v_hh and p.auth_user_id = auth.uid() limit 1)))
             from household_members m where m.user_id = auth.uid() and m.household_id = v_hh),
    'profiles', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'display_name', p.display_name) order by p.sort_order, p.display_name)
                            from profiles p where p.household_id = v_hh), '[]'),
    'funds', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'name', f.name, 'country', f.country, 'currency', f.currency,
                                                           'group_name', f.group_name, 'sort_order', f.sort_order, 'is_spend_pot', f.is_spend_pot,
                                                           'is_leftover_target', f.is_leftover_target, 'icon', f.icon) order by f.sort_order, f.name)
                         from funds f where f.household_id = v_hh and f.is_active), '[]'),
    'trips', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'currency', t.currency, 'currencies', t.currencies,
                                                           'countries', t.countries, 'start_date', t.start_date, 'end_date', t.end_date)
                                        order by t.start_date desc nulls first, t.name)
                         from trips t where t.household_id = v_hh), '[]'),
    'cards', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'profile_id', c.profile_id, 'travel_only', c.travel_only,
                                                           'sort_order', c.sort_order, 'kind', c.kind, 'currency', c.currency,
                                                           'show_daily', c.show_daily, 'show_trip', c.show_trip, 'show_fund', c.show_fund)
                                        order by c.sort_order, c.name)
                         from payment_methods c where c.household_id = v_hh and not c.is_archived), '[]'),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'name', c.name, 'group_name', c.group_name,
                                                                'group_id', c.group_id, 'icon', c.icon, 'role', c.role) order by c.sort_order, c.name)
                              from categories c where c.household_id = v_hh and c.is_active), '[]'),
    'card_defaults', coalesce((select jsonb_agg(jsonb_build_object('profile_id', d.profile_id, 'context', d.context, 'payment_method_id', d.payment_method_id))
                                 from card_defaults d where d.household_id = v_hh), '[]'),
    -- what was bought lately: the description takeover and the most-used categories
    'recent_daily', coalesce((select jsonb_agg(jsonb_build_object('description', r.description, 'category', r.category, 'amount', r.amount, 'currency', r.currency)
                                               order by r.date desc, r.created_at desc)
                                from (select e.description, e.category, e.amount, e.currency, e.date, e.created_at from expenses e
                                       where e.household_id = v_hh and e.trip_id is null and e.deleted_at is null
                                       order by e.date desc, e.created_at desc limit 300) r), '[]'),
    'recent_travel', coalesce((select jsonb_agg(jsonb_build_object('description', r.description, 'category', r.category, 'amount', r.amount, 'currency', r.currency)
                                                order by r.date desc, r.created_at desc)
                                 from (select e.description, e.category, e.amount, e.currency, e.date, e.created_at from expenses e
                                        where e.household_id = v_hh and e.trip_id is not null and e.deleted_at is null
                                        order by e.date desc, e.created_at desc limit 120) r), '[]'),
    'first_month', coalesce((select date_trunc('month', min(e.date))::date from expenses e
                              where e.household_id = v_hh and e.trip_id is null and e.deleted_at is null), v_month),
    -- the plan's named sources (newest month first), then sources used for money that arrived; each name once
    'income_sources', coalesce((select jsonb_agg(s.name order by s.k, s.at desc)
                                  from (select x.name, x.k, x.at, row_number() over (partition by lower(x.name) order by x.k, x.at desc) as n
                                          from (select b.source_name as name, 1 as k, b.month::timestamptz as at
                                                  from (select source_name, month from income_budgets where household_id = v_hh order by month desc limit 60) b
                                                union all
                                                select t.income_source, 2, t.created_at
                                                  from (select income_source, created_at from fund_transactions
                                                         where household_id = v_hh and income_source is not null order by created_at desc limit 120) t) x) s
                                 where s.n = 1), '[]'),
    'plan', (select jsonb_build_object('month', s.month, 'applied_on', s.applied_on, 'saved', s.saved, 'version', s.version,
                                       'fund_lines', exists (select 1 from fund_budgets b where b.household_id = v_hh and b.month = v_month))
               from plan_status(v_month) s)
  );
end $$;
revoke execute on function public.app_bootstrap() from public, anon;
grant execute on function public.app_bootstrap() to authenticated, service_role;

-- ── 4 · Home ────────────────────────────────────────────────────────────
-- spending = daily purchases, not "Payment" (settling up), not paid from a fund, refunds negative
create or replace function public.home_summary()
returns jsonb language plpgsql stable set search_path = public as $$
declare v_hh uuid; v_today date; v_month date; v_applied date;
begin
  v_hh := bh_current_household(false);
  if v_hh is null then return null; end if;
  v_today := bh_today(v_hh);
  v_month := date_trunc('month', v_today)::date;
  select s.applied_on into v_applied from plan_status(v_month) s;
  return jsonb_build_object(
    'today', v_today,
    'month', v_month,
    'plan_applied', v_applied is not null,
    'week', coalesce((select jsonb_agg(jsonb_build_object('date', w.date, 'currency', w.currency, 'amount', w.amount) order by w.date, w.currency)
                        from (select e.date, e.currency, sum(case when e.is_refund then -e.amount else e.amount end) as amount
                                from expenses e
                               where e.household_id = v_hh and e.trip_id is null and e.deleted_at is null and e.fund_id is null
                                 and e.category <> 'Payment' and e.date between v_today - 6 and v_today
                               group by e.date, e.currency) w), '[]'),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'date', r.date, 'description', r.description, 'category', r.category,
                                                            'amount', r.amount, 'currency', r.currency, 'is_refund', r.is_refund, 'fund_id', r.fund_id,
                                                            'payer', r.payer) order by r.date desc, r.created_at desc)
                          from (select e.id, e.date, e.description, e.category, e.amount, e.currency, e.is_refund, e.fund_id, e.created_at,
                                       p.display_name as payer
                                  from expenses e left join profiles p on p.id = e.payer_profile_id
                                 where e.household_id = v_hh and e.trip_id is null and e.deleted_at is null and e.date <= v_today
                                 order by e.date desc, e.created_at desc limit 5) r), '[]'),
    'month_groups', coalesce((select jsonb_agg(jsonb_build_object('currency', g.currency, 'group_id', g.group_id, 'name', g.name, 'amount', g.amount)
                                               order by g.currency, g.amount desc)
                                from (select e.currency, c.group_id, coalesce(cg.name, 'Other') as name,
                                             sum(case when e.is_refund then -e.amount else e.amount end) as amount
                                        from expenses e
                                        left join categories c on c.id = e.category_id
                                        left join category_groups cg on cg.id = c.group_id
                                       where e.household_id = v_hh and e.trip_id is null and e.deleted_at is null and e.fund_id is null
                                         and e.category <> 'Payment' and e.date between v_month and v_today
                                       group by e.currency, c.group_id, cg.name) g), '[]'),
    -- income that arrived: the applied plan's named sources, plus money logged as income this month
    'income', coalesce((select jsonb_agg(jsonb_build_object('source', i.source, 'currency', i.currency, 'amount', i.amount) order by i.currency, i.amount desc)
                          from (select x.source, x.currency, sum(x.amount) as amount
                                  from (select b.source_name as source, b.currency, b.amount from income_budgets b
                                         where b.household_id = v_hh and b.month = v_month and v_applied is not null
                                        union all
                                        select coalesce(t.income_source, 'Other'), f.currency, t.amount
                                          from fund_transactions t join funds f on f.id = t.fund_id
                                         where t.household_id = v_hh and t.income_source is not null and t.date between v_month and v_today) x
                                 group by x.source, x.currency) i), '[]')
  );
end $$;
revoke execute on function public.home_summary() from public, anon;
grant execute on function public.home_summary() to authenticated, service_role;

-- ── 5 · Budget ──────────────────────────────────────────────────────────
-- one currency, p_months months ending with p_month. A purchase counts on its day (later ones are "scheduled");
-- one paid from a fund is shown but never counted against the month's budget.
create or replace function public.budget_summary(p_month date, p_currency text, p_months integer default 6)
returns jsonb language plpgsql stable set search_path = public as $$
declare v_hh uuid; v_today date; v_m date; v_from date; v_to date; v_out jsonb;
begin
  v_hh := bh_current_household(false);
  if v_hh is null then return null; end if;
  v_today := bh_today(v_hh);
  v_m := date_trunc('month', coalesce(p_month, v_today))::date;
  v_from := (v_m - make_interval(months => greatest(least(coalesce(p_months, 6), 24), 1) - 1))::date;
  v_to := (v_m + interval '1 month')::date;
  -- one pass over the window's purchases, summed by month, category, paid-from-a-fund and later-than-today
  with r as (
    select date_trunc('month', e.date)::date as month, e.category_id, max(e.category) as name,
           e.fund_id is not null as from_fund, e.date > v_today as later,
           sum(case when e.is_refund then -e.amount else e.amount end) as amount, count(*)::int as n
      from expenses e
     where e.household_id = v_hh and e.trip_id is null and e.deleted_at is null and e.currency = p_currency
       and e.category <> 'Payment' and e.date >= v_from and e.date < v_to
     group by 1, 2, 4, 5
  ), rc as (
    select r.*, c.group_id, coalesce(cg.name, 'Other') as group_name, c.icon
      from r left join categories c on c.id = r.category_id left join category_groups cg on cg.id = c.group_id
  )
  select jsonb_build_object(
    'month', v_m, 'currency', p_currency, 'today', v_today, 'from', v_from,
    -- the household's daily groups in Budget order (by their first active category); a group of only the
    -- settle-up category is not a budget group
    'groups', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'icon', g.icon, 'active', g.active) order by g.first_cat nulls last, g.sort_order, g.name)
                          from (select cg.id, cg.name, cg.sort_order,
                                       (select c.icon from categories c where c.group_id = cg.id and c.is_active order by c.sort_order, c.name limit 1) as icon,
                                       (select min(c.sort_order) from categories c where c.group_id = cg.id and c.is_active) as first_cat,
                                       exists (select 1 from categories c where c.group_id = cg.id and c.is_active) as active,
                                       exists (select 1 from categories c where c.group_id = cg.id)
                                         and not exists (select 1 from categories c where c.group_id = cg.id and c.role is distinct from 'settle_up') as settle_only
                                  from category_groups cg where cg.household_id = v_hh and cg.kind = 'daily') g
                         where not g.settle_only), '[]'),
    -- counted: on or before today, not paid from a fund
    'spend', coalesce((select jsonb_agg(jsonb_build_object('month', s.month, 'group_id', s.group_id, 'name', s.group_name, 'amount', s.amount))
                         from (select month, group_id, group_name, sum(amount) as amount from rc where not from_fund and not later group by 1, 2, 3) s), '[]'),
    'scheduled', coalesce((select jsonb_agg(jsonb_build_object('month', s.month, 'amount', s.amount))
                             from (select month, sum(amount) as amount from rc where not from_fund and later group by 1) s), '[]'),
    'from_funds', coalesce((select jsonb_agg(jsonb_build_object('month', s.month, 'amount', s.amount))
                              from (select month, sum(amount) as amount from rc where from_fund group by 1) s), '[]'),
    -- the chosen month's categories (to today): what counts, and how many were paid from funds
    'cats', coalesce((select jsonb_agg(jsonb_build_object('group_id', k.group_id, 'category_id', k.category_id, 'name', k.name, 'icon', k.icon,
                                                          'amount', k.amount, 'from_funds', k.from_funds) order by k.amount desc, k.name)
                        from (select group_id, category_id, max(name) as name, max(icon) as icon,
                                     coalesce(sum(amount) filter (where not from_fund), 0) as amount,
                                     coalesce(sum(n) filter (where from_fund), 0)::int as from_funds
                                from rc where month = v_m and not later group by group_id, category_id) k), '[]'),
    -- budget lines by group id (with the line's own label)
    'budget', coalesce((select jsonb_agg(jsonb_build_object('month', b.month, 'group_id', b.category_group_id, 'label', b.category_group, 'amount', b.amount))
                          from category_budgets b
                         where b.household_id = v_hh and b.currency = p_currency and b.month >= v_from and b.month <= v_m), '[]'),
    'pots', coalesce((select jsonb_agg(jsonb_build_object('fund_id', m.fund_id, 'name', m.name, 'balance', m.balance, 'currency', m.currency, 'icon', m.icon)
                                       order by m.sort_order, m.name)
                        from fund_money m
                       where m.household_id = v_hh and m.is_spend_pot and m.is_active and m.currency = p_currency), '[]')
  ) into v_out;
  return v_out;
end $$;
revoke execute on function public.budget_summary(date, text, integer) from public, anon;
grant execute on function public.budget_summary(date, text, integer) to authenticated, service_role;

-- ── 6 · Trips ───────────────────────────────────────────────────────────
create or replace function public.trip_summary()
returns jsonb language sql stable set search_path = public as $$
  with hh as (select bh_current_household(false) as id),
  e as (
    select e.id, e.trip_id, e.currency, e.sent_to_fund, case when e.is_refund then -e.amount else e.amount end as amount
      from expenses e
     where e.household_id = (select id from hh) and e.trip_id is not null and e.deleted_at is null
  ), tot as (
    select trip_id, jsonb_object_agg(currency, amount) as totals
      from (select trip_id, currency, sum(amount) as amount from e group by trip_id, currency) x group by trip_id
  ), cnt as (
    select trip_id, count(*)::int as n, bool_and(sent_to_fund) as all_sent from e group by trip_id
  ), fr as (   -- what each person fronted on lines not yet sent to the travel fund (a refund's split is negative)
    select trip_id, jsonb_agg(jsonb_build_object('profile_id', profile_id, 'currency', currency, 'amount', amount) order by profile_id, currency) as fronted
      from (select e.trip_id, s.profile_id, e.currency, sum(s.amount) as amount
              from e join expense_splits s on s.expense_id = e.id
             where not e.sent_to_fund and s.profile_id is not null
             group by e.trip_id, s.profile_id, e.currency) y
     group by trip_id
  )
  select coalesce(jsonb_agg(jsonb_build_object('trip_id', t.id, 'n', coalesce(c.n, 0), 'all_sent', coalesce(c.all_sent, false),
                                               'totals', coalesce(tot.totals, '{}'), 'fronted', coalesce(fr.fronted, '[]'))), '[]')
    from trips t
    left join cnt c on c.trip_id = t.id
    left join tot on tot.trip_id = t.id
    left join fr on fr.trip_id = t.id
   where t.household_id = (select id from hh)
$$;
revoke execute on function public.trip_summary() from public, anon;
grant execute on function public.trip_summary() to authenticated, service_role;

-- ── proof: every fund and card number is what it was ────────────────────
do $$
declare v_bad int; v_funds int;
begin
  select count(*) into v_funds from public.fund_money;
  select count(*) into v_bad from _b_fund b full join public.fund_balances a using (fund_id) where a.balance is distinct from b.balance;
  if v_bad > 0 then raise exception 'read models: % funds'' Available changed', v_bad; end if;
  select count(*) into v_bad from _b_clr b full join public.fund_balances_cleared a using (fund_id)
   where a.cleared_balance is distinct from b.cleared_balance or a.pending_spend is distinct from b.pending_spend;
  if v_bad > 0 then raise exception 'read models: % funds'' cleared numbers changed', v_bad; end if;
  select count(*) into v_bad from _b_cash b full join public.fund_cash a using (fund_id)
   where a.cash_balance is distinct from b.cash_balance or a.owed_on_cards is distinct from b.owed_on_cards;
  if v_bad > 0 then raise exception 'read models: % funds'' cash changed', v_bad; end if;
  select count(*) into v_bad from _b_card b full join public.card_balances a using (payment_method_id) where a.owed is distinct from b.owed;
  if v_bad > 0 then raise exception 'read models: % card balances changed', v_bad; end if;
  raise notice 'read models ok: % funds, every number unchanged', v_funds;
end $$;
drop table _b_fund; drop table _b_clr; drop table _b_cash; drop table _b_card;
notify pgrst, 'reload schema';
commit;
