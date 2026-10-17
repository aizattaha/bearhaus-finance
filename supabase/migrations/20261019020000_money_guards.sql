-- Money guards (Review Board round 1, Bundle A — DECISIONS E36). Before Aizat closes any statement.
--
--  A1 · Owed on cards stops at the start date. A fund's "In the bank" and "Owed on cards" counted every credit-card
--        purchase or card-charged fund row as owed, whatever its date, while the card itself counts only from
--        households.pot_start (what it owed before that is its opening, backed by one fund). So a fund purchase on a
--        card before the start was owed for ever, and a still-unpaid one was counted twice. Now, before the start
--        date, everything a fund spent left the bank when it was bought, and a card payment from then is outside the
--        app's era (as on the card). Available doesn't move; In the bank and Owed move for funds with such rows.
--        bh_owed_gaps() ties the two sides together: what the cards owe = what the funds owe, apart from the lines
--        only one side counts (a trip line not yet sent, a settle-up on a card, a purchase in another currency, a
--        purchase not filed to a pot). The nightly check fails if they ever drift apart. The Desk's two Sort moves
--        now assert In the bank and Owed too, not only Available.
--  A2 · A purchase that has refunds can't be switched into a refund (every number moved by twice the purchase).
--  A3 · A card payment without a statement settles the card's oldest saved statement that ended before it and isn't
--        paid yet; link_card_payment() lets the Desk link (or unlink) a payment the phone saved earlier.
--  A4 · A card's type or currency can't change once it has purchases, payments, statements or an opening
--        (it rewrote the card's whole history); cards_in_use() tells the phone which selects to grey out.
--  A5 · record_card_payment and refund_purchases take p_id, as record_transfer does: a retap answers "already saved".
--  A6 · The app login can no longer hard-delete purchases or fund rows (the bin, the trip-send lock and the
--        refunds-first rule are the only ways out); a sent purchase can't be deleted even by a server path that
--        forgot the lock; the nightly check sees a purchase whose send has gone.
begin;
create temp table _g_money on commit drop as select fund_id, balance, cleared_balance, pending_spend, cash_balance, owed_on_cards from public.fund_money;
create temp table _g_card on commit drop as select payment_method_id, owed, unsettled from public.card_balances;
create temp table _g_stmt on commit drop as select statement_id, reconciled_total, due, paid, status from public.statement_balances;

-- ── A1 · the rule: card owed only from the start date ──────────────────
create or replace function public.fund_money_asof(p_asof date)
returns table (household_id uuid, fund_id uuid, name text, country text, currency text, is_active boolean, sort_order integer,
               group_name text, is_leftover_target boolean, is_spend_pot boolean, icon text, balance numeric, cleared_balance numeric,
               pending_spend numeric, cash_balance numeric, owed_on_cards numeric)
language sql stable as $$
with fg as (
  select t.fund_id, t.account_payment_method_id as pm_id, t.type, t.kind,
         t.date > coalesce(p_asof, (now() at time zone h.timezone)::date) as later, t.reconciled_at is not null as ticked,
         coalesce(t.date < h.pot_start, false) as early, sum(t.amount) as amount
    from public.fund_transactions t
    join public.funds f on f.id = t.fund_id
    join public.households h on h.id = f.household_id
   group by 1, 2, 3, 4, 5, 6, 7
), fr as (
  -- In the bank: before the start date a card-charged row left the bank when it happened, and a card payment from
  -- then is outside the app's era (the card's opening holds what was still owed); from the start date the card owes
  select fg.fund_id,
         sum(case when fg.later or fg.kind = 'card_payment' then 0 when fg.type = 'income' then fg.amount else -fg.amount end) as avail,
         sum(case when fg.later or not fg.ticked or fg.kind = 'card_payment' then 0 when fg.type = 'income' then fg.amount else -fg.amount end) as cleared,
         sum(case when fg.later then 0
                  when fg.kind = 'card_payment' and fg.early then 0
                  when fg.type = 'expense' and fg.kind <> 'card_payment' and pm.kind = 'credit_card' and not fg.early then 0
                  when fg.type = 'income' then fg.amount else -fg.amount end) as cash
    from fg left join public.payment_methods pm on pm.id = fg.pm_id
   group by fg.fund_id
), eg as (
  select de.pot_fund_id as fund_id, de.payment_method_id as pm_id, de.reconciled_at is not null as ticked,
         coalesce(de.date < h.pot_start, false) as early,
         sum(case when de.is_refund then -de.amount else de.amount end) as amount
    from public.expenses de
    join public.funds f on f.id = de.pot_fund_id and f.household_id = de.household_id and f.currency = de.currency
    join public.households h on h.id = f.household_id
   where de.trip_id is null and de.deleted_at is null and de.category <> 'Payment'
     and de.counts_on <= coalesce(p_asof, (now() at time zone h.timezone)::date)
     and (de.fund_id = f.id or (f.is_spend_pot and h.pot_start is not null and de.counts_on >= h.pot_start))
   group by 1, 2, 3, 4
), ex as (
  select eg.fund_id, sum(eg.amount) as spend,
         sum(eg.amount) filter (where eg.ticked) as spend_cleared,
         sum(eg.amount) filter (where not eg.ticked) as spend_pending,
         -- left the bank: anything not on a credit card, and card purchases dated before the start date (as on the card)
         sum(eg.amount) filter (where coalesce(pm.kind, 'cash') <> 'credit_card' or eg.early) as spend_cash
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

-- ── A1 · cards and funds agree on what is owed ─────────────────────────
-- Per household and currency: what the credit cards owe (card_balances) minus what the funds say they owe on cards
-- (fund_money), less the lines only one side counts. gap must be 0. A line both sides count is matched by its id; a
-- line counted in one currency by the card and another by the fund (a purchase in another currency) is one-sided in
-- each. One-sided lines are legitimate today: a trip line not sent yet, a pot-swapped trip line, a settle-up
-- ("Payment") on a card, a purchase in another currency than its card, a purchase filed to no pot, a card with no
-- currency. A drift between the two rules — what DH-01 was — shows as a gap. Counts only leave this function
-- through bh_money_check; the amounts are for tests and the local stack.
create or replace function public.bh_owed_gaps()
returns table (household_id uuid, currency text, cards_owe numeric, funds_owe numeric, card_only numeric, fund_only numeric, gap numeric)
language sql stable security definer set search_path = public as $$
with hh as (
  select h.id, h.pot_start as ps, (now() at time zone h.timezone)::date as today from households h
), cl as (   -- purchases as the card counts them: its currency, from the start date to today
  select e.id, e.household_id, pm.currency as cur,
         case when e.category = 'Payment' or e.is_refund then -1 else 1 end
           * coalesce(case when e.currency = pm.currency then e.amount else e.settled_amount end, 0) as val
    from expenses e
    join payment_methods pm on pm.id = e.payment_method_id and pm.kind = 'credit_card' and pm.currency is not null
    join hh on hh.id = e.household_id
   where e.deleted_at is null and e.date <= hh.today and (hh.ps is null or e.date >= hh.ps)
), fl as (   -- purchases a fund counts as owed on a card: in the purchase's currency, from the start date
  select e.id, e.household_id, e.currency as cur, case when e.is_refund then -e.amount else e.amount end as val
    from expenses e
    join payment_methods pm on pm.id = e.payment_method_id and pm.kind = 'credit_card'
    join funds fu on fu.id = e.pot_fund_id and fu.household_id = e.household_id and fu.currency = e.currency
    join hh on hh.id = e.household_id
   where e.trip_id is null and e.deleted_at is null and e.category <> 'Payment' and e.counts_on <= hh.today
     and (e.fund_id = fu.id or (fu.is_spend_pot and hh.ps is not null and e.counts_on >= hh.ps))
     and (hh.ps is null or e.date >= hh.ps)
  union all  -- a sent trip line on a card: its send's share, in the card's currency
  select e.id, e.household_id, fu.currency, case when e.is_refund then -e.sent_amount else e.sent_amount end
    from expenses e
    join fund_transactions a on a.id = e.settlement_tx_id and a.kind = 'allocation'
    join funds fu on fu.id = a.fund_id
    join payment_methods pm on pm.id = e.payment_method_id and pm.kind = 'credit_card' and pm.currency = fu.currency
    join hh on hh.id = fu.household_id
   where e.deleted_at is null and e.sent_amount is not null and a.date <= hh.today and (hh.ps is null or e.date >= hh.ps)
), cr as (   -- fund rows as the card counts them: money-out (and in) charged to it, and its payments
  select t.id, t.household_id, pm.currency as cur, case when t.type = 'expense' then t.amount else -t.amount end as val
    from fund_transactions t
    join payment_methods pm on pm.id = t.account_payment_method_id and pm.kind = 'credit_card' and pm.currency is not null
    join hh on hh.id = t.household_id
   where t.kind = 'movement' and t.date <= hh.today and (hh.ps is null or t.date >= hh.ps)
     and not exists (select 1 from pot_swaps s where s.spend_tx_id = t.id)
  union all
  select t.id, t.household_id, pm.currency, -t.amount
    from fund_transactions t
    join payment_methods pm on pm.id = t.settles_payment_method_id and pm.kind = 'credit_card' and pm.currency is not null
    join hh on hh.id = t.household_id
   where t.kind = 'card_payment' and t.date <= hh.today and (hh.ps is null or t.date >= hh.ps)
), fw as (   -- fund rows as the funds count them on cards, from the start date
  select t.id, t.household_id, fu.currency as cur,
         case when t.kind = 'card_payment' then (case when t.type = 'income' then t.amount else -t.amount end) else t.amount end as val
    from fund_transactions t
    join funds fu on fu.id = t.fund_id
    left join payment_methods pm on pm.id = t.account_payment_method_id
    join hh on hh.id = t.household_id
   where t.date <= hh.today and (hh.ps is null or t.date >= hh.ps)
     and (t.kind = 'card_payment' or (t.type = 'expense' and pm.kind = 'credit_card'))
), lines as (
  select coalesce(cl.household_id, fl.household_id) as household_id, cl.cur as ccur, fl.cur as fcur, cl.val as cval, fl.val as fval
    from cl full join fl on fl.id = cl.id
  union all
  select coalesce(cr.household_id, fw.household_id), cr.cur, fw.cur, cr.val, fw.val
    from cr full join fw on fw.id = cr.id
  union all   -- a card's opening: on the card, and on the fund that backs it
  select o.household_id, pm.currency, fu.currency, o.amount, o.amount
    from card_openings o join payment_methods pm on pm.id = o.payment_method_id join funds fu on fu.id = o.fund_id
), one as (
  select household_id, ccur as cur, sum(cval) as card_only, 0::numeric as fund_only
    from lines where ccur is not null and fcur is distinct from ccur group by 1, 2
  union all
  select household_id, fcur, 0, sum(fval) from lines where fcur is not null and ccur is distinct from fcur group by 1, 2
), c as (
  select b.household_id, b.currency, sum(b.owed) as owed from card_balances b where b.currency is not null group by 1, 2
), f as (
  select m.household_id, m.currency, sum(m.owed_on_cards) as owed from fund_money m group by 1, 2
), o as (
  select household_id, cur, sum(card_only) as card_only, sum(fund_only) as fund_only from one group by 1, 2
), k as (
  select household_id, currency from c union select household_id, currency from f union select household_id, cur from o
)
select k.household_id, k.currency, coalesce(c.owed, 0), coalesce(f.owed, 0), coalesce(o.card_only, 0), coalesce(o.fund_only, 0),
       round(coalesce(c.owed, 0) - coalesce(f.owed, 0) - coalesce(o.card_only, 0) + coalesce(o.fund_only, 0), 2)
  from k
  left join c on c.household_id = k.household_id and c.currency = k.currency
  left join f on f.household_id = k.household_id and f.currency = k.currency
  left join o on o.household_id = k.household_id and o.cur = k.currency
$$;
revoke execute on function public.bh_owed_gaps() from public, anon, authenticated;
grant execute on function public.bh_owed_gaps() to service_role;

-- ── A1 · the Sort moves keep In the bank and Owed honest too ────────────
-- a row "owes on a card" when it is on a credit card and dated from the start date (before it, it left the bank)
create or replace function public.bh_on_card_owed(p_hh uuid, p_card uuid, p_date date)
returns boolean language sql stable set search_path = public as $$
  select coalesce((select pm.kind = 'credit_card' from payment_methods pm where pm.id = p_card), false)
     and coalesce((select h.pot_start is null or p_date >= h.pot_start from households h where h.id = p_hh), true)
$$;
revoke execute on function public.bh_on_card_owed(uuid, uuid, date) from public, anon, authenticated;

-- before/after of one fund's three numbers around a move; In the bank may move only by what the card change says
create or replace function public.bh_assert_move(p_hh uuid, p_fund uuid, p_date date, p_amount numeric, p_old_card uuid, p_new_card uuid,
                                                 p_before public.fund_money, p_what text)
returns void language plpgsql stable set search_path = public as $$
declare a public.fund_money; v_want numeric := 0;
begin
  select * into a from fund_money where fund_id = p_fund;
  if p_date <= bh_today(p_hh) then
    v_want := (case when bh_on_card_owed(p_hh, p_new_card, p_date) then 0 else -p_amount end)
            - (case when bh_on_card_owed(p_hh, p_old_card, p_date) then 0 else -p_amount end);
  end if;
  if abs(a.balance - p_before.balance) > 0.005 then
    raise exception 'moving “%” would change the fund''s Available — stopped, nothing changed', p_what using errcode = 'P0001';
  end if;
  if abs(a.cash_balance - p_before.cash_balance - v_want) > 0.005 or abs(a.owed_on_cards - p_before.owed_on_cards - v_want) > 0.005 then
    raise exception 'moving “%” would change the fund''s In the bank or Owed on cards the wrong way — stopped, nothing changed', p_what using errcode = 'P0001';
  end if;
end $$;
revoke execute on function public.bh_assert_move(uuid, uuid, date, numeric, uuid, uuid, public.fund_money, text) from public, anon, authenticated;

-- fund movement → purchase (same id, date, amount; reconciliation marks carried)
create or replace function public.move_fund_spend_to_expenses(p_ids uuid[], p_category text, p_payment_method uuid default null)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_hh uuid; r record; v_n int := 0; v_before fund_money; v_card payment_methods%rowtype;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  if coalesce(trim(p_category), '') = '' then raise exception 'pick a category' using errcode = 'P0001'; end if;
  if p_payment_method is not null then
    select * into v_card from payment_methods where id = p_payment_method and household_id = v_hh;
    if v_card.id is null then raise exception 'card not found' using errcode = 'P0001'; end if;
  end if;
  perform set_config('bh.via_rpc', 'on', true);
  for r in select t.*, f.currency as fund_currency, f.name as fund_name from fund_transactions_all t join funds f on f.id = t.fund_id
            where t.household_id = v_hh and t.id = any(p_ids) and t.kind = 'movement' and t.type = 'expense' and t.deleted_at is null
              and not exists (select 1 from pot_swaps ps where ps.spend_tx_id = t.id) loop
    if v_card.id is not null and v_card.currency is not null and v_card.currency <> r.fund_currency then
      raise exception '% is in %, % is in % — pick a card in the fund''s currency or no card', v_card.name, v_card.currency, r.fund_name, r.fund_currency using errcode = 'P0001';
    end if;
    select * into v_before from fund_money where fund_id = r.fund_id;
    update fund_transactions_all set reconciled_at = null, reconciled_by = null, reconciled_statement_id = null where id = r.id;
    delete from fund_transactions_all where id = r.id;
    insert into expenses (id, household_id, date, description, category, amount, currency, payer_profile_id, payment_method_id, paid_with, comments,
                          fund_id, created_at, created_by, reconciled_at, reconciled_by, reconciled_statement_id, is_refund)
    values (r.id, v_hh, r.date, coalesce(nullif(r.remarks, ''), 'Fund spend'), p_category, r.amount, r.fund_currency, null, p_payment_method,
            coalesce(v_card.name, ''), 'moved from ' || r.fund_name || ' movements on ' || to_char(now(), 'DD Mon YYYY'),
            r.fund_id, r.created_at, r.created_by,
            case when r.reconciled_by = 'manual' then r.reconciled_at end, case when r.reconciled_by = 'manual' then 'manual' end, r.reconciled_statement_id, false);
    perform bh_assert_move(v_hh, r.fund_id, r.date, r.amount, r.account_payment_method_id, p_payment_method, v_before, coalesce(nullif(r.remarks, ''), 'Fund spend'));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke execute on function public.move_fund_spend_to_expenses(uuid[], text, uuid) from public, anon;
grant execute on function public.move_fund_spend_to_expenses(uuid[], text, uuid) to authenticated, service_role;

-- purchase → fund movement (the way back; only for rows that name a fund); p_cards can restore the original card
create or replace function public.move_expense_to_fund_spend(p_ids uuid[], p_cards jsonb default null)
returns integer language plpgsql security definer set search_path = public as $$
declare v_hh uuid; r record; v_n int := 0; v_before fund_money; v_card uuid;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  perform set_config('bh.via_rpc', 'on', true);
  for r in select * from expenses where household_id = v_hh and id = any(p_ids) and fund_id is not null and deleted_at is null loop
    if r.reconciled_statement_id is not null and exists (select 1 from statements where id = r.reconciled_statement_id and closed_at is not null) then
      raise exception '“%” is on a closed statement — reopen it first', r.description using errcode = 'P0001';
    end if;
    if r.refund_of is not null or exists (select 1 from expenses x where x.refund_of = r.id) then   -- live or in the bin
      raise exception '“%” has a refund linked to it — it stays a purchase', r.description using errcode = 'P0001';
    end if;
    v_card := r.payment_method_id;
    if p_cards is not null and p_cards ? r.id::text then
      v_card := nullif(p_cards ->> r.id::text, '')::uuid;
      if v_card is not null and not exists (select 1 from payment_methods where id = v_card and household_id = v_hh) then
        raise exception 'card not found' using errcode = 'P0001';
      end if;
    end if;
    select * into v_before from fund_money where fund_id = r.fund_id;
    update expenses set reconciled_at = null, reconciled_by = null, reconciled_statement_id = null where id = r.id;
    delete from expenses where id = r.id;
    insert into fund_transactions_all (id, household_id, fund_id, type, kind, date, amount, remarks, origin, created_at, created_by,
                                       account_payment_method_id, reconciled_at, reconciled_by, reconciled_statement_id)
    values (r.id, v_hh, r.fund_id, 'expense', 'movement', r.date, r.amount, r.description, 'manual', r.created_at, r.created_by,
            v_card, case when r.reconciled_by = 'manual' then r.reconciled_at end, case when r.reconciled_by = 'manual' then 'manual' end, r.reconciled_statement_id);
    perform bh_assert_move(v_hh, r.fund_id, r.date, r.amount, r.payment_method_id, v_card, v_before, r.description);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke execute on function public.move_expense_to_fund_spend(uuid[], jsonb) from public, anon;
grant execute on function public.move_expense_to_fund_spend(uuid[], jsonb) to authenticated, service_role;

-- ── A2 · a purchase with refunds stays a purchase ──────────────────────
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
    -- a refunded purchase: stays a purchase, not below its refunds, same currency and trip, not in the bin before them
    if new.is_refund is distinct from old.is_refund then
      raise exception '“%” has refunds — it can''t become a refund itself (delete its refunds first)', new.description using errcode = 'P0001';
    end if;
    if new.amount + 0.005 < new.refunded then
      raise exception '“%” has % refunded — the amount can''t go below that', new.description, to_char(new.refunded, 'FM999999990.00') using errcode = 'P0001';
    end if;
    if new.currency is distinct from old.currency or new.trip_id is distinct from old.trip_id then
      raise exception '“%” has refunds — delete them before changing its currency or trip', new.description using errcode = 'P0001';
    end if;
    if new.deleted_at is not null and old.deleted_at is null then
      raise exception '“%” has refunds — delete them first', new.description using errcode = 'P0001';
    end if;
    if (new.date, new.category_id, new.fund_id, new.pot_fund_id) is distinct from (old.date, old.category_id, old.fund_id, old.pot_fund_id) then
      update expenses set counts_on = counts_on where refund_of = new.id;
    end if;
  end if;
  return null;
end $$;
revoke execute on function public.bh_expense_refunds_sync() from public, anon, authenticated;

-- ── A3 + A5 · card payments: linked to their statement, safe to retap ────
drop function if exists public.record_card_payment(uuid, date, jsonb, uuid, text);
create or replace function public.record_card_payment(
  p_card uuid, p_date date, p_legs jsonb, p_statement uuid default null, p_remarks text default null, p_id uuid default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_hh uuid; v_card payment_methods%rowtype; v_stmt statements%rowtype; v_sid uuid := p_statement;
  v_group uuid := coalesce(p_id, gen_random_uuid()); v_leg record; v_fund funds%rowtype; v_tag text;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  if exists (select 1 from fund_transactions_all where transfer_group_id = v_group) then
    if exists (select 1 from fund_transactions_all where transfer_group_id = v_group and household_id = v_hh and kind = 'card_payment') then
      return v_group;   -- a retap: already saved
    end if;
    raise exception 'that payment id is taken';
  end if;
  select * into v_card from payment_methods where id = p_card and household_id = v_hh;
  if v_card.id is null then raise exception 'card not found' using errcode = 'P0001'; end if;
  if v_card.kind <> 'credit_card' then raise exception '% is not a credit card', v_card.name using errcode = 'P0001'; end if;
  if p_date is null then raise exception 'enter the payment date' using errcode = 'P0001'; end if;
  if jsonb_typeof(p_legs) <> 'array' or jsonb_array_length(p_legs) = 0 then raise exception 'say which fund pays' using errcode = 'P0001'; end if;
  if v_sid is null then
    -- no statement named (the phone): the card's oldest saved statement that ended before this payment and isn't paid yet
    select b.statement_id into v_sid from statement_balances b
     where b.payment_method_id = p_card and b.household_id = v_hh and b.period_end < p_date
       and coalesce(b.paid, 0) + coalesce(b.scheduled, 0) + 0.005 < b.due
     order by b.period_end limit 1;
  end if;
  if v_sid is not null then
    select * into v_stmt from statements where id = v_sid and household_id = v_hh;
    if v_stmt.id is null then raise exception 'statement not found' using errcode = 'P0001'; end if;
    if v_stmt.payment_method_id <> p_card then raise exception 'that statement belongs to another card' using errcode = 'P0001'; end if;
  end if;
  -- the remark always starts with "Paid <card>" so every list reads the same; a note or the statement follows
  v_tag := 'Paid ' || v_card.name || case
             when nullif(trim(p_remarks), '') is not null then ' · ' || trim(p_remarks)
             when v_stmt.id is not null then ' · statement ' || to_char(v_stmt.period_start, 'DD Mon') || ' – ' || to_char(v_stmt.period_end, 'DD Mon YYYY')
             else '' end;
  for v_leg in select (x->>'fund_id')::uuid as fund_id, (x->>'amount')::numeric as amount from jsonb_array_elements(p_legs) x loop
    if v_leg.amount is null or v_leg.amount <= 0 then raise exception 'each amount must be more than zero' using errcode = 'P0001'; end if;
    select * into v_fund from funds where id = v_leg.fund_id and household_id = v_hh and is_active;
    if v_fund.id is null then raise exception 'fund not found' using errcode = 'P0001'; end if;
    if v_card.currency is not null and v_fund.currency <> v_card.currency then
      raise exception '% is in %, the card is in % — pay it from a fund in %', v_fund.name, v_fund.currency, v_card.currency, v_card.currency using errcode = 'P0001';
    end if;
    insert into fund_transactions (household_id, fund_id, type, kind, date, amount, remarks, origin,
                                   transfer_group_id, settles_payment_method_id, settles_statement_id)
    values (v_hh, v_fund.id, 'expense', 'card_payment', p_date, round(v_leg.amount, 2), v_tag, 'manual', v_group, p_card, v_stmt.id);
  end loop;
  return v_group;
end $$;
revoke execute on function public.record_card_payment(uuid, date, jsonb, uuid, text, uuid) from public, anon;
grant execute on function public.record_card_payment(uuid, date, jsonb, uuid, text, uuid) to authenticated, service_role;

-- link a saved card payment to a statement of the same card, or unlink it (null) — every leg moves together
create or replace function public.link_card_payment(p_group uuid, p_statement uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare v_hh uuid; v_card uuid; v_n int;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  select max(settles_payment_method_id::text)::uuid into v_card from fund_transactions
   where transfer_group_id = p_group and household_id = v_hh and kind = 'card_payment';
  if v_card is null then raise exception 'payment not found — refresh' using errcode = 'P0001'; end if;
  if p_statement is not null and not exists (select 1 from statements where id = p_statement and household_id = v_hh and payment_method_id = v_card) then
    raise exception 'that statement belongs to another card' using errcode = 'P0001';
  end if;
  update fund_transactions_all set settles_statement_id = p_statement
   where transfer_group_id = p_group and household_id = v_hh and kind = 'card_payment' and deleted_at is null
     and settles_statement_id is distinct from p_statement;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke execute on function public.link_card_payment(uuid, uuid) from public, anon;
grant execute on function public.link_card_payment(uuid, uuid) to authenticated, service_role;

-- ── A5 · refunds: safe to retap ────────────────────────────────────────
-- p_id names the first refund row; the others take ids derived from it, so a retap finds them all
drop function if exists public.refund_purchases(jsonb, date, text, text);
create or replace function public.refund_purchases(p_items jsonb, p_date date, p_via text, p_note text default null, p_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_hh uuid; it record; o expenses%rowtype; v_left numeric; v_amt numeric; v_new uuid; v_out jsonb := '[]';
  v_cash uuid; v_kind text; v_before numeric; v_after numeric; v_want numeric; v_counts boolean; v_pot_start date;
  v_prev text := coalesce(current_setting('bh.allow_archived', true), '');
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  if p_id is not null and exists (select 1 from expenses where id = p_id) then
    if exists (select 1 from expenses where id = p_id and household_id = v_hh and refund_of is not null) then   -- a retap: already saved
      select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'of', e.refund_of, 'amount', e.amount) order by x.n), '[]') into v_out
        from generate_series(1, greatest(jsonb_array_length(coalesce(p_items, '[]')), 1)) x(n)
        join expenses e on e.id = case when x.n = 1 then p_id else md5(p_id::text || ':' || x.n)::uuid end and e.household_id = v_hh;
      return v_out;
    end if;
    raise exception 'that refund id is taken';
  end if;
  if p_via not in ('card', 'cash') then raise exception 'say how the money came back: on the card, or as a transfer or cash' using errcode = 'P0001'; end if;
  if p_date is null then raise exception 'pick the date the money came back' using errcode = 'P0001'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'pick what was refunded' using errcode = 'P0001'; end if;
  select id into v_cash from payment_methods where household_id = v_hh and kind = 'cash' and not is_archived order by sort_order limit 1;
  select pot_start into v_pot_start from households where id = v_hh;
  for it in select (x.v->>'id')::uuid as id, x.n,
                   case when jsonb_typeof(x.v->'amount') = 'number' then (x.v->>'amount')::numeric end as amount
              from jsonb_array_elements(p_items) with ordinality x(v, n) loop
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
    insert into expenses (id, household_id, trip_id, date, description, category_id, category, amount, currency, payer_profile_id,
                          payment_method_id, paid_with, comments, is_refund, fund_id, refund_of)
    values (case when p_id is null then gen_random_uuid() when it.n = 1 then p_id else md5(p_id::text || ':' || it.n)::uuid end,
            v_hh, o.trip_id, p_date, left('Refund · ' || o.description, 200), o.category_id, o.category, v_amt, o.currency,
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
revoke execute on function public.refund_purchases(jsonb, date, text, text, uuid) from public, anon;
grant execute on function public.refund_purchases(jsonb, date, text, text, uuid) to authenticated, service_role;

-- ── A4 · a card with history keeps its type and currency ───────────────
create or replace function public.bh_card_in_use(p_card uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from expenses where payment_method_id = p_card)
      or exists (select 1 from fund_transactions_all where account_payment_method_id = p_card or settles_payment_method_id = p_card)
      or exists (select 1 from statements where payment_method_id = p_card)
      or exists (select 1 from card_openings where payment_method_id = p_card)
$$;
revoke execute on function public.bh_card_in_use(uuid) from public, anon, authenticated;

create or replace function public.bh_card_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- bh.card_change is for a deliberate, server-side re-derivation (E32), never the apps
  if (new.kind is distinct from old.kind or new.currency is distinct from old.currency)
     and coalesce(current_setting('bh.card_change', true), '') <> 'on' and bh_card_in_use(old.id) then
    raise exception '% already has purchases, payments or statements — its type and currency stay as they are (add a new card and archive this one)', old.name
      using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke execute on function public.bh_card_guard() from public, anon, authenticated;
drop trigger if exists b0_card_guard on public.payment_methods;
create trigger b0_card_guard before update on public.payment_methods for each row execute function public.bh_card_guard();

-- which of the caller's cards have history (the phone greys out their type and currency)
create or replace function public.cards_in_use()
returns setof uuid language sql stable security definer set search_path = public as $$
  select pm.id from payment_methods pm where pm.household_id = any (array(select bh_member_of())) and bh_card_in_use(pm.id)
$$;
revoke execute on function public.cards_in_use() from public, anon;
grant execute on function public.cards_in_use() to authenticated, service_role;

-- ── A6 · no hard deletes from the app login ────────────────────────────
revoke delete on public.expenses, public.daily_expenses, public.travel_expenses, public.fund_transactions, public.fund_transactions_all
  from authenticated;
drop policy if exists "hh: delete" on public.expenses;
drop policy if exists "hh: delete" on public.fund_transactions_all;

-- a sent purchase stays as it was sent until the send is undone — and isn't deleted either (the bin's purge only
-- removes binned rows, and a sent purchase can't be binned)
create or replace function public.bh_expense_sent_lock()
returns trigger language plpgsql set search_path = public as $$
declare v_fund text;
begin
  if tg_op = 'DELETE' then
    if old.settlement_tx_id is not null and old.deleted_at is null then
      select f.name into v_fund from fund_transactions_all a join funds f on f.id = a.fund_id where a.id = old.settlement_tx_id;
      raise exception 'this purchase was sent to % — undo that send on the trip first', coalesce(v_fund, 'a trip fund') using errcode = 'P0001';
    end if;
    return old;
  end if;
  if coalesce(current_setting('bh.via_rpc', true), '') = 'on' then return new; end if;
  if old.settlement_tx_id is not null and (
       new.amount is distinct from old.amount or new.currency is distinct from old.currency
    or new.payment_method_id is distinct from old.payment_method_id or new.is_refund is distinct from old.is_refund
    or new.trip_id is distinct from old.trip_id or new.household_id is distinct from old.household_id
    or new.deleted_at is distinct from old.deleted_at or new.sent_to_fund is distinct from old.sent_to_fund
    or new.settled_amount is distinct from old.settled_amount or new.pot_swap_id is distinct from old.pot_swap_id) then
    select f.name into v_fund from fund_transactions_all a join funds f on f.id = a.fund_id where a.id = old.settlement_tx_id;
    raise exception 'this purchase was sent to % — undo that send on the trip first', coalesce(v_fund, 'a trip fund') using errcode = 'P0001';
  end if;
  if old.pot_swap_id is not null and new.pot_swap_id is not distinct from old.pot_swap_id and new.sent_to_fund is distinct from old.sent_to_fund then
    raise exception 'this purchase is settled by a pot swap — undo the swap first' using errcode = 'P0001';
  end if;
  return new;
end $$;
revoke execute on function public.bh_expense_sent_lock() from public, anon, authenticated;
drop trigger if exists expenses_sent_lock on public.expenses;
create trigger expenses_sent_lock before update or delete on public.expenses for each row execute function public.bh_expense_sent_lock();

-- ── the nightly check: the new fail lines ──────────────────────────────
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
           where e.deleted_at is null
             and (e.settlement_tx_id is not null and (
                    not e.sent_to_fund
                    or not exists (select 1 from fund_transactions a where a.id = e.settlement_tx_id)
                    or e.sent_amount is not null and exists (select 1 from payment_methods c join fund_transactions a on a.id = e.settlement_tx_id join funds f on f.id = a.fund_id
                                where c.id = e.payment_method_id and c.kind = 'credit_card' and c.currency is not null and c.currency <> f.currency))
                  -- a send that was deleted outright leaves its purchases marked with what they took
                  or e.settlement_tx_id is null and e.sent_amount is not null))
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
  select 'purchases with refunds that are themselves refunds', 'fail',
         (select count(*)::int from expenses o
           where o.refund_of is null and o.is_refund
             and (o.refunded > 0 or exists (select 1 from expenses r where r.refund_of = o.id and r.deleted_at is null)))
  union all
  select 'funds and cards that disagree on what is owed', 'fail',
         (select count(*)::int from bh_owed_gaps() g where abs(g.gap) >= 0.005)
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
  select 'card payments not linked to a statement', 'info',
         (select count(distinct transfer_group_id)::int from fund_transactions where kind = 'card_payment' and settles_statement_id is null)
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

-- ── proof: what moved, and only that (counts only) ─────────────────────
do $$
declare v_bad int; v_moved int; v_gaps int;
begin
  select count(*) into v_bad from _g_money b full join public.fund_money a using (fund_id)
   where (a.balance, a.cleared_balance, a.pending_spend) is distinct from (b.balance, b.cleared_balance, b.pending_spend);
  if v_bad > 0 then raise exception 'money guards: % funds'' Available, cleared or pending changed', v_bad; end if;
  select count(*) into v_bad from _g_money b join public.fund_money a using (fund_id)
   where abs((a.cash_balance - b.cash_balance) - (a.owed_on_cards - b.owed_on_cards)) > 0.005;
  if v_bad > 0 then raise exception 'money guards: % funds'' In the bank and Owed moved apart', v_bad; end if;
  select count(*) into v_moved from _g_money b join public.fund_money a using (fund_id) where a.cash_balance is distinct from b.cash_balance;
  select count(*) into v_bad from _g_card b full join public.card_balances a using (payment_method_id)
   where (a.owed, a.unsettled) is distinct from (b.owed, b.unsettled);
  if v_bad > 0 then raise exception 'money guards: % cards changed', v_bad; end if;
  select count(*) into v_bad from _g_stmt b full join public.statement_balances a using (statement_id)
   where (a.reconciled_total, a.due, a.paid, a.status) is distinct from (b.reconciled_total, b.due, b.paid, b.status);
  if v_bad > 0 then raise exception 'money guards: % statements changed', v_bad; end if;
  select count(*) into v_gaps from public.bh_owed_gaps() where abs(gap) >= 0.005;
  raise notice 'money guards ok: % funds'' In the bank and Owed moved (pre-start card rows), Available and cards unchanged; % household-currencies where cards and funds disagree', v_moved, v_gaps;
end $$;
notify pgrst, 'reload schema';
commit;
