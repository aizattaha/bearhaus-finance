-- The original household, in skeleton: a handful of the data-fix migrations from 2026 refer to
-- BearHaus rows by id (a fund, a trip). On a scratch database those rows must exist for the
-- chain to apply; everything else about the household is created by the migrations themselves.
insert into auth.users (id, email) values ('6a09f1b4-5863-465e-b015-3af50adb7524', 'owner@test.local') on conflict do nothing;
insert into public.households (id, name, owner_user_id) values ('82f25ed0-bd15-4089-a184-833137120d7f', 'BearHaus', '6a09f1b4-5863-465e-b015-3af50adb7524') on conflict do nothing;
insert into public.profiles (household_id, display_name, sort_order) values ('82f25ed0-bd15-4089-a184-833137120d7f', 'Aizat', 0), ('82f25ed0-bd15-4089-a184-833137120d7f', 'Paige', 1);
insert into public.funds (id, household_id, name, country, currency) values
  ('6854426f-f59e-4bd7-bbbc-6f4f953af16b', '82f25ed0-bd15-4089-a184-833137120d7f', 'Float', 'AU', 'AUD'),
  ('0192571a-a619-41ac-88ce-5b0c465227a2', '82f25ed0-bd15-4089-a184-833137120d7f', 'Future DreamHouse SG', 'SG', 'SGD'),
  (gen_random_uuid(), '82f25ed0-bd15-4089-a184-833137120d7f', 'AIA ProtectPlus 2 (Anne)', 'SG', 'SGD'),
  (gen_random_uuid(), '82f25ed0-bd15-4089-a184-833137120d7f', 'AXA Term Protector', 'SG', 'SGD'),
  (gen_random_uuid(), '82f25ed0-bd15-4089-a184-833137120d7f', 'BearHaus Rainy Day AU', 'AU', 'AUD'),
  (gen_random_uuid(), '82f25ed0-bd15-4089-a184-833137120d7f', 'Car Fund', 'AU', 'AUD'),
  (gen_random_uuid(), '82f25ed0-bd15-4089-a184-833137120d7f', 'Dry Powder AU (Paige)', 'AU', 'AUD'),
  (gen_random_uuid(), '82f25ed0-bd15-4089-a184-833137120d7f', 'Edu Fund (Claire)', 'AU', 'AUD'),
  (gen_random_uuid(), '82f25ed0-bd15-4089-a184-833137120d7f', 'FWD Future First', 'SG', 'SGD'),
  (gen_random_uuid(), '82f25ed0-bd15-4089-a184-833137120d7f', 'Google Drive', 'SG', 'SGD'),
  (gen_random_uuid(), '82f25ed0-bd15-4089-a184-833137120d7f', 'HSBC FlexiProtector (Anne)', 'SG', 'SGD'),
  (gen_random_uuid(), '82f25ed0-bd15-4089-a184-833137120d7f', 'Investment Fund AU (Aizat)', 'AU', 'AUD'),
  (gen_random_uuid(), '82f25ed0-bd15-4089-a184-833137120d7f', 'Life Multiprotect (Aizat)', 'SG', 'SGD'),
  (gen_random_uuid(), '82f25ed0-bd15-4089-a184-833137120d7f', 'Life Multiprotect (Paige)', 'SG', 'SGD'),
  (gen_random_uuid(), '82f25ed0-bd15-4089-a184-833137120d7f', 'Life Treasure (Claire)', 'SG', 'SGD'),
  (gen_random_uuid(), '82f25ed0-bd15-4089-a184-833137120d7f', 'MediShield (Aizat)', 'SG', 'SGD'),
  (gen_random_uuid(), '82f25ed0-bd15-4089-a184-833137120d7f', 'MediShield (Anne)', 'SG', 'SGD'),
  (gen_random_uuid(), '82f25ed0-bd15-4089-a184-833137120d7f', 'MediShield (Claire)', 'SG', 'SGD'),
  (gen_random_uuid(), '82f25ed0-bd15-4089-a184-833137120d7f', 'MediShield (Paige)', 'SG', 'SGD'),
  (gen_random_uuid(), '82f25ed0-bd15-4089-a184-833137120d7f', 'Monthly Expenses (Aizat)', 'AU', 'AUD'),
  (gen_random_uuid(), '82f25ed0-bd15-4089-a184-833137120d7f', 'Monthly Expenses (Paige)', 'AU', 'AUD'),
  (gen_random_uuid(), '82f25ed0-bd15-4089-a184-833137120d7f', 'Property Tax', 'SG', 'SGD'),
  (gen_random_uuid(), '82f25ed0-bd15-4089-a184-833137120d7f', 'Rainy Day Fund AU (Aizat)', 'AU', 'AUD'),
  (gen_random_uuid(), '82f25ed0-bd15-4089-a184-833137120d7f', 'Travel Fund AU', 'AU', 'AUD')
on conflict do nothing;
insert into public.trips (id, household_id, name, countries, currencies) values ('127802a5-8433-402e-91b1-05a778b111c6', '82f25ed0-bd15-4089-a184-833137120d7f', '202609 SGCN', '{SG,CN}', '{SGD,CNY}') on conflict do nothing;
