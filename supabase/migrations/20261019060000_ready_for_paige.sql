-- Bundle C · "close the loop, ready for Paige" (Review Board round 1). UI, read models and guards only — no money
-- rule changes and no stored row changes (new money rules are frozen until one real month has run).
--
--   1 · A login that signed up with a JOIN code can't set up a household of its own by mistake: the code it was
--       invited with is still waiting, so it must join (a trigger on households; the phone also hides the form).
--   2 · bh_card_periods(hh): each credit card's statement periods from the start date to today, from its closing
--       day, and whether a closed statement covers each one. Server-only; feeds the two read models below.
--   3 · setup_todo(): the owner's setup list, worked out from the data (Home and the Desk Dashboard). Empty for
--       anyone but the owner. Two ticks the database can't see — the sign-up check switched on in Supabase, and
--       "no invite needed" — are kept in households.setup_done through setup_mark().
--   4 · money_checks(): per credit card "checked to <date>" (the last closed statement) and per fund the cards its
--       money sits on, so a fund says "not yet checked against statements" until each of them has been.
--   5 · fund_explain(fund): how a fund's Available is made — all time and this month (opening + in − out −
--       purchases), by fund_money's own rules, plus In the bank and Owed on cards from fund_money itself.

begin;

-- ── 1 · invited to join, not to start a household ─────────────────────────
create or replace function public.bh_household_invited_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from auth.users u
               join member_invites mi on lower(mi.code) = lower(trim(u.raw_user_meta_data ->> 'invite'))
              where u.id = coalesce(new.owner_user_id, auth.uid()) and mi.used_at is null and mi.expires_at > now()) then
    raise exception 'this login was invited to join a household — use the JOIN code from the invite instead of setting up a new one'
      using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke all on function public.bh_household_invited_guard() from public, anon, authenticated;
drop trigger if exists households_invited_guard on public.households;
create trigger households_invited_guard before insert on public.households
  for each row execute function public.bh_household_invited_guard();

-- ── 2 · statement periods per credit card, from the start date ────────────
-- A period ends on the card's closing day (the month's last day when the month is shorter). Covered = a closed
-- statement on that card spans the period's end, whatever its own dates (a statement saved under an older closing
-- day still counts — ENG-03).
create or replace function public.bh_card_periods(p_hh uuid)
returns table(card_id uuid, period_start date, period_end date, ended boolean, covered boolean, statement_id uuid)
language sql stable security definer set search_path = public as $$
  with h as (select id, pot_start, bh_today(id) as today from households where id = p_hh and pot_start is not null),
  c as (select pm.id, pm.closing_day from payment_methods pm, h
         where pm.household_id = h.id and pm.kind = 'credit_card' and pm.closing_day between 1 and 31),
  m as (select c.id as card_id, c.closing_day, gs::date as month
          from c, h, generate_series(date_trunc('month', h.pot_start), date_trunc('month', h.today) + interval '1 month', interval '1 month') gs),
  e as (select card_id, make_date(extract(year from month)::int, extract(month from month)::int,
                                  least(closing_day, extract(day from (month + interval '1 month - 1 day'))::int)) as period_end
          from m),
  p as (select card_id, coalesce(lag(period_end) over (partition by card_id order by period_end) + 1, period_end - interval '1 month' + interval '1 day')::date as period_start, period_end
          from e)
  select p.card_id, p.period_start, p.period_end, p.period_end < h.today as ended,
         s.id is not null as covered, s.id as statement_id
    from p cross join h
    left join lateral (select st.id from statements st
                        where st.payment_method_id = p.card_id and st.closed_at is not null
                          and st.period_start <= p.period_end and st.period_end >= p.period_end
                        order by st.period_end limit 1) s on true
   where p.period_end >= h.pot_start and p.period_start <= h.today
$$;
revoke all on function public.bh_card_periods(uuid) from public, anon, authenticated;

-- ── 3 · the owner's setup list ─────────────────────────────────────────────
alter table public.households add column if not exists setup_done text[] not null default '{}';
-- (members can't write it directly: households keeps its column-level UPDATE grant — name, joint_label,
--  travel_fund_id, timezone — so this column changes only through setup_mark)

create or replace function public.setup_mark(p_item text, p_done boolean)
returns text[] language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v text[];
begin
  select household_id into v_hh from household_members where user_id = auth.uid() and role = 'owner';
  if v_hh is null then raise exception 'only the household''s owner keeps the setup list' using errcode = '42501'; end if;
  if p_item not in ('signup_check', 'invite') then raise exception 'unknown setup item'; end if;
  update households set setup_done = case when p_done then array(select distinct x from unnest(setup_done || p_item) x order by 1)
                                          else array_remove(setup_done, p_item) end
   where id = v_hh returning setup_done into v;
  return v;
end $$;
revoke all on function public.setup_mark(text, boolean) from public, anon;
grant execute on function public.setup_mark(text, boolean) to authenticated, service_role;

-- Each item: key, n (what is left), done, and any detail the screen needs. In the order to do them (ENG-12):
-- that's me · default cards · closing days (before ticking anything) · old refunds · Sort fund spending · openings
-- on the start date · statements to close and pay · trips (type what the card charged, then send) · invite · the
-- sign-up check. The apps hold the words and the link to the screen that does each one.
create or replace function public.setup_todo()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_hh uuid; h record; v_today date;
  n_me int; n_def int; n_close int; n_ref int; n_sort int; n_open int; n_stc int; n_stp int; n_wait int; n_send int; n_inv int;
  v_def jsonb; v_cl jsonb; v_op jsonb; v_st jsonb;
begin
  select m.household_id into v_hh from household_members m where m.user_id = auth.uid() and m.role = 'owner';
  if v_hh is null then return '[]'::jsonb; end if;
  select * into h from households where id = v_hh;
  v_today := bh_today(v_hh);

  select count(*) into n_me from household_members where household_id = v_hh and user_id = auth.uid() and profile_id is null;

  -- default cards: every person has a Daily default (Trip and From a fund fall back to it)
  select count(*), coalesce(jsonb_agg(p.display_name order by p.sort_order), '[]') into n_def, v_def
    from profiles p
   where p.household_id = v_hh
     and not exists (select 1 from card_defaults d where d.household_id = v_hh and d.profile_id = p.id and d.context = 'daily');

  select count(*), coalesce(jsonb_agg(pm.name order by pm.sort_order, pm.name), '[]') into n_close, v_cl
    from payment_methods pm
   where pm.household_id = v_hh and pm.kind = 'credit_card' and not pm.is_archived and pm.closing_day is null;

  select count(*) into n_ref from expenses where household_id = v_hh and is_refund and refund_of is null and deleted_at is null;

  select count(*) into n_sort from fund_spend_sort where household_id = v_hh;

  -- what each credit card owed on the start date: entered once per card (zero is an answer)
  select count(*), coalesce(jsonb_agg(pm.name order by pm.sort_order, pm.name), '[]') into n_open, v_op
    from payment_methods pm
   where pm.household_id = v_hh and pm.kind = 'credit_card' and not pm.is_archived and h.pot_start is not null
     and not exists (select 1 from card_openings o where o.payment_method_id = pm.id);

  -- statements: ended periods no closed statement covers, then closed statements still to pay
  select count(*) filter (where p.ended and not p.covered),
         coalesce(jsonb_agg(jsonb_build_object('card_id', p.card_id, 'card', pm.name, 'period_end', p.period_end) order by p.period_end, pm.name)
                    filter (where p.ended and not p.covered), '[]')
    into n_stc, v_st
    from bh_card_periods(v_hh) p join payment_methods pm on pm.id = p.card_id
   where not pm.is_archived;
  select count(*) into n_stp
    from statements s join statement_balances b on b.statement_id = s.id
   where s.household_id = v_hh and s.closed_at is not null and b.status not in ('paid', 'scheduled') and coalesce(b.due, 0) > 0.005;

  -- finished trips: card lines waiting for what the card charged, then lines ready to send
  select count(*) filter (where l.mode = 'card' and l.value is null),
         count(*) filter (where l.value is not null)
    into n_wait, n_send
    from trips t
    cross join lateral bh_trip_lines(v_hh, t.id) l
   where t.household_id = v_hh and not l.sent
     and coalesce(t.end_date, (select max(e.date) from expenses e where e.trip_id = t.id and e.deleted_at is null)) < v_today;

  select count(*) into n_inv from profiles p
   where p.household_id = v_hh and not exists (select 1 from household_members m where m.profile_id = p.id);

  return jsonb_build_array(
    jsonb_build_object('key', 'me', 'n', n_me, 'done', n_me = 0),
    jsonb_build_object('key', 'defaults', 'n', n_def, 'done', n_def = 0, 'people', v_def),
    jsonb_build_object('key', 'closing_days', 'n', n_close, 'done', n_close = 0, 'cards', v_cl),
    jsonb_build_object('key', 'old_refunds', 'n', n_ref, 'done', n_ref = 0),
    jsonb_build_object('key', 'sort', 'n', n_sort, 'done', n_sort = 0),
    jsonb_build_object('key', 'openings', 'n', n_open, 'done', n_open = 0, 'cards', v_op),
    jsonb_build_object('key', 'statements', 'n', n_stc + n_stp, 'done', n_stc + n_stp = 0, 'to_close', n_stc, 'to_pay', n_stp,
                       'blocked', n_close > 0, 'periods', v_st),
    jsonb_build_object('key', 'trips', 'n', n_wait + n_send, 'done', n_wait + n_send = 0, 'waiting', n_wait, 'to_send', n_send),
    jsonb_build_object('key', 'invite', 'n', n_inv, 'done', n_inv = 0 or 'invite' = any(h.setup_done)),
    jsonb_build_object('key', 'signup_check', 'n', case when 'signup_check' = any(h.setup_done) then 0 else 1 end,
                       'done', 'signup_check' = any(h.setup_done))
  );
end $$;
revoke all on function public.setup_todo() from public, anon;
grant execute on function public.setup_todo() to authenticated, service_role;

-- ── 4 · checked against statements ────────────────────────────────────────
-- A credit card is "checked to" the end of its last closed statement; until one is closed it is not checked.
-- `open_before` = ended periods before that date no closed statement covers (closed out of order). A fund's money
-- sits on the cards its purchases (counted against it, from the start date), its card-charged fund rows and the
-- card openings it backs use; the fund is checked to the earliest of those cards, or not at all if any isn't.
create or replace function public.money_checks()
returns jsonb language sql stable security definer set search_path = public as $$
  with hh as (select bh_current_household(false) as id),
  h as (select households.* from households, hh where households.id = hh.id),
  cards as (
    select pm.id, pm.name, pm.currency, pm.is_archived,
           (select max(s.period_end) from statements s where s.payment_method_id = pm.id and s.closed_at is not null) as checked_to
      from payment_methods pm, hh
     where pm.household_id = hh.id and pm.kind = 'credit_card'
  ),
  per as (select * from bh_card_periods((select id from hh))),
  cardx as (
    select c.*, (select count(*)::int from per where per.card_id = c.id and per.ended and not per.covered
                    and c.checked_to is not null and per.period_end < c.checked_to) as open_before,
           exists (select 1 from expenses e, h where e.payment_method_id = c.id and e.deleted_at is null
                     and (h.pot_start is null or e.date >= h.pot_start)) as used
      from cards c
  ),
  fc as (   -- the cards each fund's money sits on, from the start date
    select distinct e.pot_fund_id as fund_id, e.payment_method_id as card_id
      from expenses e join h on h.id = e.household_id join cards c on c.id = e.payment_method_id
     where e.deleted_at is null and e.pot_fund_id is not null and e.trip_id is null and e.category <> 'Payment'
       and (h.pot_start is null or e.counts_on >= h.pot_start)
    union
    select distinct t.fund_id, t.account_payment_method_id
      from fund_transactions t join h on h.id = t.household_id join cards c on c.id = t.account_payment_method_id
     where t.kind <> 'card_payment' and (h.pot_start is null or t.date >= h.pot_start)
    union
    select o.fund_id, o.payment_method_id from card_openings o join cards c on c.id = o.payment_method_id
  )
  select jsonb_build_object(
    'cards', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'currency', currency, 'archived', is_archived,
                                                           'checked_to', checked_to, 'open_before', open_before, 'used', used)
                                        order by is_archived, name) from cardx where used or not is_archived), '[]'),
    'funds', coalesce((select jsonb_agg(jsonb_build_object('fund_id', fund_id, 'checked_to', checked_to, 'unchecked', unchecked))
                         from (select fc.fund_id,
                                      case when bool_and(c.checked_to is not null) then min(c.checked_to) end as checked_to,
                                      coalesce(jsonb_agg(c.name order by c.name) filter (where c.checked_to is null), '[]') as unchecked
                                 from fc join cardx c on c.id = fc.card_id
                                group by fc.fund_id) f), '[]'),
    'unchecked', (select count(*)::int from cardx where used and checked_to is null)
  )
$$;
revoke all on function public.money_checks() from public, anon;
grant execute on function public.money_checks() to authenticated, service_role;

-- ── 5 · how a fund's Available is made ─────────────────────────────────────
-- The same rules as fund_money_asof (the money rule is not restated anywhere else; test_ready_for_paige asserts
-- every part adds up to fund_money, fund by fund): fund rows dated up to today, card payments left out; purchases
-- counted against the fund by their counting date — a fund's own, plus a spending pot's from the start date.
-- This month = the household's month so far; its opening is fund_money as of the day before.
create or replace function public.fund_explain(p_fund uuid)
returns jsonb language sql stable security invoker set search_path = public as $$
  with f as (select f.*, h.pot_start, bh_today(h.id) as today
               from funds f join households h on h.id = f.household_id
              where f.id = p_fund and f.household_id = any (array(select bh_member_of()))),
  ms as (select date_trunc('month', today)::date as d from f),
  rows_ as (
    select t.date, t.type, t.kind, t.amount
      from fund_transactions t, f
     where t.fund_id = f.id and t.date <= f.today and t.kind is distinct from 'card_payment'
  ),
  buys as (
    select de.counts_on, case when de.is_refund then -de.amount else de.amount end as amount
      from expenses de, f
     where de.household_id = f.household_id and de.pot_fund_id = f.id and de.currency = f.currency
       and de.trip_id is null and de.deleted_at is null and de.category <> 'Payment' and de.counts_on <= f.today
       and (de.fund_id = f.id or (f.is_spend_pot and f.pot_start is not null and de.counts_on >= f.pot_start))
  ),
  fm as (select m.balance, m.cash_balance, m.owed_on_cards from fund_money m, f where m.fund_id = f.id),
  op as (select a.balance from f, ms, fund_money_asof(ms.d - 1) a where a.fund_id = f.id)
  select jsonb_build_object(
    'fund_id', f.id, 'currency', f.currency, 'today', f.today, 'month_start', (select d from ms),
    'available', (select balance from fm), 'in_bank', (select cash_balance from fm), 'owed_on_cards', (select owed_on_cards from fm),
    'all', jsonb_build_object(
      'money_in',  (select coalesce(sum(amount), 0) from rows_ where type = 'income'),
      'moved_out', (select coalesce(sum(amount), 0) from rows_ where type = 'expense'),
      'purchases', (select coalesce(sum(amount), 0) from buys),
      'rows', (select count(*) from rows_) + (select count(*) from buys)),
    'month', jsonb_build_object(
      'opening',   coalesce((select balance from op), 0),
      'money_in',  (select coalesce(sum(amount), 0) from rows_, ms where type = 'income' and date >= ms.d),
      'moved_out', (select coalesce(sum(amount), 0) from rows_, ms where type = 'expense' and date >= ms.d),
      'purchases', (select coalesce(sum(amount), 0) from buys, ms where counts_on >= ms.d),
      'rows', (select count(*) from rows_, ms where date >= ms.d) + (select count(*) from buys, ms where counts_on >= ms.d))
  )
  from f
$$;
revoke all on function public.fund_explain(uuid) from public, anon;
grant execute on function public.fund_explain(uuid) to authenticated, service_role;

notify pgrst, 'reload schema';
commit;
