


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."check_invite"("p_code" "text") RETURNS boolean
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from beta_invites
    where lower(code) = lower(trim(p_code))
      and used_count < max_uses
  );
$$;


ALTER FUNCTION "public"."check_invite"("p_code" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_household_setup"("p_code" "text", "p_household" "text", "p_people" "text"[], "p_joint_label" "text", "p_countries" "text"[]) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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

  -- burn one use of the invite code (case-insensitive)
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

  -- starter funds per country; Float only once (the budget buffer)
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

  -- starter wallets: shared cash + one card per person (rename in Settings)
  insert into payment_methods (household_id, name, profile_id, sort_order)
  values (v_hh, 'Cash', null, 0);
  insert into payment_methods (household_id, name, profile_id, sort_order)
  select v_hh, 'Bank card — ' || display_name, id, 1
  from profiles where household_id = v_hh;

  return v_hh;
end;
$$;


ALTER FUNCTION "public"."create_household_setup"("p_code" "text", "p_household" "text", "p_people" "text"[], "p_joint_label" "text", "p_countries" "text"[]) OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."beta_invites" (
    "code" "text" NOT NULL,
    "note" "text",
    "max_uses" integer DEFAULT 1 NOT NULL,
    "used_count" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."beta_invites" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."category_budgets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "household_id" "uuid" NOT NULL,
    "month" "date" NOT NULL,
    "category_group" "text" NOT NULL,
    "amount" numeric(12,2) DEFAULT 0 NOT NULL,
    "currency" "text" DEFAULT 'AUD'::"text" NOT NULL,
    CONSTRAINT "category_budgets_month_check" CHECK (("month" = ("date_trunc"('month'::"text", ("month")::timestamp with time zone))::"date"))
);


ALTER TABLE "public"."category_budgets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."daily_expense_splits" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "household_id" "uuid" NOT NULL,
    "expense_id" "uuid" NOT NULL,
    "profile_id" "uuid",
    "amount" numeric(12,2) NOT NULL
);


ALTER TABLE "public"."daily_expense_splits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."daily_expenses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "household_id" "uuid" NOT NULL,
    "date" "date" NOT NULL,
    "description" "text" NOT NULL,
    "category" "text" NOT NULL,
    "amount" numeric(12,2) NOT NULL,
    "currency" "text" DEFAULT 'AUD'::"text" NOT NULL,
    "payer_profile_id" "uuid",
    "paid_with" "text" DEFAULT ''::"text" NOT NULL,
    "comments" "text" DEFAULT ''::"text" NOT NULL,
    "legacy_sync_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "daily_expenses_amount_check" CHECK (("amount" >= (0)::numeric))
);


ALTER TABLE "public"."daily_expenses" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."fund_balances" AS
SELECT
    NULL::"uuid" AS "household_id",
    NULL::"uuid" AS "fund_id",
    NULL::"text" AS "name",
    NULL::"text" AS "country",
    NULL::"text" AS "currency",
    NULL::boolean AS "is_active",
    NULL::integer AS "sort_order",
    NULL::"text" AS "group_name",
    NULL::boolean AS "is_leftover_target",
    NULL::numeric AS "balance";


ALTER VIEW "public"."fund_balances" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."fund_budgets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "household_id" "uuid" NOT NULL,
    "fund_id" "uuid" NOT NULL,
    "month" "date" NOT NULL,
    "amount" numeric(12,2) DEFAULT 0 NOT NULL,
    CONSTRAINT "fund_budgets_month_check" CHECK (("month" = ("date_trunc"('month'::"text", ("month")::timestamp with time zone))::"date"))
);


ALTER TABLE "public"."fund_budgets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."fund_transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "household_id" "uuid" NOT NULL,
    "fund_id" "uuid" NOT NULL,
    "type" "text" NOT NULL,
    "date" "date" NOT NULL,
    "amount" numeric(12,2) NOT NULL,
    "remarks" "text" DEFAULT ''::"text" NOT NULL,
    "origin" "text" DEFAULT 'manual'::"text" NOT NULL,
    "legacy_sync_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "fund_transactions_amount_check" CHECK (("amount" >= (0)::numeric)),
    CONSTRAINT "fund_transactions_origin_check" CHECK (("origin" = ANY (ARRAY['manual'::"text", 'planned'::"text"]))),
    CONSTRAINT "fund_transactions_type_check" CHECK (("type" = ANY (ARRAY['income'::"text", 'expense'::"text"])))
);


ALTER TABLE "public"."fund_transactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."funds" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "household_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "country" "text" NOT NULL,
    "currency" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "group_name" "text" DEFAULT ''::"text" NOT NULL,
    "is_leftover_target" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."funds" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."households" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "owner_user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "travel_fund_id" "uuid",
    "joint_label" "text" DEFAULT 'Joint'::"text"
);


ALTER TABLE "public"."households" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."income_budgets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "household_id" "uuid" NOT NULL,
    "month" "date" NOT NULL,
    "source_name" "text" NOT NULL,
    "profile_id" "uuid",
    "currency" "text" NOT NULL,
    "amount" numeric(12,2) DEFAULT 0 NOT NULL,
    CONSTRAINT "income_budgets_month_check" CHECK (("month" = ("date_trunc"('month'::"text", ("month")::timestamp with time zone))::"date"))
);


ALTER TABLE "public"."income_budgets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payment_methods" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "household_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "profile_id" "uuid",
    "travel_only" boolean DEFAULT false NOT NULL,
    "is_archived" boolean DEFAULT false NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."payment_methods" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "household_id" "uuid" NOT NULL,
    "display_name" "text" NOT NULL,
    "auth_user_id" "uuid",
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."travel_expense_splits" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "household_id" "uuid" NOT NULL,
    "expense_id" "uuid" NOT NULL,
    "profile_id" "uuid",
    "amount" numeric(12,2) NOT NULL
);


ALTER TABLE "public"."travel_expense_splits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."travel_expenses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "household_id" "uuid" NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "date" "date" NOT NULL,
    "description" "text" NOT NULL,
    "category" "text" NOT NULL,
    "amount" numeric(12,2) NOT NULL,
    "currency" "text" DEFAULT 'AUD'::"text" NOT NULL,
    "payer_profile_id" "uuid",
    "paid_with" "text" DEFAULT ''::"text" NOT NULL,
    "comments" "text" DEFAULT ''::"text" NOT NULL,
    "sent_to_fund" boolean DEFAULT false NOT NULL,
    "legacy_sync_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "travel_expenses_amount_check" CHECK (("amount" >= (0)::numeric))
);


ALTER TABLE "public"."travel_expenses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trips" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "household_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "start_date" "date",
    "end_date" "date",
    "currency" "text",
    "countries" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "currencies" "text"[] DEFAULT '{}'::"text"[] NOT NULL
);


ALTER TABLE "public"."trips" OWNER TO "postgres";


ALTER TABLE ONLY "public"."beta_invites"
    ADD CONSTRAINT "beta_invites_pkey" PRIMARY KEY ("code");



ALTER TABLE ONLY "public"."category_budgets"
    ADD CONSTRAINT "category_budgets_household_id_month_category_group_key" UNIQUE ("household_id", "month", "category_group");



ALTER TABLE ONLY "public"."category_budgets"
    ADD CONSTRAINT "category_budgets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."daily_expense_splits"
    ADD CONSTRAINT "daily_expense_splits_expense_id_profile_id_key" UNIQUE NULLS NOT DISTINCT ("expense_id", "profile_id");



ALTER TABLE ONLY "public"."daily_expense_splits"
    ADD CONSTRAINT "daily_expense_splits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."daily_expenses"
    ADD CONSTRAINT "daily_expenses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fund_budgets"
    ADD CONSTRAINT "fund_budgets_fund_id_month_key" UNIQUE ("fund_id", "month");



ALTER TABLE ONLY "public"."fund_budgets"
    ADD CONSTRAINT "fund_budgets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."fund_transactions"
    ADD CONSTRAINT "fund_transactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."funds"
    ADD CONSTRAINT "funds_household_id_name_key" UNIQUE ("household_id", "name");



ALTER TABLE ONLY "public"."funds"
    ADD CONSTRAINT "funds_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."households"
    ADD CONSTRAINT "households_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."income_budgets"
    ADD CONSTRAINT "income_budgets_household_id_month_source_name_key" UNIQUE ("household_id", "month", "source_name");



ALTER TABLE ONLY "public"."income_budgets"
    ADD CONSTRAINT "income_budgets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payment_methods"
    ADD CONSTRAINT "payment_methods_household_id_name_key" UNIQUE ("household_id", "name");



ALTER TABLE ONLY "public"."payment_methods"
    ADD CONSTRAINT "payment_methods_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_household_id_display_name_key" UNIQUE ("household_id", "display_name");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."travel_expense_splits"
    ADD CONSTRAINT "travel_expense_splits_expense_id_profile_id_key" UNIQUE NULLS NOT DISTINCT ("expense_id", "profile_id");



ALTER TABLE ONLY "public"."travel_expense_splits"
    ADD CONSTRAINT "travel_expense_splits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."travel_expenses"
    ADD CONSTRAINT "travel_expenses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trips"
    ADD CONSTRAINT "trips_household_id_name_key" UNIQUE ("household_id", "name");



ALTER TABLE ONLY "public"."trips"
    ADD CONSTRAINT "trips_pkey" PRIMARY KEY ("id");



CREATE INDEX "category_budgets_household_id_month_idx" ON "public"."category_budgets" USING "btree" ("household_id", "month");



CREATE INDEX "daily_expense_splits_expense_id_idx" ON "public"."daily_expense_splits" USING "btree" ("expense_id");



CREATE INDEX "daily_expenses_household_id_date_idx" ON "public"."daily_expenses" USING "btree" ("household_id", "date");



CREATE INDEX "fund_budgets_household_id_month_idx" ON "public"."fund_budgets" USING "btree" ("household_id", "month");



CREATE INDEX "fund_transactions_fund_id_idx" ON "public"."fund_transactions" USING "btree" ("fund_id");



CREATE INDEX "fund_transactions_household_id_date_idx" ON "public"."fund_transactions" USING "btree" ("household_id", "date");



CREATE INDEX "funds_household_id_idx" ON "public"."funds" USING "btree" ("household_id");



CREATE INDEX "income_budgets_household_id_month_idx" ON "public"."income_budgets" USING "btree" ("household_id", "month");



CREATE INDEX "profiles_household_id_idx" ON "public"."profiles" USING "btree" ("household_id");



CREATE INDEX "travel_expense_splits_expense_id_idx" ON "public"."travel_expense_splits" USING "btree" ("expense_id");



CREATE INDEX "travel_expenses_household_id_date_idx" ON "public"."travel_expenses" USING "btree" ("household_id", "date");



CREATE INDEX "travel_expenses_trip_id_idx" ON "public"."travel_expenses" USING "btree" ("trip_id");



CREATE INDEX "trips_household_id_idx" ON "public"."trips" USING "btree" ("household_id");



CREATE OR REPLACE VIEW "public"."fund_balances" WITH ("security_invoker"='true') AS
 SELECT "f"."household_id",
    "f"."id" AS "fund_id",
    "f"."name",
    "f"."country",
    "f"."currency",
    "f"."is_active",
    "f"."sort_order",
    "f"."group_name",
    "f"."is_leftover_target",
    COALESCE("sum"(
        CASE
            WHEN ("t"."type" = 'income'::"text") THEN "t"."amount"
            ELSE (- "t"."amount")
        END), (0)::numeric) AS "balance"
   FROM ("public"."funds" "f"
     LEFT JOIN "public"."fund_transactions" "t" ON (("t"."fund_id" = "f"."id")))
  GROUP BY "f"."id";



ALTER TABLE ONLY "public"."category_budgets"
    ADD CONSTRAINT "category_budgets_household_id_fkey" FOREIGN KEY ("household_id") REFERENCES "public"."households"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_expense_splits"
    ADD CONSTRAINT "daily_expense_splits_expense_id_fkey" FOREIGN KEY ("expense_id") REFERENCES "public"."daily_expenses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_expense_splits"
    ADD CONSTRAINT "daily_expense_splits_household_id_fkey" FOREIGN KEY ("household_id") REFERENCES "public"."households"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_expense_splits"
    ADD CONSTRAINT "daily_expense_splits_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."daily_expenses"
    ADD CONSTRAINT "daily_expenses_household_id_fkey" FOREIGN KEY ("household_id") REFERENCES "public"."households"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."daily_expenses"
    ADD CONSTRAINT "daily_expenses_payer_profile_id_fkey" FOREIGN KEY ("payer_profile_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."fund_budgets"
    ADD CONSTRAINT "fund_budgets_fund_id_fkey" FOREIGN KEY ("fund_id") REFERENCES "public"."funds"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fund_budgets"
    ADD CONSTRAINT "fund_budgets_household_id_fkey" FOREIGN KEY ("household_id") REFERENCES "public"."households"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."fund_transactions"
    ADD CONSTRAINT "fund_transactions_fund_id_fkey" FOREIGN KEY ("fund_id") REFERENCES "public"."funds"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."fund_transactions"
    ADD CONSTRAINT "fund_transactions_household_id_fkey" FOREIGN KEY ("household_id") REFERENCES "public"."households"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."funds"
    ADD CONSTRAINT "funds_household_id_fkey" FOREIGN KEY ("household_id") REFERENCES "public"."households"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."households"
    ADD CONSTRAINT "households_owner_user_id_fkey" FOREIGN KEY ("owner_user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."households"
    ADD CONSTRAINT "households_travel_fund_id_fkey" FOREIGN KEY ("travel_fund_id") REFERENCES "public"."funds"("id");



ALTER TABLE ONLY "public"."income_budgets"
    ADD CONSTRAINT "income_budgets_household_id_fkey" FOREIGN KEY ("household_id") REFERENCES "public"."households"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."income_budgets"
    ADD CONSTRAINT "income_budgets_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."payment_methods"
    ADD CONSTRAINT "payment_methods_household_id_fkey" FOREIGN KEY ("household_id") REFERENCES "public"."households"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payment_methods"
    ADD CONSTRAINT "payment_methods_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_auth_user_id_fkey" FOREIGN KEY ("auth_user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_household_id_fkey" FOREIGN KEY ("household_id") REFERENCES "public"."households"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."travel_expense_splits"
    ADD CONSTRAINT "travel_expense_splits_expense_id_fkey" FOREIGN KEY ("expense_id") REFERENCES "public"."travel_expenses"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."travel_expense_splits"
    ADD CONSTRAINT "travel_expense_splits_household_id_fkey" FOREIGN KEY ("household_id") REFERENCES "public"."households"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."travel_expense_splits"
    ADD CONSTRAINT "travel_expense_splits_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."travel_expenses"
    ADD CONSTRAINT "travel_expenses_household_id_fkey" FOREIGN KEY ("household_id") REFERENCES "public"."households"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."travel_expenses"
    ADD CONSTRAINT "travel_expenses_payer_profile_id_fkey" FOREIGN KEY ("payer_profile_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."travel_expenses"
    ADD CONSTRAINT "travel_expenses_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."trips"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."trips"
    ADD CONSTRAINT "trips_household_id_fkey" FOREIGN KEY ("household_id") REFERENCES "public"."households"("id") ON DELETE CASCADE;



ALTER TABLE "public"."beta_invites" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."category_budgets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."daily_expense_splits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."daily_expenses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."fund_budgets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."fund_transactions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."funds" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."households" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."income_budgets" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "own household only" ON "public"."category_budgets" USING (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "own household only" ON "public"."daily_expense_splits" USING (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "own household only" ON "public"."daily_expenses" USING (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "own household only" ON "public"."fund_budgets" USING (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "own household only" ON "public"."fund_transactions" USING (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "own household only" ON "public"."funds" USING (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "own household only" ON "public"."households" USING (("owner_user_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("owner_user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "own household only" ON "public"."income_budgets" USING (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "own household only" ON "public"."payment_methods" USING (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "own household only" ON "public"."profiles" USING (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "own household only" ON "public"."travel_expense_splits" USING (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "own household only" ON "public"."travel_expenses" USING (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid")))));



CREATE POLICY "own household only" ON "public"."trips" USING (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid"))))) WITH CHECK (("household_id" IN ( SELECT "households"."id"
   FROM "public"."households"
  WHERE ("households"."owner_user_id" = ( SELECT "auth"."uid"() AS "uid")))));



ALTER TABLE "public"."payment_methods" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."travel_expense_splits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."travel_expenses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."trips" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";






















































































































































REVOKE ALL ON FUNCTION "public"."check_invite"("p_code" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."check_invite"("p_code" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."check_invite"("p_code" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_invite"("p_code" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_household_setup"("p_code" "text", "p_household" "text", "p_people" "text"[], "p_joint_label" "text", "p_countries" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_household_setup"("p_code" "text", "p_household" "text", "p_people" "text"[], "p_joint_label" "text", "p_countries" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."create_household_setup"("p_code" "text", "p_household" "text", "p_people" "text"[], "p_joint_label" "text", "p_countries" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_household_setup"("p_code" "text", "p_household" "text", "p_people" "text"[], "p_joint_label" "text", "p_countries" "text"[]) TO "service_role";


















GRANT ALL ON TABLE "public"."beta_invites" TO "service_role";



GRANT ALL ON TABLE "public"."category_budgets" TO "anon";
GRANT ALL ON TABLE "public"."category_budgets" TO "authenticated";
GRANT ALL ON TABLE "public"."category_budgets" TO "service_role";



GRANT ALL ON TABLE "public"."daily_expense_splits" TO "anon";
GRANT ALL ON TABLE "public"."daily_expense_splits" TO "authenticated";
GRANT ALL ON TABLE "public"."daily_expense_splits" TO "service_role";



GRANT ALL ON TABLE "public"."daily_expenses" TO "anon";
GRANT ALL ON TABLE "public"."daily_expenses" TO "authenticated";
GRANT ALL ON TABLE "public"."daily_expenses" TO "service_role";



GRANT ALL ON TABLE "public"."fund_balances" TO "anon";
GRANT ALL ON TABLE "public"."fund_balances" TO "authenticated";
GRANT ALL ON TABLE "public"."fund_balances" TO "service_role";



GRANT ALL ON TABLE "public"."fund_budgets" TO "anon";
GRANT ALL ON TABLE "public"."fund_budgets" TO "authenticated";
GRANT ALL ON TABLE "public"."fund_budgets" TO "service_role";



GRANT ALL ON TABLE "public"."fund_transactions" TO "anon";
GRANT ALL ON TABLE "public"."fund_transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."fund_transactions" TO "service_role";



GRANT ALL ON TABLE "public"."funds" TO "anon";
GRANT ALL ON TABLE "public"."funds" TO "authenticated";
GRANT ALL ON TABLE "public"."funds" TO "service_role";



GRANT ALL ON TABLE "public"."households" TO "anon";
GRANT ALL ON TABLE "public"."households" TO "authenticated";
GRANT ALL ON TABLE "public"."households" TO "service_role";



GRANT ALL ON TABLE "public"."income_budgets" TO "anon";
GRANT ALL ON TABLE "public"."income_budgets" TO "authenticated";
GRANT ALL ON TABLE "public"."income_budgets" TO "service_role";



GRANT ALL ON TABLE "public"."payment_methods" TO "anon";
GRANT ALL ON TABLE "public"."payment_methods" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_methods" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON TABLE "public"."travel_expense_splits" TO "anon";
GRANT ALL ON TABLE "public"."travel_expense_splits" TO "authenticated";
GRANT ALL ON TABLE "public"."travel_expense_splits" TO "service_role";



GRANT ALL ON TABLE "public"."travel_expenses" TO "anon";
GRANT ALL ON TABLE "public"."travel_expenses" TO "authenticated";
GRANT ALL ON TABLE "public"."travel_expenses" TO "service_role";



GRANT ALL ON TABLE "public"."trips" TO "anon";
GRANT ALL ON TABLE "public"."trips" TO "authenticated";
GRANT ALL ON TABLE "public"."trips" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































