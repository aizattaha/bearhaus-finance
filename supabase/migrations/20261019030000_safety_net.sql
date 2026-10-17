-- Safety net that works on its own (Review Board round 1, Bundle B — DECISIONS E37). Moves no money.
--
--  B1 · Heartbeat. Every money-check run and every backup leaves a row in ops_runs (server-only, counts only:
--        no amount, no household, no name but the check's own). ops_heartbeat() gives the owner's Desk Dashboard
--        "last money check · last backup", stale after 36 hours (check) or 8 days (backup). Silence — a failed
--        run, a paused schedule, GitHub switching schedules off after 60 quiet days — now shows.
--  B2 · A smarter nightly check. bh_money_check_run() stores the counts and says, per line, whether a 'warn'
--        count rose since the last stored run; the workflow fails on any 'fail' above zero OR any rise, so a
--        second problem can't hide behind a known one. The dead "integrity issues" line is gone (nothing has
--        written integrity_issues since the group check started refusing, 20261017010000). New lines: rows on
--        another card's statement or card payments to a card that isn't a credit card (warn); trip card lines
--        marked settled with no send — the card owes them and no fund carries them (info, DH-06); and the
--        takeover signals (warn, last 24 hours): new logins, member changes, new invites, owner changes,
--        password resets or email changes asked for. ("Sent" purchases with no send already fail since E36.)
--  B3 · A narrow login for the nightly check. Role bh_monitor can connect and run exactly two functions —
--        bh_money_check_run(text) and bh_backup_done(text, integer) — and read nothing. It is created without a
--        password and can't log in until the "Monitor login" workflow gives it one from the GitHub secret
--        MONITOR_DB_PASSWORD (as a SCRAM hash; the password never appears in SQL or a log).
--  DH-10 · data_fixes_applied records each private data fix run by tools/ops/run-data-fix.sh (name and time).
begin;

-- ── B1 · the run log (server-only) ─────────────────────────────────────
create table if not exists public.ops_runs (
  id       bigserial primary key,
  kind     text not null check (kind in ('money_check', 'backup')),
  ran_at   timestamptz not null default now(),
  source   text not null check (source in ('schedule', 'manual', 'test')),
  via      text not null default session_user,     -- which login wrote it: bh_monitor once B3 is set up
  fails    integer,                                -- money check: lines with a 'fail' count above zero
  warns    integer,                                --              lines with a 'warn' count above zero
  rises    integer,                                --              'warn' lines whose count rose since the last run
  lines    jsonb,                                  --              [{n: check name, s: severity, b: count, r: rose}]
  kb       integer                                 -- backup: size of the encrypted file
);
create index if not exists ops_runs_kind_at on public.ops_runs (kind, ran_at desc, id desc);
alter table public.ops_runs enable row level security;   -- no policies: only the functions below touch it
revoke all on public.ops_runs from public, anon, authenticated;
revoke all on sequence public.ops_runs_id_seq from public, anon, authenticated;
grant all on public.ops_runs to service_role;
grant all on sequence public.ops_runs_id_seq to service_role;

create table if not exists public.data_fixes_applied (
  name    text primary key,                        -- the fix file's name, e.g. 2026-10-16-what.sql
  ran_at  timestamptz not null default now(),
  ran_by  text not null default session_user
);
alter table public.data_fixes_applied enable row level security;
revoke all on public.data_fixes_applied from public, anon, authenticated;
grant all on public.data_fixes_applied to service_role;

-- ── B2 · the check itself: counts only ─────────────────────────────────
create or replace function public.bh_money_check()
returns table (check_name text, severity text, bad integer)
language sql stable security definer set search_path = public as $$
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
  union all
  select 'card rows on another card''s statement, or card payments to a card that isn''t a credit card', 'warn',
         (select count(*)::int from expenses e join statements s on s.id = e.reconciled_statement_id
           where e.deleted_at is null and s.payment_method_id is distinct from e.payment_method_id)
       + (select count(distinct t.transfer_group_id)::int from fund_transactions t
           left join payment_methods pm on pm.id = t.settles_payment_method_id
           left join statements s on s.id = t.settles_statement_id
           where t.kind = 'card_payment'
             and (pm.kind is distinct from 'credit_card' or (s.id is not null and s.payment_method_id <> t.settles_payment_method_id)))
  union all
  select 'trip card lines marked settled with no send (the card owes them, no fund carries them)', 'info',
         (select count(*)::int from expenses e join payment_methods pm on pm.id = e.payment_method_id and pm.kind = 'credit_card'
           where e.trip_id is not null and e.deleted_at is null and e.sent_to_fund and e.settlement_tx_id is null)
  union all
  -- takeover signals (SEC-09): each is normal when you invite someone; a rise fails the night's run, so you hear of it
  select 'takeover? logins created in the last day', 'warn',
         (select count(*)::int from auth.users where created_at > now() - interval '24 hours')
  union all
  select 'takeover? household members added, changed or removed in the last day', 'warn',
         (select count(*)::int from audit_log where table_name = 'household_members' and at > now() - interval '24 hours')
  union all
  select 'takeover? invites created in the last day', 'warn',
         (select count(*)::int from member_invites where created_at > now() - interval '24 hours')
  union all
  select 'takeover? household owner changed in the last day', 'warn',
         (select count(*)::int from audit_log
           where table_name = 'households' and op = 'update' and 'owner_user_id' = any(changed) and at > now() - interval '24 hours')
  union all
  select 'takeover? password resets or email changes asked for in the last day', 'warn',
         (select count(*)::int from auth.users
           where recovery_sent_at > now() - interval '24 hours' or email_change_sent_at > now() - interval '24 hours')
$$;
revoke execute on function public.bh_money_check() from public, anon, authenticated;
grant execute on function public.bh_money_check() to service_role;

-- one run: check, compare with the last stored run, store, answer (what the nightly workflow calls)
create or replace function public.bh_money_check_run(p_source text default 'manual')
returns table (check_name text, severity text, bad integer, previous integer, rose boolean)
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
declare v_prev jsonb; v_lines jsonb;
begin
  if p_source is null or p_source not in ('schedule', 'manual', 'test') then
    raise exception 'bh_money_check_run: source must be schedule, manual or test' using errcode = '22023';
  end if;
  select r.lines into v_prev from ops_runs r where r.kind = 'money_check' order by r.ran_at desc, r.id desc limit 1;
  with c as (select m.check_name as n, m.severity as s, m.bad as b from bh_money_check() m),
       p as (select e ->> 'n' as n, (e ->> 'b')::int as b from jsonb_array_elements(coalesce(v_prev, '[]')) e)
  select jsonb_agg(jsonb_build_object('n', c.n, 's', c.s, 'b', c.b, 'p', p.b,
                                      'r', c.s = 'warn' and p.b is not null and c.b > p.b)
                   order by case c.s when 'fail' then 1 when 'warn' then 2 else 3 end, c.n)
    into v_lines
    from c left join p on p.n = c.n;
  insert into ops_runs (kind, source, fails, warns, rises, lines)
  select 'money_check', p_source,
         count(*) filter (where e ->> 's' = 'fail' and (e ->> 'b')::int > 0),
         count(*) filter (where e ->> 's' = 'warn' and (e ->> 'b')::int > 0),
         count(*) filter (where (e ->> 'r')::boolean),
         (select jsonb_agg(x - 'p') from jsonb_array_elements(v_lines) x)
    from jsonb_array_elements(v_lines) e;
  return query
    select e ->> 'n', e ->> 's', (e ->> 'b')::int, (e ->> 'p')::int, (e ->> 'r')::boolean
      from jsonb_array_elements(v_lines) with ordinality as l(e, i) order by l.i;
end $$;
revoke execute on function public.bh_money_check_run(text) from public, anon, authenticated;
grant execute on function public.bh_money_check_run(text) to service_role;

-- the backup job, after its encrypted file is uploaded
create or replace function public.bh_backup_done(p_source text, p_kb integer)
returns timestamptz
language plpgsql volatile security definer set search_path = public as $$
declare v_at timestamptz;
begin
  if p_source is null or p_source not in ('schedule', 'manual', 'test') then
    raise exception 'bh_backup_done: source must be schedule, manual or test' using errcode = '22023';
  end if;
  if p_kb is null or p_kb < 1 or p_kb > 10000000 then
    raise exception 'bh_backup_done: the size must be between 1 KB and 10 GB' using errcode = '22023';
  end if;
  insert into ops_runs (kind, source, kb) values ('backup', p_source, p_kb) returning ran_at into v_at;
  return v_at;
end $$;
revoke execute on function public.bh_backup_done(text, integer) from public, anon, authenticated;
grant execute on function public.bh_backup_done(text, integer) to service_role;

-- the Dashboard's line: the owner of a household sees it; anyone else gets no row
create or replace function public.ops_heartbeat()
returns table (check_at timestamptz, check_state text, check_fails integer, check_warns integer, check_rises integer,
               check_lines jsonb, backup_at timestamptz, backup_state text, backup_kb integer)
language sql stable security definer set search_path = public as $$
  with c as (select * from ops_runs where kind = 'money_check' order by ran_at desc, id desc limit 1),
       b as (select * from ops_runs where kind = 'backup' order by ran_at desc, id desc limit 1)
  select c.ran_at,
         case when c.ran_at is null then 'never'
              when c.ran_at < now() - interval '36 hours' then 'stale'
              when c.fails > 0 or c.rises > 0 then 'fail'
              when c.warns > 0 then 'look'
              else 'ok' end,
         c.fails, c.warns, c.rises,
         coalesce((select jsonb_agg(e order by ord) from jsonb_array_elements(c.lines) with ordinality as l(e, ord)
                    where e ->> 's' in ('fail', 'warn') and (e ->> 'b')::int > 0), '[]'::jsonb),
         b.ran_at,
         case when b.ran_at is null then 'never'
              when b.ran_at < now() - interval '8 days' then 'stale'
              when b.ran_at < now() - interval '50 hours' then 'late'
              else 'ok' end,
         b.kb
    from (select 1) one
    left join c on true left join b on true
   where exists (select 1 from household_members m where m.user_id = auth.uid() and m.role = 'owner')
$$;
revoke execute on function public.ops_heartbeat() from public, anon;
grant execute on function public.ops_heartbeat() to authenticated, service_role;

-- ── B3 · the nightly check's own login: connect, run two functions, read nothing ──
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'bh_monitor') then
    create role bh_monitor nologin noinherit nocreatedb nocreaterole connection limit 3;
  end if;
  execute format('grant connect on database %I to bh_monitor', current_database());
end $$;
alter role bh_monitor set statement_timeout = '60s';
grant usage on schema public to bh_monitor;
grant execute on function public.bh_money_check_run(text) to bh_monitor;
grant execute on function public.bh_backup_done(text, integer) to bh_monitor;

-- proof: bh_monitor runs exactly the two, and holds no table right in public
do $$
declare v text;
begin
  select string_agg(p.oid::regprocedure::text, ', ') into v from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and has_function_privilege('bh_monitor', p.oid, 'execute')
     and p.oid not in ('public.bh_money_check_run(text)'::regprocedure, 'public.bh_backup_done(text, integer)'::regprocedure);
  if v is not null then raise exception 'safety net: bh_monitor can also run %', v; end if;
  select string_agg(c.relname, ', ') into v from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p', 'v', 'm')
     and has_table_privilege('bh_monitor', c.oid, 'select, insert, update, delete, truncate');
  if v is not null then raise exception 'safety net: bh_monitor has rights on %', v; end if;
  raise notice 'safety net ok: bh_monitor runs 2 functions and reads nothing';
end $$;

notify pgrst, 'reload schema';
commit;
