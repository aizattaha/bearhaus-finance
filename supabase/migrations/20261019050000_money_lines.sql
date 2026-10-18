-- The whole ledger in one list (Aizat, 18 Oct 2026: "incomes, fund transactions before a certain date, monthly plans,
-- pot swaps and transfers … compiled into one list, so we show the whole picture").
--
-- The Desk's Transactions page read only `expenses` (and hid settle-ups), so nothing in `fund_transactions_all` ever
-- showed: incomes, plan allocations, transfers, pot swaps, card payments, trip sends, and the old "money out of a fund"
-- rows Sort hasn't moved yet (all from before the start date — which is why they looked cut off by date).
--
-- Display only — no money rule changes, no row changes, no write path:
--   money_lines  one row per live ledger row (both tables), one shape: what kind of money event it belongs to
--                (`kind`), the key that ties an event's rows together (`event_key`: a transfer's two sides, a card
--                payment's legs, a pot swap's pairs and bank-pot row, a month's plan), date, currency, amount and its
--                sign for the money, fund, card, category and group, trip, the editor it opens in (`row_kind`).
--                security_invoker: each reader sees only their household's rows (RLS of the tables underneath).
--   ledger_page  the Desk's list: filters (month, kinds, card, fund, category or group, words) applied to the rows,
--                then whole events returned page by page with all their rows, the number of events, and per-currency
--                sums of what matched (spent, income) — the browser only formats.
-- (DA-04's `money_lines`, first step: a reporting shape. Rebuilding the money views on it is not part of this.)

begin;

create or replace view public.money_lines with (security_invoker = true) as
  -- purchases, refunds, settle-ups, trip lines
  select e.household_id, 'expense'::text as src, e.id,
         case when e.trip_id is null then 'daily' else 'travel' end as row_kind,
         case when e.category = 'Payment' then 'settle_up'
              when e.trip_id is not null then 'trip'
              when e.is_refund then 'refund' else 'purchase' end as kind,
         'e:' || e.id::text as event_key,
         e.date, e.counts_on, e.currency, e.amount,
         case when e.is_refund then e.amount else -e.amount end as signed,
         coalesce(e.fund_id, e.pot_fund_id) as fund_id, e.fund_id as named_fund_id,
         e.payment_method_id, e.category_id, c.group_id, e.trip_id,
         e.description, e.category as category_name, e.comments, e.payer_profile_id,
         e.reconciled_at, e.reconciled_by, e.is_refund, e.refund_of, e.refunded, e.pot_swap_id,
         null::text as type, null::text as ledger_kind, null::uuid as transfer_group_id, e.created_at
    from public.expenses e
    left join public.categories c on c.id = e.category_id
   where e.deleted_at is null
  union all
  -- the fund ledger: one kind per row, decided by what the row is (not its remark text)
  select t.household_id, 'fund', t.id, 'fund',
         case when t.kind = 'card_payment' then 'card_payment'
              when t.trip_id is not null then 'trip_send'
              when sw.id is not null then 'pot_swap'
              when t.origin = 'planned' then 'plan'
              when t.transfer_group_id is not null then 'transfer'
              when t.kind = 'movement' and t.type = 'income' then 'income'
              when t.kind = 'movement' then 'money_out'
              else 'allocation' end,
         case when t.kind = 'card_payment' then 'g:' || coalesce(t.transfer_group_id, t.id)::text
              when t.trip_id is not null then 'f:' || t.id::text
              when sw.id is not null then 's:' || sw.id::text
              when t.origin = 'planned' then 'p:' || to_char(t.date, 'YYYY-MM')
              when t.transfer_group_id is not null then 'g:' || t.transfer_group_id::text
              else 'f:' || t.id::text end,
         t.date, t.date, f.currency, t.amount,
         case when t.type = 'income' then t.amount else -t.amount end,
         t.fund_id, null::uuid,
         coalesce(t.account_payment_method_id, t.settles_payment_method_id), null::uuid, null::uuid, t.trip_id,
         t.remarks, null::text, null::text, null::uuid,
         t.reconciled_at, t.reconciled_by, false, null::uuid, null::numeric, sw.id,
         t.type, t.kind, t.transfer_group_id, t.created_at
    from public.fund_transactions_all t
    join public.funds f on f.id = t.fund_id
    left join lateral (select s.id from public.pot_swaps s
                        where s.household_id = t.household_id
                          and (s.dst_group_id = t.transfer_group_id or s.src_group_id = t.transfer_group_id or s.spend_tx_id = t.id)
                        limit 1) sw on true
   where t.deleted_at is null;

-- ── the Desk's list ──────────────────────────────────────────────────────
-- p_card: a card id, or 'none' (purchases on no card) · p_fund: a fund id (its purchases and its fund rows), 'any'
-- (purchases paid from a fund) or 'budget' (purchases counted against the month's budget) · p_cat: 'c:<category id>'
-- or 'g:<group id>' · p_kinds: any of purchase refund settle_up trip income money_out allocation plan transfer
-- pot_swap card_payment trip_send (null = all). An event shows when any of its rows matches, with all its rows.
create or replace function public.ledger_page(p_month date default null, p_kinds text[] default null, p_card text default null,
                                              p_fund text default null, p_cat text default null, p_search text default null,
                                              p_limit integer default 100, p_offset integer default 0)
returns jsonb
language plpgsql stable set search_path = public as $$
declare v_hh uuid; v_from date; v_to date; v_out jsonb; v_lim int := least(greatest(coalesce(p_limit, 100), 1), 500);
begin
  v_hh := bh_current_household(false);
  if v_hh is null then return null; end if;
  if p_month is not null then v_from := date_trunc('month', p_month)::date; v_to := (v_from + interval '1 month')::date; end if;
  with m as (
    select l.* from money_lines l
     where l.household_id = v_hh
       and (v_from is null or (l.date >= v_from and l.date < v_to))
       and (p_kinds is null or l.kind = any(p_kinds))
       and (p_card is null or p_card = '' or (p_card = 'none' and l.src = 'expense' and l.payment_method_id is null)
            or (p_card <> 'none' and l.payment_method_id::text = p_card))
       and (p_fund is null or p_fund = ''
            or (p_fund = 'any' and l.named_fund_id is not null)
            or (p_fund = 'budget' and l.kind in ('purchase', 'refund') and l.named_fund_id is null)
            or (p_fund not in ('any', 'budget') and l.fund_id::text = p_fund))
       and (p_cat is null or p_cat = ''
            or (p_cat like 'c:%' and l.category_id::text = substr(p_cat, 3))
            or (p_cat like 'g:%' and l.group_id::text = substr(p_cat, 3)))
       and (p_search is null or p_search = '' or l.description ilike '%' || p_search || '%')
  ), ev as (
    select event_key, min(date) as d, max(created_at) as c from m group by event_key
  ), pg as (
    select * from ev order by d desc, c desc, event_key limit v_lim offset greatest(coalesce(p_offset, 0), 0)
  ), legs as (
    -- every row of the page's events (a matching row may have partners the filter didn't match); an event's rows sit
    -- within a month of each other, which keeps the read on the household/date index
    select l.* from money_lines l
     where l.household_id = v_hh
       and l.date >= (select min(d) from pg) - 31 and l.date <= (select max(d) from pg) + 31
       and l.event_key in (select event_key from pg)
  )
  select jsonb_build_object(
    'total', (select count(*) from ev),
    'sums', coalesce((select jsonb_agg(jsonb_build_object('currency', s.currency, 'spent', s.spent, 'income', s.income) order by s.currency)
                        from (select currency,
                                     -sum(signed) filter (where kind in ('purchase', 'refund', 'trip')) as spent,
                                     sum(amount) filter (where kind = 'income') as income
                                from m group by currency) s), '[]'),
    'events', coalesce((select jsonb_agg(e order by (e->>'date') desc, e->>'c' desc, e->>'key')
      from (select jsonb_build_object(
                     'key', pg.event_key, 'date', pg.d, 'c', pg.c,
                     'kind', (select l.kind from legs l where l.event_key = pg.event_key limit 1),
                     -- per currency: what moved (a transfer's one side, a card payment's legs, a plan's top-ups) and
                     -- the net for the money (0 for a transfer)
                     'amounts', (select jsonb_agg(jsonb_build_object('currency', a.currency, 'amount', a.moved, 'net', a.net) order by a.currency)
                                   from (select l.currency, greatest(sum(l.amount) filter (where l.signed > 0), sum(l.amount) filter (where l.signed < 0), 0) as moved,
                                                sum(l.signed) as net
                                           from legs l where l.event_key = pg.event_key group by l.currency) a),
                     'legs', (select jsonb_agg(jsonb_build_object(
                                'src', l.src, 'id', l.id, 'row', l.row_kind, 'kind', l.kind, 'date', l.date, 'currency', l.currency,
                                'amount', l.amount, 'signed', l.signed, 'fund_id', l.fund_id, 'named_fund_id', l.named_fund_id,
                                'payment_method_id', l.payment_method_id, 'category_id', l.category_id, 'trip_id', l.trip_id,
                                'description', l.description, 'category', l.category_name, 'comments', l.comments, 'payer_profile_id', l.payer_profile_id,
                                'fund_name', (select f.name from funds f where f.id = l.fund_id),
                                'trip_name', (select t.name from trips t where t.id = l.trip_id),
                                'reconciled_at', l.reconciled_at, 'reconciled_by', l.reconciled_by, 'is_refund', l.is_refund,
                                'refund_of', l.refund_of, 'refunded', l.refunded, 'pot_swap_id', l.pot_swap_id, 'type', l.type)
                                order by l.signed, l.currency, l.id)
                                from legs l where l.event_key = pg.event_key)) as e
              from pg) x), '[]')
  ) into v_out;
  return v_out;
end $$;

-- ── grants (rule 7): readable and runnable by a signed-in login, nothing for the public key ──
revoke all on public.money_lines from public, anon;
grant select on public.money_lines to authenticated, service_role;
revoke execute on function public.ledger_page(date, text[], text, text, text, text, integer, integer) from public, anon;
grant execute on function public.ledger_page(date, text[], text, text, text, text, integer, integer) to authenticated, service_role;

notify pgrst, 'reload schema';
commit;
