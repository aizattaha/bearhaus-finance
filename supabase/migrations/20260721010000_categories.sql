-- ============================================================
-- Categories as data (Phase 6)
--  1. categories table — per-household, RLS "own household only"
--  2. seed_default_categories(hh) — the standard set
--  3. seed every existing household
--  4. normalise legacy budget group labels (sheet-era names)
--  5. new households get categories at onboarding (RPC updated)
-- ============================================================

-- 1 ── table ---------------------------------------------------
create table if not exists public.categories (
  id           uuid default gen_random_uuid() not null primary key,
  household_id uuid not null,
  kind         text not null check (kind in ('daily', 'travel')),
  name         text not null,
  group_name   text not null,
  icon         text not null default '🛍️',
  sort_order   integer default 0 not null,
  is_active    boolean default true not null,
  created_at   timestamp with time zone default now() not null
);
create unique index if not exists categories_hh_kind_name on public.categories (household_id, kind, name);
alter table public.categories enable row level security;
drop policy if exists "own household only" on public.categories;
create policy "own household only" on public.categories
  using (household_id in (select id from public.households where owner_user_id = (select auth.uid())))
  with check (household_id in (select id from public.households where owner_user_id = (select auth.uid())));

-- 2 ── the standard set ---------------------------------------
create or replace function public.seed_default_categories(p_hh uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into categories (household_id, kind, name, group_name, icon, sort_order)
  select p_hh, v.kind, v.name, v.group_name, v.icon, v.ord
  from (values
    -- daily: group order mirrors the Budget page
    ('daily','Rent','Rent','🏠',0),
    ('daily','Dining out','Daily Expenses','🍜',1),
    ('daily','Groceries','Daily Expenses','🛒',2),
    ('daily','Household supplies','Daily Expenses','🧻',3),
    ('daily','Home - Other','Daily Expenses','🏡',4),
    ('daily','Furniture','Daily Expenses','🛋️',5),
    ('daily','Sports','Daily Expenses','⚽',6),
    ('daily','Clothing','Daily Expenses','👕',7),
    ('daily','Gifts','Daily Expenses','🎁',8),
    ('daily','Liquor','Daily Expenses','🍺',9),
    ('daily','Entertainment - Other','Daily Expenses','🎭',10),
    ('daily','Electronics','Daily Expenses','🔌',11),
    ('daily','Movies','Daily Expenses','🎬',12),
    ('daily','Games','Daily Expenses','🎮',13),
    ('daily','Medical Expenses','Daily Expenses','💊',14),
    ('daily','Health','Daily Expenses','🩺',15),
    ('daily','Life - Other','Daily Expenses','🌿',16),
    ('daily','Hotel','Daily Expenses','🏨',17),
    ('daily','Childcare','Education','👶',18),
    ('daily','Education','Education','🎓',19),
    ('daily','Activities','Education','🎨',20),
    ('daily','Bus/train','Transportation','🚆',21),
    ('daily','Gas/fuel','Transportation','⛽',22),
    ('daily','Car','Transportation','🚗',23),
    ('daily','Parking','Transportation','🅿️',24),
    ('daily','Taxi','Transportation','🚕',25),
    ('daily','Bicycle','Transportation','🚲',26),
    ('daily','Transportation - Other','Transportation','🚌',27),
    ('daily','Water','Utilities','🚿',28),
    ('daily','Electricity','Utilities','💡',29),
    ('daily','Gas','Utilities','🔥',30),
    ('daily','TV/Phone/Internet','TV/Phone/Internet','📱',31),
    ('daily','Insurance','Insurance','🛡️',32),
    ('daily','Payment','Transfers','🔁',33),
    -- travel: group names keep their emoji — they are display keys
    ('travel','Flights','✈️ Flights & transport','✈️',0),
    ('travel','Airport Transfer','✈️ Flights & transport','🚐',1),
    ('travel','Taxi/Grab','✈️ Flights & transport','🚕',2),
    ('travel','Public Transport','✈️ Flights & transport','🚆',3),
    ('travel','Car Rental','✈️ Flights & transport','🚙',4),
    ('travel','Ferry/Train','✈️ Flights & transport','⛴️',5),
    ('travel','Hotel','🏨 Accommodation','🏨',6),
    ('travel','Airbnb/Hostel','🏨 Accommodation','🏘️',7),
    ('travel','Dining out','🍜 Food & drinks','🍜',8),
    ('travel','Street Food','🍜 Food & drinks','🌮',9),
    ('travel','Groceries','🍜 Food & drinks','🛒',10),
    ('travel','Drinks','🍜 Food & drinks','🥤',11),
    ('travel','Tours & Experiences','🎡 Activities','🎡',12),
    ('travel','Attraction Entry','🎡 Activities','🎟️',13),
    ('travel','Shopping','🛍️ Shopping','🛍️',14),
    ('travel','Souvenirs','🛍️ Shopping','🎁',15),
    ('travel','Travel Insurance','💊 Health & comms','🛡️',16),
    ('travel','Medical','💊 Health & comms','💊',17),
    ('travel','SIM Card/Data','💊 Health & comms','📶',18),
    ('travel','Currency exchange','💱 Money','💱',19),
    ('travel','Other','🗂️ Other','🗂️',20)
  ) as v(kind, name, group_name, icon, ord)
  where not exists (
    select 1 from categories c
    where c.household_id = p_hh and c.kind = v.kind and c.name = v.name
  );
end;
$$;
revoke all on function public.seed_default_categories(uuid) from public;

-- 3 ── seed everyone who already has a household ---------------
select public.seed_default_categories(id) from public.households;

-- 4 ── unify legacy budget labels (sheet era) so budget groups
--      and category groups speak the same names
update public.category_budgets set category_group = 'Rent'              where category_group = 'Rental';
update public.category_budgets set category_group = 'Transportation'    where category_group = 'Transport';
update public.category_budgets set category_group = 'TV/Phone/Internet' where category_group = 'Phone Bill/Internet';

-- 5 ── new households get categories at onboarding -------------
create or replace function public.create_household_setup(
  p_code       text,
  p_household  text,
  p_people     text[],
  p_joint_label text,
  p_countries  text[]
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_hh      uuid;
  v_person  text;
  v_cc      text;
  v_cur     text;
  v_sort    int  := 0;
  v_psort   int  := 0;
  v_fund    uuid;
  v_travel  uuid := null;
  v_primary boolean := true;
begin
  if v_uid is null then
    raise exception 'not signed in';
  end if;
  if exists (select 1 from households where owner_user_id = v_uid) then
    raise exception 'this login already has a household';
  end if;
  if coalesce(array_length(p_people, 1), 0) = 0 then
    raise exception 'add at least one person';
  end if;
  if coalesce(array_length(p_people, 1), 0) > 6 then
    raise exception 'six people max for now';
  end if;
  if coalesce(array_length(p_countries, 1), 0) = 0 then
    raise exception 'pick at least one country';
  end if;

  update beta_invites
     set used_count = used_count + 1
   where lower(code) = lower(trim(p_code))
     and used_count < max_uses;
  if not found then
    raise exception 'invite code not recognised — or already used';
  end if;

  insert into households (name, owner_user_id, joint_label)
  values (
    coalesce(nullif(trim(p_household), ''), 'My household'),
    v_uid,
    nullif(trim(coalesce(p_joint_label, '')), '')
  )
  returning id into v_hh;

  foreach v_person in array p_people loop
    if trim(v_person) <> '' then
      insert into profiles (household_id, display_name, sort_order)
      values (v_hh, trim(v_person), v_psort);
      v_psort := v_psort + 1;
    end if;
  end loop;

  foreach v_cc in array p_countries loop
    if v_cc not in ('AU', 'SG') then
      raise exception 'unsupported country % — the beta supports AU and SG', v_cc;
    end if;
    v_cur := case v_cc when 'SG' then 'SGD' else 'AUD' end;
    if v_primary then
      insert into funds (household_id, name, country, currency, group_name, sort_order)
      values (v_hh, 'Float', v_cc, v_cur, '', v_sort);
      v_sort := v_sort + 1;
    end if;
    insert into funds (household_id, name, country, currency, group_name, sort_order, is_leftover_target)
    values (v_hh, 'Savings', v_cc, v_cur, '', v_sort, true);
    v_sort := v_sort + 1;
    insert into funds (household_id, name, country, currency, group_name, sort_order)
    values (v_hh, 'Emergency fund', v_cc, v_cur, '', v_sort);
    v_sort := v_sort + 1;
    insert into funds (household_id, name, country, currency, group_name, sort_order)
    values (v_hh, 'Travel fund', v_cc, v_cur, '', v_sort)
    returning id into v_fund;
    v_sort := v_sort + 1;
    if v_primary then
      v_travel := v_fund;
    end if;
    v_primary := false;
  end loop;

  update households set travel_fund_id = v_travel where id = v_hh;

  insert into payment_methods (household_id, name, profile_id, sort_order)
  values (v_hh, 'Cash', null, 0);
  insert into payment_methods (household_id, name, profile_id, sort_order)
  select v_hh, 'Bank card — ' || display_name, id, 1
  from profiles where household_id = v_hh;

  perform seed_default_categories(v_hh);

  return v_hh;
end;
$$;
revoke all on function public.create_household_setup(text, text, text[], text, text[]) from public;
grant execute on function public.create_household_setup(text, text, text[], text, text[]) to authenticated;
