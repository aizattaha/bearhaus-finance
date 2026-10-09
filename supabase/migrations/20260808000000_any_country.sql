-- Phase 6 "any country" (Aug 2026): signup accepts any country + currency pair.
-- p_currencies is optional — older app versions that omit it still work for AU/SG
-- (the old hardcoded mapping stays as the fallback). The old 5-arg overload is
-- dropped so PostgREST never sees an ambiguous pair.
drop function if exists public.create_household_setup(text, text, text[], text, text[]);

create or replace function public.create_household_setup(
  p_code        text,
  p_household   text,
  p_people      text[],
  p_joint_label text,
  p_countries   text[],
  p_currencies  text[] default null
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
  v_i       int;
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
  if coalesce(array_length(p_countries, 1), 0) > 4 then
    raise exception 'four countries max for now';
  end if;
  if p_currencies is not null
     and coalesce(array_length(p_currencies, 1), 0) <> coalesce(array_length(p_countries, 1), 0) then
    raise exception 'countries and currencies don''t line up';
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

  for v_i in 1 .. array_length(p_countries, 1) loop
    v_cc := upper(trim(p_countries[v_i]));
    if v_cc !~ '^[A-Z]{2}$' then
      raise exception 'country codes are two letters — got %', v_cc;
    end if;
    v_cur := case
      when p_currencies is not null then upper(trim(p_currencies[v_i]))
      when v_cc = 'SG' then 'SGD'
      when v_cc = 'AU' then 'AUD'
      else null
    end;
    if v_cur is null or v_cur !~ '^[A-Z]{3}$' then
      raise exception 'missing or invalid currency for %', v_cc;
    end if;
    if v_primary then
      insert into funds (household_id, name, country, currency, group_name, sort_order)
      values (v_hh, 'Float', v_cc, v_cur, 'Savings & buffers', v_sort);
      v_sort := v_sort + 1;
    end if;
    insert into funds (household_id, name, country, currency, group_name, sort_order, is_leftover_target)
    values (v_hh, 'Savings', v_cc, v_cur, 'Savings & buffers', v_sort, true);
    v_sort := v_sort + 1;
    insert into funds (household_id, name, country, currency, group_name, sort_order)
    values (v_hh, 'Emergency fund', v_cc, v_cur, 'Savings & buffers', v_sort);
    v_sort := v_sort + 1;
    insert into funds (household_id, name, country, currency, group_name, sort_order)
    values (v_hh, 'Travel fund', v_cc, v_cur, 'Savings & buffers', v_sort)
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
