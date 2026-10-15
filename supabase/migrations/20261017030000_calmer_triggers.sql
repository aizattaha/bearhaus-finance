-- Calmer triggers (v2 sprint 3, chunk 4; D2-11).
--
--  1 · Re-filing purchases to their pot is one set-based statement (no per-row function calls) and touches only
--      rows whose pot actually changes. A fund change re-files only when the fund is (or was) a spending pot,
--      and only in that currency; reordering or archiving any other fund re-files nothing.
--  2 · Budget lines re-file once per statement, only for lines that name their own pot and only when the pot,
--      group, currency or month changed — an amount change re-files nothing.
--  3 · Saving the month's plan changes only the lines that changed (it used to delete and rewrite the month,
--      which re-filed every purchase twice and filled the Activity log).
--  4 · A change the server copies into a row — the pot stamp, a category or card name copied after a rename — is
--      not an edit: it writes no Activity line and leaves updated_at / updated_by alone, so an edit open on the
--      other phone isn't refused as "changed elsewhere".
--
-- No balance moves (asserted).
begin;
create temp table _b_fund as select fund_id, balance from public.fund_balances;
create temp table _b_pots as select id, pot_fund_id from public.expenses;

-- ── 4 · what counts as an edit ──────────────────────────────────────────
-- true when two versions of a row differ only in columns the server keeps in step itself
create or replace function public.bh_derived_only(p_table text, p_old jsonb, p_new jsonb)
returns boolean language sql immutable set search_path = public as $$
  select (p_old - s.k) = (p_new - s.k)
    from (select array['updated_at', 'updated_by', 'created_at'] || case p_table
                   when 'expenses'         then array['pot_fund_id', 'category', 'paid_with']   -- the stamp; name copies of the ids
                   when 'categories'       then array['group_name']
                   when 'category_budgets' then array['category_group']
                   else array[]::text[] end as k) s
$$;
revoke execute on function public.bh_derived_only(text, jsonb, jsonb) from public, anon;
grant execute on function public.bh_derived_only(text, jsonb, jsonb) to authenticated, service_role;   -- the touch/by triggers run as the writer

create or replace function public.bh_touch_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'UPDATE' and public.bh_derived_only(tg_table_name, to_jsonb(old), to_jsonb(new)) then
    new.updated_at := old.updated_at;   -- re-filed or renamed by the server: not an edit
  else
    new.updated_at := now();
  end if;
  return new;
end $$;

create or replace function public.bh_stamp_by()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := coalesce(new.created_by, auth.uid()); new.updated_by := coalesce(auth.uid(), new.updated_by);
  elsif public.bh_derived_only(tg_table_name, to_jsonb(old), to_jsonb(new)) then
    new.updated_by := old.updated_by;   -- the deleted-by in the bin reads this; a re-file doesn't change who did it
  else
    new.updated_by := coalesce(auth.uid(), new.updated_by);
  end if;
  return new;
end $$;

create or replace function public.bh_audit()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_old jsonb; v_new jsonb; v_hh uuid; v_id uuid; v_keys text[]; v_b jsonb := '{}'; v_a jsonb := '{}'; k text; v_label text;
  v_skip text[] := array['updated_at', 'updated_by', 'created_at'];
  v_table text := regexp_replace(tg_table_name, '_all$', '');
begin
  if tg_op = 'DELETE' then
    v_old := to_jsonb(old);
    v_hh := case when tg_table_name = 'households' then old.id else (v_old->>'household_id')::uuid end;
    v_label := coalesce(v_old->>'description', v_old->>'remarks', v_old->>'income_source', v_old->>'display_name', v_old->>'name', v_old->>'label', v_old->>'source_name', v_old->>'category_group');
    insert into audit_log (household_id, table_name, row_id, op, by_user, label, before)
    values (v_hh, v_table, (v_old->>'id')::uuid, 'delete', auth.uid(), v_label, v_old - v_skip);
    return old;
  end if;
  v_new := to_jsonb(new);
  v_hh := case when tg_table_name = 'households' then new.id else (v_new->>'household_id')::uuid end;
  v_id := (v_new->>'id')::uuid;
  v_label := coalesce(v_new->>'description', v_new->>'remarks', v_new->>'income_source', v_new->>'display_name', v_new->>'name', v_new->>'label', v_new->>'source_name', v_new->>'category_group');
  if tg_op = 'INSERT' then
    insert into audit_log (household_id, table_name, row_id, op, by_user, label, after)
    values (v_hh, v_table, v_id, 'insert', auth.uid(), v_label, v_new - v_skip);
    return new;
  end if;
  v_old := to_jsonb(old);
  if public.bh_derived_only(tg_table_name, v_old, v_new) then return new; end if;   -- the server keeping copies in step: no line
  for k in select jsonb_object_keys(v_new) loop
    if k = any(v_skip) then continue; end if;
    if v_new->k is distinct from v_old->k then
      v_keys := array_append(v_keys, k);
      v_b := v_b || jsonb_build_object(k, v_old->k);
      v_a := v_a || jsonb_build_object(k, v_new->k);
    end if;
  end loop;
  if v_keys is null then return new; end if;
  insert into audit_log (household_id, table_name, row_id, op, by_user, label, changed, before, after)
  values (v_hh, v_table, v_id, 'update', auth.uid(), v_label, v_keys, v_b, v_a);
  return new;
end $$;
revoke execute on function public.bh_audit() from public, anon, authenticated;

-- ── 1 · re-filing, set-based ────────────────────────────────────────────
-- where each daily purchase in the window belongs — the same rule as expense_pot_for(), worked out for all rows
-- in one join: the purchase's own fund; else its budget line's pot that month; else the currency's first pot
drop function if exists public.restamp_pots(uuid, date, date);
create or replace function public.restamp_pots(p_hh uuid, p_from date default null, p_to date default null, p_cur text default null)
returns integer language plpgsql security definer set search_path = public as $$
declare v_n integer;
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
       where e.household_id = p_hh and e.trip_id is null
         and (p_from is null or e.date >= p_from) and (p_to is null or e.date < p_to)
         and (p_cur is null or e.currency = p_cur)) x
     where x.now_pot is distinct from x.pot
  )
  update expenses e set pot_fund_id = w.pot
    from want w
   where e.id = w.id and e.household_id = p_hh;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
revoke execute on function public.restamp_pots(uuid, date, date, text) from public, anon, authenticated;
grant execute on function public.restamp_pots(uuid, date, date, text) to service_role;

-- a fund decides where purchases land only while it is a spending pot: re-file that currency, from this month
create or replace function public.bh_funds_restamp()
returns trigger language plpgsql security definer set search_path = public as $$
declare r record; v_from date;
begin
  r := coalesce(new, old);
  if tg_op = 'INSERT' and not new.is_spend_pot then return new; end if;
  if tg_op = 'DELETE' and not old.is_spend_pot then return old; end if;
  if tg_op = 'UPDATE' and not ((old.is_spend_pot or new.is_spend_pot) and (
       new.is_spend_pot is distinct from old.is_spend_pot or new.is_active is distinct from old.is_active
    or new.sort_order is distinct from old.sort_order or new.currency is distinct from old.currency)) then
    return new;
  end if;
  v_from := date_trunc('month', bh_today(r.household_id))::date;
  perform restamp_pots(r.household_id, v_from, null, r.currency);
  if tg_op = 'UPDATE' and new.currency is distinct from old.currency then
    perform restamp_pots(r.household_id, v_from, null, old.currency);
  end if;
  return r;
end $$;
revoke execute on function public.bh_funds_restamp() from public, anon, authenticated;

-- ── 2 · budget lines: once per statement, only what moves a pot ─────────
create or replace function public.bh_cb_refile(p_hh uuid, p_month date, p_cur text)
returns void language plpgsql security definer set search_path = public as $$
declare v_from date := greatest(p_month, date_trunc('month', bh_today(p_hh))::date);   -- never a past month
begin
  if v_from < (p_month + interval '1 month')::date then
    perform restamp_pots(p_hh, v_from, (p_month + interval '1 month')::date, p_cur);
  end if;
end $$;
revoke execute on function public.bh_cb_refile(uuid, date, text) from public, anon, authenticated;

create or replace function public.bh_cb_restamp()
returns trigger language plpgsql security definer set search_path = public as $$
declare r record;
begin
  -- a line without its own pot leaves purchases with the currency's first pot either way
  if tg_op = 'INSERT' then
    for r in select distinct household_id, month, currency from nt where pot_fund_id is not null loop
      perform bh_cb_refile(r.household_id, r.month, r.currency);
    end loop;
  elsif tg_op = 'DELETE' then
    for r in select distinct household_id, month, currency from ot where pot_fund_id is not null loop
      perform bh_cb_refile(r.household_id, r.month, r.currency);
    end loop;
  else
    for r in select distinct x.household_id, x.month, x.currency from (
               select n.household_id, n.month, n.currency from nt n join ot o using (id)
                where (n.pot_fund_id is not null or o.pot_fund_id is not null)
                  and (n.pot_fund_id, n.category_group_id, n.currency, n.month) is distinct from (o.pot_fund_id, o.category_group_id, o.currency, o.month)
               union
               select o.household_id, o.month, o.currency from nt n join ot o using (id)
                where (n.pot_fund_id is not null or o.pot_fund_id is not null)
                  and (n.pot_fund_id, n.category_group_id, n.currency, n.month) is distinct from (o.pot_fund_id, o.category_group_id, o.currency, o.month)) x loop
      perform bh_cb_refile(r.household_id, r.month, r.currency);
    end loop;
  end if;
  return null;
end $$;
revoke execute on function public.bh_cb_restamp() from public, anon, authenticated;
drop trigger if exists category_budgets_restamp on public.category_budgets;
drop trigger if exists category_budgets_restamp_ins on public.category_budgets;
drop trigger if exists category_budgets_restamp_upd on public.category_budgets;
drop trigger if exists category_budgets_restamp_del on public.category_budgets;
create trigger category_budgets_restamp_ins after insert on public.category_budgets
  referencing new table as nt for each statement execute function public.bh_cb_restamp();
create trigger category_budgets_restamp_upd after update on public.category_budgets
  referencing old table as ot new table as nt for each statement execute function public.bh_cb_restamp();
create trigger category_budgets_restamp_del after delete on public.category_budgets
  referencing old table as ot for each statement execute function public.bh_cb_restamp();

-- ── 3 · saving the plan changes only what changed ───────────────────────
create or replace function public.save_month_plan(p_month date, p_inc jsonb, p_cat jsonb, p_fb jsonb, p_seen text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_hh uuid;
begin
  v_hh := bh_current_household(); if v_hh is null then raise exception 'no household — or your login is view-only' using errcode = '42501'; end if;
  if p_month is null or p_month <> date_trunc('month', p_month)::date then raise exception 'pick a month' using errcode = 'P0001'; end if;
  if p_seen is not null and p_seen <> bh_plan_version(v_hh, p_month) then
    raise exception 'the plan was changed on another phone — close it and open it again to see the latest' using errcode = 'P0001';
  end if;

  -- income: one line per source
  delete from income_budgets b
   where b.household_id = v_hh and b.month = p_month
     and not exists (select 1 from jsonb_to_recordset(coalesce(p_inc, '[]'::jsonb)) as x(source_name text, currency text, amount numeric)
                      where x.amount > 0 and x.source_name = b.source_name);
  insert into income_budgets (household_id, month, source_name, currency, amount)
  select v_hh, p_month, x.source_name, x.currency, x.amount
    from jsonb_to_recordset(coalesce(p_inc, '[]'::jsonb)) as x(source_name text, currency text, amount numeric)
   where x.amount > 0
  on conflict (household_id, month, source_name) do update set currency = excluded.currency, amount = excluded.amount
   where (income_budgets.currency, income_budgets.amount) is distinct from (excluded.currency, excluded.amount);

  -- spending budget: one line per group and currency, with its pot if it names one of this household's
  delete from category_budgets b
   where b.household_id = v_hh and b.month = p_month
     and not exists (select 1 from jsonb_to_recordset(coalesce(p_cat, '[]'::jsonb)) as x(category_group text, currency text, amount numeric, pot_fund_id uuid)
                      where x.amount > 0 and x.category_group = b.category_group and x.currency = b.currency);
  insert into category_budgets (household_id, month, category_group, currency, amount, pot_fund_id)
  select v_hh, p_month, x.category_group, x.currency, x.amount,
         case when exists (select 1 from funds f where f.id = x.pot_fund_id and f.household_id = v_hh) then x.pot_fund_id end
    from jsonb_to_recordset(coalesce(p_cat, '[]'::jsonb)) as x(category_group text, currency text, amount numeric, pot_fund_id uuid)
   where x.amount > 0
  on conflict (household_id, month, category_group, currency) do update set amount = excluded.amount, pot_fund_id = excluded.pot_fund_id
   where (category_budgets.amount, category_budgets.pot_fund_id) is distinct from (excluded.amount, excluded.pot_fund_id);

  -- contributions: one line per fund
  delete from fund_budgets b
   where b.household_id = v_hh and b.month = p_month
     and not exists (select 1 from jsonb_to_recordset(coalesce(p_fb, '[]'::jsonb)) as x(fund_id uuid, amount numeric)
                      where x.amount > 0 and x.fund_id = b.fund_id);
  insert into fund_budgets (household_id, month, fund_id, amount)
  select v_hh, p_month, x.fund_id, x.amount
    from jsonb_to_recordset(coalesce(p_fb, '[]'::jsonb)) as x(fund_id uuid, amount numeric)
   where x.amount > 0 and exists (select 1 from funds f where f.id = x.fund_id and f.household_id = v_hh)
  on conflict (fund_id, month) do update set amount = excluded.amount
   where fund_budgets.amount is distinct from excluded.amount;
  -- the budget-line trigger re-files this month's purchases where a line's pot changed (never a past month's)
end $$;
revoke execute on function public.save_month_plan(date, jsonb, jsonb, jsonb, text) from public, anon;
grant execute on function public.save_month_plan(date, jsonb, jsonb, jsonb, text) to authenticated, service_role;

-- ── proof ────────────────────────────────────────────────────────────────
do $$
declare v_bad int;
begin
  select count(*) into v_bad from _b_fund b full join public.fund_balances a using (fund_id) where a.balance is distinct from b.balance;
  if v_bad > 0 then raise exception 'calmer triggers: % fund balances changed', v_bad; end if;
  select count(*) into v_bad from _b_pots b join public.expenses e using (id) where e.pot_fund_id is distinct from b.pot_fund_id;
  if v_bad > 0 then raise exception 'calmer triggers: % purchases changed pot', v_bad; end if;
  raise notice 'calmer triggers ok: no purchase moved, balances unchanged';
end $$;
drop table _b_fund; drop table _b_pots;
notify pgrst, 'reload schema';
commit;
