-- Card opening positions (v2 sprint 1, 15 Oct 2026). v2 review: DB-1 F3.
--
-- The app counts a credit card's purchases from the household's pot_start (1 Sep 2026 for the original
-- household). A card that already owed money that day (August purchases on the statement that closes in
-- early September) is paid AFTER pot_start, so paying it in full pushed the card's "owed" and the paying
-- pot's "owed on cards" below zero. The fix is the card's starting position:
--
--   card_openings(card, amount, fund)   what the card owed on pot_start, and which fund's cash stands
--                                       behind it (the money set aside to pay it — usually the spending pot)
--   card_balances.owed                  + opening; payments now count from pot_start, like the purchases
--   fund_cash.cash_balance              + the openings the fund backs, so "owed on cards" includes them
--                                       and paying them brings it back to zero
--
-- Available never changes (asserted): the opening touches the cash view and the card view only.
begin;
create temp table _before as select fund_id, balance from public.fund_balances;

create table if not exists public.card_openings (
  id                uuid primary key default gen_random_uuid(),   -- the activity log keys rows by id
  payment_method_id uuid not null unique references public.payment_methods(id) on delete cascade,
  household_id      uuid not null references public.households(id) on delete cascade,
  fund_id           uuid not null references public.funds(id) on delete restrict,
  amount            numeric(12,2) not null check (amount >= 0),
  note              text check (note is null or length(note) <= 200),
  created_at        timestamptz not null default now(),
  created_by        uuid default auth.uid()
);
create index if not exists card_openings_fund on public.card_openings (fund_id);
alter table public.card_openings enable row level security;
create policy "hh: read"   on public.card_openings for select using (household_id in (select bh_member_of()));
create policy "hh: insert" on public.card_openings for insert with check (household_id in (select bh_writer_of()));
create policy "hh: update" on public.card_openings for update using (household_id in (select bh_writer_of())) with check (household_id in (select bh_writer_of()));
create policy "hh: delete" on public.card_openings for delete using (household_id in (select bh_writer_of()));
revoke all on public.card_openings from public, anon;
grant select, insert, update, delete on public.card_openings to authenticated;
grant all on public.card_openings to service_role;

-- the card is a credit card of the household; the fund is the household's and holds the card's currency
create or replace function public.bh_card_opening_check()
returns trigger language plpgsql set search_path = public as $$
declare v_card payment_methods%rowtype; v_fund funds%rowtype;
begin
  select * into v_card from payment_methods where id = new.payment_method_id;
  select * into v_fund from funds where id = new.fund_id;
  if v_card.id is null or v_card.household_id <> new.household_id then raise exception 'card not found' using errcode = '42501'; end if;
  if v_card.kind <> 'credit_card' then raise exception '% is not a credit card', v_card.name; end if;
  if v_fund.id is null or v_fund.household_id <> new.household_id then raise exception 'fund not found' using errcode = '42501'; end if;
  if v_card.currency is not null and v_fund.currency <> v_card.currency then
    raise exception '% holds %, the card is in % — pick a fund in %', v_fund.name, v_fund.currency, v_card.currency, v_card.currency;
  end if;
  if tg_op = 'INSERT' and current_user in ('authenticated', 'anon') then new.created_by := auth.uid(); end if;
  return new;
end $$;
revoke execute on function public.bh_card_opening_check() from public, anon, authenticated;
drop trigger if exists card_openings_check on public.card_openings;
create trigger card_openings_check before insert or update on public.card_openings
  for each row execute function public.bh_card_opening_check();
drop trigger if exists zzz_card_openings_audit on public.card_openings;
create trigger zzz_card_openings_audit after insert or update or delete on public.card_openings
  for each row execute function public.bh_audit();

-- ── card_balances: + opening; payments counted from pot_start like the purchases ──
create or replace view public.card_balances with (security_invoker = true) as
 SELECT pm.household_id, pm.id AS payment_method_id, pm.name, pm.currency, pm.closing_day, pm.is_archived,
        COALESCE(ch.charges, 0) AS charges, COALESCE(ch.credits, 0) AS credits,
        COALESCE(fr.charges, 0) AS fund_charges, COALESCE(py.paid, 0) AS payments,
        round(COALESCE(op.amount, 0) + COALESCE(ch.charges, 0) - COALESCE(ch.credits, 0) + COALESCE(fr.charges, 0) - COALESCE(py.paid, 0), 2) AS owed,
        py.last_paid,
        COALESCE(op.amount, 0) AS opening
   FROM payment_methods pm
   JOIN households h ON h.id = pm.household_id
   LEFT JOIN card_openings op ON op.payment_method_id = pm.id
   LEFT JOIN LATERAL (
     SELECT sum(e.amount) FILTER (WHERE e.category <> 'Payment' AND NOT e.is_refund) AS charges,
            sum(e.amount) FILTER (WHERE e.category = 'Payment' OR e.is_refund) AS credits
       FROM expenses e
      WHERE e.payment_method_id = pm.id AND e.deleted_at IS NULL AND e.date <= CURRENT_DATE AND (h.pot_start IS NULL OR e.date >= h.pot_start)
   ) ch ON true
   LEFT JOIN LATERAL (
     SELECT sum(CASE WHEN t.type = 'expense' THEN t.amount ELSE -t.amount END) AS charges
       FROM fund_transactions t
      WHERE t.account_payment_method_id = pm.id AND t.kind = 'movement' AND t.date <= CURRENT_DATE AND (h.pot_start IS NULL OR t.date >= h.pot_start)
   ) fr ON true
   LEFT JOIN LATERAL (
     SELECT sum(t.amount) AS paid, max(t.date) AS last_paid
       FROM fund_transactions t
      WHERE t.settles_payment_method_id = pm.id AND t.kind = 'card_payment' AND t.date <= CURRENT_DATE AND (h.pot_start IS NULL OR t.date >= h.pot_start)
   ) py ON true
  WHERE pm.kind = 'credit_card';

-- ── fund_cash: the cash a fund holds includes the opening card debts it backs ──
create or replace view public.fund_cash with (security_invoker = true) as
 SELECT b.household_id, b.fund_id, b.name, b.currency, b.is_active, b.is_spend_pot, b.balance,
        c.cash_balance, round(c.cash_balance - b.balance, 2) AS owed_on_cards
   FROM public.fund_balances b
   JOIN (
     SELECT f.id AS fund_id,
            COALESCE(sum(CASE WHEN t.date > CURRENT_DATE THEN 0::numeric
                              WHEN t.type = 'expense' AND t.kind = 'movement' AND bh_is_credit_card(t.account_payment_method_id) THEN 0::numeric
                              WHEN t.type = 'income' THEN t.amount ELSE - t.amount END), 0::numeric) -
            COALESCE((SELECT sum(CASE WHEN de.is_refund THEN -de.amount ELSE de.amount END) FROM expenses de
                       LEFT JOIN payment_methods pm ON pm.id = de.payment_method_id
                      WHERE de.trip_id IS NULL AND de.deleted_at IS NULL AND de.household_id = f.household_id AND de.currency = f.currency
                        AND de.category <> 'Payment' AND de.date <= CURRENT_DATE AND de.pot_fund_id = f.id
                        AND (de.fund_id = f.id OR (f.is_spend_pot AND h.pot_start IS NOT NULL AND de.date >= h.pot_start))
                        AND coalesce(pm.kind, 'cash') <> 'credit_card'), 0::numeric) +
            COALESCE((SELECT sum(o.amount) FROM card_openings o WHERE o.fund_id = f.id), 0::numeric) AS cash_balance
       FROM funds f
       JOIN households h ON h.id = f.household_id
       LEFT JOIN fund_transactions t ON t.fund_id = f.id
      GROUP BY f.id, h.pot_start
   ) c ON c.fund_id = b.fund_id;

revoke all on public.card_balances, public.fund_cash from anon;
grant select on public.card_balances, public.fund_cash to authenticated, service_role;

-- ── proof: Available did not move ────────────────────────────────────────
do $$
declare v_bad int;
begin
  select count(*) into v_bad from _before b join public.fund_balances a using (fund_id) where abs(a.balance - b.balance) > 0.005;
  if v_bad > 0 then raise exception 'card openings: % fund balances changed', v_bad; end if;
  raise notice 'card openings ok: Available unchanged';
end $$;
drop table _before;
notify pgrst, 'reload schema';
commit;
