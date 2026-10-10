-- "Who paid" clean-up (Aizat, 10 Oct 2026).
--
-- Rule: a row paid with a PERSONAL card (a payment method that belongs to a profile) was paid
-- by that person. A null payer is only meaningful on joint cards (Cash, Bank - Joint, YouTrip -
-- Joint) and on rows with no card at all.
--   1. Backfill: every daily/travel row with a personal card and no payer gets the card's owner.
--      Rows that already name a payer are never touched (a deliberate "Paige paid with Aizat's
--      card" stays).
--   2. Trigger: from now on the same rule applies on insert, and whenever a row is moved onto
--      a personal card while its payer is empty — so the data stays clean without anyone
--      remembering to pick "Who paid".
-- Rows on joint cards and the sheet-era rows with no card stay as they are (joint).

begin;

update public.daily_expenses d
   set payer_profile_id = pm.profile_id
  from public.payment_methods pm
 where pm.id = d.payment_method_id and pm.profile_id is not null and d.payer_profile_id is null;

update public.travel_expenses t
   set payer_profile_id = pm.profile_id
  from public.payment_methods pm
 where pm.id = t.payment_method_id and pm.profile_id is not null and t.payer_profile_id is null;

create or replace function public.bh_expense_before_write()
returns trigger language plpgsql as $$
declare v_kind text; v_owner uuid;
begin
  -- keep the id in step with the name (older app builds only send the name)
  if new.payment_method_id is null and coalesce(new.paid_with, '') <> '' then
    select id into new.payment_method_id from payment_methods
     where household_id = new.household_id and name = new.paid_with limit 1;
  end if;
  if new.payment_method_id is not null and (tg_op = 'INSERT' or new.payment_method_id is distinct from old.payment_method_id) then
    select name into new.paid_with from payment_methods where id = new.payment_method_id;
  end if;
  select kind, profile_id into v_kind, v_owner from payment_methods where id = new.payment_method_id;
  -- a personal card names the payer when nobody did
  if new.payer_profile_id is null and v_owner is not null
     and (tg_op = 'INSERT' or new.payment_method_id is distinct from old.payment_method_id) then
    new.payer_profile_id := v_owner;
  end if;
  -- cash ticks itself when the row is created or switched TO cash; an explicit un-tick
  -- (reconciled_at set to null on an unchanged card) is respected, so a mistake can be fixed
  if v_kind = 'cash' and new.reconciled_at is null
     and (tg_op = 'INSERT' or new.payment_method_id is distinct from old.payment_method_id) then
    new.reconciled_at := now(); new.reconciled_by := 'auto'; new.reconciled_statement_id := null;
  elsif tg_op = 'UPDATE' and v_kind is distinct from 'cash' and old.reconciled_by = 'auto' and new.reconciled_by = 'auto'
        and new.payment_method_id is distinct from old.payment_method_id then
    -- was cash, now a real card: the automatic tick no longer applies
    new.reconciled_at := null; new.reconciled_by := null; new.reconciled_statement_id := null;
  end if;
  return new;
end;
$$;

commit;
