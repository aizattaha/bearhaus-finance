-- Refunds against the purchase (Aizat, 17 Oct 2026 — DECISIONS E35).
--
--  1 · A refund names the purchase it belongs to (expenses.refund_of), all of it or a part: a big purchase for many
--        people can have part of it come back. refund_purchases(items, date, via, note) is the one way to make one:
--        via 'card' = back on the card or account it was paid with (the statement shows the credit; the card owes
--        less); via 'cash' = a bank transfer or cash into the fund the purchase counted against, while the card still
--        owes the full charge until it is paid.
--  2 · The purchase keeps its full amount (it still matches the card statement); expenses.refunded is the sum of
--        its live refunds (kept by the server), and the apps grey it out / show "refunded" from it.
--  3 · Budget and funds count only what was used, in the purchase's own month, category and pot: every row has a
--        counting date (expenses.counts_on — its own date, or its purchase's date for a linked refund), and the
--        sums (fund_money, budget_summary, home_summary, pot_month_spend) count by it. Cards and statements still
--        count a refund on its own date, as the bank does.
--  4 · A linked refund follows its purchase (category, fund, pot, trip, counting date). Refunds can't come to more
--        than the purchase; a refunded purchase can't shrink below its refunds, change currency or trip, or go to
--        the bin before its refunds do. Deleting a refund (the bin) undoes it.
--  5 · Refunds entered the old way (a separate refund line, not linked) keep counting as before — Aizat deletes
--        each once its purchase is refunded the new way. The nightly check counts them (info).
--
-- No number moves today (asserted): nothing is linked yet, so every row counts on its own date as before.
begin;
create temp table _r_money on commit drop as select fund_id, balance, cleared_balance, pending_spend, cash_balance, owed_on_cards from public.fund_money;
create temp table _r_card on commit drop as select payment_method_id, owed, unsettled from public.card_balances;
create temp table _r_stmt on commit drop as select statement_id, reconciled_total, due, paid, status from public.statement_balances;
create temp table _r_pots on commit drop as select id, pot_fund_id, updated_at from public.expenses;

-- ── 1 · the columns ─────────────────────────────────────────────────────
alter table public.expenses add column if not exists refund_of uuid references public.expenses(id) on delete cascade;
alter table public.expenses add column if not exists refunded numeric(12,2) not null default 0;
alter table public.expenses add column if not exists counts_on date;
alter table public.expenses disable trigger user;   -- a plain backfill of a derived column: no Activity, no stamps
update public.expenses set counts_on = date where counts_on is distinct from date;
alter table public.expenses enable trigger user;
alter table public.expenses alter column counts_on set not null;
create index if not exists expenses_refund_of on public.expenses (refund_of) where refund_of is not null;
-- the money sums now count by counts_on: the covering index follows (same columns, plus the purchase's own date)
drop index if exists public.expenses_hh_money;
create index expenses_hh_money on public.expenses (household_id, counts_on)
  include (date, pot_fund_id, currency, category_id, category, amount, is_refund, fund_id, payment_method_id, reconciled_at)
  where trip_id is null and deleted_at is null;

-- the compat views carry the new columns (appended)
create or replace view public.travel_expenses with (security_invoker = true) as
  select id, household_id, trip_id, date, description, category, amount, currency, payer_profile_id, paid_with, comments,
         sent_to_fund, legacy_sync_id, created_at, payment_method_id, reconciled_at, reconciled_statement_id, reconciled_by, pot_swap_id, updated_at,
         pot_fund_id, created_by, updated_by, category_id, is_refund, fund_id, settled_amount, settlement_tx_id, sent_amount,
         refund_of, refunded, counts_on
    from public.expenses where trip_id is not null and deleted_at is null
  with cascaded check option;
create or replace view public.daily_expenses with (security_invoker = true) as
  select id, household_id, date, description, category, amount, currency, payer_profile_id, paid_with, comments,
         legacy_sync_id, created_at, payment_method_id, reconciled_at, reconciled_statement_id, reconciled_by, pot_swap_id, updated_at,
         pot_fund_id, created_by, updated_by, category_id, is_refund, fund_id, settled_amount,
         refund_of, refunded, counts_on
    from public.expenses where trip_id is null and deleted_at is null
  with cascaded check option;

-- what the server keeps in step is not an edit (no Activity line, no "changed" stamp)
create or replace function public.bh_derived_only(p_table text, p_old jsonb, p_new jsonb)
returns boolean language sql immutable set search_path = public as $$
  select (p_old - s.k) = (p_new - s.k)
    from (select array['updated_at', 'updated_by', 'created_at'] || case p_table
                   when 'expenses'              then array['kind', 'pot_fund_id', 'category', 'paid_with', 'settlement_tx_id', 'sent_amount', 'refunded', 'counts_on']
                   when 'categories'            then array['group_name']
                   when 'category_budgets'      then array['category_group']
                   when 'fund_transactions_all' then array['trip_id']
                   else array[]::text[] end as k) s
$$;
revoke execute on function public.bh_derived_only(text, jsonb, jsonb) from public, anon;
grant execute on function public.bh_derived_only(text, jsonb, jsonb) to authenticated, service_role;

-- ── 2 · server-owned ────────────────────────────────────────────────────
create or replace function public.bh_expense_client_guard()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then return new; end if;
  if tg_op = 'INSERT' then
    new.reconciled_at := null; new.reconciled_by := null; new.reconciled_statement_id := null;   -- cash re-ticks itself next
    new.deleted_at := null;
    new.pot_fund_id := null;                                                                     -- stamped by the server
    new.settlement_tx_id := null; new.sent_amount := null;                                       -- set by the trip send
    new.settled_amount := null;                                                                  -- set from the statement
    new.refund_of := null; new.refunded := 0;                                                    -- refund_purchases only
    new.created_by := auth.uid();
  else
    new.created_by := old.created_by;
    new.deleted_at := old.deleted_at;
    new.pot_fund_id := old.pot_fund_id;                                                          -- re-stamped when its inputs change
    new.settlement_tx_id := old.settlement_tx_id;
    new.sent_amount := old.sent_amount;
    new.settled_amount := old.settled_amount;
    new.refund_of := old.refund_of;
    new.refunded := old.refunded;
  end if;
  return new;
end $$;

-- ── 3 · a refund follows its purchase ───────────────────────────────────
-- runs after the client guard (b0) and before the name↔id sync (bx): a linked refund takes its purchase's category,
-- fund, trip and counting date; every other row counts on its own date
create or replace function public.bh_expense_refund_follow()
returns trigger language plpgsql set search_path = public as $$
declare o expenses%rowtype;
begin
  if new.refund_of is null then new.counts_on := new.date; return new; end if;
  select * into o from expenses where id = new.refund_of;
  if o.id is null or o.household_id <> new.household_id then raise exception 'that purchase isn''t in this household' using errcode = 'P0001'; end if;
  if o.refund_of is not null or o.is_refund then raise exception 'a refund can only be against a purchase' using errcode = 'P0001'; end if;
  if o.deleted_at is not null and new.deleted_at is null then raise exception 'restore “%” first — this is its refund', o.description using errcode = 'P0001'; end if;
  if not new.is_refund then raise exception 'this is a refund of “%” — delete it instead', o.description using errcode = 'P0001'; end if;
  if new.currency is distinct from o.currency then raise exception 'a refund is in its purchase''s currency (%)', o.currency using errcode = 'P0001'; end if;
  new.category_id := o.category_id; new.category := o.category; new.fund_id := o.fund_id; new.trip_id := o.trip_id;
  new.counts_on := o.date;
  return new;
end $$;
revoke execute on function public.bh_expense_refund_follow() from public, anon, authenticated;
drop trigger if exists bw_expenses_refund on public.expenses;
create trigger bw_expenses_refund before insert or update on public.expenses for each row execute function public.bh_expense_refund_follow();

-- the pot: a refund counts where its purchase counts
create or replace function public.bh_expense_stamp_pot()
returns trigger language plpgsql as $$
begin
  if new.refund_of is not null then
    new.pot_fund_id := (select o.pot_fund_id from expenses o where o.id = new.refund_of);
    return new;
  end if;
  if tg_op = 'INSERT' or new.fund_id is distinct from old.fund_id or new.category_id is distinct from old.category_id
     or new.category is distinct from old.category or new.currency is distinct from old.currency
     or new.date is distinct from old.date or new.trip_id is distinct from old.trip_id or new.household_id is distinct from old.household_id then
    new.pot_fund_id := coalesce(new.fund_id, expense_pot_for(new.household_id, new.trip_id, new.category_id, new.category, new.currency, new.date));
  end if;
  return new;
end $$;

-- after a write: a purchase's refunded total, the refunds' limit, and refunds re-following a changed purchase
create or replace function public.bh_expense_refunds_sync()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_sum numeric; v_amt numeric; v_desc text;
begin
  -- a refund written, changed, binned or restored: its purchase's refunded total, which may not pass the purchase
  if (tg_op <> 'INSERT' and old.refund_of is not null) or (tg_op <> 'DELETE' and new.refund_of is not null) then
    for v_id in select distinct x from unnest(array[case when tg_op <> 'INSERT' then old.refund_of end,
                                                    case when tg_op <> 'DELETE' then new.refund_of end]) x where x is not null loop
      select coalesce(sum(r.amount), 0) into v_sum from expenses r where r.refund_of = v_id and r.deleted_at is null;
      select amount, description into v_amt, v_desc from expenses where id = v_id;
      if v_sum > v_amt + 0.005 then
        raise exception 'refunds would come to more than “%” — at most % can come back', v_desc, to_char(v_amt, 'FM999999990.00') using errcode = 'P0001';
      end if;
      update expenses set refunded = v_sum where id = v_id and refunded is distinct from v_sum;
    end loop;
  end if;
  if tg_op = 'UPDATE' and new.refund_of is null and new.refunded > 0 then
    -- a refunded purchase: not below its refunds, same currency and trip, and not in the bin before them
    if new.amount + 0.005 < new.refunded then
      raise exception '“%” has % refunded — the amount can''t go below that', new.description, to_char(new.refunded, 'FM999999990.00') using errcode = 'P0001';
    end if;
    if new.currency is distinct from old.currency or new.trip_id is distinct from old.trip_id then
      raise exception '“%” has refunds — delete them before changing its currency or trip', new.description using errcode = 'P0001';
    end if;
    if new.deleted_at is not null and old.deleted_at is null then
      raise exception '“%” has refunds — delete them first', new.description using errcode = 'P0001';
    end if;
    -- its refunds re-follow it (category, fund, pot, counting date)
    if (new.date, new.category_id, new.fund_id, new.pot_fund_id) is distinct from (old.date, old.category_id, old.fund_id, old.pot_fund_id) then
      update expenses set counts_on = counts_on where refund_of = new.id;
    end if;
  end if;
  return null;
end $$;
revoke execute on function public.bh_expense_refunds_sync() from public, anon, authenticated;
drop trigger if exists zzb_expenses_refunds on public.expenses;
create trigger zzb_expenses_refunds after insert or update or delete on public.expenses for each row execute function public.bh_expense_refunds_sync();

-- re-filing leaves refunds to follow their purchase (the trigger above does it, set-based here for the rest)
create or replace function public.restamp_pots(p_hh uuid, p_from date default null, p_to date default null, p_cur text default null)
returns integer language plpgsql security definer set search_path = public as $$
declare v_n integer; v_r integer;
begin
  with dp as (
    select distinct on (currency) currency, id from funds
     where household_id = p_hh and is_spend_pot and is_active
     order by currency, sort_order, id
  ), lines as (
    select distinct on (c.id, cb.currency, cb.month) c.id as category_id, cb.currency, cb.month, cb.pot_fund_id
      from category_budgets cb
      join categories c on c.group_id = cb.category_group_id
      join funds f on f.id = cb.pot_fund_id and f.household_id = p_hh and f.is_spend_pot and f.currency = cb.currency
     where cb.household_id = p_hh and cb.pot_fund_id is not null
       and (p_cur is null or cb.currency = p_cur)
       and (p_from is null or cb.month >= date_trunc('month', p_from)::date) and (p_to is null or cb.month < p_to)
     order by c.id, cb.currency, cb.month, cb.id
  ), want as (   -- only the rows whose pot actually changes
    select x.id, x.pot from (
      select e.id, e.pot_fund_id as now_pot,
             coalesce(e.fund_id, case when e.category <> 'Payment' then coalesce(l.pot_fund_id, dp.id) end) as pot
        from expenses e
        left join lines l on l.category_id = e.category_id and l.currency = e.currency and l.month = date_trunc('month', e.date)::date
        left join dp on dp.currency = e.currency
       where e.household_id = p_hh and e.trip_id is null and e.refund_of is null
         and (p_from is null or e.date >= p_from) and (p_to is null or e.date < p_to)
         and (p_cur is null or e.currency = p_cur)) x
     where x.now_pot is distinct from x.pot
  )
  update expenses e set pot_fund_id = w.pot
    from want w
   where e.id = w.id and e.household_id = p_hh;
  get diagnostics v_n = row_count;
  -- a refund sits in its purchase's pot
  update expenses r set pot_fund_id = o.pot_fund_id
    from expenses o
   where r.refund_of = o.id and r.household_id = p_hh and r.pot_fund_id is distinct from o.pot_fund_id;
  get diagnostics v_r = row_count;
  return v_n + v_r;
end $$;
revoke execute on function public.restamp_pots(uuid, date, date, text) from public, anon, authenticated;
grant execute on function public.restamp_pots(uuid, date, date, text) to service_role;

-- ── 4 · making a refund ─────────────────────────────────────────────────
-- p_items: [{"id": <purchase>, "amount": <optional; default what is left>}]; p_via 'card' (back on the card or
-- account it was paid with) or 'cash' (a bank transfer or cash, into the fund the purchase counted against)
create or replace function public.refund_purchases(p_items jsonb, p_date date, p_via text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_hh uuid; it record; o expenses%rowtype; v_left numeric; v_amt numeric; v_new uuid; v_out jsonb := '[]';
  v_cash uuid; v_kind text; v_before numeric; v_after numeric; v_want numeric; v_counts boolean; v_pot_start date;
  v_prev text := coalesce(current_setting('bh.allow_archived', true), '');
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  if p_via not in ('card', 'cash') then raise exception 'say how the money came back: on the card, or as a transfer or cash' using errcode = 'P0001'; end if;
  if p_date is null then raise exception 'pick the date the money came back' using errcode = 'P0001'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'pick what was refunded' using errcode = 'P0001'; end if;
  select id into v_cash from payment_methods where household_id = v_hh and kind = 'cash' and not is_archived order by sort_order limit 1;
  select pot_start into v_pot_start from households where id = v_hh;
  for it in select (x->>'id')::uuid as id,
                   case when jsonb_typeof(x->'amount') = 'number' then (x->>'amount')::numeric end as amount
              from jsonb_array_elements(p_items) x loop
    select * into o from expenses where id = it.id and household_id = v_hh and deleted_at is null for update;
    if o.id is null then raise exception 'purchase not found — pull down to refresh' using errcode = 'P0001'; end if;
    if o.is_refund or o.refund_of is not null then raise exception '“%” is itself a refund', o.description using errcode = 'P0001'; end if;
    if o.category = 'Payment' then raise exception '“%” is a settle-up, not a purchase', o.description using errcode = 'P0001'; end if;
    if p_date < o.date then raise exception 'a refund can''t come back before “%” was bought', o.description using errcode = 'P0001'; end if;
    v_left := o.amount - o.refunded;
    v_amt := round(coalesce(it.amount, v_left), 2);
    if v_amt <= 0 then raise exception '“%” is already fully refunded', o.description using errcode = 'P0001'; end if;
    if v_amt > v_left + 0.005 then
      raise exception 'only % of “%” is left to refund', to_char(v_left, 'FM999999990.00'), o.description using errcode = 'P0001';
    end if;
    select kind into v_kind from payment_methods where id = o.payment_method_id;
    if p_via = 'card' and (o.payment_method_id is null or v_kind = 'cash') then
      raise exception '“%” wasn''t paid by card — choose transfer or cash', o.description using errcode = 'P0001';
    end if;
    -- the fund the purchase counts against moves by what comes back, once it counts (on or before today; a spending
    -- pot from its start date; a trip line only when its trip is sent)
    v_counts := o.trip_id is null and o.pot_fund_id is not null and o.date <= bh_today(v_hh)
                and (o.fund_id is not null or (v_pot_start is not null and o.date >= v_pot_start));
    select balance into v_before from fund_balances where fund_id = o.pot_fund_id;
    perform set_config('bh.allow_archived', 'on', true);   -- the card it was paid with, even if archived since
    insert into expenses (household_id, trip_id, date, description, category_id, category, amount, currency, payer_profile_id,
                          payment_method_id, paid_with, comments, is_refund, fund_id, refund_of)
    values (v_hh, o.trip_id, p_date, left('Refund · ' || o.description, 200), o.category_id, o.category, v_amt, o.currency,
            case when p_via = 'card' then o.payer_profile_id end,
            case when p_via = 'card' then o.payment_method_id else v_cash end,
            case when p_via = 'card' then o.paid_with else '' end,
            trim(coalesce(p_note, '')), true, o.fund_id, o.id)
    returning id into v_new;
    perform set_config('bh.allow_archived', v_prev, true);
    select balance into v_after from fund_balances where fund_id = o.pot_fund_id;
    v_want := case when v_counts then v_amt else 0 end;
    if o.pot_fund_id is not null and abs(coalesce(v_after, 0) - coalesce(v_before, 0) - v_want) > 0.005 then
      raise exception 'refund: the fund moved by the wrong amount — nothing saved';
    end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object('id', v_new, 'of', o.id, 'amount', v_amt));
  end loop;
  return v_out;
end $$;
revoke execute on function public.refund_purchases(jsonb, date, text, text) from public, anon;
grant execute on function public.refund_purchases(jsonb, date, text, text) to authenticated, service_role;

-- ── 5 · the sums count by counts_on ─────────────────────────────────────
-- fund_money_asof as in 20261019000000, the purchases' part counting by counts_on
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
     and de.counts_on <= coalesce(p_asof, (now() at time zone h.timezone)::date)
     and (de.fund_id = f.id or (f.is_spend_pot and h.pot_start is not null and de.counts_on >= h.pot_start))
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
), st as (   -- trip sends: what their purchases on credit cards in the fund's currency took, since the start date
  select a.fund_id, sum(case when e.is_refund then -e.sent_amount else e.sent_amount end) as share
    from public.fund_transactions a
    join public.funds f on f.id = a.fund_id
    join public.households h on h.id = f.household_id
    join public.expenses e on e.settlement_tx_id = a.id and e.deleted_at is null and e.sent_amount is not null
    join public.payment_methods pm on pm.id = e.payment_method_id and pm.kind = 'credit_card' and pm.currency = f.currency
   where a.kind = 'allocation' and a.date <= coalesce(p_asof, (now() at time zone h.timezone)::date)
     and (h.pot_start is null or e.date >= h.pot_start)
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

create or replace function public.pot_month_spend(p_fund uuid)
 RETURNS TABLE(month date, amount numeric, n integer, last_date date)
 LANGUAGE sql STABLE SET search_path TO 'public'
AS $function$
  select date_trunc('month', de.counts_on)::date as month,
         sum(case when de.is_refund then -de.amount else de.amount end) as amount,
         count(*)::int as n, max(de.counts_on) as last_date
    from expenses de
    join funds f on f.id = p_fund and f.household_id = de.household_id
    join households h on h.id = f.household_id
   where de.trip_id is null and de.deleted_at is null
     and de.currency = f.currency and de.category <> 'Payment'
     and de.counts_on <= (now() at time zone h.timezone)::date and de.pot_fund_id = f.id
     and (de.fund_id = f.id or (f.is_spend_pot and h.pot_start is not null and de.counts_on >= h.pot_start))
   group by 1 order by 1 desc
$function$;
revoke execute on function public.pot_month_spend(uuid) from public, anon;
grant execute on function public.pot_month_spend(uuid) to authenticated, service_role;

-- home_summary and budget_summary as in 20261017000000, counting by counts_on (a linked refund in its purchase's month)
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
                        from (select e.counts_on as date, e.currency, sum(case when e.is_refund then -e.amount else e.amount end) as amount
                                from expenses e
                               where e.household_id = v_hh and e.trip_id is null and e.deleted_at is null and e.fund_id is null
                                 and e.category <> 'Payment' and e.counts_on between v_today - 6 and v_today
                               group by e.counts_on, e.currency) w), '[]'),
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
                                         and e.category <> 'Payment' and e.counts_on between v_month and v_today
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
    select date_trunc('month', e.counts_on)::date as month, e.category_id, max(e.category) as name,
           e.fund_id is not null as from_fund, e.counts_on > v_today as later,
           sum(case when e.is_refund then -e.amount else e.amount end) as amount, count(*)::int as n
      from expenses e
     where e.household_id = v_hh and e.trip_id is null and e.deleted_at is null and e.currency = p_currency
       and e.category <> 'Payment' and e.counts_on >= v_from and e.counts_on < v_to
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

-- ── 6 · the nightly check knows refunds ─────────────────────────────────
create or replace function public.bh_money_check()
returns table (check_name text, severity text, bad integer)
language sql stable security definer set search_path = public as $$
  select 'integrity issues noted in the last day', 'fail',
         (select count(*)::int from integrity_issues where noted_at > now() - interval '26 hours')
  union all
  select 'fund purchases in another currency or on a trip', 'fail',
         (select count(*)::int from expenses e join funds f on f.id = e.fund_id
           where e.deleted_at is null and (e.currency <> f.currency or e.trip_id is not null))
  union all
  select 'months with plan rows but no apply record', 'fail',
         (select count(*)::int from (select distinct household_id, date_trunc('month', date)::date as m from fund_transactions where origin = 'planned') x
           where not exists (select 1 from plan_applications a where a.household_id = x.household_id and a.month = x.m))
  union all
  select 'trip sends that don''t equal their purchases', 'fail',
         (select count(*)::int from fund_transactions a
           where a.trip_id is not null and a.kind = 'allocation'
             and exists (select 1 from expenses e where e.settlement_tx_id = a.id and e.deleted_at is null)
             and not exists (select 1 from expenses e where e.settlement_tx_id = a.id and e.deleted_at is null and e.sent_amount is null)
             and abs((case when a.type = 'income' then -a.amount else a.amount end)
                     - (select coalesce(sum(case when e.is_refund then -e.sent_amount else e.sent_amount end), 0)
                          from expenses e where e.settlement_tx_id = a.id and e.deleted_at is null)) >= 0.005)
  union all
  select 'sent purchases out of step with their send', 'fail',
         (select count(*)::int from expenses e
           where e.settlement_tx_id is not null and e.deleted_at is null
             and (not e.sent_to_fund
                  or not exists (select 1 from fund_transactions a where a.id = e.settlement_tx_id)
                  or e.sent_amount is not null and exists (select 1 from payment_methods c join fund_transactions a on a.id = e.settlement_tx_id join funds f on f.id = a.fund_id
                              where c.id = e.payment_method_id and c.kind = 'credit_card' and c.currency is not null and c.currency <> f.currency)))
  union all
  select 'refunds that come to more than their purchase', 'fail',
         (select count(*)::int from expenses o where o.refund_of is null and o.deleted_at is null and o.refunded > o.amount + 0.005)
       + (select count(*)::int from expenses o
           where o.refund_of is null and abs(o.refunded - coalesce((select sum(r.amount) from expenses r where r.refund_of = o.id and r.deleted_at is null), 0)) >= 0.005)
  union all
  select 'refunds that don''t count where their purchase counts', 'fail',
         (select count(*)::int from expenses r join expenses o on o.id = r.refund_of
           where r.deleted_at is null and (r.counts_on <> o.date or r.pot_fund_id is distinct from o.pot_fund_id
                                           or r.category_id is distinct from o.category_id or r.fund_id is distinct from o.fund_id or not r.is_refund))
  union all
  select 'transfer and card-payment groups that don''t hold together', 'warn',
         (select count(*)::int from (select distinct transfer_group_id as g from fund_transactions_all where transfer_group_id is not null) x
           where bh_group_problem(x.g) is not null)
  union all
  select 'purchases since the start date not filed to a pot', 'warn',
         (select count(*)::int from expenses e join households h on h.id = e.household_id
           where e.trip_id is null and e.deleted_at is null and e.category <> 'Payment' and h.pot_start is not null and e.date >= h.pot_start
             and not exists (select 1 from funds f where f.id = e.pot_fund_id and f.currency = e.currency and (f.is_spend_pot or f.id = e.fund_id)))
  union all
  select 'purchases whose who-paid lines don''t match the amount', 'warn',
         (select count(*)::int from expenses e
           where e.deleted_at is null and (
                 coalesce((select sum(s.amount) from expense_splits s where s.expense_id = e.id and s.profile_id is null), 0)
                   <> -(case when e.is_refund then -e.amount else e.amount end)
              or coalesce((select sum(s.amount) from expense_splits s where s.expense_id = e.id and s.profile_id is not null), 0)
                   <> case when e.payer_profile_id is null then 0 else (case when e.is_refund then -e.amount else e.amount end) end))
  union all
  select 'rows with a negative amount', 'warn',
         (select count(*)::int from expenses where amount < 0 and deleted_at is null)
       + (select count(*)::int from fund_transactions where amount < 0)
  union all
  select 'statements that overlap on one card', 'warn',
         (select count(*)::int from statements a join statements b
             on a.payment_method_id = b.payment_method_id and a.id < b.id and a.period_start <= b.period_end and b.period_start <= a.period_end)
  union all
  select 'cards owed less than zero', 'warn', (select count(*)::int from card_balances where owed < -0.005)
  union all
  select 'funds owing less than zero on cards', 'warn', (select count(*)::int from fund_cash where owed_on_cards < -0.005)
  union all
  select 'trip sends left for a person (no purchase explains them, or an old rate can''t be read)', 'warn',
         (select count(*)::int from fund_transactions a
           where a.trip_id is not null and a.kind = 'allocation'
             and (not exists (select 1 from expenses e where e.settlement_tx_id = a.id and e.deleted_at is null)
                  or exists (select 1 from expenses e where e.settlement_tx_id = a.id and e.deleted_at is null and e.sent_amount is null)))
  union all
  select 'refunds entered the old way (not linked to a purchase)', 'info',
         (select count(*)::int from expenses where is_refund and refund_of is null and deleted_at is null)
  union all
  select 'foreign purchases on cards waiting for the charged amount', 'info', (select coalesce(sum(unsettled), 0)::int from card_balances)
$$;
revoke execute on function public.bh_money_check() from public, anon, authenticated;
grant execute on function public.bh_money_check() to service_role;

-- ── proof: no number moves ──────────────────────────────────────────────
do $$
declare v_bad int; v_n int;
begin
  select count(*) into v_n from public.expenses where refund_of is not null;
  if v_n > 0 then raise exception 'refunds: % linked refunds already exist — this migration expects none', v_n; end if;
  select count(*) into v_bad from public.expenses where counts_on is distinct from date;
  if v_bad > 0 then raise exception 'refunds: % rows count on another day than their own', v_bad; end if;
  select count(*) into v_bad from _r_money b full join public.fund_money a using (fund_id)
   where (a.balance, a.cleared_balance, a.pending_spend, a.cash_balance, a.owed_on_cards)
         is distinct from (b.balance, b.cleared_balance, b.pending_spend, b.cash_balance, b.owed_on_cards);
  if v_bad > 0 then raise exception 'refunds: % funds'' numbers changed', v_bad; end if;
  select count(*) into v_bad from _r_card b full join public.card_balances a using (payment_method_id)
   where (a.owed, a.unsettled) is distinct from (b.owed, b.unsettled);
  if v_bad > 0 then raise exception 'refunds: % cards changed', v_bad; end if;
  select count(*) into v_bad from _r_stmt b full join public.statement_balances a using (statement_id)
   where (a.reconciled_total, a.due, a.paid, a.status) is distinct from (b.reconciled_total, b.due, b.paid, b.status);
  if v_bad > 0 then raise exception 'refunds: % statements changed', v_bad; end if;
  select count(*) into v_bad from _r_pots b join public.expenses e using (id)
   where e.pot_fund_id is distinct from b.pot_fund_id or e.updated_at is distinct from b.updated_at;
  if v_bad > 0 then raise exception 'refunds: % purchases changed pot or were stamped as edited', v_bad; end if;
  select count(*) into v_n from public.expenses where is_refund and refund_of is null and deleted_at is null;
  raise notice 'refunds ok: no number moved; % refunds entered the old way stay as they are until deleted', v_n;
end $$;
notify pgrst, 'reload schema';
commit;
