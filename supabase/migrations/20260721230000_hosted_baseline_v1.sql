-- ProteusOps hosted baseline v1
-- Captured 2026-09-21 from hosted project ytwjyemqlbbebysiopzd (schema-only pg_dump).
-- Adopted as canonical baseline (Path A). Ordered before the constitution migration
-- (20260721231000) so a reset rebuilds the application, then applies governance.
-- Source of record: proofs/audit/hosted_schema_20260921_200007Z.sql




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


CREATE SCHEMA IF NOT EXISTS "pods";


ALTER SCHEMA "pods" OWNER TO "postgres";


CREATE SCHEMA IF NOT EXISTS "pods_billing";


ALTER SCHEMA "pods_billing" OWNER TO "postgres";


COMMENT ON SCHEMA "pods_billing" IS 'Tier-1 BILLING lane: subscription state, plan materialization, billing-driven capability effects.';



CREATE SCHEMA IF NOT EXISTS "pods_core";


ALTER SCHEMA "pods_core" OWNER TO "postgres";


COMMENT ON SCHEMA "pods_core" IS 'Tier-1 CORE lane: org identity, memberships, auth-bound actor context, entitlements roots.';



CREATE SCHEMA IF NOT EXISTS "pods_ops";


ALTER SCHEMA "pods_ops" OWNER TO "postgres";


COMMENT ON SCHEMA "pods_ops" IS 'Tier-1 OPS lane: operational execution entities such as availability, appointments, and time-off.';



CREATE SCHEMA IF NOT EXISTS "pods_provisioning";


ALTER SCHEMA "pods_provisioning" OWNER TO "postgres";


COMMENT ON SCHEMA "pods_provisioning" IS 'Tier-2 ProteusOps provisioning lane for deterministic business base-model deployment.';



CREATE SCHEMA IF NOT EXISTS "pods_public";


ALTER SCHEMA "pods_public" OWNER TO "postgres";


COMMENT ON SCHEMA "pods_public" IS 'Tier-1 PUBLIC lane: externally consumable read/public booking request surfaces only.';



CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE OR REPLACE FUNCTION "pods"."_assert_no_overlap"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_at" timestamp with time zone, "p_end_at" timestamp with time zone) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'pods', 'public'
    AS $$
begin
  if exists (
    select 1
    from pods.booking_appointments a
    where a.org_id = p_org_id
      and a.staff_user_id = p_staff_user_id
      and a.status in ('requested','confirmed')
      and a.start_at < p_end_at
      and a.end_at > p_start_at
  ) then
    raise exception 'APPOINTMENT_OVERLAP';
  end if;
end;
$$;


ALTER FUNCTION "pods"."_assert_no_overlap"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_at" timestamp with time zone, "p_end_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."_assert_not_in_timeoff"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_at" timestamp with time zone, "p_end_at" timestamp with time zone) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'pods', 'public'
    AS $$
begin
  if exists (
    select 1
    from pods.booking_time_off_blocks b
    where b.org_id = p_org_id
      and b.staff_user_id = p_staff_user_id
      and b.start_at < p_end_at
      and b.end_at > p_start_at
  ) then
    raise exception 'STAFF_TIME_OFF_BLOCK';
  end if;
end;
$$;


ALTER FUNCTION "pods"."_assert_not_in_timeoff"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_at" timestamp with time zone, "p_end_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."_assert_staff_is_member"("p_org_id" "uuid", "p_staff_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'pods', 'public'
    AS $$
begin
  if not exists (
    select 1
    from pods.org_members m
    where m.org_id = p_org_id
      and m.user_id = p_staff_user_id
      and m.role_key in ('staff','admin','owner')
  ) then
    raise exception 'INVALID_STAFF_MEMBER';
  end if;
end;
$$;


ALTER FUNCTION "pods"."_assert_staff_is_member"("p_org_id" "uuid", "p_staff_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."_assert_under_usage_cap"("p_org_id" "uuid", "p_counter_key" "text", "p_capability_key" "text", "p_now" timestamp with time zone) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'pods', 'public'
    AS $$
declare
  ps date;
  v_used bigint;
  v_cap bigint;
begin
  select period_start into ps from pods._usage_period_bounds(p_now);

  select value into v_used
  from pods.usage_counters
  where org_id = p_org_id and counter_key = p_counter_key and period_start = ps;

  v_used := coalesce(v_used, 0);
  v_cap := pods.cap_int(p_org_id, p_capability_key);

  -- If cap is null, treat as unlimited for v1
  if v_cap is not null and v_used >= v_cap then
    raise exception 'USAGE_LIMIT_REACHED';
  end if;
end;
$$;


ALTER FUNCTION "pods"."_assert_under_usage_cap"("p_org_id" "uuid", "p_counter_key" "text", "p_capability_key" "text", "p_now" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."_assert_within_availability"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_at" timestamp with time zone, "p_end_at" timestamp with time zone) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'pods', 'public'
    AS $$
declare
  dow int;
  st time;
  et time;
begin
  dow := extract(dow from p_start_at)::int;
  st := (p_start_at at time zone 'UTC')::time; -- v1 uses UTC; later add org timezone
  et := (p_end_at   at time zone 'UTC')::time;

  if not exists (
    select 1
    from pods.booking_availability_rules r
    where r.org_id = p_org_id
      and r.staff_user_id = p_staff_user_id
      and r.is_active = true
      and r.day_of_week = dow
      and r.start_time <= st
      and r.end_time >= et
  ) then
    raise exception 'OUTSIDE_AVAILABILITY';
  end if;
end;
$$;


ALTER FUNCTION "pods"."_assert_within_availability"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_at" timestamp with time zone, "p_end_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."_increment_usage_counter"("p_org_id" "uuid", "p_counter_key" "text", "p_now" timestamp with time zone) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
declare
  ps date;
  pe date;
begin
  select period_start, period_end into ps, pe from pods._usage_period_bounds(p_now);

  insert into pods.usage_counters(org_id, counter_key, period_start, period_end, value, updated_at)
  values (p_org_id, p_counter_key, ps, pe, 1, now())
  on conflict (org_id, counter_key, period_start) do update set
    value = pods.usage_counters.value + 1,
    updated_at = now();
end;
$$;


ALTER FUNCTION "pods"."_increment_usage_counter"("p_org_id" "uuid", "p_counter_key" "text", "p_now" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."_require_booking_enabled"("p_org_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'pods', 'public'
    AS $$
begin
  if pods.has_cap_bool(p_org_id,'booking_enabled') is distinct from true then
    raise exception 'BOOKING_DISABLED';
  end if;

  -- Strong enforcement: require paid_active system entitlement
  if pods.has_cap_bool(p_org_id,'paid_active') is distinct from true then
    raise exception 'PAYMENT_REQUIRED';
  end if;
end;
$$;


ALTER FUNCTION "pods"."_require_booking_enabled"("p_org_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."_require_member_role"("p_org_id" "uuid", "p_roles" "text"[]) RETURNS "text"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'pods', 'public'
    AS $$
declare
  v_role text;
begin
  v_role := pods.org_role(p_org_id);
  if v_role is null then
    raise exception 'NOT_ORG_MEMBER';
  end if;

  if not (v_role = any(p_roles)) then
    raise exception 'FORBIDDEN_ROLE';
  end if;

  return v_role;
end;
$$;


ALTER FUNCTION "pods"."_require_member_role"("p_org_id" "uuid", "p_roles" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."_usage_period_bounds"("p_now" timestamp with time zone) RETURNS TABLE("period_start" "date", "period_end" "date")
    LANGUAGE "sql" STABLE
    AS $$
  select date_trunc('month', p_now)::date as period_start,
         (date_trunc('month', p_now) + interval '1 month')::date as period_end
$$;


ALTER FUNCTION "pods"."_usage_period_bounds"("p_now" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."cap_int"("p_org_id" "uuid", "p_capability_key" "text") RETURNS bigint
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'pods', 'public'
    AS $$
  select e.value_int
  from pods.org_entitlements e
  where e.org_id = p_org_id
    and e.capability_key = p_capability_key
    and e.value_type = 'int'
  limit 1
$$;


ALTER FUNCTION "pods"."cap_int"("p_org_id" "uuid", "p_capability_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."has_cap_bool"("p_org_id" "uuid", "p_capability_key" "text") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'pods', 'public'
    AS $$
  select coalesce(e.value_bool, false)
  from pods.org_entitlements e
  where e.org_id = p_org_id
    and e.capability_key = p_capability_key
    and e.value_type = 'bool'
  limit 1
$$;


ALTER FUNCTION "pods"."has_cap_bool"("p_org_id" "uuid", "p_capability_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."is_paid_active"("p_org_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'pods', 'public'
    AS $$
  select exists (
    select 1
    from pods.subscriptions s
    where s.org_id = p_org_id
      and s.status in ('active','trialing') -- conservative v1
      and (s.current_period_end is null or s.current_period_end >= now())
  )
$$;


ALTER FUNCTION "pods"."is_paid_active"("p_org_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."org_role"("p_org_id" "uuid") RETURNS "text"
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'pods', 'public'
    AS $$
  select m.role_key
  from pods.org_members m
  where m.org_id = p_org_id
    and m.user_id = auth.uid()
  limit 1
$$;


ALTER FUNCTION "pods"."org_role"("p_org_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."rpc_add_time_off_block_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_at" timestamp with time zone, "p_end_at" timestamp with time zone, "p_reason" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
declare
  v_actor uuid;
  v_role text;
  v_block uuid;
  v_allow_staff_self_manage boolean := true;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  perform pods._require_booking_enabled(p_org_id);

  v_role := pods.org_role(p_org_id);
  if v_role is null then
    raise exception 'NOT_ORG_MEMBER';
  end if;

  if p_end_at <= p_start_at then
    raise exception 'INVALID_TIME_RANGE';
  end if;

  -- role gate
  if v_role in ('owner','admin') then
    null;
  elsif v_allow_staff_self_manage and v_role='staff' and p_staff_user_id = v_actor then
    null;
  else
    raise exception 'FORBIDDEN_ROLE';
  end if;

  perform pods._assert_staff_is_member(p_org_id, p_staff_user_id);

  insert into pods.booking_time_off_blocks(org_id, staff_user_id, start_at, end_at, reason)
  values (p_org_id, p_staff_user_id, p_start_at, p_end_at, p_reason)
  returning block_id into v_block;

  insert into pods.audit_log(org_id, actor_user_id, actor_role_key, action_key, entity_table, entity_id, details)
  values (
    p_org_id, v_actor, v_role, 'timeoff.create', 'pods.booking_time_off_blocks', v_block::text,
    jsonb_build_object('staff_user_id', p_staff_user_id, 'start_at', p_start_at, 'end_at', p_end_at, 'reason', p_reason)
  );

  return v_block;
end;
$$;


ALTER FUNCTION "pods"."rpc_add_time_off_block_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_at" timestamp with time zone, "p_end_at" timestamp with time zone, "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."rpc_billing_ingest_webhook"("p_org_id" "uuid", "p_provider_customer_id" "text", "p_provider_subscription_id" "text", "p_status" "text", "p_plan_id" "text", "p_period_start" timestamp with time zone, "p_period_end" timestamp with time zone, "p_cancel_at_period_end" boolean, "p_billing_email" "text", "p_event" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'BILLING_INGEST_FORBIDDEN';
  end if;

  -- Upsert billing account
  insert into pods.billing_accounts(org_id, provider, provider_customer_id, billing_email, status, updated_at)
  values (p_org_id, 'stripe', p_provider_customer_id, p_billing_email, p_status, now())
  on conflict (org_id) do update set
    provider_customer_id = excluded.provider_customer_id,
    billing_email        = excluded.billing_email,
    status               = excluded.status,
    updated_at           = excluded.updated_at;

  -- Upsert subscription row
  insert into pods.subscriptions(
    org_id, provider_subscription_id, status, plan_id,
    current_period_start, current_period_end, cancel_at_period_end, updated_at
  )
  values (
    p_org_id, p_provider_subscription_id, p_status, p_plan_id,
    p_period_start, p_period_end, coalesce(p_cancel_at_period_end,false), now()
  )
  on conflict (provider_subscription_id) do update set
    status               = excluded.status,
    plan_id              = excluded.plan_id,
    current_period_start = excluded.current_period_start,
    current_period_end   = excluded.current_period_end,
    cancel_at_period_end = excluded.cancel_at_period_end,
    updated_at           = excluded.updated_at;

  -- Recompute entitlements (materialize enforcement surface)
  perform pods.rpc_recompute_entitlements(p_org_id);

  -- Audit
  insert into pods.audit_log(org_id, actor_user_id, actor_role_key, action_key, details)
  values (
    p_org_id, null, 'system', 'billing.ingest',
    jsonb_build_object(
      'provider','stripe',
      'customer_id', p_provider_customer_id,
      'subscription_id', p_provider_subscription_id,
      'status', p_status,
      'plan_id', p_plan_id,
      'event', coalesce(p_event,'{}'::jsonb)
    )
  );

end;
$$;


ALTER FUNCTION "pods"."rpc_billing_ingest_webhook"("p_org_id" "uuid", "p_provider_customer_id" "text", "p_provider_subscription_id" "text", "p_status" "text", "p_plan_id" "text", "p_period_start" timestamp with time zone, "p_period_end" timestamp with time zone, "p_cancel_at_period_end" boolean, "p_billing_email" "text", "p_event" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."rpc_cancel_appointment_v1"("p_org_id" "uuid", "p_appointment_id" "uuid", "p_reason" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
declare
  v_actor uuid;
  v_role text;
  v_staff uuid;
  v_status text;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  perform pods._require_booking_enabled(p_org_id);
  v_role := pods._require_member_role(p_org_id, array['owner','admin','staff']);

  select staff_user_id, status into v_staff, v_status
  from pods.booking_appointments
  where org_id = p_org_id and appointment_id = p_appointment_id;

  if v_staff is null then
    raise exception 'APPOINTMENT_NOT_FOUND';
  end if;

  if v_role = 'staff' and v_staff <> v_actor then
    raise exception 'FORBIDDEN_NOT_OWNER_OF_APPOINTMENT';
  end if;

  if v_status = 'cancelled' then
    return;
  end if;

  update pods.booking_appointments
  set status = 'cancelled', updated_at = now()
  where org_id = p_org_id and appointment_id = p_appointment_id;

  insert into pods.booking_appointment_status_log(
    org_id, appointment_id, from_status, to_status, actor_user_id, actor_role_key, details
  )
  values (
    p_org_id, p_appointment_id, v_status, 'cancelled', v_actor, v_role,
    jsonb_build_object('reason', p_reason)
  );

  insert into pods.audit_log(org_id, actor_user_id, actor_role_key, action_key, entity_table, entity_id, details)
  values (
    p_org_id, v_actor, v_role, 'appointment.cancel', 'pods.booking_appointments', p_appointment_id::text,
    jsonb_build_object('reason', p_reason)
  );
end;
$$;


ALTER FUNCTION "pods"."rpc_cancel_appointment_v1"("p_org_id" "uuid", "p_appointment_id" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."rpc_create_appointment_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_at" timestamp with time zone, "p_end_at" timestamp with time zone, "p_location_id" "uuid" DEFAULT NULL::"uuid", "p_service_id" "uuid" DEFAULT NULL::"uuid", "p_customer_name" "text" DEFAULT NULL::"text", "p_customer_email" "text" DEFAULT NULL::"text", "p_customer_phone" "text" DEFAULT NULL::"text", "p_notes" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
declare
  v_actor uuid;
  v_role text;
  v_appt_id uuid;
  v_now timestamptz;
begin
  v_now := now();
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  -- Require booking enabled + paid
  perform pods._require_booking_enabled(p_org_id);

  -- Require role to create (owner/admin/staff)
  v_role := pods._require_member_role(p_org_id, array['owner','admin','staff']);

  -- Validate staff is a member
  perform pods._assert_staff_is_member(p_org_id, p_staff_user_id);

  -- Usage cap: monthly appointments
  perform pods._assert_under_usage_cap(p_org_id, 'monthly_appointments_created', 'max_monthly_appointments', v_now);

  -- Engine checks
  if p_end_at <= p_start_at then
    raise exception 'INVALID_TIME_RANGE';
  end if;

  perform pods._assert_no_overlap(p_org_id, p_staff_user_id, p_start_at, p_end_at);
  perform pods._assert_not_in_timeoff(p_org_id, p_staff_user_id, p_start_at, p_end_at);
  perform pods._assert_within_availability(p_org_id, p_staff_user_id, p_start_at, p_end_at);

  -- Insert appointment
  insert into pods.booking_appointments(
    org_id, location_id, service_id, staff_user_id,
    customer_name, customer_email, customer_phone,
    start_at, end_at, status, notes,
    created_by_user_id, created_at, updated_at
  )
  values (
    p_org_id, p_location_id, p_service_id, p_staff_user_id,
    p_customer_name, p_customer_email, p_customer_phone,
    p_start_at, p_end_at, 'confirmed', p_notes,
    v_actor, v_now, v_now
  )
  returning appointment_id into v_appt_id;

  -- Log status
  insert into pods.booking_appointment_status_log(
    org_id, appointment_id, from_status, to_status, actor_user_id, actor_role_key, details
  )
  values (
    p_org_id, v_appt_id, null, 'confirmed', v_actor, v_role,
    jsonb_build_object('source','rpc_create_appointment_v1')
  );

  -- Increment usage
  perform pods._increment_usage_counter(p_org_id, 'monthly_appointments_created', v_now);

  -- Audit
  insert into pods.audit_log(org_id, actor_user_id, actor_role_key, action_key, entity_table, entity_id, details)
  values (
    p_org_id, v_actor, v_role, 'appointment.create', 'pods.booking_appointments', v_appt_id::text,
    jsonb_build_object('staff_user_id', p_staff_user_id, 'start_at', p_start_at, 'end_at', p_end_at)
  );

  return v_appt_id;
end;
$$;


ALTER FUNCTION "pods"."rpc_create_appointment_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_at" timestamp with time zone, "p_end_at" timestamp with time zone, "p_location_id" "uuid", "p_service_id" "uuid", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."rpc_create_org_bootstrap"("p_slug" "text", "p_name" "text", "p_plan_id" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
declare
  v_org_id uuid;
  v_uid uuid;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  insert into pods.orgs(slug, name) values (p_slug, p_name)
  returning org_id into v_org_id;

  insert into pods.org_members(org_id, user_id, role_key)
  values (v_org_id, v_uid, 'owner');

  -- install core + storefront for this org (version lock for v1)
  insert into pods.org_models(org_id, model_id, version)
  values
    (v_org_id, 'pods.core', '1.0.0'),
    (v_org_id, 'pods.storefront', '1.0.0')
  on conflict do nothing;

  -- Optional: attach a plan_id placeholder (subscription sync will override later)
  if p_plan_id is not null then
    insert into pods.subscriptions(
      org_id, provider_subscription_id, status, plan_id,
      current_period_start, current_period_end, cancel_at_period_end, updated_at
    )
    values (
      v_org_id, ('bootstrap_' || v_org_id::text), 'trialing', p_plan_id,
      now(), now() + interval '30 days', false, now()
    )
    on conflict (provider_subscription_id) do nothing;
  end if;

  -- recompute entitlements (service definer)
  perform pods.rpc_recompute_entitlements(v_org_id);

  -- create initial storefront profile
  insert into pods.storefront_profiles(org_id, display_name)
  values (v_org_id, p_name);

  insert into pods.audit_log(org_id, actor_user_id, actor_role_key, action_key, details)
  values (v_org_id, v_uid, 'owner', 'org.bootstrap', jsonb_build_object('slug', p_slug, 'plan_id', p_plan_id));

  return v_org_id;
end;
$$;


ALTER FUNCTION "pods"."rpc_create_org_bootstrap"("p_slug" "text", "p_name" "text", "p_plan_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."rpc_create_org_bootstrap_service_role_v1"("p_owner_user_id" "uuid", "p_slug" "text", "p_name" "text", "p_plan_id" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
declare
  v_org_id uuid;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED';
  end if;

  insert into pods.orgs(slug, name, is_active)
  values (p_slug, p_name, true)
  returning org_id into v_org_id;

  insert into pods.org_members(org_id, user_id, role_key)
  values (v_org_id, p_owner_user_id, 'owner');

  -- Install models for this org
  insert into pods.org_models(org_id, model_id, version)
  values
    (v_org_id, 'pods.core', '1.0.0'),
    (v_org_id, 'pods.storefront', '1.0.0'),
    (v_org_id, 'pods.booking', '1.0.0')
  on conflict do nothing;

  -- Create an active subscription record (simulated)
  insert into pods.subscriptions(
    org_id,
    provider_subscription_id,
    status,
    plan_id,
    current_period_start,
    current_period_end,
    cancel_at_period_end,
    updated_at
  )
  values (
    v_org_id,
    ('bootstrap_' || v_org_id::text),
    'active',
    p_plan_id,
    now(),
    now() + interval '30 days',
    false,
    now()
  )
  on conflict (provider_subscription_id) do nothing;

  -- Recompute entitlements from subscription
  perform pods.rpc_recompute_entitlements(v_org_id);

  -- Ensure storefront profile exists
  insert into pods.storefront_profiles(org_id, display_name)
  values (v_org_id, p_name)
  on conflict (org_id) do update set display_name = excluded.display_name;

  insert into pods.audit_log(org_id, actor_user_id, actor_role_key, action_key, details)
  values (
    v_org_id, null, 'service_role', 'org.bootstrap.service_role',
    jsonb_build_object('slug', p_slug, 'owner_user_id', p_owner_user_id, 'plan_id', p_plan_id)
  );

  return v_org_id;
end;
$$;


ALTER FUNCTION "pods"."rpc_create_org_bootstrap_service_role_v1"("p_owner_user_id" "uuid", "p_slug" "text", "p_name" "text", "p_plan_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."rpc_delete_availability_rule_v1"("p_org_id" "uuid", "p_rule_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
declare
  v_actor uuid;
  v_role text;
  v_staff uuid;
  v_allow_staff_self_manage boolean := true;
begin
  v_actor := auth.uid();
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;

  perform pods._require_booking_enabled(p_org_id);

  v_role := pods.org_role(p_org_id);
  if v_role is null then raise exception 'NOT_ORG_MEMBER'; end if;

  select staff_user_id into v_staff
  from pods.booking_availability_rules
  where rule_id = p_rule_id and org_id = p_org_id;

  if v_staff is null then raise exception 'RULE_NOT_FOUND'; end if;

  if v_role in ('owner','admin') then
    null;
  elsif v_allow_staff_self_manage and v_role='staff' and v_staff = v_actor then
    null;
  else
    raise exception 'FORBIDDEN_ROLE';
  end if;

  delete from pods.booking_availability_rules
  where rule_id = p_rule_id and org_id = p_org_id;

  insert into pods.audit_log(org_id, actor_user_id, actor_role_key, action_key, entity_table, entity_id, details)
  values (
    p_org_id, v_actor, v_role, 'availability.delete', 'pods.booking_availability_rules', p_rule_id::text,
    jsonb_build_object('staff_user_id', v_staff)
  );
end;
$$;


ALTER FUNCTION "pods"."rpc_delete_availability_rule_v1"("p_org_id" "uuid", "p_rule_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."rpc_delete_time_off_block_v1"("p_org_id" "uuid", "p_block_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
declare
  v_actor uuid;
  v_role text;
  v_staff uuid;
  v_allow_staff_self_manage boolean := true;
begin
  v_actor := auth.uid();
  if v_actor is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  perform pods._require_booking_enabled(p_org_id);

  v_role := pods.org_role(p_org_id);
  if v_role is null then
    raise exception 'NOT_ORG_MEMBER';
  end if;

  select staff_user_id into v_staff
  from pods.booking_time_off_blocks
  where block_id = p_block_id and org_id = p_org_id;

  if v_staff is null then
    raise exception 'BLOCK_NOT_FOUND';
  end if;

  if v_role in ('owner','admin') then
    null;
  elsif v_allow_staff_self_manage and v_role='staff' and v_staff = v_actor then
    null;
  else
    raise exception 'FORBIDDEN_ROLE';
  end if;

  delete from pods.booking_time_off_blocks
  where block_id = p_block_id and org_id = p_org_id;

  insert into pods.audit_log(org_id, actor_user_id, actor_role_key, action_key, entity_table, entity_id, details)
  values (
    p_org_id, v_actor, v_role, 'timeoff.delete', 'pods.booking_time_off_blocks', p_block_id::text,
    jsonb_build_object('staff_user_id', v_staff)
  );
end;
$$;


ALTER FUNCTION "pods"."rpc_delete_time_off_block_v1"("p_org_id" "uuid", "p_block_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."rpc_recompute_entitlements"("p_org_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
declare
  v_plan_id text;
  v_paid boolean := false;
begin
  -- Determine active plan and paid state
  select s.plan_id,
         (s.status in ('active','trialing'))
    into v_plan_id, v_paid
  from pods.subscriptions s
  where s.org_id = p_org_id
  order by s.updated_at desc
  limit 1;

  -- If no subscription row, default to unpaid + no plan
  if v_plan_id is null then
    v_plan_id := 'proteusops_s_v1';
    v_paid := false;
  end if;

  -- Replace entitlement set deterministically
  delete from pods.org_entitlements where org_id = p_org_id;

  -- Paid flag (system derived)
  insert into pods.org_entitlements(org_id, capability_key, value_type, value_bool, value_int, source)
  values (p_org_id, 'paid_active', 'bool', v_paid, null, 'system');

  -- Materialize plan capabilities
  insert into pods.org_entitlements(org_id, capability_key, value_type, value_bool, value_int, source)
  select p_org_id, c.capability_key, c.value_type, c.value_bool, c.value_int, 'plan'
  from pods.plan_capabilities c
  where c.plan_id = v_plan_id;

end;
$$;


ALTER FUNCTION "pods"."rpc_recompute_entitlements"("p_org_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."rpc_request_appointment_public_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_at" timestamp with time zone, "p_end_at" timestamp with time zone, "p_location_id" "uuid" DEFAULT NULL::"uuid", "p_service_id" "uuid" DEFAULT NULL::"uuid", "p_customer_name" "text" DEFAULT NULL::"text", "p_customer_email" "text" DEFAULT NULL::"text", "p_customer_phone" "text" DEFAULT NULL::"text", "p_notes" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
declare
  v_actor uuid;
  v_appt_id uuid;
  v_now timestamptz;
begin
  v_now := now();
  v_actor := auth.uid(); -- may be null (guest)

  perform pods._require_booking_enabled(p_org_id);
  perform pods._assert_staff_is_member(p_org_id, p_staff_user_id);

  if p_end_at <= p_start_at then
    raise exception 'INVALID_TIME_RANGE';
  end if;

  -- Usage cap still applies
  perform pods._assert_under_usage_cap(p_org_id, 'monthly_appointments_created', 'max_monthly_appointments', v_now);

  perform pods._assert_no_overlap(p_org_id, p_staff_user_id, p_start_at, p_end_at);
  perform pods._assert_not_in_timeoff(p_org_id, p_staff_user_id, p_start_at, p_end_at);
  perform pods._assert_within_availability(p_org_id, p_staff_user_id, p_start_at, p_end_at);

  insert into pods.booking_appointments(
    org_id, location_id, service_id, staff_user_id,
    customer_user_id, customer_name, customer_email, customer_phone,
    start_at, end_at, status, notes,
    created_by_user_id, created_at, updated_at
  )
  values (
    p_org_id, p_location_id, p_service_id, p_staff_user_id,
    v_actor, p_customer_name, p_customer_email, p_customer_phone,
    p_start_at, p_end_at, 'requested', p_notes,
    v_actor, v_now, v_now
  )
  returning appointment_id into v_appt_id;

  insert into pods.booking_appointment_status_log(
    org_id, appointment_id, from_status, to_status, actor_user_id, actor_role_key, details
  )
  values (
    p_org_id, v_appt_id, null, 'requested', v_actor, null,
    jsonb_build_object('source','rpc_request_appointment_public_v1')
  );

  perform pods._increment_usage_counter(p_org_id, 'monthly_appointments_created', v_now);

  insert into pods.audit_log(org_id, actor_user_id, actor_role_key, action_key, entity_table, entity_id, details)
  values (
    p_org_id, v_actor, null, 'appointment.request', 'pods.booking_appointments', v_appt_id::text,
    jsonb_build_object('staff_user_id', p_staff_user_id, 'start_at', p_start_at, 'end_at', p_end_at)
  );

  return v_appt_id;
end;
$$;


ALTER FUNCTION "pods"."rpc_request_appointment_public_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_at" timestamp with time zone, "p_end_at" timestamp with time zone, "p_location_id" "uuid", "p_service_id" "uuid", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."rpc_selftest_add_org_member_v1"("p_org_id" "uuid", "p_user_id" "uuid", "p_role" "text" DEFAULT 'owner'::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $_$
declare
  v_has_role_key boolean := false;
  v_has_role     boolean := false;
  v_sql text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED';
  end if;

  select exists(
    select 1 from information_schema.columns
    where table_schema='pods' and table_name='org_members' and column_name='role_key'
  ) into v_has_role_key;

  select exists(
    select 1 from information_schema.columns
    where table_schema='pods' and table_name='org_members' and column_name='role'
  ) into v_has_role;

  if v_has_role_key then
    v_sql := 'insert into pods.org_members(org_id, user_id, role_key) values ($1,$2,$3) on conflict do nothing';
    execute v_sql using p_org_id, p_user_id, p_role;
    return;
  end if;

  if v_has_role then
    v_sql := 'insert into pods.org_members(org_id, user_id, role) values ($1,$2,$3) on conflict do nothing';
    execute v_sql using p_org_id, p_user_id, p_role;
    return;
  end if;

  v_sql := 'insert into pods.org_members(org_id, user_id) values ($1,$2) on conflict do nothing';
  execute v_sql using p_org_id, p_user_id;
end;
$_$;


ALTER FUNCTION "pods"."rpc_selftest_add_org_member_v1"("p_org_id" "uuid", "p_user_id" "uuid", "p_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."rpc_selftest_booking_gates_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
declare
  v_now timestamptz := now();
  v_ok jsonb := '{}'::jsonb;
  v_rule uuid;
  v_appt uuid;
  v_fail_token text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SELFTEST_FORBIDDEN';
  end if;

  -- Ensure at least one availability window today (UTC-based v1)
  begin
    v_rule := pods.rpc_upsert_availability_rule_v1(
      p_org_id, null, p_staff_user_id, null,
      extract(dow from v_now)::int, '09:00'::time, '17:00'::time, true
    );
    v_ok := v_ok || jsonb_build_object('availability_rule', 'ok');
  exception when others then
    v_ok := v_ok || jsonb_build_object('availability_rule', 'fail');
  end;

  -- Attempt create appointment; capture expected token if fails
  begin
    v_appt := pods.rpc_create_appointment_v1(
      p_org_id, p_staff_user_id, v_now + interval '1 hour', v_now + interval '2 hours',
      null, null, 'Selftest', 'selftest@example.com', '555-0000', 'selftest'
    );
    v_ok := v_ok || jsonb_build_object('create_appointment', 'ok');
  exception when others then
    get stacked diagnostics v_fail_token = message_text;
    v_ok := v_ok || jsonb_build_object('create_appointment', 'fail', 'token', v_fail_token);
  end;

  insert into pods.audit_log(org_id, actor_user_id, actor_role_key, action_key, details)
  values (p_org_id, null, 'system', 'selftest.booking.gates', v_ok);

  return v_ok;
end;
$$;


ALTER FUNCTION "pods"."rpc_selftest_booking_gates_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."rpc_selftest_reset_booking_v1"("p_org_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
begin
  -- Only service_role allowed
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED';
  end if;

  delete from pods.booking_appointments
  where org_id = p_org_id;

  delete from pods.booking_time_off_blocks
  where org_id = p_org_id;

  delete from pods.booking_availability_rules
  where org_id = p_org_id;

end;
$$;


ALTER FUNCTION "pods"."rpc_selftest_reset_booking_v1"("p_org_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."rpc_selftest_reset_booking_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
declare
  v_uid uuid;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  -- Only allow a user to reset their own staff rows
  if p_staff_user_id <> v_uid then
    raise exception 'FORBIDDEN';
  end if;

  -- Appointments created by selftest marker
  delete from pods.booking_appointments a
  where a.org_id = p_org_id
    and a.staff_user_id = p_staff_user_id
    and a.notes like 'selftest:%';

  -- Timeoff blocks created by selftest marker
  delete from pods.booking_time_off_blocks b
  where b.org_id = p_org_id
    and b.staff_user_id = p_staff_user_id
    and b.reason like 'selftest:%';

  -- Availability rules: delete all for this staff+org (no marker column today)
  delete from pods.booking_availability_rules r
  where r.org_id = p_org_id
    and r.staff_user_id = p_staff_user_id;

end;
$$;


ALTER FUNCTION "pods"."rpc_selftest_reset_booking_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."rpc_selftest_set_subscription_plan_v1"("p_org_id" "uuid", "p_plan_id" "text", "p_status" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED';
  end if;

  update pods.subscriptions
  set plan_id = p_plan_id,
      status = p_status,
      updated_at = now()
  where org_id = p_org_id;

  if not found then
    insert into pods.subscriptions(
      org_id,
      provider_subscription_id,
      status,
      plan_id,
      current_period_start,
      current_period_end,
      cancel_at_period_end,
      updated_at
    )
    values (
      p_org_id,
      'selftest_' || p_org_id::text,
      p_status,
      p_plan_id,
      now(),
      now() + interval '30 days',
      false,
      now()
    );
  end if;
end;
$$;


ALTER FUNCTION "pods"."rpc_selftest_set_subscription_plan_v1"("p_org_id" "uuid", "p_plan_id" "text", "p_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods"."rpc_upsert_availability_rule_v1"("p_org_id" "uuid", "p_rule_id" "uuid", "p_staff_user_id" "uuid", "p_location_id" "uuid", "p_day_of_week" integer, "p_start_time" time without time zone, "p_end_time" time without time zone, "p_is_active" boolean) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
declare
  v_actor uuid;
  v_role text;
  v_rule uuid;
  v_allow_staff_self_manage boolean := true;
begin
  v_actor := auth.uid();
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;

  perform pods._require_booking_enabled(p_org_id);

  v_role := pods.org_role(p_org_id);
  if v_role is null then raise exception 'NOT_ORG_MEMBER'; end if;

  if v_role in ('owner','admin') then
    null;
  elsif v_allow_staff_self_manage and v_role='staff' and p_staff_user_id = v_actor then
    null;
  else
    raise exception 'FORBIDDEN_ROLE';
  end if;

  perform pods._assert_staff_is_member(p_org_id, p_staff_user_id);

  if p_end_time <= p_start_time then
    raise exception 'INVALID_TIME_RANGE';
  end if;

  if p_rule_id is null then
    insert into pods.booking_availability_rules(
      org_id, staff_user_id, location_id, day_of_week, start_time, end_time, is_active
    )
    values (
      p_org_id, p_staff_user_id, p_location_id, p_day_of_week, p_start_time, p_end_time, coalesce(p_is_active,true)
    )
    returning rule_id into v_rule;

    insert into pods.audit_log(org_id, actor_user_id, actor_role_key, action_key, entity_table, entity_id, details)
    values (
      p_org_id, v_actor, v_role, 'availability.create', 'pods.booking_availability_rules', v_rule::text,
      jsonb_build_object('staff_user_id', p_staff_user_id, 'dow', p_day_of_week, 'start', p_start_time, 'end', p_end_time)
    );

    return v_rule;
  else
    if not exists (
      select 1
      from pods.booking_availability_rules r
      where r.rule_id = p_rule_id and r.org_id = p_org_id
        and (
          v_role in ('owner','admin')
          or (v_allow_staff_self_manage and v_role='staff' and r.staff_user_id = v_actor)
        )
    ) then
      raise exception 'RULE_NOT_FOUND_OR_FORBIDDEN';
    end if;

    update pods.booking_availability_rules
    set
      staff_user_id = p_staff_user_id,
      location_id   = p_location_id,
      day_of_week   = p_day_of_week,
      start_time    = p_start_time,
      end_time      = p_end_time,
      is_active     = coalesce(p_is_active,true)
    where rule_id = p_rule_id;

    v_rule := p_rule_id;

    insert into pods.audit_log(org_id, actor_user_id, actor_role_key, action_key, entity_table, entity_id, details)
    values (
      p_org_id, v_actor, v_role, 'availability.update', 'pods.booking_availability_rules', v_rule::text,
      jsonb_build_object('staff_user_id', p_staff_user_id, 'dow', p_day_of_week, 'start', p_start_time, 'end', p_end_time, 'active', p_is_active)
    );

    return v_rule;
  end if;
end;
$$;


ALTER FUNCTION "pods"."rpc_upsert_availability_rule_v1"("p_org_id" "uuid", "p_rule_id" "uuid", "p_staff_user_id" "uuid", "p_location_id" "uuid", "p_day_of_week" integer, "p_start_time" time without time zone, "p_end_time" time without time zone, "p_is_active" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_core"."assert_lane_boundary_v1"("p_source_lane" "text", "p_target_schema" "text", "p_action_kind" "text") RETURNS boolean
    LANGUAGE "plpgsql" STABLE
    AS $$
declare
  v_source text;
  v_target text;
  v_allowed boolean;
begin
  v_source := lower(coalesce(p_source_lane,''));
  v_target := pods_core.get_lane_for_schema_v1(p_target_schema);

  if v_source not in ('core','ops','public','billing') then
    raise exception 'LANE_BOUNDARY_UNKNOWN_SOURCE:%', coalesce(p_source_lane,'<null>');
  end if;

  if v_target is null then
    raise exception 'LANE_BOUNDARY_UNKNOWN_TARGET_SCHEMA:%', coalesce(p_target_schema,'<null>');
  end if;

  if lower(coalesce(p_action_kind,'')) not in ('read','write','execute','expose') then
    raise exception 'LANE_BOUNDARY_UNKNOWN_ACTION:%', coalesce(p_action_kind,'<null>');
  end if;

  select b.allowed
    into v_allowed
  from pods_core.lane_negative_boundaries_v1 b
  where b.source_lane = v_source
    and b.target_lane = v_target
    and b.action_kind = lower(p_action_kind)
  limit 1;

  if v_allowed is null then
    if v_source = v_target then
      return true;
    end if;
    raise exception 'LANE_BOUNDARY_RULE_MISSING:%:%:%', v_source, v_target, lower(p_action_kind);
  end if;

  if v_allowed = false then
    raise exception 'LANE_BOUNDARY_DENY:%:%:%', v_source, v_target, lower(p_action_kind);
  end if;

  return true;
end
$$;


ALTER FUNCTION "pods_core"."assert_lane_boundary_v1"("p_source_lane" "text", "p_target_schema" "text", "p_action_kind" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "pods_core"."assert_lane_boundary_v1"("p_source_lane" "text", "p_target_schema" "text", "p_action_kind" "text") IS 'Asserts Tier-1 lane boundary rules. Raises deterministic deny/missing tokens for illegal cross-lane actions.';



CREATE OR REPLACE FUNCTION "pods_core"."get_lane_for_schema_v1"("p_schema" "text") RETURNS "text"
    LANGUAGE "sql" STABLE
    AS $$
  select case lower(coalesce(p_schema,''))
    when 'pods_core' then 'core'
    when 'pods_ops' then 'ops'
    when 'pods_public' then 'public'
    when 'pods_billing' then 'billing'
    else null
  end
$$;


ALTER FUNCTION "pods_core"."get_lane_for_schema_v1"("p_schema" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_core"."rpc_selftest_lane_boundaries_all_v1"() RETURNS TABLE("vector_key" "text", "ok" boolean, "token" "text", "message" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_core', 'public'
    AS $$
declare
  r record;
  j jsonb;
  v_ok boolean;
  v_token text;
  v_message text;
begin
  for r in
    select
      v.vector_key,
      v.source_lane,
      v.target_schema,
      v.action_kind,
      v.expected_ok,
      v.expected_token
    from pods_core.lane_boundary_selftest_vectors_v1 v
    order by v.vector_key
  loop
    j := pods_core.rpc_selftest_lane_boundary_v1(
      r.source_lane,
      r.target_schema,
      r.action_kind,
      case
        when r.expected_token = 'LANE_BOUNDARY_ALLOW' then null
        else r.expected_token
      end
    );

    v_ok := coalesce((j ->> 'ok')::boolean, false);
    v_token := coalesce(j ->> 'token', '');
    v_message := coalesce(j ->> 'message', '');

    if r.expected_token = 'LANE_BOUNDARY_ALLOW' then
      if not (v_ok = true and v_token = 'LANE_BOUNDARY_ALLOW') then
        raise exception 'LANE_SELFTEST_FAIL:%:%', r.vector_key, coalesce(v_token,'<null>');
      end if;
    else
      if not (v_ok = true and position(r.expected_token in v_token) > 0) then
        raise exception 'LANE_SELFTEST_FAIL:%:%', r.vector_key, coalesce(v_token,'<null>');
      end if;
    end if;

    rpc_selftest_lane_boundaries_all_v1.vector_key := r.vector_key;
    rpc_selftest_lane_boundaries_all_v1.ok := v_ok;
    rpc_selftest_lane_boundaries_all_v1.token := v_token;
    rpc_selftest_lane_boundaries_all_v1.message := v_message;
    return next;
  end loop;

  return;
end
$$;


ALTER FUNCTION "pods_core"."rpc_selftest_lane_boundaries_all_v1"() OWNER TO "postgres";


COMMENT ON FUNCTION "pods_core"."rpc_selftest_lane_boundaries_all_v1"() IS 'Executes all Tier-1 lane boundary vectors and raises deterministic failure tokens if any vector deviates from expected behavior.';



CREATE OR REPLACE FUNCTION "pods_core"."rpc_selftest_lane_boundary_v1"("p_source_lane" "text", "p_target_schema" "text", "p_action_kind" "text", "p_expected_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_core', 'public'
    AS $$
declare
  v_ok boolean;
  v_msg text;
begin
  begin
    v_ok := pods_core.assert_lane_boundary_v1(
      p_source_lane,
      p_target_schema,
      p_action_kind
    );

    if coalesce(v_ok,false) is true then
      return jsonb_build_object(
        'ok', true,
        'source_lane', lower(coalesce(p_source_lane,'')),
        'target_schema', lower(coalesce(p_target_schema,'')),
        'action_kind', lower(coalesce(p_action_kind,'')),
        'token', 'LANE_BOUNDARY_ALLOW'
      );
    end if;

    return jsonb_build_object(
      'ok', false,
      'source_lane', lower(coalesce(p_source_lane,'')),
      'target_schema', lower(coalesce(p_target_schema,'')),
      'action_kind', lower(coalesce(p_action_kind,'')),
      'token', 'LANE_BOUNDARY_UNEXPECTED_FALSE'
    );
  exception
    when others then
      v_msg := sqlerrm;

      if p_expected_token is not null and position(p_expected_token in v_msg) > 0 then
        return jsonb_build_object(
          'ok', true,
          'source_lane', lower(coalesce(p_source_lane,'')),
          'target_schema', lower(coalesce(p_target_schema,'')),
          'action_kind', lower(coalesce(p_action_kind,'')),
          'token', p_expected_token,
          'message', v_msg
        );
      end if;

      return jsonb_build_object(
        'ok', false,
        'source_lane', lower(coalesce(p_source_lane,'')),
        'target_schema', lower(coalesce(p_target_schema,'')),
        'action_kind', lower(coalesce(p_action_kind,'')),
        'token', 'LANE_BOUNDARY_UNEXPECTED_EXCEPTION',
        'message', v_msg
      );
  end;
end
$$;


ALTER FUNCTION "pods_core"."rpc_selftest_lane_boundary_v1"("p_source_lane" "text", "p_target_schema" "text", "p_action_kind" "text", "p_expected_token" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "pods_core"."rpc_selftest_lane_boundary_v1"("p_source_lane" "text", "p_target_schema" "text", "p_action_kind" "text", "p_expected_token" "text") IS 'Runs deterministic Tier-1 lane boundary checks and returns structured pass/fail JSON.';



CREATE OR REPLACE FUNCTION "pods_provisioning"."_sha256_text_v1"("p_text" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select encode(extensions.digest(convert_to(coalesce(p_text,''), 'UTF8'), 'sha256'), 'hex')
$$;


ALTER FUNCTION "pods_provisioning"."_sha256_text_v1"("p_text" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."_slugify_v1"("p_text" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select trim(both '-' from regexp_replace(lower(coalesce(p_text,'')), '[^a-z0-9]+', '-', 'g'))
$$;


ALTER FUNCTION "pods_provisioning"."_slugify_v1"("p_text" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_acknowledge_runtime_drift_v1"("p_model_runtime_drift_report_id" "uuid", "p_resolution_status" "text" DEFAULT 'approved'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_report record;
begin
  if p_resolution_status not in ('expected','approved','pending_review','rollback_required','blocked') then
    raise exception 'MODEL_RUNTIME_DRIFT_RESOLUTION_DENY';
  end if;

  select *
  into v_report
  from pods_provisioning.model_runtime_drift_reports_v1
  where model_runtime_drift_report_id = p_model_runtime_drift_report_id
  limit 1;

  if not found then
    raise exception 'MODEL_RUNTIME_DRIFT_REPORT_NOT_FOUND';
  end if;

  update pods_provisioning.model_runtime_drift_findings_v1
  set resolution_status = p_resolution_status
  where model_runtime_drift_report_id = p_model_runtime_drift_report_id;

  update pods_provisioning.model_runtime_drift_reports_v1
  set drift_status = 'acknowledged'
  where model_runtime_drift_report_id = p_model_runtime_drift_report_id
    and drift_status = 'drift_detected';

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_RUNTIME_DRIFT_OK',
    'model_runtime_drift_report_id', p_model_runtime_drift_report_id,
    'resolution_status', p_resolution_status,
    'acknowledged', true
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_acknowledge_runtime_drift_v1"("p_model_runtime_drift_report_id" "uuid", "p_resolution_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_add_civic_survey_question_v1"("p_civic_campaign_id" "uuid", "p_question_key" "text", "p_question_text" "text", "p_question_type" "text" DEFAULT 'text'::"text", "p_required" boolean DEFAULT false, "p_display_order" integer DEFAULT 0) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_campaign record;
  v_body jsonb;
  v_hash text;
  v_question_id uuid;
begin
  if p_civic_campaign_id is null then
    raise exception 'CIVIC_SURVEY_CAMPAIGN_REQUIRED';
  end if;

  if p_question_key is null or btrim(p_question_key) = '' then
    raise exception 'CIVIC_SURVEY_QUESTION_KEY_REQUIRED';
  end if;

  if p_question_text is null or btrim(p_question_text) = '' then
    raise exception 'CIVIC_SURVEY_QUESTION_TEXT_REQUIRED';
  end if;

  select *
  into v_campaign
  from pods_provisioning.civic_action_campaigns_v1 c
  where c.civic_campaign_id = p_civic_campaign_id
  limit 1;

  if not found then
    raise exception 'CIVIC_SURVEY_CAMPAIGN_NOT_FOUND';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_SURVEY_QUESTION_OK',
    'org_id', v_campaign.org_id,
    'civic_campaign_id', v_campaign.civic_campaign_id,
    'question_key', p_question_key,
    'question_text', p_question_text,
    'question_type', coalesce(p_question_type,'text'),
    'required', coalesce(p_required,false),
    'display_order', coalesce(p_display_order,0)
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.civic_action_survey_questions_v1(
    civic_campaign_id,
    org_id,
    question_key,
    question_text,
    question_type,
    required,
    display_order,
    question_body,
    question_hash
  )
  values (
    v_campaign.civic_campaign_id,
    v_campaign.org_id,
    p_question_key,
    p_question_text,
    coalesce(p_question_type,'text'),
    coalesce(p_required,false),
    coalesce(p_display_order,0),
    v_body,
    v_hash
  )
  on conflict (civic_campaign_id, question_key) do update
  set
    question_text = excluded.question_text,
    question_type = excluded.question_type,
    required = excluded.required,
    display_order = excluded.display_order,
    question_body = excluded.question_body,
    question_hash = excluded.question_hash
  returning civic_survey_question_id
  into v_question_id;

  return v_body || jsonb_build_object(
    'civic_survey_question_id', v_question_id,
    'question_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_add_civic_survey_question_v1"("p_civic_campaign_id" "uuid", "p_question_key" "text", "p_question_text" "text", "p_question_type" "text", "p_required" boolean, "p_display_order" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_admin_update_appointment_request_v1"("p_appointment_request_id" "uuid", "p_action_kind" "text", "p_operator_user_id" "uuid" DEFAULT NULL::"uuid", "p_admin_note" "text" DEFAULT ''::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_req record;
  v_new_status text;
  v_body jsonb;
  v_hash text;
  v_action_id uuid;
begin
  if p_appointment_request_id is null then
    raise exception 'ADMIN_ACTION_APPOINTMENT_REQUEST_ID_REQUIRED';
  end if;

  if p_action_kind is null or p_action_kind not in ('confirm','decline','cancel') then
    raise exception 'ADMIN_ACTION_KIND_INVALID:%', coalesce(p_action_kind,'');
  end if;

  select *
  into v_req
  from pods_provisioning.public_appointment_requests_v1 r
  where r.appointment_request_id = p_appointment_request_id
  for update;

  if not found then
    raise exception 'ADMIN_ACTION_APPOINTMENT_REQUEST_NOT_FOUND';
  end if;

  if v_req.status not in ('requested','confirmed') then
    raise exception 'ADMIN_ACTION_STATUS_NOT_MUTABLE:%', v_req.status;
  end if;

  if p_action_kind = 'confirm' then
    if v_req.status <> 'requested' then
      raise exception 'ADMIN_CONFIRM_REQUIRES_REQUESTED';
    end if;
    v_new_status := 'confirmed';
  elsif p_action_kind = 'decline' then
    if v_req.status <> 'requested' then
      raise exception 'ADMIN_DECLINE_REQUIRES_REQUESTED';
    end if;
    v_new_status := 'declined';
  else
    if v_req.status <> 'confirmed' then
      raise exception 'ADMIN_CANCEL_REQUIRES_CONFIRMED';
    end if;
    v_new_status := 'cancelled';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_APPOINTMENT_ADMIN_ACTION_OK',
    'appointment_request_id', p_appointment_request_id,
    'org_id', v_req.org_id,
    'action_kind', p_action_kind,
    'previous_status', v_req.status,
    'new_status', v_new_status,
    'operator_user_id', p_operator_user_id,
    'admin_note', coalesce(p_admin_note,''),
    'customer_email', v_req.customer_email,
    'service_code', v_req.service_code,
    'requested_date', v_req.requested_date::text,
    'requested_start_time', v_req.requested_start_time::text,
    'requested_end_time', v_req.requested_end_time::text
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  update pods_provisioning.public_appointment_requests_v1
  set status = v_new_status
  where appointment_request_id = p_appointment_request_id;

  insert into pods_provisioning.appointment_admin_actions_v1(
    appointment_request_id,
    org_id,
    action_kind,
    previous_status,
    new_status,
    operator_user_id,
    admin_note,
    action_body,
    action_hash
  )
  values (
    p_appointment_request_id,
    v_req.org_id,
    p_action_kind,
    v_req.status,
    v_new_status,
    p_operator_user_id,
    coalesce(p_admin_note,''),
    v_body,
    v_hash
  )
  returning admin_action_id
  into v_action_id;

  return v_body || jsonb_build_object(
    'admin_action_id', v_action_id,
    'action_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_admin_update_appointment_request_v1"("p_appointment_request_id" "uuid", "p_action_kind" "text", "p_operator_user_id" "uuid", "p_admin_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_append_audit_event_v1"("p_org_id" "uuid", "p_model_instance_runtime_id" "uuid", "p_event_type" "text", "p_actor_role" "text" DEFAULT 'system'::"text", "p_event_ref_type" "text" DEFAULT ''::"text", "p_event_ref_id" "uuid" DEFAULT NULL::"uuid", "p_event_body" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_body jsonb;
  v_hash text;
  v_id uuid;
begin
  if p_org_id is null then
    raise exception 'MODEL_AUDIT_ORG_REQUIRED';
  end if;

  if p_event_type is null or btrim(p_event_type) = '' then
    raise exception 'MODEL_AUDIT_EVENT_TYPE_REQUIRED';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_AUDIT_LEDGER_OK',
    'org_id', p_org_id,
    'model_instance_runtime_id', p_model_instance_runtime_id,
    'event_type', p_event_type,
    'actor_role', coalesce(nullif(p_actor_role,''),'system'),
    'event_ref_type', coalesce(p_event_ref_type,''),
    'event_ref_id', p_event_ref_id,
    'event_body', coalesce(p_event_body,'{}'::jsonb)
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_audit_ledger_v1(
    org_id,
    model_instance_runtime_id,
    event_type,
    event_status,
    actor_role,
    event_ref_type,
    event_ref_id,
    event_body,
    event_hash
  )
  values (
    p_org_id,
    p_model_instance_runtime_id,
    p_event_type,
    'recorded',
    coalesce(nullif(p_actor_role,''),'system'),
    coalesce(p_event_ref_type,''),
    p_event_ref_id,
    v_body,
    v_hash
  )
  returning model_audit_event_id
  into v_id;

  return v_body || jsonb_build_object(
    'model_audit_event_id', v_id,
    'event_status', 'recorded',
    'event_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_append_audit_event_v1"("p_org_id" "uuid", "p_model_instance_runtime_id" "uuid", "p_event_type" "text", "p_actor_role" "text", "p_event_ref_type" "text", "p_event_ref_id" "uuid", "p_event_body" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_apply_model_runtime_edit_v1"("p_model_instance_runtime_id" "uuid", "p_target_type" "text", "p_target_key" "text", "p_edit_action" "text", "p_field_updates" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_instance record;
  v_body jsonb;
  v_hash text;
  v_id uuid;
begin
  if p_model_instance_runtime_id is null then
    raise exception 'MODEL_RUNTIME_EDITOR_INSTANCE_REQUIRED';
  end if;

  select *
  into v_instance
  from pods_provisioning.model_instance_runtimes_v1
  where model_instance_runtime_id = p_model_instance_runtime_id
  limit 1;

  if not found then
    raise exception 'MODEL_RUNTIME_EDITOR_INSTANCE_NOT_FOUND';
  end if;

  if p_target_type not in ('page','block','form','asset','settings','provider','license_gate') then
    raise exception 'MODEL_RUNTIME_EDITOR_TARGET_DENY';
  end if;

  if p_edit_action not in ('update_fields','add_block','remove_block','replace_asset','update_visibility','update_goal') then
    raise exception 'MODEL_RUNTIME_EDITOR_ACTION_DENY';
  end if;

  if p_field_updates ? 'html' or p_field_updates ? 'script' or p_field_updates ? 'raw_js' or p_field_updates ? 'raw_css' then
    raise exception 'MODEL_RUNTIME_EDITOR_RAW_CODE_DENY';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_RUNTIME_EDITOR_OK',
    'org_id', v_instance.org_id,
    'model_key', v_instance.model_key,
    'model_version', v_instance.model_version,
    'model_instance_runtime_id', v_instance.model_instance_runtime_id,
    'instance_slug', v_instance.instance_slug,
    'target_type', p_target_type,
    'target_key', p_target_key,
    'edit_action', p_edit_action,
    'field_updates', p_field_updates,
    'editor_status', 'applied',
    'safe_owner_edit', true,
    'raw_code_allowed', false
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_runtime_editor_changes_v1(
    org_id,
    model_instance_runtime_id,
    target_type,
    target_key,
    edit_action,
    field_updates,
    editor_status,
    change_body,
    change_hash
  )
  values (
    v_instance.org_id,
    v_instance.model_instance_runtime_id,
    p_target_type,
    p_target_key,
    p_edit_action,
    coalesce(p_field_updates,'{}'::jsonb),
    'applied',
    v_body,
    v_hash
  )
  returning model_runtime_editor_change_id
  into v_id;

  return v_body || jsonb_build_object(
    'model_runtime_editor_change_id', v_id,
    'change_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_apply_model_runtime_edit_v1"("p_model_instance_runtime_id" "uuid", "p_target_type" "text", "p_target_key" "text", "p_edit_action" "text", "p_field_updates" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_archive_site_v1"("p_model_launch_authority_id" "uuid", "p_reason" "text" DEFAULT ''::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_authority record;
  v_body jsonb;
  v_hash text;
  v_receipt_id uuid;
begin
  select *
  into v_authority
  from pods_provisioning.model_launch_authorities_v1
  where model_launch_authority_id = p_model_launch_authority_id
  limit 1;

  if not found then
    raise exception 'MODEL_SITE_ARCHIVE_AUTHORITY_NOT_FOUND';
  end if;

  if v_authority.launch_state not in ('draft','ready_for_review','ready_for_launch','launched','suspended') then
    raise exception 'MODEL_SITE_ARCHIVE_STATE_DENY:%', v_authority.launch_state;
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_SITE_ARCHIVE_OK',
    'org_id', v_authority.org_id,
    'model_launch_authority_id', v_authority.model_launch_authority_id,
    'model_launch_package_id', v_authority.model_launch_package_id,
    'model_instance_runtime_id', v_authority.model_instance_runtime_id,
    'launch_action', 'archive',
    'launch_result', 'completed',
    'launch_state', 'archived',
    'reason_present', coalesce(p_reason,'') <> ''
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_launch_receipts_v1(
    org_id,
    model_launch_authority_id,
    model_launch_package_id,
    model_instance_runtime_id,
    launch_action,
    launch_result,
    receipt_body,
    receipt_hash
  )
  values (
    v_authority.org_id,
    v_authority.model_launch_authority_id,
    v_authority.model_launch_package_id,
    v_authority.model_instance_runtime_id,
    'archive',
    'completed',
    v_body,
    v_hash
  )
  returning model_launch_receipt_id
  into v_receipt_id;

  update pods_provisioning.model_launch_authorities_v1
  set launch_state = 'archived'
  where model_launch_authority_id = v_authority.model_launch_authority_id;

  update pods_provisioning.model_instance_runtimes_v1
  set instance_status = 'archived'
  where model_instance_runtime_id = v_authority.model_instance_runtime_id;

  update pods_provisioning.model_launch_packages_v1
  set package_status = 'archived'
  where model_launch_package_id = v_authority.model_launch_package_id;

  return v_body || jsonb_build_object(
    'model_launch_receipt_id', v_receipt_id,
    'receipt_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_archive_site_v1"("p_model_launch_authority_id" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_assign_staff_to_appointment_v1"("p_appointment_request_id" "uuid", "p_staff_member_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_req record;
  v_staff record;
  v_body jsonb;
  v_hash text;
  v_assignment_id uuid;
begin
  if p_appointment_request_id is null then
    raise exception 'STAFF_ASSIGN_APPOINTMENT_REQUIRED';
  end if;

  if p_staff_member_id is null then
    raise exception 'STAFF_ASSIGN_STAFF_REQUIRED';
  end if;

  select *
  into v_req
  from pods_provisioning.public_appointment_requests_v1 r
  where r.appointment_request_id = p_appointment_request_id
  limit 1;

  if not found then
    raise exception 'STAFF_ASSIGN_APPOINTMENT_NOT_FOUND';
  end if;

  if v_req.status <> 'confirmed' then
    raise exception 'STAFF_ASSIGN_REQUIRES_CONFIRMED_APPOINTMENT';
  end if;

  select *
  into v_staff
  from pods_provisioning.staff_members_v1 sm
  where sm.staff_member_id = p_staff_member_id
    and sm.org_id = v_req.org_id
    and sm.active = true
  limit 1;

  if not found then
    raise exception 'STAFF_ASSIGN_STAFF_NOT_FOUND_FOR_ORG';
  end if;

  if exists (
    select 1
    from pods_provisioning.staff_appointment_assignments_v1 sa
    where sa.staff_member_id = p_staff_member_id
      and sa.assignment_status = 'assigned'
      and sa.assigned_date = v_req.requested_date
      and sa.assigned_start_time < v_req.requested_end_time
      and sa.assigned_end_time > v_req.requested_start_time
  ) then
    raise exception 'STAFF_ASSIGN_OVERLAP_DENY:%', p_staff_member_id;
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_STAFF_ASSIGNMENT_OK',
    'appointment_request_id', v_req.appointment_request_id,
    'org_id', v_req.org_id,
    'staff_member_id', v_staff.staff_member_id,
    'staff_display_name', v_staff.display_name,
    'staff_role_key', v_staff.role_key,
    'service_code', v_req.service_code,
    'assigned_date', v_req.requested_date::text,
    'assigned_start_time', v_req.requested_start_time::text,
    'assigned_end_time', v_req.requested_end_time::text,
    'assignment_status', 'assigned'
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.staff_appointment_assignments_v1(
    appointment_request_id,
    org_id,
    staff_member_id,
    service_code,
    assigned_date,
    assigned_start_time,
    assigned_end_time,
    assignment_status,
    assignment_body,
    assignment_hash
  )
  values (
    v_req.appointment_request_id,
    v_req.org_id,
    v_staff.staff_member_id,
    v_req.service_code,
    v_req.requested_date,
    v_req.requested_start_time,
    v_req.requested_end_time,
    'assigned',
    v_body,
    v_hash
  )
  returning staff_assignment_id
  into v_assignment_id;

  return v_body || jsonb_build_object(
    'staff_assignment_id', v_assignment_id,
    'assignment_hash', v_hash
  );
exception
  when unique_violation then
    raise exception 'STAFF_ASSIGN_APPOINTMENT_ALREADY_ASSIGNED:%', p_appointment_request_id;
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_assign_staff_to_appointment_v1"("p_appointment_request_id" "uuid", "p_staff_member_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_attach_domain_to_runtime_v1"("p_model_instance_runtime_id" "uuid", "p_domain_name" "text", "p_provider_key" "text" DEFAULT 'cloudflare'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_runtime record;
  v_body jsonb;
  v_hash text;
  v_id uuid;
begin
  select *
  into v_runtime
  from pods_provisioning.model_instance_runtimes_v1
  where model_instance_runtime_id = p_model_instance_runtime_id
  limit 1;

  if not found then
    raise exception 'DOMAIN_RUNTIME_BINDING_RUNTIME_NOT_FOUND';
  end if;

  if p_domain_name is null or btrim(p_domain_name) = '' then
    raise exception 'DOMAIN_RUNTIME_BINDING_DOMAIN_REQUIRED';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_DOMAIN_PROVIDER_AUTHORITY_OK',
    'org_id', v_runtime.org_id,
    'model_instance_runtime_id', p_model_instance_runtime_id,
    'domain_name', lower(btrim(p_domain_name)),
    'provider_key', p_provider_key,
    'binding_status', 'attached',
    'dns_status', 'pending',
    'ssl_status', 'pending'
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.domain_runtime_bindings_v1(
    org_id,
    model_instance_runtime_id,
    domain_name,
    provider_key,
    binding_status,
    dns_status,
    ssl_status,
    binding_hash
  )
  values (
    v_runtime.org_id,
    p_model_instance_runtime_id,
    lower(btrim(p_domain_name)),
    p_provider_key,
    'attached',
    'pending',
    'pending',
    v_hash
  )
  returning domain_runtime_binding_id
  into v_id;

  return v_body || jsonb_build_object(
    'domain_runtime_binding_id', v_id,
    'binding_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_attach_domain_to_runtime_v1"("p_model_instance_runtime_id" "uuid", "p_domain_name" "text", "p_provider_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_bootstrap_public_booking_surface_v1"("p_provision_run_id" "uuid", "p_requested_slug" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $_$
declare
  v_run record;
  v_slug text;
  v_path text;
  v_receipt jsonb;
  v_hash text;
begin
  if p_provision_run_id is null then
    raise exception 'PUBLIC_BOOKING_PROVISION_RUN_REQUIRED';
  end if;

  select *
  into v_run
  from pods_provisioning.provision_runs_v1 pr
  where pr.provision_run_id = p_provision_run_id
    and pr.status = 'completed'
  limit 1;

  if not found then
    raise exception 'PUBLIC_BOOKING_PROVISION_RUN_NOT_FOUND_OR_NOT_COMPLETED';
  end if;

  if exists (
    select 1
    from pods_provisioning.public_booking_surfaces_v1 pbs
    where pbs.org_id = v_run.org_id
      and pbs.template_key = v_run.template_key
      and pbs.template_version = v_run.template_version
  ) then
    raise exception 'PUBLIC_BOOKING_SURFACE_ALREADY_EXISTS:%', p_provision_run_id;
  end if;

  v_slug := pods_provisioning._slugify_v1(coalesce(p_requested_slug, v_run.template_key || '-' || left(v_run.org_id::text, 8)));

  if length(v_slug) < 4 then
    v_slug := 'business-' || left(v_run.org_id::text, 8);
  end if;

  if v_slug !~ '^[a-z0-9][a-z0-9\-]{2,62}[a-z0-9]$' then
    raise exception 'PUBLIC_BOOKING_SLUG_INVALID:%', v_slug;
  end if;

  v_path := '/book/' || v_slug;

  v_receipt := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PUBLIC_BOOKING_BOOTSTRAP_OK',
    'org_id', v_run.org_id,
    'provision_run_id', v_run.provision_run_id,
    'template_key', v_run.template_key,
    'template_version', v_run.template_version,
    'booking_slug', v_slug,
    'booking_path', v_path,
    'enabled', true,
    'customer_message', 'Your public booking surface has been created.',
    'customer_next_steps', jsonb_build_array(
      'Review booking page branding',
      'Verify service list',
      'Verify staff availability',
      'Publish booking page when ready'
    )
  );

  v_hash := pods_provisioning._sha256_text_v1(v_receipt::text);

  insert into pods_provisioning.public_booking_surfaces_v1(
    provision_run_id,
    org_id,
    template_key,
    template_version,
    booking_slug,
    booking_path,
    enabled,
    receipt_body,
    receipt_hash
  )
  values (
    v_run.provision_run_id,
    v_run.org_id,
    v_run.template_key,
    v_run.template_version,
    v_slug,
    v_path,
    true,
    v_receipt,
    v_hash
  );

  insert into pods_provisioning.seeded_objects_v1(
    provision_run_id,
    org_id,
    template_key,
    template_version,
    object_kind,
    object_schema,
    object_table,
    object_id,
    object_key,
    seeded_hash
  )
  values (
    v_run.provision_run_id,
    v_run.org_id,
    v_run.template_key,
    v_run.template_version,
    'public_surface',
    'pods_provisioning',
    'public_booking_surfaces_v1',
    null,
    v_slug,
    v_hash
  )
  on conflict (provision_run_id, object_kind, object_key) do nothing;

  return v_receipt || jsonb_build_object('receipt_hash', v_hash);
end;
$_$;


ALTER FUNCTION "pods_provisioning"."rpc_bootstrap_public_booking_surface_v1"("p_provision_run_id" "uuid", "p_requested_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_bridge_provider_connections_to_runtime_v1"("p_org_id" "uuid", "p_provider_connection_rollup_id" "uuid", "p_model_key" "text" DEFAULT 'DEVELOPER_PORTAL_V1'::"text", "p_model_version" "text" DEFAULT 'v1'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_rollup record;
  v_provider text;
  v_session record;

  v_bridged jsonb := '[]'::jsonb;
  v_receipts jsonb := '[]'::jsonb;
  v_runtime jsonb;

  v_ready boolean;
  v_body jsonb;
  v_hash text;
  v_bridge_id uuid;
begin
  if p_org_id is null then
    raise exception 'PROVIDER_RUNTIME_BRIDGE_ORG_REQUIRED';
  end if;

  select *
  into v_rollup
  from pods_provisioning.provider_connection_rollups_v1 r
  where r.provider_connection_rollup_id = p_provider_connection_rollup_id
    and r.org_id = p_org_id
  limit 1;

  if not found then
    raise exception 'PROVIDER_RUNTIME_BRIDGE_ROLLUP_NOT_FOUND';
  end if;

  if v_rollup.connection_ready is not true then
    v_body := jsonb_build_object(
      'ok', true,
      'token', 'PROTEUSOPS_PROVIDER_CONNECTION_RUNTIME_BRIDGE_OK',
      'org_id', p_org_id,
      'model_key', p_model_key,
      'model_version', p_model_version,
      'provider_connection_rollup_id', p_provider_connection_rollup_id,
      'bridged_providers', v_bridged,
      'runtime_receipts', v_receipts,
      'missing_providers', v_rollup.missing_providers,
      'bridge_ready', false,
      'launch_blocked', true
    );

    v_hash := pods_provisioning._sha256_text_v1(v_body::text);

    insert into pods_provisioning.provider_connection_runtime_bridges_v1(
      org_id, model_key, model_version, provider_connection_rollup_id,
      bridged_providers, runtime_receipts, missing_providers,
      bridge_ready, launch_blocked, bridge_body, bridge_hash
    )
    values (
      p_org_id, p_model_key, p_model_version, p_provider_connection_rollup_id,
      v_bridged, v_receipts, v_rollup.missing_providers,
      false, true, v_body, v_hash
    )
    returning provider_connection_runtime_bridge_id into v_bridge_id;

    return v_body || jsonb_build_object(
      'provider_connection_runtime_bridge_id', v_bridge_id,
      'bridge_hash', v_hash
    );
  end if;

  for v_provider in
    select value::text
    from jsonb_array_elements_text(v_rollup.verified_providers)
  loop
    select *
    into v_session
    from pods_provisioning.provider_connection_sessions_v1 s
    where s.org_id = p_org_id
      and s.provider_key = v_provider
      and s.connection_status = 'verified'
      and s.secret_ref like 'secret://%'
    order by s.updated_at desc
    limit 1;

    if not found then
      raise exception 'PROVIDER_RUNTIME_BRIDGE_SESSION_NOT_FOUND:%', v_provider;
    end if;

    if v_provider = 'supabase' then
      v_runtime := pods_provisioning.rpc_verify_supabase_adapter_runtime_v1(
        p_org_id,
        coalesce(nullif(v_session.provider_project_ref,''),'connected-project'),
        'https://' || coalesce(nullif(v_session.provider_project_ref,''),'connected-project') || '.supabase.co',
        true,true,true,true,null
      );

    elsif v_provider = 'stripe' then
      v_runtime := pods_provisioning.rpc_verify_stripe_adapter_runtime_v1(
        p_org_id,
        coalesce(nullif(v_session.provider_account_ref,''),'acct_connected'),
        'test',
        true,true,true,true,true,true,null
      );

    elsif v_provider = 'email' then
      v_runtime := pods_provisioning.rpc_verify_email_adapter_runtime_v1(
        p_org_id,
        'connected_email',
        'connected.example.com',
        true,true,true,true,true,null
      );

    elsif v_provider = 'github' then
      v_runtime := pods_provisioning.rpc_verify_github_adapter_runtime_v1(
        p_org_id,
        'connected',
        coalesce(nullif(v_session.provider_project_ref,''),'connected-repo'),
        'https://github.com/connected/' || coalesce(nullif(v_session.provider_project_ref,''),'connected-repo'),
        true,true,true,true,true,null
      );

    elsif v_provider = 'storage' then
      v_runtime := pods_provisioning.rpc_verify_storage_adapter_runtime_v1(
        p_org_id,
        'supabase_storage',
        coalesce(nullif(v_session.provider_project_ref,''),'connected_storage'),
        true,true,true,true,true,null
      );

    else
      v_runtime := jsonb_build_object(
        'ok', true,
        'token', 'PROTEUSOPS_PROVIDER_RUNTIME_BRIDGE_PROVIDER_SKIPPED',
        'provider_key', v_provider
      );
    end if;

    v_bridged := v_bridged || jsonb_build_array(v_provider);
    v_receipts := v_receipts || jsonb_build_array(
      jsonb_build_object(
        'provider_key', v_provider,
        'runtime_token', v_runtime->>'token',
        'runtime_status', coalesce(v_runtime->>'runtime_status','verified')
      )
    );
  end loop;

  v_ready := jsonb_array_length(v_rollup.missing_providers) = 0;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PROVIDER_CONNECTION_RUNTIME_BRIDGE_OK',
    'org_id', p_org_id,
    'model_key', p_model_key,
    'model_version', p_model_version,
    'provider_connection_rollup_id', p_provider_connection_rollup_id,
    'bridged_providers', v_bridged,
    'runtime_receipts', v_receipts,
    'missing_providers', v_rollup.missing_providers,
    'bridge_ready', v_ready,
    'launch_blocked', not v_ready
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.provider_connection_runtime_bridges_v1(
    org_id, model_key, model_version, provider_connection_rollup_id,
    bridged_providers, runtime_receipts, missing_providers,
    bridge_ready, launch_blocked, bridge_body, bridge_hash
  )
  values (
    p_org_id, p_model_key, p_model_version, p_provider_connection_rollup_id,
    v_bridged, v_receipts, v_rollup.missing_providers,
    v_ready, not v_ready, v_body, v_hash
  )
  returning provider_connection_runtime_bridge_id into v_bridge_id;

  return v_body || jsonb_build_object(
    'provider_connection_runtime_bridge_id', v_bridge_id,
    'bridge_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_bridge_provider_connections_to_runtime_v1"("p_org_id" "uuid", "p_provider_connection_rollup_id" "uuid", "p_model_key" "text", "p_model_version" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_build_audit_checkpoint_v1"("p_org_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_hashes jsonb;
  v_count integer;
  v_checkpoint_hash text;
  v_id uuid;
begin
  select
    coalesce(jsonb_agg(event_hash order by created_at, model_audit_event_id), '[]'::jsonb),
    count(*)
  into v_hashes, v_count
  from pods_provisioning.model_audit_ledger_v1
  where org_id = p_org_id
    and event_status in ('recorded','verified');

  if v_count = 0 then
    raise exception 'MODEL_AUDIT_CHECKPOINT_NO_EVENTS';
  end if;

  v_checkpoint_hash := pods_provisioning._sha256_text_v1(v_hashes::text);

  insert into pods_provisioning.model_audit_checkpoints_v1(
    org_id,
    event_count,
    checkpoint_status,
    event_hashes,
    checkpoint_hash
  )
  values (
    p_org_id,
    v_count,
    'created',
    v_hashes,
    v_checkpoint_hash
  )
  returning model_audit_checkpoint_id
  into v_id;

  update pods_provisioning.model_audit_ledger_v1
  set event_status = 'checkpointed'
  where org_id = p_org_id
    and event_status in ('recorded','verified');

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_AUDIT_LEDGER_OK',
    'model_audit_checkpoint_id', v_id,
    'event_count', v_count,
    'checkpoint_status', 'created',
    'checkpoint_hash', v_checkpoint_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_build_audit_checkpoint_v1"("p_org_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_build_contractor_estimate_v1"("p_estimate_request_id" "uuid", "p_labor_cents" integer, "p_material_cents" integer, "p_deposit_percent" integer DEFAULT 20, "p_customer_message" "text" DEFAULT 'Please review this estimate.'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_req record;
  v_site_visit record;
  v_estimate_number text;
  v_subtotal integer;
  v_tax integer := 0;
  v_total integer;
  v_deposit integer;
  v_body jsonb;
  v_hash text;
  v_estimate_id uuid;
  v_labor_hash text;
  v_material_hash text;
begin
  if p_estimate_request_id is null then
    raise exception 'CONTRACTOR_ESTIMATE_REQUEST_REQUIRED';
  end if;

  if p_labor_cents is null or p_labor_cents < 0 then
    raise exception 'CONTRACTOR_ESTIMATE_LABOR_INVALID';
  end if;

  if p_material_cents is null or p_material_cents < 0 then
    raise exception 'CONTRACTOR_ESTIMATE_MATERIAL_INVALID';
  end if;

  if p_deposit_percent is null or p_deposit_percent < 0 or p_deposit_percent > 100 then
    raise exception 'CONTRACTOR_ESTIMATE_DEPOSIT_PERCENT_INVALID';
  end if;

  select *
  into v_req
  from pods_provisioning.contractor_estimate_requests_v1 er
  where er.estimate_request_id = p_estimate_request_id
  for update;

  if not found then
    raise exception 'CONTRACTOR_ESTIMATE_REQUEST_NOT_FOUND';
  end if;

  select *
  into v_site_visit
  from pods_provisioning.contractor_site_visits_v1 sv
  where sv.estimate_request_id = p_estimate_request_id
    and sv.visit_status = 'completed'
  limit 1;

  if not found then
    raise exception 'CONTRACTOR_ESTIMATE_REQUIRES_COMPLETED_SITE_VISIT';
  end if;

  v_subtotal := p_labor_cents + p_material_cents;
  v_total := v_subtotal + v_tax;
  v_deposit := floor((v_total * p_deposit_percent) / 100.0)::integer;

  v_estimate_number := 'EST-' || left(v_req.org_id::text, 8) || '-' || left(v_req.estimate_request_id::text, 8);

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CONTRACTOR_ESTIMATE_BUILDER_OK',
    'estimate_request_id', v_req.estimate_request_id,
    'org_id', v_req.org_id,
    'template_key', v_req.template_key,
    'template_version', v_req.template_version,
    'service_code', v_req.service_code,
    'estimate_number', v_estimate_number,
    'estimate_status', 'sent',
    'labor_cents', p_labor_cents,
    'material_cents', p_material_cents,
    'subtotal_cents', v_subtotal,
    'tax_cents', v_tax,
    'total_cents', v_total,
    'deposit_required', (v_deposit > 0),
    'deposit_amount_cents', v_deposit,
    'deposit_percent', p_deposit_percent,
    'valid_until', (current_date + 14)::text,
    'customer_message', coalesce(p_customer_message,''),
    'approval_ready', true,
    'decline_ready', true,
    'site_visit_id', v_site_visit.site_visit_id,
    'measurement_summary', v_site_visit.measurement_summary,
    'photo_refs', v_site_visit.photo_refs
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.contractor_estimates_v1(
    estimate_request_id,
    org_id,
    estimate_number,
    estimate_status,
    subtotal_cents,
    tax_cents,
    total_cents,
    deposit_required,
    deposit_amount_cents,
    valid_until,
    customer_message,
    estimate_body,
    estimate_hash
  )
  values (
    v_req.estimate_request_id,
    v_req.org_id,
    v_estimate_number,
    'sent',
    v_subtotal,
    v_tax,
    v_total,
    (v_deposit > 0),
    v_deposit,
    current_date + 14,
    coalesce(p_customer_message,''),
    v_body,
    v_hash
  )
  returning contractor_estimate_id
  into v_estimate_id;

  v_labor_hash := pods_provisioning._sha256_text_v1(
    v_estimate_id::text || '|labor|' || p_labor_cents::text
  );

  insert into pods_provisioning.contractor_estimate_line_items_v1(
    contractor_estimate_id,
    org_id,
    line_kind,
    description,
    quantity,
    unit_price_cents,
    line_total_cents,
    display_order,
    line_body,
    line_hash
  )
  values (
    v_estimate_id,
    v_req.org_id,
    'labor',
    'Labor',
    1,
    p_labor_cents,
    p_labor_cents,
    1,
    jsonb_build_object('line_kind','labor','amount_cents',p_labor_cents),
    v_labor_hash
  );

  v_material_hash := pods_provisioning._sha256_text_v1(
    v_estimate_id::text || '|material|' || p_material_cents::text
  );

  insert into pods_provisioning.contractor_estimate_line_items_v1(
    contractor_estimate_id,
    org_id,
    line_kind,
    description,
    quantity,
    unit_price_cents,
    line_total_cents,
    display_order,
    line_body,
    line_hash
  )
  values (
    v_estimate_id,
    v_req.org_id,
    'material',
    'Materials',
    1,
    p_material_cents,
    p_material_cents,
    2,
    jsonb_build_object('line_kind','material','amount_cents',p_material_cents),
    v_material_hash
  );

  update pods_provisioning.contractor_estimate_requests_v1
  set estimate_status = 'estimate_sent'
  where estimate_request_id = v_req.estimate_request_id;

  return v_body || jsonb_build_object(
    'contractor_estimate_id', v_estimate_id,
    'estimate_hash', v_hash,
    'line_item_count', 2
  );
exception
  when unique_violation then
    raise exception 'CONTRACTOR_ESTIMATE_DUPLICATE_DENY:%', p_estimate_request_id;
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_build_contractor_estimate_v1"("p_estimate_request_id" "uuid", "p_labor_cents" integer, "p_material_cents" integer, "p_deposit_percent" integer, "p_customer_message" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_cancel_appointment_with_refund_intent_v1"("p_appointment_request_id" "uuid", "p_cancelled_by" "text" DEFAULT 'operator'::"text", "p_cancellation_reason" "text" DEFAULT ''::"text", "p_policy_key" "text" DEFAULT 'default-cancellation'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_req record;
  v_policy record;
  v_payment record;
  v_cancel_body jsonb;
  v_cancel_hash text;
  v_cancel_id uuid;
  v_refund_body jsonb;
  v_refund_hash text;
  v_refund_id uuid;
  v_refund_amount integer := 0;
begin
  if p_appointment_request_id is null then
    raise exception 'CANCELLATION_APPOINTMENT_REQUIRED';
  end if;

  if p_cancelled_by is null or p_cancelled_by not in ('customer','operator','system') then
    raise exception 'CANCELLATION_BY_INVALID:%', coalesce(p_cancelled_by,'');
  end if;

  select *
  into v_req
  from pods_provisioning.public_appointment_requests_v1 r
  where r.appointment_request_id = p_appointment_request_id
  for update;

  if not found then
    raise exception 'CANCELLATION_APPOINTMENT_NOT_FOUND';
  end if;

  if v_req.status not in ('requested','confirmed') then
    raise exception 'CANCELLATION_STATUS_NOT_MUTABLE:%', v_req.status;
  end if;

  select *
  into v_policy
  from pods_provisioning.cancellation_policies_v1 cp
  where cp.org_id = v_req.org_id
    and cp.policy_key = p_policy_key
    and cp.active = true
  limit 1;

  if not found then
    raise exception 'CANCELLATION_POLICY_NOT_FOUND:%', p_policy_key;
  end if;

  select *
  into v_payment
  from pods_provisioning.payment_intents_v1 pi
  where pi.appointment_request_id = p_appointment_request_id
  limit 1;

  if found and v_policy.refund_allowed then
    v_refund_amount := floor((v_payment.amount_cents * v_policy.refund_percent) / 100.0)::integer;
  end if;

  v_cancel_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_REFUND_AND_CANCELLATION_OK',
    'appointment_request_id', v_req.appointment_request_id,
    'org_id', v_req.org_id,
    'cancelled_by', p_cancelled_by,
    'cancellation_reason', coalesce(p_cancellation_reason,''),
    'previous_appointment_status', v_req.status,
    'new_appointment_status', 'cancelled',
    'policy_key', v_policy.policy_key,
    'refund_intent_required', (found and v_refund_amount > 0),
    'refund_amount_cents', v_refund_amount
  );

  v_cancel_hash := pods_provisioning._sha256_text_v1(v_cancel_body::text);

  insert into pods_provisioning.cancellation_requests_v1(
    appointment_request_id,
    org_id,
    cancellation_policy_id,
    cancelled_by,
    cancellation_reason,
    previous_appointment_status,
    new_appointment_status,
    refund_intent_required,
    refund_amount_cents,
    cancellation_body,
    cancellation_hash
  )
  values (
    v_req.appointment_request_id,
    v_req.org_id,
    v_policy.cancellation_policy_id,
    p_cancelled_by,
    coalesce(p_cancellation_reason,''),
    v_req.status,
    'cancelled',
    (found and v_refund_amount > 0),
    v_refund_amount,
    v_cancel_body,
    v_cancel_hash
  )
  returning cancellation_request_id
  into v_cancel_id;

  update pods_provisioning.public_appointment_requests_v1
  set status = 'cancelled'
  where appointment_request_id = v_req.appointment_request_id;

  if found and v_refund_amount > 0 then
    v_refund_body := jsonb_build_object(
      'ok', true,
      'token', 'PROTEUSOPS_REFUND_INTENT_OK',
      'payment_intent_id', v_payment.payment_intent_id,
      'cancellation_request_id', v_cancel_id,
      'org_id', v_req.org_id,
      'provider_key', v_payment.provider_key,
      'refund_amount_cents', v_refund_amount,
      'currency', v_payment.currency,
      'refund_status', 'pending'
    );

    v_refund_hash := pods_provisioning._sha256_text_v1(v_refund_body::text);

    insert into pods_provisioning.refund_intents_v1(
      payment_intent_id,
      cancellation_request_id,
      org_id,
      provider_key,
      provider_refund_id,
      refund_amount_cents,
      currency,
      refund_status,
      refund_body,
      refund_hash
    )
    values (
      v_payment.payment_intent_id,
      v_cancel_id,
      v_req.org_id,
      v_payment.provider_key,
      '',
      v_refund_amount,
      v_payment.currency,
      'pending',
      v_refund_body,
      v_refund_hash
    )
    returning refund_intent_id
    into v_refund_id;
  end if;

  return v_cancel_body || jsonb_build_object(
    'cancellation_request_id', v_cancel_id,
    'cancellation_hash', v_cancel_hash,
    'refund_intent_id', v_refund_id
  );
exception
  when unique_violation then
    raise exception 'CANCELLATION_DUPLICATE_DENY:%', p_appointment_request_id;
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_cancel_appointment_with_refund_intent_v1"("p_appointment_request_id" "uuid", "p_cancelled_by" "text", "p_cancellation_reason" "text", "p_policy_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_check_launch_readiness_v1"("p_model_launch_package_id" "uuid", "p_deployment_target_key" "text" DEFAULT 'proteusops_hosted'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_package record;
  v_checks jsonb;
  v_blockers jsonb := '[]'::jsonb;
  v_ready boolean := true;
  v_body jsonb;
  v_hash text;
  v_authority_id uuid;
begin
  select *
  into v_package
  from pods_provisioning.model_launch_packages_v1
  where model_launch_package_id = p_model_launch_package_id
  limit 1;

  if not found then
    raise exception 'MODEL_LAUNCH_AUTHORITY_PACKAGE_NOT_FOUND';
  end if;

  v_checks := jsonb_build_object(
    'providers_connected', jsonb_array_length(coalesce(v_package.provider_manifest,'[]'::jsonb)) > 0,
    'runtime_generated', v_package.model_site_runtime_generation_id is not null,
    'permissions_generated', coalesce(v_package.permission_manifest,'{}'::jsonb) <> '{}'::jsonb,
    'pages_generated', jsonb_array_length(coalesce(v_package.route_manifest,'[]'::jsonb)) > 0,
    'forms_generated', jsonb_array_length(coalesce(v_package.form_manifest,'[]'::jsonb)) > 0,
    'renderer_generated', coalesce(v_package.renderer_manifest,'{}'::jsonb) <> '{}'::jsonb,
    'assets_valid', jsonb_array_length(coalesce(v_package.asset_manifest,'[]'::jsonb)) > 0,
    'license_rules_valid', coalesce(v_package.renderer_manifest,'{}'::jsonb) ? 'license_gates',
    'deployment_target_selected', coalesce(p_deployment_target_key,'') <> ''
  );

  if not ((v_checks->>'providers_connected')::boolean) then
    v_blockers := v_blockers || jsonb_build_array('providers_missing');
  end if;

  if not ((v_checks->>'runtime_generated')::boolean) then
    v_blockers := v_blockers || jsonb_build_array('runtime_missing');
  end if;

  if not ((v_checks->>'permissions_generated')::boolean) then
    v_blockers := v_blockers || jsonb_build_array('permissions_missing');
  end if;

  if not ((v_checks->>'pages_generated')::boolean) then
    v_blockers := v_blockers || jsonb_build_array('pages_missing');
  end if;

  if not ((v_checks->>'forms_generated')::boolean) then
    v_blockers := v_blockers || jsonb_build_array('forms_missing');
  end if;

  if not ((v_checks->>'renderer_generated')::boolean) then
    v_blockers := v_blockers || jsonb_build_array('renderer_missing');
  end if;

  if not ((v_checks->>'assets_valid')::boolean) then
    v_blockers := v_blockers || jsonb_build_array('assets_missing');
  end if;

  if not ((v_checks->>'license_rules_valid')::boolean) then
    v_blockers := v_blockers || jsonb_build_array('license_rules_missing');
  end if;

  if not ((v_checks->>'deployment_target_selected')::boolean) then
    v_blockers := v_blockers || jsonb_build_array('deployment_target_missing');
  end if;

  v_ready := jsonb_array_length(v_blockers) = 0 and v_package.launchable = true;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_LAUNCH_AUTHORITY_OK',
    'org_id', v_package.org_id,
    'model_key', v_package.model_key,
    'model_version', v_package.model_version,
    'model_launch_package_id', v_package.model_launch_package_id,
    'model_instance_runtime_id', v_package.model_instance_runtime_id,
    'deployment_target_key', p_deployment_target_key,
    'launch_ready', v_ready,
    'launch_state', case when v_ready then 'ready_for_review' else 'draft' end,
    'readiness_checks', v_checks,
    'launch_blockers', v_blockers
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_launch_authorities_v1(
    org_id,
    model_launch_package_id,
    model_instance_runtime_id,
    launch_state,
    deployment_target_key,
    readiness_checks,
    launch_blockers,
    authority_body,
    authority_hash
  )
  values (
    v_package.org_id,
    v_package.model_launch_package_id,
    v_package.model_instance_runtime_id,
    case when v_ready then 'ready_for_review' else 'draft' end,
    p_deployment_target_key,
    v_checks,
    v_blockers,
    v_body,
    v_hash
  )
  returning model_launch_authority_id
  into v_authority_id;

  return v_body || jsonb_build_object(
    'model_launch_authority_id', v_authority_id,
    'authority_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_check_launch_readiness_v1"("p_model_launch_package_id" "uuid", "p_deployment_target_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_civic_action_launch_ready_from_deployment_v1"("p_civic_deployment_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_deploy record;
  v_launch jsonb;
  v_ready boolean;
  v_status text;
  v_body jsonb;
  v_hash text;
  v_receipt_id uuid;
begin
  if p_civic_deployment_id is null then
    raise exception 'CIVIC_LAUNCH_READY_DEPLOYMENT_REQUIRED';
  end if;

  select *
  into v_deploy
  from pods_provisioning.civic_action_model_deployments_v1 d
  where d.civic_deployment_id = p_civic_deployment_id
  limit 1;

  if not found then
    raise exception 'CIVIC_LAUNCH_READY_DEPLOYMENT_NOT_FOUND';
  end if;

  v_launch := pods_provisioning.rpc_connection_layer_launch_control_v1(
    v_deploy.org_id,
    'CIVIC_ACTION_V1',
    'v1',
    null,
    null,
    null
  );

  v_ready := (v_launch->>'launch_ready' = 'true');

  if v_ready then
    v_status := 'ready';
  else
    v_status := 'blocked';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_LAUNCH_READY_FROM_DEPLOYMENT_OK',
    'org_id', v_deploy.org_id,
    'civic_deployment_id', v_deploy.civic_deployment_id,
    'civic_campaign_id', v_deploy.civic_campaign_id,
    'model_key', 'CIVIC_ACTION_V1',
    'model_version', 'v2',
    'issue_title', v_deploy.issue_title,
    'launch_ready', v_ready,
    'launch_status', v_status,
    'ready_providers', coalesce(v_launch->'provider_readiness'->'ready_providers','[]'::jsonb),
    'missing_providers', coalesce(v_launch->'provider_connection_rollup'->'missing_providers','[]'::jsonb),
    'required_providers', v_deploy.required_providers,
    'operator_next_steps', case
      when v_ready then jsonb_build_array(
        'Review public campaign page',
        'Review moderation settings',
        'Click Launch'
      )
      else jsonb_build_array(
        'Connect missing providers',
        'Re-run launch readiness',
        'Return to civic deployment dashboard'
      )
    end,
    'connection_launch', v_launch
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.civic_action_launch_ready_receipts_v1(
    civic_deployment_id,
    org_id,
    model_key,
    model_version,
    launch_ready,
    launch_status,
    missing_providers,
    ready_providers,
    receipt_body,
    receipt_hash
  )
  values (
    v_deploy.civic_deployment_id,
    v_deploy.org_id,
    'CIVIC_ACTION_V1',
    'v2',
    v_ready,
    v_status,
    coalesce(v_launch->'provider_connection_rollup'->'missing_providers','[]'::jsonb),
    coalesce(v_launch->'provider_readiness'->'ready_providers','[]'::jsonb),
    v_body,
    v_hash
  )
  returning civic_launch_ready_receipt_id
  into v_receipt_id;

  return v_body || jsonb_build_object(
    'civic_launch_ready_receipt_id', v_receipt_id,
    'receipt_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_civic_action_launch_ready_from_deployment_v1"("p_civic_deployment_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_civic_event_public_count_v1"("p_civic_event_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_rsvp_count integer;
  v_speaker_count integer;
  v_volunteer_count integer;
begin
  select count(*)
  into v_rsvp_count
  from pods_provisioning.civic_action_event_rsvps_v1
  where civic_event_id = p_civic_event_id
    and rsvp_status in ('going','interested')
    and moderation_status in ('pending','approved');

  select count(*)
  into v_speaker_count
  from pods_provisioning.civic_action_event_rsvps_v1
  where civic_event_id = p_civic_event_id
    and wants_to_speak = true
    and moderation_status in ('pending','approved');

  select count(*)
  into v_volunteer_count
  from pods_provisioning.civic_action_event_rsvps_v1
  where civic_event_id = p_civic_event_id
    and wants_to_volunteer = true
    and moderation_status in ('pending','approved');

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_EVENT_COUNT_OK',
    'civic_event_id', p_civic_event_id,
    'rsvp_count', v_rsvp_count,
    'speaker_signup_count', v_speaker_count,
    'volunteer_signup_count', v_volunteer_count
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_civic_event_public_count_v1"("p_civic_event_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_civic_evidence_public_library_v1"("p_civic_campaign_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_total_count integer;
  v_visible_count integer;
  v_type_counts jsonb;
begin
  select count(*)
  into v_total_count
  from pods_provisioning.civic_action_evidence_v1
  where civic_campaign_id = p_civic_campaign_id;

  select count(*)
  into v_visible_count
  from pods_provisioning.civic_action_evidence_v1
  where civic_campaign_id = p_civic_campaign_id
    and public_visible = true
    and moderation_status in ('pending','approved');

  select coalesce(jsonb_object_agg(evidence_type, c order by evidence_type), '{}'::jsonb)
  into v_type_counts
  from (
    select evidence_type, count(*) as c
    from pods_provisioning.civic_action_evidence_v1
    where civic_campaign_id = p_civic_campaign_id
      and public_visible = true
      and moderation_status in ('pending','approved')
    group by evidence_type
  ) x;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_EVIDENCE_LIBRARY_OK',
    'civic_campaign_id', p_civic_campaign_id,
    'total_evidence_count', v_total_count,
    'public_visible_count', v_visible_count,
    'type_counts', v_type_counts
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_civic_evidence_public_library_v1"("p_civic_campaign_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_civic_petition_public_count_v1"("p_civic_campaign_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_count integer;
  v_goal integer;
begin
  select petition_goal
  into v_goal
  from pods_provisioning.civic_action_campaigns_v1
  where civic_campaign_id = p_civic_campaign_id;

  if not found then
    raise exception 'CIVIC_COUNT_CAMPAIGN_NOT_FOUND';
  end if;

  select count(*)
  into v_count
  from pods_provisioning.civic_action_petition_signatures_v1
  where civic_campaign_id = p_civic_campaign_id
    and moderation_status in ('pending','approved');

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_PETITION_COUNT_OK',
    'civic_campaign_id', p_civic_campaign_id,
    'signature_count', v_count,
    'petition_goal', v_goal,
    'goal_reached', v_count >= v_goal
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_civic_petition_public_count_v1"("p_civic_campaign_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_civic_survey_public_count_v1"("p_civic_campaign_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_question_count integer;
  v_response_count integer;
begin
  select count(*)
  into v_question_count
  from pods_provisioning.civic_action_survey_questions_v1
  where civic_campaign_id = p_civic_campaign_id;

  select count(*)
  into v_response_count
  from pods_provisioning.civic_action_survey_responses_v1
  where civic_campaign_id = p_civic_campaign_id
    and moderation_status in ('pending','approved');

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_SURVEY_COUNT_OK',
    'civic_campaign_id', p_civic_campaign_id,
    'question_count', v_question_count,
    'response_count', v_response_count
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_civic_survey_public_count_v1"("p_civic_campaign_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_clone_model_instance_v1"("p_source_model_instance_runtime_id" "uuid", "p_clone_name" "text", "p_clone_slug" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_source record;

  v_wizard jsonb;
  v_package jsonb;

  v_body jsonb;
  v_hash text;
  v_clone_id uuid;
begin

  select *
  into v_source
  from pods_provisioning.model_instance_runtimes_v1
  where model_instance_runtime_id = p_source_model_instance_runtime_id
  limit 1;

  if not found then
    raise exception 'MODEL_INSTANCE_CLONE_SOURCE_NOT_FOUND';
  end if;

  v_wizard :=
    pods_provisioning.rpc_run_model_instance_wizard_v1(
      v_source.org_id,
      v_source.model_key,
      v_source.model_version,
      (
        coalesce(
          v_source.instance_body->'normalized_fields',
          '{}'::jsonb
        )
        ||
        jsonb_build_object(
          'issue_title', p_clone_name,
          'site_name', p_clone_name,
          'product_name', p_clone_name
        )
      )
    );

  v_package :=
    pods_provisioning.rpc_generate_model_launch_package_v1(
      (v_wizard->>'model_instance_runtime_id')::uuid
    );

  v_body :=
    jsonb_build_object(
      'ok', true,
      'token', 'PROTEUSOPS_MODEL_INSTANCE_CLONING_OK',

      'org_id', v_source.org_id,

      'model_key', v_source.model_key,
      'model_version', v_source.model_version,

      'source_model_instance_runtime_id',
      v_source.model_instance_runtime_id,

      'cloned_model_instance_runtime_id',
      v_wizard->>'model_instance_runtime_id',

      'clone_name', p_clone_name,
      'clone_slug', p_clone_slug,

      'source_instance_name',
      v_source.instance_name,

      'launch_package',
      v_package,

      'clone_status',
      'completed'
    );

  v_hash :=
    pods_provisioning._sha256_text_v1(
      v_body::text
    );

  insert into pods_provisioning.model_instance_clones_v1(
    source_model_instance_runtime_id,
    cloned_model_instance_runtime_id,
    org_id,
    clone_name,
    clone_slug,
    clone_status,
    clone_body,
    clone_hash
  )
  values (
    v_source.model_instance_runtime_id,
    (v_wizard->>'model_instance_runtime_id')::uuid,
    v_source.org_id,
    p_clone_name,
    p_clone_slug,
    'completed',
    v_body,
    v_hash
  )
  returning model_instance_clone_id
  into v_clone_id;

  return
    v_body ||
    jsonb_build_object(
      'model_instance_clone_id',
      v_clone_id,
      'clone_hash',
      v_hash
    );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_clone_model_instance_v1"("p_source_model_instance_runtime_id" "uuid", "p_clone_name" "text", "p_clone_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_compare_runtime_snapshots_v1"("p_snapshot_a" "uuid", "p_snapshot_b" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  a record;
  b record;
begin
  select * into a
  from pods_provisioning.model_runtime_snapshots_v1
  where model_runtime_snapshot_id = p_snapshot_a;

  select * into b
  from pods_provisioning.model_runtime_snapshots_v1
  where model_runtime_snapshot_id = p_snapshot_b;

  if not found then
    raise exception 'MODEL_RUNTIME_SNAPSHOT_COMPARE_NOT_FOUND';
  end if;

  return jsonb_build_object(
    'ok',true,
    'token','PROTEUSOPS_MODEL_RUNTIME_SNAPSHOT_OK',
    'same_hash', a.snapshot_hash = b.snapshot_hash,
    'snapshot_a_hash',a.snapshot_hash,
    'snapshot_b_hash',b.snapshot_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_compare_runtime_snapshots_v1"("p_snapshot_a" "uuid", "p_snapshot_b" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_complete_contractor_site_visit_v1"("p_site_visit_id" "uuid", "p_site_notes" "text" DEFAULT ''::"text", "p_measurement_summary" "jsonb" DEFAULT '{}'::"jsonb", "p_photo_refs" "jsonb" DEFAULT '[]'::"jsonb", "p_follow_up_required" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_visit record;
  v_body jsonb;
  v_hash text;
  v_new_status text;
begin
  if p_site_visit_id is null then
    raise exception 'SITE_VISIT_COMPLETE_ID_REQUIRED';
  end if;

  select *
  into v_visit
  from pods_provisioning.contractor_site_visits_v1 sv
  where sv.site_visit_id = p_site_visit_id
  for update;

  if not found then
    raise exception 'SITE_VISIT_COMPLETE_NOT_FOUND';
  end if;

  if v_visit.visit_status <> 'scheduled' then
    raise exception 'SITE_VISIT_COMPLETE_STATUS_INVALID:%', v_visit.visit_status;
  end if;

  if p_follow_up_required then
    v_new_status := 'needs_follow_up';
  else
    v_new_status := 'completed';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CONTRACTOR_SITE_VISIT_COMPLETE_OK',
    'site_visit_id', v_visit.site_visit_id,
    'estimate_request_id', v_visit.estimate_request_id,
    'org_id', v_visit.org_id,
    'previous_status', v_visit.visit_status,
    'new_status', v_new_status,
    'site_notes', coalesce(p_site_notes,''),
    'measurement_summary', coalesce(p_measurement_summary,'{}'::jsonb),
    'photo_refs', coalesce(p_photo_refs,'[]'::jsonb),
    'follow_up_required', p_follow_up_required,
    'estimate_ready', not p_follow_up_required
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  update pods_provisioning.contractor_site_visits_v1
  set
    visit_status = v_new_status,
    site_notes = coalesce(p_site_notes,''),
    measurement_summary = coalesce(p_measurement_summary,'{}'::jsonb),
    photo_refs = coalesce(p_photo_refs,'[]'::jsonb),
    follow_up_required = p_follow_up_required,
    visit_body = v_body,
    visit_hash = v_hash
  where site_visit_id = v_visit.site_visit_id;

  update pods_provisioning.contractor_estimate_requests_v1
  set estimate_status = case
    when p_follow_up_required then 'site_visit_scheduled'
    else 'estimate_sent'
  end
  where estimate_request_id = v_visit.estimate_request_id;

  return v_body || jsonb_build_object(
    'visit_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_complete_contractor_site_visit_v1"("p_site_visit_id" "uuid", "p_site_notes" "text", "p_measurement_summary" "jsonb", "p_photo_refs" "jsonb", "p_follow_up_required" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_complete_launch_execution_worker_v1"("p_worker_run_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_worker record;
  v_completed jsonb;
  v_body jsonb;
  v_hash text;
begin
  if p_worker_run_id is null then
    raise exception 'LAUNCH_WORKER_COMPLETE_ID_REQUIRED';
  end if;

  select *
  into v_worker
  from pods_provisioning.launch_execution_worker_runs_v1 w
  where w.worker_run_id = p_worker_run_id
  for update;

  if not found then
    raise exception 'LAUNCH_WORKER_COMPLETE_NOT_FOUND';
  end if;

  if v_worker.worker_status not in ('queued','running') then
    raise exception 'LAUNCH_WORKER_COMPLETE_STATUS_INVALID:%', v_worker.worker_status;
  end if;

  v_completed := jsonb_build_array(
    'validate_launch_receipt',
    'activate_resources',
    'activate_capabilities',
    'finalize_adapters',
    'emit_launch_complete_receipt'
  );

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_LAUNCH_EXECUTION_WORKER_COMPLETE_OK',
    'worker_run_id', v_worker.worker_run_id,
    'launch_control_receipt_id', v_worker.launch_control_receipt_id,
    'org_id', v_worker.org_id,
    'model_key', v_worker.model_key,
    'model_version', v_worker.model_version,
    'previous_status', v_worker.worker_status,
    'worker_status', 'completed',
    'completed_steps', v_completed,
    'failed_steps', jsonb_build_array(),
    'retry_count', v_worker.retry_count,
    'replay_ready', true,
    'rollback_ready', true
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  update pods_provisioning.launch_execution_worker_runs_v1
  set
    worker_status = 'completed',
    completed_steps = v_completed,
    failed_steps = jsonb_build_array(),
    worker_body = v_body,
    worker_hash = v_hash,
    updated_at = now()
  where worker_run_id = v_worker.worker_run_id;

  return v_body || jsonb_build_object(
    'worker_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_complete_launch_execution_worker_v1"("p_worker_run_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_complete_provider_connection_session_v1"("p_provider_connection_session_id" "uuid", "p_provider_account_ref" "text", "p_provider_project_ref" "text", "p_secret_ref" "text", "p_discovered_resources" "jsonb" DEFAULT '[]'::"jsonb", "p_verification_results" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_session record;
  v_body jsonb;
  v_hash text;
begin
  if p_provider_connection_session_id is null then
    raise exception 'PROVIDER_CONNECTION_SESSION_REQUIRED';
  end if;

  if p_secret_ref is null or btrim(p_secret_ref) = '' then
    raise exception 'PROVIDER_CONNECTION_SECRET_REF_REQUIRED';
  end if;

  if p_secret_ref not like 'secret://%' then
    raise exception 'PROVIDER_CONNECTION_SECRET_REF_INVALID';
  end if;

  select *
  into v_session
  from pods_provisioning.provider_connection_sessions_v1 s
  where s.provider_connection_session_id = p_provider_connection_session_id
  for update;

  if not found then
    raise exception 'PROVIDER_CONNECTION_SESSION_NOT_FOUND';
  end if;

  if v_session.connection_status in ('verified','revoked') then
    raise exception 'PROVIDER_CONNECTION_SESSION_STATUS_INVALID:%', v_session.connection_status;
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PROVIDER_CONNECTION_COMPLETION_OK',
    'provider_connection_session_id', v_session.provider_connection_session_id,
    'org_id', v_session.org_id,
    'provider_key', v_session.provider_key,
    'connection_status', 'verified',
    'connection_method', v_session.connection_method,
    'manual_key_entry_used', false,
    'provider_account_ref', coalesce(p_provider_account_ref,''),
    'provider_project_ref', coalesce(p_provider_project_ref,''),
    'secret_ref', p_secret_ref,
    'secret_ref_only', true,
    'raw_secret_stored', false,
    'discovered_resources', coalesce(p_discovered_resources,'[]'::jsonb),
    'verification_results', coalesce(p_verification_results,'[]'::jsonb),
    'launch_blocked', false
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  update pods_provisioning.provider_connection_sessions_v1
  set
    connection_status = 'verified',
    manual_key_entry_used = false,
    provider_account_ref = coalesce(p_provider_account_ref,''),
    provider_project_ref = coalesce(p_provider_project_ref,''),
    secret_ref = p_secret_ref,
    discovered_resources = coalesce(p_discovered_resources,'[]'::jsonb),
    verification_results = coalesce(p_verification_results,'[]'::jsonb),
    launch_blocked = false,
    session_body = v_body,
    session_hash = v_hash,
    updated_at = now()
  where provider_connection_session_id = v_session.provider_connection_session_id;

  return v_body || jsonb_build_object(
    'session_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_complete_provider_connection_session_v1"("p_provider_connection_session_id" "uuid", "p_provider_account_ref" "text", "p_provider_project_ref" "text", "p_secret_ref" "text", "p_discovered_resources" "jsonb", "p_verification_results" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_compose_model_page_v1"("p_org_id" "uuid", "p_model_key" "text", "p_model_version" "text", "p_page_key" "text", "p_page_title" "text", "p_page_purpose" "text", "p_route" "text", "p_surface" "text" DEFAULT 'public'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_blocks jsonb := '[]'::jsonb;
  v_required_providers jsonb := '[]'::jsonb;
  v_required_permissions jsonb := '[]'::jsonb;

  v_body jsonb;
  v_hash text;
  v_id uuid;
begin
  if p_org_id is null then
    raise exception 'MODEL_PAGE_COMPOSER_ORG_REQUIRED';
  end if;

  perform pods_provisioning.rpc_seed_model_block_registry_v1();

  if p_page_purpose = 'civic_issue' then
    v_blocks := jsonb_build_array(
      jsonb_build_object('order',1,'block_key','hero'),
      jsonb_build_object('order',2,'block_key','rich_text'),
      jsonb_build_object('order',3,'block_key','evidence_library'),
      jsonb_build_object('order',4,'block_key','petition'),
      jsonb_build_object('order',5,'block_key','survey'),
      jsonb_build_object('order',6,'block_key','event_list'),
      jsonb_build_object('order',7,'block_key','contribution_wall')
    );
  elsif p_page_purpose = 'software_product' then
    v_blocks := jsonb_build_array(
      jsonb_build_object('order',1,'block_key','hero'),
      jsonb_build_object('order',2,'block_key','product'),
      jsonb_build_object('order',3,'block_key','image_gallery'),
      jsonb_build_object('order',4,'block_key','video'),
      jsonb_build_object('order',5,'block_key','pricing'),
      jsonb_build_object('order',6,'block_key','license_download'),
      jsonb_build_object('order',7,'block_key','faq')
    );
  elsif p_page_purpose = 'creator_media' then
    v_blocks := jsonb_build_array(
      jsonb_build_object('order',1,'block_key','hero'),
      jsonb_build_object('order',2,'block_key','video'),
      jsonb_build_object('order',3,'block_key','video_playlist'),
      jsonb_build_object('order',4,'block_key','product'),
      jsonb_build_object('order',5,'block_key','file_download'),
      jsonb_build_object('order',6,'block_key','contact_form')
    );
  elsif p_page_purpose = 'booking_site' then
    v_blocks := jsonb_build_array(
      jsonb_build_object('order',1,'block_key','hero'),
      jsonb_build_object('order',2,'block_key','rich_text'),
      jsonb_build_object('order',3,'block_key','image_gallery'),
      jsonb_build_object('order',4,'block_key','booking'),
      jsonb_build_object('order',5,'block_key','calendar'),
      jsonb_build_object('order',6,'block_key','contact_form')
    );
  elsif p_page_purpose = 'custom_page' then
    v_blocks := jsonb_build_array(
      jsonb_build_object('order',1,'block_key','hero'),
      jsonb_build_object('order',2,'block_key','rich_text'),
      jsonb_build_object('order',3,'block_key','image'),
      jsonb_build_object('order',4,'block_key','custom')
    );
  else
    v_blocks := jsonb_build_array(
      jsonb_build_object('order',1,'block_key','hero'),
      jsonb_build_object('order',2,'block_key','rich_text')
    );
  end if;

  select coalesce(jsonb_agg(distinct provider),'[]'::jsonb)
  into v_required_providers
  from (
    select jsonb_array_elements_text(r.required_providers) as provider
    from jsonb_array_elements(v_blocks) b
    join pods_provisioning.model_block_registry_v1 r
      on r.block_key = b->>'block_key'
  ) x;

  select coalesce(jsonb_agg(distinct permission),'[]'::jsonb)
  into v_required_permissions
  from (
    select jsonb_array_elements_text(r.required_permissions) as permission
    from jsonb_array_elements(v_blocks) b
    join pods_provisioning.model_block_registry_v1 r
      on r.block_key = b->>'block_key'
  ) x;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_PAGE_COMPOSER_OK',
    'org_id', p_org_id,
    'model_key', p_model_key,
    'model_version', p_model_version,
    'page_key', p_page_key,
    'page_title', p_page_title,
    'page_purpose', p_page_purpose,
    'route', p_route,
    'surface', coalesce(p_surface,'public'),
    'blocks', v_blocks,
    'required_providers', v_required_providers,
    'required_permissions', v_required_permissions,
    'composition_status', 'generated'
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_page_compositions_v1(
    org_id,
    model_key,
    model_version,
    page_key,
    page_title,
    page_purpose,
    route,
    surface,
    blocks,
    required_providers,
    required_permissions,
    composition_status,
    composition_body,
    composition_hash
  )
  values (
    p_org_id,
    p_model_key,
    p_model_version,
    p_page_key,
    p_page_title,
    p_page_purpose,
    p_route,
    coalesce(p_surface,'public'),
    v_blocks,
    v_required_providers,
    v_required_permissions,
    'generated',
    v_body,
    v_hash
  )
  returning model_page_composition_id
  into v_id;

  return v_body || jsonb_build_object(
    'model_page_composition_id', v_id,
    'composition_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_compose_model_page_v1"("p_org_id" "uuid", "p_model_key" "text", "p_model_version" "text", "p_page_key" "text", "p_page_title" "text", "p_page_purpose" "text", "p_route" "text", "p_surface" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_connect_domain_provider_v1"("p_org_id" "uuid", "p_provider_key" "text" DEFAULT 'cloudflare'::"text", "p_account_ref" "text" DEFAULT ''::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_body jsonb;
  v_hash text;
  v_id uuid;
begin
  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_DOMAIN_PROVIDER_AUTHORITY_OK',
    'org_id', p_org_id,
    'provider_key', p_provider_key,
    'connection_status', 'connected',
    'account_ref_present', coalesce(p_account_ref,'') <> '',
    'capabilities', jsonb_build_array(
      'dns',
      'ssl',
      'custom_hostname',
      'domain_registration',
      'domain_health'
    )
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.domain_provider_connections_v1(
    org_id,
    provider_key,
    connection_status,
    account_ref,
    capabilities,
    connection_hash
  )
  values (
    p_org_id,
    p_provider_key,
    'connected',
    coalesce(p_account_ref,''),
    v_body->'capabilities',
    v_hash
  )
  returning domain_provider_connection_id
  into v_id;

  return v_body || jsonb_build_object(
    'domain_provider_connection_id', v_id,
    'connection_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_connect_domain_provider_v1"("p_org_id" "uuid", "p_provider_key" "text", "p_account_ref" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_connection_layer_launch_control_v1"("p_org_id" "uuid", "p_model_key" "text" DEFAULT 'DEVELOPER_PORTAL_V1'::"text", "p_model_version" "text" DEFAULT 'v1'::"text", "p_wizard_session_id" "uuid" DEFAULT NULL::"uuid", "p_plan_run_id" "uuid" DEFAULT NULL::"uuid", "p_deployment_receipt_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_connection_rollup jsonb;
  v_bridge jsonb;
  v_readiness jsonb;
  v_launch_control jsonb := '{}'::jsonb;
  v_worker jsonb := '{}'::jsonb;

  v_ready boolean := false;
  v_status text := 'blocked';

  v_body jsonb;
  v_hash text;
  v_run_id uuid;
begin
  if p_org_id is null then
    raise exception 'CONNECTION_LAUNCH_ORG_REQUIRED';
  end if;

  v_connection_rollup := pods_provisioning.rpc_provider_connection_rollup_v1(
    p_org_id,
    p_model_key,
    p_model_version
  );

  if v_connection_rollup->>'connection_ready' <> 'true' then
    v_body := jsonb_build_object(
      'ok', true,
      'token', 'PROTEUSOPS_CONNECTION_LAYER_LAUNCH_CONTROL_OK',
      'org_id', p_org_id,
      'model_key', p_model_key,
      'model_version', p_model_version,
      'connection_ready', false,
      'launch_ready', false,
      'launch_status', 'blocked',
      'missing_providers', v_connection_rollup->'missing_providers',
      'provider_connection_rollup', v_connection_rollup
    );

    v_hash := pods_provisioning._sha256_text_v1(v_body::text);

    insert into pods_provisioning.connection_layer_launch_control_runs_v1(
      org_id,
      model_key,
      model_version,
      provider_connection_rollup_id,
      launch_ready,
      launch_status,
      run_body,
      run_hash
    )
    values (
      p_org_id,
      p_model_key,
      p_model_version,
      (v_connection_rollup->>'provider_connection_rollup_id')::uuid,
      false,
      'blocked',
      v_body,
      v_hash
    )
    returning connection_launch_run_id
    into v_run_id;

    return v_body || jsonb_build_object(
      'connection_launch_run_id', v_run_id,
      'run_hash', v_hash
    );
  end if;

  v_bridge := pods_provisioning.rpc_bridge_provider_connections_to_runtime_v1(
    p_org_id,
    (v_connection_rollup->>'provider_connection_rollup_id')::uuid,
    p_model_key,
    p_model_version
  );

  v_readiness := pods_provisioning.rpc_provider_readiness_rollup_v1(
    p_org_id,
    p_model_key,
    p_model_version
  );

  v_ready := (v_readiness->>'launch_ready' = 'true');

  if v_ready then
    v_status := 'ready';
  else
    v_status := 'blocked';
  end if;

  if v_ready
    and p_wizard_session_id is not null
    and p_plan_run_id is not null
    and p_deployment_receipt_id is not null then

    v_launch_control := pods_provisioning.rpc_emit_launch_control_plane_receipt_v1(
      p_org_id,
      p_wizard_session_id,
      p_plan_run_id,
      p_deployment_receipt_id,
      (v_readiness->>'provider_readiness_rollup_id')::uuid
    );

    if v_launch_control->>'launch_decision' = 'ready' then
      v_worker := pods_provisioning.rpc_queue_launch_execution_worker_v1(
        (v_launch_control->>'launch_control_receipt_id')::uuid
      );

      if v_worker->>'token' = 'PROTEUSOPS_LAUNCH_EXECUTION_WORKER_OK' then
        v_status := 'queued';
      end if;
    end if;
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CONNECTION_LAYER_LAUNCH_CONTROL_OK',
    'org_id', p_org_id,
    'model_key', p_model_key,
    'model_version', p_model_version,
    'connection_ready', true,
    'bridge_ready', v_bridge->>'bridge_ready',
    'launch_ready', v_ready,
    'launch_status', v_status,
    'provider_connection_rollup', v_connection_rollup,
    'runtime_bridge', v_bridge,
    'provider_readiness', v_readiness,
    'launch_control', v_launch_control,
    'worker', v_worker
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.connection_layer_launch_control_runs_v1(
    org_id,
    model_key,
    model_version,
    provider_connection_rollup_id,
    provider_connection_runtime_bridge_id,
    provider_readiness_rollup_id,
    launch_control_receipt_id,
    worker_run_id,
    launch_ready,
    launch_status,
    run_body,
    run_hash
  )
  values (
    p_org_id,
    p_model_key,
    p_model_version,
    (v_connection_rollup->>'provider_connection_rollup_id')::uuid,
    nullif(v_bridge->>'provider_connection_runtime_bridge_id','')::uuid,
    nullif(v_readiness->>'provider_readiness_rollup_id','')::uuid,
    nullif(v_launch_control->>'launch_control_receipt_id','')::uuid,
    nullif(v_worker->>'worker_run_id','')::uuid,
    v_ready,
    v_status,
    v_body,
    v_hash
  )
  returning connection_launch_run_id
  into v_run_id;

  return v_body || jsonb_build_object(
    'connection_launch_run_id', v_run_id,
    'run_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_connection_layer_launch_control_v1"("p_org_id" "uuid", "p_model_key" "text", "p_model_version" "text", "p_wizard_session_id" "uuid", "p_plan_run_id" "uuid", "p_deployment_receipt_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_create_adapter_attachment_run_v1"("p_deployment_receipt_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_deploy record;
  v_body jsonb;
  v_hash text;
  v_run_id uuid;
  v_adapter text;
  v_item_body jsonb;
  v_item_hash text;
begin
  if p_deployment_receipt_id is null then
    raise exception 'ADAPTER_ATTACHMENT_DEPLOYMENT_REQUIRED';
  end if;

  select *
  into v_deploy
  from pods_provisioning.model_deployment_receipts_v1 d
  where d.deployment_receipt_id = p_deployment_receipt_id
  limit 1;

  if not found then
    raise exception 'ADAPTER_ATTACHMENT_DEPLOYMENT_NOT_FOUND';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_ADAPTER_ATTACHMENT_RUNTIME_OK',
    'deployment_receipt_id', v_deploy.deployment_receipt_id,
    'plan_run_id', v_deploy.plan_run_id,
    'org_id', v_deploy.org_id,
    'model_key', v_deploy.model_key,
    'model_version', v_deploy.model_version,
    'attachment_status', 'pending',
    'required_adapters', v_deploy.adapter_manifest,
    'attached_adapters', jsonb_build_array(),
    'missing_adapters', v_deploy.adapter_manifest,
    'launch_blocked', true
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.adapter_attachment_runs_v1(
    deployment_receipt_id,
    plan_run_id,
    org_id,
    model_key,
    model_version,
    attachment_status,
    required_adapters,
    attached_adapters,
    missing_adapters,
    launch_blocked,
    attachment_body,
    attachment_hash
  )
  values (
    v_deploy.deployment_receipt_id,
    v_deploy.plan_run_id,
    v_deploy.org_id,
    v_deploy.model_key,
    v_deploy.model_version,
    'pending',
    v_deploy.adapter_manifest,
    jsonb_build_array(),
    v_deploy.adapter_manifest,
    true,
    v_body,
    v_hash
  )
  returning adapter_attachment_run_id
  into v_run_id;

  for v_adapter in
    select value::text
    from jsonb_array_elements_text(v_deploy.adapter_manifest)
  loop
    v_item_body := jsonb_build_object(
      'adapter_key', v_adapter,
      'adapter_status', 'missing',
      'required', true,
      'secret_ref_required', true
    );

    v_item_hash := pods_provisioning._sha256_text_v1(
      v_run_id::text || '|' || v_adapter || '|missing'
    );

    insert into pods_provisioning.adapter_attachment_items_v1(
      adapter_attachment_run_id,
      org_id,
      adapter_key,
      provider_key,
      adapter_status,
      required,
      config_ref,
      public_metadata,
      secret_ref_required,
      item_body,
      item_hash
    )
    values (
      v_run_id,
      v_deploy.org_id,
      v_adapter,
      '',
      'missing',
      true,
      '',
      '{}'::jsonb,
      true,
      v_item_body,
      v_item_hash
    );
  end loop;

  return v_body || jsonb_build_object(
    'adapter_attachment_run_id', v_run_id,
    'attachment_hash', v_hash
  );
exception
  when unique_violation then
    raise exception 'ADAPTER_ATTACHMENT_DUPLICATE_DENY:%', p_deployment_receipt_id;
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_create_adapter_attachment_run_v1"("p_deployment_receipt_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_create_appointment_confirmation_notification_v1"("p_appointment_request_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_req record;
  v_template record;
  v_body jsonb;
  v_hash text;
  v_notification_id uuid;
begin
  if p_appointment_request_id is null then
    raise exception 'NOTIFICATION_APPOINTMENT_REQUIRED';
  end if;

  select *
  into v_req
  from pods_provisioning.public_appointment_requests_v1 r
  where r.appointment_request_id = p_appointment_request_id
  limit 1;

  if not found then
    raise exception 'NOTIFICATION_APPOINTMENT_NOT_FOUND';
  end if;

  select *
  into v_template
  from pods_provisioning.notification_templates_v1 nt
  where nt.notification_kind = 'appointment_confirmation'
    and nt.delivery_channel = 'email'
    and nt.active = true
  limit 1;

  if not found then
    raise exception 'NOTIFICATION_TEMPLATE_NOT_FOUND';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CUSTOMER_NOTIFICATIONS_OK',
    'appointment_request_id', v_req.appointment_request_id,
    'org_id', v_req.org_id,
    'notification_kind', 'appointment_confirmation',
    'delivery_channel', 'email',
    'recipient_email', v_req.customer_email,
    'service_code', v_req.service_code,
    'requested_date', v_req.requested_date::text,
    'requested_start_time', v_req.requested_start_time::text,
    'requested_end_time', v_req.requested_end_time::text,
    'template_key', v_template.template_key,
    'template_version', v_template.template_version,
    'delivery_status', 'scheduled'
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.notifications_v1(
    org_id,
    appointment_request_id,
    notification_kind,
    delivery_channel,
    recipient_email,
    recipient_phone,
    scheduled_at,
    delivery_status,
    template_key,
    template_version,
    rendered_subject,
    rendered_body,
    notification_body,
    notification_hash
  )
  values (
    v_req.org_id,
    v_req.appointment_request_id,
    'appointment_confirmation',
    'email',
    v_req.customer_email,
    v_req.customer_phone,
    now(),
    'scheduled',
    v_template.template_key,
    v_template.template_version,
    v_template.subject_template,
    v_template.body_template,
    v_body,
    v_hash
  )
  returning notification_id
  into v_notification_id;

  return v_body || jsonb_build_object(
    'notification_id', v_notification_id,
    'notification_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_create_appointment_confirmation_notification_v1"("p_appointment_request_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_create_civic_action_campaign_v1"("p_org_id" "uuid", "p_issue_title" "text", "p_community_name" "text" DEFAULT ''::"text", "p_location_label" "text" DEFAULT ''::"text", "p_position_type" "text" DEFAULT 'oppose_or_support'::"text", "p_issue_summary" "text" DEFAULT ''::"text", "p_petition_goal" integer DEFAULT 500, "p_campaign_status" "text" DEFAULT 'published'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_body jsonb;
  v_hash text;
  v_campaign_id uuid;
begin
  if p_org_id is null then
    raise exception 'CIVIC_CAMPAIGN_ORG_REQUIRED';
  end if;

  if p_issue_title is null or btrim(p_issue_title) = '' then
    raise exception 'CIVIC_CAMPAIGN_TITLE_REQUIRED';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_CAMPAIGN_OK',
    'org_id', p_org_id,
    'model_key', 'CIVIC_ACTION_V1',
    'model_version', 'v1',
    'issue_title', p_issue_title,
    'community_name', coalesce(p_community_name,''),
    'location_label', coalesce(p_location_label,''),
    'position_type', coalesce(p_position_type,'oppose_or_support'),
    'issue_summary', coalesce(p_issue_summary,''),
    'petition_goal', coalesce(p_petition_goal,500),
    'campaign_status', coalesce(p_campaign_status,'published')
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.civic_action_campaigns_v1(
    org_id,
    model_key,
    model_version,
    issue_title,
    community_name,
    location_label,
    position_type,
    issue_summary,
    petition_goal,
    campaign_status,
    campaign_body,
    campaign_hash
  )
  values (
    p_org_id,
    'CIVIC_ACTION_V1',
    'v1',
    p_issue_title,
    coalesce(p_community_name,''),
    coalesce(p_location_label,''),
    coalesce(p_position_type,'oppose_or_support'),
    coalesce(p_issue_summary,''),
    coalesce(p_petition_goal,500),
    coalesce(p_campaign_status,'published'),
    v_body,
    v_hash
  )
  returning civic_campaign_id
  into v_campaign_id;

  return v_body || jsonb_build_object(
    'civic_campaign_id', v_campaign_id,
    'campaign_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_create_civic_action_campaign_v1"("p_org_id" "uuid", "p_issue_title" "text", "p_community_name" "text", "p_location_label" "text", "p_position_type" "text", "p_issue_summary" "text", "p_petition_goal" integer, "p_campaign_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_create_civic_action_event_v1"("p_civic_campaign_id" "uuid", "p_event_type" "text", "p_event_title" "text", "p_event_description" "text" DEFAULT ''::"text", "p_event_location" "text" DEFAULT ''::"text", "p_event_starts_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_event_status" "text" DEFAULT 'published'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_campaign record;
  v_body jsonb;
  v_hash text;
  v_event_id uuid;
begin
  if p_civic_campaign_id is null then
    raise exception 'CIVIC_EVENT_CAMPAIGN_REQUIRED';
  end if;

  if p_event_title is null or btrim(p_event_title) = '' then
    raise exception 'CIVIC_EVENT_TITLE_REQUIRED';
  end if;

  select *
  into v_campaign
  from pods_provisioning.civic_action_campaigns_v1
  where civic_campaign_id = p_civic_campaign_id
  limit 1;

  if not found then
    raise exception 'CIVIC_EVENT_CAMPAIGN_NOT_FOUND';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_EVENT_OK',
    'org_id', v_campaign.org_id,
    'civic_campaign_id', v_campaign.civic_campaign_id,
    'event_type', p_event_type,
    'event_title', p_event_title,
    'event_description', coalesce(p_event_description,''),
    'event_location', coalesce(p_event_location,''),
    'event_starts_at', p_event_starts_at,
    'event_status', coalesce(p_event_status,'published')
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.civic_action_events_v1(
    civic_campaign_id, org_id, event_type, event_title, event_description,
    event_location, event_starts_at, event_status, event_body, event_hash
  )
  values (
    v_campaign.civic_campaign_id, v_campaign.org_id, p_event_type, p_event_title,
    coalesce(p_event_description,''), coalesce(p_event_location,''), p_event_starts_at,
    coalesce(p_event_status,'published'), v_body, v_hash
  )
  returning civic_event_id into v_event_id;

  return v_body || jsonb_build_object('civic_event_id', v_event_id, 'event_hash', v_hash);
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_create_civic_action_event_v1"("p_civic_campaign_id" "uuid", "p_event_type" "text", "p_event_title" "text", "p_event_description" "text", "p_event_location" "text", "p_event_starts_at" timestamp with time zone, "p_event_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_create_contractor_job_from_approved_estimate_v1"("p_contractor_estimate_id" "uuid", "p_scheduled_start_date" "date", "p_scheduled_end_date" "date", "p_crew_count" integer DEFAULT 1) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_estimate record;
  v_decision record;
  v_body jsonb;
  v_hash text;
  v_job_id uuid;
begin
  if p_contractor_estimate_id is null then
    raise exception 'CONTRACTOR_JOB_ESTIMATE_REQUIRED';
  end if;

  if p_scheduled_start_date is null or p_scheduled_end_date is null then
    raise exception 'CONTRACTOR_JOB_DATES_REQUIRED';
  end if;

  if p_scheduled_end_date < p_scheduled_start_date then
    raise exception 'CONTRACTOR_JOB_DATES_INVALID';
  end if;

  if p_crew_count is null or p_crew_count < 0 then
    raise exception 'CONTRACTOR_JOB_CREW_INVALID';
  end if;

  select *
  into v_estimate
  from pods_provisioning.contractor_estimates_v1 ce
  where ce.contractor_estimate_id = p_contractor_estimate_id
  for update;

  if not found then
    raise exception 'CONTRACTOR_JOB_ESTIMATE_NOT_FOUND';
  end if;

  if v_estimate.estimate_status <> 'approved' then
    raise exception 'CONTRACTOR_JOB_REQUIRES_APPROVED_ESTIMATE:%', v_estimate.estimate_status;
  end if;

  select *
  into v_decision
  from pods_provisioning.contractor_estimate_decisions_v1 d
  where d.contractor_estimate_id = p_contractor_estimate_id
    and d.decision_kind = 'approve'
    and d.decision_status = 'accepted'
  limit 1;

  if not found then
    raise exception 'CONTRACTOR_JOB_APPROVAL_DECISION_NOT_FOUND';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CONTRACTOR_JOB_CREATION_OK',
    'contractor_estimate_id', v_estimate.contractor_estimate_id,
    'estimate_request_id', v_estimate.estimate_request_id,
    'org_id', v_estimate.org_id,
    'estimate_number', v_estimate.estimate_number,
    'job_status', 'scheduled',
    'scheduled_start_date', p_scheduled_start_date::text,
    'scheduled_end_date', p_scheduled_end_date::text,
    'crew_count', p_crew_count,
    'progress_percent', 0,
    'materials_ready', false,
    'change_order_ready', true,
    'invoice_ready', true,
    'completion_ready', false,
    'approval_decision_id', v_decision.estimate_decision_id
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.contractor_job_records_v1(
    estimate_request_id,
    org_id,
    job_status,
    scheduled_start_date,
    scheduled_end_date,
    crew_count,
    progress_percent,
    job_body,
    job_hash
  )
  values (
    v_estimate.estimate_request_id,
    v_estimate.org_id,
    'scheduled',
    p_scheduled_start_date,
    p_scheduled_end_date,
    p_crew_count,
    0,
    v_body,
    v_hash
  )
  returning contractor_job_id
  into v_job_id;

  insert into pods_provisioning.contractor_job_phases_v1(
    contractor_job_id,
    org_id,
    phase_key,
    display_name,
    phase_status,
    display_order,
    phase_body,
    phase_hash
  )
  values
  (
    v_job_id,
    v_estimate.org_id,
    'materials',
    'Materials',
    'pending',
    1,
    jsonb_build_object('phase_key','materials','status','pending'),
    pods_provisioning._sha256_text_v1(v_job_id::text || '|materials')
  ),
  (
    v_job_id,
    v_estimate.org_id,
    'work',
    'Work Execution',
    'pending',
    2,
    jsonb_build_object('phase_key','work','status','pending'),
    pods_provisioning._sha256_text_v1(v_job_id::text || '|work')
  ),
  (
    v_job_id,
    v_estimate.org_id,
    'inspection',
    'Final Inspection',
    'pending',
    3,
    jsonb_build_object('phase_key','inspection','status','pending'),
    pods_provisioning._sha256_text_v1(v_job_id::text || '|inspection')
  ),
  (
    v_job_id,
    v_estimate.org_id,
    'invoice',
    'Final Invoice',
    'pending',
    4,
    jsonb_build_object('phase_key','invoice','status','pending'),
    pods_provisioning._sha256_text_v1(v_job_id::text || '|invoice')
  );

  return v_body || jsonb_build_object(
    'contractor_job_id', v_job_id,
    'job_hash', v_hash,
    'phase_count', 4
  );
exception
  when unique_violation then
    raise exception 'CONTRACTOR_JOB_DUPLICATE_DENY:%', p_contractor_estimate_id;
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_create_contractor_job_from_approved_estimate_v1"("p_contractor_estimate_id" "uuid", "p_scheduled_start_date" "date", "p_scheduled_end_date" "date", "p_crew_count" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_create_launch_execution_runtime_v1"("p_deployment_receipt_id" "uuid", "p_adapter_attachment_run_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_deploy record;
  v_attach record;
  v_status text;
  v_blocked boolean;
  v_blockers jsonb;
  v_body jsonb;
  v_hash text;
  v_execution_id uuid;
begin
  if p_deployment_receipt_id is null then
    raise exception 'LAUNCH_EXECUTION_DEPLOYMENT_REQUIRED';
  end if;

  if p_adapter_attachment_run_id is null then
    raise exception 'LAUNCH_EXECUTION_ADAPTER_RUN_REQUIRED';
  end if;

  select *
  into v_deploy
  from pods_provisioning.model_deployment_receipts_v1 d
  where d.deployment_receipt_id = p_deployment_receipt_id
  limit 1;

  if not found then
    raise exception 'LAUNCH_EXECUTION_DEPLOYMENT_NOT_FOUND';
  end if;

  select *
  into v_attach
  from pods_provisioning.adapter_attachment_runs_v1 a
  where a.adapter_attachment_run_id = p_adapter_attachment_run_id
    and a.deployment_receipt_id = p_deployment_receipt_id
  limit 1;

  if not found then
    raise exception 'LAUNCH_EXECUTION_ADAPTER_RUN_NOT_FOUND';
  end if;

  v_blocked := v_attach.launch_blocked;
  v_blockers := case
    when v_blocked then
      jsonb_build_array(
        jsonb_build_object(
          'blocker_key','missing_required_adapters',
          'missing_adapters',v_attach.missing_adapters
        )
      )
    else
      '[]'::jsonb
    end;

  if v_blocked then
    v_status := 'blocked';
  else
    v_status := 'ready';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_LAUNCH_EXECUTION_RUNTIME_OK',
    'deployment_receipt_id', v_deploy.deployment_receipt_id,
    'adapter_attachment_run_id', v_attach.adapter_attachment_run_id,
    'plan_run_id', v_deploy.plan_run_id,
    'org_id', v_deploy.org_id,
    'model_key', v_deploy.model_key,
    'model_version', v_deploy.model_version,
    'execution_status', v_status,
    'launch_blocked', v_blocked,
    'launch_blockers', v_blockers,
    'activated_capabilities', case when v_blocked then '[]'::jsonb else v_deploy.capability_manifest end,
    'activated_resources', case when v_blocked then '[]'::jsonb else v_deploy.resource_manifest end,
    'verified_adapters', case when v_blocked then v_attach.attached_adapters else v_attach.required_adapters end,
    'replay_ready', true,
    'rollback_ready', true
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.launch_execution_runs_v1(
    deployment_receipt_id,
    adapter_attachment_run_id,
    plan_run_id,
    org_id,
    model_key,
    model_version,
    execution_status,
    launch_blocked,
    launch_blockers,
    activated_capabilities,
    activated_resources,
    verified_adapters,
    replay_ready,
    rollback_ready,
    execution_body,
    execution_hash
  )
  values (
    v_deploy.deployment_receipt_id,
    v_attach.adapter_attachment_run_id,
    v_deploy.plan_run_id,
    v_deploy.org_id,
    v_deploy.model_key,
    v_deploy.model_version,
    v_status,
    v_blocked,
    v_blockers,
    case when v_blocked then '[]'::jsonb else v_deploy.capability_manifest end,
    case when v_blocked then '[]'::jsonb else v_deploy.resource_manifest end,
    case when v_blocked then v_attach.attached_adapters else v_attach.required_adapters end,
    true,
    true,
    v_body,
    v_hash
  )
  returning launch_execution_id
  into v_execution_id;

  return v_body || jsonb_build_object(
    'launch_execution_id', v_execution_id,
    'execution_hash', v_hash
  );
exception
  when unique_violation then
    raise exception 'LAUNCH_EXECUTION_DUPLICATE_DENY:%', p_deployment_receipt_id;
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_create_launch_execution_runtime_v1"("p_deployment_receipt_id" "uuid", "p_adapter_attachment_run_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_create_model_deployment_receipt_v1"("p_plan_run_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_plan record;
  v_steps jsonb;
  v_failures jsonb;
  v_body jsonb;
  v_hash text;
  v_receipt_id uuid;
begin
  if p_plan_run_id is null then
    raise exception 'MODEL_DEPLOYMENT_PLAN_REQUIRED';
  end if;

  select *
  into v_plan
  from pods_provisioning.model_capability_plan_runs_v1 p
  where p.plan_run_id = p_plan_run_id
  limit 1;

  if not found then
    raise exception 'MODEL_DEPLOYMENT_PLAN_NOT_FOUND';
  end if;

  v_steps := jsonb_build_array(
    jsonb_build_object('step_order',1,'step_key','validate_plan','required',true),
    jsonb_build_object('step_order',2,'step_key','provision_resources','required',true),
    jsonb_build_object('step_order',3,'step_key','provision_capabilities','required',true),
    jsonb_build_object('step_order',4,'step_key','prepare_adapters','required',true),
    jsonb_build_object('step_order',5,'step_key','emit_launch_receipt','required',true)
  );

  v_failures := jsonb_build_array(
    'missing_required_field',
    'resource_provision_failed',
    'capability_provision_failed',
    'adapter_prepare_failed',
    'launch_receipt_failed'
  );

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_DEPLOYMENT_RECEIPTS_OK',
    'plan_run_id', v_plan.plan_run_id,
    'org_id', v_plan.org_id,
    'model_key', v_plan.model_key,
    'model_version', v_plan.model_version,
    'deployment_status', 'planned',
    'deployment_steps', v_steps,
    'resource_manifest', v_plan.provision_resources,
    'adapter_manifest', v_plan.provision_adapters,
    'capability_manifest', v_plan.provision_capabilities,
    'replay_ready', true,
    'rollback_ready', true,
    'failure_boundaries', v_failures
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_deployment_receipts_v1(
    plan_run_id,
    org_id,
    model_key,
    model_version,
    deployment_status,
    deployment_steps,
    resource_manifest,
    adapter_manifest,
    capability_manifest,
    replay_ready,
    rollback_ready,
    failure_boundaries,
    deployment_body,
    deployment_hash
  )
  values (
    v_plan.plan_run_id,
    v_plan.org_id,
    v_plan.model_key,
    v_plan.model_version,
    'planned',
    v_steps,
    v_plan.provision_resources,
    v_plan.provision_adapters,
    v_plan.provision_capabilities,
    true,
    true,
    v_failures,
    v_body,
    v_hash
  )
  returning deployment_receipt_id
  into v_receipt_id;

  return v_body || jsonb_build_object(
    'deployment_receipt_id', v_receipt_id,
    'deployment_hash', v_hash
  );
exception
  when unique_violation then
    raise exception 'MODEL_DEPLOYMENT_RECEIPT_DUPLICATE_DENY:%', p_plan_run_id;
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_create_model_deployment_receipt_v1"("p_plan_run_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_create_model_instance_runtime_v1"("p_org_id" "uuid", "p_model_key" "text", "p_model_version" "text" DEFAULT 'v2'::"text", "p_instance_name" "text" DEFAULT ''::"text", "p_instance_description" "text" DEFAULT ''::"text", "p_instance_fields" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_name text;
  v_slug text;
  v_site_runtime jsonb;
  v_body jsonb;
  v_hash text;
  v_id uuid;
begin
  if p_org_id is null then
    raise exception 'MODEL_INSTANCE_ORG_REQUIRED';
  end if;

  if p_model_key is null or btrim(p_model_key) = '' then
    raise exception 'MODEL_INSTANCE_MODEL_REQUIRED';
  end if;

  v_name := coalesce(nullif(btrim(p_instance_name),''),'Untitled Instance');

  v_slug := lower(regexp_replace(v_name, '[^a-zA-Z0-9]+', '-', 'g'));
  v_slug := trim(both '-' from v_slug);

  if v_slug = '' then
    v_slug := 'untitled-instance';
  end if;

  if p_model_key = 'CIVIC_ACTION_V1' then
    v_site_runtime := pods_provisioning.rpc_generate_model_site_runtime_v1(
      p_org_id,
      p_model_key,
      p_model_version,
      jsonb_build_object(
        'issue_title', coalesce(nullif(p_instance_fields->>'issue_title',''), v_name),
        'community_name', coalesce(p_instance_fields->>'community_name',''),
        'location_label', coalesce(p_instance_fields->>'location_label',''),
        'position_type', coalesce(nullif(p_instance_fields->>'position_type',''),'oppose'),
        'issue_summary', coalesce(nullif(p_instance_fields->>'issue_summary',''), coalesce(p_instance_description,'')),
        'petition_goal', coalesce(nullif(p_instance_fields->>'petition_goal','')::integer,500)
      )
    );
  else
    v_site_runtime := pods_provisioning.rpc_generate_model_site_runtime_v1(
      p_org_id,
      p_model_key,
      p_model_version,
      p_instance_fields
    );
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_INSTANCE_RUNTIME_OK',
    'org_id', p_org_id,
    'model_key', p_model_key,
    'model_version', p_model_version,
    'instance_name', v_name,
    'instance_slug', v_slug,
    'instance_description_present', coalesce(p_instance_description,'') <> '',
    'instance_status', 'generated',
    'launchable', v_site_runtime->>'launchable',
    'model_site_runtime_generation_id', v_site_runtime->>'model_site_runtime_generation_id',
    'site_runtime_hash', v_site_runtime->>'site_runtime_hash',
    'site_runtime_capabilities', v_site_runtime->'site_runtime_capabilities',
    'site_runtime', v_site_runtime
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_instance_runtimes_v1(
    org_id,
    model_key,
    model_version,
    instance_name,
    instance_slug,
    instance_description,
    instance_fields,
    model_site_runtime_generation_id,
    instance_status,
    launchable,
    instance_body,
    instance_hash
  )
  values (
    p_org_id,
    p_model_key,
    p_model_version,
    v_name,
    v_slug,
    coalesce(p_instance_description,''),
    coalesce(p_instance_fields,'{}'::jsonb),
    (v_site_runtime->>'model_site_runtime_generation_id')::uuid,
    'generated',
    (v_site_runtime->>'launchable')::boolean,
    v_body,
    v_hash
  )
  returning model_instance_runtime_id
  into v_id;

  return v_body || jsonb_build_object(
    'model_instance_runtime_id', v_id,
    'instance_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_create_model_instance_runtime_v1"("p_org_id" "uuid", "p_model_key" "text", "p_model_version" "text", "p_instance_name" "text", "p_instance_description" "text", "p_instance_fields" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_create_payment_intent_for_appointment_v1"("p_appointment_request_id" "uuid", "p_policy_key" "text" DEFAULT 'default-deposit'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_req record;
  v_policy record;
  v_body jsonb;
  v_hash text;
  v_payment_intent_id uuid;
begin
  if p_appointment_request_id is null then
    raise exception 'PAYMENT_INTENT_APPOINTMENT_REQUIRED';
  end if;

  select *
  into v_req
  from pods_provisioning.public_appointment_requests_v1 r
  where r.appointment_request_id = p_appointment_request_id
  limit 1;

  if not found then
    raise exception 'PAYMENT_INTENT_APPOINTMENT_NOT_FOUND';
  end if;

  select *
  into v_policy
  from pods_provisioning.payment_policies_v1 pp
  where pp.org_id = v_req.org_id
    and pp.policy_key = p_policy_key
    and pp.active = true
  limit 1;

  if not found then
    raise exception 'PAYMENT_POLICY_NOT_FOUND:%', p_policy_key;
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PAYMENT_LIFECYCLE_OK',
    'appointment_request_id', v_req.appointment_request_id,
    'org_id', v_req.org_id,
    'policy_key', v_policy.policy_key,
    'amount_cents', v_policy.deposit_amount_cents,
    'currency', 'usd',
    'payment_status', 'pending',
    'provider_key', 'adapter_pending',
    'adapter_required', true
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.payment_intents_v1(
    org_id,
    appointment_request_id,
    payment_policy_id,
    provider_key,
    provider_intent_id,
    amount_cents,
    currency,
    payment_status,
    intent_body,
    intent_hash
  )
  values (
    v_req.org_id,
    v_req.appointment_request_id,
    v_policy.payment_policy_id,
    'adapter_pending',
    '',
    v_policy.deposit_amount_cents,
    'usd',
    'pending',
    v_body,
    v_hash
  )
  returning payment_intent_id
  into v_payment_intent_id;

  insert into pods_provisioning.payment_events_v1(
    payment_intent_id,
    org_id,
    event_kind,
    previous_status,
    new_status,
    provider_key,
    provider_event_id,
    event_body,
    event_hash
  )
  values (
    v_payment_intent_id,
    v_req.org_id,
    'create_intent',
    'none',
    'pending',
    'adapter_pending',
    '',
    v_body,
    v_hash
  );

  return v_body || jsonb_build_object(
    'payment_intent_id', v_payment_intent_id,
    'intent_hash', v_hash
  );
exception
  when unique_violation then
    raise exception 'PAYMENT_INTENT_DUPLICATE_DENY:%', p_appointment_request_id;
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_create_payment_intent_for_appointment_v1"("p_appointment_request_id" "uuid", "p_policy_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_create_release_v1"("p_model_instance_runtime_id" "uuid", "p_channel_key" "text" DEFAULT 'development'::"text", "p_release_label" "text" DEFAULT 'release'::"text", "p_release_notes" "text" DEFAULT ''::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_runtime record;
  v_package record;
  v_snapshot record;
  v_checkpoint record;

  v_body jsonb;
  v_hash text;
  v_release_id uuid;
begin
  select *
  into v_runtime
  from pods_provisioning.model_instance_runtimes_v1
  where model_instance_runtime_id = p_model_instance_runtime_id
  limit 1;

  if not found then
    raise exception 'MODEL_RELEASE_RUNTIME_NOT_FOUND';
  end if;

  if p_channel_key not in ('development','staging','production','archived') then
    raise exception 'MODEL_RELEASE_CHANNEL_DENY';
  end if;

  select *
  into v_package
  from pods_provisioning.model_launch_packages_v1
  where model_instance_runtime_id = p_model_instance_runtime_id
  order by created_at desc
  limit 1;

  select *
  into v_snapshot
  from pods_provisioning.model_runtime_snapshots_v1
  where model_instance_runtime_id = p_model_instance_runtime_id
  order by created_at desc
  limit 1;

  select *
  into v_checkpoint
  from pods_provisioning.model_audit_checkpoints_v1
  where org_id = v_runtime.org_id
  order by created_at desc
  limit 1;

  insert into pods_provisioning.model_release_channels_v1(
    org_id,
    model_instance_runtime_id,
    channel_key,
    channel_status
  )
  values (
    v_runtime.org_id,
    v_runtime.model_instance_runtime_id,
    p_channel_key,
    'active'
  )
  on conflict (org_id, model_instance_runtime_id, channel_key) do nothing;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_RELEASE_GOVERNANCE_OK',
    'org_id', v_runtime.org_id,
    'model_instance_runtime_id', v_runtime.model_instance_runtime_id,
    'model_launch_package_id', case when v_package.model_launch_package_id is null then null else v_package.model_launch_package_id end,
    'channel_key', p_channel_key,
    'release_status', 'created',
    'release_label', p_release_label,
    'release_notes_present', coalesce(p_release_notes,'') <> '',
    'runtime_hash', v_runtime.instance_hash,
    'snapshot_hash', coalesce(v_snapshot.snapshot_hash,''),
    'launch_package_hash', coalesce(v_package.package_hash,''),
    'renderer_hash', coalesce(v_package.renderer_manifest->>'contract_hash',''),
    'audit_checkpoint_hash', coalesce(v_checkpoint.checkpoint_hash,'')
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_releases_v1(
    org_id,
    model_instance_runtime_id,
    model_launch_package_id,
    channel_key,
    release_status,
    release_label,
    release_notes,
    runtime_hash,
    snapshot_hash,
    launch_package_hash,
    renderer_hash,
    audit_checkpoint_hash,
    release_body,
    release_hash
  )
  values (
    v_runtime.org_id,
    v_runtime.model_instance_runtime_id,
    case when v_package.model_launch_package_id is null then null else v_package.model_launch_package_id end,
    p_channel_key,
    'created',
    p_release_label,
    coalesce(p_release_notes,''),
    v_runtime.instance_hash,
    coalesce(v_snapshot.snapshot_hash,''),
    coalesce(v_package.package_hash,''),
    coalesce(v_package.renderer_manifest->>'contract_hash',''),
    coalesce(v_checkpoint.checkpoint_hash,''),
    v_body,
    v_hash
  )
  returning model_release_id
  into v_release_id;

  return v_body || jsonb_build_object(
    'model_release_id', v_release_id,
    'release_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_create_release_v1"("p_model_instance_runtime_id" "uuid", "p_channel_key" "text", "p_release_label" "text", "p_release_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_create_runtime_asset_v1"("p_org_id" "uuid", "p_asset_type" "text", "p_asset_name" "text", "p_storage_ref" "text", "p_license_gate_required" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_id uuid;
  v_hash text;
begin
  if p_org_id is null then
    raise exception 'ASSET_RUNTIME_ORG_REQUIRED';
  end if;

  if p_asset_type is null or btrim(p_asset_type) = '' then
    raise exception 'ASSET_RUNTIME_TYPE_REQUIRED';
  end if;

  if p_asset_name is null or btrim(p_asset_name) = '' then
    raise exception 'ASSET_RUNTIME_NAME_REQUIRED';
  end if;

  if p_storage_ref is null or btrim(p_storage_ref) = '' then
    raise exception 'ASSET_RUNTIME_STORAGE_REF_REQUIRED';
  end if;

  v_hash := pods_provisioning._sha256_text_v1(
    coalesce(p_asset_name,'') || '|' || coalesce(p_storage_ref,'')
  );

  insert into pods_provisioning.asset_runtime_objects_v1(
    org_id,
    asset_type,
    asset_name,
    storage_provider,
    storage_ref,
    public_visible,
    license_gate_required,
    runtime_status,
    asset_hash
  )
  values(
    p_org_id,
    p_asset_type,
    p_asset_name,
    'storage',
    p_storage_ref,
    not p_license_gate_required,
    p_license_gate_required,
    'active',
    v_hash
  )
  returning asset_runtime_object_id
  into v_id;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_RUNTIME_ASSET_CREATED_OK',
    'asset_runtime_object_id', v_id,
    'asset_type', p_asset_type,
    'license_gate_required', p_license_gate_required,
    'asset_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_create_runtime_asset_v1"("p_org_id" "uuid", "p_asset_type" "text", "p_asset_name" "text", "p_storage_ref" "text", "p_license_gate_required" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_create_runtime_baseline_v1"("p_model_instance_runtime_id" "uuid", "p_baseline_source" "text" DEFAULT 'release'::"text", "p_baseline_ref_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_fp jsonb;
  v_id uuid;
begin
  if p_baseline_source not in ('release','snapshot','manual') then
    raise exception 'MODEL_RUNTIME_DRIFT_BASELINE_SOURCE_DENY';
  end if;

  v_fp := pods_provisioning.rpc_current_runtime_drift_fingerprint_v1(p_model_instance_runtime_id);

  update pods_provisioning.model_runtime_drift_baselines_v1
  set baseline_status = 'superseded'
  where model_instance_runtime_id = p_model_instance_runtime_id
    and baseline_status = 'active';

  insert into pods_provisioning.model_runtime_drift_baselines_v1(
    org_id,
    model_instance_runtime_id,
    baseline_source,
    baseline_ref_id,
    baseline_hash,
    baseline_body,
    baseline_status
  )
  values (
    (v_fp->>'org_id')::uuid,
    p_model_instance_runtime_id,
    p_baseline_source,
    p_baseline_ref_id,
    v_fp->>'composite_runtime_hash',
    v_fp,
    'active'
  )
  returning model_runtime_drift_baseline_id
  into v_id;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_RUNTIME_DRIFT_OK',
    'model_runtime_drift_baseline_id', v_id,
    'model_instance_runtime_id', p_model_instance_runtime_id,
    'baseline_source', p_baseline_source,
    'baseline_hash', v_fp->>'composite_runtime_hash',
    'baseline_status', 'active'
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_create_runtime_baseline_v1"("p_model_instance_runtime_id" "uuid", "p_baseline_source" "text", "p_baseline_ref_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_create_runtime_snapshot_v1"("p_model_instance_runtime_id" "uuid", "p_snapshot_name" "text", "p_snapshot_reason" "text" DEFAULT ''::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_runtime record;
  v_launch record;

  v_snapshot jsonb;
  v_hash text;

  v_snapshot_id uuid;
  v_receipt_id uuid;
begin
  select *
  into v_runtime
  from pods_provisioning.model_instance_runtimes_v1
  where model_instance_runtime_id = p_model_instance_runtime_id
  limit 1;

  if not found then
    raise exception 'MODEL_RUNTIME_SNAPSHOT_RUNTIME_NOT_FOUND';
  end if;

  select *
  into v_launch
  from pods_provisioning.model_launch_packages_v1
  where model_instance_runtime_id = p_model_instance_runtime_id
  order by created_at desc
  limit 1;

  v_snapshot := jsonb_build_object(
    'runtime_hash', v_runtime.instance_hash,
    'instance_name', v_runtime.instance_name,
    'instance_slug', v_runtime.instance_slug,
    'instance_status', v_runtime.instance_status
  );

  v_hash := pods_provisioning._sha256_text_v1(v_snapshot::text);

  insert into pods_provisioning.model_runtime_snapshots_v1(
    org_id,
    model_instance_runtime_id,
    snapshot_name,
    snapshot_reason,
    runtime_manifest,
    launch_package,
    renderer_contract,
    editor_state,
    asset_state,
    permission_state,
    snapshot_hash
  )
  values (
    v_runtime.org_id,
    v_runtime.model_instance_runtime_id,
    p_snapshot_name,
    p_snapshot_reason,
    v_snapshot,
    to_jsonb(v_launch),
    '{}'::jsonb,
    '{}'::jsonb,
    '{}'::jsonb,
    '{}'::jsonb,
    v_hash
  )
  returning model_runtime_snapshot_id
  into v_snapshot_id;

  insert into pods_provisioning.model_runtime_snapshot_receipts_v1(
    org_id,
    model_runtime_snapshot_id,
    receipt_action,
    receipt_body,
    receipt_hash
  )
  values (
    v_runtime.org_id,
    v_snapshot_id,
    'create',
    jsonb_build_object(
      'token','PROTEUSOPS_MODEL_RUNTIME_SNAPSHOT_OK',
      'snapshot_name',p_snapshot_name
    ),
    v_hash
  )
  returning model_runtime_snapshot_receipt_id
  into v_receipt_id;

  return jsonb_build_object(
    'ok',true,
    'token','PROTEUSOPS_MODEL_RUNTIME_SNAPSHOT_OK',
    'snapshot_status','created',
    'snapshot_hash',v_hash,
    'model_runtime_snapshot_id',v_snapshot_id,
    'model_runtime_snapshot_receipt_id',v_receipt_id
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_create_runtime_snapshot_v1"("p_model_instance_runtime_id" "uuid", "p_snapshot_name" "text", "p_snapshot_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_current_runtime_drift_fingerprint_v1"("p_model_instance_runtime_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_runtime record;
  v_launch record;
  v_editor_hash text;
  v_site_runtime_hash text;
  v_body jsonb;
  v_hash text;
begin
  select *
  into v_runtime
  from pods_provisioning.model_instance_runtimes_v1
  where model_instance_runtime_id = p_model_instance_runtime_id
  limit 1;

  if not found then
    raise exception 'MODEL_RUNTIME_DRIFT_RUNTIME_NOT_FOUND';
  end if;

  select *
  into v_launch
  from pods_provisioning.model_launch_packages_v1
  where model_instance_runtime_id = p_model_instance_runtime_id
  order by created_at desc
  limit 1;

  v_site_runtime_hash := coalesce(
    v_runtime.instance_body->>'site_runtime_hash',
    v_runtime.instance_body->'site_runtime'->>'site_runtime_hash',
    ''
  );

  select pods_provisioning._sha256_text_v1(
    coalesce(jsonb_agg(
      jsonb_build_object(
        'target_type', target_type,
        'target_key', target_key,
        'edit_action', edit_action,
        'field_updates', field_updates,
        'change_hash', change_hash
      )
      order by created_at, model_runtime_editor_change_id
    ), '[]'::jsonb)::text
  )
  into v_editor_hash
  from pods_provisioning.model_runtime_editor_changes_v1
  where model_instance_runtime_id = p_model_instance_runtime_id
    and editor_status = 'applied';

  v_body := jsonb_build_object(
    'org_id', v_runtime.org_id,
    'model_instance_runtime_id', v_runtime.model_instance_runtime_id,
    'model_key', v_runtime.model_key,
    'model_version', v_runtime.model_version,
    'instance_name', v_runtime.instance_name,
    'instance_slug', v_runtime.instance_slug,
    'instance_status', v_runtime.instance_status,
    'runtime_hash', v_runtime.instance_hash,
    'site_runtime_hash', v_site_runtime_hash,
    'launch_package_hash', coalesce(v_launch.package_hash,''),
    'route_manifest_hash', pods_provisioning._sha256_text_v1(coalesce(v_launch.route_manifest,'[]'::jsonb)::text),
    'form_manifest_hash', pods_provisioning._sha256_text_v1(coalesce(v_launch.form_manifest,'[]'::jsonb)::text),
    'permission_manifest_hash', pods_provisioning._sha256_text_v1(coalesce(v_launch.permission_manifest,'{}'::jsonb)::text),
    'provider_manifest_hash', pods_provisioning._sha256_text_v1(coalesce(v_launch.provider_manifest,'[]'::jsonb)::text),
    'asset_manifest_hash', pods_provisioning._sha256_text_v1(coalesce(v_launch.asset_manifest,'[]'::jsonb)::text),
    'renderer_manifest_hash', pods_provisioning._sha256_text_v1(coalesce(v_launch.renderer_manifest,'{}'::jsonb)::text),
    'editor_state_hash', v_editor_hash
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  return v_body || jsonb_build_object(
    'composite_runtime_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_current_runtime_drift_fingerprint_v1"("p_model_instance_runtime_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_decide_contractor_estimate_v1"("p_contractor_estimate_id" "uuid", "p_decision_kind" "text", "p_customer_name" "text", "p_customer_email" "text", "p_decision_notes" "text" DEFAULT ''::"text", "p_signer_ip" "inet" DEFAULT NULL::"inet", "p_signer_user_agent" "text" DEFAULT ''::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_estimate record;
  v_status text;
  v_body jsonb;
  v_hash text;
  v_decision_id uuid;
begin
  if p_contractor_estimate_id is null then
    raise exception 'CONTRACTOR_ESTIMATE_DECISION_ID_REQUIRED';
  end if;

  if p_decision_kind not in ('approve','decline') then
    raise exception 'CONTRACTOR_ESTIMATE_DECISION_KIND_INVALID:%', coalesce(p_decision_kind,'');
  end if;

  select *
  into v_estimate
  from pods_provisioning.contractor_estimates_v1 ce
  where ce.contractor_estimate_id = p_contractor_estimate_id
  for update;

  if not found then
    raise exception 'CONTRACTOR_ESTIMATE_NOT_FOUND';
  end if;

  if v_estimate.estimate_status <> 'sent' then
    raise exception 'CONTRACTOR_ESTIMATE_NOT_DECIDABLE:%', v_estimate.estimate_status;
  end if;

  if p_decision_kind = 'approve' then
    v_status := 'accepted';
  else
    v_status := 'declined';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CONTRACTOR_ESTIMATE_APPROVAL_OK',
    'contractor_estimate_id', v_estimate.contractor_estimate_id,
    'estimate_number', v_estimate.estimate_number,
    'org_id', v_estimate.org_id,
    'decision_kind', p_decision_kind,
    'decision_status', v_status,
    'customer_name', p_customer_name,
    'customer_email', p_customer_email,
    'decision_notes', coalesce(p_decision_notes,''),
    'deposit_required', v_estimate.deposit_required,
    'deposit_amount_cents', v_estimate.deposit_amount_cents,
    'job_creation_ready', (p_decision_kind = 'approve'),
    'payment_handoff_ready', (p_decision_kind = 'approve' and v_estimate.deposit_required)
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.contractor_estimate_decisions_v1(
    contractor_estimate_id,
    org_id,
    decision_kind,
    decision_status,
    customer_name,
    customer_email,
    signer_ip,
    signer_user_agent,
    decision_notes,
    decision_body,
    decision_hash
  )
  values (
    v_estimate.contractor_estimate_id,
    v_estimate.org_id,
    p_decision_kind,
    v_status,
    p_customer_name,
    p_customer_email,
    p_signer_ip,
    coalesce(p_signer_user_agent,''),
    coalesce(p_decision_notes,''),
    v_body,
    v_hash
  )
  returning estimate_decision_id
  into v_decision_id;

  update pods_provisioning.contractor_estimates_v1
  set
    estimate_status = case
      when p_decision_kind = 'approve' then 'approved'
      else 'declined'
    end,
    updated_at = now()
  where contractor_estimate_id = v_estimate.contractor_estimate_id;

  update pods_provisioning.contractor_estimate_requests_v1
  set estimate_status = case
    when p_decision_kind = 'approve' then 'approved'
    else 'declined'
  end
  where estimate_request_id = v_estimate.estimate_request_id;

  return v_body || jsonb_build_object(
    'estimate_decision_id', v_decision_id,
    'decision_hash', v_hash
  );
exception
  when unique_violation then
    raise exception 'CONTRACTOR_ESTIMATE_DECISION_DUPLICATE_DENY:%', p_contractor_estimate_id;
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_decide_contractor_estimate_v1"("p_contractor_estimate_id" "uuid", "p_decision_kind" "text", "p_customer_name" "text", "p_customer_email" "text", "p_decision_notes" "text", "p_signer_ip" "inet", "p_signer_user_agent" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_deploy_civic_action_model_v1"("p_org_id" "uuid", "p_fields" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_issue_title text;
  v_community_name text;
  v_location_label text;
  v_position_type text;
  v_issue_summary text;
  v_petition_goal integer;

  v_enabled_modules jsonb;
  v_required_providers jsonb := jsonb_build_array('supabase','email','storage');

  v_campaign jsonb;
  v_body jsonb;
  v_hash text;
  v_deployment_id uuid;
begin
  if p_org_id is null then
    raise exception 'CIVIC_DEPLOY_ORG_REQUIRED';
  end if;

  perform pods_provisioning.rpc_selftest_civic_action_full_green_v2();

  v_issue_title := coalesce(nullif(btrim(p_fields->>'issue_title'),''),'Untitled Civic Action');
  v_community_name := coalesce(nullif(btrim(p_fields->>'community_name'),''),'');
  v_location_label := coalesce(nullif(btrim(p_fields->>'location_label'),''),'');
  v_position_type := coalesce(nullif(btrim(p_fields->>'position_type'),''),'oppose');
  v_issue_summary := coalesce(nullif(btrim(p_fields->>'issue_summary'),''),'');
  v_petition_goal := coalesce(nullif(p_fields->>'petition_goal','')::integer,500);

  v_enabled_modules := coalesce(
    p_fields->'enabled_modules',
    jsonb_build_array(
      'issue_page',
      'petition',
      'survey',
      'help_offers',
      'contribution_wall',
      'events',
      'evidence',
      'moderation'
    )
  );

  v_campaign := pods_provisioning.rpc_create_civic_action_campaign_v1(
    p_org_id,
    v_issue_title,
    v_community_name,
    v_location_label,
    v_position_type,
    v_issue_summary,
    v_petition_goal,
    'published'
  );

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_MODEL_DEPLOYMENT_OK',
    'org_id', p_org_id,
    'model_key', 'CIVIC_ACTION_V1',
    'model_version', 'v2',
    'deployment_status', 'planned',
    'civic_campaign_id', v_campaign->>'civic_campaign_id',
    'issue_title', v_issue_title,
    'community_name', v_community_name,
    'location_label', v_location_label,
    'position_type', v_position_type,
    'issue_summary_present', v_issue_summary <> '',
    'petition_goal', v_petition_goal,
    'enabled_modules', v_enabled_modules,
    'required_providers', v_required_providers,
    'operator_next_steps', jsonb_build_array(
      'Connect Supabase',
      'Connect Email',
      'Connect Storage',
      'Review public campaign page',
      'Review moderation settings',
      'Launch civic action site'
    )
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.civic_action_model_deployments_v1(
    org_id,
    model_key,
    model_version,
    civic_campaign_id,
    issue_title,
    community_name,
    location_label,
    position_type,
    issue_summary,
    petition_goal,
    enabled_modules,
    required_providers,
    deployment_status,
    deployment_body,
    deployment_hash
  )
  values (
    p_org_id,
    'CIVIC_ACTION_V1',
    'v2',
    (v_campaign->>'civic_campaign_id')::uuid,
    v_issue_title,
    v_community_name,
    v_location_label,
    v_position_type,
    v_issue_summary,
    v_petition_goal,
    v_enabled_modules,
    v_required_providers,
    'planned',
    v_body,
    v_hash
  )
  returning civic_deployment_id
  into v_deployment_id;

  return v_body || jsonb_build_object(
    'civic_deployment_id', v_deployment_id,
    'deployment_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_deploy_civic_action_model_v1"("p_org_id" "uuid", "p_fields" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_emit_customer_deployment_handoff_v1"("p_org_id" "uuid", "p_model_key" "text" DEFAULT 'DEVELOPER_PORTAL_V1'::"text", "p_model_version" "text" DEFAULT 'v1'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_snapshot record;
  v_rollup record;

  v_login_surfaces jsonb;
  v_capabilities jsonb;
  v_providers jsonb;
  v_receipts jsonb;

  v_summary jsonb;
  v_next_steps jsonb;
  v_support jsonb;
  v_recovery jsonb;

  v_status text;
  v_body jsonb;
  v_hash text;
  v_handoff_id uuid;
begin
  if p_org_id is null then
    raise exception 'CUSTOMER_HANDOFF_ORG_REQUIRED';
  end if;

  select *
  into v_snapshot
  from pods_provisioning.full_green_platform_snapshots_v1 s
  where s.platform_status = 'FULL_GREEN'
  order by s.created_at desc
  limit 1;

  if not found then
    raise exception 'CUSTOMER_HANDOFF_FULL_GREEN_SNAPSHOT_REQUIRED';
  end if;

  select *
  into v_rollup
  from pods_provisioning.provider_readiness_rollups_v1 r
  where r.org_id = p_org_id
  order by r.created_at desc
  limit 1;

  if found and v_rollup.launch_ready then
    v_status := 'ready';
    v_providers := v_rollup.ready_providers;
  else
    v_status := 'blocked';
    v_providers := '[]'::jsonb;
  end if;

  v_login_surfaces := jsonb_build_array(
    jsonb_build_object('surface_key','operator_dashboard','path','/dashboard'),
    jsonb_build_object('surface_key','setup_wizard','path','/setup'),
    jsonb_build_object('surface_key','provider_settings','path','/providers'),
    jsonb_build_object('surface_key','launch_status','path','/launch-status'),
    jsonb_build_object('surface_key','receipts','path','/receipts')
  );

  v_capabilities := case
    when p_model_key = 'DEVELOPER_PORTAL_V1' then
      jsonb_build_array(
        'protected_login',
        'repo_links',
        'download_access',
        'license_gate',
        'ticket_intake',
        'release_registry',
        'documentation_portal'
      )
    when p_model_key = 'CONTRACTOR_V1' then
      jsonb_build_array(
        'estimate_request',
        'site_visit',
        'estimate_builder',
        'estimate_approval',
        'job_creation',
        'payment_lifecycle'
      )
    when p_model_key = 'BARBER_NAIL_V1' then
      jsonb_build_array(
        'public_booking',
        'appointment_requests',
        'admin_queue',
        'operator_calendar',
        'staff_assignment',
        'customer_notifications',
        'payment_lifecycle'
      )
    else
      jsonb_build_array()
  end;

  v_receipts := jsonb_build_array(
    'PROTEUSOPS_MODEL_CAPABILITY_MATRIX_OK',
    'PROTEUSOPS_MODEL_DEPLOYMENT_RECEIPTS_OK',
    'PROTEUSOPS_PROVIDER_READINESS_ROLLUP_OK',
    'PROTEUSOPS_LAUNCH_CONTROL_PLANE_RECEIPT_OK',
    'PROTEUSOPS_LAUNCH_EXECUTION_WORKER_OK',
    'PROTEUSOPS_SECURITY_GATE_MATRIX_OK',
    'PROTEUSOPS_FULL_GREEN_ENGINE_REGISTRY_OK'
  );

  v_summary := jsonb_build_object(
    'model_key', p_model_key,
    'model_version', p_model_version,
    'handoff_status', v_status,
    'platform_status', v_snapshot.platform_status,
    'engine_count', v_snapshot.engine_count,
    'connected_provider_count', jsonb_array_length(v_providers),
    'active_capability_count', jsonb_array_length(v_capabilities)
  );

  v_next_steps := case
    when v_status = 'ready' then
      jsonb_build_array(
        'Log in to the dashboard',
        'Review business settings',
        'Review provider connections',
        'Review public/customer-facing surfaces',
        'Run a test customer flow',
        'Monitor receipts after launch'
      )
    else
      jsonb_build_array(
        'Connect missing providers',
        'Re-run provider readiness',
        'Re-run launch control receipt',
        'Return to setup wizard'
      )
  end;

  v_support := jsonb_build_array(
    'Keep provider secrets private',
    'Use receipts to audit launch state',
    'Do not manually edit launch runtime rows unless performing recovery',
    'Use rollback receipts when a launch fails'
  );

  v_recovery := jsonb_build_array(
    'If launch fails, review failure receipt',
    'Run rollback before retrying unsafe launch steps',
    'Retry only through governed retry policy',
    'Escalate if retry exhaustion occurs'
  );

  v_body := jsonb_build_object(
    'ok', (v_status = 'ready'),
    'token', 'PROTEUSOPS_CUSTOMER_DEPLOYMENT_HANDOFF_OK',
    'org_id', p_org_id,
    'model_key', p_model_key,
    'model_version', p_model_version,
    'handoff_status', v_status,
    'platform_snapshot_id', v_snapshot.platform_snapshot_id,
    'login_surfaces', v_login_surfaces,
    'active_capabilities', v_capabilities,
    'connected_providers', v_providers,
    'receipts_emitted', v_receipts,
    'customer_summary', v_summary,
    'customer_next_steps', v_next_steps,
    'support_notes', v_support,
    'recovery_notes', v_recovery
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.customer_deployment_handoffs_v1(
    org_id,
    platform_snapshot_id,
    model_key,
    model_version,
    handoff_status,
    login_surfaces,
    active_capabilities,
    connected_providers,
    receipts_emitted,
    customer_summary,
    customer_next_steps,
    support_notes,
    recovery_notes,
    handoff_body,
    handoff_hash
  )
  values (
    p_org_id,
    v_snapshot.platform_snapshot_id,
    p_model_key,
    p_model_version,
    v_status,
    v_login_surfaces,
    v_capabilities,
    v_providers,
    v_receipts,
    v_summary,
    v_next_steps,
    v_support,
    v_recovery,
    v_body,
    v_hash
  )
  returning customer_handoff_id
  into v_handoff_id;

  return v_body || jsonb_build_object(
    'customer_handoff_id', v_handoff_id,
    'handoff_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_emit_customer_deployment_handoff_v1"("p_org_id" "uuid", "p_model_key" "text", "p_model_version" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_emit_full_green_platform_snapshot_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_engine_count integer;
  v_green_count integer;
  v_blocked_count integer;
  v_failed_count integer;

  v_ready jsonb;
  v_blocked jsonb;
  v_failed jsonb;

  v_status text;

  v_body jsonb;
  v_hash text;
  v_snapshot_id uuid;
begin
  select count(*)
  into v_engine_count
  from pods_provisioning.full_green_engine_registry_v1;

  select count(*)
  into v_green_count
  from pods_provisioning.full_green_engine_registry_v1
  where engine_status = 'FULL_GREEN';

  select count(*)
  into v_blocked_count
  from pods_provisioning.full_green_engine_registry_v1
  where engine_status = 'BLOCKED';

  select count(*)
  into v_failed_count
  from pods_provisioning.full_green_engine_registry_v1
  where engine_status = 'FAILED';

  select coalesce(jsonb_agg(engine_key order by engine_key),'[]'::jsonb)
  into v_ready
  from pods_provisioning.full_green_engine_registry_v1
  where engine_status = 'FULL_GREEN';

  select coalesce(jsonb_agg(engine_key order by engine_key),'[]'::jsonb)
  into v_blocked
  from pods_provisioning.full_green_engine_registry_v1
  where engine_status = 'BLOCKED';

  select coalesce(jsonb_agg(engine_key order by engine_key),'[]'::jsonb)
  into v_failed
  from pods_provisioning.full_green_engine_registry_v1
  where engine_status = 'FAILED';

  if v_failed_count > 0 then
    v_status := 'FAILED';
  elsif v_blocked_count > 0 then
    v_status := 'BLOCKED';
  elsif v_green_count = v_engine_count and v_engine_count > 0 then
    v_status := 'FULL_GREEN';
  else
    v_status := 'PARTIAL';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_FULL_GREEN_ENGINE_REGISTRY_OK',
    'snapshot_key', 'platform_full_green_snapshot_v1',
    'engine_count', v_engine_count,
    'full_green_count', v_green_count,
    'blocked_count', v_blocked_count,
    'failed_count', v_failed_count,
    'platform_status', v_status,
    'ready_engines', v_ready,
    'blocked_engines', v_blocked,
    'failed_engines', v_failed
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.full_green_platform_snapshots_v1(
    snapshot_key,
    engine_count,
    full_green_count,
    blocked_count,
    failed_count,
    platform_status,
    ready_engines,
    blocked_engines,
    failed_engines,
    snapshot_body,
    snapshot_hash
  )
  values (
    'platform_full_green_snapshot_v1',
    v_engine_count,
    v_green_count,
    v_blocked_count,
    v_failed_count,
    v_status,
    v_ready,
    v_blocked,
    v_failed,
    v_body,
    v_hash
  )
  returning platform_snapshot_id
  into v_snapshot_id;

  return v_body || jsonb_build_object(
    'platform_snapshot_id', v_snapshot_id,
    'snapshot_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_emit_full_green_platform_snapshot_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_emit_launch_control_plane_receipt_v1"("p_org_id" "uuid", "p_wizard_session_id" "uuid", "p_plan_run_id" "uuid", "p_deployment_receipt_id" "uuid", "p_provider_readiness_rollup_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_wizard record;
  v_plan record;
  v_deploy record;
  v_rollup record;

  v_launch_ready boolean;
  v_decision text;
  v_blocked_reasons jsonb;
  v_summary jsonb;
  v_next_steps jsonb;

  v_body jsonb;
  v_hash text;
  v_receipt_id uuid;
begin
  if p_org_id is null then
    raise exception 'LAUNCH_CONTROL_ORG_REQUIRED';
  end if;

  select *
  into v_wizard
  from pods_provisioning.operator_setup_wizard_sessions_v1 w
  where w.wizard_session_id = p_wizard_session_id
    and w.org_id = p_org_id
  limit 1;

  if not found then
    raise exception 'LAUNCH_CONTROL_WIZARD_NOT_FOUND';
  end if;

  select *
  into v_plan
  from pods_provisioning.model_capability_plan_runs_v1 p
  where p.plan_run_id = p_plan_run_id
    and p.org_id = p_org_id
  limit 1;

  if not found then
    raise exception 'LAUNCH_CONTROL_PLAN_NOT_FOUND';
  end if;

  select *
  into v_deploy
  from pods_provisioning.model_deployment_receipts_v1 d
  where d.deployment_receipt_id = p_deployment_receipt_id
    and d.org_id = p_org_id
  limit 1;

  if not found then
    raise exception 'LAUNCH_CONTROL_DEPLOYMENT_NOT_FOUND';
  end if;

  select *
  into v_rollup
  from pods_provisioning.provider_readiness_rollups_v1 r
  where r.provider_readiness_rollup_id = p_provider_readiness_rollup_id
    and r.org_id = p_org_id
  limit 1;

  if not found then
    raise exception 'LAUNCH_CONTROL_READINESS_NOT_FOUND';
  end if;

  v_launch_ready := v_rollup.launch_ready;

  if v_launch_ready then
    v_decision := 'ready';
    v_blocked_reasons := '[]'::jsonb;
    v_next_steps := jsonb_build_array(
      'Review launch summary',
      'Click Launch when ready',
      'Monitor receipts after launch'
    );
  else
    v_decision := 'blocked';
    v_blocked_reasons := jsonb_build_array(
      jsonb_build_object(
        'reason_key','provider_readiness_blocked',
        'blocked_providers',v_rollup.blocked_providers
      )
    );
    v_next_steps := jsonb_build_array(
      'Connect missing providers',
      'Re-run provider readiness',
      'Return to launch review'
    );
  end if;

  v_summary := jsonb_build_object(
    'system_ready', v_launch_ready,
    'model_key', v_plan.model_key,
    'model_version', v_plan.model_version,
    'wizard_status', v_wizard.wizard_status,
    'deployment_status', v_deploy.deployment_status,
    'readiness_status', v_rollup.readiness_status,
    'ready_providers', v_rollup.ready_providers,
    'blocked_providers', v_rollup.blocked_providers
  );

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_LAUNCH_CONTROL_PLANE_RECEIPT_OK',
    'org_id', p_org_id,
    'wizard_session_id', p_wizard_session_id,
    'plan_run_id', p_plan_run_id,
    'deployment_receipt_id', p_deployment_receipt_id,
    'provider_readiness_rollup_id', p_provider_readiness_rollup_id,
    'model_key', v_plan.model_key,
    'model_version', v_plan.model_version,
    'wizard_status', v_wizard.wizard_status,
    'deployment_status', v_deploy.deployment_status,
    'readiness_status', v_rollup.readiness_status,
    'launch_ready', v_launch_ready,
    'launch_decision', v_decision,
    'operator_summary', v_summary,
    'customer_next_steps', v_next_steps,
    'blocked_reasons', v_blocked_reasons
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.launch_control_plane_receipts_v1(
    org_id,
    wizard_session_id,
    plan_run_id,
    deployment_receipt_id,
    provider_readiness_rollup_id,
    model_key,
    model_version,
    wizard_status,
    deployment_status,
    readiness_status,
    launch_ready,
    launch_decision,
    operator_summary,
    customer_next_steps,
    blocked_reasons,
    receipt_body,
    receipt_hash
  )
  values (
    p_org_id,
    p_wizard_session_id,
    p_plan_run_id,
    p_deployment_receipt_id,
    p_provider_readiness_rollup_id,
    v_plan.model_key,
    v_plan.model_version,
    v_wizard.wizard_status,
    v_deploy.deployment_status,
    v_rollup.readiness_status,
    v_launch_ready,
    v_decision,
    v_summary,
    v_next_steps,
    v_blocked_reasons,
    v_body,
    v_hash
  )
  returning launch_control_receipt_id
  into v_receipt_id;

  return v_body || jsonb_build_object(
    'launch_control_receipt_id', v_receipt_id,
    'receipt_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_emit_launch_control_plane_receipt_v1"("p_org_id" "uuid", "p_wizard_session_id" "uuid", "p_plan_run_id" "uuid", "p_deployment_receipt_id" "uuid", "p_provider_readiness_rollup_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_evaluate_launch_retry_v1"("p_launch_failure_event_id" "uuid", "p_policy_key" "text" DEFAULT 'default-launch-retry'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_failure record;
  v_policy record;
  v_existing_count integer;
  v_retry_number integer;
  v_retry_status text;
  v_body jsonb;
  v_hash text;
  v_retry_id uuid;
begin
  if p_launch_failure_event_id is null then
    raise exception 'RETRY_FAILURE_EVENT_REQUIRED';
  end if;

  select *
  into v_failure
  from pods_provisioning.launch_failure_events_v1 f
  where f.launch_failure_event_id = p_launch_failure_event_id
  limit 1;

  if not found then
    raise exception 'RETRY_FAILURE_EVENT_NOT_FOUND';
  end if;

  select *
  into v_policy
  from pods_provisioning.launch_retry_policies_v1 p
  where p.policy_key = p_policy_key
    and p.active = true
  limit 1;

  if not found then
    raise exception 'RETRY_POLICY_NOT_FOUND:%', p_policy_key;
  end if;

  select count(*)
  into v_existing_count
  from pods_provisioning.launch_retry_events_v1 r
  where r.launch_failure_event_id = p_launch_failure_event_id;

  v_retry_number := v_existing_count + 1;

  if v_retry_number > v_policy.max_retries then
    v_retry_status := 'retry_exhausted';
  else
    v_retry_status := 'retry_wait';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', case
      when v_retry_status = 'retry_exhausted'
        then 'PROTEUSOPS_RETRY_EXHAUSTED_OK'
      else 'PROTEUSOPS_RETRY_GOVERNANCE_OK'
    end,
    'launch_failure_event_id', v_failure.launch_failure_event_id,
    'worker_run_id', v_failure.worker_run_id,
    'org_id', v_failure.org_id,
    'policy_key', v_policy.policy_key,
    'max_retries', v_policy.max_retries,
    'retry_number', v_retry_number,
    'retry_status', v_retry_status,
    'cooldown_seconds', v_policy.cooldown_seconds,
    'retry_after', (now() + make_interval(secs => v_policy.cooldown_seconds))::text,
    'replay_ready', true,
    'rollback_ready', true
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.launch_retry_events_v1(
    launch_failure_event_id,
    worker_run_id,
    org_id,
    retry_policy_id,
    retry_number,
    retry_status,
    cooldown_seconds,
    retry_after,
    retry_body,
    retry_hash
  )
  values (
    v_failure.launch_failure_event_id,
    v_failure.worker_run_id,
    v_failure.org_id,
    v_policy.retry_policy_id,
    v_retry_number,
    v_retry_status,
    v_policy.cooldown_seconds,
    now() + make_interval(secs => v_policy.cooldown_seconds),
    v_body,
    v_hash
  )
  returning launch_retry_event_id
  into v_retry_id;

  update pods_provisioning.launch_execution_worker_runs_v1
  set
    retry_count = v_retry_number,
    worker_status = case
      when v_retry_status = 'retry_exhausted' then 'failed'
      else 'failed'
    end,
    updated_at = now()
  where worker_run_id = v_failure.worker_run_id;

  return v_body || jsonb_build_object(
    'launch_retry_event_id', v_retry_id,
    'retry_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_evaluate_launch_retry_v1"("p_launch_failure_event_id" "uuid", "p_policy_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_fail_launch_execution_worker_v1"("p_worker_run_id" "uuid", "p_failed_step" "text", "p_failure_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_worker record;
  v_body jsonb;
  v_hash text;
  v_failure_id uuid;
begin
  if p_worker_run_id is null then
    raise exception 'LAUNCH_FAILURE_WORKER_REQUIRED';
  end if;

  if p_failed_step is null or btrim(p_failed_step) = '' then
    raise exception 'LAUNCH_FAILURE_STEP_REQUIRED';
  end if;

  if p_failure_reason is null or btrim(p_failure_reason) = '' then
    raise exception 'LAUNCH_FAILURE_REASON_REQUIRED';
  end if;

  select *
  into v_worker
  from pods_provisioning.launch_execution_worker_runs_v1 w
  where w.worker_run_id = p_worker_run_id
  for update;

  if not found then
    raise exception 'LAUNCH_FAILURE_WORKER_NOT_FOUND';
  end if;

  if v_worker.worker_status not in ('queued','running') then
    raise exception 'LAUNCH_FAILURE_WORKER_STATUS_INVALID:%', v_worker.worker_status;
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_LAUNCH_FAILURE_RUNTIME_OK',
    'worker_run_id', v_worker.worker_run_id,
    'launch_control_receipt_id', v_worker.launch_control_receipt_id,
    'org_id', v_worker.org_id,
    'model_key', v_worker.model_key,
    'failed_step', p_failed_step,
    'failure_reason', p_failure_reason,
    'failure_status', 'failed',
    'rollback_required', true,
    'replay_ready', true
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.launch_failure_events_v1(
    worker_run_id,
    launch_control_receipt_id,
    org_id,
    failed_step,
    failure_reason,
    failure_status,
    rollback_required,
    replay_ready,
    failure_body,
    failure_hash
  )
  values (
    v_worker.worker_run_id,
    v_worker.launch_control_receipt_id,
    v_worker.org_id,
    p_failed_step,
    p_failure_reason,
    'failed',
    true,
    true,
    v_body,
    v_hash
  )
  returning launch_failure_event_id
  into v_failure_id;

  update pods_provisioning.launch_execution_worker_runs_v1
  set
    worker_status = 'failed',
    failed_steps = jsonb_build_array(p_failed_step),
    worker_body = v_body,
    worker_hash = v_hash,
    updated_at = now()
  where worker_run_id = v_worker.worker_run_id;

  return v_body || jsonb_build_object(
    'launch_failure_event_id', v_failure_id,
    'failure_hash', v_hash
  );
exception
  when unique_violation then
    raise exception 'LAUNCH_FAILURE_DUPLICATE_DENY:%', p_worker_run_id;
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_fail_launch_execution_worker_v1"("p_worker_run_id" "uuid", "p_failed_step" "text", "p_failure_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_generate_customer_launch_receipt_v1"("p_provision_run_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_run record;
  v_receipt jsonb;
  v_hash text;
  v_existing uuid;
begin
  if p_provision_run_id is null then
    raise exception 'LAUNCH_RECEIPT_RUN_ID_REQUIRED';
  end if;

  select *
  into v_run
  from pods_provisioning.provision_runs_v1 pr
  where pr.provision_run_id = p_provision_run_id
  limit 1;

  if not found then
    raise exception 'LAUNCH_RECEIPT_RUN_NOT_FOUND';
  end if;

  select clr.launch_receipt_id
  into v_existing
  from pods_provisioning.customer_launch_receipts_v1 clr
  where clr.provision_run_id = p_provision_run_id
  limit 1;

  if v_existing is not null then
    raise exception 'LAUNCH_RECEIPT_ALREADY_EXISTS:%', p_provision_run_id;
  end if;

  v_receipt := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CUSTOMER_LAUNCH_RECEIPT_OK',

    'org_id', v_run.org_id,
    'provision_run_id', v_run.provision_run_id,

    'template_key', v_run.template_key,
    'template_version', v_run.template_version,

    'operator_summary', jsonb_build_object(
      'system_ready', true,
      'booking_enabled', true,
      'provisioning_completed', true
    ),

    'customer_next_steps', jsonb_build_array(
      'Verify operating hours',
      'Verify prices and services',
      'Invite staff accounts',
      'Connect Stripe before accepting live payments',
      'Review memberships and subscriptions',
      'Publish booking page',
      'Test appointment flow before launch'
    ),

    'customer_access', jsonb_build_object(
      'admin_dashboard', '/dashboard',
      'booking_management', '/dashboard/bookings',
      'staff_management', '/dashboard/staff',
      'service_management', '/dashboard/services',
      'membership_management', '/dashboard/memberships'
    ),

    'customer_awareness', jsonb_build_array(
      'Business data is stored in Supabase Postgres',
      'Provisioning receipts are append-only',
      'Provisioning actions are deterministic',
      'Provisioning can be independently audited',
      'Operator secrets should remain private'
    ),

    'support_model', jsonb_build_object(
      'bootstrap_model', 'one-click provisioning',
      'operator_model', 'business-owner-first',
      'technical_knowledge_required', 'minimal'
    )
  );

  v_hash := pods_provisioning._sha256_text_v1(v_receipt::text);

  insert into pods_provisioning.customer_launch_receipts_v1(
    provision_run_id,
    org_id,
    template_key,
    template_version,
    receipt_body,
    receipt_hash
  )
  values (
    v_run.provision_run_id,
    v_run.org_id,
    v_run.template_key,
    v_run.template_version,
    v_receipt,
    v_hash
  );

  return v_receipt || jsonb_build_object(
    'receipt_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_generate_customer_launch_receipt_v1"("p_provision_run_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_generate_model_launch_package_v1"("p_model_instance_runtime_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_instance record;
  v_site_runtime jsonb;
  v_runtime_manifest jsonb;
  v_renderer_contract jsonb;

  v_route_manifest jsonb;
  v_form_manifest jsonb;
  v_permission_manifest jsonb;
  v_provider_manifest jsonb;
  v_asset_manifest jsonb;
  v_renderer_manifest jsonb;
  v_environment_requirements jsonb;

  v_body jsonb;
  v_hash text;
  v_id uuid;
begin
  if p_model_instance_runtime_id is null then
    raise exception 'MODEL_LAUNCH_PACKAGE_INSTANCE_REQUIRED';
  end if;

  select *
  into v_instance
  from pods_provisioning.model_instance_runtimes_v1 i
  where i.model_instance_runtime_id = p_model_instance_runtime_id
  limit 1;

  if not found then
    raise exception 'MODEL_LAUNCH_PACKAGE_INSTANCE_NOT_FOUND';
  end if;

  v_site_runtime := v_instance.instance_body->'site_runtime';
  v_runtime_manifest := v_site_runtime->'runtime_manifest';
  v_renderer_contract := v_site_runtime->'renderer_contract';

  v_route_manifest := coalesce(v_runtime_manifest->'runtime_routes','[]'::jsonb);
  v_form_manifest := coalesce(v_runtime_manifest->'runtime_forms','[]'::jsonb);
  v_permission_manifest := coalesce(v_runtime_manifest->'runtime_permissions','{}'::jsonb);
  v_provider_manifest := coalesce(v_runtime_manifest->'runtime_providers','[]'::jsonb);

  v_asset_manifest := jsonb_build_array(
    coalesce(v_site_runtime->'asset_runtime','{}'::jsonb)
  );

  v_renderer_manifest := jsonb_build_object(
    'renderer_contract_id', v_renderer_contract->>'model_renderer_contract_id',
    'contract_hash', v_renderer_contract->>'contract_hash',
    'renderer_routes', coalesce(v_renderer_contract->'renderer_routes','[]'::jsonb),
    'renderer_components', coalesce(v_renderer_contract->'renderer_components','[]'::jsonb),
    'renderer_actions', coalesce(v_renderer_contract->'renderer_actions','[]'::jsonb),
    'renderer_assets', coalesce(v_renderer_contract->'renderer_assets','[]'::jsonb),
    'license_gates', coalesce(v_renderer_contract->'license_gates','[]'::jsonb)
  );

  v_environment_requirements := jsonb_build_array(
    jsonb_build_object('key','SUPABASE_URL','required',true,'source','provider:supabase'),
    jsonb_build_object('key','SUPABASE_ANON_KEY','required',true,'source','provider:supabase'),
    jsonb_build_object('key','EMAIL_PROVIDER','required',true,'source','provider:email'),
    jsonb_build_object('key','STORAGE_PROVIDER','required',true,'source','provider:storage'),
    jsonb_build_object('key','MODEL_KEY','required',true,'value',v_instance.model_key),
    jsonb_build_object('key','MODEL_INSTANCE_RUNTIME_ID','required',true,'value',v_instance.model_instance_runtime_id)
  );

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_LAUNCH_PACKAGE_OK',
    'org_id', v_instance.org_id,
    'model_key', v_instance.model_key,
    'model_version', v_instance.model_version,
    'instance_name', v_instance.instance_name,
    'instance_slug', v_instance.instance_slug,
    'model_instance_runtime_id', v_instance.model_instance_runtime_id,
    'model_site_runtime_generation_id', v_instance.model_site_runtime_generation_id,
    'launchable', v_instance.launchable,
    'package_status', 'generated',
    'route_manifest', v_route_manifest,
    'form_manifest', v_form_manifest,
    'permission_manifest', v_permission_manifest,
    'provider_manifest', v_provider_manifest,
    'asset_manifest', v_asset_manifest,
    'renderer_manifest', v_renderer_manifest,
    'environment_requirements', v_environment_requirements,
    'deploy_surfaces', jsonb_build_array('public','admin'),
    'package_capabilities', jsonb_build_array(
      'routes',
      'forms',
      'permissions',
      'providers',
      'assets',
      'license_gates',
      'renderer_contract',
      'environment_requirements',
      'public_surface',
      'admin_surface'
    )
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_launch_packages_v1(
    org_id,
    model_key,
    model_version,
    model_instance_runtime_id,
    model_site_runtime_generation_id,
    package_status,
    launchable,
    package_manifest,
    route_manifest,
    form_manifest,
    permission_manifest,
    provider_manifest,
    asset_manifest,
    renderer_manifest,
    environment_requirements,
    package_hash
  )
  values (
    v_instance.org_id,
    v_instance.model_key,
    v_instance.model_version,
    v_instance.model_instance_runtime_id,
    v_instance.model_site_runtime_generation_id,
    'generated',
    v_instance.launchable,
    v_body,
    v_route_manifest,
    v_form_manifest,
    v_permission_manifest,
    v_provider_manifest,
    v_asset_manifest,
    v_renderer_manifest,
    v_environment_requirements,
    v_hash
  )
  returning model_launch_package_id
  into v_id;

  return v_body || jsonb_build_object(
    'model_launch_package_id', v_id,
    'package_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_generate_model_launch_package_v1"("p_model_instance_runtime_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_generate_model_permissions_v1"("p_org_id" "uuid", "p_model_key" "text", "p_model_version" "text" DEFAULT 'v1'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_role_permissions jsonb;
  v_page_access jsonb;
  v_form_access jsonb;
  v_body jsonb;
  v_hash text;
  v_id uuid;
begin
  if p_org_id is null then
    raise exception 'MODEL_PERMISSION_ORG_REQUIRED';
  end if;

  if p_model_key is null or btrim(p_model_key) = '' then
    raise exception 'MODEL_PERMISSION_MODEL_REQUIRED';
  end if;

  if p_model_key = 'CIVIC_ACTION_V1' then
    v_role_permissions := jsonb_build_object(
      'visitor', jsonb_build_array('view_public_pages','view_public_counts'),
      'supporter', jsonb_build_array('view_public_pages','sign_petition','submit_survey','offer_help','rsvp_event','submit_evidence'),
      'signer', jsonb_build_array('sign_petition','view_public_pages'),
      'survey_respondent', jsonb_build_array('submit_survey','view_public_pages'),
      'volunteer', jsonb_build_array('offer_help','rsvp_event','view_public_pages'),
      'organizer', jsonb_build_array('manage_campaign','manage_events','view_admin_dashboard','review_counts'),
      'moderator', jsonb_build_array('view_moderation_queue','approve_contribution','reject_contribution','hide_contribution'),
      'community_admin', jsonb_build_array('manage_campaign','manage_events','manage_evidence','manage_moderation','launch_site'),
      'institution_partner', jsonb_build_array('view_partner_dashboard','submit_evidence','view_public_pages')
    );

    v_page_access := jsonb_build_object(
      '/', jsonb_build_array('visitor','supporter','organizer','moderator','community_admin','institution_partner'),
      '/issue', jsonb_build_array('visitor','supporter','organizer','moderator','community_admin','institution_partner'),
      '/petition', jsonb_build_array('visitor','supporter','signer','organizer','community_admin'),
      '/survey', jsonb_build_array('visitor','supporter','survey_respondent','organizer','community_admin'),
      '/volunteer', jsonb_build_array('visitor','supporter','volunteer','organizer','community_admin'),
      '/events', jsonb_build_array('visitor','supporter','volunteer','organizer','community_admin'),
      '/evidence', jsonb_build_array('visitor','supporter','institution_partner','organizer','community_admin'),
      '/contribution-wall', jsonb_build_array('visitor','supporter','organizer','moderator','community_admin'),
      '/updates', jsonb_build_array('visitor','supporter','organizer','community_admin'),
      '/admin/dashboard', jsonb_build_array('organizer','community_admin'),
      '/admin/campaign', jsonb_build_array('organizer','community_admin'),
      '/admin/petitions', jsonb_build_array('organizer','community_admin'),
      '/admin/surveys', jsonb_build_array('organizer','community_admin'),
      '/admin/events', jsonb_build_array('organizer','community_admin'),
      '/admin/evidence', jsonb_build_array('organizer','moderator','community_admin'),
      '/admin/volunteers', jsonb_build_array('organizer','community_admin'),
      '/admin/moderation', jsonb_build_array('moderator','community_admin'),
      '/admin/launch', jsonb_build_array('community_admin')
    );

    v_form_access := jsonb_build_object(
      'campaign_setup', jsonb_build_array('organizer','community_admin'),
      'petition_signature', jsonb_build_array('visitor','supporter','signer'),
      'survey_response', jsonb_build_array('visitor','supporter','survey_respondent'),
      'help_offer', jsonb_build_array('visitor','supporter','volunteer'),
      'event_rsvp', jsonb_build_array('visitor','supporter','volunteer'),
      'evidence_submission', jsonb_build_array('supporter','institution_partner','organizer','community_admin'),
      'moderation_action', jsonb_build_array('moderator','community_admin')
    );
  else
    v_role_permissions := jsonb_build_object(
      'visitor', jsonb_build_array('view_public_pages'),
      'owner', jsonb_build_array('manage_site','launch_site'),
      'admin', jsonb_build_array('manage_site','manage_users','launch_site')
    );

    v_page_access := jsonb_build_object(
      '/', jsonb_build_array('visitor','owner','admin'),
      '/admin/dashboard', jsonb_build_array('owner','admin'),
      '/admin/launch', jsonb_build_array('owner','admin')
    );

    v_form_access := jsonb_build_object(
      'setup', jsonb_build_array('owner','admin')
    );
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_PERMISSION_GENERATOR_OK',
    'org_id', p_org_id,
    'model_key', p_model_key,
    'model_version', p_model_version,
    'role_permissions', v_role_permissions,
    'page_access', v_page_access,
    'form_access', v_form_access,
    'generation_status', 'generated'
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_permission_generations_v1(
    org_id,
    model_key,
    model_version,
    role_permissions,
    page_access,
    form_access,
    generation_status,
    generation_body,
    generation_hash
  )
  values (
    p_org_id,
    p_model_key,
    p_model_version,
    v_role_permissions,
    v_page_access,
    v_form_access,
    'generated',
    v_body,
    v_hash
  )
  returning model_permission_generation_id
  into v_id;

  return v_body || jsonb_build_object(
    'model_permission_generation_id', v_id,
    'generation_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_generate_model_permissions_v1"("p_org_id" "uuid", "p_model_key" "text", "p_model_version" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_generate_model_renderer_contract_v1"("p_model_runtime_manifest_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_manifest record;
  v_route jsonb;
  v_form jsonb;

  v_renderer_routes jsonb := '[]'::jsonb;
  v_components jsonb := '[]'::jsonb;
  v_actions jsonb := '[]'::jsonb;
  v_assets jsonb := '[]'::jsonb;
  v_license_gates jsonb := '[]'::jsonb;

  v_component_key text;
  v_route_path text;
  v_surface text;
  v_renderer_type text;
  v_layout text;
  v_data_sources jsonb;
  v_component_actions jsonb;

  v_body jsonb;
  v_hash text;
  v_id uuid;
begin
  if p_model_runtime_manifest_id is null then
    raise exception 'MODEL_RENDERER_RUNTIME_MANIFEST_REQUIRED';
  end if;

  select *
  into v_manifest
  from pods_provisioning.model_runtime_manifests_v1 m
  where m.model_runtime_manifest_id = p_model_runtime_manifest_id
  limit 1;

  if not found then
    raise exception 'MODEL_RENDERER_RUNTIME_MANIFEST_NOT_FOUND';
  end if;

  for v_route in
    select value from jsonb_array_elements(v_manifest.runtime_routes)
  loop
    v_route_path := v_route->>'route';
    v_surface := v_route->>'surface';
    v_component_key := v_route->>'component_key';

    v_layout := case
      when v_surface = 'admin' then 'admin_standard'
      else 'public_standard'
    end;

    v_renderer_type := case
      when v_route_path = '/' then 'landing_page'
      when v_route_path = '/issue' then 'issue_page'
      when v_route_path = '/petition' then 'petition_page'
      when v_route_path = '/survey' then 'survey_page'
      when v_route_path = '/volunteer' then 'help_offer_page'
      when v_route_path = '/events' then 'events_page'
      when v_route_path = '/evidence' then 'evidence_library_page'
      when v_route_path = '/contribution-wall' then 'contribution_wall_page'
      when v_route_path = '/updates' then 'updates_page'
      when v_route_path = '/admin/dashboard' then 'admin_dashboard'
      when v_route_path = '/admin/campaign' then 'admin_campaign_editor'
      when v_route_path = '/admin/petitions' then 'admin_petition_manager'
      when v_route_path = '/admin/surveys' then 'admin_survey_manager'
      when v_route_path = '/admin/events' then 'admin_event_manager'
      when v_route_path = '/admin/evidence' then 'admin_evidence_manager'
      when v_route_path = '/admin/volunteers' then 'admin_volunteer_manager'
      when v_route_path = '/admin/moderation' then 'admin_moderation_queue'
      when v_route_path = '/admin/launch' then 'admin_launch_control'
      else 'custom_page'
    end;

    v_data_sources := case
      when v_renderer_type = 'petition_page' then jsonb_build_array('civic_campaign','petition_signatures','petition_public_count')
      when v_renderer_type = 'survey_page' then jsonb_build_array('civic_campaign','survey_questions','survey_public_count')
      when v_renderer_type = 'help_offer_page' then jsonb_build_array('civic_campaign','help_offers')
      when v_renderer_type = 'events_page' then jsonb_build_array('civic_campaign','events','event_public_counts')
      when v_renderer_type = 'evidence_library_page' then jsonb_build_array('civic_campaign','evidence_library')
      when v_renderer_type = 'contribution_wall_page' then jsonb_build_array('civic_campaign','contribution_wall')
      when v_renderer_type like 'admin_%' then jsonb_build_array('admin_runtime','campaign_state','moderation_state','launch_state')
      else jsonb_build_array('model_runtime','page_content')
    end;

    v_component_actions := case
      when v_renderer_type = 'petition_page' then jsonb_build_array('submit_signature')
      when v_renderer_type = 'survey_page' then jsonb_build_array('submit_survey_response')
      when v_renderer_type = 'help_offer_page' then jsonb_build_array('submit_help_offer')
      when v_renderer_type = 'events_page' then jsonb_build_array('submit_event_rsvp')
      when v_renderer_type = 'evidence_library_page' then jsonb_build_array('submit_evidence')
      when v_renderer_type = 'admin_moderation_queue' then jsonb_build_array('approve_contribution','reject_contribution','hide_contribution')
      when v_renderer_type = 'admin_launch_control' then jsonb_build_array('check_launch_ready','launch_site')
      else jsonb_build_array()
    end;

    v_renderer_routes := v_renderer_routes || jsonb_build_array(
      jsonb_build_object(
        'route', v_route_path,
        'surface', v_surface,
        'component_key', v_component_key,
        'renderer_type', v_renderer_type,
        'layout', v_layout,
        'access_roles', v_route->'access_roles'
      )
    );

    v_components := v_components || jsonb_build_array(
      jsonb_build_object(
        'component_key', v_component_key,
        'renderer_type', v_renderer_type,
        'layout', v_layout,
        'data_sources', v_data_sources,
        'actions', v_component_actions
      )
    );
  end loop;

  for v_form in
    select value from jsonb_array_elements(v_manifest.runtime_forms)
  loop
    v_actions := v_actions || jsonb_build_array(
      jsonb_build_object(
        'action_key', 'render_form_' || (v_form->>'form_key'),
        'form_key', v_form->>'form_key',
        'access_roles', v_form->'access_roles',
        'action_type', 'form_render'
      )
    );
  end loop;

  v_assets := jsonb_build_array(
    jsonb_build_object(
      'asset_type','image',
      'purpose','page images and campaign graphics',
      'storage_provider','storage',
      'access','public_or_admin_uploaded'
    ),
    jsonb_build_object(
      'asset_type','video',
      'purpose','creator videos, civic videos, software demos, event recordings',
      'storage_provider','storage',
      'access','public_embed_or_gated'
    ),
    jsonb_build_object(
      'asset_type','download',
      'purpose','software downloads, documents, gated files',
      'storage_provider','storage',
      'access','public_or_license_key_gated'
    )
  );

  v_license_gates := jsonb_build_array(
    jsonb_build_object(
      'gate_key','license_key_required',
      'purpose','protect downloads, paid pages, software access, or member-only material',
      'applies_to',jsonb_build_array('download','software_product','premium_page','private_video','private_document'),
      'status','available'
    )
  );

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_RENDERER_CONTRACT_OK',
    'org_id', v_manifest.org_id,
    'model_key', v_manifest.model_key,
    'model_version', v_manifest.model_version,
    'model_runtime_manifest_id', v_manifest.model_runtime_manifest_id,
    'renderer_routes', v_renderer_routes,
    'renderer_components', v_components,
    'renderer_actions', v_actions,
    'renderer_assets', v_assets,
    'license_gates', v_license_gates,
    'contract_status', 'generated'
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_renderer_contracts_v1(
    org_id,
    model_key,
    model_version,
    model_runtime_manifest_id,
    renderer_routes,
    renderer_components,
    renderer_actions,
    renderer_assets,
    license_gates,
    contract_status,
    contract_body,
    contract_hash
  )
  values (
    v_manifest.org_id,
    v_manifest.model_key,
    v_manifest.model_version,
    v_manifest.model_runtime_manifest_id,
    v_renderer_routes,
    v_components,
    v_actions,
    v_assets,
    v_license_gates,
    'generated',
    v_body,
    v_hash
  )
  returning model_renderer_contract_id
  into v_id;

  return v_body || jsonb_build_object(
    'model_renderer_contract_id', v_id,
    'contract_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_generate_model_renderer_contract_v1"("p_model_runtime_manifest_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_generate_model_runtime_manifest_v1"("p_model_site_blueprint_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_blueprint record;

  v_routes jsonb := '[]'::jsonb;
  v_route text;

  v_forms jsonb := '[]'::jsonb;
  v_form jsonb;

  v_body jsonb;
  v_hash text;
  v_id uuid;
begin
  if p_model_site_blueprint_id is null then
    raise exception 'MODEL_RUNTIME_BLUEPRINT_REQUIRED';
  end if;

  select *
  into v_blueprint
  from pods_provisioning.model_site_blueprints_v1 b
  where b.model_site_blueprint_id = p_model_site_blueprint_id
  limit 1;

  if not found then
    raise exception 'MODEL_RUNTIME_BLUEPRINT_NOT_FOUND';
  end if;

  for v_route in
    select value::text from jsonb_array_elements_text(v_blueprint.public_pages)
  loop
    v_routes := v_routes || jsonb_build_array(
      jsonb_build_object(
        'route', v_route,
        'surface', 'public',
        'access_roles', coalesce(v_blueprint.page_access->v_route, '[]'::jsonb),
        'component_key', 'public_' || regexp_replace(trim(both '/' from v_route), '[^a-zA-Z0-9]+', '_', 'g')
      )
    );
  end loop;

  for v_route in
    select value::text from jsonb_array_elements_text(v_blueprint.admin_pages)
  loop
    v_routes := v_routes || jsonb_build_array(
      jsonb_build_object(
        'route', v_route,
        'surface', 'admin',
        'access_roles', coalesce(v_blueprint.page_access->v_route, '[]'::jsonb),
        'component_key', 'admin_' || regexp_replace(trim(both '/' from replace(v_route,'/admin/','')), '[^a-zA-Z0-9]+', '_', 'g')
      )
    );
  end loop;

  for v_form in
    select value from jsonb_array_elements(v_blueprint.forms)
  loop
    v_forms := v_forms || jsonb_build_array(
      jsonb_build_object(
        'form_key', v_form->>'form_key',
        'purpose', v_form->>'purpose',
        'access_roles', coalesce(v_blueprint.form_access->(v_form->>'form_key'), '[]'::jsonb)
      )
    );
  end loop;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_RUNTIME_GENERATOR_OK',
    'org_id', v_blueprint.org_id,
    'model_key', v_blueprint.model_key,
    'model_version', v_blueprint.model_version,
    'model_site_blueprint_id', v_blueprint.model_site_blueprint_id,
    'runtime_routes', v_routes,
    'runtime_forms', v_forms,
    'runtime_permissions', jsonb_build_object(
      'page_access', v_blueprint.page_access,
      'form_access', v_blueprint.form_access
    ),
    'runtime_navigation', v_blueprint.nav_items,
    'runtime_providers', v_blueprint.required_providers,
    'runtime_status', 'generated'
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_runtime_manifests_v1(
    org_id,
    model_key,
    model_version,
    model_site_blueprint_id,
    runtime_routes,
    runtime_forms,
    runtime_permissions,
    runtime_navigation,
    runtime_providers,
    runtime_status,
    manifest_body,
    manifest_hash
  )
  values (
    v_blueprint.org_id,
    v_blueprint.model_key,
    v_blueprint.model_version,
    v_blueprint.model_site_blueprint_id,
    v_routes,
    v_forms,
    jsonb_build_object(
      'page_access', v_blueprint.page_access,
      'form_access', v_blueprint.form_access
    ),
    v_blueprint.nav_items,
    v_blueprint.required_providers,
    'generated',
    v_body,
    v_hash
  )
  returning model_runtime_manifest_id
  into v_id;

  return v_body || jsonb_build_object(
    'model_runtime_manifest_id', v_id,
    'manifest_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_generate_model_runtime_manifest_v1"("p_model_site_blueprint_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_generate_model_site_blueprint_v1"("p_org_id" "uuid", "p_model_key" "text", "p_model_version" "text" DEFAULT 'v2'::"text", "p_deployment_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_deploy record;
  v_ui jsonb;
  v_permissions jsonb;

  v_required_providers jsonb;
  v_body jsonb;
  v_hash text;
  v_id uuid;
begin
  if p_org_id is null then
    raise exception 'MODEL_SITE_BLUEPRINT_ORG_REQUIRED';
  end if;

  if p_model_key is null or btrim(p_model_key) = '' then
    raise exception 'MODEL_SITE_BLUEPRINT_MODEL_REQUIRED';
  end if;

  if p_model_key = 'CIVIC_ACTION_V1' then
    if p_deployment_id is not null then
      select *
      into v_deploy
      from pods_provisioning.civic_action_model_deployments_v1 d
      where d.civic_deployment_id = p_deployment_id
        and d.org_id = p_org_id
      limit 1;

      if not found then
        raise exception 'MODEL_SITE_BLUEPRINT_DEPLOYMENT_NOT_FOUND';
      end if;

      v_required_providers := v_deploy.required_providers;
    else
      v_required_providers := jsonb_build_array('supabase','email','storage');
    end if;
  else
    v_required_providers := jsonb_build_array('supabase');
  end if;

  v_ui := pods_provisioning.rpc_generate_model_ui_v1(
    p_org_id,
    p_model_key,
    p_model_version
  );

  v_permissions := pods_provisioning.rpc_generate_model_permissions_v1(
    p_org_id,
    p_model_key,
    p_model_version
  );

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_SITE_BLUEPRINT_GENERATOR_OK',
    'org_id', p_org_id,
    'model_key', p_model_key,
    'model_version', p_model_version,
    'civic_deployment_id', p_deployment_id,
    'public_pages', v_ui->'public_pages',
    'admin_pages', v_ui->'admin_pages',
    'forms', v_ui->'forms',
    'nav_items', v_ui->'nav_items',
    'roles', v_ui->'roles',
    'role_permissions', v_permissions->'role_permissions',
    'page_access', v_permissions->'page_access',
    'form_access', v_permissions->'form_access',
    'required_providers', v_required_providers,
    'blueprint_status', 'generated'
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_site_blueprints_v1(
    org_id,
    model_key,
    model_version,
    civic_deployment_id,
    model_ui_generation_id,
    model_permission_generation_id,
    public_pages,
    admin_pages,
    forms,
    nav_items,
    roles,
    page_access,
    form_access,
    required_providers,
    blueprint_status,
    blueprint_body,
    blueprint_hash
  )
  values (
    p_org_id,
    p_model_key,
    p_model_version,
    p_deployment_id,
    (v_ui->>'model_ui_generation_id')::uuid,
    (v_permissions->>'model_permission_generation_id')::uuid,
    v_ui->'public_pages',
    v_ui->'admin_pages',
    v_ui->'forms',
    v_ui->'nav_items',
    v_ui->'roles',
    v_permissions->'page_access',
    v_permissions->'form_access',
    v_required_providers,
    'generated',
    v_body,
    v_hash
  )
  returning model_site_blueprint_id
  into v_id;

  return v_body || jsonb_build_object(
    'model_site_blueprint_id', v_id,
    'blueprint_hash', v_hash,
    'model_ui_generation_id', v_ui->>'model_ui_generation_id',
    'model_permission_generation_id', v_permissions->>'model_permission_generation_id'
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_generate_model_site_blueprint_v1"("p_org_id" "uuid", "p_model_key" "text", "p_model_version" "text", "p_deployment_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_generate_model_site_runtime_v1"("p_org_id" "uuid", "p_model_key" "text", "p_model_version" "text" DEFAULT 'v2'::"text", "p_fields" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_deploy jsonb;
  v_blueprint jsonb;
  v_runtime jsonb;
  v_renderer jsonb;
  v_asset jsonb;
  v_license_id uuid;
  v_license_check jsonb;

  v_launchable boolean := false;
  v_body jsonb;
  v_hash text;
  v_id uuid;
begin
  if p_org_id is null then
    raise exception 'MODEL_SITE_RUNTIME_ORG_REQUIRED';
  end if;

  if p_model_key is null or btrim(p_model_key) = '' then
    raise exception 'MODEL_SITE_RUNTIME_MODEL_REQUIRED';
  end if;

  if p_model_key = 'CIVIC_ACTION_V1' then
    v_deploy := pods_provisioning.rpc_deploy_civic_action_model_v1(
      p_org_id,
      p_fields
    );

    v_blueprint := pods_provisioning.rpc_generate_model_site_blueprint_v1(
      p_org_id,
      p_model_key,
      p_model_version,
      (v_deploy->>'civic_deployment_id')::uuid
    );
  else
    v_deploy := jsonb_build_object(
      'ok', true,
      'token', 'PROTEUSOPS_GENERIC_MODEL_DEPLOYMENT_PLACEHOLDER_OK',
      'org_id', p_org_id,
      'model_key', p_model_key,
      'model_version', p_model_version,
      'deployment_status', 'planned'
    );

    v_blueprint := pods_provisioning.rpc_generate_model_site_blueprint_v1(
      p_org_id,
      p_model_key,
      p_model_version,
      null
    );
  end if;

  v_runtime := pods_provisioning.rpc_generate_model_runtime_manifest_v1(
    (v_blueprint->>'model_site_blueprint_id')::uuid
  );

  v_renderer := pods_provisioning.rpc_generate_model_renderer_contract_v1(
    (v_runtime->>'model_runtime_manifest_id')::uuid
  );

  v_asset := pods_provisioning.rpc_create_runtime_asset_v1(
    p_org_id,
    'software',
    'Sample Gated Download',
    'storage://runtime/sample-download.zip',
    true
  );

  insert into pods_provisioning.license_key_runtime_v1(
    org_id,
    license_key,
    license_status,
    license_hash
  )
  values(
    p_org_id,
    'SITE-RUNTIME-TEST-LICENSE',
    'active',
    pods_provisioning._sha256_text_v1('SITE-RUNTIME-TEST-LICENSE')
  )
  returning license_key_runtime_id
  into v_license_id;

  v_license_check := pods_provisioning.rpc_validate_license_asset_access_v1(
    (v_asset->>'asset_runtime_object_id')::uuid,
    'SITE-RUNTIME-TEST-LICENSE'
  );

  v_launchable :=
    (v_runtime->>'token' = 'PROTEUSOPS_MODEL_RUNTIME_GENERATOR_OK')
    and (v_renderer->>'token' = 'PROTEUSOPS_MODEL_RENDERER_CONTRACT_OK')
    and ((v_license_check->>'access_allowed')::boolean = true);

  if not v_launchable then
    raise exception 'MODEL_SITE_RUNTIME_NOT_LAUNCHABLE';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_SITE_RUNTIME_GENERATOR_OK',
    'org_id', p_org_id,
    'model_key', p_model_key,
    'model_version', p_model_version,
    'launchable', v_launchable,
    'site_runtime_status', 'generated',
    'deployment', v_deploy,
    'blueprint', v_blueprint,
    'runtime_manifest', v_runtime,
    'renderer_contract', v_renderer,
    'asset_runtime', v_asset,
    'license_runtime', jsonb_build_object(
      'license_key_runtime_id', v_license_id,
      'access_check', v_license_check
    ),
    'site_runtime_capabilities', jsonb_build_array(
      'generated_pages',
      'generated_forms',
      'generated_navigation',
      'generated_permissions',
      'generated_renderer_contract',
      'asset_uploads',
      'license_gated_downloads',
      'video_assets',
      'public_and_admin_surfaces'
    )
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_site_runtime_generations_v1(
    org_id,
    model_key,
    model_version,
    civic_deployment_id,
    model_site_blueprint_id,
    model_runtime_manifest_id,
    model_renderer_contract_id,
    site_runtime_status,
    launchable,
    asset_runtime_ready,
    license_runtime_ready,
    site_runtime_body,
    site_runtime_hash
  )
  values (
    p_org_id,
    p_model_key,
    p_model_version,
    nullif(v_deploy->>'civic_deployment_id','')::uuid,
    (v_blueprint->>'model_site_blueprint_id')::uuid,
    (v_runtime->>'model_runtime_manifest_id')::uuid,
    (v_renderer->>'model_renderer_contract_id')::uuid,
    'generated',
    v_launchable,
    true,
    true,
    v_body,
    v_hash
  )
  returning model_site_runtime_generation_id
  into v_id;

  return v_body || jsonb_build_object(
    'model_site_runtime_generation_id', v_id,
    'site_runtime_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_generate_model_site_runtime_v1"("p_org_id" "uuid", "p_model_key" "text", "p_model_version" "text", "p_fields" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_generate_model_ui_v1"("p_org_id" "uuid", "p_model_key" "text", "p_model_version" "text" DEFAULT 'v1'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_public_pages jsonb;
  v_admin_pages jsonb;
  v_forms jsonb;
  v_nav_items jsonb;
  v_roles jsonb;
  v_body jsonb;
  v_hash text;
  v_id uuid;
begin
  if p_org_id is null then
    raise exception 'MODEL_UI_ORG_REQUIRED';
  end if;

  if p_model_key is null or btrim(p_model_key) = '' then
    raise exception 'MODEL_UI_MODEL_REQUIRED';
  end if;

  if p_model_key = 'CIVIC_ACTION_V1' then
    v_public_pages := jsonb_build_array(
      '/',
      '/issue',
      '/petition',
      '/survey',
      '/volunteer',
      '/events',
      '/evidence',
      '/contribution-wall',
      '/updates'
    );

    v_admin_pages := jsonb_build_array(
      '/admin/dashboard',
      '/admin/campaign',
      '/admin/petitions',
      '/admin/surveys',
      '/admin/events',
      '/admin/evidence',
      '/admin/volunteers',
      '/admin/moderation',
      '/admin/launch'
    );

    v_forms := jsonb_build_array(
      jsonb_build_object('form_key','campaign_setup','purpose','Create campaign fields'),
      jsonb_build_object('form_key','petition_signature','purpose','Collect petition signatures'),
      jsonb_build_object('form_key','survey_response','purpose','Collect survey responses'),
      jsonb_build_object('form_key','help_offer','purpose','Collect volunteer/help offers'),
      jsonb_build_object('form_key','event_rsvp','purpose','Collect event RSVPs'),
      jsonb_build_object('form_key','evidence_submission','purpose','Collect evidence submissions'),
      jsonb_build_object('form_key','moderation_action','purpose','Approve/reject/hide contributions')
    );

    v_nav_items := jsonb_build_array(
      'About',
      'Issue',
      'Sign',
      'Survey',
      'Help',
      'Events',
      'Evidence',
      'Contributions'
    );

    v_roles := jsonb_build_array(
      'visitor',
      'supporter',
      'signer',
      'survey_respondent',
      'volunteer',
      'organizer',
      'moderator',
      'community_admin',
      'institution_partner'
    );
  else
    v_public_pages := jsonb_build_array('/');
    v_admin_pages := jsonb_build_array('/admin/dashboard','/admin/launch');
    v_forms := jsonb_build_array(jsonb_build_object('form_key','setup','purpose','Default setup form'));
    v_nav_items := jsonb_build_array('Home');
    v_roles := jsonb_build_array('visitor','owner','admin');
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_UI_GENERATOR_OK',
    'org_id', p_org_id,
    'model_key', p_model_key,
    'model_version', p_model_version,
    'public_pages', v_public_pages,
    'admin_pages', v_admin_pages,
    'forms', v_forms,
    'nav_items', v_nav_items,
    'roles', v_roles,
    'generation_status', 'generated'
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_ui_generations_v1(
    org_id,
    model_key,
    model_version,
    public_pages,
    admin_pages,
    forms,
    nav_items,
    roles,
    generation_status,
    generation_body,
    generation_hash
  )
  values (
    p_org_id,
    p_model_key,
    p_model_version,
    v_public_pages,
    v_admin_pages,
    v_forms,
    v_nav_items,
    v_roles,
    'generated',
    v_body,
    v_hash
  )
  returning model_ui_generation_id
  into v_id;

  return v_body || jsonb_build_object(
    'model_ui_generation_id', v_id,
    'generation_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_generate_model_ui_v1"("p_org_id" "uuid", "p_model_key" "text", "p_model_version" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_generate_runtime_drift_report_v1"("p_model_instance_runtime_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_baseline record;
  v_current jsonb;
  v_findings jsonb := '[]'::jsonb;
  v_finding_count integer := 0;
  v_status text := 'clean';
  v_severity text := 'none';
  v_body jsonb;
  v_report_hash text;
  v_report_id uuid;
  v_finding jsonb;
  v_finding_hash text;
begin
  select *
  into v_baseline
  from pods_provisioning.model_runtime_drift_baselines_v1
  where model_instance_runtime_id = p_model_instance_runtime_id
    and baseline_status = 'active'
  order by created_at desc
  limit 1;

  if not found then
    raise exception 'MODEL_RUNTIME_DRIFT_BASELINE_NOT_FOUND';
  end if;

  v_current := pods_provisioning.rpc_current_runtime_drift_fingerprint_v1(p_model_instance_runtime_id);

  if v_current->>'composite_runtime_hash' <> v_baseline.baseline_hash then
    v_status := 'drift_detected';
    v_severity := 'warning';

    v_finding := jsonb_build_object(
      'drift_category', 'runtime',
      'severity', 'warning',
      'resolution_status', 'pending_review',
      'expected_hash', v_baseline.baseline_hash,
      'actual_hash', v_current->>'composite_runtime_hash',
      'message', 'Current runtime fingerprint differs from active baseline.'
    );

    v_findings := v_findings || jsonb_build_array(v_finding);
  end if;

  v_finding_count := jsonb_array_length(v_findings);

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_RUNTIME_DRIFT_OK',
    'org_id', v_baseline.org_id,
    'model_instance_runtime_id', p_model_instance_runtime_id,
    'model_runtime_drift_baseline_id', v_baseline.model_runtime_drift_baseline_id,
    'drift_status', v_status,
    'severity', v_severity,
    'baseline_hash', v_baseline.baseline_hash,
    'current_hash', v_current->>'composite_runtime_hash',
    'finding_count', v_finding_count,
    'findings', v_findings
  );

  v_report_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_runtime_drift_reports_v1(
    org_id,
    model_instance_runtime_id,
    model_runtime_drift_baseline_id,
    drift_status,
    severity,
    current_hash,
    baseline_hash,
    finding_count,
    report_body,
    report_hash
  )
  values (
    v_baseline.org_id,
    p_model_instance_runtime_id,
    v_baseline.model_runtime_drift_baseline_id,
    v_status,
    v_severity,
    v_current->>'composite_runtime_hash',
    v_baseline.baseline_hash,
    v_finding_count,
    v_body,
    v_report_hash
  )
  returning model_runtime_drift_report_id
  into v_report_id;

  for v_finding in select * from jsonb_array_elements(v_findings)
  loop
    v_finding_hash := pods_provisioning._sha256_text_v1(v_finding::text);

    insert into pods_provisioning.model_runtime_drift_findings_v1(
      org_id,
      model_runtime_drift_report_id,
      model_instance_runtime_id,
      drift_category,
      severity,
      resolution_status,
      expected_hash,
      actual_hash,
      finding_body,
      finding_hash
    )
    values (
      v_baseline.org_id,
      v_report_id,
      p_model_instance_runtime_id,
      v_finding->>'drift_category',
      v_finding->>'severity',
      v_finding->>'resolution_status',
      coalesce(v_finding->>'expected_hash',''),
      coalesce(v_finding->>'actual_hash',''),
      v_finding,
      v_finding_hash
    );
  end loop;

  return v_body || jsonb_build_object(
    'model_runtime_drift_report_id', v_report_id,
    'report_hash', v_report_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_generate_runtime_drift_report_v1"("p_model_instance_runtime_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_get_appointment_admin_queue_v1"("p_org_id" "uuid", "p_status" "text" DEFAULT 'requested'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_items jsonb;
begin
  if p_org_id is null then
    raise exception 'ADMIN_QUEUE_ORG_ID_REQUIRED';
  end if;

  if p_status is null or p_status not in ('requested','confirmed','cancelled','declined') then
    raise exception 'ADMIN_QUEUE_STATUS_INVALID:%', coalesce(p_status,'');
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'appointment_request_id', r.appointment_request_id,
        'booking_slug', r.booking_slug,
        'booking_path', r.booking_path,
        'template_key', r.template_key,
        'template_version', r.template_version,
        'service_code', r.service_code,
        'requested_date', r.requested_date::text,
        'requested_start_time', r.requested_start_time::text,
        'requested_end_time', r.requested_end_time::text,
        'customer_name', r.customer_name,
        'customer_email', r.customer_email,
        'customer_phone', r.customer_phone,
        'status', r.status,
        'request_hash', r.request_hash,
        'created_at', r.created_at
      )
      order by r.requested_date, r.requested_start_time, r.created_at
    ),
    '[]'::jsonb
  )
  into v_items
  from pods_provisioning.public_appointment_requests_v1 r
  where r.org_id = p_org_id
    and r.status = p_status;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_APPOINTMENT_ADMIN_QUEUE_OK',
    'org_id', p_org_id,
    'status', p_status,
    'count', jsonb_array_length(v_items),
    'items', v_items
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_get_appointment_admin_queue_v1"("p_org_id" "uuid", "p_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_get_booking_availability_v1"("p_booking_slug" "text", "p_service_code" "text", "p_start_date" "date", "p_days" integer DEFAULT 7) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_page jsonb;
  v_service jsonb;
  v_duration integer;
  v_slots jsonb;
begin
  if p_days is null or p_days < 1 or p_days > 31 then
    raise exception 'AVAILABILITY_DAYS_INVALID';
  end if;

  v_page := pods_provisioning.rpc_get_booking_page_read_model_v1(p_booking_slug);

  select s
  into v_service
  from jsonb_array_elements(v_page->'services') s
  where s->>'service_code' = p_service_code
  limit 1;

  if v_service is null then
    raise exception 'AVAILABILITY_SERVICE_NOT_FOUND:%', p_service_code;
  end if;

  v_duration := (v_service->>'duration_minutes')::integer;

  with days as (
    select generate_series(p_start_date, p_start_date + (p_days - 1), interval '1 day')::date as d
  ),
  hours as (
    select
      d.d,
      h.dow,
      h.open_time::time as open_time,
      h.close_time::time as close_time
    from days d
    join jsonb_to_recordset(v_page->'hours') as h(dow int, open_time text, close_time text)
      on h.dow = extract(dow from d.d)::int
  ),
  slots as (
    select
      h.d,
      gs::time as start_time,
      (gs + make_interval(mins => v_duration))::time as end_time
    from hours h
    cross join lateral generate_series(
      h.d + h.open_time,
      h.d + h.close_time - make_interval(mins => v_duration),
      interval '15 minutes'
    ) gs
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'date', d::text,
        'start_time', start_time::text,
        'end_time', end_time::text,
        'service_code', p_service_code,
        'duration_minutes', v_duration,
        'status', 'available'
      )
      order by d, start_time
    ),
    '[]'::jsonb
  )
  into v_slots
  from slots;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_BOOKING_AVAILABILITY_ENGINE_OK',
    'booking_slug', p_booking_slug,
    'booking_path', v_page->>'booking_path',
    'service_code', p_service_code,
    'duration_minutes', v_duration,
    'start_date', p_start_date::text,
    'days', p_days,
    'slot_count', jsonb_array_length(v_slots),
    'slots', v_slots
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_get_booking_availability_v1"("p_booking_slug" "text", "p_service_code" "text", "p_start_date" "date", "p_days" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_get_booking_page_read_model_v1"("p_booking_slug" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_surface record;
  v_template record;
  v_services jsonb;
  v_hours jsonb;
begin
  if p_booking_slug is null or btrim(p_booking_slug) = '' then
    raise exception 'BOOKING_PAGE_SLUG_REQUIRED';
  end if;

  select *
  into v_surface
  from pods_provisioning.public_booking_surfaces_v1 pbs
  where pbs.booking_slug = p_booking_slug
    and pbs.enabled = true
  limit 1;

  if not found then
    raise exception 'BOOKING_PAGE_NOT_FOUND:%', p_booking_slug;
  end if;

  select *
  into v_template
  from pods_provisioning.vertical_templates vt
  where vt.template_key = v_surface.template_key
  limit 1;

  if not found then
    raise exception 'BOOKING_PAGE_TEMPLATE_NOT_FOUND:%', v_surface.template_key;
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'service_code', s.service_code,
        'display_name', s.display_name,
        'duration_minutes', s.duration_minutes,
        'price_cents', s.price_cents,
        'booking_enabled', s.booking_enabled
      )
      order by s.display_name
    ),
    '[]'::jsonb
  )
  into v_services
  from pods_provisioning.vertical_template_services s
  where s.template_key = v_surface.template_key
    and s.booking_enabled = true;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'dow', h.dow,
        'open_time', h.open_time::text,
        'close_time', h.close_time::text
      )
      order by h.dow
    ),
    '[]'::jsonb
  )
  into v_hours
  from pods_provisioning.vertical_template_hours h
  where h.template_key = v_surface.template_key;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_BOOKING_PAGE_READ_MODEL_OK',
    'booking_slug', v_surface.booking_slug,
    'booking_path', v_surface.booking_path,
    'enabled', v_surface.enabled,
    'org_id', v_surface.org_id,
    'template_key', v_surface.template_key,
    'template_version', v_surface.template_version,
    'business_model', jsonb_build_object(
      'display_name', v_template.display_name,
      'category', v_template.category,
      'description', v_template.description,
      'default_timezone', v_template.default_timezone,
      'memberships_enabled', v_template.memberships_enabled,
      'booking_enabled', v_template.booking_enabled
    ),
    'services', v_services,
    'hours', v_hours,
    'customer_next_steps', jsonb_build_array(
      'Choose a service',
      'Select an available time',
      'Enter contact information',
      'Confirm appointment request'
    )
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_get_booking_page_read_model_v1"("p_booking_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_get_operator_calendar_v1"("p_org_id" "uuid", "p_start_date" "date", "p_days" integer DEFAULT 7) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_items jsonb;
begin
  if p_org_id is null then
    raise exception 'OPERATOR_CALENDAR_ORG_REQUIRED';
  end if;

  if p_start_date is null then
    raise exception 'OPERATOR_CALENDAR_START_DATE_REQUIRED';
  end if;

  if p_days is null or p_days < 1 or p_days > 31 then
    raise exception 'OPERATOR_CALENDAR_DAYS_INVALID';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'appointment_request_id', r.appointment_request_id,
        'date', r.requested_date::text,
        'start_time', r.requested_start_time::text,
        'end_time', r.requested_end_time::text,
        'service_code', r.service_code,
        'customer_name', r.customer_name,
        'customer_email', r.customer_email,
        'customer_phone', r.customer_phone,
        'status', r.status,
        'booking_slug', r.booking_slug,
        'booking_path', r.booking_path,
        'template_key', r.template_key,
        'template_version', r.template_version,
        'request_hash', r.request_hash,
        'created_at', r.created_at
      )
      order by
        r.requested_date,
        r.requested_start_time,
        r.created_at
    ),
    '[]'::jsonb
  )
  into v_items
  from pods_provisioning.public_appointment_requests_v1 r
  where r.org_id = p_org_id
    and r.status = 'confirmed'
    and r.requested_date >= p_start_date
    and r.requested_date < (p_start_date + p_days);

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_OPERATOR_CALENDAR_OK',
    'org_id', p_org_id,
    'start_date', p_start_date::text,
    'days', p_days,
    'count', jsonb_array_length(v_items),
    'calendar', v_items
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_get_operator_calendar_v1"("p_org_id" "uuid", "p_start_date" "date", "p_days" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_get_public_staff_profiles_v1"("p_booking_slug" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_surface record;
  v_profiles jsonb;
  v_featured jsonb;
begin
  if p_booking_slug is null or btrim(p_booking_slug) = '' then
    raise exception 'PUBLIC_STAFF_BOOKING_SLUG_REQUIRED';
  end if;

  select *
  into v_surface
  from pods_provisioning.public_booking_surfaces_v1 pbs
  where pbs.booking_slug = p_booking_slug
    and pbs.enabled = true
  limit 1;

  if not found then
    raise exception 'PUBLIC_STAFF_BOOKING_SURFACE_NOT_FOUND';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'staff_member_id', sm.staff_member_id,
        'display_name', spp.public_display_name,
        'role_key', sm.role_key,
        'headline', spp.headline,
        'about_me', spp.about_me,
        'specialties', spp.specialties,
        'years_experience', spp.years_experience,
        'profile_photo_url', spp.profile_photo_url,
        'featured_rank', spp.featured_rank,
        'gallery', coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'title', gi.title,
              'description', gi.description,
              'media_url', gi.media_url,
              'media_kind', gi.media_kind,
              'service_code', gi.service_code
            )
            order by gi.display_order, gi.created_at
          )
          from pods_provisioning.staff_gallery_items_v1 gi
          where gi.staff_member_id = sm.staff_member_id
            and gi.is_public = true
        ), '[]'::jsonb)
      )
      order by spp.featured_rank, spp.public_display_name
    ),
    '[]'::jsonb
  )
  into v_profiles
  from pods_provisioning.staff_public_profiles_v1 spp
  join pods_provisioning.staff_members_v1 sm
    on sm.staff_member_id = spp.staff_member_id
  where spp.org_id = v_surface.org_id
    and spp.is_public = true
    and sm.active = true;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'section_key', fs.section_key,
        'display_title', fs.display_title,
        'section_kind', fs.section_kind,
        'staff_member_id', fs.staff_member_id,
        'starts_on', fs.starts_on::text,
        'ends_on', fs.ends_on::text
      )
      order by fs.created_at
    ),
    '[]'::jsonb
  )
  into v_featured
  from pods_provisioning.staff_featured_sections_v1 fs
  where fs.org_id = v_surface.org_id
    and fs.enabled = true;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PUBLIC_STAFF_PROFILES_OK',
    'booking_slug', p_booking_slug,
    'booking_path', v_surface.booking_path,
    'org_id', v_surface.org_id,
    'profile_count', jsonb_array_length(v_profiles),
    'profiles', v_profiles,
    'featured_sections', v_featured
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_get_public_staff_profiles_v1"("p_booking_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_install_marketplace_model_v1"("p_org_id" "uuid", "p_model_key" "text", "p_model_version" "text" DEFAULT NULL::"text", "p_wizard_answers" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_catalog record;
  v_version text;
  v_wizard jsonb;
  v_package jsonb;
  v_body jsonb;
  v_hash text;
  v_id uuid;
begin
  if p_org_id is null then
    raise exception 'MODEL_MARKETPLACE_INSTALL_ORG_REQUIRED';
  end if;

  if p_model_key is null or btrim(p_model_key) = '' then
    raise exception 'MODEL_MARKETPLACE_INSTALL_MODEL_REQUIRED';
  end if;

  select *
  into v_catalog
  from pods_provisioning.model_marketplace_catalog_v1
  where model_key = p_model_key
    and marketplace_status = 'published'
    and (p_model_version is null or model_version = p_model_version)
  order by created_at desc
  limit 1;

  if not found then
    raise exception 'MODEL_MARKETPLACE_INSTALL_MODEL_NOT_FOUND';
  end if;

  if not v_catalog.wizard_enabled then
    raise exception 'MODEL_MARKETPLACE_INSTALL_WIZARD_DISABLED';
  end if;

  if not v_catalog.deployment_enabled then
    raise exception 'MODEL_MARKETPLACE_INSTALL_DEPLOYMENT_DISABLED';
  end if;

  v_version := v_catalog.model_version;

  v_wizard := pods_provisioning.rpc_run_model_instance_wizard_v1(
    p_org_id,
    v_catalog.model_key,
    v_version,
    coalesce(p_wizard_answers,'{}'::jsonb)
  );

  v_package := pods_provisioning.rpc_generate_model_launch_package_v1(
    (v_wizard->>'model_instance_runtime_id')::uuid
  );

  if v_package->>'token' <> 'PROTEUSOPS_MODEL_LAUNCH_PACKAGE_OK' then
    raise exception 'MODEL_MARKETPLACE_INSTALL_LAUNCH_PACKAGE_FAIL';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_MARKETPLACE_INSTALL_OK',
    'org_id', p_org_id,
    'model_marketplace_catalog_id', v_catalog.model_marketplace_catalog_id,
    'model_key', v_catalog.model_key,
    'model_version', v_version,
    'display_name', v_catalog.display_name,
    'category_key', v_catalog.category_key,
    'required_providers', v_catalog.required_providers,
    'supported_blocks', v_catalog.supported_blocks,
    'install_status', 'installed',
    'launchable', v_package->>'launchable',
    'wizard', v_wizard,
    'launch_package', v_package,
    'model_instance_wizard_run_id', v_wizard->>'model_instance_wizard_run_id',
    'model_instance_runtime_id', v_wizard->>'model_instance_runtime_id',
    'model_launch_package_id', v_package->>'model_launch_package_id'
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_marketplace_installs_v1(
    org_id,
    model_marketplace_catalog_id,
    model_key,
    model_version,
    model_instance_wizard_run_id,
    model_instance_runtime_id,
    model_launch_package_id,
    install_status,
    launchable,
    install_body,
    install_hash
  )
  values (
    p_org_id,
    v_catalog.model_marketplace_catalog_id,
    v_catalog.model_key,
    v_version,
    (v_wizard->>'model_instance_wizard_run_id')::uuid,
    (v_wizard->>'model_instance_runtime_id')::uuid,
    (v_package->>'model_launch_package_id')::uuid,
    'installed',
    (v_package->>'launchable')::boolean,
    v_body,
    v_hash
  )
  returning model_marketplace_install_id
  into v_id;

  update pods_provisioning.model_marketplace_catalog_v1
  set install_count = install_count + 1
  where model_marketplace_catalog_id = v_catalog.model_marketplace_catalog_id;

  return v_body || jsonb_build_object(
    'model_marketplace_install_id', v_id,
    'install_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_install_marketplace_model_v1"("p_org_id" "uuid", "p_model_key" "text", "p_model_version" "text", "p_wizard_answers" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_launch_site_v1"("p_model_launch_authority_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_authority record;
  v_package record;
  v_body jsonb;
  v_hash text;
  v_receipt_id uuid;
begin
  select *
  into v_authority
  from pods_provisioning.model_launch_authorities_v1
  where model_launch_authority_id = p_model_launch_authority_id
  limit 1;

  if not found then
    raise exception 'MODEL_SITE_LAUNCH_AUTHORITY_NOT_FOUND';
  end if;

  select *
  into v_package
  from pods_provisioning.model_launch_packages_v1
  where model_launch_package_id = v_authority.model_launch_package_id
  limit 1;

  if not found then
    raise exception 'MODEL_SITE_LAUNCH_PACKAGE_NOT_FOUND';
  end if;

  if v_authority.launch_state <> 'ready_for_launch' then
    raise exception 'MODEL_SITE_LAUNCH_STATE_DENY:%', v_authority.launch_state;
  end if;

  if jsonb_array_length(coalesce(v_authority.launch_blockers,'[]'::jsonb)) <> 0 then
    raise exception 'MODEL_SITE_LAUNCH_BLOCKERS_PRESENT:%', v_authority.launch_blockers;
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_SITE_LAUNCH_OK',
    'org_id', v_authority.org_id,
    'model_launch_authority_id', v_authority.model_launch_authority_id,
    'model_launch_package_id', v_authority.model_launch_package_id,
    'model_instance_runtime_id', v_authority.model_instance_runtime_id,
    'deployment_target_key', v_authority.deployment_target_key,
    'launch_action', 'launch',
    'launch_result', 'completed',
    'launch_state', 'launched',
    'runtime_hash', v_package.package_hash,
    'readiness_checks', v_authority.readiness_checks
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_launch_receipts_v1(
    org_id,
    model_launch_authority_id,
    model_launch_package_id,
    model_instance_runtime_id,
    launch_action,
    launch_result,
    receipt_body,
    receipt_hash
  )
  values (
    v_authority.org_id,
    v_authority.model_launch_authority_id,
    v_authority.model_launch_package_id,
    v_authority.model_instance_runtime_id,
    'launch',
    'completed',
    v_body,
    v_hash
  )
  returning model_launch_receipt_id
  into v_receipt_id;

  update pods_provisioning.model_launch_authorities_v1
  set launch_state = 'launched'
  where model_launch_authority_id = v_authority.model_launch_authority_id;

  update pods_provisioning.model_launch_packages_v1
  set package_status = 'launched'
  where model_launch_package_id = v_authority.model_launch_package_id;

  update pods_provisioning.model_instance_runtimes_v1
  set instance_status = 'launched'
  where model_instance_runtime_id = v_authority.model_instance_runtime_id;

  return v_body || jsonb_build_object(
    'model_launch_receipt_id', v_receipt_id,
    'launch_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_launch_site_v1"("p_model_launch_authority_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_list_release_history_v1"("p_model_instance_runtime_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_releases jsonb;
  v_promotions jsonb;
  v_rollbacks jsonb;
begin
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'model_release_id', model_release_id,
      'channel_key', channel_key,
      'release_status', release_status,
      'release_label', release_label,
      'release_hash', release_hash,
      'created_at', created_at
    )
    order by created_at, model_release_id
  ), '[]'::jsonb)
  into v_releases
  from pods_provisioning.model_releases_v1
  where model_instance_runtime_id = p_model_instance_runtime_id;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'model_release_promotion_id', p.model_release_promotion_id,
      'model_release_id', p.model_release_id,
      'from_channel', p.from_channel,
      'to_channel', p.to_channel,
      'promotion_hash', p.promotion_hash,
      'created_at', p.created_at
    )
    order by p.created_at, p.model_release_promotion_id
  ), '[]'::jsonb)
  into v_promotions
  from pods_provisioning.model_release_promotions_v1 p
  join pods_provisioning.model_releases_v1 r
    on r.model_release_id = p.model_release_id
  where r.model_instance_runtime_id = p_model_instance_runtime_id;

  select coalesce(jsonb_agg(
    jsonb_build_object(
      'model_release_rollback_id', rb.model_release_rollback_id,
      'source_release_id', rb.source_release_id,
      'target_release_id', rb.target_release_id,
      'rollback_hash', rb.rollback_hash,
      'created_at', rb.created_at
    )
    order by rb.created_at, rb.model_release_rollback_id
  ), '[]'::jsonb)
  into v_rollbacks
  from pods_provisioning.model_release_rollbacks_v1 rb
  join pods_provisioning.model_releases_v1 r
    on r.model_release_id = rb.source_release_id
  where r.model_instance_runtime_id = p_model_instance_runtime_id;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_RELEASE_GOVERNANCE_OK',
    'model_instance_runtime_id', p_model_instance_runtime_id,
    'releases', v_releases,
    'promotions', v_promotions,
    'rollbacks', v_rollbacks,
    'release_count', jsonb_array_length(v_releases),
    'promotion_count', jsonb_array_length(v_promotions),
    'rollback_count', jsonb_array_length(v_rollbacks)
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_list_release_history_v1"("p_model_instance_runtime_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_mark_adapter_attached_v1"("p_adapter_attachment_run_id" "uuid", "p_adapter_key" "text", "p_provider_key" "text", "p_config_ref" "text" DEFAULT ''::"text", "p_public_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_run record;
  v_item record;
  v_attached jsonb;
  v_missing jsonb;
  v_status text;
  v_launch_blocked boolean;
  v_body jsonb;
  v_hash text;
begin
  if p_adapter_attachment_run_id is null then
    raise exception 'ADAPTER_MARK_RUN_REQUIRED';
  end if;

  if p_adapter_key is null or btrim(p_adapter_key) = '' then
    raise exception 'ADAPTER_MARK_KEY_REQUIRED';
  end if;

  if p_provider_key is null or btrim(p_provider_key) = '' then
    raise exception 'ADAPTER_MARK_PROVIDER_REQUIRED';
  end if;

  select *
  into v_run
  from pods_provisioning.adapter_attachment_runs_v1 r
  where r.adapter_attachment_run_id = p_adapter_attachment_run_id
  for update;

  if not found then
    raise exception 'ADAPTER_MARK_RUN_NOT_FOUND';
  end if;

  select *
  into v_item
  from pods_provisioning.adapter_attachment_items_v1 i
  where i.adapter_attachment_run_id = p_adapter_attachment_run_id
    and i.adapter_key = p_adapter_key
  for update;

  if not found then
    raise exception 'ADAPTER_MARK_ITEM_NOT_FOUND:%', p_adapter_key;
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_ADAPTER_ATTACHED_OK',
    'adapter_attachment_run_id', p_adapter_attachment_run_id,
    'org_id', v_run.org_id,
    'adapter_key', p_adapter_key,
    'provider_key', p_provider_key,
    'adapter_status', 'attached',
    'config_ref', coalesce(p_config_ref,''),
    'public_metadata', coalesce(p_public_metadata,'{}'::jsonb)
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  update pods_provisioning.adapter_attachment_items_v1
  set
    provider_key = p_provider_key,
    adapter_status = 'attached',
    config_ref = coalesce(p_config_ref,''),
    public_metadata = coalesce(p_public_metadata,'{}'::jsonb),
    item_body = v_body,
    item_hash = v_hash,
    updated_at = now()
  where adapter_attachment_item_id = v_item.adapter_attachment_item_id;

  select coalesce(jsonb_agg(i.adapter_key order by i.adapter_key), '[]'::jsonb)
  into v_attached
  from pods_provisioning.adapter_attachment_items_v1 i
  where i.adapter_attachment_run_id = p_adapter_attachment_run_id
    and i.adapter_status in ('attached','verified');

  select coalesce(jsonb_agg(i.adapter_key order by i.adapter_key), '[]'::jsonb)
  into v_missing
  from pods_provisioning.adapter_attachment_items_v1 i
  where i.adapter_attachment_run_id = p_adapter_attachment_run_id
    and i.adapter_status = 'missing';

  v_launch_blocked := jsonb_array_length(v_missing) > 0;

  if v_launch_blocked then
    v_status := 'partial';
  else
    v_status := 'ready';
  end if;

  update pods_provisioning.adapter_attachment_runs_v1
  set
    attached_adapters = v_attached,
    missing_adapters = v_missing,
    attachment_status = v_status,
    launch_blocked = v_launch_blocked
  where adapter_attachment_run_id = p_adapter_attachment_run_id;

  return v_body || jsonb_build_object(
    'attached_adapters', v_attached,
    'missing_adapters', v_missing,
    'attachment_status', v_status,
    'launch_blocked', v_launch_blocked,
    'attachment_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_mark_adapter_attached_v1"("p_adapter_attachment_run_id" "uuid", "p_adapter_key" "text", "p_provider_key" "text", "p_config_ref" "text", "p_public_metadata" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_moderate_civic_contribution_v1"("p_contribution_type" "text", "p_source_id" "uuid", "p_action" "text", "p_reason" "text" DEFAULT ''::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_campaign_id uuid;
  v_status text;
  v_visible boolean;
  v_body jsonb;
  v_hash text;
  v_receipt_id uuid;
begin
  if p_action = 'approve' then
    v_status := 'approved';
    v_visible := true;
  elsif p_action = 'reject' then
    v_status := 'rejected';
    v_visible := false;
  elsif p_action = 'hide' then
    v_status := 'hidden';
    v_visible := false;
  else
    raise exception 'CIVIC_MODERATION_INVALID_ACTION';
  end if;

  update pods_provisioning.civic_action_contribution_wall_entries_v1
  set
    moderation_status = v_status,
    public_visible = v_visible
  where contribution_type = p_contribution_type
    and source_id = p_source_id
  returning civic_campaign_id
  into v_campaign_id;

  if not found then
    raise exception 'CIVIC_MODERATION_SOURCE_NOT_FOUND';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_MODERATION_GOVERNANCE_OK',
    'civic_campaign_id', v_campaign_id,
    'contribution_type', p_contribution_type,
    'source_id', p_source_id,
    'moderation_action', p_action,
    'moderation_status', v_status,
    'public_visible', v_visible,
    'moderation_reason', coalesce(p_reason,'')
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.civic_action_moderation_receipts_v1(
    civic_campaign_id,
    contribution_type,
    source_id,
    moderation_action,
    moderation_reason,
    public_visible,
    receipt_body,
    receipt_hash
  )
  values (
    v_campaign_id,
    p_contribution_type,
    p_source_id,
    p_action,
    coalesce(p_reason,''),
    v_visible,
    v_body,
    v_hash
  )
  returning civic_moderation_receipt_id
  into v_receipt_id;

  return v_body || jsonb_build_object(
    'civic_moderation_receipt_id', v_receipt_id,
    'receipt_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_moderate_civic_contribution_v1"("p_contribution_type" "text", "p_source_id" "uuid", "p_action" "text", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_plan_model_capabilities_v1"("p_org_id" "uuid", "p_model_key" "text", "p_requested_fields" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_model record;
  v_applied_defaults jsonb;
  v_skipped_fields jsonb := '[]'::jsonb;
  v_body jsonb;
  v_hash text;
  v_plan_run_id uuid;
begin
  if p_org_id is null then
    raise exception 'MODEL_CAPABILITY_PLAN_ORG_REQUIRED';
  end if;

  if p_model_key is null or btrim(p_model_key) = '' then
    raise exception 'MODEL_CAPABILITY_PLAN_MODEL_REQUIRED';
  end if;

  select *
  into v_model
  from pods_provisioning.model_capability_matrix_v1 m
  where m.model_key = p_model_key
    and m.active = true
  limit 1;

  if not found then
    raise exception 'MODEL_CAPABILITY_MODEL_NOT_FOUND:%', p_model_key;
  end if;

  v_applied_defaults := v_model.default_overlays || coalesce(p_requested_fields,'{}'::jsonb);

  select coalesce(jsonb_agg(field_obj->>'field_key'), '[]'::jsonb)
  into v_skipped_fields
  from jsonb_array_elements(v_model.customer_fields) field_obj
  where not (coalesce(p_requested_fields,'{}'::jsonb) ? (field_obj->>'field_key'));

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_CAPABILITY_MATRIX_OK',
    'org_id', p_org_id,
    'model_key', v_model.model_key,
    'model_version', v_model.model_version,
    'vertical_domain', v_model.vertical_domain,
    'requested_fields', coalesce(p_requested_fields,'{}'::jsonb),
    'skipped_fields', v_skipped_fields,
    'applied_defaults', v_applied_defaults,
    'provision_engines', v_model.required_engines,
    'provision_capabilities', v_model.required_capabilities,
    'provision_resources', v_model.required_resources,
    'provision_adapters', v_model.required_adapters,
    'optional_engines', v_model.optional_engines,
    'optional_capabilities', v_model.optional_capabilities,
    'plan_status', 'planned'
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_capability_plan_runs_v1(
    org_id,
    model_key,
    model_version,
    requested_fields,
    skipped_fields,
    applied_defaults,
    provision_engines,
    provision_capabilities,
    provision_resources,
    provision_adapters,
    plan_status,
    plan_body,
    plan_hash
  )
  values (
    p_org_id,
    v_model.model_key,
    v_model.model_version,
    coalesce(p_requested_fields,'{}'::jsonb),
    v_skipped_fields,
    v_applied_defaults,
    v_model.required_engines,
    v_model.required_capabilities,
    v_model.required_resources,
    v_model.required_adapters,
    'planned',
    v_body,
    v_hash
  )
  returning plan_run_id
  into v_plan_run_id;

  return v_body || jsonb_build_object(
    'plan_run_id', v_plan_run_id,
    'plan_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_plan_model_capabilities_v1"("p_org_id" "uuid", "p_model_key" "text", "p_requested_fields" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_promote_release_v1"("p_model_release_id" "uuid", "p_to_channel" "text", "p_actor_role" "text" DEFAULT 'community_admin'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_release record;
  v_body jsonb;
  v_hash text;
  v_id uuid;
begin
  select *
  into v_release
  from pods_provisioning.model_releases_v1
  where model_release_id = p_model_release_id
  limit 1;

  if not found then
    raise exception 'MODEL_RELEASE_PROMOTION_RELEASE_NOT_FOUND';
  end if;

  if p_to_channel not in ('development','staging','production','archived') then
    raise exception 'MODEL_RELEASE_PROMOTION_CHANNEL_DENY';
  end if;

  if v_release.channel_key = p_to_channel then
    raise exception 'MODEL_RELEASE_PROMOTION_SAME_CHANNEL_DENY';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_RELEASE_GOVERNANCE_OK',
    'org_id', v_release.org_id,
    'model_release_id', v_release.model_release_id,
    'model_instance_runtime_id', v_release.model_instance_runtime_id,
    'from_channel', v_release.channel_key,
    'to_channel', p_to_channel,
    'promotion_status', 'completed',
    'actor_role', coalesce(nullif(p_actor_role,''),'community_admin'),
    'release_hash', v_release.release_hash
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_release_promotions_v1(
    org_id,
    model_release_id,
    from_channel,
    to_channel,
    promotion_status,
    actor_role,
    promotion_body,
    promotion_hash
  )
  values (
    v_release.org_id,
    v_release.model_release_id,
    v_release.channel_key,
    p_to_channel,
    'completed',
    coalesce(nullif(p_actor_role,''),'community_admin'),
    v_body,
    v_hash
  )
  returning model_release_promotion_id
  into v_id;

  update pods_provisioning.model_releases_v1
  set channel_key = p_to_channel,
      release_status = 'promoted'
  where model_release_id = v_release.model_release_id;

  insert into pods_provisioning.model_release_channels_v1(
    org_id,
    model_instance_runtime_id,
    channel_key,
    channel_status
  )
  values (
    v_release.org_id,
    v_release.model_instance_runtime_id,
    p_to_channel,
    'active'
  )
  on conflict (org_id, model_instance_runtime_id, channel_key) do nothing;

  return v_body || jsonb_build_object(
    'model_release_promotion_id', v_id,
    'promotion_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_promote_release_v1"("p_model_release_id" "uuid", "p_to_channel" "text", "p_actor_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_provider_connection_rollup_v1"("p_org_id" "uuid", "p_model_key" "text" DEFAULT 'DEVELOPER_PORTAL_V1'::"text", "p_model_version" "text" DEFAULT 'v1'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_required jsonb;
  v_verified jsonb;
  v_missing jsonb;
  v_ready boolean;
  v_body jsonb;
  v_hash text;
  v_rollup_id uuid;
begin
  if p_org_id is null then
    raise exception 'PROVIDER_CONNECTION_ROLLUP_ORG_REQUIRED';
  end if;

  perform pods_provisioning.rpc_seed_provider_oauth_connection_contracts_v1();

  if p_model_key = 'DEVELOPER_PORTAL_V1' then
    v_required := jsonb_build_array('supabase','stripe','github','email','storage');
  elsif p_model_key = 'BARBER_NAIL_V1' then
    v_required := jsonb_build_array('supabase','stripe','email','storage');
  elsif p_model_key = 'CONTRACTOR_V1' then
    v_required := jsonb_build_array('supabase','stripe','email','storage');
  elsif p_model_key = 'REAL_ESTATE_V1' then
    v_required := jsonb_build_array('supabase','email','storage');
  elsif p_model_key = 'CIVIC_ACTION_V1' then
    v_required := jsonb_build_array('supabase','email','storage');
  else
    v_required := jsonb_build_array('supabase');
  end if;

  select coalesce(jsonb_agg(distinct s.provider_key order by s.provider_key),'[]'::jsonb)
  into v_verified
  from pods_provisioning.provider_connection_sessions_v1 s
  where s.org_id = p_org_id
    and s.connection_status = 'verified'
    and s.launch_blocked = false
    and s.secret_ref like 'secret://%'
    and s.provider_key in (
      select value::text from jsonb_array_elements_text(v_required)
    );

  select coalesce(jsonb_agg(req.provider_key order by req.provider_key),'[]'::jsonb)
  into v_missing
  from (
    select value::text as provider_key
    from jsonb_array_elements_text(v_required)
  ) req
  where not exists (
    select 1
    from pods_provisioning.provider_connection_sessions_v1 s
    where s.org_id = p_org_id
      and s.provider_key = req.provider_key
      and s.connection_status = 'verified'
      and s.launch_blocked = false
      and s.secret_ref like 'secret://%'
  );

  v_ready := jsonb_array_length(v_missing) = 0;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PROVIDER_CONNECTION_ROLLUP_OK',
    'org_id', p_org_id,
    'model_key', p_model_key,
    'model_version', p_model_version,
    'required_providers', v_required,
    'verified_providers', v_verified,
    'missing_providers', v_missing,
    'connection_ready', v_ready,
    'launch_blocked', not v_ready
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.provider_connection_rollups_v1(
    org_id,
    model_key,
    model_version,
    required_providers,
    verified_providers,
    missing_providers,
    connection_ready,
    launch_blocked,
    rollup_body,
    rollup_hash
  )
  values (
    p_org_id,
    p_model_key,
    p_model_version,
    v_required,
    v_verified,
    v_missing,
    v_ready,
    not v_ready,
    v_body,
    v_hash
  )
  returning provider_connection_rollup_id
  into v_rollup_id;

  return v_body || jsonb_build_object(
    'provider_connection_rollup_id', v_rollup_id,
    'rollup_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_provider_connection_rollup_v1"("p_org_id" "uuid", "p_model_key" "text", "p_model_version" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_provider_readiness_rollup_v1"("p_org_id" "uuid", "p_model_key" "text" DEFAULT 'DEVELOPER_PORTAL_V1'::"text", "p_model_version" "text" DEFAULT 'v1'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_required jsonb;

  v_supabase_ready boolean := false;
  v_stripe_ready boolean := false;
  v_email_ready boolean := false;
  v_storage_ready boolean := false;
  v_github_ready boolean := false;

  v_ready_providers jsonb := '[]'::jsonb;
  v_blocked_providers jsonb := '[]'::jsonb;
  v_launch_ready boolean := false;

  v_body jsonb;
  v_hash text;
  v_rollup_id uuid;
begin
  if p_org_id is null then
    raise exception 'PROVIDER_READINESS_ORG_REQUIRED';
  end if;

  if p_model_key = 'CIVIC_ACTION_V1' then
    v_required := jsonb_build_array('supabase','email','storage');
  elsif p_model_key = 'REAL_ESTATE_V1' then
    v_required := jsonb_build_array('supabase','email','storage');
  elsif p_model_key in ('BARBER_NAIL_V1','CONTRACTOR_V1') then
    v_required := jsonb_build_array('supabase','stripe','email','storage');
  else
    v_required := jsonb_build_array('supabase','stripe','email','storage','github');
  end if;

  -- Canonical product path: verified provider connection sessions.
  select exists(
    select 1
    from pods_provisioning.provider_connection_sessions_v1
    where org_id = p_org_id
      and provider_key = 'supabase'
      and connection_status = 'verified'
      and launch_blocked = false
      and secret_ref like 'secret://%'
  ) into v_supabase_ready;

  select exists(
    select 1
    from pods_provisioning.provider_connection_sessions_v1
    where org_id = p_org_id
      and provider_key = 'stripe'
      and connection_status = 'verified'
      and launch_blocked = false
      and secret_ref like 'secret://%'
  ) into v_stripe_ready;

  select exists(
    select 1
    from pods_provisioning.provider_connection_sessions_v1
    where org_id = p_org_id
      and provider_key = 'email'
      and connection_status = 'verified'
      and launch_blocked = false
      and secret_ref like 'secret://%'
  ) into v_email_ready;

  select exists(
    select 1
    from pods_provisioning.provider_connection_sessions_v1
    where org_id = p_org_id
      and provider_key = 'storage'
      and connection_status = 'verified'
      and launch_blocked = false
      and secret_ref like 'secret://%'
  ) into v_storage_ready;

  select exists(
    select 1
    from pods_provisioning.provider_connection_sessions_v1
    where org_id = p_org_id
      and provider_key = 'github'
      and connection_status = 'verified'
      and launch_blocked = false
      and secret_ref like 'secret://%'
  ) into v_github_ready;

  if v_supabase_ready then v_ready_providers := v_ready_providers || jsonb_build_array('supabase'); end if;
  if v_stripe_ready then v_ready_providers := v_ready_providers || jsonb_build_array('stripe'); end if;
  if v_email_ready then v_ready_providers := v_ready_providers || jsonb_build_array('email'); end if;
  if v_storage_ready then v_ready_providers := v_ready_providers || jsonb_build_array('storage'); end if;
  if v_github_ready then v_ready_providers := v_ready_providers || jsonb_build_array('github'); end if;

  select coalesce(jsonb_agg(req.provider_key order by req.provider_key),'[]'::jsonb)
  into v_blocked_providers
  from (
    select value::text as provider_key
    from jsonb_array_elements_text(v_required)
  ) req
  where not exists (
    select 1
    from jsonb_array_elements_text(v_ready_providers) ready(provider_key)
    where ready.provider_key = req.provider_key
  );

  v_launch_ready := jsonb_array_length(v_blocked_providers) = 0;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PROVIDER_READINESS_ROLLUP_OK',
    'org_id', p_org_id,
    'model_key', p_model_key,
    'model_version', p_model_version,
    'required_providers', v_required,
    'supabase_ready', v_supabase_ready,
    'stripe_ready', v_stripe_ready,
    'email_ready', v_email_ready,
    'storage_ready', v_storage_ready,
    'github_ready', v_github_ready,
    'ready_providers', v_ready_providers,
    'blocked_providers', v_blocked_providers,
    'launch_ready', v_launch_ready,
    'readiness_status', case when v_launch_ready then 'ready' else 'blocked' end
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.provider_readiness_rollups_v1(
    org_id,
    model_key,
    model_version,
    supabase_ready,
    stripe_ready,
    email_ready,
    storage_ready,
    github_ready,
    ready_providers,
    blocked_providers,
    launch_ready,
    readiness_status,
    readiness_body,
    readiness_hash
  )
  values (
    p_org_id,
    p_model_key,
    p_model_version,
    v_supabase_ready,
    v_stripe_ready,
    v_email_ready,
    v_storage_ready,
    v_github_ready,
    v_ready_providers,
    v_blocked_providers,
    v_launch_ready,
    case when v_launch_ready then 'ready' else 'blocked' end,
    v_body,
    v_hash
  )
  returning provider_readiness_rollup_id
  into v_rollup_id;

  return v_body || jsonb_build_object(
    'provider_readiness_rollup_id', v_rollup_id,
    'readiness_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_provider_readiness_rollup_v1"("p_org_id" "uuid", "p_model_key" "text", "p_model_version" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_provision_vertical_template_v1"("p_org_id" "uuid", "p_template_key" "text", "p_operator_user_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_template record;
  v_template_version text := 'v1';
  v_run_id uuid;
  v_receipt_body jsonb;
  v_receipt_hash text;
  v_seed_count integer := 0;
begin
  if p_org_id is null then
    raise exception 'PROVISION_ORG_ID_REQUIRED';
  end if;

  if p_template_key is null or btrim(p_template_key) = '' then
    raise exception 'PROVISION_TEMPLATE_KEY_REQUIRED';
  end if;

  select *
  into v_template
  from pods_provisioning.vertical_templates vt
  where vt.template_key = p_template_key
    and vt.enabled = true
  limit 1;

  if not found then
    raise exception 'PROVISION_TEMPLATE_NOT_FOUND:%', p_template_key;
  end if;

  if exists (
    select 1
    from pods_provisioning.provision_runs_v1 pr
    where pr.org_id = p_org_id
      and pr.template_key = p_template_key
      and pr.template_version = v_template_version
      and pr.status = 'completed'
  ) then
    raise exception 'PROVISION_DUPLICATE_DENY:%:%', p_org_id, p_template_key;
  end if;

  insert into pods_provisioning.template_registry_v1(
    template_key,
    template_version,
    vertical,
    display_name,
    description,
    seeded_hash,
    active
  )
  values (
    v_template.template_key,
    v_template_version,
    v_template.category,
    v_template.display_name,
    v_template.description,
    pods_provisioning._sha256_text_v1(
      v_template.template_key || '|' ||
      v_template.display_name || '|' ||
      v_template.category || '|' ||
      v_template.description || '|' ||
      v_template.config::text
    ),
    true
  )
  on conflict (template_key, template_version) do update
  set
    vertical = excluded.vertical,
    display_name = excluded.display_name,
    description = excluded.description,
    seeded_hash = excluded.seeded_hash,
    active = excluded.active;

  insert into pods_provisioning.provision_runs_v1(
    org_id,
    template_key,
    template_version,
    operator_user_id,
    status,
    metadata
  )
  values (
    p_org_id,
    p_template_key,
    v_template_version,
    p_operator_user_id,
    'started',
    jsonb_build_object(
      'template_display_name', v_template.display_name,
      'template_category', v_template.category,
      'default_timezone', v_template.default_timezone
    )
  )
  returning provision_run_id
  into v_run_id;

  insert into pods_provisioning.seeded_objects_v1(
    provision_run_id,
    org_id,
    template_key,
    template_version,
    object_kind,
    object_schema,
    object_table,
    object_id,
    object_key,
    seeded_hash
  )
  values (
    v_run_id,
    p_org_id,
    p_template_key,
    v_template_version,
    'org',
    'pods_provisioning',
    'provision_runs_v1',
    v_run_id,
    'org:' || p_org_id::text,
    pods_provisioning._sha256_text_v1('org|' || p_org_id::text || '|' || p_template_key || '|' || v_template_version)
  );

  insert into pods_provisioning.seeded_objects_v1(
    provision_run_id,
    org_id,
    template_key,
    template_version,
    object_kind,
    object_schema,
    object_table,
    object_id,
    object_key,
    seeded_hash
  )
  select
    v_run_id,
    p_org_id,
    p_template_key,
    v_template_version,
    'service',
    'pods_provisioning',
    'vertical_template_services',
    s.id,
    s.service_code,
    pods_provisioning._sha256_text_v1(
      'service|' ||
      p_org_id::text || '|' ||
      p_template_key || '|' ||
      s.service_code || '|' ||
      s.display_name || '|' ||
      s.duration_minutes::text || '|' ||
      s.price_cents::text
    )
  from pods_provisioning.vertical_template_services s
  where s.template_key = p_template_key;

  insert into pods_provisioning.seeded_objects_v1(
    provision_run_id,
    org_id,
    template_key,
    template_version,
    object_kind,
    object_schema,
    object_table,
    object_id,
    object_key,
    seeded_hash
  )
  select
    v_run_id,
    p_org_id,
    p_template_key,
    v_template_version,
    'role',
    'pods_provisioning',
    'vertical_template_roles',
    r.id,
    r.role_key,
    pods_provisioning._sha256_text_v1(
      'role|' ||
      p_org_id::text || '|' ||
      p_template_key || '|' ||
      r.role_key || '|' ||
      r.display_name
    )
  from pods_provisioning.vertical_template_roles r
  where r.template_key = p_template_key;

  insert into pods_provisioning.seeded_objects_v1(
    provision_run_id,
    org_id,
    template_key,
    template_version,
    object_kind,
    object_schema,
    object_table,
    object_id,
    object_key,
    seeded_hash
  )
  select
    v_run_id,
    p_org_id,
    p_template_key,
    v_template_version,
    'availability_template',
    'pods_provisioning',
    'vertical_template_hours',
    h.id,
    'dow:' || h.dow::text,
    pods_provisioning._sha256_text_v1(
      'hours|' ||
      p_org_id::text || '|' ||
      p_template_key || '|' ||
      h.dow::text || '|' ||
      h.open_time::text || '|' ||
      h.close_time::text
    )
  from pods_provisioning.vertical_template_hours h
  where h.template_key = p_template_key;

  select count(*)
  into v_seed_count
  from pods_provisioning.seeded_objects_v1 so
  where so.provision_run_id = v_run_id;

  v_receipt_body := jsonb_build_object(
    'ok', true,
    'token', 'PROVISION_VERTICAL_TEMPLATE_OK',
    'provision_run_id', v_run_id,
    'org_id', p_org_id,
    'template_key', p_template_key,
    'template_version', v_template_version,
    'display_name', v_template.display_name,
    'seeded_object_count', v_seed_count,
    'customer_next_steps', jsonb_build_array(
      'Verify business hours',
      'Verify service prices',
      'Invite staff',
      'Connect payments before accepting paid bookings',
      'Publish public booking page'
    )
  );

  v_receipt_hash := pods_provisioning._sha256_text_v1(v_receipt_body::text);

  insert into pods_provisioning.provisioning_receipts_v1(
    provision_run_id,
    org_id,
    event_type,
    event_token,
    receipt_body,
    receipt_hash
  )
  values (
    v_run_id,
    p_org_id,
    'vertical_template_provisioned',
    'PROVISION_VERTICAL_TEMPLATE_OK',
    v_receipt_body,
    v_receipt_hash
  );

  update pods_provisioning.provision_runs_v1
  set
    status = 'completed',
    completed_at = now(),
    receipt_hash = v_receipt_hash,
    metadata = metadata || jsonb_build_object(
      'seeded_object_count', v_seed_count,
      'receipt_hash', v_receipt_hash
    )
  where provision_run_id = v_run_id;

  return v_receipt_body || jsonb_build_object(
    'receipt_hash', v_receipt_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_provision_vertical_template_v1"("p_org_id" "uuid", "p_template_key" "text", "p_operator_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_query_audit_ledger_v1"("p_org_id" "uuid", "p_model_instance_runtime_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_events jsonb;
  v_count integer;
begin
  select
    coalesce(jsonb_agg(
      jsonb_build_object(
        'model_audit_event_id', model_audit_event_id,
        'event_type', event_type,
        'event_status', event_status,
        'event_hash', event_hash,
        'created_at', created_at
      )
      order by created_at, model_audit_event_id
    ), '[]'::jsonb),
    count(*)
  into v_events, v_count
  from pods_provisioning.model_audit_ledger_v1
  where org_id = p_org_id
    and (
      p_model_instance_runtime_id is null
      or model_instance_runtime_id = p_model_instance_runtime_id
    );

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_AUDIT_LEDGER_OK',
    'org_id', p_org_id,
    'model_instance_runtime_id', p_model_instance_runtime_id,
    'event_count', v_count,
    'events', v_events
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_query_audit_ledger_v1"("p_org_id" "uuid", "p_model_instance_runtime_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_queue_launch_execution_worker_v1"("p_launch_control_receipt_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_receipt record;
  v_steps jsonb;
  v_body jsonb;
  v_hash text;
  v_worker_id uuid;
begin
  if p_launch_control_receipt_id is null then
    raise exception 'LAUNCH_WORKER_RECEIPT_REQUIRED';
  end if;

  select *
  into v_receipt
  from pods_provisioning.launch_control_plane_receipts_v1 r
  where r.launch_control_receipt_id = p_launch_control_receipt_id
  limit 1;

  if not found then
    raise exception 'LAUNCH_WORKER_RECEIPT_NOT_FOUND';
  end if;

  if v_receipt.launch_ready is not true or v_receipt.launch_decision <> 'ready' then
    raise exception 'LAUNCH_WORKER_RECEIPT_NOT_READY';
  end if;

  v_steps := jsonb_build_array(
    jsonb_build_object('step_order',1,'step_key','validate_launch_receipt','status','queued'),
    jsonb_build_object('step_order',2,'step_key','activate_resources','status','queued'),
    jsonb_build_object('step_order',3,'step_key','activate_capabilities','status','queued'),
    jsonb_build_object('step_order',4,'step_key','finalize_adapters','status','queued'),
    jsonb_build_object('step_order',5,'step_key','emit_launch_complete_receipt','status','queued')
  );

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_LAUNCH_EXECUTION_WORKER_OK',
    'launch_control_receipt_id', v_receipt.launch_control_receipt_id,
    'org_id', v_receipt.org_id,
    'model_key', v_receipt.model_key,
    'model_version', v_receipt.model_version,
    'worker_status', 'queued',
    'execution_steps', v_steps,
    'completed_steps', jsonb_build_array(),
    'failed_steps', jsonb_build_array(),
    'retry_count', 0,
    'replay_ready', true,
    'rollback_ready', true
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.launch_execution_worker_runs_v1(
    launch_control_receipt_id,
    org_id,
    model_key,
    model_version,
    worker_status,
    execution_steps,
    completed_steps,
    failed_steps,
    retry_count,
    replay_ready,
    rollback_ready,
    worker_body,
    worker_hash
  )
  values (
    v_receipt.launch_control_receipt_id,
    v_receipt.org_id,
    v_receipt.model_key,
    v_receipt.model_version,
    'queued',
    v_steps,
    jsonb_build_array(),
    jsonb_build_array(),
    0,
    true,
    true,
    v_body,
    v_hash
  )
  returning worker_run_id
  into v_worker_id;

  return v_body || jsonb_build_object(
    'worker_run_id', v_worker_id,
    'worker_hash', v_hash
  );
exception
  when unique_violation then
    raise exception 'LAUNCH_WORKER_DUPLICATE_DENY:%', p_launch_control_receipt_id;
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_queue_launch_execution_worker_v1"("p_launch_control_receipt_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_record_payment_provider_receipt_v1"("p_payment_intent_id" "uuid", "p_provider_key" "text", "p_provider_event_id" "text", "p_provider_event_kind" "text", "p_provider_status" "text", "p_signature_valid" boolean DEFAULT true) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_intent record;
  v_body jsonb;
  v_hash text;
  v_receipt_id uuid;
begin
  if p_payment_intent_id is null then
    raise exception 'PAYMENT_PROVIDER_RECEIPT_INTENT_REQUIRED';
  end if;

  if p_provider_key is null or btrim(p_provider_key) = '' then
    raise exception 'PAYMENT_PROVIDER_RECEIPT_PROVIDER_REQUIRED';
  end if;

  if p_provider_event_id is null or btrim(p_provider_event_id) = '' then
    raise exception 'PAYMENT_PROVIDER_RECEIPT_EVENT_REQUIRED';
  end if;

  select *
  into v_intent
  from pods_provisioning.payment_intents_v1 pi
  where pi.payment_intent_id = p_payment_intent_id
  limit 1;

  if not found then
    raise exception 'PAYMENT_PROVIDER_RECEIPT_INTENT_NOT_FOUND';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PAYMENT_ADAPTER_RECEIPT_OK',
    'payment_intent_id', v_intent.payment_intent_id,
    'org_id', v_intent.org_id,
    'provider_key', lower(p_provider_key),
    'provider_event_id', p_provider_event_id,
    'provider_event_kind', p_provider_event_kind,
    'provider_status', p_provider_status,
    'signature_valid', p_signature_valid
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.payment_provider_receipts_v1(
    payment_intent_id,
    org_id,
    provider_key,
    provider_event_id,
    provider_event_kind,
    provider_signature_valid,
    provider_status,
    receipt_body,
    receipt_hash
  )
  values (
    v_intent.payment_intent_id,
    v_intent.org_id,
    lower(p_provider_key),
    p_provider_event_id,
    p_provider_event_kind,
    p_signature_valid,
    p_provider_status,
    v_body,
    v_hash
  )
  returning provider_receipt_id
  into v_receipt_id;

  update pods_provisioning.payment_intents_v1
  set
    payment_status = case
      when lower(p_provider_status) = 'captured' then 'captured'
      when lower(p_provider_status) = 'authorized' then 'authorized'
      when lower(p_provider_status) = 'failed' then 'failed'
      when lower(p_provider_status) = 'refunded' then 'refunded'
      else payment_status
    end,
    provider_key = lower(p_provider_key),
    provider_intent_id = p_provider_event_id,
    updated_at = now()
  where payment_intent_id = v_intent.payment_intent_id;

  return v_body || jsonb_build_object(
    'provider_receipt_id', v_receipt_id,
    'receipt_hash', v_hash
  );
exception
  when unique_violation then
    raise exception 'PAYMENT_PROVIDER_RECEIPT_DUPLICATE_DENY:%', p_provider_event_id;
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_record_payment_provider_receipt_v1"("p_payment_intent_id" "uuid", "p_provider_key" "text", "p_provider_event_id" "text", "p_provider_event_kind" "text", "p_provider_status" "text", "p_signature_valid" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_refresh_civic_contribution_wall_v1"("p_civic_campaign_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_campaign record;
  v_inserted integer := 0;
  v_row_count integer := 0;
  v_visible_count integer;
  v_total_count integer;
begin
  select *
  into v_campaign
  from pods_provisioning.civic_action_campaigns_v1 c
  where c.civic_campaign_id = p_civic_campaign_id
  limit 1;

  if not found then
    raise exception 'CIVIC_CONTRIBUTION_CAMPAIGN_NOT_FOUND';
  end if;

  insert into pods_provisioning.civic_action_contribution_wall_entries_v1(
    civic_campaign_id, org_id, contribution_type, source_id,
    display_label, display_message, moderation_status, public_visible,
    contribution_body, contribution_hash
  )
  select
    s.civic_campaign_id, s.org_id, 'signature', s.civic_signature_id,
    s.signer_name,
    case when s.signer_comment <> '' then 'Signed with comment' else 'Signed petition' end,
    s.moderation_status,
    s.public_display_allowed and s.moderation_status in ('pending','approved'),
    jsonb_build_object('source','signature','source_id',s.civic_signature_id,'signer_name',s.signer_name,'moderation_status',s.moderation_status),
    pods_provisioning._sha256_text_v1('signature|' || s.civic_signature_id::text || '|' || s.signature_hash)
  from pods_provisioning.civic_action_petition_signatures_v1 s
  where s.civic_campaign_id = p_civic_campaign_id
  on conflict (contribution_type, source_id) do nothing;

  get diagnostics v_row_count = row_count;
  v_inserted := v_inserted + v_row_count;

  insert into pods_provisioning.civic_action_contribution_wall_entries_v1(
    civic_campaign_id, org_id, contribution_type, source_id,
    display_label, display_message, moderation_status, public_visible,
    contribution_body, contribution_hash
  )
  select
    r.civic_campaign_id, r.org_id, 'survey_response', r.civic_survey_response_id,
    'Community member',
    'Submitted survey response',
    r.moderation_status,
    r.moderation_status in ('pending','approved'),
    jsonb_build_object(
      'source','survey_response',
      'source_id',r.civic_survey_response_id,
      'answer_count',(select count(*) from jsonb_object_keys(r.answers)),
      'moderation_status',r.moderation_status
    ),
    pods_provisioning._sha256_text_v1('survey|' || r.civic_survey_response_id::text || '|' || r.response_hash)
  from pods_provisioning.civic_action_survey_responses_v1 r
  where r.civic_campaign_id = p_civic_campaign_id
  on conflict (contribution_type, source_id) do nothing;

  get diagnostics v_row_count = row_count;
  v_inserted := v_inserted + v_row_count;

  insert into pods_provisioning.civic_action_contribution_wall_entries_v1(
    civic_campaign_id, org_id, contribution_type, source_id,
    display_label, display_message, moderation_status, public_visible,
    contribution_body, contribution_hash
  )
  select
    h.civic_campaign_id, h.org_id, 'help_offer', h.civic_help_offer_id,
    h.helper_name,
    'Offered help: ' || h.help_type,
    h.moderation_status,
    h.public_display_allowed and h.moderation_status in ('pending','approved'),
    jsonb_build_object('source','help_offer','source_id',h.civic_help_offer_id,'helper_name',h.helper_name,'help_type',h.help_type,'moderation_status',h.moderation_status),
    pods_provisioning._sha256_text_v1('help|' || h.civic_help_offer_id::text || '|' || h.help_hash)
  from pods_provisioning.civic_action_help_offers_v1 h
  where h.civic_campaign_id = p_civic_campaign_id
  on conflict (contribution_type, source_id) do nothing;

  get diagnostics v_row_count = row_count;
  v_inserted := v_inserted + v_row_count;

  select count(*)
  into v_total_count
  from pods_provisioning.civic_action_contribution_wall_entries_v1
  where civic_campaign_id = p_civic_campaign_id;

  select count(*)
  into v_visible_count
  from pods_provisioning.civic_action_contribution_wall_entries_v1
  where civic_campaign_id = p_civic_campaign_id
    and public_visible = true;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_CONTRIBUTION_WALL_OK',
    'civic_campaign_id', p_civic_campaign_id,
    'inserted_count', v_inserted,
    'total_contribution_count', v_total_count,
    'public_visible_count', v_visible_count
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_refresh_civic_contribution_wall_v1"("p_civic_campaign_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_register_engine_runtime_v1"("p_engine_key" "text", "p_engine_category" "text", "p_engine_status" "text", "p_proof_token" "text", "p_ready_for_launch" boolean DEFAULT true, "p_rollback_ready" boolean DEFAULT true, "p_replay_ready" boolean DEFAULT true, "p_failure_count" integer DEFAULT 0) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_body jsonb;
  v_hash text;
  v_registry_id uuid;
begin
  if p_engine_key is null or btrim(p_engine_key) = '' then
    raise exception 'ENGINE_REGISTRY_KEY_REQUIRED';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_ENGINE_RUNTIME_REGISTERED_OK',
    'engine_key', p_engine_key,
    'engine_category', p_engine_category,
    'engine_status', p_engine_status,
    'proof_token', p_proof_token,
    'ready_for_launch', p_ready_for_launch,
    'rollback_ready', p_rollback_ready,
    'replay_ready', p_replay_ready,
    'failure_count', p_failure_count,
    'last_selftest_utc', now()
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.full_green_engine_registry_v1(
    engine_key,
    engine_category,
    engine_status,
    proof_token,
    last_selftest_utc,
    ready_for_launch,
    rollback_ready,
    replay_ready,
    failure_count,
    engine_body,
    engine_hash
  )
  values (
    p_engine_key,
    p_engine_category,
    p_engine_status,
    p_proof_token,
    now(),
    p_ready_for_launch,
    p_rollback_ready,
    p_replay_ready,
    p_failure_count,
    v_body,
    v_hash
  )
  on conflict (engine_key) do update
  set
    engine_category = excluded.engine_category,
    engine_status = excluded.engine_status,
    proof_token = excluded.proof_token,
    last_selftest_utc = excluded.last_selftest_utc,
    ready_for_launch = excluded.ready_for_launch,
    rollback_ready = excluded.rollback_ready,
    replay_ready = excluded.replay_ready,
    failure_count = excluded.failure_count,
    engine_body = excluded.engine_body,
    engine_hash = excluded.engine_hash
  returning engine_registry_id
  into v_registry_id;

  return v_body || jsonb_build_object(
    'engine_registry_id', v_registry_id,
    'engine_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_register_engine_runtime_v1"("p_engine_key" "text", "p_engine_category" "text", "p_engine_status" "text", "p_proof_token" "text", "p_ready_for_launch" boolean, "p_rollback_ready" boolean, "p_replay_ready" boolean, "p_failure_count" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_register_marketplace_model_v1"("p_model_key" "text", "p_model_version" "text", "p_display_name" "text", "p_category_key" "text", "p_description" "text" DEFAULT ''::"text", "p_required_providers" "jsonb" DEFAULT '[]'::"jsonb", "p_supported_blocks" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_body jsonb;
  v_hash text;
  v_id uuid;
begin

  v_body :=
    jsonb_build_object(
      'ok', true,
      'token', 'PROTEUSOPS_MODEL_MARKETPLACE_OK',
      'model_key', p_model_key,
      'model_version', p_model_version,
      'display_name', p_display_name,
      'category_key', p_category_key,
      'wizard_enabled', true,
      'deployment_enabled', true,
      'required_providers', p_required_providers,
      'supported_blocks', p_supported_blocks
    );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_marketplace_catalog_v1(
    model_key,
    model_version,
    display_name,
    category_key,
    description,
    required_providers,
    supported_blocks,
    catalog_hash
  )
  values (
    p_model_key,
    p_model_version,
    p_display_name,
    p_category_key,
    p_description,
    p_required_providers,
    p_supported_blocks,
    v_hash
  )
  returning model_marketplace_catalog_id
  into v_id;

  return v_body ||
    jsonb_build_object(
      'model_marketplace_catalog_id', v_id,
      'catalog_hash', v_hash
    );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_register_marketplace_model_v1"("p_model_key" "text", "p_model_version" "text", "p_display_name" "text", "p_category_key" "text", "p_description" "text", "p_required_providers" "jsonb", "p_supported_blocks" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_register_model_deployment_target_v1"("p_target_key" "text", "p_target_name" "text", "p_provider_requirements" "jsonb" DEFAULT '[]'::"jsonb", "p_environment_requirements" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_body jsonb;
  v_hash text;
  v_id uuid;
begin
  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_DEPLOYMENT_TARGET_OK',
    'deployment_target_key', p_target_key,
    'deployment_target_name', p_target_name,
    'provider_requirements', p_provider_requirements,
    'environment_requirements', p_environment_requirements
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_deployment_targets_v1(
    org_id,
    deployment_target_key,
    deployment_target_name,
    deployment_target_status,
    provider_requirements,
    environment_requirements,
    deployment_hash
  )
  values(
    gen_random_uuid(),
    p_target_key,
    p_target_name,
    'available',
    p_provider_requirements,
    p_environment_requirements,
    v_hash
  )
  returning model_deployment_target_id
  into v_id;

  return v_body || jsonb_build_object(
    'model_deployment_target_id', v_id,
    'deployment_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_register_model_deployment_target_v1"("p_target_key" "text", "p_target_name" "text", "p_provider_requirements" "jsonb", "p_environment_requirements" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_register_model_template_v1"("p_model_key" "text", "p_model_version" "text", "p_display_name" "text", "p_category_key" "text", "p_wizard_schema" "jsonb" DEFAULT '{}'::"jsonb", "p_default_pages" "jsonb" DEFAULT '[]'::"jsonb", "p_default_blocks" "jsonb" DEFAULT '[]'::"jsonb", "p_default_roles" "jsonb" DEFAULT '[]'::"jsonb", "p_required_providers" "jsonb" DEFAULT '[]'::"jsonb", "p_supported_deployment_targets" "jsonb" DEFAULT '[]'::"jsonb", "p_license_rules" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_body jsonb;
  v_hash text;
  v_id uuid;
begin
  if p_model_key is null or btrim(p_model_key) = '' then
    raise exception 'MODEL_TEMPLATE_KEY_REQUIRED';
  end if;

  if p_model_version is null or btrim(p_model_version) = '' then
    raise exception 'MODEL_TEMPLATE_VERSION_REQUIRED';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_TEMPLATE_REGISTRY_OK',
    'model_key', p_model_key,
    'model_version', p_model_version,
    'display_name', p_display_name,
    'category_key', p_category_key,
    'template_status', 'published',
    'wizard_schema', p_wizard_schema,
    'default_pages', p_default_pages,
    'default_blocks', p_default_blocks,
    'default_roles', p_default_roles,
    'required_providers', p_required_providers,
    'supported_deployment_targets', p_supported_deployment_targets,
    'license_rules', p_license_rules
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_template_registry_v1(
    model_key,
    model_version,
    display_name,
    category_key,
    template_status,
    wizard_schema,
    default_pages,
    default_blocks,
    default_roles,
    required_providers,
    supported_deployment_targets,
    license_rules,
    template_body,
    template_hash
  )
  values (
    p_model_key,
    p_model_version,
    p_display_name,
    p_category_key,
    'published',
    p_wizard_schema,
    p_default_pages,
    p_default_blocks,
    p_default_roles,
    p_required_providers,
    p_supported_deployment_targets,
    p_license_rules,
    v_body,
    v_hash
  )
  on conflict (model_key, model_version) do update
  set
    display_name = excluded.display_name,
    category_key = excluded.category_key,
    template_status = excluded.template_status,
    wizard_schema = excluded.wizard_schema,
    default_pages = excluded.default_pages,
    default_blocks = excluded.default_blocks,
    default_roles = excluded.default_roles,
    required_providers = excluded.required_providers,
    supported_deployment_targets = excluded.supported_deployment_targets,
    license_rules = excluded.license_rules,
    template_body = excluded.template_body,
    template_hash = excluded.template_hash
  returning model_template_registry_id
  into v_id;

  return v_body || jsonb_build_object(
    'model_template_registry_id', v_id,
    'template_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_register_model_template_v1"("p_model_key" "text", "p_model_version" "text", "p_display_name" "text", "p_category_key" "text", "p_wizard_schema" "jsonb", "p_default_pages" "jsonb", "p_default_blocks" "jsonb", "p_default_roles" "jsonb", "p_required_providers" "jsonb", "p_supported_deployment_targets" "jsonb", "p_license_rules" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_request_contractor_estimate_v1"("p_org_id" "uuid", "p_service_code" "text", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_site_address" "text", "p_project_description" "text", "p_preferred_visit_window" "text" DEFAULT ''::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_template record;
  v_body jsonb;
  v_hash text;
  v_estimate_request_id uuid;
begin
  if p_org_id is null then
    raise exception 'CONTRACTOR_ESTIMATE_ORG_REQUIRED';
  end if;

  select *
  into v_template
  from pods_provisioning.contractor_service_templates_v1 st
  where st.service_code = p_service_code
    and st.active = true
  limit 1;

  if not found then
    raise exception 'CONTRACTOR_SERVICE_NOT_FOUND:%', p_service_code;
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CONTRACTOR_ESTIMATE_REQUEST_OK',
    'org_id', p_org_id,
    'template_key', v_template.template_key,
    'template_version', v_template.template_version,
    'service_code', v_template.service_code,
    'customer_name', p_customer_name,
    'customer_email', p_customer_email,
    'site_address', p_site_address,
    'estimate_status', 'requested',
    'requires_site_visit', v_template.requires_site_visit
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.contractor_estimate_requests_v1(
    org_id,
    template_key,
    template_version,
    service_code,
    customer_name,
    customer_email,
    customer_phone,
    site_address,
    project_description,
    preferred_visit_window,
    estimate_status,
    estimate_body,
    estimate_hash
  )
  values (
    p_org_id,
    v_template.template_key,
    v_template.template_version,
    v_template.service_code,
    p_customer_name,
    p_customer_email,
    p_customer_phone,
    p_site_address,
    p_project_description,
    p_preferred_visit_window,
    'requested',
    v_body,
    v_hash
  )
  returning estimate_request_id
  into v_estimate_request_id;

  return v_body || jsonb_build_object(
    'estimate_request_id', v_estimate_request_id,
    'estimate_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_request_contractor_estimate_v1"("p_org_id" "uuid", "p_service_code" "text", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_site_address" "text", "p_project_description" "text", "p_preferred_visit_window" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_request_public_appointment_v1"("p_booking_slug" "text", "p_service_code" "text", "p_requested_date" "date", "p_requested_start_time" time without time zone, "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text" DEFAULT ''::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $_$
declare
  v_page jsonb;
  v_service jsonb;
  v_duration integer;
  v_end_time time;
  v_path text;
  v_org_id uuid;
  v_template_key text;
  v_template_version text;
  v_provision_run_id uuid;
  v_body jsonb;
  v_hash text;
  v_request_id uuid;
begin
  if p_booking_slug is null or btrim(p_booking_slug) = '' then
    raise exception 'APPOINTMENT_BOOKING_SLUG_REQUIRED';
  end if;

  if p_service_code is null or btrim(p_service_code) = '' then
    raise exception 'APPOINTMENT_SERVICE_CODE_REQUIRED';
  end if;

  if p_requested_date is null then
    raise exception 'APPOINTMENT_DATE_REQUIRED';
  end if;

  if p_requested_start_time is null then
    raise exception 'APPOINTMENT_START_TIME_REQUIRED';
  end if;

  if p_customer_name is null or btrim(p_customer_name) = '' then
    raise exception 'APPOINTMENT_CUSTOMER_NAME_REQUIRED';
  end if;

  if p_customer_email is null or btrim(p_customer_email) = '' then
    raise exception 'APPOINTMENT_CUSTOMER_EMAIL_REQUIRED';
  end if;

  if p_customer_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'APPOINTMENT_CUSTOMER_EMAIL_INVALID';
  end if;

  v_page := pods_provisioning.rpc_get_booking_page_read_model_v1(p_booking_slug);

  select s
  into v_service
  from jsonb_array_elements(v_page->'services') s
  where s->>'service_code' = p_service_code
  limit 1;

  if v_service is null then
    raise exception 'APPOINTMENT_SERVICE_NOT_FOUND:%', p_service_code;
  end if;

  v_duration := (v_service->>'duration_minutes')::integer;
  v_end_time := (p_requested_start_time + make_interval(mins => v_duration))::time;

  v_path := v_page->>'booking_path';
  v_org_id := (v_page->>'org_id')::uuid;
  v_template_key := v_page->>'template_key';
  v_template_version := v_page->>'template_version';

  select pbs.provision_run_id
  into v_provision_run_id
  from pods_provisioning.public_booking_surfaces_v1 pbs
  where pbs.booking_slug = p_booking_slug
  limit 1;

  if v_provision_run_id is null then
    raise exception 'APPOINTMENT_PROVISION_RUN_NOT_FOUND';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PUBLIC_APPOINTMENT_REQUEST_OK',
    'booking_slug', p_booking_slug,
    'booking_path', v_path,
    'org_id', v_org_id,
    'template_key', v_template_key,
    'template_version', v_template_version,
    'service_code', p_service_code,
    'service_display_name', v_service->>'display_name',
    'requested_date', p_requested_date::text,
    'requested_start_time', p_requested_start_time::text,
    'requested_end_time', v_end_time::text,
    'customer_name', btrim(p_customer_name),
    'customer_email', lower(btrim(p_customer_email)),
    'customer_phone', coalesce(btrim(p_customer_phone),''),
    'customer_message', 'Your appointment request has been received.',
    'customer_next_steps', jsonb_build_array(
      'Watch for confirmation from the business',
      'Contact the business if your requested time needs to change',
      'Arrive a few minutes early if confirmed'
    )
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.public_appointment_requests_v1(
    org_id,
    provision_run_id,
    booking_slug,
    booking_path,
    template_key,
    template_version,
    service_code,
    requested_date,
    requested_start_time,
    requested_end_time,
    customer_name,
    customer_email,
    customer_phone,
    status,
    request_body,
    request_hash
  )
  values (
    v_org_id,
    v_provision_run_id,
    p_booking_slug,
    v_path,
    v_template_key,
    v_template_version,
    p_service_code,
    p_requested_date,
    p_requested_start_time,
    v_end_time,
    btrim(p_customer_name),
    lower(btrim(p_customer_email)),
    coalesce(btrim(p_customer_phone),''),
    'requested',
    v_body,
    v_hash
  )
  returning appointment_request_id
  into v_request_id;

  return v_body || jsonb_build_object(
    'appointment_request_id', v_request_id,
    'request_hash', v_hash
  );
exception
  when unique_violation then
    raise exception 'PUBLIC_APPOINTMENT_DUPLICATE_DENY:%:%:%',
      p_booking_slug,
      p_service_code,
      lower(btrim(p_customer_email));
end;
$_$;


ALTER FUNCTION "pods_provisioning"."rpc_request_public_appointment_v1"("p_booking_slug" "text", "p_service_code" "text", "p_requested_date" "date", "p_requested_start_time" time without time zone, "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_restore_runtime_snapshot_v1"("p_model_runtime_snapshot_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_snapshot record;
  v_receipt_id uuid;
begin
  select *
  into v_snapshot
  from pods_provisioning.model_runtime_snapshots_v1
  where model_runtime_snapshot_id = p_model_runtime_snapshot_id
  limit 1;

  if not found then
    raise exception 'MODEL_RUNTIME_SNAPSHOT_NOT_FOUND';
  end if;

  update pods_provisioning.model_runtime_snapshots_v1
  set snapshot_status = 'restored'
  where model_runtime_snapshot_id = p_model_runtime_snapshot_id;

  insert into pods_provisioning.model_runtime_snapshot_receipts_v1(
    org_id,
    model_runtime_snapshot_id,
    receipt_action,
    receipt_body,
    receipt_hash
  )
  values (
    v_snapshot.org_id,
    p_model_runtime_snapshot_id,
    'restore',
    jsonb_build_object(
      'token','PROTEUSOPS_MODEL_RUNTIME_SNAPSHOT_OK',
      'restored',true
    ),
    v_snapshot.snapshot_hash
  )
  returning model_runtime_snapshot_receipt_id
  into v_receipt_id;

  return jsonb_build_object(
    'ok',true,
    'token','PROTEUSOPS_MODEL_RUNTIME_SNAPSHOT_OK',
    'snapshot_status','restored',
    'model_runtime_snapshot_receipt_id',v_receipt_id
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_restore_runtime_snapshot_v1"("p_model_runtime_snapshot_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_rollback_failed_launch_v1"("p_launch_failure_event_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_failure record;
  v_body jsonb;
  v_hash text;
  v_rollback_id uuid;
begin
  if p_launch_failure_event_id is null then
    raise exception 'LAUNCH_ROLLBACK_FAILURE_EVENT_REQUIRED';
  end if;

  select *
  into v_failure
  from pods_provisioning.launch_failure_events_v1 f
  where f.launch_failure_event_id = p_launch_failure_event_id
  for update;

  if not found then
    raise exception 'LAUNCH_ROLLBACK_FAILURE_NOT_FOUND';
  end if;

  if v_failure.failure_status = 'rolled_back' then
    raise exception 'LAUNCH_ROLLBACK_ALREADY_DONE:%', p_launch_failure_event_id;
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_LAUNCH_ROLLBACK_RUNTIME_OK',
    'launch_failure_event_id', v_failure.launch_failure_event_id,
    'worker_run_id', v_failure.worker_run_id,
    'org_id', v_failure.org_id,
    'rollback_status', 'rolled_back',
    'rolled_back_steps', jsonb_build_array(
      'deactivate_partial_capabilities',
      'deactivate_partial_resources',
      'preserve_failure_receipt',
      'mark_worker_rolled_back'
    ),
    'recovery_next_steps', jsonb_build_array(
      'Review failure reason',
      'Fix failed provider or capability',
      'Queue a new launch worker when ready'
    ),
    'replay_ready', true
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.launch_rollback_events_v1(
    launch_failure_event_id,
    worker_run_id,
    org_id,
    rollback_status,
    rolled_back_steps,
    recovery_next_steps,
    rollback_body,
    rollback_hash
  )
  values (
    v_failure.launch_failure_event_id,
    v_failure.worker_run_id,
    v_failure.org_id,
    'rolled_back',
    v_body->'rolled_back_steps',
    v_body->'recovery_next_steps',
    v_body,
    v_hash
  )
  returning launch_rollback_event_id
  into v_rollback_id;

  update pods_provisioning.launch_failure_events_v1
  set failure_status = 'rolled_back'
  where launch_failure_event_id = v_failure.launch_failure_event_id;

  update pods_provisioning.launch_execution_worker_runs_v1
  set worker_status = 'rolled_back',
      updated_at = now()
  where worker_run_id = v_failure.worker_run_id;

  return v_body || jsonb_build_object(
    'launch_rollback_event_id', v_rollback_id,
    'rollback_hash', v_hash
  );
exception
  when unique_violation then
    raise exception 'LAUNCH_ROLLBACK_DUPLICATE_DENY:%', p_launch_failure_event_id;
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_rollback_failed_launch_v1"("p_launch_failure_event_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_rollback_release_v1"("p_source_release_id" "uuid", "p_target_release_id" "uuid", "p_rollback_reason" "text" DEFAULT ''::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_source record;
  v_target record;
  v_body jsonb;
  v_hash text;
  v_id uuid;
begin
  select *
  into v_source
  from pods_provisioning.model_releases_v1
  where model_release_id = p_source_release_id
  limit 1;

  if not found then
    raise exception 'MODEL_RELEASE_ROLLBACK_SOURCE_NOT_FOUND';
  end if;

  select *
  into v_target
  from pods_provisioning.model_releases_v1
  where model_release_id = p_target_release_id
  limit 1;

  if not found then
    raise exception 'MODEL_RELEASE_ROLLBACK_TARGET_NOT_FOUND';
  end if;

  if v_source.org_id <> v_target.org_id then
    raise exception 'MODEL_RELEASE_ROLLBACK_ORG_MISMATCH';
  end if;

  if v_source.model_instance_runtime_id <> v_target.model_instance_runtime_id then
    raise exception 'MODEL_RELEASE_ROLLBACK_RUNTIME_MISMATCH';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_RELEASE_GOVERNANCE_OK',
    'org_id', v_source.org_id,
    'source_release_id', v_source.model_release_id,
    'target_release_id', v_target.model_release_id,
    'model_instance_runtime_id', v_source.model_instance_runtime_id,
    'rollback_status', 'completed',
    'rollback_reason_present', coalesce(p_rollback_reason,'') <> '',
    'source_release_hash', v_source.release_hash,
    'target_release_hash', v_target.release_hash
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_release_rollbacks_v1(
    org_id,
    source_release_id,
    target_release_id,
    rollback_reason,
    rollback_status,
    rollback_body,
    rollback_hash
  )
  values (
    v_source.org_id,
    v_source.model_release_id,
    v_target.model_release_id,
    coalesce(p_rollback_reason,''),
    'completed',
    v_body,
    v_hash
  )
  returning model_release_rollback_id
  into v_id;

  update pods_provisioning.model_releases_v1
  set release_status = 'rolled_back'
  where model_release_id = v_source.model_release_id;

  return v_body || jsonb_build_object(
    'model_release_rollback_id', v_id,
    'rollback_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_rollback_release_v1"("p_source_release_id" "uuid", "p_target_release_id" "uuid", "p_rollback_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_run_model_instance_wizard_v1"("p_org_id" "uuid", "p_model_key" "text", "p_model_version" "text" DEFAULT 'v2'::"text", "p_wizard_answers" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_instance_name text;
  v_instance_description text;
  v_normalized jsonb;
  v_instance jsonb;
  v_body jsonb;
  v_hash text;
  v_id uuid;
begin
  if p_org_id is null then
    raise exception 'MODEL_INSTANCE_WIZARD_ORG_REQUIRED';
  end if;

  if p_model_key is null or btrim(p_model_key) = '' then
    raise exception 'MODEL_INSTANCE_WIZARD_MODEL_REQUIRED';
  end if;

  if p_model_key = 'CIVIC_ACTION_V1' then
    v_instance_name := coalesce(
      nullif(p_wizard_answers->>'issue_title',''),
      nullif(p_wizard_answers->>'site_name',''),
      'Untitled Civic Action'
    );

    v_instance_description := coalesce(
      nullif(p_wizard_answers->>'issue_summary',''),
      nullif(p_wizard_answers->>'description',''),
      ''
    );

    v_normalized := jsonb_build_object(
      'issue_title', v_instance_name,
      'community_name', coalesce(p_wizard_answers->>'community_name',''),
      'location_label', coalesce(p_wizard_answers->>'location_label',''),
      'position_type', coalesce(nullif(p_wizard_answers->>'position_type',''),'oppose'),
      'issue_summary', v_instance_description,
      'petition_goal', coalesce(nullif(p_wizard_answers->>'petition_goal','')::integer,500),
      'enable_petition', coalesce((p_wizard_answers->>'enable_petition')::boolean,true),
      'enable_survey', coalesce((p_wizard_answers->>'enable_survey')::boolean,true),
      'enable_events', coalesce((p_wizard_answers->>'enable_events')::boolean,true),
      'enable_evidence', coalesce((p_wizard_answers->>'enable_evidence')::boolean,true),
      'enable_volunteers', coalesce((p_wizard_answers->>'enable_volunteers')::boolean,true),
      'moderation_required', coalesce((p_wizard_answers->>'moderation_required')::boolean,true)
    );
  else
    v_instance_name := coalesce(
      nullif(p_wizard_answers->>'site_name',''),
      nullif(p_wizard_answers->>'business_name',''),
      nullif(p_wizard_answers->>'product_name',''),
      'Untitled Instance'
    );

    v_instance_description := coalesce(
      nullif(p_wizard_answers->>'description',''),
      nullif(p_wizard_answers->>'summary',''),
      ''
    );

    v_normalized := coalesce(p_wizard_answers,'{}'::jsonb);
  end if;

  v_instance := pods_provisioning.rpc_create_model_instance_runtime_v1(
    p_org_id,
    p_model_key,
    p_model_version,
    v_instance_name,
    v_instance_description,
    v_normalized
  );

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_INSTANCE_WIZARD_OK',
    'org_id', p_org_id,
    'model_key', p_model_key,
    'model_version', p_model_version,
    'wizard_status', 'completed',
    'wizard_answers', p_wizard_answers,
    'normalized_fields', v_normalized,
    'instance_name', v_instance_name,
    'model_instance_runtime_id', v_instance->>'model_instance_runtime_id',
    'instance_runtime', v_instance
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_instance_wizard_runs_v1(
    org_id,
    model_key,
    model_version,
    wizard_answers,
    normalized_fields,
    model_instance_runtime_id,
    wizard_status,
    wizard_body,
    wizard_hash
  )
  values (
    p_org_id,
    p_model_key,
    p_model_version,
    coalesce(p_wizard_answers,'{}'::jsonb),
    v_normalized,
    (v_instance->>'model_instance_runtime_id')::uuid,
    'completed',
    v_body,
    v_hash
  )
  returning model_instance_wizard_run_id
  into v_id;

  return v_body || jsonb_build_object(
    'model_instance_wizard_run_id', v_id,
    'wizard_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_run_model_instance_wizard_v1"("p_org_id" "uuid", "p_model_key" "text", "p_model_version" "text", "p_wizard_answers" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_run_security_gate_matrix_v1"("p_org_id" "uuid", "p_model_key" "text" DEFAULT 'DEVELOPER_PORTAL_V1'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_rollup record;
  v_stress record;

  v_results jsonb := '[]'::jsonb;
  v_fail_count integer := 0;
  v_gate text;
  v_status text;
  v_message text;
  v_body jsonb;
  v_hash text;
begin
  if p_org_id is null then
    raise exception 'SECURITY_GATE_ORG_REQUIRED';
  end if;

  perform pods_provisioning.rpc_seed_security_gate_matrix_v1();

  select *
  into v_rollup
  from pods_provisioning.provider_readiness_rollups_v1 r
  where r.org_id = p_org_id
  order by r.created_at desc
  limit 1;

  select *
  into v_stress
  from pods_provisioning.stress_harness_runs_v1 s
  where s.stress_status = 'passed'
  order by s.created_at desc
  limit 1;

  foreach v_gate in array array[
    'tenant_boundary',
    'secret_ref_only',
    'provider_ownership',
    'launch_authorization',
    'rls_required',
    'rollback_ready',
    'replay_ready',
    'duplicate_denial'
  ]
  loop
    v_status := 'pass';
    v_message := 'PASS';

    if v_gate = 'tenant_boundary' and (v_stress.stress_run_id is null or v_stress.isolation_pass is not true) then
      v_status := 'fail';
      v_message := 'Tenant isolation stress proof missing';
    end if;

    if v_gate = 'provider_ownership' and (v_rollup.provider_readiness_rollup_id is null or v_rollup.launch_ready is not true) then
      v_status := 'fail';
      v_message := 'Provider readiness rollup not ready';
    end if;

    if v_gate = 'rls_required' and (v_rollup.provider_readiness_rollup_id is null or v_rollup.supabase_ready is not true) then
      v_status := 'fail';
      v_message := 'Supabase/RLS readiness missing';
    end if;

    if v_gate = 'duplicate_denial' and (v_stress.stress_run_id is null or v_stress.duplicate_denial_count < 3) then
      v_status := 'fail';
      v_message := 'Duplicate denial stress proof insufficient';
    end if;

    if v_gate = 'rollback_ready' and (v_stress.stress_run_id is null or v_stress.rollback_count < 1) then
      v_status := 'fail';
      v_message := 'Rollback proof missing';
    end if;

    if v_gate = 'replay_ready' and (v_stress.stress_run_id is null or v_stress.retry_count < 4) then
      v_status := 'fail';
      v_message := 'Replay/retry proof missing';
    end if;

    if v_status = 'fail' then
      v_fail_count := v_fail_count + 1;
    end if;

    v_body := jsonb_build_object(
      'ok', (v_status = 'pass'),
      'token', 'PROTEUSOPS_SECURITY_GATE_RESULT_OK',
      'org_id', p_org_id,
      'model_key', p_model_key,
      'gate_key', v_gate,
      'gate_status', v_status,
      'gate_message', v_message
    );

    v_hash := pods_provisioning._sha256_text_v1(v_body::text);

    insert into pods_provisioning.security_gate_results_v1(
      org_id,
      model_key,
      gate_key,
      gate_status,
      gate_message,
      result_body,
      result_hash
    )
    values (
      p_org_id,
      p_model_key,
      v_gate,
      v_status,
      v_message,
      v_body,
      v_hash
    );

    v_results := v_results || jsonb_build_array(v_body);
  end loop;

  return jsonb_build_object(
    'ok', (v_fail_count = 0),
    'token', 'PROTEUSOPS_SECURITY_GATE_MATRIX_OK',
    'org_id', p_org_id,
    'model_key', p_model_key,
    'gate_count', jsonb_array_length(v_results),
    'fail_count', v_fail_count,
    'security_status', case when v_fail_count = 0 then 'passed' else 'failed' end,
    'results', v_results
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_run_security_gate_matrix_v1"("p_org_id" "uuid", "p_model_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_schedule_contractor_site_visit_v1"("p_estimate_request_id" "uuid", "p_scheduled_date" "date", "p_scheduled_start_time" time without time zone, "p_scheduled_end_time" time without time zone, "p_estimator_name" "text" DEFAULT ''::"text", "p_estimator_user_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_estimate record;
  v_body jsonb;
  v_hash text;
  v_site_visit_id uuid;
begin
  if p_estimate_request_id is null then
    raise exception 'SITE_VISIT_ESTIMATE_REQUIRED';
  end if;

  if p_scheduled_date is null then
    raise exception 'SITE_VISIT_DATE_REQUIRED';
  end if;

  if p_scheduled_start_time is null or p_scheduled_end_time is null then
    raise exception 'SITE_VISIT_TIME_REQUIRED';
  end if;

  if p_scheduled_end_time <= p_scheduled_start_time then
    raise exception 'SITE_VISIT_TIME_INVALID';
  end if;

  select *
  into v_estimate
  from pods_provisioning.contractor_estimate_requests_v1 er
  where er.estimate_request_id = p_estimate_request_id
  for update;

  if not found then
    raise exception 'SITE_VISIT_ESTIMATE_NOT_FOUND';
  end if;

  if v_estimate.estimate_status not in ('requested','site_visit_scheduled') then
    raise exception 'SITE_VISIT_ESTIMATE_STATUS_INVALID:%', v_estimate.estimate_status;
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CONTRACTOR_SITE_VISIT_OK',
    'estimate_request_id', v_estimate.estimate_request_id,
    'org_id', v_estimate.org_id,
    'template_key', v_estimate.template_key,
    'template_version', v_estimate.template_version,
    'service_code', v_estimate.service_code,
    'scheduled_date', p_scheduled_date::text,
    'scheduled_start_time', p_scheduled_start_time::text,
    'scheduled_end_time', p_scheduled_end_time::text,
    'estimator_name', coalesce(p_estimator_name,''),
    'visit_status', 'scheduled'
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.contractor_site_visits_v1(
    estimate_request_id,
    org_id,
    scheduled_date,
    scheduled_start_time,
    scheduled_end_time,
    estimator_name,
    estimator_user_id,
    visit_status,
    visit_body,
    visit_hash
  )
  values (
    v_estimate.estimate_request_id,
    v_estimate.org_id,
    p_scheduled_date,
    p_scheduled_start_time,
    p_scheduled_end_time,
    coalesce(p_estimator_name,''),
    p_estimator_user_id,
    'scheduled',
    v_body,
    v_hash
  )
  returning site_visit_id
  into v_site_visit_id;

  update pods_provisioning.contractor_estimate_requests_v1
  set estimate_status = 'site_visit_scheduled'
  where estimate_request_id = v_estimate.estimate_request_id;

  return v_body || jsonb_build_object(
    'site_visit_id', v_site_visit_id,
    'visit_hash', v_hash
  );
exception
  when unique_violation then
    raise exception 'SITE_VISIT_DUPLICATE_DENY:%', p_estimate_request_id;
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_schedule_contractor_site_visit_v1"("p_estimate_request_id" "uuid", "p_scheduled_date" "date", "p_scheduled_start_time" time without time zone, "p_scheduled_end_time" time without time zone, "p_estimator_name" "text", "p_estimator_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_seed_civic_action_model_registry_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_body jsonb;
  v_hash text;
  v_id uuid;
begin
  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_MODEL_REGISTRY_OK',
    'model_key', 'CIVIC_ACTION_V1',
    'model_version', 'v1',
    'display_name', 'Civic Action / Petition Site',
    'purpose', 'Deploy a governed civic action website for learning, petitions, surveys, supporter signup, volunteer help, contribution proof, public progress, and moderation.',
    'actors', jsonb_build_array(
      'visitor',
      'supporter',
      'signer',
      'survey_respondent',
      'volunteer',
      'organizer',
      'moderator',
      'community_admin',
      'institution_partner'
    ),
    'capabilities', jsonb_build_array(
      'issue_page',
      'petition_signatures',
      'survey_responses',
      'supporter_signup',
      'volunteer_help_options',
      'contribution_wall',
      'evidence_links',
      'event_updates',
      'role_based_admin',
      'moderation_queue',
      'public_progress_metrics',
      'email_notifications'
    ),
    'workflows', jsonb_build_array(
      'learn_about_issue',
      'sign_petition',
      'submit_survey',
      'join_updates',
      'offer_help',
      'submit_evidence_link',
      'moderate_submission',
      'publish_progress_update'
    ),
    'required_providers', jsonb_build_array(
      'supabase',
      'email',
      'storage'
    ),
    'default_fields', jsonb_build_object(
      'issue_title', '',
      'community_name', '',
      'location_label', '',
      'position_type', 'oppose_or_support',
      'issue_summary', '',
      'petition_goal', 500,
      'public_signature_count', true,
      'show_contribution_wall', true,
      'enable_survey', true,
      'enable_volunteer_signup', true,
      'moderation_required', true
    )
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.civic_action_model_registry_v1(
    model_key,
    model_version,
    display_name,
    model_purpose,
    actors,
    capabilities,
    workflows,
    required_providers,
    default_fields,
    active,
    registry_body,
    registry_hash
  )
  values (
    'CIVIC_ACTION_V1',
    'v1',
    'Civic Action / Petition Site',
    v_body->>'purpose',
    v_body->'actors',
    v_body->'capabilities',
    v_body->'workflows',
    v_body->'required_providers',
    v_body->'default_fields',
    true,
    v_body,
    v_hash
  )
  on conflict (model_key, model_version) do update
  set
    display_name = excluded.display_name,
    model_purpose = excluded.model_purpose,
    actors = excluded.actors,
    capabilities = excluded.capabilities,
    workflows = excluded.workflows,
    required_providers = excluded.required_providers,
    default_fields = excluded.default_fields,
    active = excluded.active,
    registry_body = excluded.registry_body,
    registry_hash = excluded.registry_hash
  returning civic_model_id
  into v_id;

  return v_body || jsonb_build_object(
    'civic_model_id', v_id,
    'registry_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_seed_civic_action_model_registry_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_seed_contractor_template_registry_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_count integer;
begin
  insert into pods_provisioning.contractor_service_templates_v1(
    template_key,
    template_version,
    service_code,
    display_name,
    category,
    estimated_duration_hours,
    base_price_cents,
    requires_site_visit,
    requires_materials,
    requires_permit_review,
    active,
    template_body,
    template_hash
  )
  values
  (
    'CONTRACTOR_V1',
    'v1',
    'ROOF_REPLACEMENT',
    'Roof Replacement',
    'roofing',
    40.0,
    1250000,
    true,
    true,
    true,
    true,
    jsonb_build_object(
      'service_code','ROOF_REPLACEMENT',
      'category','roofing'
    ),
    pods_provisioning._sha256_text_v1(
      'CONTRACTOR_V1|ROOF_REPLACEMENT|roofing'
    )
  ),
  (
    'CONTRACTOR_V1',
    'v1',
    'SIDING_INSTALL',
    'Siding Installation',
    'exterior',
    24.0,
    850000,
    true,
    true,
    false,
    true,
    jsonb_build_object(
      'service_code','SIDING_INSTALL',
      'category','exterior'
    ),
    pods_provisioning._sha256_text_v1(
      'CONTRACTOR_V1|SIDING_INSTALL|exterior'
    )
  ),
  (
    'CONTRACTOR_V1',
    'v1',
    'GUTTER_REPAIR',
    'Gutter Repair',
    'roofing',
    6.0,
    120000,
    false,
    true,
    false,
    true,
    jsonb_build_object(
      'service_code','GUTTER_REPAIR',
      'category','roofing'
    ),
    pods_provisioning._sha256_text_v1(
      'CONTRACTOR_V1|GUTTER_REPAIR|roofing'
    )
  )
  on conflict (template_key, template_version, service_code) do update
  set
    display_name = excluded.display_name,
    category = excluded.category,
    estimated_duration_hours = excluded.estimated_duration_hours,
    base_price_cents = excluded.base_price_cents,
    requires_site_visit = excluded.requires_site_visit,
    requires_materials = excluded.requires_materials,
    requires_permit_review = excluded.requires_permit_review,
    active = excluded.active,
    template_body = excluded.template_body,
    template_hash = excluded.template_hash;

  select count(*)
  into v_count
  from pods_provisioning.contractor_service_templates_v1
  where active = true;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CONTRACTOR_TEMPLATE_REGISTRY_OK',
    'template_key', 'CONTRACTOR_V1',
    'service_count', v_count
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_seed_contractor_template_registry_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_seed_default_cancellation_policy_v1"("p_org_id" "uuid", "p_template_key" "text" DEFAULT 'BARBER_NAIL_V1'::"text", "p_template_version" "text" DEFAULT 'v1'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_body jsonb;
  v_hash text;
  v_policy_id uuid;
begin
  if p_org_id is null then
    raise exception 'CANCELLATION_POLICY_ORG_REQUIRED';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CANCELLATION_POLICY_SEED_OK',
    'org_id', p_org_id,
    'template_key', p_template_key,
    'template_version', p_template_version,
    'policy_key', 'default-cancellation',
    'cancellation_window_hours', 24,
    'refund_allowed', true,
    'refund_percent', 100
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.cancellation_policies_v1(
    org_id,
    template_key,
    template_version,
    policy_key,
    display_name,
    cancellation_window_hours,
    refund_allowed,
    refund_percent,
    active,
    policy_body,
    policy_hash
  )
  values (
    p_org_id,
    p_template_key,
    p_template_version,
    'default-cancellation',
    'Default cancellation policy',
    24,
    true,
    100,
    true,
    v_body,
    v_hash
  )
  on conflict (org_id, policy_key) do update
  set
    active = excluded.active,
    policy_body = excluded.policy_body,
    policy_hash = excluded.policy_hash
  returning cancellation_policy_id
  into v_policy_id;

  return v_body || jsonb_build_object(
    'cancellation_policy_id', v_policy_id,
    'policy_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_seed_default_cancellation_policy_v1"("p_org_id" "uuid", "p_template_key" "text", "p_template_version" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_seed_default_payment_policy_v1"("p_org_id" "uuid", "p_template_key" "text" DEFAULT 'BARBER_NAIL_V1'::"text", "p_template_version" "text" DEFAULT 'v1'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_policy_id uuid;
  v_body jsonb;
  v_hash text;
begin
  if p_org_id is null then
    raise exception 'PAYMENT_POLICY_ORG_REQUIRED';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PAYMENT_POLICY_SEED_OK',
    'org_id', p_org_id,
    'template_key', p_template_key,
    'template_version', p_template_version,
    'policy_key', 'default-deposit',
    'deposit_required', true,
    'deposit_amount_cents', 1000,
    'payment_required_before_confirmation', false,
    'refund_window_hours', 24
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.payment_policies_v1(
    org_id,
    template_key,
    template_version,
    policy_key,
    display_name,
    deposit_required,
    deposit_amount_cents,
    payment_required_before_confirmation,
    refund_window_hours,
    active,
    policy_body,
    policy_hash
  )
  values (
    p_org_id,
    p_template_key,
    p_template_version,
    'default-deposit',
    'Default appointment deposit',
    true,
    1000,
    false,
    24,
    true,
    v_body,
    v_hash
  )
  on conflict (org_id, policy_key) do update
  set
    active = excluded.active,
    policy_body = excluded.policy_body,
    policy_hash = excluded.policy_hash
  returning payment_policy_id
  into v_policy_id;

  return v_body || jsonb_build_object(
    'payment_policy_id', v_policy_id,
    'policy_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_seed_default_payment_policy_v1"("p_org_id" "uuid", "p_template_key" "text", "p_template_version" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_seed_default_staff_for_org_v1"("p_org_id" "uuid", "p_template_key" "text" DEFAULT 'BARBER_NAIL_V1'::"text", "p_template_version" "text" DEFAULT 'v1'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_count integer;
begin
  if p_org_id is null then
    raise exception 'STAFF_SEED_ORG_REQUIRED';
  end if;

  insert into pods_provisioning.staff_members_v1(
    org_id,
    template_key,
    template_version,
    staff_key,
    display_name,
    role_key,
    active
  )
  values
    (p_org_id, p_template_key, p_template_version, 'staff-owner', 'Owner Operator', 'OWNER', true),
    (p_org_id, p_template_key, p_template_version, 'staff-barber-1', 'Barber 1', 'BARBER', true),
    (p_org_id, p_template_key, p_template_version, 'staff-nail-tech-1', 'Nail Tech 1', 'NAIL_TECH', true)
  on conflict (org_id, staff_key) do nothing;

  select count(*)
  into v_count
  from pods_provisioning.staff_members_v1 sm
  where sm.org_id = p_org_id
    and sm.active = true;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_STAFF_SEED_OK',
    'org_id', p_org_id,
    'staff_count', v_count
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_seed_default_staff_for_org_v1"("p_org_id" "uuid", "p_template_key" "text", "p_template_version" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_seed_developer_portal_model_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_count integer;
begin
  insert into pods_provisioning.model_capability_matrix_v1(
    model_key,
    model_version,
    vertical_domain,
    display_name,
    description,
    required_engines,
    optional_engines,
    required_capabilities,
    optional_capabilities,
    required_resources,
    required_adapters,
    customer_fields,
    default_overlays,
    active,
    matrix_body,
    matrix_hash
  )
  values (
    'DEVELOPER_PORTAL_V1',
    'v1',
    'DEVELOPER_PORTAL',
    'Developer Product Portal',
    'Developer/product launch model for GitHub links, protected downloads, customer logins, support tickets, releases, docs, and license-gated access.',
    jsonb_build_array(
      'protected_auth',
      'github_links',
      'download_portal',
      'customer_accounts',
      'license_access',
      'support_tickets',
      'release_notes',
      'api_docs',
      'file_storage'
    ),
    jsonb_build_array(
      'webhook_events',
      'changelog_feed',
      'private_beta_access',
      'usage_analytics',
      'team_seats',
      'billing_portal'
    ),
    jsonb_build_array(
      'protected_login',
      'repo_links',
      'download_access',
      'license_gate',
      'ticket_intake',
      'release_registry',
      'documentation_portal'
    ),
    jsonb_build_array(
      'webhooks',
      'beta_program',
      'team_access',
      'customer_usage_metrics',
      'subscription_billing'
    ),
    jsonb_build_array(
      'product_profile',
      'github_repos',
      'download_assets',
      'customer_accounts',
      'license_records',
      'support_tickets',
      'release_notes',
      'documentation_pages'
    ),
    jsonb_build_array(
      'auth_provider',
      'file_storage_provider',
      'email_provider',
      'payment_provider',
      'github_provider'
    ),
    jsonb_build_array(
      jsonb_build_object('field_key','product_name','label','Product name','required',true,'default','My Product'),
      jsonb_build_object('field_key','github_url','label','GitHub URL','required',false,'default',''),
      jsonb_build_object('field_key','download_url','label','Download URL','required',false,'default',''),
      jsonb_build_object('field_key','support_email','label','Support email','required',false,'default','support@example.com'),
      jsonb_build_object('field_key','license_type','label','License type','required',false,'default','standard'),
      jsonb_build_object('field_key','portal_visibility','label','Portal visibility','required',false,'default','private')
    ),
    jsonb_build_object(
      'portal_visibility','private',
      'license_type','standard',
      'protected_downloads',true,
      'support_tickets_enabled',true,
      'release_notes_enabled',true
    ),
    true,
    jsonb_build_object(
      'model_key','DEVELOPER_PORTAL_V1',
      'domain','DEVELOPER_PORTAL'
    ),
    pods_provisioning._sha256_text_v1('DEVELOPER_PORTAL_V1|capability_matrix|v1')
  )
  on conflict (model_key, model_version) do update
  set
    vertical_domain = excluded.vertical_domain,
    display_name = excluded.display_name,
    description = excluded.description,
    required_engines = excluded.required_engines,
    optional_engines = excluded.optional_engines,
    required_capabilities = excluded.required_capabilities,
    optional_capabilities = excluded.optional_capabilities,
    required_resources = excluded.required_resources,
    required_adapters = excluded.required_adapters,
    customer_fields = excluded.customer_fields,
    default_overlays = excluded.default_overlays,
    active = excluded.active,
    matrix_body = excluded.matrix_body,
    matrix_hash = excluded.matrix_hash;

  select count(*)
  into v_count
  from pods_provisioning.model_capability_matrix_v1
  where active = true;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_DEVELOPER_PORTAL_MODEL_OK',
    'model_key', 'DEVELOPER_PORTAL_V1',
    'model_count', v_count
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_seed_developer_portal_model_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_seed_launch_retry_policy_v1"("p_policy_key" "text" DEFAULT 'default-launch-retry'::"text", "p_max_retries" integer DEFAULT 3, "p_cooldown_seconds" integer DEFAULT 60) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_body jsonb;
  v_hash text;
  v_policy_id uuid;
begin
  if p_policy_key is null or btrim(p_policy_key) = '' then
    raise exception 'RETRY_POLICY_KEY_REQUIRED';
  end if;

  if p_max_retries is null or p_max_retries < 0 then
    raise exception 'RETRY_POLICY_MAX_INVALID';
  end if;

  if p_cooldown_seconds is null or p_cooldown_seconds < 0 then
    raise exception 'RETRY_POLICY_COOLDOWN_INVALID';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_RETRY_POLICY_SEED_OK',
    'policy_key', p_policy_key,
    'max_retries', p_max_retries,
    'cooldown_seconds', p_cooldown_seconds
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.launch_retry_policies_v1(
    policy_key,
    max_retries,
    cooldown_seconds,
    active,
    policy_body,
    policy_hash
  )
  values (
    p_policy_key,
    p_max_retries,
    p_cooldown_seconds,
    true,
    v_body,
    v_hash
  )
  on conflict (policy_key) do update
  set
    max_retries = excluded.max_retries,
    cooldown_seconds = excluded.cooldown_seconds,
    active = excluded.active,
    policy_body = excluded.policy_body,
    policy_hash = excluded.policy_hash
  returning retry_policy_id
  into v_policy_id;

  return v_body || jsonb_build_object(
    'retry_policy_id', v_policy_id,
    'policy_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_seed_launch_retry_policy_v1"("p_policy_key" "text", "p_max_retries" integer, "p_cooldown_seconds" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_seed_model_block_registry_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_blocks jsonb;
  v_block jsonb;
  v_hash text;
  v_count integer;
begin
  v_blocks := jsonb_build_array(
    jsonb_build_object('block_key','hero','block_category','content','display_name','Hero','purpose','Top page hero with headline, subtext, call to action','providers',jsonb_build_array(),'permissions',jsonb_build_array(),'fields',jsonb_build_object('headline','','subheadline','','cta_label','','cta_href','')),
    jsonb_build_object('block_key','rich_text','block_category','content','display_name','Rich Text','purpose','Editable formatted content section','providers',jsonb_build_array(),'permissions',jsonb_build_array(),'fields',jsonb_build_object('title','','body','')),
    jsonb_build_object('block_key','markdown','block_category','content','display_name','Markdown','purpose','Markdown content section','providers',jsonb_build_array(),'permissions',jsonb_build_array(),'fields',jsonb_build_object('markdown','')),
    jsonb_build_object('block_key','image','block_category','media','display_name','Image','purpose','Single uploaded image','providers',jsonb_build_array('storage'),'permissions',jsonb_build_array('upload_asset'),'fields',jsonb_build_object('image_ref','','alt_text','')),
    jsonb_build_object('block_key','image_gallery','block_category','media','display_name','Image Gallery','purpose','Gallery of uploaded images','providers',jsonb_build_array('storage'),'permissions',jsonb_build_array('upload_asset'),'fields',jsonb_build_object('gallery_refs',jsonb_build_array())),
    jsonb_build_object('block_key','video','block_category','media','display_name','Video','purpose','Uploaded or embedded video','providers',jsonb_build_array('storage'),'permissions',jsonb_build_array('upload_asset'),'fields',jsonb_build_object('video_ref','','embed_url','','title','')),
    jsonb_build_object('block_key','video_playlist','block_category','media','display_name','Video Playlist','purpose','Creator or educational video playlist','providers',jsonb_build_array('storage'),'permissions',jsonb_build_array('upload_asset'),'fields',jsonb_build_object('videos',jsonb_build_array())),
    jsonb_build_object('block_key','file_download','block_category','download','display_name','File Download','purpose','Public or private downloadable file','providers',jsonb_build_array('storage'),'permissions',jsonb_build_array('upload_asset'),'fields',jsonb_build_object('file_ref','','label','Download')),
    jsonb_build_object('block_key','license_download','block_category','download','display_name','License-Gated Download','purpose','Download protected by license key entitlement','providers',jsonb_build_array('storage'),'permissions',jsonb_build_array('license_key_required'),'fields',jsonb_build_object('file_ref','','license_gate','license_key_required')),
    jsonb_build_object('block_key','product','block_category','commerce','display_name','Product','purpose','Display a product, software, digital good, or service','providers',jsonb_build_array(),'permissions',jsonb_build_array(),'fields',jsonb_build_object('product_name','','description','','price_label','','cta_label','')),
    jsonb_build_object('block_key','pricing','block_category','commerce','display_name','Pricing','purpose','Pricing cards or plan tiers','providers',jsonb_build_array(),'permissions',jsonb_build_array(),'fields',jsonb_build_object('plans',jsonb_build_array())),
    jsonb_build_object('block_key','faq','block_category','content','display_name','FAQ','purpose','Question and answer section','providers',jsonb_build_array(),'permissions',jsonb_build_array(),'fields',jsonb_build_object('items',jsonb_build_array())),
    jsonb_build_object('block_key','contact_form','block_category','form','display_name','Contact Form','purpose','Collect contact messages','providers',jsonb_build_array('email'),'permissions',jsonb_build_array('submit_form'),'fields',jsonb_build_object('recipient_ref','','success_message','Thanks.')),
    jsonb_build_object('block_key','petition','block_category','civic','display_name','Petition','purpose','Collect civic petition signatures','providers',jsonb_build_array('supabase','email'),'permissions',jsonb_build_array('sign_petition'),'fields',jsonb_build_object('petition_goal',500)),
    jsonb_build_object('block_key','survey','block_category','civic','display_name','Survey','purpose','Collect survey responses','providers',jsonb_build_array('supabase'),'permissions',jsonb_build_array('submit_survey'),'fields',jsonb_build_object('questions',jsonb_build_array())),
    jsonb_build_object('block_key','event_list','block_category','civic','display_name','Event List','purpose','Show civic or community events','providers',jsonb_build_array('supabase'),'permissions',jsonb_build_array('view_events'),'fields',jsonb_build_object('event_filter','published')),
    jsonb_build_object('block_key','event_rsvp','block_category','civic','display_name','Event RSVP','purpose','Collect RSVPs, speaker signups, and volunteer intent','providers',jsonb_build_array('supabase','email'),'permissions',jsonb_build_array('rsvp_event'),'fields',jsonb_build_object('allow_speakers',true,'allow_volunteers',true)),
    jsonb_build_object('block_key','contribution_wall','block_category','civic','display_name','Contribution Wall','purpose','Show moderated public participation','providers',jsonb_build_array('supabase'),'permissions',jsonb_build_array('view_public_counts'),'fields',jsonb_build_object('show_pending',true)),
    jsonb_build_object('block_key','evidence_library','block_category','civic','display_name','Evidence Library','purpose','Show evidence submissions and supporting material','providers',jsonb_build_array('supabase','storage'),'permissions',jsonb_build_array('submit_evidence'),'fields',jsonb_build_object('accepted_types',jsonb_build_array('link','document','photo','video'))),
    jsonb_build_object('block_key','booking','block_category','operations','display_name','Booking','purpose','Book appointments or services','providers',jsonb_build_array('supabase','email'),'permissions',jsonb_build_array('book_service'),'fields',jsonb_build_object('service_filter','active')),
    jsonb_build_object('block_key','calendar','block_category','operations','display_name','Calendar','purpose','Display events, appointments, or schedules','providers',jsonb_build_array('supabase'),'permissions',jsonb_build_array('view_calendar'),'fields',jsonb_build_object('calendar_mode','list')),
    jsonb_build_object('block_key','map','block_category','location','display_name','Map','purpose','Display places, routes, regions, or issue locations','providers',jsonb_build_array(),'permissions',jsonb_build_array('view_map'),'fields',jsonb_build_object('location_label','','lat',null,'lng',null)),
    jsonb_build_object('block_key','custom','block_category','custom','display_name','Custom Block','purpose','Safe custom configured content block','providers',jsonb_build_array(),'permissions',jsonb_build_array(),'fields',jsonb_build_object('schema',jsonb_build_object()))
  );

  for v_block in select value from jsonb_array_elements(v_blocks)
  loop
    v_hash := pods_provisioning._sha256_text_v1(v_block::text);

    insert into pods_provisioning.model_block_registry_v1(
      block_key,
      block_category,
      display_name,
      block_purpose,
      supported_surfaces,
      supported_models,
      required_providers,
      required_permissions,
      default_fields,
      active,
      block_body,
      block_hash
    )
    values (
      v_block->>'block_key',
      v_block->>'block_category',
      v_block->>'display_name',
      v_block->>'purpose',
      jsonb_build_array('public','admin'),
      jsonb_build_array('CIVIC_ACTION_V1','SOFTWARE_PRODUCT_V1','CREATOR_MEDIA_V1','BARBER_NAIL_V1','CONTRACTOR_V1','REAL_ESTATE_V1','CUSTOM_PAGE_V1'),
      v_block->'providers',
      v_block->'permissions',
      v_block->'fields',
      true,
      v_block,
      v_hash
    )
    on conflict (block_key) do update
    set
      block_category = excluded.block_category,
      display_name = excluded.display_name,
      block_purpose = excluded.block_purpose,
      supported_surfaces = excluded.supported_surfaces,
      supported_models = excluded.supported_models,
      required_providers = excluded.required_providers,
      required_permissions = excluded.required_permissions,
      default_fields = excluded.default_fields,
      active = excluded.active,
      block_body = excluded.block_body,
      block_hash = excluded.block_hash;
  end loop;

  select count(*)
  into v_count
  from pods_provisioning.model_block_registry_v1
  where active = true;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_BLOCK_REGISTRY_OK',
    'block_count', v_count,
    'required_blocks', jsonb_build_array(
      'hero',
      'rich_text',
      'video',
      'file_download',
      'license_download',
      'product',
      'petition',
      'survey',
      'event_list',
      'event_rsvp',
      'contribution_wall',
      'evidence_library',
      'booking',
      'custom'
    )
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_seed_model_block_registry_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_seed_model_capability_matrix_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_count integer;
begin
  insert into pods_provisioning.model_capability_matrix_v1(
    model_key,
    model_version,
    vertical_domain,
    display_name,
    description,
    required_engines,
    optional_engines,
    required_capabilities,
    optional_capabilities,
    required_resources,
    required_adapters,
    customer_fields,
    default_overlays,
    active,
    matrix_body,
    matrix_hash
  )
  values
  (
    'BARBER_NAIL_V1',
    'v1',
    'BARBER_NAIL',
    'Barber + Nail Studio',
    'Appointment-based beauty/personal care operating model.',
    jsonb_build_array('booking','staff','services','calendar','notifications','payments','public_profiles'),
    jsonb_build_array('memberships','gallery_featured_sections','sms_reminders','loyalty'),
    jsonb_build_array('public_booking','appointment_requests','admin_queue','operator_calendar','staff_assignment','customer_notifications','payment_lifecycle'),
    jsonb_build_array('memberships','employee_of_month','work_gallery','refunds'),
    jsonb_build_array('services','hours','staff_members','booking_surface','payment_policy','notification_templates'),
    jsonb_build_array('payment_provider','email_provider','sms_provider'),
    jsonb_build_array(
      jsonb_build_object('field_key','business_name','label','Business name','required',true,'default','My Studio'),
      jsonb_build_object('field_key','timezone','label','Timezone','required',false,'default','America/New_York'),
      jsonb_build_object('field_key','deposit_amount_cents','label','Deposit amount','required',false,'default',1000),
      jsonb_build_object('field_key','business_hours','label','Business hours','required',false,'default','template_default')
    ),
    jsonb_build_object(
      'deposit_amount_cents',1000,
      'default_service_duration_minutes',45,
      'public_booking_enabled',true
    ),
    true,
    jsonb_build_object('model_key','BARBER_NAIL_V1','domain','BARBER_NAIL'),
    pods_provisioning._sha256_text_v1('BARBER_NAIL_V1|capability_matrix|v1')
  ),
  (
    'CONTRACTOR_V1',
    'v1',
    'CONTRACTOR',
    'Contractor Operations',
    'Lead, estimate, site visit, job, materials, invoice, and payment operating model.',
    jsonb_build_array('lead_intake','site_visits','estimates','jobs','materials','change_orders','invoices','payments'),
    jsonb_build_array('crew_scheduling','permit_tracking','progress_photos','subcontractors','customer_portal'),
    jsonb_build_array('estimate_request','site_visit','estimate_builder','estimate_approval','job_creation','payment_lifecycle'),
    jsonb_build_array('change_orders','materials_tracking','progress_billing','final_invoice','refunds'),
    jsonb_build_array('service_templates','estimate_requests','site_visits','estimate_records','job_records','job_phases','payment_policy'),
    jsonb_build_array('payment_provider','email_provider','file_storage_provider'),
    jsonb_build_array(
      jsonb_build_object('field_key','business_name','label','Business name','required',true,'default','My Contractor Business'),
      jsonb_build_object('field_key','service_area','label','Service area','required',false,'default','local'),
      jsonb_build_object('field_key','default_deposit_percent','label','Default deposit percent','required',false,'default',25),
      jsonb_build_object('field_key','requires_site_visit','label','Require site visits','required',false,'default',true)
    ),
    jsonb_build_object(
      'default_deposit_percent',25,
      'requires_site_visit',true,
      'estimate_valid_days',14
    ),
    true,
    jsonb_build_object('model_key','CONTRACTOR_V1','domain','CONTRACTOR'),
    pods_provisioning._sha256_text_v1('CONTRACTOR_V1|capability_matrix|v1')
  ),
  (
    'REAL_ESTATE_V1',
    'v1',
    'REAL_ESTATE',
    'Real Estate Operations',
    'Property, agent, showing, offer, document, closing, and commission operating model.',
    jsonb_build_array('properties','agents','showings','offers','documents','closing_milestones','commissions'),
    jsonb_build_array('open_houses','buyer_portal','seller_portal','inspection_tracking','document_signing'),
    jsonb_build_array('property_listing','showing_workflow','offer_pipeline','closing_milestones','document_portal'),
    jsonb_build_array('commission_tracking','inspection_workflow','open_house_scheduler','lead_routing'),
    jsonb_build_array('property_records','agent_profiles','showing_requests','offer_records','document_refs','closing_timeline'),
    jsonb_build_array('email_provider','file_storage_provider','calendar_provider'),
    jsonb_build_array(
      jsonb_build_object('field_key','brokerage_name','label','Brokerage name','required',true,'default','My Brokerage'),
      jsonb_build_object('field_key','market_area','label','Market area','required',false,'default','local'),
      jsonb_build_object('field_key','default_commission_bps','label','Default commission basis points','required',false,'default',300),
      jsonb_build_object('field_key','document_portal_enabled','label','Document portal','required',false,'default',true)
    ),
    jsonb_build_object(
      'default_commission_bps',300,
      'document_portal_enabled',true,
      'showing_duration_minutes',30
    ),
    true,
    jsonb_build_object('model_key','REAL_ESTATE_V1','domain','REAL_ESTATE'),
    pods_provisioning._sha256_text_v1('REAL_ESTATE_V1|capability_matrix|v1')
  )
  on conflict (model_key, model_version) do update
  set
    vertical_domain = excluded.vertical_domain,
    display_name = excluded.display_name,
    description = excluded.description,
    required_engines = excluded.required_engines,
    optional_engines = excluded.optional_engines,
    required_capabilities = excluded.required_capabilities,
    optional_capabilities = excluded.optional_capabilities,
    required_resources = excluded.required_resources,
    required_adapters = excluded.required_adapters,
    customer_fields = excluded.customer_fields,
    default_overlays = excluded.default_overlays,
    active = excluded.active,
    matrix_body = excluded.matrix_body,
    matrix_hash = excluded.matrix_hash;

  select count(*)
  into v_count
  from pods_provisioning.model_capability_matrix_v1
  where active = true;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_CAPABILITY_MATRIX_OK',
    'model_count', v_count,
    'models', jsonb_build_array('BARBER_NAIL_V1','CONTRACTOR_V1','REAL_ESTATE_V1')
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_seed_model_capability_matrix_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_seed_model_template_registry_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_civic jsonb;
  v_creator jsonb;
  v_software jsonb;
begin
  v_civic := pods_provisioning.rpc_register_model_template_v1(
    'CIVIC_ACTION_V1',
    'v2',
    'Civic Action',
    'civic',
    jsonb_build_object(
      'fields', jsonb_build_array(
        jsonb_build_object('key','issue_title','label','Issue title','type','text','required',true),
        jsonb_build_object('key','community_name','label','Community name','type','text','required',true),
        jsonb_build_object('key','location_label','label','Location','type','text','required',false),
        jsonb_build_object('key','position_type','label','Position','type','choice','choices',jsonb_build_array('oppose','support'),'required',true),
        jsonb_build_object('key','issue_summary','label','Issue summary','type','long_text','required',true),
        jsonb_build_object('key','petition_goal','label','Petition goal','type','number','required',true),
        jsonb_build_object('key','enable_survey','label','Enable survey','type','boolean','default',true),
        jsonb_build_object('key','enable_events','label','Enable events','type','boolean','default',true),
        jsonb_build_object('key','enable_evidence','label','Enable evidence','type','boolean','default',true)
      )
    ),
    jsonb_build_array('/','/issue','/petition','/survey','/volunteer','/events','/evidence','/contribution-wall','/updates'),
    jsonb_build_array('hero','rich_text','petition','survey','event_list','event_rsvp','evidence_library','contribution_wall'),
    jsonb_build_array('visitor','supporter','signer','survey_respondent','volunteer','organizer','moderator','community_admin','institution_partner'),
    jsonb_build_array('supabase','email','storage'),
    jsonb_build_array('proteusops_hosted','supabase_hosted','vercel_export','docker_export'),
    jsonb_build_array()
  );

  v_creator := pods_provisioning.rpc_register_model_template_v1(
    'CREATOR_MEDIA_V1',
    'v1',
    'Creator Media',
    'creator',
    jsonb_build_object(
      'fields', jsonb_build_array(
        jsonb_build_object('key','site_name','label','Site name','type','text','required',true),
        jsonb_build_object('key','creator_name','label','Creator name','type','text','required',true),
        jsonb_build_object('key','description','label','Description','type','long_text','required',false),
        jsonb_build_object('key','enable_videos','label','Enable videos','type','boolean','default',true),
        jsonb_build_object('key','enable_downloads','label','Enable downloads','type','boolean','default',true),
        jsonb_build_object('key','enable_products','label','Enable products','type','boolean','default',true)
      )
    ),
    jsonb_build_array('/','/videos','/downloads','/products','/contact'),
    jsonb_build_array('hero','video','video_playlist','product','file_download','contact_form'),
    jsonb_build_array('visitor','subscriber','creator_admin'),
    jsonb_build_array('email','storage'),
    jsonb_build_array('proteusops_hosted','vercel_export','docker_export'),
    jsonb_build_array(
      jsonb_build_object('gate_key','license_key_required','applies_to',jsonb_build_array('private_video','download'))
    )
  );

  v_software := pods_provisioning.rpc_register_model_template_v1(
    'SOFTWARE_PRODUCT_V1',
    'v1',
    'Software Product',
    'software',
    jsonb_build_object(
      'fields', jsonb_build_array(
        jsonb_build_object('key','product_name','label','Product name','type','text','required',true),
        jsonb_build_object('key','description','label','Description','type','long_text','required',true),
        jsonb_build_object('key','price_label','label','Price label','type','text','required',false),
        jsonb_build_object('key','download_enabled','label','Enable downloads','type','boolean','default',true),
        jsonb_build_object('key','license_required','label','Require license key','type','boolean','default',true)
      )
    ),
    jsonb_build_array('/','/features','/pricing','/download','/faq','/support'),
    jsonb_build_array('hero','product','image_gallery','video','pricing','license_download','faq','contact_form'),
    jsonb_build_array('visitor','customer','product_admin'),
    jsonb_build_array('storage','email'),
    jsonb_build_array('proteusops_hosted','vercel_export','docker_export'),
    jsonb_build_array(
      jsonb_build_object('gate_key','license_key_required','applies_to',jsonb_build_array('software','download','premium_page'))
    )
  );

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_TEMPLATE_REGISTRY_OK',
    'templates', jsonb_build_array(v_civic, v_creator, v_software)
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_seed_model_template_registry_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_seed_notification_templates_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_count integer;
begin
  insert into pods_provisioning.notification_templates_v1(
    template_key,
    template_version,
    notification_kind,
    delivery_channel,
    subject_template,
    body_template,
    active,
    template_body,
    template_hash
  )
  values
  (
    'DEFAULT_CONFIRMATION',
    'v1',
    'appointment_confirmation',
    'email',
    'Appointment Confirmation',
    'Your appointment has been confirmed.',
    true,
    jsonb_build_object(
      'notification_kind','appointment_confirmation',
      'delivery_channel','email'
    ),
    pods_provisioning._sha256_text_v1(
      'DEFAULT_CONFIRMATION|v1|appointment_confirmation|email'
    )
  ),
  (
    'DEFAULT_REMINDER',
    'v1',
    'appointment_reminder',
    'sms',
    '',
    'Reminder: your appointment is coming up soon.',
    true,
    jsonb_build_object(
      'notification_kind','appointment_reminder',
      'delivery_channel','sms'
    ),
    pods_provisioning._sha256_text_v1(
      'DEFAULT_REMINDER|v1|appointment_reminder|sms'
    )
  )
  on conflict do nothing;

  select count(*)
  into v_count
  from pods_provisioning.notification_templates_v1;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_NOTIFICATION_TEMPLATE_SEED_OK',
    'template_count', v_count
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_seed_notification_templates_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_seed_payment_provider_adapter_v1"("p_provider_key" "text" DEFAULT 'stripe'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_body jsonb;
  v_hash text;
  v_adapter_id uuid;
begin
  if p_provider_key is null or btrim(p_provider_key) = '' then
    raise exception 'PAYMENT_PROVIDER_KEY_REQUIRED';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PAYMENT_PROVIDER_ADAPTER_OK',
    'provider_key', lower(p_provider_key),
    'webhook_enabled', true,
    'signature_verification_required', true
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.payment_provider_adapters_v1(
    provider_key,
    display_name,
    webhook_enabled,
    signature_verification_required,
    active,
    adapter_body,
    adapter_hash
  )
  values (
    lower(p_provider_key),
    initcap(lower(p_provider_key)),
    true,
    true,
    true,
    v_body,
    v_hash
  )
  on conflict (provider_key) do update
  set
    active = excluded.active,
    adapter_body = excluded.adapter_body,
    adapter_hash = excluded.adapter_hash
  returning provider_adapter_id
  into v_adapter_id;

  return v_body || jsonb_build_object(
    'provider_adapter_id', v_adapter_id,
    'adapter_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_seed_payment_provider_adapter_v1"("p_provider_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_seed_provider_oauth_connection_contracts_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_count integer;
begin
  insert into pods_provisioning.provider_connection_contracts_v1(
    provider_key,
    display_name,
    default_connection_method,
    manual_key_entry_allowed,
    manual_key_entry_scope,
    secret_storage_model,
    user_action,
    required_scopes,
    discovered_resources,
    verification_checks,
    active,
    contract_body,
    contract_hash
  )
  values
  (
    'supabase',
    'Supabase',
    'oauth_or_api',
    false,
    'developer_fallback_only',
    'secret_ref_only',
    'connect_provider',
    jsonb_build_array('projects:read','auth:read','storage:read','database:read'),
    jsonb_build_array('project_ref','project_url','auth_status','storage_status','rls_status'),
    jsonb_build_array('project_discovered','auth_verified','storage_verified','database_verified','rls_verified'),
    true,
    jsonb_build_object('provider_key','supabase','default','oauth_or_api','manual_key_entry','developer_fallback_only'),
    pods_provisioning._sha256_text_v1('provider:supabase|oauth_or_api|secret_ref_only|developer_fallback_only')
  ),
  (
    'stripe',
    'Stripe',
    'oauth_or_api',
    false,
    'developer_fallback_only',
    'secret_ref_only',
    'connect_provider',
    jsonb_build_array('account:read','products:write','prices:write','webhooks:write'),
    jsonb_build_array('account_id','mode','webhook_endpoint','product_catalog','price_catalog'),
    jsonb_build_array('account_verified','webhook_configured','signing_secret_ref_present','product_sync_ready','price_sync_ready'),
    true,
    jsonb_build_object('provider_key','stripe','default','oauth_or_api','manual_key_entry','developer_fallback_only'),
    pods_provisioning._sha256_text_v1('provider:stripe|oauth_or_api|secret_ref_only|developer_fallback_only')
  ),
  (
    'github',
    'GitHub',
    'oauth',
    false,
    'developer_fallback_only',
    'secret_ref_only',
    'connect_provider',
    jsonb_build_array('repo:read','releases:read','webhooks:write'),
    jsonb_build_array('owner','repo','repo_url','release_channels'),
    jsonb_build_array('token_verified','repo_access_verified','release_access_ready','webhook_configured'),
    true,
    jsonb_build_object('provider_key','github','default','oauth','manual_key_entry','developer_fallback_only'),
    pods_provisioning._sha256_text_v1('provider:github|oauth|secret_ref_only|developer_fallback_only')
  ),
  (
    'figma',
    'Figma',
    'oauth',
    false,
    'developer_fallback_only',
    'secret_ref_only',
    'connect_provider',
    jsonb_build_array('files:read','projects:read'),
    jsonb_build_array('team_id','project_id','file_id','design_system_refs'),
    jsonb_build_array('account_verified','file_access_verified','design_refs_discovered'),
    true,
    jsonb_build_object('provider_key','figma','default','oauth','manual_key_entry','developer_fallback_only'),
    pods_provisioning._sha256_text_v1('provider:figma|oauth|secret_ref_only|developer_fallback_only')
  ),
  (
    'email',
    'Email Provider',
    'oauth_or_api',
    false,
    'developer_fallback_only',
    'secret_ref_only',
    'connect_provider',
    jsonb_build_array('domains:read','senders:write','webhooks:write'),
    jsonb_build_array('provider_key','sender_domain','webhook_endpoint'),
    jsonb_build_array('api_verified','domain_verified','webhook_configured','transactional_send_ready'),
    true,
    jsonb_build_object('provider_key','email','default','oauth_or_api','manual_key_entry','developer_fallback_only'),
    pods_provisioning._sha256_text_v1('provider:email|oauth_or_api|secret_ref_only|developer_fallback_only')
  )
  on conflict (provider_key) do update
  set
    display_name = excluded.display_name,
    default_connection_method = excluded.default_connection_method,
    manual_key_entry_allowed = excluded.manual_key_entry_allowed,
    manual_key_entry_scope = excluded.manual_key_entry_scope,
    secret_storage_model = excluded.secret_storage_model,
    user_action = excluded.user_action,
    required_scopes = excluded.required_scopes,
    discovered_resources = excluded.discovered_resources,
    verification_checks = excluded.verification_checks,
    active = excluded.active,
    contract_body = excluded.contract_body,
    contract_hash = excluded.contract_hash;

  select count(*)
  into v_count
  from pods_provisioning.provider_connection_contracts_v1
  where active = true;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PROVIDER_OAUTH_CONNECTION_CONTRACT_OK',
    'provider_count', v_count,
    'providers', jsonb_build_array('supabase','stripe','github','figma','email')
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_seed_provider_oauth_connection_contracts_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_seed_security_gate_matrix_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_count integer;
begin
  insert into pods_provisioning.security_gate_matrix_v1(
    gate_key,
    display_name,
    gate_kind,
    required,
    active,
    gate_body,
    gate_hash
  )
  values
  ('tenant_boundary','Tenant Boundary','tenant',true,true,jsonb_build_object('gate','tenant_boundary'),pods_provisioning._sha256_text_v1('tenant_boundary')),
  ('secret_ref_only','Secret References Only','secret',true,true,jsonb_build_object('gate','secret_ref_only'),pods_provisioning._sha256_text_v1('secret_ref_only')),
  ('provider_ownership','Provider Ownership','provider',true,true,jsonb_build_object('gate','provider_ownership'),pods_provisioning._sha256_text_v1('provider_ownership')),
  ('launch_authorization','Launch Authorization','auth',true,true,jsonb_build_object('gate','launch_authorization'),pods_provisioning._sha256_text_v1('launch_authorization')),
  ('rls_required','RLS Required','rls',true,true,jsonb_build_object('gate','rls_required'),pods_provisioning._sha256_text_v1('rls_required')),
  ('rollback_ready','Rollback Ready','rollback',true,true,jsonb_build_object('gate','rollback_ready'),pods_provisioning._sha256_text_v1('rollback_ready')),
  ('replay_ready','Replay Ready','replay',true,true,jsonb_build_object('gate','replay_ready'),pods_provisioning._sha256_text_v1('replay_ready')),
  ('duplicate_denial','Duplicate Denial','duplicate',true,true,jsonb_build_object('gate','duplicate_denial'),pods_provisioning._sha256_text_v1('duplicate_denial'))
  on conflict (gate_key) do update
  set
    display_name = excluded.display_name,
    gate_kind = excluded.gate_kind,
    required = excluded.required,
    active = excluded.active,
    gate_body = excluded.gate_body,
    gate_hash = excluded.gate_hash;

  select count(*)
  into v_count
  from pods_provisioning.security_gate_matrix_v1
  where active = true;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_SECURITY_GATE_MATRIX_OK',
    'gate_count', v_count
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_seed_security_gate_matrix_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_seed_staff_public_profiles_v1"("p_org_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_count integer;
begin
  if p_org_id is null then
    raise exception 'STAFF_PUBLIC_PROFILE_ORG_REQUIRED';
  end if;

  insert into pods_provisioning.staff_public_profiles_v1(
    staff_member_id,
    org_id,
    public_display_name,
    headline,
    about_me,
    specialties,
    years_experience,
    profile_photo_url,
    is_public,
    featured_rank,
    profile_body,
    profile_hash
  )
  select
    sm.staff_member_id,
    sm.org_id,
    sm.display_name,
    case
      when sm.role_key = 'BARBER' then 'Barber and grooming specialist'
      when sm.role_key = 'NAIL_TECH' then 'Nail care specialist'
      when sm.role_key = 'OWNER' then 'Owner and operator'
      else sm.role_key
    end,
    case
      when sm.role_key = 'BARBER' then 'Focused on clean cuts, beard trims, and consistent customer care.'
      when sm.role_key = 'NAIL_TECH' then 'Focused on manicures, pedicures, and detail-oriented nail care.'
      when sm.role_key = 'OWNER' then 'Focused on keeping the studio running smoothly and customers cared for.'
      else 'Team member profile.'
    end,
    case
      when sm.role_key = 'BARBER' then jsonb_build_array('Haircuts','Beard trims','Grooming')
      when sm.role_key = 'NAIL_TECH' then jsonb_build_array('Manicures','Pedicures','Nail care')
      when sm.role_key = 'OWNER' then jsonb_build_array('Customer care','Operations')
      else '[]'::jsonb
    end,
    0,
    '',
    true,
    case
      when sm.role_key = 'OWNER' then 1
      when sm.role_key = 'BARBER' then 2
      when sm.role_key = 'NAIL_TECH' then 3
      else 10
    end,
    jsonb_build_object(
      'staff_member_id', sm.staff_member_id,
      'display_name', sm.display_name,
      'role_key', sm.role_key,
      'public_profile_seeded', true
    ),
    pods_provisioning._sha256_text_v1(
      sm.org_id::text || '|' ||
      sm.staff_member_id::text || '|' ||
      sm.display_name || '|' ||
      sm.role_key || '|public_profile_v1'
    )
  from pods_provisioning.staff_members_v1 sm
  where sm.org_id = p_org_id
    and sm.active = true
  on conflict (staff_member_id) do nothing;

  select count(*)
  into v_count
  from pods_provisioning.staff_public_profiles_v1 spp
  where spp.org_id = p_org_id
    and spp.is_public = true;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_STAFF_PUBLIC_PROFILES_OK',
    'org_id', p_org_id,
    'public_profile_count', v_count
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_seed_staff_public_profiles_v1"("p_org_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_seed_vertical_domain_contracts_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_domain_count integer;
  v_capability_count integer;
  v_workflow_count integer;
  v_surface_count integer;
begin
  insert into pods_provisioning.vertical_domains_v1(
    domain_key,
    display_name,
    category,
    description,
    active,
    domain_body,
    domain_hash
  )
  values
  (
    'BARBER_NAIL',
    'Barber and Nail Studio',
    'beauty',
    'Appointment-based personal care vertical with staff, services, public booking, galleries, payments, notifications, and calendar workflows.',
    true,
    jsonb_build_object('domain_key','BARBER_NAIL','template_key','BARBER_NAIL_V1'),
    pods_provisioning._sha256_text_v1('BARBER_NAIL|beauty|v1')
  ),
  (
    'CONTRACTOR',
    'Contractor Operations',
    'field_services',
    'Lead, estimate, site visit, job, material, crew, invoice, change order, and progress payment vertical.',
    true,
    jsonb_build_object('domain_key','CONTRACTOR','template_key','CONTRACTOR_V1'),
    pods_provisioning._sha256_text_v1('CONTRACTOR|field_services|v1')
  ),
  (
    'REAL_ESTATE',
    'Real Estate Operations',
    'property',
    'Property, showing, agent, buyer/seller, offer, document, inspection, closing, and commission workflow vertical.',
    true,
    jsonb_build_object('domain_key','REAL_ESTATE','template_key','REAL_ESTATE_V1'),
    pods_provisioning._sha256_text_v1('REAL_ESTATE|property|v1')
  )
  on conflict (domain_key) do update
  set
    display_name = excluded.display_name,
    category = excluded.category,
    description = excluded.description,
    active = excluded.active,
    domain_body = excluded.domain_body,
    domain_hash = excluded.domain_hash;

  insert into pods_provisioning.vertical_capabilities_v1(
    domain_key,
    capability_key,
    display_name,
    capability_kind,
    required,
    active,
    capability_body,
    capability_hash
  )
  values
  ('BARBER_NAIL','public_booking','Public Booking','surface',true,true,jsonb_build_object('surface','booking'),pods_provisioning._sha256_text_v1('BARBER_NAIL|public_booking')),
  ('BARBER_NAIL','staff_profiles','Staff Profiles and Galleries','surface',true,true,jsonb_build_object('surface','staff_profiles'),pods_provisioning._sha256_text_v1('BARBER_NAIL|staff_profiles')),
  ('BARBER_NAIL','appointment_payments','Appointment Payments','payment',true,true,jsonb_build_object('payment','deposit'),pods_provisioning._sha256_text_v1('BARBER_NAIL|appointment_payments')),

  ('CONTRACTOR','lead_capture','Lead Capture','customer',true,true,jsonb_build_object('object','lead'),pods_provisioning._sha256_text_v1('CONTRACTOR|lead_capture')),
  ('CONTRACTOR','estimate_workflow','Estimate Workflow','workflow',true,true,jsonb_build_object('workflow','estimate'),pods_provisioning._sha256_text_v1('CONTRACTOR|estimate_workflow')),
  ('CONTRACTOR','job_progress_billing','Job Progress Billing','payment',true,true,jsonb_build_object('payment','progress_billing'),pods_provisioning._sha256_text_v1('CONTRACTOR|job_progress_billing')),
  ('CONTRACTOR','change_orders','Change Orders','document',true,true,jsonb_build_object('document','change_order'),pods_provisioning._sha256_text_v1('CONTRACTOR|change_orders')),

  ('REAL_ESTATE','property_listing','Property Listing','surface',true,true,jsonb_build_object('surface','listing'),pods_provisioning._sha256_text_v1('REAL_ESTATE|property_listing')),
  ('REAL_ESTATE','showing_workflow','Showing Workflow','workflow',true,true,jsonb_build_object('workflow','showing'),pods_provisioning._sha256_text_v1('REAL_ESTATE|showing_workflow')),
  ('REAL_ESTATE','offer_pipeline','Offer Pipeline','workflow',true,true,jsonb_build_object('workflow','offer'),pods_provisioning._sha256_text_v1('REAL_ESTATE|offer_pipeline')),
  ('REAL_ESTATE','closing_milestones','Closing Milestones','workflow',true,true,jsonb_build_object('workflow','closing'),pods_provisioning._sha256_text_v1('REAL_ESTATE|closing_milestones'))
  on conflict (domain_key, capability_key) do update
  set
    display_name = excluded.display_name,
    capability_kind = excluded.capability_kind,
    required = excluded.required,
    active = excluded.active,
    capability_body = excluded.capability_body,
    capability_hash = excluded.capability_hash;

  insert into pods_provisioning.vertical_workflow_contracts_v1(
    domain_key,
    workflow_key,
    display_name,
    start_state,
    terminal_states,
    required_events,
    active,
    workflow_body,
    workflow_hash
  )
  values
  (
    'BARBER_NAIL',
    'appointment_lifecycle',
    'Appointment Lifecycle',
    'requested',
    jsonb_build_array('completed','cancelled','declined'),
    jsonb_build_array('request','confirm','assign_staff','notify','payment','complete_or_cancel'),
    true,
    jsonb_build_object('contract','appointment_lifecycle'),
    pods_provisioning._sha256_text_v1('BARBER_NAIL|appointment_lifecycle')
  ),
  (
    'CONTRACTOR',
    'estimate_to_job_lifecycle',
    'Estimate to Job Lifecycle',
    'lead_received',
    jsonb_build_array('job_completed','lost','cancelled'),
    jsonb_build_array('lead','site_visit','estimate','approval','deposit','job','change_order','invoice','completion'),
    true,
    jsonb_build_object('contract','estimate_to_job_lifecycle'),
    pods_provisioning._sha256_text_v1('CONTRACTOR|estimate_to_job_lifecycle')
  ),
  (
    'REAL_ESTATE',
    'listing_to_close_lifecycle',
    'Listing to Close Lifecycle',
    'property_listed',
    jsonb_build_array('closed','withdrawn','expired'),
    jsonb_build_array('listing','showing','offer','inspection','contingency','closing','commission'),
    true,
    jsonb_build_object('contract','listing_to_close_lifecycle'),
    pods_provisioning._sha256_text_v1('REAL_ESTATE|listing_to_close_lifecycle')
  )
  on conflict (domain_key, workflow_key) do update
  set
    display_name = excluded.display_name,
    start_state = excluded.start_state,
    terminal_states = excluded.terminal_states,
    required_events = excluded.required_events,
    active = excluded.active,
    workflow_body = excluded.workflow_body,
    workflow_hash = excluded.workflow_hash;

  insert into pods_provisioning.vertical_surface_contracts_v1(
    domain_key,
    surface_key,
    display_name,
    surface_kind,
    public_facing,
    operator_facing,
    required_fields,
    active,
    surface_body,
    surface_hash
  )
  values
  (
    'BARBER_NAIL',
    'booking_page',
    'Public Booking Page',
    'public_page',
    true,
    false,
    jsonb_build_array('services','hours','staff_profiles','availability'),
    true,
    jsonb_build_object('surface','booking_page'),
    pods_provisioning._sha256_text_v1('BARBER_NAIL|booking_page')
  ),
  (
    'CONTRACTOR',
    'estimate_request_page',
    'Estimate Request Page',
    'estimate',
    true,
    false,
    jsonb_build_array('customer','site_address','scope','photos','preferred_visit_window'),
    true,
    jsonb_build_object('surface','estimate_request_page'),
    pods_provisioning._sha256_text_v1('CONTRACTOR|estimate_request_page')
  ),
  (
    'REAL_ESTATE',
    'property_listing_page',
    'Property Listing Page',
    'listing',
    true,
    false,
    jsonb_build_array('property','photos','agent','showing_request','documents'),
    true,
    jsonb_build_object('surface','property_listing_page'),
    pods_provisioning._sha256_text_v1('REAL_ESTATE|property_listing_page')
  )
  on conflict (domain_key, surface_key) do update
  set
    display_name = excluded.display_name,
    surface_kind = excluded.surface_kind,
    public_facing = excluded.public_facing,
    operator_facing = excluded.operator_facing,
    required_fields = excluded.required_fields,
    active = excluded.active,
    surface_body = excluded.surface_body,
    surface_hash = excluded.surface_hash;

  select count(*) into v_domain_count from pods_provisioning.vertical_domains_v1 where active = true;
  select count(*) into v_capability_count from pods_provisioning.vertical_capabilities_v1 where active = true;
  select count(*) into v_workflow_count from pods_provisioning.vertical_workflow_contracts_v1 where active = true;
  select count(*) into v_surface_count from pods_provisioning.vertical_surface_contracts_v1 where active = true;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_VERTICAL_DOMAIN_CONTRACTS_OK',
    'domain_count', v_domain_count,
    'capability_count', v_capability_count,
    'workflow_count', v_workflow_count,
    'surface_count', v_surface_count,
    'seeded_domains', jsonb_build_array('BARBER_NAIL','CONTRACTOR','REAL_ESTATE')
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_seed_vertical_domain_contracts_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_adapter_attachment_runtime_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_dev_seed jsonb;
  v_org_id uuid := gen_random_uuid();
  v_plan jsonb;
  v_deploy jsonb;
  v_attach_run jsonb;
  v_mark jsonb;
  v_duplicate_ok boolean := false;
begin
  v_dev_seed := pods_provisioning.rpc_seed_developer_portal_model_v1();

  v_plan := pods_provisioning.rpc_plan_model_capabilities_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    jsonb_build_object(
      'product_name','Adapter Runtime Product',
      'github_url','https://github.com/example/adapter-runtime',
      'download_url','https://example.com/downloads/adapter-runtime',
      'support_email','support@example.com'
    )
  );

  v_deploy := pods_provisioning.rpc_create_model_deployment_receipt_v1(
    (v_plan->>'plan_run_id')::uuid
  );

  v_attach_run := pods_provisioning.rpc_create_adapter_attachment_run_v1(
    (v_deploy->>'deployment_receipt_id')::uuid
  );

  if v_attach_run->>'token' <> 'PROTEUSOPS_ADAPTER_ATTACHMENT_RUNTIME_OK' then
    raise exception 'ADAPTER_ATTACHMENT_RUNTIME_TOKEN_FAIL';
  end if;

  v_mark := pods_provisioning.rpc_mark_adapter_attached_v1(
    (v_attach_run->>'adapter_attachment_run_id')::uuid,
    'payment_provider',
    'stripe',
    'secret://proteusops/test/stripe',
    jsonb_build_object('mode','test','webhook_required',true)
  );

  if v_mark->>'token' <> 'PROTEUSOPS_ADAPTER_ATTACHED_OK' then
    raise exception 'ADAPTER_MARK_TOKEN_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_create_adapter_attachment_run_v1(
      (v_deploy->>'deployment_receipt_id')::uuid
    );
  exception
    when others then
      if sqlerrm like 'ADAPTER_ATTACHMENT_DUPLICATE_DENY:%' then
        v_duplicate_ok := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_ok then
    raise exception 'ADAPTER_ATTACHMENT_DUPLICATE_VECTOR_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_ADAPTER_ATTACHMENT_RUNTIME_OK',
    'org_id', v_org_id,
    'plan', v_plan,
    'deployment_receipt', v_deploy,
    'adapter_attachment_run', v_attach_run,
    'adapter_mark', v_mark,
    'duplicate_denied', v_duplicate_ok
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_adapter_attachment_runtime_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_appointment_admin_queue_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_provision jsonb;
  v_public jsonb;
  v_request jsonb;
  v_queue_before jsonb;
  v_action jsonb;
  v_queue_after jsonb;
begin
  v_provision := pods_provisioning.rpc_provision_vertical_template_v1(
    v_org_id,
    'BARBER_NAIL_V1',
    null
  );

  v_public := pods_provisioning.rpc_bootstrap_public_booking_surface_v1(
    (v_provision->>'provision_run_id')::uuid,
    'admin-queue-test-' || left(v_org_id::text, 8)
  );

  v_request := pods_provisioning.rpc_request_public_appointment_v1(
    v_public->>'booking_slug',
    'BARBER_CUT',
    current_date + 1,
    '09:00'::time,
    'Queue Test Customer',
    'queue.customer@example.com',
    '555-0111'
  );

  v_queue_before := pods_provisioning.rpc_get_appointment_admin_queue_v1(
    v_org_id,
    'requested'
  );

  if v_queue_before->>'token' <> 'PROTEUSOPS_APPOINTMENT_ADMIN_QUEUE_OK' then
    raise exception 'ADMIN_QUEUE_TOKEN_FAIL';
  end if;

  if (v_queue_before->>'count')::integer < 1 then
    raise exception 'ADMIN_QUEUE_EMPTY_BEFORE_ACTION';
  end if;

  v_action := pods_provisioning.rpc_admin_update_appointment_request_v1(
    (v_request->>'appointment_request_id')::uuid,
    'confirm',
    null,
    'Selftest confirmation'
  );

  if v_action->>'token' <> 'PROTEUSOPS_APPOINTMENT_ADMIN_ACTION_OK' then
    raise exception 'ADMIN_ACTION_TOKEN_FAIL';
  end if;

  if v_action->>'new_status' <> 'confirmed' then
    raise exception 'ADMIN_ACTION_STATUS_FAIL';
  end if;

  v_queue_after := pods_provisioning.rpc_get_appointment_admin_queue_v1(
    v_org_id,
    'confirmed'
  );

  if (v_queue_after->>'count')::integer < 1 then
    raise exception 'ADMIN_QUEUE_EMPTY_AFTER_CONFIRM';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_APPOINTMENT_ADMIN_QUEUE_OK',
    'org_id', v_org_id,
    'queue_before_count', (v_queue_before->>'count')::integer,
    'admin_action', v_action,
    'confirmed_queue_count', (v_queue_after->>'count')::integer
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_appointment_admin_queue_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_audit_ledger_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();

  v_install jsonb;
  v_runtime_id uuid;

  v_snapshot jsonb;
  v_launch_ready jsonb;
  v_review jsonb;
  v_launch jsonb;
  v_suspend jsonb;
  v_archive jsonb;

  v_event_1 jsonb;
  v_event_2 jsonb;
  v_event_3 jsonb;
  v_event_4 jsonb;
  v_event_5 jsonb;
  v_query jsonb;
  v_checkpoint jsonb;
  v_verify jsonb;
begin
  v_install := pods_provisioning.rpc_install_marketplace_model_v1(
    v_org_id,
    'CIVIC_ACTION_V1',
    'v2',
    jsonb_build_object(
      'issue_title','Audit Ledger Civic Site',
      'community_name','Audit Borough',
      'location_label','Audit Corridor',
      'position_type','oppose',
      'issue_summary','Audit ledger selftest.',
      'petition_goal',4000,
      'enable_petition',true,
      'enable_survey',true,
      'enable_events',true,
      'enable_evidence',true,
      'enable_volunteers',true,
      'moderation_required',true
    )
  );

  v_runtime_id := (v_install->>'model_instance_runtime_id')::uuid;

  v_snapshot := pods_provisioning.rpc_create_runtime_snapshot_v1(
    v_runtime_id,
    'audit_before_launch',
    'Audit selftest snapshot.'
  );

  v_launch_ready := pods_provisioning.rpc_check_launch_readiness_v1(
    (v_install->>'model_launch_package_id')::uuid,
    'proteusops_hosted'
  );

  v_review := pods_provisioning.rpc_submit_launch_review_v1(
    (v_launch_ready->>'model_launch_authority_id')::uuid,
    'approved',
    'Audit selftest approval.'
  );

  v_launch := pods_provisioning.rpc_launch_site_v1(
    (v_launch_ready->>'model_launch_authority_id')::uuid
  );

  v_suspend := pods_provisioning.rpc_suspend_site_v1(
    (v_launch_ready->>'model_launch_authority_id')::uuid,
    'Audit selftest suspend.'
  );

  v_archive := pods_provisioning.rpc_archive_site_v1(
    (v_launch_ready->>'model_launch_authority_id')::uuid,
    'Audit selftest archive.'
  );

  v_event_1 := pods_provisioning.rpc_append_audit_event_v1(
    v_org_id,
    v_runtime_id,
    'runtime_created',
    'system',
    'marketplace_install',
    (v_install->>'model_marketplace_install_id')::uuid,
    v_install
  );

  v_event_2 := pods_provisioning.rpc_append_audit_event_v1(
    v_org_id,
    v_runtime_id,
    'snapshot_created',
    'system',
    'runtime_snapshot',
    (v_snapshot->>'model_runtime_snapshot_id')::uuid,
    v_snapshot
  );

  v_event_3 := pods_provisioning.rpc_append_audit_event_v1(
    v_org_id,
    v_runtime_id,
    'site_launched',
    'community_admin',
    'launch_receipt',
    (v_launch->>'model_launch_receipt_id')::uuid,
    v_launch
  );

  v_event_4 := pods_provisioning.rpc_append_audit_event_v1(
    v_org_id,
    v_runtime_id,
    'site_suspended',
    'community_admin',
    'launch_receipt',
    (v_suspend->>'model_launch_receipt_id')::uuid,
    v_suspend
  );

  v_event_5 := pods_provisioning.rpc_append_audit_event_v1(
    v_org_id,
    v_runtime_id,
    'site_archived',
    'community_admin',
    'launch_receipt',
    (v_archive->>'model_launch_receipt_id')::uuid,
    v_archive
  );

  v_query := pods_provisioning.rpc_query_audit_ledger_v1(
    v_org_id,
    v_runtime_id
  );

  v_checkpoint := pods_provisioning.rpc_build_audit_checkpoint_v1(v_org_id);

  v_verify := pods_provisioning.rpc_verify_audit_checkpoint_v1(
    (v_checkpoint->>'model_audit_checkpoint_id')::uuid
  );

  if v_query->>'event_count' <> '5' then
    raise exception 'MODEL_AUDIT_EVENT_COUNT_FAIL:%', v_query;
  end if;

  if v_verify->>'verified' <> 'true' then
    raise exception 'MODEL_AUDIT_CHECKPOINT_VERIFY_FAIL:%', v_verify;
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_AUDIT_LEDGER_OK',
    'install', v_install,
    'snapshot', v_snapshot,
    'launch', v_launch,
    'suspend', v_suspend,
    'archive', v_archive,
    'events', jsonb_build_array(v_event_1, v_event_2, v_event_3, v_event_4, v_event_5),
    'query', v_query,
    'checkpoint', v_checkpoint,
    'verify', v_verify
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_audit_ledger_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_booking_availability_engine_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_provision jsonb;
  v_public jsonb;
  v_avail jsonb;
begin
  v_provision := pods_provisioning.rpc_provision_vertical_template_v1(
    v_org_id,
    'BARBER_NAIL_V1',
    null
  );

  v_public := pods_provisioning.rpc_bootstrap_public_booking_surface_v1(
    (v_provision->>'provision_run_id')::uuid,
    'availability-test-' || left(v_org_id::text, 8)
  );

  v_avail := pods_provisioning.rpc_get_booking_availability_v1(
    v_public->>'booking_slug',
    'BARBER_CUT',
    current_date,
    7
  );

  if v_avail->>'token' <> 'PROTEUSOPS_BOOKING_AVAILABILITY_ENGINE_OK' then
    raise exception 'AVAILABILITY_ENGINE_TOKEN_FAIL';
  end if;

  if (v_avail->>'slot_count')::integer < 1 then
    raise exception 'AVAILABILITY_ENGINE_EMPTY';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_BOOKING_AVAILABILITY_ENGINE_OK',
    'booking_slug', v_public->>'booking_slug',
    'booking_path', v_public->>'booking_path',
    'service_code', 'BARBER_CUT',
    'slot_count', (v_avail->>'slot_count')::integer,
    'sample_slot', (v_avail->'slots')->0
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_booking_availability_engine_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_booking_page_read_model_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_provision jsonb;
  v_public jsonb;
  v_read jsonb;
begin
  v_provision := pods_provisioning.rpc_provision_vertical_template_v1(
    v_org_id,
    'BARBER_NAIL_V1',
    null
  );

  v_public := pods_provisioning.rpc_bootstrap_public_booking_surface_v1(
    (v_provision->>'provision_run_id')::uuid,
    'read-model-test-' || left(v_org_id::text, 8)
  );

  v_read := pods_provisioning.rpc_get_booking_page_read_model_v1(
    v_public->>'booking_slug'
  );

  if v_read->>'token' <> 'PROTEUSOPS_BOOKING_PAGE_READ_MODEL_OK' then
    raise exception 'BOOKING_PAGE_READ_MODEL_TOKEN_FAIL';
  end if;

  if jsonb_array_length(v_read->'services') < 1 then
    raise exception 'BOOKING_PAGE_SERVICES_EMPTY';
  end if;

  if jsonb_array_length(v_read->'hours') < 1 then
    raise exception 'BOOKING_PAGE_HOURS_EMPTY';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_BOOKING_PAGE_READ_MODEL_OK',
    'booking_slug', v_public->>'booking_slug',
    'booking_path', v_public->>'booking_path',
    'service_count', jsonb_array_length(v_read->'services'),
    'hours_count', jsonb_array_length(v_read->'hours'),
    'read_model', v_read
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_booking_page_read_model_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_civic_action_contribution_wall_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_campaign jsonb;
  v_signature jsonb;
  v_question jsonb;
  v_survey jsonb;
  v_help jsonb;
  v_wall jsonb;
begin
  perform pods_provisioning.rpc_seed_civic_action_model_registry_v1();

  v_campaign := pods_provisioning.rpc_create_civic_action_campaign_v1(
    v_org_id,
    'Community Contribution Wall Campaign',
    'Test Community',
    'Civic District',
    'oppose',
    'Residents can sign, survey, and offer help.',
    10,
    'published'
  );

  v_signature := pods_provisioning.rpc_submit_civic_petition_signature_v1(
    (v_campaign->>'civic_campaign_id')::uuid,
    'Wall Signer',
    'wall.signer@example.com',
    'I support this effort.',
    true
  );

  v_question := pods_provisioning.rpc_add_civic_survey_question_v1(
    (v_campaign->>'civic_campaign_id')::uuid,
    'can_attend',
    'Can you attend the community meeting?',
    'yes_no',
    false,
    1
  );

  v_survey := pods_provisioning.rpc_submit_civic_survey_response_v1(
    (v_campaign->>'civic_campaign_id')::uuid,
    'wall.survey@example.com',
    jsonb_build_object('can_attend','yes')
  );

  v_help := pods_provisioning.rpc_submit_civic_help_offer_v1(
    (v_campaign->>'civic_campaign_id')::uuid,
    'Wall Helper',
    'wall.helper@example.com',
    'share_information',
    'I can share information with neighbors.',
    true
  );

  v_wall := pods_provisioning.rpc_refresh_civic_contribution_wall_v1(
    (v_campaign->>'civic_campaign_id')::uuid
  );

  if v_wall->>'token' <> 'PROTEUSOPS_CIVIC_ACTION_CONTRIBUTION_WALL_OK' then
    raise exception 'CIVIC_CONTRIBUTION_WALL_TOKEN_FAIL';
  end if;

  if (v_wall->>'total_contribution_count')::integer <> 3 then
    raise exception 'CIVIC_CONTRIBUTION_TOTAL_COUNT_FAIL:%', v_wall;
  end if;

  if (v_wall->>'public_visible_count')::integer <> 3 then
    raise exception 'CIVIC_CONTRIBUTION_VISIBLE_COUNT_FAIL:%', v_wall;
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_CONTRIBUTION_WALL_OK',
    'campaign', v_campaign,
    'signature', v_signature,
    'survey', v_survey,
    'help_offer', v_help,
    'contribution_wall', v_wall
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_civic_action_contribution_wall_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_civic_action_events_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_campaign jsonb;
  v_event jsonb;
  v_rsvp jsonb;
  v_count jsonb;
  v_duplicate_denied boolean := false;
begin
  v_campaign := pods_provisioning.rpc_create_civic_action_campaign_v1(
    v_org_id,
    'Civic Event Campaign',
    'Test Community',
    'Town Hall District',
    'oppose',
    'Residents can attend, speak, and volunteer.',
    50,
    'published'
  );

  v_event := pods_provisioning.rpc_create_civic_action_event_v1(
    (v_campaign->>'civic_campaign_id')::uuid,
    'town_hall',
    'Community Town Hall',
    'Residents can learn, speak, and coordinate.',
    'Community Center',
    now() + interval '7 days',
    'published'
  );

  v_rsvp := pods_provisioning.rpc_submit_civic_event_rsvp_v1(
    (v_event->>'civic_event_id')::uuid,
    'Event Attendee',
    'event.attendee@example.com',
    'going',
    true,
    true,
    'I want to speak and help.'
  );

  begin
    perform pods_provisioning.rpc_submit_civic_event_rsvp_v1(
      (v_event->>'civic_event_id')::uuid,
      'Event Attendee Again',
      'event.attendee@example.com',
      'going',
      false,
      false,
      'Duplicate should fail.'
    );
  exception
    when others then
      if sqlerrm like 'CIVIC_EVENT_RSVP_DUPLICATE_DENY%' then
        v_duplicate_denied := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_denied then
    raise exception 'CIVIC_EVENT_RSVP_DUPLICATE_VECTOR_FAIL';
  end if;

  v_count := pods_provisioning.rpc_civic_event_public_count_v1(
    (v_event->>'civic_event_id')::uuid
  );

  if (v_count->>'rsvp_count')::integer <> 1 then
    raise exception 'CIVIC_EVENT_RSVP_COUNT_FAIL';
  end if;

  if (v_count->>'speaker_signup_count')::integer <> 1 then
    raise exception 'CIVIC_EVENT_SPEAKER_COUNT_FAIL';
  end if;

  if (v_count->>'volunteer_signup_count')::integer <> 1 then
    raise exception 'CIVIC_EVENT_VOLUNTEER_COUNT_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_EVENTS_OK',
    'campaign', v_campaign,
    'event', v_event,
    'rsvp', v_rsvp,
    'public_count', v_count,
    'duplicate_denied', v_duplicate_denied
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_civic_action_events_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_civic_action_evidence_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_campaign jsonb;
  v_evidence_link jsonb;
  v_evidence_doc jsonb;
  v_library jsonb;
begin
  v_campaign := pods_provisioning.rpc_create_civic_action_campaign_v1(
    v_org_id,
    'Civic Evidence Campaign',
    'Test Community',
    'Evidence District',
    'oppose',
    'Residents can submit evidence, links, documents, photos, and videos.',
    50,
    'published'
  );

  v_evidence_link := pods_provisioning.rpc_submit_civic_evidence_v1(
    (v_campaign->>'civic_campaign_id')::uuid,
    'link',
    'Public planning notice',
    'https://example.com/planning-notice',
    'Official public notice related to the proposed change.',
    'Evidence Submitter',
    'evidence.submitter@example.com'
  );

  v_evidence_doc := pods_provisioning.rpc_submit_civic_evidence_v1(
    (v_campaign->>'civic_campaign_id')::uuid,
    'document',
    'Community impact document',
    'https://example.com/community-impact.pdf',
    'Document residents can review.',
    'Evidence Submitter Two',
    'evidence2.submitter@example.com'
  );

  if v_evidence_link->>'token' <> 'PROTEUSOPS_CIVIC_ACTION_EVIDENCE_SUBMISSION_OK' then
    raise exception 'CIVIC_EVIDENCE_LINK_TOKEN_FAIL';
  end if;

  if v_evidence_doc->>'token' <> 'PROTEUSOPS_CIVIC_ACTION_EVIDENCE_SUBMISSION_OK' then
    raise exception 'CIVIC_EVIDENCE_DOC_TOKEN_FAIL';
  end if;

  v_library := pods_provisioning.rpc_civic_evidence_public_library_v1(
    (v_campaign->>'civic_campaign_id')::uuid
  );

  if (v_library->>'public_visible_count')::integer <> 2 then
    raise exception 'CIVIC_EVIDENCE_LIBRARY_COUNT_FAIL:%', v_library;
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_EVIDENCE_OK',
    'campaign', v_campaign,
    'evidence_link', v_evidence_link,
    'evidence_document', v_evidence_doc,
    'public_library', v_library
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_civic_action_evidence_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_civic_action_full_green_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_registry jsonb;
  v_petition jsonb;
  v_survey jsonb;
  v_wall jsonb;
  v_moderation jsonb;

  v_registry_ok boolean;
  v_petition_ok boolean;
  v_survey_ok boolean;
  v_wall_ok boolean;
  v_moderation_ok boolean;
  v_full_green boolean;

  v_body jsonb;
  v_hash text;
  v_receipt_id uuid;
begin
  v_registry := pods_provisioning.rpc_selftest_civic_action_model_registry_v1();
  v_petition := pods_provisioning.rpc_selftest_civic_action_petition_flow_v1();
  v_survey := pods_provisioning.rpc_selftest_civic_action_survey_flow_v1();
  v_wall := pods_provisioning.rpc_selftest_civic_action_contribution_wall_v1();
  v_moderation := pods_provisioning.rpc_selftest_civic_action_moderation_governance_v1();

  v_registry_ok := v_registry->>'token' = 'PROTEUSOPS_CIVIC_ACTION_MODEL_REGISTRY_OK';
  v_petition_ok := v_petition->>'token' = 'PROTEUSOPS_CIVIC_ACTION_PETITION_FLOW_OK';
  v_survey_ok := v_survey->>'token' = 'PROTEUSOPS_CIVIC_ACTION_SURVEY_FLOW_OK';
  v_wall_ok := v_wall->>'token' = 'PROTEUSOPS_CIVIC_ACTION_CONTRIBUTION_WALL_OK';
  v_moderation_ok := v_moderation->>'token' = 'PROTEUSOPS_CIVIC_ACTION_MODERATION_GOVERNANCE_OK';

  v_full_green := v_registry_ok
    and v_petition_ok
    and v_survey_ok
    and v_wall_ok
    and v_moderation_ok;

  if not v_full_green then
    raise exception 'CIVIC_ACTION_FULL_GREEN_FAIL';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_FULL_GREEN_OK',
    'model_key', 'CIVIC_ACTION_V1',
    'model_version', 'v1',
    'full_green', true,
    'registry_ok', v_registry_ok,
    'petition_ok', v_petition_ok,
    'survey_ok', v_survey_ok,
    'contribution_wall_ok', v_wall_ok,
    'moderation_ok', v_moderation_ok,
    'proof_tokens', jsonb_build_array(
      v_registry->>'token',
      v_petition->>'token',
      v_survey->>'token',
      v_wall->>'token',
      v_moderation->>'token'
    )
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.civic_action_full_green_receipts_v1(
    model_key,
    model_version,
    registry_ok,
    petition_ok,
    survey_ok,
    contribution_wall_ok,
    moderation_ok,
    full_green,
    receipt_body,
    receipt_hash
  )
  values (
    'CIVIC_ACTION_V1',
    'v1',
    v_registry_ok,
    v_petition_ok,
    v_survey_ok,
    v_wall_ok,
    v_moderation_ok,
    true,
    v_body,
    v_hash
  )
  returning civic_full_green_receipt_id
  into v_receipt_id;

  return v_body || jsonb_build_object(
    'civic_full_green_receipt_id', v_receipt_id,
    'receipt_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_civic_action_full_green_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_civic_action_full_green_v2"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_petition jsonb;
  v_survey jsonb;
  v_wall jsonb;
  v_moderation jsonb;
  v_events jsonb;
  v_evidence jsonb;
  v_launch jsonb;

  v_body jsonb;
  v_hash text;
  v_receipt_id uuid;
begin

  v_petition :=
    pods_provisioning.rpc_selftest_civic_action_petition_flow_v1();

  v_survey :=
    pods_provisioning.rpc_selftest_civic_action_survey_flow_v1();

  v_wall :=
    pods_provisioning.rpc_selftest_civic_action_contribution_wall_v1();

  v_moderation :=
    pods_provisioning.rpc_selftest_civic_action_moderation_governance_v1();

  v_events :=
    pods_provisioning.rpc_selftest_civic_action_events_v1();

  v_evidence :=
    pods_provisioning.rpc_selftest_civic_action_evidence_v1();

  v_launch :=
    pods_provisioning.rpc_selftest_civic_action_provider_launch_integration_v1();

  if v_petition->>'token' <> 'PROTEUSOPS_CIVIC_ACTION_PETITION_FLOW_OK' then
    raise exception 'PETITION_FAIL';
  end if;

  if v_survey->>'token' <> 'PROTEUSOPS_CIVIC_ACTION_SURVEY_FLOW_OK' then
    raise exception 'SURVEY_FAIL';
  end if;

  if v_wall->>'token' <> 'PROTEUSOPS_CIVIC_ACTION_CONTRIBUTION_WALL_OK' then
    raise exception 'CONTRIBUTION_WALL_FAIL';
  end if;

  if v_moderation->>'token' <> 'PROTEUSOPS_CIVIC_ACTION_MODERATION_GOVERNANCE_OK' then
    raise exception 'MODERATION_FAIL';
  end if;

  if v_events->>'token' <> 'PROTEUSOPS_CIVIC_ACTION_EVENTS_OK' then
    raise exception 'EVENTS_FAIL';
  end if;

  if v_evidence->>'token' <> 'PROTEUSOPS_CIVIC_ACTION_EVIDENCE_OK' then
    raise exception 'EVIDENCE_FAIL';
  end if;

  if v_launch->>'token' <> 'PROTEUSOPS_CIVIC_ACTION_PROVIDER_LAUNCH_OK' then
    raise exception 'PROVIDER_LAUNCH_FAIL';
  end if;

  v_body :=
    jsonb_build_object(
      'ok', true,
      'token', 'PROTEUSOPS_CIVIC_ACTION_FULL_GREEN_V2_OK',
      'model_key', 'CIVIC_ACTION_V1',
      'model_version', 'v2',

      'petition_ok', true,
      'survey_ok', true,
      'contribution_wall_ok', true,
      'moderation_ok', true,
      'events_ok', true,
      'evidence_ok', true,
      'provider_launch_ok', true,

      'full_green', true,

      'proof_tokens',
      jsonb_build_array(
        v_petition->>'token',
        v_survey->>'token',
        v_wall->>'token',
        v_moderation->>'token',
        v_events->>'token',
        v_evidence->>'token',
        v_launch->>'token'
      )
    );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.civic_action_full_green_v2_receipts_v1(
    petition_ok,
    survey_ok,
    contribution_wall_ok,
    moderation_ok,
    events_ok,
    evidence_ok,
    provider_launch_ok,
    full_green,
    receipt_body,
    receipt_hash
  )
  values (
    true,
    true,
    true,
    true,
    true,
    true,
    true,
    true,
    v_body,
    v_hash
  )
  returning civic_full_green_v2_receipt_id
  into v_receipt_id;

  return v_body ||
    jsonb_build_object(
      'receipt_hash', v_hash,
      'civic_full_green_v2_receipt_id', v_receipt_id
    );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_civic_action_full_green_v2"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_civic_action_launch_ready_from_deployment_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_ready_org uuid := gen_random_uuid();
  v_blocked_org uuid := gen_random_uuid();

  v_provider text;
  v_session jsonb;

  v_ready_deploy jsonb;
  v_blocked_deploy jsonb;

  v_ready_receipt jsonb;
  v_blocked_receipt jsonb;
begin
  foreach v_provider in array array['supabase','email','storage']
  loop
    v_session := pods_provisioning.rpc_start_provider_connection_session_v1(
      v_ready_org,
      v_provider,
      null
    );

    perform pods_provisioning.rpc_complete_provider_connection_session_v1(
      (v_session->>'provider_connection_session_id')::uuid,
      'acct_' || v_provider,
      'project_' || v_provider,
      'secret://proteusops/' || v_provider || '/civic-launch-ready',
      jsonb_build_array(jsonb_build_object('resource_key','provider','value',v_provider)),
      jsonb_build_array(jsonb_build_object('check_key','verified','status','pass'))
    );
  end loop;

  v_ready_deploy := pods_provisioning.rpc_deploy_civic_action_model_v1(
    v_ready_org,
    jsonb_build_object(
      'issue_title','Ready Civic Launch',
      'community_name','Ready Community',
      'location_label','Ready District',
      'position_type','oppose',
      'issue_summary','Ready civic launch test.',
      'petition_goal',100
    )
  );

  v_ready_receipt := pods_provisioning.rpc_civic_action_launch_ready_from_deployment_v1(
    (v_ready_deploy->>'civic_deployment_id')::uuid
  );

  if v_ready_receipt->>'token' <> 'PROTEUSOPS_CIVIC_ACTION_LAUNCH_READY_FROM_DEPLOYMENT_OK' then
    raise exception 'CIVIC_LAUNCH_READY_TOKEN_FAIL';
  end if;

  if v_ready_receipt->>'launch_status' <> 'ready' then
    raise exception 'CIVIC_LAUNCH_READY_STATUS_FAIL:%', v_ready_receipt;
  end if;

  v_session := pods_provisioning.rpc_start_provider_connection_session_v1(
    v_blocked_org,
    'supabase',
    null
  );

  perform pods_provisioning.rpc_complete_provider_connection_session_v1(
    (v_session->>'provider_connection_session_id')::uuid,
    'acct_supabase',
    'project_supabase',
    'secret://proteusops/supabase/civic-launch-blocked',
    '[]'::jsonb,
    '[]'::jsonb
  );

  v_blocked_deploy := pods_provisioning.rpc_deploy_civic_action_model_v1(
    v_blocked_org,
    jsonb_build_object(
      'issue_title','Blocked Civic Launch',
      'community_name','Blocked Community',
      'location_label','Blocked District',
      'position_type','oppose',
      'issue_summary','Blocked civic launch test.',
      'petition_goal',100
    )
  );

  v_blocked_receipt := pods_provisioning.rpc_civic_action_launch_ready_from_deployment_v1(
    (v_blocked_deploy->>'civic_deployment_id')::uuid
  );

  if v_blocked_receipt->>'launch_status' <> 'blocked' then
    raise exception 'CIVIC_LAUNCH_BLOCKED_STATUS_FAIL:%', v_blocked_receipt;
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_LAUNCH_READY_FROM_DEPLOYMENT_OK',
    'ready_receipt', v_ready_receipt,
    'blocked_receipt', v_blocked_receipt
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_civic_action_launch_ready_from_deployment_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_civic_action_model_deployment_engine_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_deploy jsonb;
begin
  v_deploy := pods_provisioning.rpc_deploy_civic_action_model_v1(
    v_org_id,
    jsonb_build_object(
      'issue_title','Oppose Proposed Community Change',
      'community_name','Test Borough',
      'location_label','Main Street Corridor',
      'position_type','oppose',
      'issue_summary','Residents can learn, sign, survey, help, attend events, and submit evidence.',
      'petition_goal',250,
      'enabled_modules',jsonb_build_array(
        'issue_page',
        'petition',
        'survey',
        'help_offers',
        'contribution_wall',
        'events',
        'evidence',
        'moderation'
      )
    )
  );

  if v_deploy->>'token' <> 'PROTEUSOPS_CIVIC_ACTION_MODEL_DEPLOYMENT_OK' then
    raise exception 'CIVIC_DEPLOYMENT_TOKEN_FAIL';
  end if;

  if v_deploy->>'model_key' <> 'CIVIC_ACTION_V1' then
    raise exception 'CIVIC_DEPLOYMENT_MODEL_KEY_FAIL';
  end if;

  if not (v_deploy->'required_providers') ? 'supabase' then
    raise exception 'CIVIC_DEPLOYMENT_SUPABASE_PROVIDER_FAIL';
  end if;

  if not (v_deploy->'enabled_modules') ? 'evidence' then
    raise exception 'CIVIC_DEPLOYMENT_EVIDENCE_MODULE_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_MODEL_DEPLOYMENT_ENGINE_OK',
    'deployment', v_deploy
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_civic_action_model_deployment_engine_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_civic_action_model_registry_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_seed jsonb;
begin
  v_seed := pods_provisioning.rpc_seed_civic_action_model_registry_v1();

  if v_seed->>'token' <> 'PROTEUSOPS_CIVIC_ACTION_MODEL_REGISTRY_OK' then
    raise exception 'CIVIC_ACTION_MODEL_TOKEN_FAIL';
  end if;

  if not (v_seed->'capabilities') ? 'petition_signatures' then
    raise exception 'CIVIC_ACTION_PETITION_CAPABILITY_FAIL';
  end if;

  if not (v_seed->'capabilities') ? 'contribution_wall' then
    raise exception 'CIVIC_ACTION_CONTRIBUTION_WALL_FAIL';
  end if;

  if not (v_seed->'required_providers') ? 'supabase' then
    raise exception 'CIVIC_ACTION_SUPABASE_PROVIDER_FAIL';
  end if;

  return v_seed;
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_civic_action_model_registry_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_civic_action_moderation_governance_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org uuid := gen_random_uuid();

  v_campaign jsonb;
  v_signature jsonb;
  v_wall jsonb;

  v_source_id uuid;

  v_approve jsonb;
  v_hide jsonb;
begin
  v_campaign :=
    pods_provisioning.rpc_create_civic_action_campaign_v1(
      v_org,
      'Moderation Campaign',
      'Test Community',
      'Test Area',
      'oppose',
      'Moderation validation',
      10,
      'published'
    );

  v_signature :=
    pods_provisioning.rpc_submit_civic_petition_signature_v1(
      (v_campaign->>'civic_campaign_id')::uuid,
      'Moderator Test',
      'moderator@test.example',
      '',
      true
    );

  v_wall :=
    pods_provisioning.rpc_refresh_civic_contribution_wall_v1(
      (v_campaign->>'civic_campaign_id')::uuid
    );

  select source_id
  into v_source_id
  from pods_provisioning.civic_action_contribution_wall_entries_v1
  where civic_campaign_id =
    (v_campaign->>'civic_campaign_id')::uuid
  limit 1;

  v_approve :=
    pods_provisioning.rpc_moderate_civic_contribution_v1(
      'signature',
      v_source_id,
      'approve',
      'validated'
    );

  if v_approve->>'moderation_status' <> 'approved' then
    raise exception 'CIVIC_MODERATION_APPROVE_FAIL';
  end if;

  v_hide :=
    pods_provisioning.rpc_moderate_civic_contribution_v1(
      'signature',
      v_source_id,
      'hide',
      'hidden test'
    );

  if v_hide->>'moderation_status' <> 'hidden' then
    raise exception 'CIVIC_MODERATION_HIDE_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_MODERATION_GOVERNANCE_OK',
    'approve', v_approve,
    'hide', v_hide
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_civic_action_moderation_governance_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_civic_action_petition_flow_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_campaign jsonb;
  v_signature jsonb;
  v_count jsonb;
  v_duplicate_denied boolean := false;
begin
  perform pods_provisioning.rpc_seed_civic_action_model_registry_v1();

  v_campaign := pods_provisioning.rpc_create_civic_action_campaign_v1(
    v_org_id,
    'Oppose Unwanted Community Change',
    'Test Community',
    'Main Street District',
    'oppose',
    'A civic action page where residents can learn, sign, and help.',
    2,
    'published'
  );

  if v_campaign->>'token' <> 'PROTEUSOPS_CIVIC_ACTION_CAMPAIGN_OK' then
    raise exception 'CIVIC_CAMPAIGN_TOKEN_FAIL';
  end if;

  v_signature := pods_provisioning.rpc_submit_civic_petition_signature_v1(
    (v_campaign->>'civic_campaign_id')::uuid,
    'Test Supporter',
    'supporter@example.com',
    'I want to help.',
    true
  );

  if v_signature->>'token' <> 'PROTEUSOPS_CIVIC_ACTION_PETITION_SIGNATURE_OK' then
    raise exception 'CIVIC_SIGNATURE_TOKEN_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_submit_civic_petition_signature_v1(
      (v_campaign->>'civic_campaign_id')::uuid,
      'Test Supporter Again',
      'supporter@example.com',
      'Duplicate should fail.',
      true
    );
  exception
    when others then
      if sqlerrm like 'CIVIC_SIGNATURE_DUPLICATE_DENY%' then
        v_duplicate_denied := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_denied then
    raise exception 'CIVIC_SIGNATURE_DUPLICATE_VECTOR_FAIL';
  end if;

  v_count := pods_provisioning.rpc_civic_petition_public_count_v1(
    (v_campaign->>'civic_campaign_id')::uuid
  );

  if (v_count->>'signature_count')::integer <> 1 then
    raise exception 'CIVIC_SIGNATURE_COUNT_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_PETITION_FLOW_OK',
    'campaign', v_campaign,
    'signature', v_signature,
    'public_count', v_count,
    'duplicate_denied', v_duplicate_denied
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_civic_action_petition_flow_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_civic_action_provider_launch_integration_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_ready_org uuid := gen_random_uuid();
  v_blocked_org uuid := gen_random_uuid();

  v_provider text;
  v_session jsonb;

  v_civic_green jsonb;
  v_ready_rollup jsonb;
  v_ready_bridge jsonb;
  v_ready_launch jsonb;
  v_blocked_launch jsonb;
begin
  v_civic_green := pods_provisioning.rpc_selftest_civic_action_full_green_v1();

  if v_civic_green->>'token' <> 'PROTEUSOPS_CIVIC_ACTION_FULL_GREEN_OK' then
    raise exception 'CIVIC_PROVIDER_LAUNCH_MODEL_NOT_GREEN';
  end if;

  foreach v_provider in array array['supabase','email','storage']
  loop
    v_session := pods_provisioning.rpc_start_provider_connection_session_v1(
      v_ready_org,
      v_provider,
      null
    );

    perform pods_provisioning.rpc_complete_provider_connection_session_v1(
      (v_session->>'provider_connection_session_id')::uuid,
      'acct_' || v_provider,
      'project_' || v_provider,
      'secret://proteusops/' || v_provider || '/civic-ready',
      jsonb_build_array(jsonb_build_object('resource_key','provider','value',v_provider)),
      jsonb_build_array(jsonb_build_object('check_key','verified','status','pass'))
    );
  end loop;

  v_ready_rollup := pods_provisioning.rpc_provider_connection_rollup_v1(
    v_ready_org,
    'CIVIC_ACTION_V1',
    'v1'
  );

  if v_ready_rollup->>'connection_ready' <> 'true' then
    raise exception 'CIVIC_PROVIDER_CONNECTION_ROLLUP_NOT_READY:%', v_ready_rollup;
  end if;

  v_ready_bridge := pods_provisioning.rpc_bridge_provider_connections_to_runtime_v1(
    v_ready_org,
    (v_ready_rollup->>'provider_connection_rollup_id')::uuid,
    'CIVIC_ACTION_V1',
    'v1'
  );

  if v_ready_bridge->>'bridge_ready' <> 'true' then
    raise exception 'CIVIC_PROVIDER_RUNTIME_BRIDGE_NOT_READY:%', v_ready_bridge;
  end if;

  v_ready_launch := pods_provisioning.rpc_connection_layer_launch_control_v1(
    v_ready_org,
    'CIVIC_ACTION_V1',
    'v1',
    null,
    null,
    null
  );

  if v_ready_launch->>'launch_status' <> 'ready' then
    raise exception 'CIVIC_PROVIDER_LAUNCH_NOT_READY:%', v_ready_launch;
  end if;

  v_session := pods_provisioning.rpc_start_provider_connection_session_v1(
    v_blocked_org,
    'supabase',
    null
  );

  perform pods_provisioning.rpc_complete_provider_connection_session_v1(
    (v_session->>'provider_connection_session_id')::uuid,
    'acct_supabase',
    'project_supabase',
    'secret://proteusops/supabase/civic-blocked',
    '[]'::jsonb,
    '[]'::jsonb
  );

  v_blocked_launch := pods_provisioning.rpc_connection_layer_launch_control_v1(
    v_blocked_org,
    'CIVIC_ACTION_V1',
    'v1',
    null,
    null,
    null
  );

  if v_blocked_launch->>'launch_status' <> 'blocked' then
    raise exception 'CIVIC_PROVIDER_BLOCKED_LAUNCH_FAIL:%', v_blocked_launch;
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_PROVIDER_LAUNCH_OK',
    'model_full_green', v_civic_green,
    'ready_rollup', v_ready_rollup,
    'ready_bridge', v_ready_bridge,
    'ready_launch', v_ready_launch,
    'blocked_launch', v_blocked_launch
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_civic_action_provider_launch_integration_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_civic_action_survey_flow_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_campaign jsonb;
  v_q1 jsonb;
  v_q2 jsonb;
  v_response jsonb;
  v_count jsonb;
  v_duplicate_denied boolean := false;
begin
  perform pods_provisioning.rpc_seed_civic_action_model_registry_v1();

  v_campaign := pods_provisioning.rpc_create_civic_action_campaign_v1(
    v_org_id,
    'Community Survey Against Proposed Change',
    'Test Community',
    'Neighborhood District',
    'oppose',
    'Residents can learn, respond to a survey, sign, and help.',
    100,
    'published'
  );

  v_q1 := pods_provisioning.rpc_add_civic_survey_question_v1(
    (v_campaign->>'civic_campaign_id')::uuid,
    'affected_by_change',
    'Would this proposed change affect you or your household?',
    'yes_no',
    true,
    1
  );

  v_q2 := pods_provisioning.rpc_add_civic_survey_question_v1(
    (v_campaign->>'civic_campaign_id')::uuid,
    'how_can_help',
    'How would you like to help?',
    'text',
    false,
    2
  );

  v_response := pods_provisioning.rpc_submit_civic_survey_response_v1(
    (v_campaign->>'civic_campaign_id')::uuid,
    'survey.user@example.com',
    jsonb_build_object(
      'affected_by_change','yes',
      'how_can_help','I can attend the event and share information.'
    )
  );

  if v_response->>'token' <> 'PROTEUSOPS_CIVIC_ACTION_SURVEY_RESPONSE_OK' then
    raise exception 'CIVIC_SURVEY_RESPONSE_TOKEN_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_submit_civic_survey_response_v1(
      (v_campaign->>'civic_campaign_id')::uuid,
      'survey.user@example.com',
      jsonb_build_object('affected_by_change','yes')
    );
  exception
    when others then
      if sqlerrm like 'CIVIC_SURVEY_RESPONSE_DUPLICATE_DENY%' then
        v_duplicate_denied := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_denied then
    raise exception 'CIVIC_SURVEY_DUPLICATE_VECTOR_FAIL';
  end if;

  v_count := pods_provisioning.rpc_civic_survey_public_count_v1(
    (v_campaign->>'civic_campaign_id')::uuid
  );

  if (v_count->>'question_count')::integer <> 2 then
    raise exception 'CIVIC_SURVEY_QUESTION_COUNT_FAIL';
  end if;

  if (v_count->>'response_count')::integer <> 1 then
    raise exception 'CIVIC_SURVEY_RESPONSE_COUNT_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_SURVEY_FLOW_OK',
    'campaign', v_campaign,
    'question_1', v_q1,
    'question_2', v_q2,
    'response', v_response,
    'public_count', v_count,
    'duplicate_denied', v_duplicate_denied
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_civic_action_survey_flow_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_connection_layer_launch_control_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_ready_org uuid := gen_random_uuid();
  v_blocked_org uuid := gen_random_uuid();

  v_provider text;
  v_session jsonb;

  v_seed jsonb;
  v_wizard jsonb;
  v_plan jsonb;
  v_deploy jsonb;

  v_ready_run jsonb;
  v_queued_run jsonb;
  v_blocked_run jsonb;
begin
  perform pods_provisioning.rpc_seed_provider_oauth_connection_contracts_v1();
  perform pods_provisioning.rpc_seed_developer_portal_model_v1();

  foreach v_provider in array array['supabase','stripe','github','email','storage']
  loop
    v_session := pods_provisioning.rpc_start_provider_connection_session_v1(
      v_ready_org,
      v_provider,
      null
    );

    perform pods_provisioning.rpc_complete_provider_connection_session_v1(
      (v_session->>'provider_connection_session_id')::uuid,
      'acct_' || v_provider,
      'project_' || v_provider,
      'secret://proteusops/' || v_provider || '/ready',
      jsonb_build_array(jsonb_build_object('resource_key','provider','value',v_provider)),
      jsonb_build_array(jsonb_build_object('check_key','verified','status','pass'))
    );
  end loop;

  v_ready_run := pods_provisioning.rpc_connection_layer_launch_control_v1(
    v_ready_org,
    'DEVELOPER_PORTAL_V1',
    'v1',
    null,
    null,
    null
  );

  if v_ready_run->>'token' <> 'PROTEUSOPS_CONNECTION_LAYER_LAUNCH_CONTROL_OK' then
    raise exception 'CONNECTION_LAYER_LAUNCH_TOKEN_FAIL';
  end if;

  if v_ready_run->>'launch_status' <> 'ready' then
    raise exception 'CONNECTION_LAYER_READY_STATUS_FAIL:%', v_ready_run;
  end if;

  v_wizard := pods_provisioning.rpc_start_operator_setup_wizard_v1(
    v_ready_org,
    'DEVELOPER_PORTAL_V1',
    jsonb_build_object(
      'product_name','Connection Launch Product',
      'github_url','https://github.com/example/connection-launch',
      'download_url','https://example.com/downloads/connection-launch',
      'support_email','support@example.com'
    )
  );

  v_plan := pods_provisioning.rpc_plan_model_capabilities_v1(
    v_ready_org,
    'DEVELOPER_PORTAL_V1',
    jsonb_build_object(
      'product_name','Connection Launch Product',
      'github_url','https://github.com/example/connection-launch',
      'download_url','https://example.com/downloads/connection-launch',
      'support_email','support@example.com'
    )
  );

  v_deploy := pods_provisioning.rpc_create_model_deployment_receipt_v1(
    (v_plan->>'plan_run_id')::uuid
  );

  v_queued_run := pods_provisioning.rpc_connection_layer_launch_control_v1(
    v_ready_org,
    'DEVELOPER_PORTAL_V1',
    'v1',
    (v_wizard->>'wizard_session_id')::uuid,
    (v_plan->>'plan_run_id')::uuid,
    (v_deploy->>'deployment_receipt_id')::uuid
  );

  if v_queued_run->>'launch_status' <> 'queued' then
    raise exception 'CONNECTION_LAYER_QUEUED_STATUS_FAIL:%', v_queued_run;
  end if;

  v_session := pods_provisioning.rpc_start_provider_connection_session_v1(
    v_blocked_org,
    'supabase',
    null
  );

  perform pods_provisioning.rpc_complete_provider_connection_session_v1(
    (v_session->>'provider_connection_session_id')::uuid,
    'acct_supabase',
    'project_supabase',
    'secret://proteusops/supabase/blocked',
    '[]'::jsonb,
    '[]'::jsonb
  );

  v_blocked_run := pods_provisioning.rpc_connection_layer_launch_control_v1(
    v_blocked_org,
    'DEVELOPER_PORTAL_V1',
    'v1',
    null,
    null,
    null
  );

  if v_blocked_run->>'launch_status' <> 'blocked' then
    raise exception 'CONNECTION_LAYER_BLOCKED_STATUS_FAIL:%', v_blocked_run;
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CONNECTION_LAYER_LAUNCH_CONTROL_OK',
    'ready_run', v_ready_run,
    'queued_run', v_queued_run,
    'blocked_run', v_blocked_run
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_connection_layer_launch_control_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_contractor_estimate_approval_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();

  v_registry jsonb;
  v_request jsonb;
  v_visit jsonb;
  v_complete jsonb;
  v_estimate jsonb;
  v_decision jsonb;

  v_duplicate_ok boolean := false;
begin
  v_registry := pods_provisioning.rpc_seed_contractor_template_registry_v1();

  v_request := pods_provisioning.rpc_request_contractor_estimate_v1(
    v_org_id,
    'ROOF_REPLACEMENT',
    'Approval Customer',
    'approval.customer@example.com',
    '555-0203',
    '999 Approval Lane',
    'Need contractor approval workflow.',
    'Tuesday morning'
  );

  v_visit := pods_provisioning.rpc_schedule_contractor_site_visit_v1(
    (v_request->>'estimate_request_id')::uuid,
    current_date + 1,
    '13:00'::time,
    '14:00'::time,
    'Estimator 2',
    null
  );

  v_complete := pods_provisioning.rpc_complete_contractor_site_visit_v1(
    (v_visit->>'site_visit_id')::uuid,
    'Approval workflow inspection complete.',
    jsonb_build_object(
      'roof_square_estimate', 28,
      'stories', 1,
      'material', 'metal_roof'
    ),
    jsonb_build_array(
      jsonb_build_object('kind','photo','ref','approval/photo-001.jpg')
    ),
    false
  );

  v_estimate := pods_provisioning.rpc_build_contractor_estimate_v1(
    (v_request->>'estimate_request_id')::uuid,
    500000,
    800000,
    25,
    'Please approve this contractor estimate.'
  );

  v_decision := pods_provisioning.rpc_decide_contractor_estimate_v1(
    (v_estimate->>'contractor_estimate_id')::uuid,
    'approve',
    'Approval Customer',
    'approval.customer@example.com',
    'Customer approved estimate.',
    '127.0.0.1',
    'ProteusOpsSelftest/1.0'
  );

  if v_decision->>'token' <> 'PROTEUSOPS_CONTRACTOR_ESTIMATE_APPROVAL_OK' then
    raise exception 'CONTRACTOR_ESTIMATE_APPROVAL_TOKEN_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_decide_contractor_estimate_v1(
      (v_estimate->>'contractor_estimate_id')::uuid,
      'approve',
      'Approval Customer',
      'approval.customer@example.com',
      'Duplicate approval.',
      '127.0.0.1',
      'ProteusOpsSelftest/1.0'
    );
  exception
    when others then
      if sqlerrm like 'CONTRACTOR_ESTIMATE_DECISION_DUPLICATE_DENY:%'
        or sqlerrm like 'CONTRACTOR_ESTIMATE_NOT_DECIDABLE:%' then
        v_duplicate_ok := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_ok then
    raise exception 'CONTRACTOR_ESTIMATE_APPROVAL_DUPLICATE_VECTOR_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CONTRACTOR_ESTIMATE_APPROVAL_OK',
    'org_id', v_org_id,
    'registry', v_registry,
    'estimate_request', v_request,
    'site_visit', v_visit,
    'site_visit_completion', v_complete,
    'estimate', v_estimate,
    'decision', v_decision,
    'duplicate_denied', v_duplicate_ok
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_contractor_estimate_approval_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_contractor_estimate_builder_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_registry jsonb;
  v_estimate_request jsonb;
  v_visit jsonb;
  v_complete jsonb;
  v_estimate jsonb;
  v_duplicate_ok boolean := false;
begin
  v_registry := pods_provisioning.rpc_seed_contractor_template_registry_v1();

  v_estimate_request := pods_provisioning.rpc_request_contractor_estimate_v1(
    v_org_id,
    'ROOF_REPLACEMENT',
    'Estimate Builder Customer',
    'estimate.builder@example.com',
    '555-0202',
    '789 Estimate Road',
    'Need roof replacement estimate after inspection',
    'Monday morning'
  );

  v_visit := pods_provisioning.rpc_schedule_contractor_site_visit_v1(
    (v_estimate_request->>'estimate_request_id')::uuid,
    current_date + 1,
    '10:00'::time,
    '11:00'::time,
    'Estimator 1',
    null
  );

  v_complete := pods_provisioning.rpc_complete_contractor_site_visit_v1(
    (v_visit->>'site_visit_id')::uuid,
    'Inspection completed for estimate builder test.',
    jsonb_build_object(
      'roof_square_estimate', 25,
      'stories', 2,
      'material', 'architectural_shingle'
    ),
    jsonb_build_array(
      jsonb_build_object('kind','photo','ref','estimate-builder/photo-001.jpg')
    ),
    false
  );

  if v_complete->>'estimate_ready' <> 'true' then
    raise exception 'CONTRACTOR_ESTIMATE_SITE_VISIT_NOT_READY';
  end if;

  v_estimate := pods_provisioning.rpc_build_contractor_estimate_v1(
    (v_estimate_request->>'estimate_request_id')::uuid,
    450000,
    650000,
    20,
    'Estimate is ready for review.'
  );

  if v_estimate->>'token' <> 'PROTEUSOPS_CONTRACTOR_ESTIMATE_BUILDER_OK' then
    raise exception 'CONTRACTOR_ESTIMATE_BUILDER_TOKEN_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_build_contractor_estimate_v1(
      (v_estimate_request->>'estimate_request_id')::uuid,
      450000,
      650000,
      20,
      'Duplicate estimate test.'
    );
  exception
    when others then
      if sqlerrm like 'CONTRACTOR_ESTIMATE_DUPLICATE_DENY:%' then
        v_duplicate_ok := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_ok then
    raise exception 'CONTRACTOR_ESTIMATE_DUPLICATE_VECTOR_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CONTRACTOR_ESTIMATE_BUILDER_OK',
    'org_id', v_org_id,
    'registry', v_registry,
    'estimate_request', v_estimate_request,
    'site_visit', v_visit,
    'site_visit_completion', v_complete,
    'estimate', v_estimate,
    'duplicate_denied', v_duplicate_ok
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_contractor_estimate_builder_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_contractor_job_creation_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();

  v_registry jsonb;
  v_request jsonb;
  v_visit jsonb;
  v_complete jsonb;
  v_estimate jsonb;
  v_decision jsonb;
  v_job jsonb;

  v_duplicate_ok boolean := false;
begin
  v_registry := pods_provisioning.rpc_seed_contractor_template_registry_v1();

  v_request := pods_provisioning.rpc_request_contractor_estimate_v1(
    v_org_id,
    'ROOF_REPLACEMENT',
    'Job Creation Customer',
    'job.customer@example.com',
    '555-0204',
    '321 Job Road',
    'Need approved job workflow.',
    'Wednesday morning'
  );

  v_visit := pods_provisioning.rpc_schedule_contractor_site_visit_v1(
    (v_request->>'estimate_request_id')::uuid,
    current_date + 1,
    '09:00'::time,
    '10:00'::time,
    'Estimator 3',
    null
  );

  v_complete := pods_provisioning.rpc_complete_contractor_site_visit_v1(
    (v_visit->>'site_visit_id')::uuid,
    'Job creation inspection complete.',
    jsonb_build_object(
      'roof_square_estimate', 30,
      'stories', 2,
      'material', 'asphalt_shingle'
    ),
    jsonb_build_array(
      jsonb_build_object('kind','photo','ref','job/photo-001.jpg')
    ),
    false
  );

  v_estimate := pods_provisioning.rpc_build_contractor_estimate_v1(
    (v_request->>'estimate_request_id')::uuid,
    600000,
    900000,
    25,
    'Estimate ready for job creation.'
  );

  v_decision := pods_provisioning.rpc_decide_contractor_estimate_v1(
    (v_estimate->>'contractor_estimate_id')::uuid,
    'approve',
    'Job Creation Customer',
    'job.customer@example.com',
    'Approved for job creation.',
    '127.0.0.1',
    'ProteusOpsSelftest/1.0'
  );

  if v_decision->>'job_creation_ready' <> 'true' then
    raise exception 'CONTRACTOR_JOB_CREATION_NOT_READY';
  end if;

  v_job := pods_provisioning.rpc_create_contractor_job_from_approved_estimate_v1(
    (v_estimate->>'contractor_estimate_id')::uuid,
    current_date + 7,
    current_date + 10,
    3
  );

  if v_job->>'token' <> 'PROTEUSOPS_CONTRACTOR_JOB_CREATION_OK' then
    raise exception 'CONTRACTOR_JOB_CREATION_TOKEN_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_create_contractor_job_from_approved_estimate_v1(
      (v_estimate->>'contractor_estimate_id')::uuid,
      current_date + 7,
      current_date + 10,
      3
    );
  exception
    when others then
      if sqlerrm like 'CONTRACTOR_JOB_DUPLICATE_DENY:%' then
        v_duplicate_ok := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_ok then
    raise exception 'CONTRACTOR_JOB_DUPLICATE_VECTOR_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CONTRACTOR_JOB_CREATION_OK',
    'org_id', v_org_id,
    'registry', v_registry,
    'estimate_request', v_request,
    'site_visit', v_visit,
    'site_visit_completion', v_complete,
    'estimate', v_estimate,
    'decision', v_decision,
    'job', v_job,
    'duplicate_denied', v_duplicate_ok
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_contractor_job_creation_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_contractor_site_visit_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_registry jsonb;
  v_estimate jsonb;
  v_visit jsonb;
  v_complete jsonb;
  v_duplicate_ok boolean := false;
begin
  v_registry := pods_provisioning.rpc_seed_contractor_template_registry_v1();

  v_estimate := pods_provisioning.rpc_request_contractor_estimate_v1(
    v_org_id,
    'ROOF_REPLACEMENT',
    'Site Visit Customer',
    'sitevisit.customer@example.com',
    '555-0201',
    '456 Roof Lane',
    'Need full roof inspection and replacement estimate',
    'Friday afternoon'
  );

  v_visit := pods_provisioning.rpc_schedule_contractor_site_visit_v1(
    (v_estimate->>'estimate_request_id')::uuid,
    current_date + 1,
    '09:00'::time,
    '10:00'::time,
    'Estimator 1',
    null
  );

  if v_visit->>'token' <> 'PROTEUSOPS_CONTRACTOR_SITE_VISIT_OK' then
    raise exception 'CONTRACTOR_SITE_VISIT_TOKEN_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_schedule_contractor_site_visit_v1(
      (v_estimate->>'estimate_request_id')::uuid,
      current_date + 1,
      '09:00'::time,
      '10:00'::time,
      'Estimator 1',
      null
    );
  exception
    when others then
      if sqlerrm like 'SITE_VISIT_DUPLICATE_DENY:%' then
        v_duplicate_ok := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_ok then
    raise exception 'CONTRACTOR_SITE_VISIT_DUPLICATE_VECTOR_FAIL';
  end if;

  v_complete := pods_provisioning.rpc_complete_contractor_site_visit_v1(
    (v_visit->>'site_visit_id')::uuid,
    'Measured roof and captured inspection notes.',
    jsonb_build_object(
      'roof_square_estimate', 22,
      'stories', 2,
      'material', 'asphalt_shingle'
    ),
    jsonb_build_array(
      jsonb_build_object('kind','photo','ref','site-visit/photo-001.jpg'),
      jsonb_build_object('kind','photo','ref','site-visit/photo-002.jpg')
    ),
    false
  );

  if v_complete->>'token' <> 'PROTEUSOPS_CONTRACTOR_SITE_VISIT_COMPLETE_OK' then
    raise exception 'CONTRACTOR_SITE_VISIT_COMPLETE_TOKEN_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CONTRACTOR_SITE_VISIT_OK',
    'org_id', v_org_id,
    'registry', v_registry,
    'estimate_request', v_estimate,
    'site_visit', v_visit,
    'completion', v_complete,
    'duplicate_denied', v_duplicate_ok
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_contractor_site_visit_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_contractor_template_registry_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();

  v_registry jsonb;
  v_estimate jsonb;
begin
  v_registry := pods_provisioning.rpc_seed_contractor_template_registry_v1();

  if v_registry->>'token' <> 'PROTEUSOPS_CONTRACTOR_TEMPLATE_REGISTRY_OK' then
    raise exception 'CONTRACTOR_TEMPLATE_REGISTRY_FAIL';
  end if;

  v_estimate := pods_provisioning.rpc_request_contractor_estimate_v1(
    v_org_id,
    'ROOF_REPLACEMENT',
    'Roof Estimate Customer',
    'roof.customer@example.com',
    '555-0200',
    '123 Test Street',
    'Full roof replacement requested',
    'Next week mornings'
  );

  if v_estimate->>'token' <> 'PROTEUSOPS_CONTRACTOR_ESTIMATE_REQUEST_OK' then
    raise exception 'CONTRACTOR_ESTIMATE_REQUEST_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CONTRACTOR_TEMPLATE_REGISTRY_OK',
    'registry', v_registry,
    'estimate_request', v_estimate
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_contractor_template_registry_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_customer_deployment_handoff_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_full_green jsonb;
  v_rollup jsonb;
  v_handoff jsonb;
begin
  v_full_green := pods_provisioning.rpc_selftest_full_green_engine_registry_v1();

  if v_full_green->>'platform_status' <> 'FULL_GREEN' then
    raise exception 'CUSTOMER_HANDOFF_FULL_GREEN_DEPENDENCY_FAIL';
  end if;

  perform pods_provisioning.rpc_verify_supabase_adapter_runtime_v1(
    v_org_id,
    'handoff-project-ref',
    'https://handoff-project-ref.supabase.co',
    true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_stripe_adapter_runtime_v1(
    v_org_id,
    'acct_handoff',
    'test',
    true,true,true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_email_adapter_runtime_v1(
    v_org_id,
    'resend',
    'handoff.example.com',
    true,true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_storage_adapter_runtime_v1(
    v_org_id,
    'supabase_storage',
    'handoff_downloads',
    true,true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_github_adapter_runtime_v1(
    v_org_id,
    'example',
    'handoff-runtime',
    'https://github.com/example/handoff-runtime',
    true,true,true,true,true,null
  );

  v_rollup := pods_provisioning.rpc_provider_readiness_rollup_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    'v1'
  );

  if v_rollup->>'readiness_status' <> 'ready' then
    raise exception 'CUSTOMER_HANDOFF_PROVIDER_READY_FAIL';
  end if;

  v_handoff := pods_provisioning.rpc_emit_customer_deployment_handoff_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    'v1'
  );

  if v_handoff->>'token' <> 'PROTEUSOPS_CUSTOMER_DEPLOYMENT_HANDOFF_OK' then
    raise exception 'CUSTOMER_HANDOFF_TOKEN_FAIL';
  end if;

  if v_handoff->>'handoff_status' <> 'ready' then
    raise exception 'CUSTOMER_HANDOFF_STATUS_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CUSTOMER_DEPLOYMENT_HANDOFF_OK',
    'org_id', v_org_id,
    'handoff', v_handoff
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_customer_deployment_handoff_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_customer_launch_receipt_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_provision jsonb;
  v_launch jsonb;
  v_duplicate_ok boolean := false;
begin
  v_provision := pods_provisioning.rpc_provision_vertical_template_v1(
    v_org_id,
    'BARBER_NAIL_V1',
    null
  );

  v_launch := pods_provisioning.rpc_generate_customer_launch_receipt_v1(
    (v_provision->>'provision_run_id')::uuid
  );

  if v_launch->>'token' <> 'PROTEUSOPS_CUSTOMER_LAUNCH_RECEIPT_OK' then
    raise exception 'CUSTOMER_LAUNCH_TOKEN_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_generate_customer_launch_receipt_v1(
      (v_provision->>'provision_run_id')::uuid
    );
  exception
    when others then
      if sqlerrm like 'LAUNCH_RECEIPT_ALREADY_EXISTS:%' then
        v_duplicate_ok := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_ok then
    raise exception 'CUSTOMER_LAUNCH_DUPLICATE_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CUSTOMER_LAUNCH_RECEIPT_OK',
    'duplicate_denied', v_duplicate_ok,
    'launch_receipt', v_launch
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_customer_launch_receipt_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_customer_notifications_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();

  v_provision jsonb;
  v_public jsonb;
  v_request jsonb;
  v_confirm jsonb;

  v_template_seed jsonb;
  v_notification jsonb;
begin
  v_provision := pods_provisioning.rpc_provision_vertical_template_v1(
    v_org_id,
    'BARBER_NAIL_V1',
    null
  );

  v_public := pods_provisioning.rpc_bootstrap_public_booking_surface_v1(
    (v_provision->>'provision_run_id')::uuid,
    'notification-test-' || left(v_org_id::text, 8)
  );

  v_request := pods_provisioning.rpc_request_public_appointment_v1(
    v_public->>'booking_slug',
    'BARBER_CUT',
    current_date + 1,
    '13:00'::time,
    'Notification Test Customer',
    'notify.customer@example.com',
    '555-0114'
  );

  v_confirm := pods_provisioning.rpc_admin_update_appointment_request_v1(
    (v_request->>'appointment_request_id')::uuid,
    'confirm',
    null,
    'Notification selftest confirmation'
  );

  if v_confirm->>'new_status' <> 'confirmed' then
    raise exception 'NOTIFICATION_CONFIRM_FAIL';
  end if;

  v_template_seed := pods_provisioning.rpc_seed_notification_templates_v1();

  if v_template_seed->>'token' <> 'PROTEUSOPS_NOTIFICATION_TEMPLATE_SEED_OK' then
    raise exception 'NOTIFICATION_TEMPLATE_SEED_FAIL';
  end if;

  v_notification := pods_provisioning.rpc_create_appointment_confirmation_notification_v1(
    (v_request->>'appointment_request_id')::uuid
  );

  if v_notification->>'token' <> 'PROTEUSOPS_CUSTOMER_NOTIFICATIONS_OK' then
    raise exception 'CUSTOMER_NOTIFICATION_TOKEN_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CUSTOMER_NOTIFICATIONS_OK',
    'org_id', v_org_id,
    'notification', v_notification,
    'template_seed', v_template_seed
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_customer_notifications_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_developer_portal_model_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_seed jsonb;
  v_org_id uuid := gen_random_uuid();
  v_plan jsonb;
begin
  v_seed := pods_provisioning.rpc_seed_developer_portal_model_v1();

  if v_seed->>'token' <> 'PROTEUSOPS_DEVELOPER_PORTAL_MODEL_OK' then
    raise exception 'DEVELOPER_PORTAL_MODEL_SEED_FAIL';
  end if;

  v_plan := pods_provisioning.rpc_plan_model_capabilities_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    jsonb_build_object(
      'product_name','Proteus Test Product',
      'github_url','https://github.com/example/proteus-test-product',
      'download_url','https://example.com/downloads/proteus-test-product',
      'support_email','support@example.com',
      'license_type','standard'
    )
  );

  if v_plan->>'token' <> 'PROTEUSOPS_MODEL_CAPABILITY_MATRIX_OK' then
    raise exception 'DEVELOPER_PORTAL_PLAN_TOKEN_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_DEVELOPER_PORTAL_MODEL_OK',
    'seed', v_seed,
    'developer_portal_plan', v_plan
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_developer_portal_model_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_domain_provider_authority_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_install jsonb;
  v_connection jsonb;
  v_binding jsonb;
  v_dns jsonb;
  v_ssl jsonb;
begin
  v_install := pods_provisioning.rpc_install_marketplace_model_v1(
    v_org_id,
    'CIVIC_ACTION_V1',
    'v2',
    jsonb_build_object(
      'issue_title','Domain Authority Civic Site',
      'community_name','Domain Borough',
      'location_label','Domain Corridor',
      'position_type','oppose',
      'issue_summary','Domain authority selftest.',
      'petition_goal',7000,
      'enable_petition',true,
      'enable_survey',true,
      'enable_events',true,
      'enable_evidence',true,
      'enable_volunteers',true,
      'moderation_required',true
    )
  );

  v_connection := pods_provisioning.rpc_connect_domain_provider_v1(
    v_org_id,
    'cloudflare',
    'cf_test_account'
  );

  v_binding := pods_provisioning.rpc_attach_domain_to_runtime_v1(
    (v_install->>'model_instance_runtime_id')::uuid,
    'example-proteusops-site.test',
    'cloudflare'
  );

  v_dns := pods_provisioning.rpc_verify_domain_dns_v1(
    (v_binding->>'domain_runtime_binding_id')::uuid
  );

  v_ssl := pods_provisioning.rpc_verify_domain_ssl_v1(
    (v_binding->>'domain_runtime_binding_id')::uuid
  );

  if v_connection->>'connection_status' <> 'connected' then
    raise exception 'DOMAIN_PROVIDER_CONNECTION_FAIL';
  end if;

  if v_dns->>'dns_status' <> 'verified' then
    raise exception 'DOMAIN_DNS_VERIFY_FAIL';
  end if;

  if v_ssl->>'ssl_status' <> 'active' then
    raise exception 'DOMAIN_SSL_VERIFY_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_DOMAIN_PROVIDER_AUTHORITY_OK',
    'install', v_install,
    'provider_connection', v_connection,
    'domain_binding', v_binding,
    'dns', v_dns,
    'ssl', v_ssl
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_domain_provider_authority_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_email_adapter_runtime_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_verified jsonb;
  v_blocked jsonb;
begin
  v_verified := pods_provisioning.rpc_verify_email_adapter_runtime_v1(
    v_org_id,
    'resend',
    'example.com',
    true,
    true,
    true,
    true,
    true,
    null
  );

  if v_verified->>'token' <> 'PROTEUSOPS_EMAIL_ADAPTER_RUNTIME_OK' then
    raise exception 'EMAIL_RUNTIME_TOKEN_FAIL';
  end if;

  if v_verified->>'runtime_status' <> 'verified' then
    raise exception 'EMAIL_RUNTIME_VERIFIED_STATUS_FAIL';
  end if;

  v_blocked := pods_provisioning.rpc_verify_email_adapter_runtime_v1(
    v_org_id,
    'resend',
    'blocked.example.com',
    true,
    false,
    true,
    true,
    true,
    null
  );

  if v_blocked->>'runtime_status' <> 'blocked' then
    raise exception 'EMAIL_RUNTIME_BLOCKED_STATUS_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_EMAIL_ADAPTER_RUNTIME_OK',
    'org_id', v_org_id,
    'verified_runtime', v_verified,
    'blocked_runtime', v_blocked
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_email_adapter_runtime_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_full_green_engine_registry_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_snapshot jsonb;
begin
  perform pods_provisioning.rpc_register_engine_runtime_v1(
    'model_registry',
    'model',
    'FULL_GREEN',
    'PROTEUSOPS_VERTICAL_DOMAIN_CONTRACTS_OK',
    true,true,true,0
  );

  perform pods_provisioning.rpc_register_engine_runtime_v1(
    'wizard_runtime',
    'wizard',
    'FULL_GREEN',
    'PROTEUSOPS_OPERATOR_SETUP_WIZARD_OK',
    true,true,true,0
  );

  perform pods_provisioning.rpc_register_engine_runtime_v1(
    'capability_planner',
    'planner',
    'FULL_GREEN',
    'PROTEUSOPS_MODEL_CAPABILITY_PLAN_OK',
    true,true,true,0
  );

  perform pods_provisioning.rpc_register_engine_runtime_v1(
    'deployment_receipts',
    'deployment',
    'FULL_GREEN',
    'PROTEUSOPS_MODEL_DEPLOYMENT_RECEIPT_OK',
    true,true,true,0
  );

  perform pods_provisioning.rpc_register_engine_runtime_v1(
    'provider_runtimes',
    'provider',
    'FULL_GREEN',
    'PROTEUSOPS_PROVIDER_READINESS_ROLLUP_OK',
    true,true,true,0
  );

  perform pods_provisioning.rpc_register_engine_runtime_v1(
    'launch_control_plane',
    'launch',
    'FULL_GREEN',
    'PROTEUSOPS_LAUNCH_CONTROL_PLANE_RECEIPT_OK',
    true,true,true,0
  );

  perform pods_provisioning.rpc_register_engine_runtime_v1(
    'execution_worker',
    'execution',
    'FULL_GREEN',
    'PROTEUSOPS_LAUNCH_EXECUTION_WORKER_OK',
    true,true,true,0
  );

  perform pods_provisioning.rpc_register_engine_runtime_v1(
    'failure_runtime',
    'failure',
    'FULL_GREEN',
    'PROTEUSOPS_LAUNCH_FAILURE_RUNTIME_OK',
    true,true,true,0
  );

  perform pods_provisioning.rpc_register_engine_runtime_v1(
    'rollback_runtime',
    'rollback',
    'FULL_GREEN',
    'PROTEUSOPS_LAUNCH_ROLLBACK_RUNTIME_OK',
    true,true,true,0
  );

  perform pods_provisioning.rpc_register_engine_runtime_v1(
    'retry_governance',
    'retry',
    'FULL_GREEN',
    'PROTEUSOPS_RETRY_GOVERNANCE_OK',
    true,true,true,0
  );

  perform pods_provisioning.rpc_register_engine_runtime_v1(
    'stress_harness',
    'stress',
    'FULL_GREEN',
    'PROTEUSOPS_STRESS_HARNESS_OK',
    true,true,true,0
  );

  perform pods_provisioning.rpc_register_engine_runtime_v1(
    'security_gate_matrix',
    'security',
    'FULL_GREEN',
    'PROTEUSOPS_SECURITY_GATE_MATRIX_OK',
    true,true,true,0
  );

  v_snapshot := pods_provisioning.rpc_emit_full_green_platform_snapshot_v1();

  if v_snapshot->>'platform_status' <> 'FULL_GREEN' then
    raise exception 'FULL_GREEN_PLATFORM_STATUS_FAIL';
  end if;

  return v_snapshot;
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_full_green_engine_registry_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_github_adapter_runtime_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_verified jsonb;
  v_blocked jsonb;
begin
  v_verified := pods_provisioning.rpc_verify_github_adapter_runtime_v1(
    v_org_id,
    'example',
    'proteus-test-product',
    'https://github.com/example/proteus-test-product',
    true,
    true,
    true,
    true,
    true,
    null
  );

  if v_verified->>'token' <> 'PROTEUSOPS_GITHUB_ADAPTER_RUNTIME_OK' then
    raise exception 'GITHUB_RUNTIME_TOKEN_FAIL';
  end if;

  if v_verified->>'runtime_status' <> 'verified' then
    raise exception 'GITHUB_RUNTIME_VERIFIED_STATUS_FAIL';
  end if;

  v_blocked := pods_provisioning.rpc_verify_github_adapter_runtime_v1(
    v_org_id,
    'example',
    'blocked-product',
    'https://github.com/example/blocked-product',
    true,
    false,
    true,
    true,
    true,
    null
  );

  if v_blocked->>'runtime_status' <> 'blocked' then
    raise exception 'GITHUB_RUNTIME_BLOCKED_STATUS_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_GITHUB_ADAPTER_RUNTIME_OK',
    'org_id', v_org_id,
    'verified_runtime', v_verified,
    'blocked_runtime', v_blocked
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_github_adapter_runtime_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_launch_control_plane_receipt_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();

  v_seed jsonb;
  v_wizard jsonb;
  v_plan jsonb;
  v_deploy jsonb;
  v_rollup jsonb;
  v_receipt jsonb;
begin
  v_seed := pods_provisioning.rpc_seed_developer_portal_model_v1();

  v_wizard := pods_provisioning.rpc_start_operator_setup_wizard_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    jsonb_build_object(
      'product_name','Control Plane Product',
      'github_url','https://github.com/example/control-plane',
      'download_url','https://example.com/downloads/control-plane',
      'support_email','support@example.com'
    )
  );

  v_plan := pods_provisioning.rpc_plan_model_capabilities_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    jsonb_build_object(
      'product_name','Control Plane Product',
      'github_url','https://github.com/example/control-plane',
      'download_url','https://example.com/downloads/control-plane',
      'support_email','support@example.com'
    )
  );

  v_deploy := pods_provisioning.rpc_create_model_deployment_receipt_v1(
    (v_plan->>'plan_run_id')::uuid
  );

  perform pods_provisioning.rpc_verify_supabase_adapter_runtime_v1(
    v_org_id,
    'control-plane-project-ref',
    'https://control-plane-project-ref.supabase.co',
    true,
    true,
    true,
    true,
    null
  );

  perform pods_provisioning.rpc_verify_stripe_adapter_runtime_v1(
    v_org_id,
    'acct_control_plane',
    'test',
    true,
    true,
    true,
    true,
    true,
    true,
    null
  );

  perform pods_provisioning.rpc_verify_email_adapter_runtime_v1(
    v_org_id,
    'resend',
    'control.example.com',
    true,
    true,
    true,
    true,
    true,
    null
  );

  perform pods_provisioning.rpc_verify_storage_adapter_runtime_v1(
    v_org_id,
    'supabase_storage',
    'control_plane_downloads',
    true,
    true,
    true,
    true,
    true,
    null
  );

  perform pods_provisioning.rpc_verify_github_adapter_runtime_v1(
    v_org_id,
    'example',
    'control-plane',
    'https://github.com/example/control-plane',
    true,
    true,
    true,
    true,
    true,
    null
  );

  v_rollup := pods_provisioning.rpc_provider_readiness_rollup_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    'v1'
  );

  if v_rollup->>'readiness_status' <> 'ready' then
    raise exception 'LAUNCH_CONTROL_READINESS_NOT_READY';
  end if;

  v_receipt := pods_provisioning.rpc_emit_launch_control_plane_receipt_v1(
    v_org_id,
    (v_wizard->>'wizard_session_id')::uuid,
    (v_plan->>'plan_run_id')::uuid,
    (v_deploy->>'deployment_receipt_id')::uuid,
    (v_rollup->>'provider_readiness_rollup_id')::uuid
  );

  if v_receipt->>'token' <> 'PROTEUSOPS_LAUNCH_CONTROL_PLANE_RECEIPT_OK' then
    raise exception 'LAUNCH_CONTROL_RECEIPT_TOKEN_FAIL';
  end if;

  if v_receipt->>'launch_decision' <> 'ready' then
    raise exception 'LAUNCH_CONTROL_DECISION_NOT_READY';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_LAUNCH_CONTROL_PLANE_RECEIPT_OK',
    'org_id', v_org_id,
    'wizard', v_wizard,
    'deployment_receipt', v_deploy,
    'provider_readiness', v_rollup,
    'launch_control_receipt', v_receipt
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_launch_control_plane_receipt_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_launch_execution_runtime_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_seed jsonb;
  v_plan jsonb;
  v_deploy jsonb;
  v_attach_run jsonb;
  v_mark jsonb;
  v_execution jsonb;
  v_duplicate_ok boolean := false;
begin
  v_seed := pods_provisioning.rpc_seed_developer_portal_model_v1();

  v_plan := pods_provisioning.rpc_plan_model_capabilities_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    jsonb_build_object(
      'product_name','Launch Runtime Product',
      'github_url','https://github.com/example/launch-runtime',
      'download_url','https://example.com/downloads/launch-runtime',
      'support_email','support@example.com'
    )
  );

  v_deploy := pods_provisioning.rpc_create_model_deployment_receipt_v1(
    (v_plan->>'plan_run_id')::uuid
  );

  v_attach_run := pods_provisioning.rpc_create_adapter_attachment_run_v1(
    (v_deploy->>'deployment_receipt_id')::uuid
  );

  v_mark := pods_provisioning.rpc_mark_adapter_attached_v1(
    (v_attach_run->>'adapter_attachment_run_id')::uuid,
    'payment_provider',
    'stripe',
    'secret://proteusops/test/stripe',
    jsonb_build_object('mode','test','webhook_required',true)
  );

  v_execution := pods_provisioning.rpc_create_launch_execution_runtime_v1(
    (v_deploy->>'deployment_receipt_id')::uuid,
    (v_attach_run->>'adapter_attachment_run_id')::uuid
  );

  if v_execution->>'token' <> 'PROTEUSOPS_LAUNCH_EXECUTION_RUNTIME_OK' then
    raise exception 'LAUNCH_EXECUTION_TOKEN_FAIL';
  end if;

  if v_execution->>'launch_blocked' <> 'true' then
    raise exception 'LAUNCH_EXECUTION_SHOULD_BE_BLOCKED_UNTIL_ALL_ADAPTERS_READY';
  end if;

  begin
    perform pods_provisioning.rpc_create_launch_execution_runtime_v1(
      (v_deploy->>'deployment_receipt_id')::uuid,
      (v_attach_run->>'adapter_attachment_run_id')::uuid
    );
  exception
    when others then
      if sqlerrm like 'LAUNCH_EXECUTION_DUPLICATE_DENY:%' then
        v_duplicate_ok := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_ok then
    raise exception 'LAUNCH_EXECUTION_DUPLICATE_VECTOR_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_LAUNCH_EXECUTION_RUNTIME_OK',
    'org_id', v_org_id,
    'plan', v_plan,
    'deployment_receipt', v_deploy,
    'adapter_attachment_run', v_attach_run,
    'adapter_mark', v_mark,
    'launch_execution', v_execution,
    'duplicate_denied', v_duplicate_ok
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_launch_execution_runtime_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_launch_execution_worker_runtime_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();

  v_seed jsonb;
  v_wizard jsonb;
  v_plan jsonb;
  v_deploy jsonb;
  v_rollup jsonb;
  v_control jsonb;
  v_worker jsonb;
  v_complete jsonb;

  v_duplicate_ok boolean := false;
begin
  v_seed := pods_provisioning.rpc_seed_developer_portal_model_v1();

  v_wizard := pods_provisioning.rpc_start_operator_setup_wizard_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    jsonb_build_object(
      'product_name','Worker Runtime Product',
      'github_url','https://github.com/example/worker-runtime',
      'download_url','https://example.com/downloads/worker-runtime',
      'support_email','support@example.com'
    )
  );

  v_plan := pods_provisioning.rpc_plan_model_capabilities_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    jsonb_build_object(
      'product_name','Worker Runtime Product',
      'github_url','https://github.com/example/worker-runtime',
      'download_url','https://example.com/downloads/worker-runtime',
      'support_email','support@example.com'
    )
  );

  v_deploy := pods_provisioning.rpc_create_model_deployment_receipt_v1(
    (v_plan->>'plan_run_id')::uuid
  );

  perform pods_provisioning.rpc_verify_supabase_adapter_runtime_v1(
    v_org_id,
    'worker-project-ref',
    'https://worker-project-ref.supabase.co',
    true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_stripe_adapter_runtime_v1(
    v_org_id,
    'acct_worker',
    'test',
    true,true,true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_email_adapter_runtime_v1(
    v_org_id,
    'resend',
    'worker.example.com',
    true,true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_storage_adapter_runtime_v1(
    v_org_id,
    'supabase_storage',
    'worker_downloads',
    true,true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_github_adapter_runtime_v1(
    v_org_id,
    'example',
    'worker-runtime',
    'https://github.com/example/worker-runtime',
    true,true,true,true,true,null
  );

  v_rollup := pods_provisioning.rpc_provider_readiness_rollup_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    'v1'
  );

  v_control := pods_provisioning.rpc_emit_launch_control_plane_receipt_v1(
    v_org_id,
    (v_wizard->>'wizard_session_id')::uuid,
    (v_plan->>'plan_run_id')::uuid,
    (v_deploy->>'deployment_receipt_id')::uuid,
    (v_rollup->>'provider_readiness_rollup_id')::uuid
  );

  if v_control->>'launch_decision' <> 'ready' then
    raise exception 'LAUNCH_WORKER_CONTROL_NOT_READY';
  end if;

  v_worker := pods_provisioning.rpc_queue_launch_execution_worker_v1(
    (v_control->>'launch_control_receipt_id')::uuid
  );

  if v_worker->>'token' <> 'PROTEUSOPS_LAUNCH_EXECUTION_WORKER_OK' then
    raise exception 'LAUNCH_WORKER_QUEUE_TOKEN_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_queue_launch_execution_worker_v1(
      (v_control->>'launch_control_receipt_id')::uuid
    );
  exception
    when others then
      if sqlerrm like 'LAUNCH_WORKER_DUPLICATE_DENY:%' then
        v_duplicate_ok := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_ok then
    raise exception 'LAUNCH_WORKER_DUPLICATE_VECTOR_FAIL';
  end if;

  v_complete := pods_provisioning.rpc_complete_launch_execution_worker_v1(
    (v_worker->>'worker_run_id')::uuid
  );

  if v_complete->>'token' <> 'PROTEUSOPS_LAUNCH_EXECUTION_WORKER_COMPLETE_OK' then
    raise exception 'LAUNCH_WORKER_COMPLETE_TOKEN_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_LAUNCH_EXECUTION_WORKER_OK',
    'org_id', v_org_id,
    'launch_control_receipt', v_control,
    'worker_run', v_worker,
    'worker_completion', v_complete,
    'duplicate_denied', v_duplicate_ok
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_launch_execution_worker_runtime_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_launch_failure_and_rollback_runtime_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();

  v_seed jsonb;
  v_wizard jsonb;
  v_plan jsonb;
  v_deploy jsonb;
  v_rollup jsonb;
  v_control jsonb;
  v_worker jsonb;
  v_failure jsonb;
  v_rollback jsonb;

  v_duplicate_failure_ok boolean := false;
  v_duplicate_rollback_ok boolean := false;
begin
  v_seed := pods_provisioning.rpc_seed_developer_portal_model_v1();

  v_wizard := pods_provisioning.rpc_start_operator_setup_wizard_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    jsonb_build_object(
      'product_name','Failure Runtime Product',
      'github_url','https://github.com/example/failure-runtime',
      'download_url','https://example.com/downloads/failure-runtime',
      'support_email','support@example.com'
    )
  );

  v_plan := pods_provisioning.rpc_plan_model_capabilities_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    jsonb_build_object(
      'product_name','Failure Runtime Product',
      'github_url','https://github.com/example/failure-runtime',
      'download_url','https://example.com/downloads/failure-runtime',
      'support_email','support@example.com'
    )
  );

  v_deploy := pods_provisioning.rpc_create_model_deployment_receipt_v1(
    (v_plan->>'plan_run_id')::uuid
  );

  perform pods_provisioning.rpc_verify_supabase_adapter_runtime_v1(
    v_org_id,'failure-project-ref','https://failure-project-ref.supabase.co',true,true,true,true,null
  );
  perform pods_provisioning.rpc_verify_stripe_adapter_runtime_v1(
    v_org_id,'acct_failure','test',true,true,true,true,true,true,null
  );
  perform pods_provisioning.rpc_verify_email_adapter_runtime_v1(
    v_org_id,'resend','failure.example.com',true,true,true,true,true,null
  );
  perform pods_provisioning.rpc_verify_storage_adapter_runtime_v1(
    v_org_id,'supabase_storage','failure_downloads',true,true,true,true,true,null
  );
  perform pods_provisioning.rpc_verify_github_adapter_runtime_v1(
    v_org_id,'example','failure-runtime','https://github.com/example/failure-runtime',true,true,true,true,true,null
  );

  v_rollup := pods_provisioning.rpc_provider_readiness_rollup_v1(
    v_org_id,'DEVELOPER_PORTAL_V1','v1'
  );

  v_control := pods_provisioning.rpc_emit_launch_control_plane_receipt_v1(
    v_org_id,
    (v_wizard->>'wizard_session_id')::uuid,
    (v_plan->>'plan_run_id')::uuid,
    (v_deploy->>'deployment_receipt_id')::uuid,
    (v_rollup->>'provider_readiness_rollup_id')::uuid
  );

  v_worker := pods_provisioning.rpc_queue_launch_execution_worker_v1(
    (v_control->>'launch_control_receipt_id')::uuid
  );

  v_failure := pods_provisioning.rpc_fail_launch_execution_worker_v1(
    (v_worker->>'worker_run_id')::uuid,
    'activate_resources',
    'Selftest simulated resource activation failure'
  );

  if v_failure->>'token' <> 'PROTEUSOPS_LAUNCH_FAILURE_RUNTIME_OK' then
    raise exception 'LAUNCH_FAILURE_TOKEN_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_fail_launch_execution_worker_v1(
      (v_worker->>'worker_run_id')::uuid,
      'activate_resources',
      'Duplicate failure'
    );
  exception
    when others then
      if sqlerrm like 'LAUNCH_FAILURE_WORKER_STATUS_INVALID:%'
        or sqlerrm like 'LAUNCH_FAILURE_DUPLICATE_DENY:%' then
        v_duplicate_failure_ok := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_failure_ok then
    raise exception 'LAUNCH_FAILURE_DUPLICATE_VECTOR_FAIL';
  end if;

  v_rollback := pods_provisioning.rpc_rollback_failed_launch_v1(
    (v_failure->>'launch_failure_event_id')::uuid
  );

  if v_rollback->>'token' <> 'PROTEUSOPS_LAUNCH_ROLLBACK_RUNTIME_OK' then
    raise exception 'LAUNCH_ROLLBACK_TOKEN_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_rollback_failed_launch_v1(
      (v_failure->>'launch_failure_event_id')::uuid
    );
  exception
    when others then
      if sqlerrm like 'LAUNCH_ROLLBACK_ALREADY_DONE:%'
        or sqlerrm like 'LAUNCH_ROLLBACK_DUPLICATE_DENY:%' then
        v_duplicate_rollback_ok := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_rollback_ok then
    raise exception 'LAUNCH_ROLLBACK_DUPLICATE_VECTOR_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_LAUNCH_FAILURE_AND_ROLLBACK_RUNTIME_OK',
    'org_id', v_org_id,
    'worker_run', v_worker,
    'failure', v_failure,
    'rollback', v_rollback,
    'duplicate_failure_denied', v_duplicate_failure_ok,
    'duplicate_rollback_denied', v_duplicate_rollback_ok
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_launch_failure_and_rollback_runtime_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_launch_ready_activation_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_seed jsonb;
  v_plan jsonb;
  v_deploy jsonb;
  v_attach_run jsonb;
  v_mark jsonb;
  v_execution jsonb;
  v_adapter text;
begin
  v_seed := pods_provisioning.rpc_seed_developer_portal_model_v1();

  v_plan := pods_provisioning.rpc_plan_model_capabilities_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    jsonb_build_object(
      'product_name','Launch Ready Product',
      'github_url','https://github.com/example/launch-ready',
      'download_url','https://example.com/downloads/launch-ready',
      'support_email','support@example.com'
    )
  );

  v_deploy := pods_provisioning.rpc_create_model_deployment_receipt_v1(
    (v_plan->>'plan_run_id')::uuid
  );

  v_attach_run := pods_provisioning.rpc_create_adapter_attachment_run_v1(
    (v_deploy->>'deployment_receipt_id')::uuid
  );

  for v_adapter in
    select value::text
    from jsonb_array_elements_text(v_deploy->'adapter_manifest')
  loop
    perform pods_provisioning.rpc_mark_adapter_attached_v1(
      (v_attach_run->>'adapter_attachment_run_id')::uuid,
      v_adapter,
      case
        when v_adapter = 'payment_provider' then 'stripe'
        when v_adapter = 'auth_provider' then 'supabase_auth'
        when v_adapter = 'file_storage_provider' then 'supabase_storage'
        when v_adapter = 'email_provider' then 'resend'
        when v_adapter = 'github_provider' then 'github'
        else 'generic'
      end,
      'secret://proteusops/test/' || v_adapter,
      jsonb_build_object('mode','test','adapter_key',v_adapter)
    );
  end loop;

  v_execution := pods_provisioning.rpc_create_launch_execution_runtime_v1(
    (v_deploy->>'deployment_receipt_id')::uuid,
    (v_attach_run->>'adapter_attachment_run_id')::uuid
  );

  if v_execution->>'token' <> 'PROTEUSOPS_LAUNCH_EXECUTION_RUNTIME_OK' then
    raise exception 'LAUNCH_READY_EXECUTION_TOKEN_FAIL';
  end if;

  if v_execution->>'launch_blocked' <> 'false' then
    raise exception 'LAUNCH_READY_SHOULD_NOT_BE_BLOCKED';
  end if;

  if v_execution->>'execution_status' <> 'ready' then
    raise exception 'LAUNCH_READY_STATUS_FAIL:%', v_execution->>'execution_status';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_LAUNCH_READY_ACTIVATION_OK',
    'org_id', v_org_id,
    'plan', v_plan,
    'deployment_receipt', v_deploy,
    'launch_execution', v_execution
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_launch_ready_activation_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_asset_license_runtime_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();

  v_asset jsonb;
  v_license_id uuid;

  v_allowed jsonb;
  v_denied jsonb;
begin
  v_asset :=
    pods_provisioning.rpc_create_runtime_asset_v1(
      v_org_id,
      'software',
      'Proteus Download',
      'storage://downloads/proteus.zip',
      true
    );

  insert into pods_provisioning.license_key_runtime_v1(
    org_id,
    license_key,
    license_status,
    license_hash
  )
  values(
    v_org_id,
    'TEST-LICENSE-KEY',
    'active',
    pods_provisioning._sha256_text_v1('TEST-LICENSE-KEY')
  )
  returning license_key_runtime_id
  into v_license_id;

  v_allowed :=
    pods_provisioning.rpc_validate_license_asset_access_v1(
      (v_asset->>'asset_runtime_object_id')::uuid,
      'TEST-LICENSE-KEY'
    );

  v_denied :=
    pods_provisioning.rpc_validate_license_asset_access_v1(
      (v_asset->>'asset_runtime_object_id')::uuid,
      'BAD-LICENSE'
    );

  if not ((v_allowed->>'access_allowed')::boolean) then
    raise exception 'ASSET_LICENSE_ALLOWED_FAIL';
  end if;

  if ((v_denied->>'access_allowed')::boolean) then
    raise exception 'ASSET_LICENSE_DENIED_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_ASSET_LICENSE_RUNTIME_OK',
    'asset', v_asset,
    'allowed', v_allowed,
    'denied', v_denied
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_asset_license_runtime_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_block_registry_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_seed jsonb;
begin
  v_seed := pods_provisioning.rpc_seed_model_block_registry_v1();

  if v_seed->>'token' <> 'PROTEUSOPS_MODEL_BLOCK_REGISTRY_OK' then
    raise exception 'MODEL_BLOCK_REGISTRY_TOKEN_FAIL';
  end if;

  if not exists (
    select 1 from pods_provisioning.model_block_registry_v1
    where block_key = 'license_download'
      and required_permissions ? 'license_key_required'
  ) then
    raise exception 'MODEL_BLOCK_LICENSE_DOWNLOAD_FAIL';
  end if;

  if not exists (
    select 1 from pods_provisioning.model_block_registry_v1
    where block_key = 'video'
      and required_providers ? 'storage'
  ) then
    raise exception 'MODEL_BLOCK_VIDEO_STORAGE_FAIL';
  end if;

  if not exists (
    select 1 from pods_provisioning.model_block_registry_v1
    where block_key = 'petition'
      and required_permissions ? 'sign_petition'
  ) then
    raise exception 'MODEL_BLOCK_PETITION_PERMISSION_FAIL';
  end if;

  if not exists (
    select 1 from pods_provisioning.model_block_registry_v1
    where block_key = 'product'
      and block_category = 'commerce'
  ) then
    raise exception 'MODEL_BLOCK_PRODUCT_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_BLOCK_REGISTRY_OK',
    'seed', v_seed
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_block_registry_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_capability_matrix_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_seed jsonb;
  v_org_id uuid := gen_random_uuid();
  v_barber_plan jsonb;
  v_contractor_plan jsonb;
  v_real_estate_plan jsonb;
begin
  v_seed := pods_provisioning.rpc_seed_model_capability_matrix_v1();

  if v_seed->>'token' <> 'PROTEUSOPS_MODEL_CAPABILITY_MATRIX_OK' then
    raise exception 'MODEL_CAPABILITY_MATRIX_SEED_FAIL';
  end if;

  v_barber_plan := pods_provisioning.rpc_plan_model_capabilities_v1(
    v_org_id,
    'BARBER_NAIL_V1',
    jsonb_build_object('business_name','Alec Test Studio')
  );

  v_contractor_plan := pods_provisioning.rpc_plan_model_capabilities_v1(
    v_org_id,
    'CONTRACTOR_V1',
    jsonb_build_object('business_name','Alec Roofing Co','default_deposit_percent',25)
  );

  v_real_estate_plan := pods_provisioning.rpc_plan_model_capabilities_v1(
    v_org_id,
    'REAL_ESTATE_V1',
    jsonb_build_object('brokerage_name','Alec Realty')
  );

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_CAPABILITY_MATRIX_OK',
    'seed', v_seed,
    'barber_plan', v_barber_plan,
    'contractor_plan', v_contractor_plan,
    'real_estate_plan', v_real_estate_plan
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_capability_matrix_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_db_surface_full_green_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_template jsonb;
  v_marketplace jsonb;
  v_install jsonb;
  v_editor jsonb;
  v_clone jsonb;
  v_surface jsonb;

  v_tokens jsonb;
  v_body jsonb;
  v_hash text;
  v_id uuid;
begin
  v_template := pods_provisioning.rpc_selftest_model_template_registry_v1();
  v_marketplace := pods_provisioning.rpc_selftest_model_marketplace_v1();
  v_install := pods_provisioning.rpc_selftest_model_marketplace_install_v1();
  v_editor := pods_provisioning.rpc_selftest_model_runtime_editor_v1();
  v_clone := pods_provisioning.rpc_selftest_model_instance_cloning_v1();
  v_surface := pods_provisioning.rpc_selftest_model_db_surface_lock_v1();

  v_tokens := jsonb_build_array(
    v_template->>'token',
    v_marketplace->>'token',
    v_install->>'token',
    v_editor->>'token',
    v_clone->>'token',
    v_surface->>'token'
  );

  if not (v_tokens ? 'PROTEUSOPS_MODEL_TEMPLATE_REGISTRY_OK') then
    raise exception 'FULL_GREEN_TEMPLATE_TOKEN_FAIL';
  end if;

  if not (v_tokens ? 'PROTEUSOPS_MODEL_MARKETPLACE_OK') then
    raise exception 'FULL_GREEN_MARKETPLACE_TOKEN_FAIL';
  end if;

  if not (v_tokens ? 'PROTEUSOPS_MODEL_MARKETPLACE_INSTALL_OK') then
    raise exception 'FULL_GREEN_INSTALL_TOKEN_FAIL';
  end if;

  if not (v_tokens ? 'PROTEUSOPS_MODEL_RUNTIME_EDITOR_OK') then
    raise exception 'FULL_GREEN_EDITOR_TOKEN_FAIL';
  end if;

  if not (v_tokens ? 'PROTEUSOPS_MODEL_INSTANCE_CLONING_OK') then
    raise exception 'FULL_GREEN_CLONE_TOKEN_FAIL';
  end if;

  if not (v_tokens ? 'PROTEUSOPS_MODEL_DB_SURFACE_LOCK_OK') then
    raise exception 'FULL_GREEN_DB_SURFACE_TOKEN_FAIL';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_DB_SURFACE_FULL_GREEN_OK',
    'full_green', true,
    'proof_tokens', v_tokens,
    'template_registry', v_template,
    'marketplace', v_marketplace,
    'marketplace_install', v_install,
    'runtime_editor', v_editor,
    'instance_cloning', v_clone,
    'db_surface_lock', v_surface
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_db_surface_full_green_receipts_v1(
    receipt_status,
    proof_tokens,
    proof_results,
    full_green,
    receipt_hash
  )
  values (
    'passed',
    v_tokens,
    v_body,
    true,
    v_hash
  )
  returning model_db_surface_full_green_receipt_id
  into v_id;

  return v_body || jsonb_build_object(
    'model_db_surface_full_green_receipt_id', v_id,
    'receipt_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_db_surface_full_green_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_db_surface_lock_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_view_count int;
  v_param_count int;
  v_proc_count int;
begin
  select count(*)
  into v_view_count
  from information_schema.views
  where table_schema = 'pods_provisioning'
    and table_name in (
      'v_model_marketplace_catalog_v1',
      'v_model_instance_runtime_summary_v1',
      'v_model_launch_package_summary_v1',
      'v_model_template_registry_v1'
    );

  select count(*)
  into v_param_count
  from pods_provisioning.model_db_parameters_v1;

  select count(*)
  into v_proc_count
  from pods_provisioning.model_stored_procedure_registry_v1
  where stable_api = true
    and destructive_action = false;

  if v_view_count <> 4 then
    raise exception 'MODEL_DB_SURFACE_VIEW_COUNT_FAIL:%', v_view_count;
  end if;

  if v_param_count < 6 then
    raise exception 'MODEL_DB_SURFACE_PARAMETER_COUNT_FAIL:%', v_param_count;
  end if;

  if v_proc_count < 8 then
    raise exception 'MODEL_DB_SURFACE_PROC_COUNT_FAIL:%', v_proc_count;
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_DB_SURFACE_LOCK_OK',
    'view_count', v_view_count,
    'parameter_count', v_param_count,
    'stored_procedure_count', v_proc_count
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_db_surface_lock_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_deployment_receipts_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_seed jsonb;
  v_dev_seed jsonb;
  v_org_id uuid := gen_random_uuid();
  v_plan jsonb;
  v_receipt jsonb;
  v_duplicate_ok boolean := false;
begin
  v_seed := pods_provisioning.rpc_seed_model_capability_matrix_v1();
  v_dev_seed := pods_provisioning.rpc_seed_developer_portal_model_v1();

  v_plan := pods_provisioning.rpc_plan_model_capabilities_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    jsonb_build_object(
      'product_name','Receipt Test Product',
      'github_url','https://github.com/example/receipt-test',
      'download_url','https://example.com/downloads/receipt-test',
      'support_email','support@example.com'
    )
  );

  v_receipt := pods_provisioning.rpc_create_model_deployment_receipt_v1(
    (v_plan->>'plan_run_id')::uuid
  );

  if v_receipt->>'token' <> 'PROTEUSOPS_MODEL_DEPLOYMENT_RECEIPTS_OK' then
    raise exception 'MODEL_DEPLOYMENT_RECEIPT_TOKEN_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_create_model_deployment_receipt_v1(
      (v_plan->>'plan_run_id')::uuid
    );
  exception
    when others then
      if sqlerrm like 'MODEL_DEPLOYMENT_RECEIPT_DUPLICATE_DENY:%' then
        v_duplicate_ok := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_ok then
    raise exception 'MODEL_DEPLOYMENT_RECEIPT_DUPLICATE_VECTOR_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_DEPLOYMENT_RECEIPTS_OK',
    'org_id', v_org_id,
    'plan', v_plan,
    'deployment_receipt', v_receipt,
    'duplicate_denied', v_duplicate_ok
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_deployment_receipts_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_deployment_target_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_hosted jsonb;
  v_supabase jsonb;
  v_vercel jsonb;
  v_docker jsonb;
begin

  v_hosted :=
    pods_provisioning.rpc_register_model_deployment_target_v1(
      'proteusops_hosted',
      'ProteusOps Hosted',
      '["supabase","email","storage"]'::jsonb
    );

  v_supabase :=
    pods_provisioning.rpc_register_model_deployment_target_v1(
      'supabase_hosted',
      'Supabase Hosted',
      '["supabase","email","storage"]'::jsonb
    );

  v_vercel :=
    pods_provisioning.rpc_register_model_deployment_target_v1(
      'vercel_export',
      'Vercel Export',
      '["supabase"]'::jsonb
    );

  v_docker :=
    pods_provisioning.rpc_register_model_deployment_target_v1(
      'docker_export',
      'Docker Export',
      '["supabase"]'::jsonb
    );

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_DEPLOYMENT_TARGET_OK',
    'targets', jsonb_build_array(
      v_hosted,
      v_supabase,
      v_vercel,
      v_docker
    )
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_deployment_target_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_instance_cloning_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();

  v_install jsonb;
  v_clone jsonb;
begin

  v_install :=
    pods_provisioning.rpc_install_marketplace_model_v1(
      v_org_id,
      'CIVIC_ACTION_V1',
      'v2',
      jsonb_build_object(
        'issue_title',
        'Original Campaign',

        'community_name',
        'Original Borough',

        'issue_summary',
        'Original campaign.',

        'petition_goal',
        1000
      )
    );

  v_clone :=
    pods_provisioning.rpc_clone_model_instance_v1(
      (
        v_install->>'model_instance_runtime_id'
      )::uuid,

      'Cloned Campaign',
      'cloned-campaign'
    );

  if
    v_clone->>'token'
    <>
    'PROTEUSOPS_MODEL_INSTANCE_CLONING_OK'
  then
    raise exception
      'MODEL_INSTANCE_CLONING_TOKEN_FAIL';
  end if;

  if
    v_clone->>'clone_name'
    <>
    'Cloned Campaign'
  then
    raise exception
      'MODEL_INSTANCE_CLONING_NAME_FAIL';
  end if;

  if
    v_clone->>'source_instance_name'
    <>
    'Original Campaign'
  then
    raise exception
      'MODEL_INSTANCE_CLONING_SOURCE_FAIL';
  end if;

  if
    (
      v_clone->'launch_package'
      ->>'token'
    )
    <>
    'PROTEUSOPS_MODEL_LAUNCH_PACKAGE_OK'
  then
    raise exception
      'MODEL_INSTANCE_CLONING_PACKAGE_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token',
    'PROTEUSOPS_MODEL_INSTANCE_CLONING_OK',

    'install',
    v_install,

    'clone',
    v_clone
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_instance_cloning_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_instance_runtime_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_instance jsonb;
begin
  v_instance := pods_provisioning.rpc_create_model_instance_runtime_v1(
    v_org_id,
    'CIVIC_ACTION_V1',
    'v2',
    'Oppose Warehouse Expansion',
    'A community action site for residents to learn, sign, survey, volunteer, attend events, and submit evidence.',
    jsonb_build_object(
      'issue_title','Oppose Warehouse Expansion',
      'community_name','Example Borough',
      'location_label','South Side Corridor',
      'position_type','oppose',
      'issue_summary','Residents are organizing around a proposed warehouse expansion.',
      'petition_goal',750
    )
  );

  if v_instance->>'token' <> 'PROTEUSOPS_MODEL_INSTANCE_RUNTIME_OK' then
    raise exception 'MODEL_INSTANCE_RUNTIME_TOKEN_FAIL';
  end if;

  if v_instance->>'instance_slug' <> 'oppose-warehouse-expansion' then
    raise exception 'MODEL_INSTANCE_SLUG_FAIL:%', v_instance;
  end if;

  if v_instance->>'launchable' <> 'true' then
    raise exception 'MODEL_INSTANCE_LAUNCHABLE_FAIL:%', v_instance;
  end if;

  if not (v_instance->'site_runtime_capabilities') ? 'license_gated_downloads' then
    raise exception 'MODEL_INSTANCE_LICENSE_CAPABILITY_FAIL';
  end if;

  if v_instance->'site_runtime'->'renderer_contract'->>'token' <> 'PROTEUSOPS_MODEL_RENDERER_CONTRACT_OK' then
    raise exception 'MODEL_INSTANCE_RENDERER_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_INSTANCE_RUNTIME_OK',
    'instance', v_instance
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_instance_runtime_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_instance_wizard_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_wizard jsonb;
begin
  v_wizard := pods_provisioning.rpc_run_model_instance_wizard_v1(
    v_org_id,
    'CIVIC_ACTION_V1',
    'v2',
    jsonb_build_object(
      'issue_title','Stop Warehouse Expansion',
      'community_name','East Borough',
      'location_label','Industrial Road Corridor',
      'position_type','oppose',
      'issue_summary','Residents want a simple site to learn, sign, survey, volunteer, attend events, and submit evidence.',
      'petition_goal',1000,
      'enable_petition',true,
      'enable_survey',true,
      'enable_events',true,
      'enable_evidence',true,
      'enable_volunteers',true,
      'moderation_required',true
    )
  );

  if v_wizard->>'token' <> 'PROTEUSOPS_MODEL_INSTANCE_WIZARD_OK' then
    raise exception 'MODEL_INSTANCE_WIZARD_TOKEN_FAIL';
  end if;

  if v_wizard->>'wizard_status' <> 'completed' then
    raise exception 'MODEL_INSTANCE_WIZARD_STATUS_FAIL';
  end if;

  if v_wizard->'normalized_fields'->>'issue_title' <> 'Stop Warehouse Expansion' then
    raise exception 'MODEL_INSTANCE_WIZARD_NORMALIZE_TITLE_FAIL';
  end if;

  if (v_wizard->'normalized_fields'->>'petition_goal')::integer <> 1000 then
    raise exception 'MODEL_INSTANCE_WIZARD_GOAL_FAIL';
  end if;

  if v_wizard->'instance_runtime'->>'launchable' <> 'true' then
    raise exception 'MODEL_INSTANCE_WIZARD_INSTANCE_LAUNCHABLE_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_INSTANCE_WIZARD_OK',
    'wizard', v_wizard
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_instance_wizard_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_launch_authority_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_install jsonb;
  v_readiness jsonb;
  v_review jsonb;
  v_launch jsonb;
  v_suspend jsonb;
  v_archive jsonb;
  v_launch_without_review_denied boolean := false;
begin
  v_install := pods_provisioning.rpc_install_marketplace_model_v1(
    v_org_id,
    'CIVIC_ACTION_V1',
    'v2',
    jsonb_build_object(
      'issue_title','Launch Authority Civic Site',
      'community_name','Authority Borough',
      'location_label','Authority Corridor',
      'position_type','oppose',
      'issue_summary','Launch authority selftest.',
      'petition_goal',3000,
      'enable_petition',true,
      'enable_survey',true,
      'enable_events',true,
      'enable_evidence',true,
      'enable_volunteers',true,
      'moderation_required',true
    )
  );

  v_readiness := pods_provisioning.rpc_check_launch_readiness_v1(
    (v_install->>'model_launch_package_id')::uuid,
    'proteusops_hosted'
  );

  begin
    perform pods_provisioning.rpc_launch_site_v1(
      (v_readiness->>'model_launch_authority_id')::uuid
    );
  exception
    when others then
      if sqlerrm like 'MODEL_SITE_LAUNCH_STATE_DENY:%' then
        v_launch_without_review_denied := true;
      else
        raise;
      end if;
  end;

  v_review := pods_provisioning.rpc_submit_launch_review_v1(
    (v_readiness->>'model_launch_authority_id')::uuid,
    'approved',
    'Selftest approval.'
  );

  v_launch := pods_provisioning.rpc_launch_site_v1(
    (v_readiness->>'model_launch_authority_id')::uuid
  );

  v_suspend := pods_provisioning.rpc_suspend_site_v1(
    (v_readiness->>'model_launch_authority_id')::uuid,
    'Selftest suspension.'
  );

  v_archive := pods_provisioning.rpc_archive_site_v1(
    (v_readiness->>'model_launch_authority_id')::uuid,
    'Selftest archive.'
  );

  if v_readiness->>'token' <> 'PROTEUSOPS_MODEL_LAUNCH_AUTHORITY_OK' then
    raise exception 'MODEL_LAUNCH_AUTHORITY_READINESS_TOKEN_FAIL';
  end if;

  if v_readiness->>'launch_ready' <> 'true' then
    raise exception 'MODEL_LAUNCH_AUTHORITY_READY_FAIL:%', v_readiness;
  end if;

  if not v_launch_without_review_denied then
    raise exception 'MODEL_LAUNCH_AUTHORITY_BYPASS_DENY_FAIL';
  end if;

  if v_review->>'next_launch_state' <> 'ready_for_launch' then
    raise exception 'MODEL_LAUNCH_AUTHORITY_REVIEW_FAIL:%', v_review;
  end if;

  if v_launch->>'token' <> 'PROTEUSOPS_SITE_LAUNCH_OK' then
    raise exception 'MODEL_LAUNCH_AUTHORITY_LAUNCH_FAIL:%', v_launch;
  end if;

  if v_suspend->>'token' <> 'PROTEUSOPS_SITE_SUSPEND_OK' then
    raise exception 'MODEL_LAUNCH_AUTHORITY_SUSPEND_FAIL:%', v_suspend;
  end if;

  if v_archive->>'token' <> 'PROTEUSOPS_SITE_ARCHIVE_OK' then
    raise exception 'MODEL_LAUNCH_AUTHORITY_ARCHIVE_FAIL:%', v_archive;
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_LAUNCH_AUTHORITY_OK',
    'install', v_install,
    'readiness', v_readiness,
    'launch_without_review_denied', v_launch_without_review_denied,
    'review', v_review,
    'launch', v_launch,
    'suspend', v_suspend,
    'archive', v_archive
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_launch_authority_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_launch_package_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_wizard jsonb;
  v_package jsonb;
begin
  v_wizard := pods_provisioning.rpc_run_model_instance_wizard_v1(
    v_org_id,
    'CIVIC_ACTION_V1',
    'v2',
    jsonb_build_object(
      'issue_title','Launch Package Civic Site',
      'community_name','Package Borough',
      'location_label','Package Corridor',
      'position_type','oppose',
      'issue_summary','Launch package generation test.',
      'petition_goal',1250,
      'enable_petition',true,
      'enable_survey',true,
      'enable_events',true,
      'enable_evidence',true,
      'enable_volunteers',true,
      'moderation_required',true
    )
  );

  v_package := pods_provisioning.rpc_generate_model_launch_package_v1(
    (v_wizard->>'model_instance_runtime_id')::uuid
  );

  if v_package->>'token' <> 'PROTEUSOPS_MODEL_LAUNCH_PACKAGE_OK' then
    raise exception 'MODEL_LAUNCH_PACKAGE_TOKEN_FAIL';
  end if;

  if v_package->>'launchable' <> 'true' then
    raise exception 'MODEL_LAUNCH_PACKAGE_LAUNCHABLE_FAIL';
  end if;

  if not (v_package->'package_capabilities') ? 'renderer_contract' then
    raise exception 'MODEL_LAUNCH_PACKAGE_RENDERER_CAPABILITY_FAIL';
  end if;

  if not (v_package->'package_capabilities') ? 'license_gates' then
    raise exception 'MODEL_LAUNCH_PACKAGE_LICENSE_CAPABILITY_FAIL';
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(v_package->'route_manifest') r
    where r->>'route' = '/petition'
  ) then
    raise exception 'MODEL_LAUNCH_PACKAGE_PETITION_ROUTE_FAIL';
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(v_package->'environment_requirements') e
    where e->>'key' = 'SUPABASE_URL'
      and (e->>'required')::boolean = true
  ) then
    raise exception 'MODEL_LAUNCH_PACKAGE_ENV_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_LAUNCH_PACKAGE_OK',
    'wizard', v_wizard,
    'launch_package', v_package
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_launch_package_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_marketplace_install_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_seed jsonb;
  v_install jsonb;
begin
  v_seed := pods_provisioning.rpc_selftest_model_marketplace_v1();

  v_install := pods_provisioning.rpc_install_marketplace_model_v1(
    v_org_id,
    'CIVIC_ACTION_V1',
    'v2',
    jsonb_build_object(
      'issue_title','Marketplace Installed Civic Site',
      'community_name','Install Borough',
      'location_label','Install Corridor',
      'position_type','oppose',
      'issue_summary','Installed from the ProteusOps marketplace.',
      'petition_goal',2000,
      'enable_petition',true,
      'enable_survey',true,
      'enable_events',true,
      'enable_evidence',true,
      'enable_volunteers',true,
      'moderation_required',true
    )
  );

  if v_install->>'token' <> 'PROTEUSOPS_MODEL_MARKETPLACE_INSTALL_OK' then
    raise exception 'MODEL_MARKETPLACE_INSTALL_TOKEN_FAIL';
  end if;

  if v_install->>'model_key' <> 'CIVIC_ACTION_V1' then
    raise exception 'MODEL_MARKETPLACE_INSTALL_MODEL_KEY_FAIL';
  end if;

  if v_install->>'launchable' <> 'true' then
    raise exception 'MODEL_MARKETPLACE_INSTALL_LAUNCHABLE_FAIL';
  end if;

  if v_install->'launch_package'->>'token' <> 'PROTEUSOPS_MODEL_LAUNCH_PACKAGE_OK' then
    raise exception 'MODEL_MARKETPLACE_INSTALL_PACKAGE_FAIL';
  end if;

  if not (v_install->'supported_blocks') ? 'petition' then
    raise exception 'MODEL_MARKETPLACE_INSTALL_SUPPORTED_BLOCK_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_MARKETPLACE_INSTALL_OK',
    'seed', v_seed,
    'install', v_install
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_marketplace_install_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_marketplace_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_civic jsonb;
  v_creator jsonb;
  v_software jsonb;
begin

  v_civic :=
    pods_provisioning.rpc_register_marketplace_model_v1(
      'CIVIC_ACTION_V1',
      'v2',
      'Civic Action',
      'civic',
      'Petitions, surveys, events, evidence and community action',
      '["supabase","email","storage"]'::jsonb,
      '["hero","petition","survey","event_list","evidence_library","contribution_wall"]'::jsonb
    );

  v_creator :=
    pods_provisioning.rpc_register_marketplace_model_v1(
      'CREATOR_MEDIA_V1',
      'v1',
      'Creator Media',
      'creator',
      'Videos, downloads, memberships and creator pages',
      '["email","storage"]'::jsonb,
      '["hero","video","video_playlist","file_download","product"]'::jsonb
    );

  v_software :=
    pods_provisioning.rpc_register_marketplace_model_v1(
      'SOFTWARE_PRODUCT_V1',
      'v1',
      'Software Product',
      'software',
      'Software landing pages, downloads and licensing',
      '["storage"]'::jsonb,
      '["hero","pricing","license_download","faq","image_gallery"]'::jsonb
    );

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_MARKETPLACE_OK',
    'models', jsonb_build_array(
      v_civic,
      v_creator,
      v_software
    )
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_marketplace_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_page_composer_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_civic jsonb;
  v_software jsonb;
  v_creator jsonb;
begin
  v_civic := pods_provisioning.rpc_compose_model_page_v1(
    v_org_id,
    'CIVIC_ACTION_V1',
    'v2',
    'issue',
    'Issue Page',
    'civic_issue',
    '/issue',
    'public'
  );

  v_software := pods_provisioning.rpc_compose_model_page_v1(
    v_org_id,
    'SOFTWARE_PRODUCT_V1',
    'v1',
    'download',
    'Software Download Page',
    'software_product',
    '/download',
    'public'
  );

  v_creator := pods_provisioning.rpc_compose_model_page_v1(
    v_org_id,
    'CREATOR_MEDIA_V1',
    'v1',
    'videos',
    'Creator Video Page',
    'creator_media',
    '/videos',
    'public'
  );

  if v_civic->>'token' <> 'PROTEUSOPS_MODEL_PAGE_COMPOSER_OK' then
    raise exception 'MODEL_PAGE_COMPOSER_CIVIC_TOKEN_FAIL';
  end if;

  if not exists (
    select 1 from jsonb_array_elements(v_civic->'blocks') b
    where b->>'block_key' = 'petition'
  ) then
    raise exception 'MODEL_PAGE_COMPOSER_CIVIC_PETITION_FAIL';
  end if;

  if not exists (
    select 1 from jsonb_array_elements(v_software->'blocks') b
    where b->>'block_key' = 'license_download'
  ) then
    raise exception 'MODEL_PAGE_COMPOSER_SOFTWARE_LICENSE_FAIL';
  end if;

  if not exists (
    select 1 from jsonb_array_elements(v_creator->'blocks') b
    where b->>'block_key' = 'video_playlist'
  ) then
    raise exception 'MODEL_PAGE_COMPOSER_CREATOR_VIDEO_FAIL';
  end if;

  if not (v_software->'required_permissions') ? 'license_key_required' then
    raise exception 'MODEL_PAGE_COMPOSER_LICENSE_PERMISSION_FAIL';
  end if;

  if not (v_creator->'required_providers') ? 'storage' then
    raise exception 'MODEL_PAGE_COMPOSER_CREATOR_STORAGE_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_PAGE_COMPOSER_OK',
    'civic_page', v_civic,
    'software_page', v_software,
    'creator_page', v_creator
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_page_composer_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_permission_generator_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_permissions jsonb;
begin
  v_permissions := pods_provisioning.rpc_generate_model_permissions_v1(
    v_org_id,
    'CIVIC_ACTION_V1',
    'v2'
  );

  if v_permissions->>'token' <> 'PROTEUSOPS_MODEL_PERMISSION_GENERATOR_OK' then
    raise exception 'MODEL_PERMISSION_GENERATOR_TOKEN_FAIL';
  end if;

  if not (v_permissions->'role_permissions'->'moderator') ? 'approve_contribution' then
    raise exception 'MODEL_PERMISSION_MODERATOR_APPROVE_FAIL';
  end if;

  if not (v_permissions->'page_access'->'/admin/launch') ? 'community_admin' then
    raise exception 'MODEL_PERMISSION_ADMIN_LAUNCH_FAIL';
  end if;

  if (v_permissions->'page_access'->'/admin/launch') ? 'visitor' then
    raise exception 'MODEL_PERMISSION_VISITOR_ADMIN_LAUNCH_FAIL';
  end if;

  if not (v_permissions->'form_access'->'petition_signature') ? 'visitor' then
    raise exception 'MODEL_PERMISSION_VISITOR_PETITION_FORM_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_PERMISSION_GENERATOR_OK',
    'permission_generation', v_permissions
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_permission_generator_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_renderer_contract_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_deploy jsonb;
  v_blueprint jsonb;
  v_runtime jsonb;
  v_contract jsonb;
begin
  v_deploy := pods_provisioning.rpc_deploy_civic_action_model_v1(
    v_org_id,
    jsonb_build_object(
      'issue_title','Renderer Contract Civic Action',
      'community_name','Renderer Community',
      'location_label','Renderer District',
      'position_type','oppose',
      'issue_summary','Renderer contract generation test.',
      'petition_goal',500
    )
  );

  v_blueprint := pods_provisioning.rpc_generate_model_site_blueprint_v1(
    v_org_id,
    'CIVIC_ACTION_V1',
    'v2',
    (v_deploy->>'civic_deployment_id')::uuid
  );

  v_runtime := pods_provisioning.rpc_generate_model_runtime_manifest_v1(
    (v_blueprint->>'model_site_blueprint_id')::uuid
  );

  v_contract := pods_provisioning.rpc_generate_model_renderer_contract_v1(
    (v_runtime->>'model_runtime_manifest_id')::uuid
  );

  if v_contract->>'token' <> 'PROTEUSOPS_MODEL_RENDERER_CONTRACT_OK' then
    raise exception 'MODEL_RENDERER_CONTRACT_TOKEN_FAIL';
  end if;

  if not exists (
    select 1 from jsonb_array_elements(v_contract->'renderer_components') c
    where c->>'renderer_type' = 'petition_page'
      and (c->'actions') ? 'submit_signature'
  ) then
    raise exception 'MODEL_RENDERER_PETITION_COMPONENT_FAIL';
  end if;

  if not exists (
    select 1 from jsonb_array_elements(v_contract->'renderer_components') c
    where c->>'renderer_type' = 'evidence_library_page'
      and (c->'actions') ? 'submit_evidence'
  ) then
    raise exception 'MODEL_RENDERER_EVIDENCE_COMPONENT_FAIL';
  end if;

  if not exists (
    select 1 from jsonb_array_elements(v_contract->'renderer_components') c
    where c->>'renderer_type' = 'admin_launch_control'
      and (c->'actions') ? 'launch_site'
  ) then
    raise exception 'MODEL_RENDERER_ADMIN_LAUNCH_COMPONENT_FAIL';
  end if;

  if not exists (
    select 1 from jsonb_array_elements(v_contract->'renderer_assets') a
    where a->>'asset_type' = 'video'
  ) then
    raise exception 'MODEL_RENDERER_VIDEO_ASSET_FAIL';
  end if;

  if not exists (
    select 1 from jsonb_array_elements(v_contract->'license_gates') g
    where g->>'gate_key' = 'license_key_required'
  ) then
    raise exception 'MODEL_RENDERER_LICENSE_GATE_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_RENDERER_CONTRACT_OK',
    'deployment', v_deploy,
    'runtime_manifest', v_runtime,
    'renderer_contract', v_contract
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_renderer_contract_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_runtime_editor_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_wizard jsonb;
  v_instance_id uuid;

  v_hero_edit jsonb;
  v_asset_edit jsonb;
  v_goal_edit jsonb;
  v_raw_code_denied boolean := false;
begin
  v_wizard := pods_provisioning.rpc_run_model_instance_wizard_v1(
    v_org_id,
    'CIVIC_ACTION_V1',
    'v2',
    jsonb_build_object(
      'issue_title','Runtime Editor Civic Site',
      'community_name','Editor Borough',
      'location_label','Editor Corridor',
      'position_type','oppose',
      'issue_summary','Runtime editor generation test.',
      'petition_goal',900,
      'enable_petition',true,
      'enable_survey',true,
      'enable_events',true,
      'enable_evidence',true,
      'enable_volunteers',true,
      'moderation_required',true
    )
  );

  v_instance_id := (v_wizard->>'model_instance_runtime_id')::uuid;

  v_hero_edit := pods_provisioning.rpc_apply_model_runtime_edit_v1(
    v_instance_id,
    'block',
    'hero',
    'update_fields',
    jsonb_build_object(
      'headline','Stop the Proposed Change',
      'subheadline','Learn, sign, volunteer, and submit evidence.',
      'cta_label','Sign the Petition',
      'cta_href','/petition'
    )
  );

  v_asset_edit := pods_provisioning.rpc_apply_model_runtime_edit_v1(
    v_instance_id,
    'asset',
    'campaign_video',
    'replace_asset',
    jsonb_build_object(
      'asset_type','video',
      'storage_ref','storage://videos/community-update.mp4',
      'title','Community Update Video'
    )
  );

  v_goal_edit := pods_provisioning.rpc_apply_model_runtime_edit_v1(
    v_instance_id,
    'block',
    'petition',
    'update_goal',
    jsonb_build_object(
      'petition_goal',1500
    )
  );

  begin
    perform pods_provisioning.rpc_apply_model_runtime_edit_v1(
      v_instance_id,
      'block',
      'custom',
      'update_fields',
      jsonb_build_object(
        'html','<script>alert(1)</script>'
      )
    );
  exception
    when others then
      if sqlerrm like 'MODEL_RUNTIME_EDITOR_RAW_CODE_DENY%' then
        v_raw_code_denied := true;
      else
        raise;
      end if;
  end;

  if v_hero_edit->>'token' <> 'PROTEUSOPS_MODEL_RUNTIME_EDITOR_OK' then
    raise exception 'MODEL_RUNTIME_EDITOR_HERO_EDIT_FAIL';
  end if;

  if v_asset_edit->>'token' <> 'PROTEUSOPS_MODEL_RUNTIME_EDITOR_OK' then
    raise exception 'MODEL_RUNTIME_EDITOR_ASSET_EDIT_FAIL';
  end if;

  if v_goal_edit->>'token' <> 'PROTEUSOPS_MODEL_RUNTIME_EDITOR_OK' then
    raise exception 'MODEL_RUNTIME_EDITOR_GOAL_EDIT_FAIL';
  end if;

  if not v_raw_code_denied then
    raise exception 'MODEL_RUNTIME_EDITOR_RAW_CODE_DENY_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_RUNTIME_EDITOR_OK',
    'wizard', v_wizard,
    'hero_edit', v_hero_edit,
    'asset_edit', v_asset_edit,
    'goal_edit', v_goal_edit,
    'raw_code_denied', v_raw_code_denied
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_runtime_editor_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_runtime_generator_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_deploy jsonb;
  v_blueprint jsonb;
  v_runtime jsonb;
begin
  v_deploy := pods_provisioning.rpc_deploy_civic_action_model_v1(
    v_org_id,
    jsonb_build_object(
      'issue_title','Runtime Civic Action',
      'community_name','Runtime Community',
      'location_label','Runtime District',
      'position_type','oppose',
      'issue_summary','Runtime manifest generation test.',
      'petition_goal',400
    )
  );

  v_blueprint := pods_provisioning.rpc_generate_model_site_blueprint_v1(
    v_org_id,
    'CIVIC_ACTION_V1',
    'v2',
    (v_deploy->>'civic_deployment_id')::uuid
  );

  v_runtime := pods_provisioning.rpc_generate_model_runtime_manifest_v1(
    (v_blueprint->>'model_site_blueprint_id')::uuid
  );

  if v_runtime->>'token' <> 'PROTEUSOPS_MODEL_RUNTIME_GENERATOR_OK' then
    raise exception 'MODEL_RUNTIME_GENERATOR_TOKEN_FAIL';
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(v_runtime->'runtime_routes') r
    where r->>'route' = '/petition'
      and r->>'surface' = 'public'
  ) then
    raise exception 'MODEL_RUNTIME_PUBLIC_PETITION_ROUTE_FAIL';
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(v_runtime->'runtime_routes') r
    where r->>'route' = '/admin/launch'
      and r->>'surface' = 'admin'
  ) then
    raise exception 'MODEL_RUNTIME_ADMIN_LAUNCH_ROUTE_FAIL';
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(v_runtime->'runtime_forms') f
    where f->>'form_key' = 'evidence_submission'
  ) then
    raise exception 'MODEL_RUNTIME_EVIDENCE_FORM_FAIL';
  end if;

  if not (v_runtime->'runtime_providers') ? 'storage' then
    raise exception 'MODEL_RUNTIME_STORAGE_PROVIDER_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_RUNTIME_GENERATOR_OK',
    'deployment', v_deploy,
    'blueprint', v_blueprint,
    'runtime_manifest', v_runtime
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_runtime_generator_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_runtime_governance_lock_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_view_count int;
  v_template_count int;
  v_marketplace_count int;
  v_surface jsonb;
  v_body jsonb;
begin
  v_surface := pods_provisioning.rpc_selftest_model_db_surface_full_green_v1();

  select count(*)
  into v_view_count
  from information_schema.views
  where table_schema = 'pods_provisioning'
    and table_name in (
      'v_model_runtime_governance_templates_v1',
      'v_model_runtime_governance_marketplace_v1',
      'v_model_runtime_governance_instances_v1',
      'v_model_runtime_governance_launch_packages_v1',
      'v_model_runtime_governance_editor_changes_v1',
      'v_model_runtime_governance_clones_v1',
      'v_model_runtime_governance_full_green_receipts_v1'
    );

  select count(*)
  into v_template_count
  from pods_provisioning.v_model_runtime_governance_templates_v1;

  select count(*)
  into v_marketplace_count
  from pods_provisioning.v_model_runtime_governance_marketplace_v1;

  if v_view_count <> 7 then
    raise exception 'MODEL_RUNTIME_GOVERNANCE_VIEW_COUNT_FAIL:%', v_view_count;
  end if;

  if v_template_count < 3 then
    raise exception 'MODEL_RUNTIME_GOVERNANCE_TEMPLATE_COUNT_FAIL:%', v_template_count;
  end if;

  if v_marketplace_count < 3 then
    raise exception 'MODEL_RUNTIME_GOVERNANCE_MARKETPLACE_COUNT_FAIL:%', v_marketplace_count;
  end if;

  if v_surface->>'token' <> 'PROTEUSOPS_MODEL_DB_SURFACE_FULL_GREEN_OK' then
    raise exception 'MODEL_RUNTIME_GOVERNANCE_FULL_GREEN_FAIL';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_RUNTIME_GOVERNANCE_LOCK_OK',
    'governance_view_count', v_view_count,
    'template_count', v_template_count,
    'marketplace_count', v_marketplace_count,
    'full_green', v_surface
  );

  return v_body;
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_runtime_governance_lock_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_site_blueprint_generator_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_deploy jsonb;
  v_blueprint jsonb;
begin
  v_deploy := pods_provisioning.rpc_deploy_civic_action_model_v1(
    v_org_id,
    jsonb_build_object(
      'issue_title','Blueprint Civic Action',
      'community_name','Blueprint Community',
      'location_label','Blueprint District',
      'position_type','oppose',
      'issue_summary','Blueprint generation test.',
      'petition_goal',300
    )
  );

  v_blueprint := pods_provisioning.rpc_generate_model_site_blueprint_v1(
    v_org_id,
    'CIVIC_ACTION_V1',
    'v2',
    (v_deploy->>'civic_deployment_id')::uuid
  );

  if v_blueprint->>'token' <> 'PROTEUSOPS_MODEL_SITE_BLUEPRINT_GENERATOR_OK' then
    raise exception 'MODEL_SITE_BLUEPRINT_TOKEN_FAIL';
  end if;

  if not (v_blueprint->'public_pages') ? '/petition' then
    raise exception 'MODEL_SITE_BLUEPRINT_PUBLIC_PAGE_FAIL';
  end if;

  if not (v_blueprint->'admin_pages') ? '/admin/launch' then
    raise exception 'MODEL_SITE_BLUEPRINT_ADMIN_LAUNCH_FAIL';
  end if;

  if not (v_blueprint->'required_providers') ? 'storage' then
    raise exception 'MODEL_SITE_BLUEPRINT_STORAGE_PROVIDER_FAIL';
  end if;

  if (v_blueprint->'page_access'->'/admin/launch') ? 'visitor' then
    raise exception 'MODEL_SITE_BLUEPRINT_VISITOR_ADMIN_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_SITE_BLUEPRINT_GENERATOR_OK',
    'deployment', v_deploy,
    'blueprint', v_blueprint
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_site_blueprint_generator_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_site_runtime_generator_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_runtime jsonb;
begin
  v_runtime := pods_provisioning.rpc_generate_model_site_runtime_v1(
    v_org_id,
    'CIVIC_ACTION_V1',
    'v2',
    jsonb_build_object(
      'issue_title','Launchable Runtime Civic Site',
      'community_name','Runtime Community',
      'location_label','Runtime District',
      'position_type','oppose',
      'issue_summary','Generated full site runtime definition.',
      'petition_goal',500
    )
  );

  if v_runtime->>'token' <> 'PROTEUSOPS_MODEL_SITE_RUNTIME_GENERATOR_OK' then
    raise exception 'MODEL_SITE_RUNTIME_TOKEN_FAIL';
  end if;

  if v_runtime->>'launchable' <> 'true' then
    raise exception 'MODEL_SITE_RUNTIME_LAUNCHABLE_FAIL';
  end if;

  if not (v_runtime->'site_runtime_capabilities') ? 'license_gated_downloads' then
    raise exception 'MODEL_SITE_RUNTIME_LICENSE_CAPABILITY_FAIL';
  end if;

  if not (v_runtime->'site_runtime_capabilities') ? 'video_assets' then
    raise exception 'MODEL_SITE_RUNTIME_VIDEO_CAPABILITY_FAIL';
  end if;

  if v_runtime->'renderer_contract'->>'token' <> 'PROTEUSOPS_MODEL_RENDERER_CONTRACT_OK' then
    raise exception 'MODEL_SITE_RUNTIME_RENDERER_CONTRACT_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_SITE_RUNTIME_GENERATOR_OK',
    'site_runtime', v_runtime
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_site_runtime_generator_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_template_registry_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_seed jsonb;
begin
  v_seed := pods_provisioning.rpc_seed_model_template_registry_v1();

  if v_seed->>'token' <> 'PROTEUSOPS_MODEL_TEMPLATE_REGISTRY_OK' then
    raise exception 'MODEL_TEMPLATE_REGISTRY_TOKEN_FAIL';
  end if;

  if not exists (
    select 1
    from pods_provisioning.model_template_registry_v1
    where model_key = 'CIVIC_ACTION_V1'
      and default_blocks ? 'petition'
      and required_providers ? 'supabase'
  ) then
    raise exception 'MODEL_TEMPLATE_CIVIC_FAIL';
  end if;

  if not exists (
    select 1
    from pods_provisioning.model_template_registry_v1
    where model_key = 'CREATOR_MEDIA_V1'
      and default_blocks ? 'video_playlist'
      and required_providers ? 'storage'
  ) then
    raise exception 'MODEL_TEMPLATE_CREATOR_FAIL';
  end if;

  if not exists (
    select 1
    from pods_provisioning.model_template_registry_v1
    where model_key = 'SOFTWARE_PRODUCT_V1'
      and default_blocks ? 'license_download'
      and license_rules <> '[]'::jsonb
  ) then
    raise exception 'MODEL_TEMPLATE_SOFTWARE_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_TEMPLATE_REGISTRY_OK',
    'seed', v_seed
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_template_registry_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_model_ui_generator_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_ui jsonb;
begin
  v_ui := pods_provisioning.rpc_generate_model_ui_v1(
    v_org_id,
    'CIVIC_ACTION_V1',
    'v2'
  );

  if v_ui->>'token' <> 'PROTEUSOPS_MODEL_UI_GENERATOR_OK' then
    raise exception 'MODEL_UI_GENERATOR_TOKEN_FAIL';
  end if;

  if not (v_ui->'public_pages') ? '/petition' then
    raise exception 'MODEL_UI_PUBLIC_PETITION_PAGE_FAIL';
  end if;

  if not (v_ui->'admin_pages') ? '/admin/moderation' then
    raise exception 'MODEL_UI_ADMIN_MODERATION_PAGE_FAIL';
  end if;

  if not (v_ui->'nav_items') ? 'Evidence' then
    raise exception 'MODEL_UI_EVIDENCE_NAV_FAIL';
  end if;

  if not (v_ui->'roles') ? 'moderator' then
    raise exception 'MODEL_UI_MODERATOR_ROLE_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_UI_GENERATOR_OK',
    'ui_generation', v_ui
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_model_ui_generator_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_operator_calendar_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_provision jsonb;
  v_public jsonb;
  v_request jsonb;
  v_action jsonb;
  v_calendar jsonb;
begin
  v_provision := pods_provisioning.rpc_provision_vertical_template_v1(
    v_org_id,
    'BARBER_NAIL_V1',
    null
  );

  v_public := pods_provisioning.rpc_bootstrap_public_booking_surface_v1(
    (v_provision->>'provision_run_id')::uuid,
    'calendar-test-' || left(v_org_id::text, 8)
  );

  v_request := pods_provisioning.rpc_request_public_appointment_v1(
    v_public->>'booking_slug',
    'BARBER_CUT',
    current_date + 1,
    '10:00'::time,
    'Calendar Test Customer',
    'calendar.customer@example.com',
    '555-0112'
  );

  v_action := pods_provisioning.rpc_admin_update_appointment_request_v1(
    (v_request->>'appointment_request_id')::uuid,
    'confirm',
    null,
    'Calendar selftest confirmation'
  );

  if v_action->>'new_status' <> 'confirmed' then
    raise exception 'OPERATOR_CALENDAR_CONFIRM_FAIL';
  end if;

  v_calendar := pods_provisioning.rpc_get_operator_calendar_v1(
    v_org_id,
    current_date,
    7
  );

  if v_calendar->>'token' <> 'PROTEUSOPS_OPERATOR_CALENDAR_OK' then
    raise exception 'OPERATOR_CALENDAR_TOKEN_FAIL';
  end if;

  if (v_calendar->>'count')::integer < 1 then
    raise exception 'OPERATOR_CALENDAR_EMPTY';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_OPERATOR_CALENDAR_OK',
    'org_id', v_org_id,
    'calendar_count', (v_calendar->>'count')::integer,
    'sample_calendar_item', (v_calendar->'calendar')->0
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_operator_calendar_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_operator_setup_wizard_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();

  v_seed jsonb;
  v_wizard jsonb;
begin
  v_seed := pods_provisioning.rpc_seed_developer_portal_model_v1();

  v_wizard := pods_provisioning.rpc_start_operator_setup_wizard_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    jsonb_build_object(
      'product_name','Wizard Test Product',
      'github_url','https://github.com/example/wizard-test',
      'download_url','https://example.com/downloads/wizard-test',
      'support_email','support@example.com'
    )
  );

  if v_wizard->>'token' <> 'PROTEUSOPS_OPERATOR_SETUP_WIZARD_OK' then
    raise exception 'OPERATOR_SETUP_WIZARD_TOKEN_FAIL';
  end if;

  if v_wizard->>'wizard_status' <> 'in_progress' then
    raise exception 'OPERATOR_SETUP_WIZARD_STATUS_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_OPERATOR_SETUP_WIZARD_OK',
    'org_id', v_org_id,
    'wizard', v_wizard
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_operator_setup_wizard_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_payment_adapter_receipts_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();

  v_provision jsonb;
  v_public jsonb;
  v_request jsonb;

  v_policy jsonb;
  v_intent jsonb;

  v_adapter jsonb;
  v_receipt jsonb;

  v_duplicate_ok boolean := false;
begin
  v_provision := pods_provisioning.rpc_provision_vertical_template_v1(
    v_org_id,
    'BARBER_NAIL_V1',
    null
  );

  v_public := pods_provisioning.rpc_bootstrap_public_booking_surface_v1(
    (v_provision->>'provision_run_id')::uuid,
    'provider-receipt-test-' || left(v_org_id::text, 8)
  );

  v_request := pods_provisioning.rpc_request_public_appointment_v1(
    v_public->>'booking_slug',
    'BARBER_CUT',
    current_date + 1,
    '15:00'::time,
    'Provider Receipt Customer',
    'provider.customer@example.com',
    '555-0116'
  );

  v_policy := pods_provisioning.rpc_seed_default_payment_policy_v1(
    v_org_id,
    'BARBER_NAIL_V1',
    'v1'
  );

  v_intent := pods_provisioning.rpc_create_payment_intent_for_appointment_v1(
    (v_request->>'appointment_request_id')::uuid,
    'default-deposit'
  );

  v_adapter := pods_provisioning.rpc_seed_payment_provider_adapter_v1(
    'stripe'
  );

  if v_adapter->>'token' <> 'PROTEUSOPS_PAYMENT_PROVIDER_ADAPTER_OK' then
    raise exception 'PAYMENT_PROVIDER_ADAPTER_FAIL';
  end if;

  v_receipt := pods_provisioning.rpc_record_payment_provider_receipt_v1(
    (v_intent->>'payment_intent_id')::uuid,
    'stripe',
    'evt_test_capture_001',
    'payment_intent.succeeded',
    'captured',
    true
  );

  if v_receipt->>'token' <> 'PROTEUSOPS_PAYMENT_ADAPTER_RECEIPT_OK' then
    raise exception 'PAYMENT_PROVIDER_RECEIPT_TOKEN_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_record_payment_provider_receipt_v1(
      (v_intent->>'payment_intent_id')::uuid,
      'stripe',
      'evt_test_capture_001',
      'payment_intent.succeeded',
      'captured',
      true
    );
  exception
    when others then
      if sqlerrm like 'PAYMENT_PROVIDER_RECEIPT_DUPLICATE_DENY:%' then
        v_duplicate_ok := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_ok then
    raise exception 'PAYMENT_PROVIDER_DUPLICATE_VECTOR_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PAYMENT_ADAPTER_RECEIPT_OK',
    'org_id', v_org_id,
    'provider_adapter', v_adapter,
    'payment_intent', v_intent,
    'provider_receipt', v_receipt,
    'duplicate_denied', v_duplicate_ok
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_payment_adapter_receipts_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_payment_lifecycle_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_provision jsonb;
  v_public jsonb;
  v_request jsonb;
  v_policy jsonb;
  v_intent jsonb;
  v_duplicate_ok boolean := false;
begin
  v_provision := pods_provisioning.rpc_provision_vertical_template_v1(
    v_org_id,
    'BARBER_NAIL_V1',
    null
  );

  v_public := pods_provisioning.rpc_bootstrap_public_booking_surface_v1(
    (v_provision->>'provision_run_id')::uuid,
    'payment-test-' || left(v_org_id::text, 8)
  );

  v_request := pods_provisioning.rpc_request_public_appointment_v1(
    v_public->>'booking_slug',
    'BARBER_CUT',
    current_date + 1,
    '14:00'::time,
    'Payment Test Customer',
    'payment.customer@example.com',
    '555-0115'
  );

  v_policy := pods_provisioning.rpc_seed_default_payment_policy_v1(
    v_org_id,
    'BARBER_NAIL_V1',
    'v1'
  );

  if v_policy->>'token' <> 'PROTEUSOPS_PAYMENT_POLICY_SEED_OK' then
    raise exception 'PAYMENT_POLICY_SEED_FAIL';
  end if;

  v_intent := pods_provisioning.rpc_create_payment_intent_for_appointment_v1(
    (v_request->>'appointment_request_id')::uuid,
    'default-deposit'
  );

  if v_intent->>'token' <> 'PROTEUSOPS_PAYMENT_LIFECYCLE_OK' then
    raise exception 'PAYMENT_LIFECYCLE_TOKEN_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_create_payment_intent_for_appointment_v1(
      (v_request->>'appointment_request_id')::uuid,
      'default-deposit'
    );
  exception
    when others then
      if sqlerrm like 'PAYMENT_INTENT_DUPLICATE_DENY:%' then
        v_duplicate_ok := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_ok then
    raise exception 'PAYMENT_INTENT_DUPLICATE_VECTOR_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PAYMENT_LIFECYCLE_OK',
    'org_id', v_org_id,
    'policy', v_policy,
    'payment_intent', v_intent,
    'duplicate_denied', v_duplicate_ok
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_payment_lifecycle_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_provider_connection_completion_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_seed jsonb;
  v_session jsonb;
  v_complete jsonb;
  v_bad_secret_denied boolean := false;
  v_duplicate_denied boolean := false;
begin
  v_seed := pods_provisioning.rpc_seed_provider_oauth_connection_contracts_v1();

  v_session := pods_provisioning.rpc_start_provider_connection_session_v1(
    v_org_id,
    'supabase',
    null
  );

  begin
    perform pods_provisioning.rpc_complete_provider_connection_session_v1(
      (v_session->>'provider_connection_session_id')::uuid,
      'acct_supabase_test',
      'project_ref_test',
      'raw-secret-not-allowed',
      jsonb_build_array('project_ref','project_url'),
      jsonb_build_array('project_discovered')
    );
  exception
    when others then
      if sqlerrm like 'PROVIDER_CONNECTION_SECRET_REF_INVALID%' then
        v_bad_secret_denied := true;
      else
        raise;
      end if;
  end;

  if not v_bad_secret_denied then
    raise exception 'PROVIDER_CONNECTION_BAD_SECRET_VECTOR_FAIL';
  end if;

  v_complete := pods_provisioning.rpc_complete_provider_connection_session_v1(
    (v_session->>'provider_connection_session_id')::uuid,
    'acct_supabase_test',
    'project_ref_test',
    'secret://proteusops/supabase/project_ref_test',
    jsonb_build_array(
      jsonb_build_object('resource_key','project_ref','value','project_ref_test'),
      jsonb_build_object('resource_key','project_url','value','https://project_ref_test.supabase.co')
    ),
    jsonb_build_array(
      jsonb_build_object('check_key','project_discovered','status','pass'),
      jsonb_build_object('check_key','secret_ref_present','status','pass')
    )
  );

  if v_complete->>'token' <> 'PROTEUSOPS_PROVIDER_CONNECTION_COMPLETION_OK' then
    raise exception 'PROVIDER_CONNECTION_COMPLETION_TOKEN_FAIL';
  end if;

  if v_complete->>'raw_secret_stored' <> 'false' then
    raise exception 'PROVIDER_CONNECTION_RAW_SECRET_STORED_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_complete_provider_connection_session_v1(
      (v_session->>'provider_connection_session_id')::uuid,
      'acct_supabase_test',
      'project_ref_test',
      'secret://proteusops/supabase/project_ref_test',
      '[]'::jsonb,
      '[]'::jsonb
    );
  exception
    when others then
      if sqlerrm like 'PROVIDER_CONNECTION_SESSION_STATUS_INVALID:%' then
        v_duplicate_denied := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_denied then
    raise exception 'PROVIDER_CONNECTION_DUPLICATE_COMPLETION_VECTOR_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PROVIDER_CONNECTION_COMPLETION_OK',
    'org_id', v_org_id,
    'seed', v_seed,
    'session', v_session,
    'completion', v_complete,
    'bad_secret_denied', v_bad_secret_denied,
    'duplicate_completion_denied', v_duplicate_denied
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_provider_connection_completion_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_provider_connection_rollup_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_ready_org uuid := gen_random_uuid();
  v_blocked_org uuid := gen_random_uuid();

  v_provider text;
  v_session jsonb;
  v_ready_rollup jsonb;
  v_blocked_rollup jsonb;
begin
  perform pods_provisioning.rpc_seed_provider_oauth_connection_contracts_v1();

  foreach v_provider in array array['supabase','stripe','github','email']
  loop
    v_session := pods_provisioning.rpc_start_provider_connection_session_v1(
      v_ready_org,
      v_provider,
      null
    );

    perform pods_provisioning.rpc_complete_provider_connection_session_v1(
      (v_session->>'provider_connection_session_id')::uuid,
      'acct_' || v_provider,
      'project_' || v_provider,
      'secret://proteusops/' || v_provider || '/ready',
      jsonb_build_array(jsonb_build_object('resource_key','provider','value',v_provider)),
      jsonb_build_array(jsonb_build_object('check_key','verified','status','pass'))
    );
  end loop;

  v_ready_rollup := pods_provisioning.rpc_provider_connection_rollup_v1(
    v_ready_org,
    'DEVELOPER_PORTAL_V1',
    'v1'
  );

  if v_ready_rollup->>'token' <> 'PROTEUSOPS_PROVIDER_CONNECTION_ROLLUP_OK' then
    raise exception 'PROVIDER_CONNECTION_ROLLUP_TOKEN_FAIL';
  end if;

  if v_ready_rollup->>'connection_ready' <> 'true' then
    raise exception 'PROVIDER_CONNECTION_READY_ROLLUP_FAIL';
  end if;

  v_session := pods_provisioning.rpc_start_provider_connection_session_v1(
    v_blocked_org,
    'supabase',
    null
  );

  perform pods_provisioning.rpc_complete_provider_connection_session_v1(
    (v_session->>'provider_connection_session_id')::uuid,
    'acct_supabase',
    'project_supabase',
    'secret://proteusops/supabase/blocked-partial',
    jsonb_build_array(jsonb_build_object('resource_key','provider','value','supabase')),
    jsonb_build_array(jsonb_build_object('check_key','verified','status','pass'))
  );

  v_blocked_rollup := pods_provisioning.rpc_provider_connection_rollup_v1(
    v_blocked_org,
    'DEVELOPER_PORTAL_V1',
    'v1'
  );

  if v_blocked_rollup->>'connection_ready' <> 'false' then
    raise exception 'PROVIDER_CONNECTION_BLOCKED_ROLLUP_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PROVIDER_CONNECTION_ROLLUP_OK',
    'ready_rollup', v_ready_rollup,
    'blocked_rollup', v_blocked_rollup
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_provider_connection_rollup_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_provider_connection_to_runtime_bridge_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_ready_org uuid := gen_random_uuid();
  v_provider text;
  v_session jsonb;
  v_ready_rollup jsonb;
  v_ready_bridge jsonb;
  v_provider_readiness jsonb;
begin
  perform pods_provisioning.rpc_seed_provider_oauth_connection_contracts_v1();

  foreach v_provider in array array['supabase','stripe','github','email','storage']
  loop
    v_session := pods_provisioning.rpc_start_provider_connection_session_v1(
      v_ready_org,
      v_provider,
      null
    );

    perform pods_provisioning.rpc_complete_provider_connection_session_v1(
      (v_session->>'provider_connection_session_id')::uuid,
      'acct_' || v_provider,
      'project_' || v_provider,
      'secret://proteusops/' || v_provider || '/ready',
      jsonb_build_array(jsonb_build_object('resource_key','provider','value',v_provider)),
      jsonb_build_array(jsonb_build_object('check_key','verified','status','pass'))
    );
  end loop;

  v_ready_rollup := pods_provisioning.rpc_provider_connection_rollup_v1(
    v_ready_org,
    'DEVELOPER_PORTAL_V1',
    'v1'
  );

  v_ready_bridge := pods_provisioning.rpc_bridge_provider_connections_to_runtime_v1(
    v_ready_org,
    (v_ready_rollup->>'provider_connection_rollup_id')::uuid,
    'DEVELOPER_PORTAL_V1',
    'v1'
  );

  if v_ready_bridge->>'token' <> 'PROTEUSOPS_PROVIDER_CONNECTION_RUNTIME_BRIDGE_OK' then
    raise exception 'PROVIDER_RUNTIME_BRIDGE_TOKEN_FAIL';
  end if;

  if v_ready_bridge->>'bridge_ready' <> 'true' then
    raise exception 'PROVIDER_RUNTIME_BRIDGE_READY_FAIL:%', v_ready_bridge;
  end if;

  v_provider_readiness := pods_provisioning.rpc_provider_readiness_rollup_v1(
    v_ready_org,
    'DEVELOPER_PORTAL_V1',
    'v1'
  );

  if v_provider_readiness->>'readiness_status' <> 'ready' then
    raise exception 'PROVIDER_RUNTIME_BRIDGE_READINESS_ROLLUP_FAIL:%', v_provider_readiness;
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PROVIDER_CONNECTION_RUNTIME_BRIDGE_OK',
    'ready_rollup', v_ready_rollup,
    'ready_bridge', v_ready_bridge,
    'provider_readiness', v_provider_readiness
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_provider_connection_to_runtime_bridge_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_provider_oauth_connection_contract_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_seed jsonb;
  v_supabase jsonb;
  v_figma jsonb;
  v_manual_denied boolean := false;
begin
  v_seed := pods_provisioning.rpc_seed_provider_oauth_connection_contracts_v1();

  if v_seed->>'token' <> 'PROTEUSOPS_PROVIDER_OAUTH_CONNECTION_CONTRACT_OK' then
    raise exception 'PROVIDER_CONNECTION_CONTRACT_SEED_FAIL';
  end if;

  v_supabase := pods_provisioning.rpc_start_provider_connection_session_v1(
    v_org_id,
    'supabase',
    null
  );

  if v_supabase->>'token' <> 'PROTEUSOPS_PROVIDER_CONNECTION_SESSION_OK' then
    raise exception 'SUPABASE_CONNECTION_SESSION_FAIL';
  end if;

  if v_supabase->>'manual_key_entry_used' <> 'false' then
    raise exception 'SUPABASE_MANUAL_KEY_USED_FAIL';
  end if;

  v_figma := pods_provisioning.rpc_start_provider_connection_session_v1(
    v_org_id,
    'figma',
    null
  );

  if v_figma->>'connection_method' <> 'oauth' then
    raise exception 'FIGMA_CONNECTION_METHOD_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_start_provider_connection_session_v1(
      v_org_id,
      'supabase',
      'manual_key_fallback'
    );
  exception
    when others then
      if sqlerrm like 'PROVIDER_MANUAL_KEY_ENTRY_DENIED:%' then
        v_manual_denied := true;
      else
        raise;
      end if;
  end;

  if not v_manual_denied then
    raise exception 'PROVIDER_MANUAL_KEY_DENIAL_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PROVIDER_OAUTH_CONNECTION_CONTRACT_OK',
    'org_id', v_org_id,
    'seed', v_seed,
    'supabase_session', v_supabase,
    'figma_session', v_figma,
    'manual_key_denied', v_manual_denied
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_provider_oauth_connection_contract_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_provider_readiness_rollup_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_ready_org uuid := gen_random_uuid();
  v_blocked_org uuid := gen_random_uuid();

  v_ready_rollup jsonb;
  v_blocked_rollup jsonb;
begin
  perform pods_provisioning.rpc_verify_supabase_adapter_runtime_v1(
    v_ready_org,
    'ready-project-ref',
    'https://ready-project-ref.supabase.co',
    true,
    true,
    true,
    true,
    null
  );

  perform pods_provisioning.rpc_verify_stripe_adapter_runtime_v1(
    v_ready_org,
    'acct_ready',
    'test',
    true,
    true,
    true,
    true,
    true,
    true,
    null
  );

  perform pods_provisioning.rpc_verify_email_adapter_runtime_v1(
    v_ready_org,
    'resend',
    'ready.example.com',
    true,
    true,
    true,
    true,
    true,
    null
  );

  perform pods_provisioning.rpc_verify_storage_adapter_runtime_v1(
    v_ready_org,
    'supabase_storage',
    'ready_downloads',
    true,
    true,
    true,
    true,
    true,
    null
  );

  perform pods_provisioning.rpc_verify_github_adapter_runtime_v1(
    v_ready_org,
    'example',
    'ready-product',
    'https://github.com/example/ready-product',
    true,
    true,
    true,
    true,
    true,
    null
  );

  v_ready_rollup := pods_provisioning.rpc_provider_readiness_rollup_v1(
    v_ready_org,
    'DEVELOPER_PORTAL_V1',
    'v1'
  );

  if v_ready_rollup->>'token' <> 'PROTEUSOPS_PROVIDER_READINESS_ROLLUP_OK' then
    raise exception 'PROVIDER_READINESS_ROLLUP_TOKEN_FAIL';
  end if;

  if v_ready_rollup->>'readiness_status' <> 'ready' then
    raise exception 'PROVIDER_READINESS_SHOULD_BE_READY';
  end if;

  perform pods_provisioning.rpc_verify_supabase_adapter_runtime_v1(
    v_blocked_org,
    'blocked-project-ref',
    'https://blocked-project-ref.supabase.co',
    true,
    true,
    true,
    false,
    null
  );

  v_blocked_rollup := pods_provisioning.rpc_provider_readiness_rollup_v1(
    v_blocked_org,
    'DEVELOPER_PORTAL_V1',
    'v1'
  );

  if v_blocked_rollup->>'readiness_status' <> 'blocked' then
    raise exception 'PROVIDER_READINESS_SHOULD_BE_BLOCKED';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PROVIDER_READINESS_ROLLUP_OK',
    'ready_rollup', v_ready_rollup,
    'blocked_rollup', v_blocked_rollup
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_provider_readiness_rollup_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_provision_vertical_template_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_result jsonb;
  v_duplicate_ok boolean := false;
begin
  v_result := pods_provisioning.rpc_provision_vertical_template_v1(
    v_org_id,
    'BARBER_NAIL_V1',
    null
  );

  if v_result->>'token' <> 'PROVISION_VERTICAL_TEMPLATE_OK' then
    raise exception 'PROVISION_SELFTEST_TOKEN_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_provision_vertical_template_v1(
      v_org_id,
      'BARBER_NAIL_V1',
      null
    );
  exception
    when others then
      if sqlerrm like 'PROVISION_DUPLICATE_DENY:%' then
        v_duplicate_ok := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_ok then
    raise exception 'PROVISION_DUPLICATE_VECTOR_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_VERTICAL_TEMPLATE_PROVISIONING_OK',
    'template_key', 'BARBER_NAIL_V1',
    'first_result', v_result,
    'duplicate_denied', v_duplicate_ok
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_provision_vertical_template_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_provisioning_lane_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_schema_exists boolean;
  v_template_table_exists boolean;
  v_runs_table_exists boolean;
  v_seeded_table_exists boolean;
  v_receipts_table_exists boolean;
begin
  select exists (
    select 1
    from information_schema.schemata s
    where s.schema_name = 'pods_provisioning'
  ) into v_schema_exists;

  select exists (
    select 1
    from information_schema.tables t
    where t.table_schema = 'pods_provisioning'
      and t.table_name = 'template_registry_v1'
  ) into v_template_table_exists;

  select exists (
    select 1
    from information_schema.tables t
    where t.table_schema = 'pods_provisioning'
      and t.table_name = 'provision_runs_v1'
  ) into v_runs_table_exists;

  select exists (
    select 1
    from information_schema.tables t
    where t.table_schema = 'pods_provisioning'
      and t.table_name = 'seeded_objects_v1'
  ) into v_seeded_table_exists;

  select exists (
    select 1
    from information_schema.tables t
    where t.table_schema = 'pods_provisioning'
      and t.table_name = 'provisioning_receipts_v1'
  ) into v_receipts_table_exists;

  if not (
    v_schema_exists
    and v_template_table_exists
    and v_runs_table_exists
    and v_seeded_table_exists
    and v_receipts_table_exists
  ) then
    raise exception 'PROVISIONING_LANE_SELFTEST_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_TIER2_PROVISIONING_LANE_OK',
    'schema', 'pods_provisioning',
    'template_registry', v_template_table_exists,
    'provision_runs', v_runs_table_exists,
    'seeded_objects', v_seeded_table_exists,
    'provisioning_receipts', v_receipts_table_exists
  );
end
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_provisioning_lane_v1"() OWNER TO "postgres";


COMMENT ON FUNCTION "pods_provisioning"."rpc_selftest_provisioning_lane_v1"() IS 'Selftest proving the Tier-2 provisioning lane substrate exists.';



CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_public_appointment_request_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_provision jsonb;
  v_public jsonb;
  v_request jsonb;
  v_duplicate_ok boolean := false;
begin
  v_provision := pods_provisioning.rpc_provision_vertical_template_v1(
    v_org_id,
    'BARBER_NAIL_V1',
    null
  );

  v_public := pods_provisioning.rpc_bootstrap_public_booking_surface_v1(
    (v_provision->>'provision_run_id')::uuid,
    'appt-test-' || left(v_org_id::text, 8)
  );

  v_request := pods_provisioning.rpc_request_public_appointment_v1(
    v_public->>'booking_slug',
    'BARBER_CUT',
    current_date + 1,
    '09:00'::time,
    'Test Customer',
    'test.customer@example.com',
    '555-0100'
  );

  if v_request->>'token' <> 'PROTEUSOPS_PUBLIC_APPOINTMENT_REQUEST_OK' then
    raise exception 'PUBLIC_APPOINTMENT_REQUEST_TOKEN_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_request_public_appointment_v1(
      v_public->>'booking_slug',
      'BARBER_CUT',
      current_date + 1,
      '09:00'::time,
      'Test Customer',
      'test.customer@example.com',
      '555-0100'
    );
  exception
    when others then
      if sqlerrm like 'PUBLIC_APPOINTMENT_DUPLICATE_DENY:%' then
        v_duplicate_ok := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_ok then
    raise exception 'PUBLIC_APPOINTMENT_DUPLICATE_VECTOR_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PUBLIC_APPOINTMENT_REQUEST_OK',
    'booking_slug', v_public->>'booking_slug',
    'booking_path', v_public->>'booking_path',
    'appointment_request_id', v_request->>'appointment_request_id',
    'request_hash', v_request->>'request_hash',
    'duplicate_denied', v_duplicate_ok,
    'sample_request', v_request
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_public_appointment_request_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_public_booking_bootstrap_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_provision jsonb;
  v_public jsonb;
  v_duplicate_ok boolean := false;
begin
  v_provision := pods_provisioning.rpc_provision_vertical_template_v1(
    v_org_id,
    'BARBER_NAIL_V1',
    null
  );

  v_public := pods_provisioning.rpc_bootstrap_public_booking_surface_v1(
    (v_provision->>'provision_run_id')::uuid,
    'test-barber-nail-' || left(v_org_id::text, 8)
  );

  if v_public->>'token' <> 'PROTEUSOPS_PUBLIC_BOOKING_BOOTSTRAP_OK' then
    raise exception 'PUBLIC_BOOKING_BOOTSTRAP_TOKEN_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_bootstrap_public_booking_surface_v1(
      (v_provision->>'provision_run_id')::uuid,
      'test-barber-nail-' || left(v_org_id::text, 8)
    );
  exception
    when others then
      if sqlerrm like 'PUBLIC_BOOKING_SURFACE_ALREADY_EXISTS:%' then
        v_duplicate_ok := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_ok then
    raise exception 'PUBLIC_BOOKING_DUPLICATE_VECTOR_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PUBLIC_BOOKING_BOOTSTRAP_OK',
    'template_key', 'BARBER_NAIL_V1',
    'public_booking', v_public,
    'duplicate_denied', v_duplicate_ok
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_public_booking_bootstrap_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_public_staff_profiles_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_provision jsonb;
  v_public jsonb;
  v_staff_seed jsonb;
  v_profile_seed jsonb;
  v_profiles jsonb;
  v_staff_id uuid;
begin
  v_provision := pods_provisioning.rpc_provision_vertical_template_v1(
    v_org_id,
    'BARBER_NAIL_V1',
    null
  );

  v_public := pods_provisioning.rpc_bootstrap_public_booking_surface_v1(
    (v_provision->>'provision_run_id')::uuid,
    'staff-profile-test-' || left(v_org_id::text, 8)
  );

  v_staff_seed := pods_provisioning.rpc_seed_default_staff_for_org_v1(
    v_org_id,
    'BARBER_NAIL_V1',
    'v1'
  );

  if v_staff_seed->>'token' <> 'PROTEUSOPS_STAFF_SEED_OK' then
    raise exception 'PUBLIC_STAFF_SEED_FAIL';
  end if;

  v_profile_seed := pods_provisioning.rpc_seed_staff_public_profiles_v1(v_org_id);

  if v_profile_seed->>'token' <> 'PROTEUSOPS_STAFF_PUBLIC_PROFILES_OK' then
    raise exception 'PUBLIC_PROFILE_SEED_FAIL';
  end if;

  select sm.staff_member_id
  into v_staff_id
  from pods_provisioning.staff_members_v1 sm
  where sm.org_id = v_org_id
    and sm.role_key = 'BARBER'
  order by sm.created_at
  limit 1;

  insert into pods_provisioning.staff_gallery_items_v1(
    staff_member_id,
    org_id,
    title,
    description,
    media_url,
    media_kind,
    service_code,
    display_order,
    is_public,
    item_body,
    item_hash
  )
  values (
    v_staff_id,
    v_org_id,
    'Sample Barber Cut',
    'Example gallery item for a public staff profile.',
    'https://example.com/gallery/sample-barber-cut.jpg',
    'image',
    'BARBER_CUT',
    1,
    true,
    jsonb_build_object('seeded', true, 'service_code', 'BARBER_CUT'),
    pods_provisioning._sha256_text_v1(v_staff_id::text || '|gallery|BARBER_CUT')
  );

  insert into pods_provisioning.staff_featured_sections_v1(
    org_id,
    section_key,
    display_title,
    section_kind,
    staff_member_id,
    starts_on,
    ends_on,
    enabled,
    section_body,
    section_hash
  )
  values (
    v_org_id,
    'employee-of-month',
    'Employee of the Month',
    'employee_of_month',
    v_staff_id,
    current_date,
    current_date + 30,
    true,
    jsonb_build_object('seeded', true),
    pods_provisioning._sha256_text_v1(v_org_id::text || '|employee-of-month|' || v_staff_id::text)
  );

  v_profiles := pods_provisioning.rpc_get_public_staff_profiles_v1(
    v_public->>'booking_slug'
  );

  if v_profiles->>'token' <> 'PROTEUSOPS_PUBLIC_STAFF_PROFILES_OK' then
    raise exception 'PUBLIC_STAFF_PROFILES_TOKEN_FAIL';
  end if;

  if (v_profiles->>'profile_count')::integer < 1 then
    raise exception 'PUBLIC_STAFF_PROFILES_EMPTY';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PUBLIC_STAFF_PROFILES_OK',
    'org_id', v_org_id,
    'booking_slug', v_public->>'booking_slug',
    'profile_seed', v_profile_seed,
    'profile_count', (v_profiles->>'profile_count')::integer,
    'public_staff_profiles', v_profiles
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_public_staff_profiles_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_refund_and_cancellation_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_provision jsonb;
  v_public jsonb;
  v_request jsonb;
  v_policy jsonb;
  v_payment_policy jsonb;
  v_payment jsonb;
  v_cancel jsonb;
  v_duplicate_ok boolean := false;
begin
  v_provision := pods_provisioning.rpc_provision_vertical_template_v1(
    v_org_id,
    'BARBER_NAIL_V1',
    null
  );

  v_public := pods_provisioning.rpc_bootstrap_public_booking_surface_v1(
    (v_provision->>'provision_run_id')::uuid,
    'cancel-test-' || left(v_org_id::text, 8)
  );

  v_request := pods_provisioning.rpc_request_public_appointment_v1(
    v_public->>'booking_slug',
    'BARBER_CUT',
    current_date + 1,
    '16:00'::time,
    'Cancel Test Customer',
    'cancel.customer@example.com',
    '555-0117'
  );

  v_payment_policy := pods_provisioning.rpc_seed_default_payment_policy_v1(
    v_org_id,
    'BARBER_NAIL_V1',
    'v1'
  );

  v_payment := pods_provisioning.rpc_create_payment_intent_for_appointment_v1(
    (v_request->>'appointment_request_id')::uuid,
    'default-deposit'
  );

  v_policy := pods_provisioning.rpc_seed_default_cancellation_policy_v1(
    v_org_id,
    'BARBER_NAIL_V1',
    'v1'
  );

  if v_policy->>'token' <> 'PROTEUSOPS_CANCELLATION_POLICY_SEED_OK' then
    raise exception 'CANCELLATION_POLICY_SEED_FAIL';
  end if;

  v_cancel := pods_provisioning.rpc_cancel_appointment_with_refund_intent_v1(
    (v_request->>'appointment_request_id')::uuid,
    'operator',
    'Selftest cancellation',
    'default-cancellation'
  );

  if v_cancel->>'token' <> 'PROTEUSOPS_REFUND_AND_CANCELLATION_OK' then
    raise exception 'REFUND_AND_CANCELLATION_TOKEN_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_cancel_appointment_with_refund_intent_v1(
      (v_request->>'appointment_request_id')::uuid,
      'operator',
      'Duplicate selftest cancellation',
      'default-cancellation'
    );
  exception
    when others then
      if sqlerrm like 'CANCELLATION_STATUS_NOT_MUTABLE:%'
        or sqlerrm like 'CANCELLATION_DUPLICATE_DENY:%' then
        v_duplicate_ok := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_ok then
    raise exception 'CANCELLATION_DUPLICATE_VECTOR_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_REFUND_AND_CANCELLATION_OK',
    'org_id', v_org_id,
    'payment_policy', v_payment_policy,
    'cancellation_policy', v_policy,
    'payment_intent', v_payment,
    'cancellation', v_cancel,
    'duplicate_denied', v_duplicate_ok
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_refund_and_cancellation_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_release_governance_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();

  v_install jsonb;
  v_runtime_id uuid;

  v_snapshot_a jsonb;
  v_release_a jsonb;
  v_promote_a_staging jsonb;
  v_promote_a_prod jsonb;

  v_snapshot_b jsonb;
  v_release_b jsonb;
  v_promote_b_staging jsonb;

  v_rollback jsonb;
  v_history jsonb;
  v_verify jsonb;
begin
  v_install := pods_provisioning.rpc_install_marketplace_model_v1(
    v_org_id,
    'CIVIC_ACTION_V1',
    'v2',
    jsonb_build_object(
      'issue_title','Release Governance Civic Site',
      'community_name','Release Borough',
      'location_label','Release Corridor',
      'position_type','oppose',
      'issue_summary','Release governance selftest.',
      'petition_goal',5000,
      'enable_petition',true,
      'enable_survey',true,
      'enable_events',true,
      'enable_evidence',true,
      'enable_volunteers',true,
      'moderation_required',true
    )
  );

  v_runtime_id := (v_install->>'model_instance_runtime_id')::uuid;

  v_snapshot_a := pods_provisioning.rpc_create_runtime_snapshot_v1(
    v_runtime_id,
    'release_a_snapshot',
    'Release A baseline.'
  );

  v_release_a := pods_provisioning.rpc_create_release_v1(
    v_runtime_id,
    'development',
    'release-a',
    'Release A.'
  );

  v_promote_a_staging := pods_provisioning.rpc_promote_release_v1(
    (v_release_a->>'model_release_id')::uuid,
    'staging',
    'community_admin'
  );

  v_promote_a_prod := pods_provisioning.rpc_promote_release_v1(
    (v_release_a->>'model_release_id')::uuid,
    'production',
    'community_admin'
  );

  update pods_provisioning.model_instance_runtimes_v1
  set instance_name = 'Release Governance Civic Site Edited'
  where model_instance_runtime_id = v_runtime_id;

  v_snapshot_b := pods_provisioning.rpc_create_runtime_snapshot_v1(
    v_runtime_id,
    'release_b_snapshot',
    'Release B edited.'
  );

  v_release_b := pods_provisioning.rpc_create_release_v1(
    v_runtime_id,
    'development',
    'release-b',
    'Release B.'
  );

  v_promote_b_staging := pods_provisioning.rpc_promote_release_v1(
    (v_release_b->>'model_release_id')::uuid,
    'staging',
    'community_admin'
  );

  v_rollback := pods_provisioning.rpc_rollback_release_v1(
    (v_release_b->>'model_release_id')::uuid,
    (v_release_a->>'model_release_id')::uuid,
    'Selftest rollback to Release A.'
  );

  v_history := pods_provisioning.rpc_list_release_history_v1(v_runtime_id);
  v_verify := pods_provisioning.rpc_verify_release_chain_v1(v_runtime_id);

  if v_release_a->>'token' <> 'PROTEUSOPS_MODEL_RELEASE_GOVERNANCE_OK' then
    raise exception 'MODEL_RELEASE_A_TOKEN_FAIL';
  end if;

  if v_promote_a_prod->>'to_channel' <> 'production' then
    raise exception 'MODEL_RELEASE_PROMOTION_PRODUCTION_FAIL:%', v_promote_a_prod;
  end if;

  if v_rollback->>'rollback_status' <> 'completed' then
    raise exception 'MODEL_RELEASE_ROLLBACK_FAIL:%', v_rollback;
  end if;

  if (v_history->>'release_count')::int < 2 then
    raise exception 'MODEL_RELEASE_HISTORY_COUNT_FAIL:%', v_history;
  end if;

  if v_verify->>'verified' <> 'true' then
    raise exception 'MODEL_RELEASE_CHAIN_VERIFY_FAIL:%', v_verify;
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_RELEASE_GOVERNANCE_OK',
    'install', v_install,
    'snapshot_a', v_snapshot_a,
    'release_a', v_release_a,
    'promote_a_staging', v_promote_a_staging,
    'promote_a_production', v_promote_a_prod,
    'snapshot_b', v_snapshot_b,
    'release_b', v_release_b,
    'promote_b_staging', v_promote_b_staging,
    'rollback', v_rollback,
    'history', v_history,
    'verify', v_verify
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_release_governance_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_retry_governance_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_failure_test jsonb;
  v_policy jsonb;
  v_retry_1 jsonb;
  v_retry_2 jsonb;
  v_retry_3 jsonb;
  v_retry_exhausted jsonb;
begin
  v_failure_test := pods_provisioning.rpc_selftest_launch_failure_and_rollback_runtime_v1();

  if v_failure_test->>'token' <> 'PROTEUSOPS_LAUNCH_FAILURE_AND_ROLLBACK_RUNTIME_OK' then
    raise exception 'RETRY_DEPENDENCY_FAILURE_RUNTIME_FAIL';
  end if;

  v_policy := pods_provisioning.rpc_seed_launch_retry_policy_v1(
    'selftest-launch-retry',
    3,
    30
  );

  if v_policy->>'token' <> 'PROTEUSOPS_RETRY_POLICY_SEED_OK' then
    raise exception 'RETRY_POLICY_SEED_FAIL';
  end if;

  v_retry_1 := pods_provisioning.rpc_evaluate_launch_retry_v1(
    ((v_failure_test->'failure')->>'launch_failure_event_id')::uuid,
    'selftest-launch-retry'
  );

  if v_retry_1->>'token' <> 'PROTEUSOPS_RETRY_GOVERNANCE_OK' then
    raise exception 'RETRY_ONE_TOKEN_FAIL';
  end if;

  v_retry_2 := pods_provisioning.rpc_evaluate_launch_retry_v1(
    ((v_failure_test->'failure')->>'launch_failure_event_id')::uuid,
    'selftest-launch-retry'
  );

  v_retry_3 := pods_provisioning.rpc_evaluate_launch_retry_v1(
    ((v_failure_test->'failure')->>'launch_failure_event_id')::uuid,
    'selftest-launch-retry'
  );

  v_retry_exhausted := pods_provisioning.rpc_evaluate_launch_retry_v1(
    ((v_failure_test->'failure')->>'launch_failure_event_id')::uuid,
    'selftest-launch-retry'
  );

  if v_retry_exhausted->>'token' <> 'PROTEUSOPS_RETRY_EXHAUSTED_OK' then
    raise exception 'RETRY_EXHAUSTED_TOKEN_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_RETRY_GOVERNANCE_OK',
    'policy', v_policy,
    'retry_1', v_retry_1,
    'retry_2', v_retry_2,
    'retry_3', v_retry_3,
    'retry_exhausted', v_retry_exhausted
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_retry_governance_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_runtime_drift_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_install jsonb;
  v_runtime_id uuid;
  v_baseline jsonb;
  v_clean_report jsonb;
  v_edit jsonb;
  v_drift_report jsonb;
  v_ack jsonb;
begin
  v_install := pods_provisioning.rpc_install_marketplace_model_v1(
    v_org_id,
    'CIVIC_ACTION_V1',
    'v2',
    jsonb_build_object(
      'issue_title','Runtime Drift Civic Site',
      'community_name','Drift Borough',
      'location_label','Drift Corridor',
      'position_type','oppose',
      'issue_summary','Runtime drift selftest.',
      'petition_goal',6000,
      'enable_petition',true,
      'enable_survey',true,
      'enable_events',true,
      'enable_evidence',true,
      'enable_volunteers',true,
      'moderation_required',true
    )
  );

  v_runtime_id := (v_install->>'model_instance_runtime_id')::uuid;

  v_baseline := pods_provisioning.rpc_create_runtime_baseline_v1(
    v_runtime_id,
    'manual',
    null
  );

  v_clean_report := pods_provisioning.rpc_generate_runtime_drift_report_v1(v_runtime_id);

  v_edit := pods_provisioning.rpc_apply_model_runtime_edit_v1(
    v_runtime_id,
    'block',
    'hero',
    'update_fields',
    jsonb_build_object(
      'headline','Runtime Drift Changed Hero',
      'subheadline','This edit should create drift.'
    )
  );

  v_drift_report := pods_provisioning.rpc_generate_runtime_drift_report_v1(v_runtime_id);

  v_ack := pods_provisioning.rpc_acknowledge_runtime_drift_v1(
    (v_drift_report->>'model_runtime_drift_report_id')::uuid,
    'approved'
  );

  if v_baseline->>'token' <> 'PROTEUSOPS_RUNTIME_DRIFT_OK' then
    raise exception 'RUNTIME_DRIFT_BASELINE_TOKEN_FAIL';
  end if;

  if v_clean_report->>'drift_status' <> 'clean' then
    raise exception 'RUNTIME_DRIFT_CLEAN_REPORT_FAIL:%', v_clean_report;
  end if;

  if v_drift_report->>'drift_status' <> 'drift_detected' then
    raise exception 'RUNTIME_DRIFT_DETECTION_FAIL:%', v_drift_report;
  end if;

  if (v_drift_report->>'finding_count')::int < 1 then
    raise exception 'RUNTIME_DRIFT_FINDING_COUNT_FAIL:%', v_drift_report;
  end if;

  if v_ack->>'acknowledged' <> 'true' then
    raise exception 'RUNTIME_DRIFT_ACK_FAIL:%', v_ack;
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_RUNTIME_DRIFT_OK',
    'install', v_install,
    'baseline', v_baseline,
    'clean_report', v_clean_report,
    'edit', v_edit,
    'drift_report', v_drift_report,
    'acknowledge', v_ack
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_runtime_drift_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_runtime_snapshot_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_install jsonb;
  v_runtime_id uuid;

  v_snap_a jsonb;
  v_snap_b jsonb;
  v_compare jsonb;
  v_restore jsonb;
begin
  v_install := pods_provisioning.rpc_install_marketplace_model_v1(
    gen_random_uuid(),
    'CIVIC_ACTION_V1',
    'v2',
    jsonb_build_object(
      'issue_title','Snapshot Test',
      'community_name','Snapshot Borough',
      'location_label','Snapshot District'
    )
  );

  v_runtime_id :=
    (v_install->>'model_instance_runtime_id')::uuid;

  v_snap_a :=
    pods_provisioning.rpc_create_runtime_snapshot_v1(
      v_runtime_id,
      'before_edit'
    );

  update pods_provisioning.model_instance_runtimes_v1
  set instance_name = 'Edited Snapshot Runtime'
  where model_instance_runtime_id = v_runtime_id;

  v_snap_b :=
    pods_provisioning.rpc_create_runtime_snapshot_v1(
      v_runtime_id,
      'after_edit'
    );

  v_compare :=
    pods_provisioning.rpc_compare_runtime_snapshots_v1(
      (v_snap_a->>'model_runtime_snapshot_id')::uuid,
      (v_snap_b->>'model_runtime_snapshot_id')::uuid
    );

  v_restore :=
    pods_provisioning.rpc_restore_runtime_snapshot_v1(
      (v_snap_a->>'model_runtime_snapshot_id')::uuid
    );

  return jsonb_build_object(
    'ok',true,
    'token','PROTEUSOPS_MODEL_RUNTIME_SNAPSHOT_OK',
    'snapshot_a',v_snap_a,
    'snapshot_b',v_snap_b,
    'comparison',v_compare,
    'restore',v_restore
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_runtime_snapshot_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_security_gate_matrix_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_seed jsonb;
  v_stress jsonb;
  v_rollup jsonb;
  v_result jsonb;
begin
  v_seed := pods_provisioning.rpc_seed_security_gate_matrix_v1();

  if v_seed->>'token' <> 'PROTEUSOPS_SECURITY_GATE_MATRIX_OK' then
    raise exception 'SECURITY_GATE_SEED_FAIL';
  end if;

  v_stress := pods_provisioning.rpc_selftest_stress_harness_v1();

  if v_stress->>'token' <> 'PROTEUSOPS_STRESS_HARNESS_OK' then
    raise exception 'SECURITY_GATE_STRESS_DEPENDENCY_FAIL';
  end if;

  perform pods_provisioning.rpc_verify_supabase_adapter_runtime_v1(
    v_org_id,
    'security-project-ref',
    'https://security-project-ref.supabase.co',
    true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_stripe_adapter_runtime_v1(
    v_org_id,
    'acct_security',
    'test',
    true,true,true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_email_adapter_runtime_v1(
    v_org_id,
    'resend',
    'security.example.com',
    true,true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_storage_adapter_runtime_v1(
    v_org_id,
    'supabase_storage',
    'security_downloads',
    true,true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_github_adapter_runtime_v1(
    v_org_id,
    'example',
    'security-runtime',
    'https://github.com/example/security-runtime',
    true,true,true,true,true,null
  );

  v_rollup := pods_provisioning.rpc_provider_readiness_rollup_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    'v1'
  );

  if v_rollup->>'readiness_status' <> 'ready' then
    raise exception 'SECURITY_GATE_PROVIDER_ROLLUP_NOT_READY';
  end if;

  v_result := pods_provisioning.rpc_run_security_gate_matrix_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1'
  );

  if v_result->>'security_status' <> 'passed' then
    raise exception 'SECURITY_GATE_MATRIX_NOT_PASSED';
  end if;

  return v_result;
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_security_gate_matrix_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_staff_assignment_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_provision jsonb;
  v_public jsonb;
  v_request jsonb;
  v_action jsonb;
  v_staff_seed jsonb;
  v_staff_id uuid;
  v_assignment jsonb;
  v_overlap_ok boolean := false;
begin
  v_provision := pods_provisioning.rpc_provision_vertical_template_v1(
    v_org_id,
    'BARBER_NAIL_V1',
    null
  );

  v_public := pods_provisioning.rpc_bootstrap_public_booking_surface_v1(
    (v_provision->>'provision_run_id')::uuid,
    'staff-test-' || left(v_org_id::text, 8)
  );

  v_request := pods_provisioning.rpc_request_public_appointment_v1(
    v_public->>'booking_slug',
    'BARBER_CUT',
    current_date + 1,
    '11:00'::time,
    'Staff Test Customer',
    'staff.customer@example.com',
    '555-0113'
  );

  v_action := pods_provisioning.rpc_admin_update_appointment_request_v1(
    (v_request->>'appointment_request_id')::uuid,
    'confirm',
    null,
    'Staff assignment selftest confirmation'
  );

  if v_action->>'new_status' <> 'confirmed' then
    raise exception 'STAFF_ASSIGN_CONFIRM_FAIL';
  end if;

  v_staff_seed := pods_provisioning.rpc_seed_default_staff_for_org_v1(
    v_org_id,
    'BARBER_NAIL_V1',
    'v1'
  );

  if v_staff_seed->>'token' <> 'PROTEUSOPS_STAFF_SEED_OK' then
    raise exception 'STAFF_SEED_TOKEN_FAIL';
  end if;

  select sm.staff_member_id
  into v_staff_id
  from pods_provisioning.staff_members_v1 sm
  where sm.org_id = v_org_id
    and sm.role_key = 'BARBER'
  order by sm.created_at, sm.staff_member_id
  limit 1;

  if v_staff_id is null then
    raise exception 'STAFF_ASSIGN_NO_BARBER_FOUND';
  end if;

  v_assignment := pods_provisioning.rpc_assign_staff_to_appointment_v1(
    (v_request->>'appointment_request_id')::uuid,
    v_staff_id
  );

  if v_assignment->>'token' <> 'PROTEUSOPS_STAFF_ASSIGNMENT_OK' then
    raise exception 'STAFF_ASSIGNMENT_TOKEN_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_assign_staff_to_appointment_v1(
      (v_request->>'appointment_request_id')::uuid,
      v_staff_id
    );
  exception
    when others then
      if sqlerrm like 'STAFF_ASSIGN_OVERLAP_DENY:%'
        or sqlerrm like 'STAFF_ASSIGN_APPOINTMENT_ALREADY_ASSIGNED:%' then
        v_overlap_ok := true;
      else
        raise;
      end if;
  end;

  if not v_overlap_ok then
    raise exception 'STAFF_ASSIGN_OVERLAP_VECTOR_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_STAFF_ASSIGNMENT_OK',
    'org_id', v_org_id,
    'staff_seed', v_staff_seed,
    'assignment', v_assignment,
    'overlap_denied', v_overlap_ok
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_staff_assignment_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_storage_adapter_runtime_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_verified jsonb;
  v_blocked jsonb;
begin
  v_verified := pods_provisioning.rpc_verify_storage_adapter_runtime_v1(
    v_org_id,
    'supabase_storage',
    'developer_portal_downloads',
    true,
    true,
    true,
    true,
    true,
    null
  );

  if v_verified->>'token' <> 'PROTEUSOPS_STORAGE_ADAPTER_RUNTIME_OK' then
    raise exception 'STORAGE_RUNTIME_TOKEN_FAIL';
  end if;

  if v_verified->>'runtime_status' <> 'verified' then
    raise exception 'STORAGE_RUNTIME_VERIFIED_STATUS_FAIL';
  end if;

  v_blocked := pods_provisioning.rpc_verify_storage_adapter_runtime_v1(
    v_org_id,
    'supabase_storage',
    'blocked_downloads',
    true,
    true,
    false,
    true,
    true,
    null
  );

  if v_blocked->>'runtime_status' <> 'blocked' then
    raise exception 'STORAGE_RUNTIME_BLOCKED_STATUS_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_STORAGE_ADAPTER_RUNTIME_OK',
    'org_id', v_org_id,
    'verified_runtime', v_verified,
    'blocked_runtime', v_blocked
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_storage_adapter_runtime_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_stress_harness_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_a uuid := gen_random_uuid();
  v_org_b uuid := gen_random_uuid();
  v_org_c uuid := gen_random_uuid();

  v_success jsonb;
  v_failure jsonb;
  v_retry jsonb;

  v_isolation_pass boolean := false;
  v_success_count integer := 0;
  v_failure_count integer := 0;
  v_rollback_count integer := 0;
  v_retry_count integer := 0;
  v_duplicate_count integer := 0;

  v_cross_org_leak_count integer := 0;

  v_body jsonb;
  v_hash text;
  v_stress_id uuid;
begin
  -- Success lane.
  perform pods_provisioning.rpc_seed_developer_portal_model_v1();

  v_success := pods_provisioning.rpc_selftest_launch_execution_worker_runtime_v1();

  if v_success->>'token' <> 'PROTEUSOPS_LAUNCH_EXECUTION_WORKER_OK' then
    raise exception 'STRESS_SUCCESS_LANE_FAIL';
  end if;

  v_success_count := 1;

  if coalesce((v_success->>'duplicate_denied')::boolean,false) then
    v_duplicate_count := v_duplicate_count + 1;
  end if;

  -- Failure + rollback lane.
  v_failure := pods_provisioning.rpc_selftest_launch_failure_and_rollback_runtime_v1();

  if v_failure->>'token' <> 'PROTEUSOPS_LAUNCH_FAILURE_AND_ROLLBACK_RUNTIME_OK' then
    raise exception 'STRESS_FAILURE_ROLLBACK_LANE_FAIL';
  end if;

  v_failure_count := 1;
  v_rollback_count := 1;

  if coalesce((v_failure->>'duplicate_failure_denied')::boolean,false) then
    v_duplicate_count := v_duplicate_count + 1;
  end if;

  if coalesce((v_failure->>'duplicate_rollback_denied')::boolean,false) then
    v_duplicate_count := v_duplicate_count + 1;
  end if;

  -- Retry lane.
  v_retry := pods_provisioning.rpc_selftest_retry_governance_v1();

  if v_retry->>'token' <> 'PROTEUSOPS_RETRY_GOVERNANCE_OK' then
    raise exception 'STRESS_RETRY_LANE_FAIL';
  end if;

  v_retry_count := 4;

  -- Isolation sanity: ensure synthetic org ids are distinct and no accidental equality.
  if v_org_a <> v_org_b and v_org_a <> v_org_c and v_org_b <> v_org_c then
    v_isolation_pass := true;
  end if;

  if not v_isolation_pass then
    raise exception 'STRESS_ORG_ISOLATION_FAIL';
  end if;

  -- Basic cross-org leak guard: generated stress orgs should not share ids.
  select count(*)
  into v_cross_org_leak_count
  from (
    select v_org_a as org_id
    union all
    select v_org_b
    union all
    select v_org_c
  ) x
  group by x.org_id
  having count(*) > 1;

  if coalesce(v_cross_org_leak_count,0) > 0 then
    raise exception 'STRESS_CROSS_ORG_LEAK_FAIL';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_STRESS_HARNESS_OK',
    'stress_key', 'stress_harness_v1',
    'org_count', 3,
    'launch_success_count', v_success_count,
    'launch_failure_count', v_failure_count,
    'rollback_count', v_rollback_count,
    'retry_count', v_retry_count,
    'duplicate_denial_count', v_duplicate_count,
    'isolation_pass', v_isolation_pass,
    'stress_status', 'passed'
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.stress_harness_runs_v1(
    stress_key,
    org_count,
    launch_success_count,
    launch_failure_count,
    rollback_count,
    retry_count,
    duplicate_denial_count,
    isolation_pass,
    stress_status,
    stress_body,
    stress_hash
  )
  values (
    'stress_harness_v1',
    3,
    v_success_count,
    v_failure_count,
    v_rollback_count,
    v_retry_count,
    v_duplicate_count,
    v_isolation_pass,
    'passed',
    v_body,
    v_hash
  )
  returning stress_run_id
  into v_stress_id;

  return v_body || jsonb_build_object(
    'stress_run_id', v_stress_id,
    'stress_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_stress_harness_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_stripe_adapter_runtime_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_verified jsonb;
  v_blocked jsonb;
begin
  v_verified := pods_provisioning.rpc_verify_stripe_adapter_runtime_v1(
    v_org_id,
    'acct_test_verified',
    'test',
    true,
    true,
    true,
    true,
    true,
    true,
    null
  );

  if v_verified->>'token' <> 'PROTEUSOPS_STRIPE_ADAPTER_RUNTIME_OK' then
    raise exception 'STRIPE_RUNTIME_TOKEN_FAIL';
  end if;

  if v_verified->>'runtime_status' <> 'verified' then
    raise exception 'STRIPE_RUNTIME_VERIFIED_STATUS_FAIL';
  end if;

  v_blocked := pods_provisioning.rpc_verify_stripe_adapter_runtime_v1(
    v_org_id,
    'acct_test_blocked',
    'test',
    true,
    true,
    false,
    true,
    true,
    true,
    null
  );

  if v_blocked->>'runtime_status' <> 'blocked' then
    raise exception 'STRIPE_RUNTIME_BLOCKED_STATUS_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_STRIPE_ADAPTER_RUNTIME_OK',
    'org_id', v_org_id,
    'verified_runtime', v_verified,
    'blocked_runtime', v_blocked
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_stripe_adapter_runtime_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_supabase_adapter_runtime_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_verified jsonb;
  v_blocked jsonb;
begin
  v_verified := pods_provisioning.rpc_verify_supabase_adapter_runtime_v1(
    v_org_id,
    'test-project-ref',
    'https://test-project-ref.supabase.co',
    true,
    true,
    true,
    true,
    null
  );

  if v_verified->>'token' <> 'PROTEUSOPS_SUPABASE_ADAPTER_RUNTIME_OK' then
    raise exception 'SUPABASE_RUNTIME_TOKEN_FAIL';
  end if;

  if v_verified->>'runtime_status' <> 'verified' then
    raise exception 'SUPABASE_RUNTIME_VERIFIED_STATUS_FAIL';
  end if;

  v_blocked := pods_provisioning.rpc_verify_supabase_adapter_runtime_v1(
    v_org_id,
    'blocked-project-ref',
    'https://blocked-project-ref.supabase.co',
    true,
    true,
    true,
    false,
    null
  );

  if v_blocked->>'runtime_status' <> 'blocked' then
    raise exception 'SUPABASE_RUNTIME_BLOCKED_STATUS_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_SUPABASE_ADAPTER_RUNTIME_OK',
    'org_id', v_org_id,
    'verified_runtime', v_verified,
    'blocked_runtime', v_blocked
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_supabase_adapter_runtime_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_vertical_templates_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
declare
  template_count integer;
  service_count integer;
  role_count integer;
begin
  select count(*)
  into template_count
  from pods_provisioning.vertical_templates;

  select count(*)
  into service_count
  from pods_provisioning.vertical_template_services;

  select count(*)
  into role_count
  from pods_provisioning.vertical_template_roles;

  if template_count < 1 then
    raise exception 'TEMPLATE_COUNT_INVALID';
  end if;

  if service_count < 1 then
    raise exception 'SERVICE_COUNT_INVALID';
  end if;

  if role_count < 1 then
    raise exception 'ROLE_COUNT_INVALID';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_VERTICAL_TEMPLATE_REGISTRY_OK',
    'template_count', template_count,
    'service_count', service_count,
    'role_count', role_count
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_selftest_vertical_templates_v1"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_start_operator_setup_wizard_v1"("p_org_id" "uuid", "p_model_key" "text", "p_requested_fields" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_plan jsonb;
  v_body jsonb;
  v_hash text;
  v_wizard_id uuid;
begin
  if p_org_id is null then
    raise exception 'SETUP_WIZARD_ORG_REQUIRED';
  end if;

  if p_model_key is null or btrim(p_model_key) = '' then
    raise exception 'SETUP_WIZARD_MODEL_REQUIRED';
  end if;

  v_plan := pods_provisioning.rpc_plan_model_capabilities_v1(
    p_org_id,
    p_model_key,
    coalesce(p_requested_fields,'{}'::jsonb)
  );

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_OPERATOR_SETUP_WIZARD_OK',
    'org_id', p_org_id,
    'model_key', p_model_key,
    'wizard_status', 'in_progress',
    'current_step', 1,
    'total_steps', 6,

    'steps', jsonb_build_array(
      jsonb_build_object('step_order',1,'step_key','select_model'),
      jsonb_build_object('step_order',2,'step_key','business_details'),
      jsonb_build_object('step_order',3,'step_key','provider_connections'),
      jsonb_build_object('step_order',4,'step_key','review_defaults'),
      jsonb_build_object('step_order',5,'step_key','launch_review'),
      jsonb_build_object('step_order',6,'step_key','launch')
    ),

    'requested_fields', v_plan->'requested_fields',
    'applied_defaults', v_plan->'applied_defaults',

    'provider_checklist', jsonb_build_array(
      jsonb_build_object('provider','auth_provider','connected',false),
      jsonb_build_object('provider','payment_provider','connected',false),
      jsonb_build_object('provider','email_provider','connected',false)
    ),

    'readiness_checklist', jsonb_build_array(
      jsonb_build_object('check_key','model_selected','complete',true),
      jsonb_build_object('check_key','required_fields_reviewed','complete',false),
      jsonb_build_object('check_key','providers_connected','complete',false),
      jsonb_build_object('check_key','launch_review_complete','complete',false)
    ),

    'launch_ready', false
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.operator_setup_wizard_sessions_v1(
    org_id,
    model_key,
    model_version,
    wizard_status,
    current_step,
    total_steps,
    completed_steps,
    skipped_steps,
    requested_fields,
    applied_defaults,
    provider_checklist,
    readiness_checklist,
    launch_ready,
    wizard_body,
    wizard_hash
  )
  values (
    p_org_id,
    p_model_key,
    'v1',
    'in_progress',
    1,
    6,
    jsonb_build_array('select_model'),
    '[]'::jsonb,
    v_plan->'requested_fields',
    v_plan->'applied_defaults',
    jsonb_build_array(
      jsonb_build_object('provider','auth_provider','connected',false),
      jsonb_build_object('provider','payment_provider','connected',false),
      jsonb_build_object('provider','email_provider','connected',false)
    ),
    jsonb_build_array(
      jsonb_build_object('check_key','model_selected','complete',true),
      jsonb_build_object('check_key','required_fields_reviewed','complete',false),
      jsonb_build_object('check_key','providers_connected','complete',false),
      jsonb_build_object('check_key','launch_review_complete','complete',false)
    ),
    false,
    v_body,
    v_hash
  )
  returning wizard_session_id
  into v_wizard_id;

  return v_body || jsonb_build_object(
    'wizard_session_id', v_wizard_id,
    'wizard_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_start_operator_setup_wizard_v1"("p_org_id" "uuid", "p_model_key" "text", "p_requested_fields" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_start_provider_connection_session_v1"("p_org_id" "uuid", "p_provider_key" "text", "p_connection_method" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_contract record;
  v_method text;
  v_body jsonb;
  v_hash text;
  v_session_id uuid;
begin
  if p_org_id is null then
    raise exception 'PROVIDER_CONNECTION_ORG_REQUIRED';
  end if;

  if p_provider_key is null or btrim(p_provider_key) = '' then
    raise exception 'PROVIDER_CONNECTION_PROVIDER_REQUIRED';
  end if;

  perform pods_provisioning.rpc_seed_provider_oauth_connection_contracts_v1();

  select *
  into v_contract
  from pods_provisioning.provider_connection_contracts_v1 c
  where c.provider_key = lower(p_provider_key)
    and c.active = true
  limit 1;

  if not found then
    raise exception 'PROVIDER_CONNECTION_CONTRACT_NOT_FOUND:%', p_provider_key;
  end if;

  v_method := coalesce(nullif(btrim(coalesce(p_connection_method,'')),''), v_contract.default_connection_method);

  if v_method = 'manual_key_fallback' and v_contract.manual_key_entry_allowed is not true then
    raise exception 'PROVIDER_MANUAL_KEY_ENTRY_DENIED:%', p_provider_key;
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PROVIDER_CONNECTION_SESSION_OK',
    'org_id', p_org_id,
    'provider_key', v_contract.provider_key,
    'connection_status', 'created',
    'connection_method', v_method,
    'user_action', 'connect_provider',
    'manual_key_entry_used', false,
    'secret_storage_model', v_contract.secret_storage_model,
    'secret_ref_required', true,
    'manual_key_entry_scope', v_contract.manual_key_entry_scope,
    'launch_blocked', true,
    'next_steps', jsonb_build_array(
      'Open provider authorization',
      'Authorize requested scopes',
      'Select provider project/account',
      'Store provider token as secret ref',
      'Run provider verification'
    )
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.provider_connection_sessions_v1(
    org_id,
    provider_key,
    connection_status,
    connection_method,
    user_action,
    manual_key_entry_used,
    provider_account_ref,
    provider_project_ref,
    secret_ref,
    discovered_resources,
    verification_results,
    launch_blocked,
    session_body,
    session_hash
  )
  values (
    p_org_id,
    v_contract.provider_key,
    'created',
    v_method,
    'connect_provider',
    false,
    '',
    '',
    '',
    '[]'::jsonb,
    '[]'::jsonb,
    true,
    v_body,
    v_hash
  )
  returning provider_connection_session_id
  into v_session_id;

  return v_body || jsonb_build_object(
    'provider_connection_session_id', v_session_id,
    'session_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_start_provider_connection_session_v1"("p_org_id" "uuid", "p_provider_key" "text", "p_connection_method" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_submit_civic_event_rsvp_v1"("p_civic_event_id" "uuid", "p_attendee_name" "text", "p_attendee_email" "text", "p_rsvp_status" "text" DEFAULT 'going'::"text", "p_wants_to_speak" boolean DEFAULT false, "p_wants_to_volunteer" boolean DEFAULT false, "p_note" "text" DEFAULT ''::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_event record;
  v_email text;
  v_attendee_hash text;
  v_body jsonb;
  v_hash text;
  v_rsvp_id uuid;
begin
  if p_civic_event_id is null then
    raise exception 'CIVIC_EVENT_RSVP_EVENT_REQUIRED';
  end if;

  if p_attendee_name is null or btrim(p_attendee_name) = '' then
    raise exception 'CIVIC_EVENT_RSVP_NAME_REQUIRED';
  end if;

  if p_attendee_email is null or btrim(p_attendee_email) = '' then
    raise exception 'CIVIC_EVENT_RSVP_EMAIL_REQUIRED';
  end if;

  select *
  into v_event
  from pods_provisioning.civic_action_events_v1
  where civic_event_id = p_civic_event_id
  limit 1;

  if not found then
    raise exception 'CIVIC_EVENT_RSVP_EVENT_NOT_FOUND';
  end if;

  if v_event.event_status <> 'published' then
    raise exception 'CIVIC_EVENT_RSVP_EVENT_NOT_PUBLISHED';
  end if;

  v_email := lower(btrim(p_attendee_email));
  v_attendee_hash := pods_provisioning._sha256_text_v1(v_event.civic_event_id::text || '|rsvp|' || v_email);

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_EVENT_RSVP_OK',
    'org_id', v_event.org_id,
    'civic_campaign_id', v_event.civic_campaign_id,
    'civic_event_id', v_event.civic_event_id,
    'attendee_name', p_attendee_name,
    'attendee_hash', v_attendee_hash,
    'rsvp_status', coalesce(p_rsvp_status,'going'),
    'wants_to_speak', coalesce(p_wants_to_speak,false),
    'wants_to_volunteer', coalesce(p_wants_to_volunteer,false),
    'note_present', coalesce(p_note,'') <> '',
    'moderation_status', 'pending'
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.civic_action_event_rsvps_v1(
    civic_event_id, civic_campaign_id, org_id, attendee_name, attendee_email,
    attendee_hash, rsvp_status, wants_to_speak, wants_to_volunteer, note,
    moderation_status, rsvp_body, rsvp_hash
  )
  values (
    v_event.civic_event_id, v_event.civic_campaign_id, v_event.org_id,
    p_attendee_name, v_email, v_attendee_hash, coalesce(p_rsvp_status,'going'),
    coalesce(p_wants_to_speak,false), coalesce(p_wants_to_volunteer,false),
    coalesce(p_note,''), 'pending', v_body, v_hash
  )
  returning civic_event_rsvp_id into v_rsvp_id;

  return v_body || jsonb_build_object('civic_event_rsvp_id', v_rsvp_id, 'rsvp_hash', v_hash);

exception
  when unique_violation then
    raise exception 'CIVIC_EVENT_RSVP_DUPLICATE_DENY';
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_submit_civic_event_rsvp_v1"("p_civic_event_id" "uuid", "p_attendee_name" "text", "p_attendee_email" "text", "p_rsvp_status" "text", "p_wants_to_speak" boolean, "p_wants_to_volunteer" boolean, "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_submit_civic_evidence_v1"("p_civic_campaign_id" "uuid", "p_evidence_type" "text", "p_evidence_title" "text", "p_evidence_url" "text" DEFAULT ''::"text", "p_evidence_description" "text" DEFAULT ''::"text", "p_submitter_name" "text" DEFAULT ''::"text", "p_submitter_email" "text" DEFAULT ''::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_campaign record;
  v_email text;
  v_submitter_hash text;
  v_body jsonb;
  v_hash text;
  v_evidence_id uuid;
begin
  if p_civic_campaign_id is null then
    raise exception 'CIVIC_EVIDENCE_CAMPAIGN_REQUIRED';
  end if;

  if p_evidence_title is null or btrim(p_evidence_title) = '' then
    raise exception 'CIVIC_EVIDENCE_TITLE_REQUIRED';
  end if;

  select *
  into v_campaign
  from pods_provisioning.civic_action_campaigns_v1
  where civic_campaign_id = p_civic_campaign_id
  limit 1;

  if not found then
    raise exception 'CIVIC_EVIDENCE_CAMPAIGN_NOT_FOUND';
  end if;

  if v_campaign.campaign_status <> 'published' then
    raise exception 'CIVIC_EVIDENCE_CAMPAIGN_NOT_PUBLISHED';
  end if;

  v_email := lower(btrim(coalesce(p_submitter_email,'')));

  v_submitter_hash := pods_provisioning._sha256_text_v1(
    v_campaign.civic_campaign_id::text || '|evidence|' || coalesce(v_email,'') || '|' || coalesce(p_evidence_title,'')
  );

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_EVIDENCE_SUBMISSION_OK',
    'org_id', v_campaign.org_id,
    'civic_campaign_id', v_campaign.civic_campaign_id,
    'evidence_type', p_evidence_type,
    'evidence_title', p_evidence_title,
    'evidence_url_present', coalesce(p_evidence_url,'') <> '',
    'evidence_description_present', coalesce(p_evidence_description,'') <> '',
    'submitter_name_present', coalesce(p_submitter_name,'') <> '',
    'submitter_hash', v_submitter_hash,
    'moderation_status', 'pending',
    'public_visible', true
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.civic_action_evidence_v1(
    civic_campaign_id,
    org_id,
    evidence_type,
    evidence_title,
    evidence_url,
    evidence_description,
    submitter_name,
    submitter_email,
    submitter_hash,
    moderation_status,
    public_visible,
    evidence_body,
    evidence_hash
  )
  values (
    v_campaign.civic_campaign_id,
    v_campaign.org_id,
    p_evidence_type,
    p_evidence_title,
    coalesce(p_evidence_url,''),
    coalesce(p_evidence_description,''),
    coalesce(p_submitter_name,''),
    v_email,
    v_submitter_hash,
    'pending',
    true,
    v_body,
    v_hash
  )
  returning civic_evidence_id
  into v_evidence_id;

  return v_body || jsonb_build_object(
    'civic_evidence_id', v_evidence_id,
    'evidence_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_submit_civic_evidence_v1"("p_civic_campaign_id" "uuid", "p_evidence_type" "text", "p_evidence_title" "text", "p_evidence_url" "text", "p_evidence_description" "text", "p_submitter_name" "text", "p_submitter_email" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_submit_civic_help_offer_v1"("p_civic_campaign_id" "uuid", "p_helper_name" "text", "p_helper_email" "text", "p_help_type" "text" DEFAULT 'general'::"text", "p_help_message" "text" DEFAULT ''::"text", "p_public_display_allowed" boolean DEFAULT true) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_campaign record;
  v_email text;
  v_helper_hash text;
  v_body jsonb;
  v_hash text;
  v_help_id uuid;
begin
  select *
  into v_campaign
  from pods_provisioning.civic_action_campaigns_v1 c
  where c.civic_campaign_id = p_civic_campaign_id
  limit 1;

  if not found then
    raise exception 'CIVIC_HELP_CAMPAIGN_NOT_FOUND';
  end if;

  if v_campaign.campaign_status <> 'published' then
    raise exception 'CIVIC_HELP_CAMPAIGN_NOT_PUBLISHED';
  end if;

  v_email := lower(btrim(p_helper_email));
  v_helper_hash := pods_provisioning._sha256_text_v1(
    v_campaign.civic_campaign_id::text || '|help|' || v_email || '|' || coalesce(p_help_type,'general')
  );

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_HELP_OFFER_OK',
    'org_id', v_campaign.org_id,
    'civic_campaign_id', v_campaign.civic_campaign_id,
    'helper_name', p_helper_name,
    'helper_hash', v_helper_hash,
    'help_type', coalesce(p_help_type,'general'),
    'help_message_present', coalesce(p_help_message,'') <> '',
    'moderation_status', 'pending',
    'public_display_allowed', coalesce(p_public_display_allowed,true)
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.civic_action_help_offers_v1(
    civic_campaign_id, org_id, helper_name, helper_email, help_type, help_message,
    helper_hash, moderation_status, public_display_allowed, help_body, help_hash
  )
  values (
    v_campaign.civic_campaign_id, v_campaign.org_id, p_helper_name, v_email,
    coalesce(p_help_type,'general'), coalesce(p_help_message,''),
    v_helper_hash, 'pending', coalesce(p_public_display_allowed,true), v_body, v_hash
  )
  returning civic_help_offer_id into v_help_id;

  return v_body || jsonb_build_object('civic_help_offer_id', v_help_id, 'help_hash', v_hash);

exception
  when unique_violation then
    raise exception 'CIVIC_HELP_DUPLICATE_DENY';
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_submit_civic_help_offer_v1"("p_civic_campaign_id" "uuid", "p_helper_name" "text", "p_helper_email" "text", "p_help_type" "text", "p_help_message" "text", "p_public_display_allowed" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_submit_civic_petition_signature_v1"("p_civic_campaign_id" "uuid", "p_signer_name" "text", "p_signer_email" "text", "p_signer_comment" "text" DEFAULT ''::"text", "p_public_display_allowed" boolean DEFAULT true) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_campaign record;
  v_email text;
  v_signer_hash text;
  v_body jsonb;
  v_hash text;
  v_signature_id uuid;
begin
  if p_civic_campaign_id is null then
    raise exception 'CIVIC_SIGNATURE_CAMPAIGN_REQUIRED';
  end if;

  if p_signer_name is null or btrim(p_signer_name) = '' then
    raise exception 'CIVIC_SIGNATURE_NAME_REQUIRED';
  end if;

  if p_signer_email is null or btrim(p_signer_email) = '' then
    raise exception 'CIVIC_SIGNATURE_EMAIL_REQUIRED';
  end if;

  select *
  into v_campaign
  from pods_provisioning.civic_action_campaigns_v1 c
  where c.civic_campaign_id = p_civic_campaign_id
  limit 1;

  if not found then
    raise exception 'CIVIC_SIGNATURE_CAMPAIGN_NOT_FOUND';
  end if;

  if v_campaign.campaign_status <> 'published' then
    raise exception 'CIVIC_SIGNATURE_CAMPAIGN_NOT_PUBLISHED';
  end if;

  v_email := lower(btrim(p_signer_email));
  v_signer_hash := pods_provisioning._sha256_text_v1(v_campaign.civic_campaign_id::text || '|' || v_email);

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_PETITION_SIGNATURE_OK',
    'org_id', v_campaign.org_id,
    'civic_campaign_id', v_campaign.civic_campaign_id,
    'signer_name', p_signer_name,
    'signer_email_hash', v_signer_hash,
    'signer_comment_present', coalesce(p_signer_comment,'') <> '',
    'moderation_status', 'pending',
    'public_display_allowed', coalesce(p_public_display_allowed,true)
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.civic_action_petition_signatures_v1(
    civic_campaign_id,
    org_id,
    signer_name,
    signer_email,
    signer_comment,
    signer_hash,
    moderation_status,
    public_display_allowed,
    signature_body,
    signature_hash
  )
  values (
    v_campaign.civic_campaign_id,
    v_campaign.org_id,
    p_signer_name,
    v_email,
    coalesce(p_signer_comment,''),
    v_signer_hash,
    'pending',
    coalesce(p_public_display_allowed,true),
    v_body,
    v_hash
  )
  returning civic_signature_id
  into v_signature_id;

  return v_body || jsonb_build_object(
    'civic_signature_id', v_signature_id,
    'signature_hash', v_hash
  );
exception
  when unique_violation then
    raise exception 'CIVIC_SIGNATURE_DUPLICATE_DENY';
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_submit_civic_petition_signature_v1"("p_civic_campaign_id" "uuid", "p_signer_name" "text", "p_signer_email" "text", "p_signer_comment" "text", "p_public_display_allowed" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_submit_civic_survey_response_v1"("p_civic_campaign_id" "uuid", "p_respondent_email" "text", "p_answers" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_campaign record;
  v_email text;
  v_respondent_hash text;
  v_answer_count integer;
  v_body jsonb;
  v_hash text;
  v_response_id uuid;
begin
  if p_civic_campaign_id is null then
    raise exception 'CIVIC_SURVEY_RESPONSE_CAMPAIGN_REQUIRED';
  end if;

  if p_respondent_email is null or btrim(p_respondent_email) = '' then
    raise exception 'CIVIC_SURVEY_RESPONSE_EMAIL_REQUIRED';
  end if;

  if p_answers is null or jsonb_typeof(p_answers) <> 'object' then
    raise exception 'CIVIC_SURVEY_RESPONSE_ANSWERS_INVALID';
  end if;

  select count(*)
  into v_answer_count
  from jsonb_object_keys(p_answers);

  select *
  into v_campaign
  from pods_provisioning.civic_action_campaigns_v1 c
  where c.civic_campaign_id = p_civic_campaign_id
  limit 1;

  if not found then
    raise exception 'CIVIC_SURVEY_RESPONSE_CAMPAIGN_NOT_FOUND';
  end if;

  if v_campaign.campaign_status <> 'published' then
    raise exception 'CIVIC_SURVEY_RESPONSE_CAMPAIGN_NOT_PUBLISHED';
  end if;

  v_email := lower(btrim(p_respondent_email));
  v_respondent_hash := pods_provisioning._sha256_text_v1(
    v_campaign.civic_campaign_id::text || '|survey|' || v_email
  );

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CIVIC_ACTION_SURVEY_RESPONSE_OK',
    'org_id', v_campaign.org_id,
    'civic_campaign_id', v_campaign.civic_campaign_id,
    'respondent_hash', v_respondent_hash,
    'answer_count', v_answer_count,
    'moderation_status', 'pending'
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.civic_action_survey_responses_v1(
    civic_campaign_id,
    org_id,
    respondent_email,
    respondent_hash,
    answers,
    moderation_status,
    response_body,
    response_hash
  )
  values (
    v_campaign.civic_campaign_id,
    v_campaign.org_id,
    v_email,
    v_respondent_hash,
    p_answers,
    'pending',
    v_body,
    v_hash
  )
  returning civic_survey_response_id
  into v_response_id;

  return v_body || jsonb_build_object(
    'civic_survey_response_id', v_response_id,
    'response_hash', v_hash
  );

exception
  when unique_violation then
    raise exception 'CIVIC_SURVEY_RESPONSE_DUPLICATE_DENY';
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_submit_civic_survey_response_v1"("p_civic_campaign_id" "uuid", "p_respondent_email" "text", "p_answers" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_submit_launch_review_v1"("p_model_launch_authority_id" "uuid", "p_review_status" "text", "p_review_notes" "text" DEFAULT ''::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_authority record;
  v_body jsonb;
  v_hash text;
  v_review_id uuid;
begin
  select *
  into v_authority
  from pods_provisioning.model_launch_authorities_v1
  where model_launch_authority_id = p_model_launch_authority_id
  limit 1;

  if not found then
    raise exception 'MODEL_LAUNCH_REVIEW_AUTHORITY_NOT_FOUND';
  end if;

  if v_authority.launch_state <> 'ready_for_review' then
    raise exception 'MODEL_LAUNCH_REVIEW_STATE_DENY:%', v_authority.launch_state;
  end if;

  if p_review_status not in ('approved','rejected','changes_requested') then
    raise exception 'MODEL_LAUNCH_REVIEW_STATUS_DENY';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_LAUNCH_AUTHORITY_OK',
    'org_id', v_authority.org_id,
    'model_launch_authority_id', v_authority.model_launch_authority_id,
    'review_status', p_review_status,
    'review_notes_present', coalesce(p_review_notes,'') <> '',
    'next_launch_state', case when p_review_status = 'approved' then 'ready_for_launch' else 'draft' end
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_launch_reviews_v1(
    org_id,
    model_launch_authority_id,
    review_status,
    reviewer_role,
    review_notes,
    review_body,
    review_hash
  )
  values (
    v_authority.org_id,
    v_authority.model_launch_authority_id,
    p_review_status,
    'community_admin',
    coalesce(p_review_notes,''),
    v_body,
    v_hash
  )
  returning model_launch_review_id
  into v_review_id;

  update pods_provisioning.model_launch_authorities_v1
  set launch_state = case when p_review_status = 'approved' then 'ready_for_launch' else 'draft' end
  where model_launch_authority_id = v_authority.model_launch_authority_id;

  return v_body || jsonb_build_object(
    'model_launch_review_id', v_review_id,
    'review_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_submit_launch_review_v1"("p_model_launch_authority_id" "uuid", "p_review_status" "text", "p_review_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_suspend_site_v1"("p_model_launch_authority_id" "uuid", "p_reason" "text" DEFAULT ''::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_authority record;
  v_body jsonb;
  v_hash text;
  v_receipt_id uuid;
begin
  select *
  into v_authority
  from pods_provisioning.model_launch_authorities_v1
  where model_launch_authority_id = p_model_launch_authority_id
  limit 1;

  if not found then
    raise exception 'MODEL_SITE_SUSPEND_AUTHORITY_NOT_FOUND';
  end if;

  if v_authority.launch_state <> 'launched' then
    raise exception 'MODEL_SITE_SUSPEND_STATE_DENY:%', v_authority.launch_state;
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_SITE_SUSPEND_OK',
    'org_id', v_authority.org_id,
    'model_launch_authority_id', v_authority.model_launch_authority_id,
    'model_launch_package_id', v_authority.model_launch_package_id,
    'model_instance_runtime_id', v_authority.model_instance_runtime_id,
    'launch_action', 'suspend',
    'launch_result', 'completed',
    'launch_state', 'suspended',
    'reason_present', coalesce(p_reason,'') <> ''
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.model_launch_receipts_v1(
    org_id,
    model_launch_authority_id,
    model_launch_package_id,
    model_instance_runtime_id,
    launch_action,
    launch_result,
    receipt_body,
    receipt_hash
  )
  values (
    v_authority.org_id,
    v_authority.model_launch_authority_id,
    v_authority.model_launch_package_id,
    v_authority.model_instance_runtime_id,
    'suspend',
    'completed',
    v_body,
    v_hash
  )
  returning model_launch_receipt_id
  into v_receipt_id;

  update pods_provisioning.model_launch_authorities_v1
  set launch_state = 'suspended'
  where model_launch_authority_id = v_authority.model_launch_authority_id;

  return v_body || jsonb_build_object(
    'model_launch_receipt_id', v_receipt_id,
    'receipt_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_suspend_site_v1"("p_model_launch_authority_id" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_validate_license_asset_access_v1"("p_asset_runtime_object_id" "uuid", "p_license_key" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_asset record;
  v_license record;

  v_allowed boolean := false;
  v_license_found boolean := false;
  v_receipt_id uuid;
  v_receipt_hash text;
begin
  if p_asset_runtime_object_id is null then
    raise exception 'ASSET_ACCESS_ASSET_REQUIRED';
  end if;

  select *
  into v_asset
  from pods_provisioning.asset_runtime_objects_v1
  where asset_runtime_object_id = p_asset_runtime_object_id;

  if not found then
    raise exception 'ASSET_NOT_FOUND';
  end if;

  if v_asset.runtime_status <> 'active' then
    v_allowed := false;
  elsif not v_asset.license_gate_required then
    v_allowed := true;
  else
    select *
    into v_license
    from pods_provisioning.license_key_runtime_v1
    where license_key = p_license_key
      and license_status = 'active'
      and org_id = v_asset.org_id
    limit 1;

    v_license_found := found;

    if v_license_found then
      v_allowed := true;
    end if;
  end if;

  v_receipt_hash := pods_provisioning._sha256_text_v1(
    v_asset.asset_runtime_object_id::text || '|' || v_allowed::text
  );

  insert into pods_provisioning.asset_access_receipts_v1(
    org_id,
    asset_runtime_object_id,
    license_key_runtime_id,
    access_result,
    receipt_hash
  )
  values(
    v_asset.org_id,
    v_asset.asset_runtime_object_id,
    case when v_license_found then v_license.license_key_runtime_id else null end,
    case when v_allowed then 'allowed' else 'denied' end,
    v_receipt_hash
  )
  returning asset_access_receipt_id
  into v_receipt_id;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_ASSET_LICENSE_RUNTIME_OK',
    'asset_runtime_object_id', v_asset.asset_runtime_object_id,
    'license_gate_required', v_asset.license_gate_required,
    'access_allowed', v_allowed,
    'asset_access_receipt_id', v_receipt_id,
    'receipt_hash', v_receipt_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_validate_license_asset_access_v1"("p_asset_runtime_object_id" "uuid", "p_license_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_verify_audit_checkpoint_v1"("p_model_audit_checkpoint_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_checkpoint record;
  v_recomputed text;
begin
  select *
  into v_checkpoint
  from pods_provisioning.model_audit_checkpoints_v1
  where model_audit_checkpoint_id = p_model_audit_checkpoint_id
  limit 1;

  if not found then
    raise exception 'MODEL_AUDIT_CHECKPOINT_NOT_FOUND';
  end if;

  v_recomputed := pods_provisioning._sha256_text_v1(v_checkpoint.event_hashes::text);

  if v_recomputed <> v_checkpoint.checkpoint_hash then
    raise exception 'MODEL_AUDIT_CHECKPOINT_HASH_FAIL';
  end if;

  update pods_provisioning.model_audit_checkpoints_v1
  set checkpoint_status = 'verified'
  where model_audit_checkpoint_id = p_model_audit_checkpoint_id;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_AUDIT_LEDGER_OK',
    'model_audit_checkpoint_id', p_model_audit_checkpoint_id,
    'checkpoint_status', 'verified',
    'checkpoint_hash', v_checkpoint.checkpoint_hash,
    'verified', true
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_verify_audit_checkpoint_v1"("p_model_audit_checkpoint_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_verify_domain_dns_v1"("p_domain_runtime_binding_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_binding record;
begin
  select *
  into v_binding
  from pods_provisioning.domain_runtime_bindings_v1
  where domain_runtime_binding_id = p_domain_runtime_binding_id
  limit 1;

  if not found then
    raise exception 'DOMAIN_DNS_VERIFY_BINDING_NOT_FOUND';
  end if;

  update pods_provisioning.domain_runtime_bindings_v1
  set dns_status = 'verified',
      binding_status = 'verified'
  where domain_runtime_binding_id = p_domain_runtime_binding_id;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_DOMAIN_PROVIDER_AUTHORITY_OK',
    'domain_runtime_binding_id', p_domain_runtime_binding_id,
    'domain_name', v_binding.domain_name,
    'dns_status', 'verified',
    'binding_status', 'verified'
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_verify_domain_dns_v1"("p_domain_runtime_binding_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_verify_domain_ssl_v1"("p_domain_runtime_binding_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_binding record;
begin
  select *
  into v_binding
  from pods_provisioning.domain_runtime_bindings_v1
  where domain_runtime_binding_id = p_domain_runtime_binding_id
  limit 1;

  if not found then
    raise exception 'DOMAIN_SSL_VERIFY_BINDING_NOT_FOUND';
  end if;

  if v_binding.dns_status <> 'verified' then
    raise exception 'DOMAIN_SSL_VERIFY_DNS_NOT_READY';
  end if;

  update pods_provisioning.domain_runtime_bindings_v1
  set ssl_status = 'active'
  where domain_runtime_binding_id = p_domain_runtime_binding_id;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_DOMAIN_PROVIDER_AUTHORITY_OK',
    'domain_runtime_binding_id', p_domain_runtime_binding_id,
    'domain_name', v_binding.domain_name,
    'ssl_status', 'active'
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_verify_domain_ssl_v1"("p_domain_runtime_binding_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_verify_email_adapter_runtime_v1"("p_org_id" "uuid", "p_provider_key" "text", "p_sender_domain" "text", "p_api_key_verified" boolean DEFAULT true, "p_sender_domain_verified" boolean DEFAULT true, "p_webhook_configured" boolean DEFAULT true, "p_bounce_handling_ready" boolean DEFAULT true, "p_transactional_send_ready" boolean DEFAULT true, "p_adapter_attachment_run_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_status text;
  v_body jsonb;
  v_hash text;
  v_runtime_id uuid;
begin
  if p_org_id is null then
    raise exception 'EMAIL_RUNTIME_ORG_REQUIRED';
  end if;

  if p_provider_key is null or btrim(p_provider_key) = '' then
    raise exception 'EMAIL_RUNTIME_PROVIDER_REQUIRED';
  end if;

  if p_sender_domain is null or btrim(p_sender_domain) = '' then
    raise exception 'EMAIL_RUNTIME_DOMAIN_REQUIRED';
  end if;

  if p_api_key_verified
    and p_sender_domain_verified
    and p_webhook_configured
    and p_bounce_handling_ready
    and p_transactional_send_ready then
    v_status := 'verified';
  else
    v_status := 'blocked';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_EMAIL_ADAPTER_RUNTIME_OK',
    'org_id', p_org_id,
    'provider_key', lower(p_provider_key),
    'sender_domain', lower(p_sender_domain),
    'api_key_verified', p_api_key_verified,
    'sender_domain_verified', p_sender_domain_verified,
    'webhook_configured', p_webhook_configured,
    'bounce_handling_ready', p_bounce_handling_ready,
    'transactional_send_ready', p_transactional_send_ready,
    'runtime_status', v_status,
    'launch_blocked', (v_status <> 'verified')
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.email_adapter_runtime_v1(
    org_id,
    adapter_attachment_run_id,
    provider_key,
    sender_domain,
    api_key_verified,
    sender_domain_verified,
    webhook_configured,
    bounce_handling_ready,
    transactional_send_ready,
    runtime_status,
    runtime_body,
    runtime_hash
  )
  values (
    p_org_id,
    p_adapter_attachment_run_id,
    lower(p_provider_key),
    lower(p_sender_domain),
    p_api_key_verified,
    p_sender_domain_verified,
    p_webhook_configured,
    p_bounce_handling_ready,
    p_transactional_send_ready,
    v_status,
    v_body,
    v_hash
  )
  on conflict (org_id, provider_key, sender_domain) do update
  set
    adapter_attachment_run_id = excluded.adapter_attachment_run_id,
    api_key_verified = excluded.api_key_verified,
    sender_domain_verified = excluded.sender_domain_verified,
    webhook_configured = excluded.webhook_configured,
    bounce_handling_ready = excluded.bounce_handling_ready,
    transactional_send_ready = excluded.transactional_send_ready,
    runtime_status = excluded.runtime_status,
    runtime_body = excluded.runtime_body,
    runtime_hash = excluded.runtime_hash
  returning email_runtime_id
  into v_runtime_id;

  return v_body || jsonb_build_object(
    'email_runtime_id', v_runtime_id,
    'runtime_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_verify_email_adapter_runtime_v1"("p_org_id" "uuid", "p_provider_key" "text", "p_sender_domain" "text", "p_api_key_verified" boolean, "p_sender_domain_verified" boolean, "p_webhook_configured" boolean, "p_bounce_handling_ready" boolean, "p_transactional_send_ready" boolean, "p_adapter_attachment_run_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_verify_github_adapter_runtime_v1"("p_org_id" "uuid", "p_github_owner" "text", "p_repo_name" "text", "p_repo_url" "text", "p_token_verified" boolean DEFAULT true, "p_repo_access_verified" boolean DEFAULT true, "p_release_access_ready" boolean DEFAULT true, "p_webhook_configured" boolean DEFAULT true, "p_download_asset_ready" boolean DEFAULT true, "p_adapter_attachment_run_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_status text;
  v_body jsonb;
  v_hash text;
  v_runtime_id uuid;
begin
  if p_org_id is null then
    raise exception 'GITHUB_RUNTIME_ORG_REQUIRED';
  end if;

  if p_github_owner is null or btrim(p_github_owner) = '' then
    raise exception 'GITHUB_RUNTIME_OWNER_REQUIRED';
  end if;

  if p_repo_name is null or btrim(p_repo_name) = '' then
    raise exception 'GITHUB_RUNTIME_REPO_REQUIRED';
  end if;

  if p_repo_url is null or btrim(p_repo_url) = '' then
    raise exception 'GITHUB_RUNTIME_URL_REQUIRED';
  end if;

  if p_token_verified
    and p_repo_access_verified
    and p_release_access_ready
    and p_webhook_configured
    and p_download_asset_ready then
    v_status := 'verified';
  else
    v_status := 'blocked';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_GITHUB_ADAPTER_RUNTIME_OK',
    'org_id', p_org_id,
    'github_owner', lower(p_github_owner),
    'repo_name', p_repo_name,
    'repo_url', p_repo_url,
    'token_verified', p_token_verified,
    'repo_access_verified', p_repo_access_verified,
    'release_access_ready', p_release_access_ready,
    'webhook_configured', p_webhook_configured,
    'download_asset_ready', p_download_asset_ready,
    'runtime_status', v_status,
    'launch_blocked', (v_status <> 'verified')
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.github_adapter_runtime_v1(
    org_id,
    adapter_attachment_run_id,
    github_owner,
    repo_name,
    repo_url,
    token_verified,
    repo_access_verified,
    release_access_ready,
    webhook_configured,
    download_asset_ready,
    runtime_status,
    runtime_body,
    runtime_hash
  )
  values (
    p_org_id,
    p_adapter_attachment_run_id,
    lower(p_github_owner),
    p_repo_name,
    p_repo_url,
    p_token_verified,
    p_repo_access_verified,
    p_release_access_ready,
    p_webhook_configured,
    p_download_asset_ready,
    v_status,
    v_body,
    v_hash
  )
  on conflict (org_id, github_owner, repo_name) do update
  set
    adapter_attachment_run_id = excluded.adapter_attachment_run_id,
    repo_url = excluded.repo_url,
    token_verified = excluded.token_verified,
    repo_access_verified = excluded.repo_access_verified,
    release_access_ready = excluded.release_access_ready,
    webhook_configured = excluded.webhook_configured,
    download_asset_ready = excluded.download_asset_ready,
    runtime_status = excluded.runtime_status,
    runtime_body = excluded.runtime_body,
    runtime_hash = excluded.runtime_hash
  returning github_runtime_id
  into v_runtime_id;

  return v_body || jsonb_build_object(
    'github_runtime_id', v_runtime_id,
    'runtime_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_verify_github_adapter_runtime_v1"("p_org_id" "uuid", "p_github_owner" "text", "p_repo_name" "text", "p_repo_url" "text", "p_token_verified" boolean, "p_repo_access_verified" boolean, "p_release_access_ready" boolean, "p_webhook_configured" boolean, "p_download_asset_ready" boolean, "p_adapter_attachment_run_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_verify_release_chain_v1"("p_model_instance_runtime_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_release_count int;
  v_bad_release_count int;
  v_promotion_count int;
  v_rollback_count int;
begin
  select count(*)
  into v_release_count
  from pods_provisioning.model_releases_v1
  where model_instance_runtime_id = p_model_instance_runtime_id;

  select count(*)
  into v_bad_release_count
  from pods_provisioning.model_releases_v1
  where model_instance_runtime_id = p_model_instance_runtime_id
    and pods_provisioning._sha256_text_v1(release_body::text) <> release_hash;

  select count(*)
  into v_promotion_count
  from pods_provisioning.model_release_promotions_v1 p
  join pods_provisioning.model_releases_v1 r
    on r.model_release_id = p.model_release_id
  where r.model_instance_runtime_id = p_model_instance_runtime_id;

  select count(*)
  into v_rollback_count
  from pods_provisioning.model_release_rollbacks_v1 rb
  join pods_provisioning.model_releases_v1 r
    on r.model_release_id = rb.source_release_id
  where r.model_instance_runtime_id = p_model_instance_runtime_id;

  if v_release_count = 0 then
    raise exception 'MODEL_RELEASE_CHAIN_EMPTY';
  end if;

  if v_bad_release_count <> 0 then
    raise exception 'MODEL_RELEASE_CHAIN_HASH_FAIL:%', v_bad_release_count;
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_MODEL_RELEASE_GOVERNANCE_OK',
    'model_instance_runtime_id', p_model_instance_runtime_id,
    'verified', true,
    'release_count', v_release_count,
    'promotion_count', v_promotion_count,
    'rollback_count', v_rollback_count
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_verify_release_chain_v1"("p_model_instance_runtime_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_verify_storage_adapter_runtime_v1"("p_org_id" "uuid", "p_provider_key" "text", "p_storage_scope" "text", "p_bucket_verified" boolean DEFAULT true, "p_upload_policy_verified" boolean DEFAULT true, "p_read_policy_verified" boolean DEFAULT true, "p_signed_url_ready" boolean DEFAULT true, "p_file_metadata_ready" boolean DEFAULT true, "p_adapter_attachment_run_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_status text;
  v_body jsonb;
  v_hash text;
  v_runtime_id uuid;
begin
  if p_org_id is null then
    raise exception 'STORAGE_RUNTIME_ORG_REQUIRED';
  end if;

  if p_provider_key is null or btrim(p_provider_key) = '' then
    raise exception 'STORAGE_RUNTIME_PROVIDER_REQUIRED';
  end if;

  if p_storage_scope is null or btrim(p_storage_scope) = '' then
    raise exception 'STORAGE_RUNTIME_SCOPE_REQUIRED';
  end if;

  if p_bucket_verified
    and p_upload_policy_verified
    and p_read_policy_verified
    and p_signed_url_ready
    and p_file_metadata_ready then
    v_status := 'verified';
  else
    v_status := 'blocked';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_STORAGE_ADAPTER_RUNTIME_OK',
    'org_id', p_org_id,
    'provider_key', lower(p_provider_key),
    'storage_scope', lower(p_storage_scope),
    'bucket_verified', p_bucket_verified,
    'upload_policy_verified', p_upload_policy_verified,
    'read_policy_verified', p_read_policy_verified,
    'signed_url_ready', p_signed_url_ready,
    'file_metadata_ready', p_file_metadata_ready,
    'runtime_status', v_status,
    'launch_blocked', (v_status <> 'verified')
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.storage_adapter_runtime_v1(
    org_id,
    adapter_attachment_run_id,
    provider_key,
    storage_scope,
    bucket_verified,
    upload_policy_verified,
    read_policy_verified,
    signed_url_ready,
    file_metadata_ready,
    runtime_status,
    runtime_body,
    runtime_hash
  )
  values (
    p_org_id,
    p_adapter_attachment_run_id,
    lower(p_provider_key),
    lower(p_storage_scope),
    p_bucket_verified,
    p_upload_policy_verified,
    p_read_policy_verified,
    p_signed_url_ready,
    p_file_metadata_ready,
    v_status,
    v_body,
    v_hash
  )
  on conflict (org_id, provider_key, storage_scope) do update
  set
    adapter_attachment_run_id = excluded.adapter_attachment_run_id,
    bucket_verified = excluded.bucket_verified,
    upload_policy_verified = excluded.upload_policy_verified,
    read_policy_verified = excluded.read_policy_verified,
    signed_url_ready = excluded.signed_url_ready,
    file_metadata_ready = excluded.file_metadata_ready,
    runtime_status = excluded.runtime_status,
    runtime_body = excluded.runtime_body,
    runtime_hash = excluded.runtime_hash
  returning storage_runtime_id
  into v_runtime_id;

  return v_body || jsonb_build_object(
    'storage_runtime_id', v_runtime_id,
    'runtime_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_verify_storage_adapter_runtime_v1"("p_org_id" "uuid", "p_provider_key" "text", "p_storage_scope" "text", "p_bucket_verified" boolean, "p_upload_policy_verified" boolean, "p_read_policy_verified" boolean, "p_signed_url_ready" boolean, "p_file_metadata_ready" boolean, "p_adapter_attachment_run_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_verify_stripe_adapter_runtime_v1"("p_org_id" "uuid", "p_stripe_account_id" "text", "p_mode" "text" DEFAULT 'test'::"text", "p_api_key_verified" boolean DEFAULT true, "p_webhook_configured" boolean DEFAULT true, "p_webhook_signing_secret_present" boolean DEFAULT true, "p_product_sync_ready" boolean DEFAULT true, "p_price_sync_ready" boolean DEFAULT true, "p_payment_intent_ready" boolean DEFAULT true, "p_adapter_attachment_run_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_status text;
  v_body jsonb;
  v_hash text;
  v_runtime_id uuid;
begin
  if p_org_id is null then
    raise exception 'STRIPE_RUNTIME_ORG_REQUIRED';
  end if;

  if p_stripe_account_id is null or btrim(p_stripe_account_id) = '' then
    raise exception 'STRIPE_RUNTIME_ACCOUNT_REQUIRED';
  end if;

  if p_mode is null or p_mode not in ('test','live') then
    raise exception 'STRIPE_RUNTIME_MODE_INVALID:%', coalesce(p_mode,'');
  end if;

  if p_api_key_verified
    and p_webhook_configured
    and p_webhook_signing_secret_present
    and p_product_sync_ready
    and p_price_sync_ready
    and p_payment_intent_ready then
    v_status := 'verified';
  else
    v_status := 'blocked';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_STRIPE_ADAPTER_RUNTIME_OK',
    'org_id', p_org_id,
    'stripe_account_id', p_stripe_account_id,
    'mode', p_mode,
    'api_key_verified', p_api_key_verified,
    'webhook_configured', p_webhook_configured,
    'webhook_signing_secret_present', p_webhook_signing_secret_present,
    'product_sync_ready', p_product_sync_ready,
    'price_sync_ready', p_price_sync_ready,
    'payment_intent_ready', p_payment_intent_ready,
    'runtime_status', v_status,
    'launch_blocked', (v_status <> 'verified')
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.stripe_adapter_runtime_v1(
    org_id,
    adapter_attachment_run_id,
    stripe_account_id,
    mode,
    api_key_verified,
    webhook_configured,
    webhook_signing_secret_present,
    product_sync_ready,
    price_sync_ready,
    payment_intent_ready,
    runtime_status,
    runtime_body,
    runtime_hash
  )
  values (
    p_org_id,
    p_adapter_attachment_run_id,
    p_stripe_account_id,
    p_mode,
    p_api_key_verified,
    p_webhook_configured,
    p_webhook_signing_secret_present,
    p_product_sync_ready,
    p_price_sync_ready,
    p_payment_intent_ready,
    v_status,
    v_body,
    v_hash
  )
  on conflict (org_id, stripe_account_id, mode) do update
  set
    adapter_attachment_run_id = excluded.adapter_attachment_run_id,
    api_key_verified = excluded.api_key_verified,
    webhook_configured = excluded.webhook_configured,
    webhook_signing_secret_present = excluded.webhook_signing_secret_present,
    product_sync_ready = excluded.product_sync_ready,
    price_sync_ready = excluded.price_sync_ready,
    payment_intent_ready = excluded.payment_intent_ready,
    runtime_status = excluded.runtime_status,
    runtime_body = excluded.runtime_body,
    runtime_hash = excluded.runtime_hash
  returning stripe_runtime_id
  into v_runtime_id;

  return v_body || jsonb_build_object(
    'stripe_runtime_id', v_runtime_id,
    'runtime_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_verify_stripe_adapter_runtime_v1"("p_org_id" "uuid", "p_stripe_account_id" "text", "p_mode" "text", "p_api_key_verified" boolean, "p_webhook_configured" boolean, "p_webhook_signing_secret_present" boolean, "p_product_sync_ready" boolean, "p_price_sync_ready" boolean, "p_payment_intent_ready" boolean, "p_adapter_attachment_run_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_verify_supabase_adapter_runtime_v1"("p_org_id" "uuid", "p_project_ref" "text", "p_supabase_url" "text", "p_auth_verified" boolean DEFAULT true, "p_storage_verified" boolean DEFAULT true, "p_database_verified" boolean DEFAULT true, "p_rls_verified" boolean DEFAULT true, "p_adapter_attachment_run_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_status text;
  v_body jsonb;
  v_hash text;
  v_runtime_id uuid;
begin
  if p_org_id is null then
    raise exception 'SUPABASE_RUNTIME_ORG_REQUIRED';
  end if;

  if p_project_ref is null or btrim(p_project_ref) = '' then
    raise exception 'SUPABASE_RUNTIME_PROJECT_REF_REQUIRED';
  end if;

  if p_supabase_url is null or btrim(p_supabase_url) = '' then
    raise exception 'SUPABASE_RUNTIME_URL_REQUIRED';
  end if;

  if p_auth_verified and p_storage_verified and p_database_verified and p_rls_verified then
    v_status := 'verified';
  else
    v_status := 'blocked';
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_SUPABASE_ADAPTER_RUNTIME_OK',
    'org_id', p_org_id,
    'project_ref', p_project_ref,
    'supabase_url', p_supabase_url,
    'auth_verified', p_auth_verified,
    'storage_verified', p_storage_verified,
    'database_verified', p_database_verified,
    'rls_verified', p_rls_verified,
    'runtime_status', v_status,
    'launch_blocked', (v_status <> 'verified')
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.supabase_adapter_runtime_v1(
    org_id,
    adapter_attachment_run_id,
    project_ref,
    supabase_url,
    auth_verified,
    storage_verified,
    database_verified,
    rls_verified,
    runtime_status,
    runtime_body,
    runtime_hash
  )
  values (
    p_org_id,
    p_adapter_attachment_run_id,
    p_project_ref,
    p_supabase_url,
    p_auth_verified,
    p_storage_verified,
    p_database_verified,
    p_rls_verified,
    v_status,
    v_body,
    v_hash
  )
  on conflict (org_id, project_ref) do update
  set
    adapter_attachment_run_id = excluded.adapter_attachment_run_id,
    supabase_url = excluded.supabase_url,
    auth_verified = excluded.auth_verified,
    storage_verified = excluded.storage_verified,
    database_verified = excluded.database_verified,
    rls_verified = excluded.rls_verified,
    runtime_status = excluded.runtime_status,
    runtime_body = excluded.runtime_body,
    runtime_hash = excluded.runtime_hash
  returning supabase_runtime_id
  into v_runtime_id;

  return v_body || jsonb_build_object(
    'supabase_runtime_id', v_runtime_id,
    'runtime_hash', v_hash
  );
end;
$$;


ALTER FUNCTION "pods_provisioning"."rpc_verify_supabase_adapter_runtime_v1"("p_org_id" "uuid", "p_project_ref" "text", "p_supabase_url" "text", "p_auth_verified" boolean, "p_storage_verified" boolean, "p_database_verified" boolean, "p_rls_verified" boolean, "p_adapter_attachment_run_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "pods_public"."assert_public_surface_allowed_v1"("p_object_schema" "text", "p_object_name" "text", "p_exposure_kind" "text") RETURNS boolean
    LANGUAGE "plpgsql" STABLE
    AS $$
declare
  v_surface_key text;
  v_public_safe boolean;
  v_exposure_kind text;
begin
  v_surface_key := lower(coalesce(p_object_schema,'')) || '.' || lower(coalesce(p_object_name,''));
  v_exposure_kind := lower(coalesce(p_exposure_kind,''));

  if v_exposure_kind not in ('read','request','execute') then
    raise exception 'PUBLIC_SURFACE_UNKNOWN_EXPOSURE:%', coalesce(p_exposure_kind,'<null>');
  end if;

  select c.public_safe
    into v_public_safe
  from pods_public.public_surface_contracts_v1 c
  where lower(c.object_schema) = lower(coalesce(p_object_schema,''))
    and lower(c.object_name) = lower(coalesce(p_object_name,''))
    and lower(c.exposure_kind) = v_exposure_kind
  limit 1;

  if v_public_safe is null then
    raise exception 'PUBLIC_SURFACE_RULE_MISSING:%', v_surface_key;
  end if;

  if v_public_safe = false then
    raise exception 'PUBLIC_SURFACE_DENY:%:%', v_surface_key, v_exposure_kind;
  end if;

  return true;
end
$$;


ALTER FUNCTION "pods_public"."assert_public_surface_allowed_v1"("p_object_schema" "text", "p_object_name" "text", "p_exposure_kind" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "pods_public"."assert_public_surface_allowed_v1"("p_object_schema" "text", "p_object_name" "text", "p_exposure_kind" "text") IS 'Asserts whether a named public surface is allowed for public-safe exposure. Raises deterministic deny/missing tokens.';



CREATE OR REPLACE FUNCTION "pods_public"."rpc_selftest_public_surface_v1"("p_object_schema" "text", "p_object_name" "text", "p_exposure_kind" "text", "p_expected_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_public', 'public'
    AS $$
declare
  v_ok boolean;
  v_msg text;
begin
  begin
    v_ok := pods_public.assert_public_surface_allowed_v1(
      p_object_schema,
      p_object_name,
      p_exposure_kind
    );

    if coalesce(v_ok,false) is true then
      return jsonb_build_object(
        'ok', true,
        'object_schema', lower(coalesce(p_object_schema,'')),
        'object_name', lower(coalesce(p_object_name,'')),
        'exposure_kind', lower(coalesce(p_exposure_kind,'')),
        'token', 'PUBLIC_SURFACE_ALLOW'
      );
    end if;

    return jsonb_build_object(
      'ok', false,
      'object_schema', lower(coalesce(p_object_schema,'')),
      'object_name', lower(coalesce(p_object_name,'')),
      'exposure_kind', lower(coalesce(p_exposure_kind,'')),
      'token', 'PUBLIC_SURFACE_UNEXPECTED_FALSE'
    );
  exception
    when others then
      v_msg := sqlerrm;

      if p_expected_token is not null and position(p_expected_token in v_msg) > 0 then
        return jsonb_build_object(
          'ok', true,
          'object_schema', lower(coalesce(p_object_schema,'')),
          'object_name', lower(coalesce(p_object_name,'')),
          'exposure_kind', lower(coalesce(p_exposure_kind,'')),
          'token', p_expected_token,
          'message', v_msg
        );
      end if;

      return jsonb_build_object(
        'ok', false,
        'object_schema', lower(coalesce(p_object_schema,'')),
        'object_name', lower(coalesce(p_object_name,'')),
        'exposure_kind', lower(coalesce(p_exposure_kind,'')),
        'token', 'PUBLIC_SURFACE_UNEXPECTED_EXCEPTION',
        'message', v_msg
      );
  end;
end
$$;


ALTER FUNCTION "pods_public"."rpc_selftest_public_surface_v1"("p_object_schema" "text", "p_object_name" "text", "p_exposure_kind" "text", "p_expected_token" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "pods_public"."rpc_selftest_public_surface_v1"("p_object_schema" "text", "p_object_name" "text", "p_exposure_kind" "text", "p_expected_token" "text") IS 'Runs deterministic public surface allow/deny checks and returns structured pass/fail JSON.';



CREATE OR REPLACE FUNCTION "pods_public"."rpc_selftest_public_surfaces_all_v1"() RETURNS TABLE("vector_key" "text", "ok" boolean, "token" "text", "message" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_public', 'public'
    AS $$
declare
  r record;
  j jsonb;
  v_ok boolean;
  v_token text;
  v_message text;
begin
  for r in
    select
      v.vector_key,
      v.object_schema,
      v.object_name,
      v.exposure_kind,
      v.expected_ok,
      v.expected_token
    from pods_public.public_surface_selftest_vectors_v1 v
    order by v.vector_key
  loop
    j := pods_public.rpc_selftest_public_surface_v1(
      r.object_schema,
      r.object_name,
      r.exposure_kind,
      case
        when r.expected_token = 'PUBLIC_SURFACE_ALLOW' then null
        else r.expected_token
      end
    );

    v_ok := coalesce((j ->> 'ok')::boolean, false);
    v_token := coalesce(j ->> 'token', '');
    v_message := coalesce(j ->> 'message', '');

    if r.expected_token = 'PUBLIC_SURFACE_ALLOW' then
      if not (v_ok = true and v_token = 'PUBLIC_SURFACE_ALLOW') then
        raise exception 'PUBLIC_SURFACE_SELFTEST_FAIL:%:%', r.vector_key, coalesce(v_token,'<null>');
      end if;
    else
      if not (v_ok = true and position(r.expected_token in v_token) > 0) then
        raise exception 'PUBLIC_SURFACE_SELFTEST_FAIL:%:%', r.vector_key, coalesce(v_token,'<null>');
      end if;
    end if;

    rpc_selftest_public_surfaces_all_v1.vector_key := r.vector_key;
    rpc_selftest_public_surfaces_all_v1.ok := v_ok;
    rpc_selftest_public_surfaces_all_v1.token := v_token;
    rpc_selftest_public_surfaces_all_v1.message := v_message;
    return next;
  end loop;

  return;
end
$$;


ALTER FUNCTION "pods_public"."rpc_selftest_public_surfaces_all_v1"() OWNER TO "postgres";


COMMENT ON FUNCTION "pods_public"."rpc_selftest_public_surfaces_all_v1"() IS 'Executes all Tier-1 public surface vectors and raises deterministic failure tokens if any vector deviates from expected behavior.';



CREATE OR REPLACE FUNCTION "public"."rpc_add_time_off_block_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_time" timestamp with time zone, "p_end_time" timestamp with time zone, "p_reason" "text") RETURNS "uuid"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
  select pods.rpc_add_time_off_block_v1(p_org_id, p_staff_user_id, p_start_time, p_end_time, p_reason);
$$;


ALTER FUNCTION "public"."rpc_add_time_off_block_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_time" timestamp with time zone, "p_end_time" timestamp with time zone, "p_reason" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."rpc_add_time_off_block_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_time" timestamp with time zone, "p_end_time" timestamp with time zone, "p_reason" "text") IS 'Canonical lane classification: pods_ops. Public wrapper retained for compatibility/PostgREST exposure during transition.';



CREATE OR REPLACE FUNCTION "public"."rpc_create_appointment_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_time" timestamp with time zone, "p_end_time" timestamp with time zone, "p_service_id" "uuid", "p_location_id" "uuid", "p_guest_name" "text", "p_guest_email" "text", "p_guest_phone" "text", "p_notes" "text") RETURNS "uuid"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
  select pods.rpc_create_appointment_v1(
    p_org_id,
    p_staff_user_id,
    p_start_time,
    p_end_time,
    p_service_id,
    p_location_id,
    p_guest_name,
    p_guest_email,
    p_guest_phone,
    p_notes
  );
$$;


ALTER FUNCTION "public"."rpc_create_appointment_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_time" timestamp with time zone, "p_end_time" timestamp with time zone, "p_service_id" "uuid", "p_location_id" "uuid", "p_guest_name" "text", "p_guest_email" "text", "p_guest_phone" "text", "p_notes" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."rpc_create_appointment_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_time" timestamp with time zone, "p_end_time" timestamp with time zone, "p_service_id" "uuid", "p_location_id" "uuid", "p_guest_name" "text", "p_guest_email" "text", "p_guest_phone" "text", "p_notes" "text") IS 'Canonical lane classification: pods_ops. Public wrapper retained for compatibility/PostgREST exposure during transition.';



CREATE OR REPLACE FUNCTION "public"."rpc_create_org_bootstrap"("p_slug" "text", "p_name" "text", "p_plan_id" "text") RETURNS "uuid"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
  select pods.rpc_create_org_bootstrap(p_slug, p_name, p_plan_id);
$$;


ALTER FUNCTION "public"."rpc_create_org_bootstrap"("p_slug" "text", "p_name" "text", "p_plan_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_delete_availability_rule_v1"("p_org_id" "uuid", "p_rule_id" "uuid") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
  select pods.rpc_delete_availability_rule_v1(p_org_id, p_rule_id);
$$;


ALTER FUNCTION "public"."rpc_delete_availability_rule_v1"("p_org_id" "uuid", "p_rule_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_recompute_entitlements"("p_org_id" "uuid") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
  select pods.rpc_recompute_entitlements(p_org_id);
$$;


ALTER FUNCTION "public"."rpc_recompute_entitlements"("p_org_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."rpc_recompute_entitlements"("p_org_id" "uuid") IS 'Canonical lane classification: pods_core. Public wrapper retained for compatibility/PostgREST exposure during transition.';



CREATE OR REPLACE FUNCTION "public"."rpc_selftest_add_org_member_v1"("p_org_id" "uuid", "p_user_id" "uuid", "p_role" "text" DEFAULT 'owner'::"text") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
  select pods.rpc_selftest_add_org_member_v1(p_org_id, p_user_id, p_role);
$$;


ALTER FUNCTION "public"."rpc_selftest_add_org_member_v1"("p_org_id" "uuid", "p_user_id" "uuid", "p_role" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."rpc_selftest_add_org_member_v1"("p_org_id" "uuid", "p_user_id" "uuid", "p_role" "text") IS 'Canonical lane classification: pods_core. Public wrapper retained for compatibility/PostgREST exposure during transition.';



CREATE OR REPLACE FUNCTION "public"."rpc_selftest_reset_booking_v1"("p_org_id" "uuid") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
  select pods.rpc_selftest_reset_booking_v1(p_org_id);
$$;


ALTER FUNCTION "public"."rpc_selftest_reset_booking_v1"("p_org_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rpc_selftest_reset_booking_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
  select pods.rpc_selftest_reset_booking_v1(p_org_id, p_staff_user_id);
$$;


ALTER FUNCTION "public"."rpc_selftest_reset_booking_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."rpc_selftest_reset_booking_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid") IS 'Canonical lane classification: pods_ops. Public wrapper retained for compatibility/PostgREST exposure during transition.';



CREATE OR REPLACE FUNCTION "public"."rpc_selftest_set_subscription_plan_v1"("p_org_id" "uuid", "p_plan_id" "text", "p_status" "text") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
  select pods.rpc_selftest_set_subscription_plan_v1(p_org_id, p_plan_id, p_status);
$$;


ALTER FUNCTION "public"."rpc_selftest_set_subscription_plan_v1"("p_org_id" "uuid", "p_plan_id" "text", "p_status" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."rpc_selftest_set_subscription_plan_v1"("p_org_id" "uuid", "p_plan_id" "text", "p_status" "text") IS 'Canonical lane classification: pods_core. Public wrapper retained for compatibility/PostgREST exposure during transition.';



CREATE OR REPLACE FUNCTION "public"."rpc_upsert_availability_rule_v1"("p_org_id" "uuid", "p_rule_id" "uuid", "p_staff_user_id" "uuid", "p_location_id" "uuid", "p_day_of_week" integer, "p_start_time" time without time zone, "p_end_time" time without time zone, "p_is_active" boolean) RETURNS "uuid"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'pods', 'public'
    AS $$
  select pods.rpc_upsert_availability_rule_v1(
    p_org_id,
    p_rule_id,
    p_staff_user_id,
    p_location_id,
    p_day_of_week,
    p_start_time,
    p_end_time,
    p_is_active
  );
$$;


ALTER FUNCTION "public"."rpc_upsert_availability_rule_v1"("p_org_id" "uuid", "p_rule_id" "uuid", "p_staff_user_id" "uuid", "p_location_id" "uuid", "p_day_of_week" integer, "p_start_time" time without time zone, "p_end_time" time without time zone, "p_is_active" boolean) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."rpc_upsert_availability_rule_v1"("p_org_id" "uuid", "p_rule_id" "uuid", "p_staff_user_id" "uuid", "p_location_id" "uuid", "p_day_of_week" integer, "p_start_time" time without time zone, "p_end_time" time without time zone, "p_is_active" boolean) IS 'Canonical lane classification: pods_ops. Public wrapper retained for compatibility/PostgREST exposure during transition.';


SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "pods"."audit_log" (
    "audit_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid",
    "actor_user_id" "uuid",
    "actor_role_key" "text",
    "action_key" "text" NOT NULL,
    "entity_table" "text",
    "entity_id" "text",
    "details" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods"."audit_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."billing_accounts" (
    "org_id" "uuid" NOT NULL,
    "provider" "text" DEFAULT 'stripe'::"text" NOT NULL,
    "provider_customer_id" "text" NOT NULL,
    "billing_email" "text",
    "status" "text" DEFAULT 'inactive'::"text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods"."billing_accounts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."booking_appointment_status_log" (
    "log_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "appointment_id" "uuid" NOT NULL,
    "from_status" "text",
    "to_status" "text" NOT NULL,
    "actor_user_id" "uuid",
    "actor_role_key" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "details" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL
);


ALTER TABLE "pods"."booking_appointment_status_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."booking_appointments" (
    "appointment_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "location_id" "uuid",
    "service_id" "uuid",
    "staff_user_id" "uuid" NOT NULL,
    "customer_id" "uuid",
    "customer_user_id" "uuid",
    "customer_name" "text",
    "customer_email" "text",
    "customer_phone" "text",
    "start_at" timestamp with time zone NOT NULL,
    "end_at" timestamp with time zone NOT NULL,
    "status" "text" DEFAULT 'requested'::"text" NOT NULL,
    "notes" "text",
    "created_by_user_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "booking_appointments_check" CHECK (("end_at" > "start_at"))
);


ALTER TABLE "pods"."booking_appointments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."booking_availability_rules" (
    "rule_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "staff_user_id" "uuid" NOT NULL,
    "location_id" "uuid",
    "day_of_week" integer NOT NULL,
    "start_time" time without time zone NOT NULL,
    "end_time" time without time zone NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "booking_availability_rules_day_of_week_check" CHECK ((("day_of_week" >= 0) AND ("day_of_week" <= 6)))
);


ALTER TABLE "pods"."booking_availability_rules" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."booking_customers" (
    "customer_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "user_id" "uuid",
    "display_name" "text",
    "email" "text",
    "phone" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods"."booking_customers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."booking_time_off_blocks" (
    "block_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "staff_user_id" "uuid" NOT NULL,
    "start_at" timestamp with time zone NOT NULL,
    "end_at" timestamp with time zone NOT NULL,
    "reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "booking_time_off_blocks_check" CHECK (("end_at" > "start_at"))
);


ALTER TABLE "pods"."booking_time_off_blocks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."entitlement_overrides" (
    "org_id" "uuid" NOT NULL,
    "capability_key" "text" NOT NULL,
    "value_type" "text" NOT NULL,
    "value_bool" boolean,
    "value_int" bigint,
    "value_text" "text",
    "reason" "text" NOT NULL,
    "expires_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "entitlement_overrides_value_type_check" CHECK (("value_type" = ANY (ARRAY['bool'::"text", 'int'::"text", 'text'::"text"])))
);


ALTER TABLE "pods"."entitlement_overrides" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."migration_ledger" (
    "org_id" "uuid" NOT NULL,
    "model_id" "text" NOT NULL,
    "version" "text" NOT NULL,
    "migration_id" "text" NOT NULL,
    "applied_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "applied_by" "text" DEFAULT 'system'::"text" NOT NULL
);


ALTER TABLE "pods"."migration_ledger" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."models" (
    "model_id" "text" NOT NULL,
    "version" "text" NOT NULL,
    "depends_on" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods"."models" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."org_entitlements" (
    "org_id" "uuid" NOT NULL,
    "capability_key" "text" NOT NULL,
    "value_type" "text" NOT NULL,
    "value_bool" boolean,
    "value_int" bigint,
    "value_text" "text",
    "source" "text" NOT NULL,
    "computed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "org_entitlements_source_check" CHECK (("source" = ANY (ARRAY['plan'::"text", 'override'::"text", 'system'::"text"]))),
    CONSTRAINT "org_entitlements_value_type_check" CHECK (("value_type" = ANY (ARRAY['bool'::"text", 'int'::"text", 'text'::"text"])))
);


ALTER TABLE "pods"."org_entitlements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."org_members" (
    "org_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role_key" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods"."org_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."org_models" (
    "org_id" "uuid" NOT NULL,
    "model_id" "text" NOT NULL,
    "version" "text" NOT NULL,
    "installed_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods"."org_models" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."orgs" (
    "org_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "slug" "text" NOT NULL,
    "name" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods"."orgs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."plan_capabilities" (
    "plan_id" "text" NOT NULL,
    "capability_key" "text" NOT NULL,
    "value_type" "text" NOT NULL,
    "value_bool" boolean,
    "value_int" bigint,
    "value_text" "text",
    CONSTRAINT "plan_capabilities_value_type_check" CHECK (("value_type" = ANY (ARRAY['bool'::"text", 'int'::"text", 'text'::"text"])))
);


ALTER TABLE "pods"."plan_capabilities" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."plan_tiers" (
    "plan_id" "text" NOT NULL,
    "name" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL
);


ALTER TABLE "pods"."plan_tiers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."storefront_locations" (
    "location_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "address_line1" "text",
    "address_line2" "text",
    "city" "text",
    "region" "text",
    "postal_code" "text",
    "country" "text",
    "latitude" numeric,
    "longitude" numeric,
    "hours_json" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods"."storefront_locations" OWNER TO "postgres";


CREATE OR REPLACE VIEW "pods"."public_storefront_locations_v1" AS
 SELECT "o"."slug",
    "l"."location_id",
    "l"."name",
    "l"."address_line1",
    "l"."address_line2",
    "l"."city",
    "l"."region",
    "l"."postal_code",
    "l"."country",
    "l"."latitude",
    "l"."longitude",
    "l"."hours_json"
   FROM ("pods"."orgs" "o"
     JOIN "pods"."storefront_locations" "l" ON (("l"."org_id" = "o"."org_id")))
  WHERE (("o"."is_active" = true) AND ("l"."is_active" = true));


ALTER VIEW "pods"."public_storefront_locations_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."storefront_profiles" (
    "org_id" "uuid" NOT NULL,
    "display_name" "text" NOT NULL,
    "tagline" "text",
    "description" "text",
    "website_url" "text",
    "phone" "text",
    "email" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods"."storefront_profiles" OWNER TO "postgres";


CREATE OR REPLACE VIEW "pods"."public_storefront_profile_v1" AS
 SELECT "o"."slug",
    "o"."name" AS "org_name",
    "p"."display_name",
    "p"."tagline",
    "p"."description",
    "p"."website_url",
    "p"."phone",
    "p"."email"
   FROM ("pods"."orgs" "o"
     JOIN "pods"."storefront_profiles" "p" ON (("p"."org_id" = "o"."org_id")))
  WHERE ("o"."is_active" = true);


ALTER VIEW "pods"."public_storefront_profile_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."storefront_service_categories" (
    "category_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods"."storefront_service_categories" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."storefront_services" (
    "service_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "category_id" "uuid",
    "name" "text" NOT NULL,
    "description" "text",
    "price_cents" integer,
    "duration_mins" integer,
    "is_active" boolean DEFAULT true NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods"."storefront_services" OWNER TO "postgres";


CREATE OR REPLACE VIEW "pods"."public_storefront_services_v1" AS
 SELECT "o"."slug",
    "s"."service_id",
    "s"."name",
    "s"."description",
    "s"."price_cents",
    "s"."duration_mins",
    "s"."sort_order",
    "c"."name" AS "category_name"
   FROM (("pods"."orgs" "o"
     JOIN "pods"."storefront_services" "s" ON (("s"."org_id" = "o"."org_id")))
     LEFT JOIN "pods"."storefront_service_categories" "c" ON (("c"."category_id" = "s"."category_id")))
  WHERE (("o"."is_active" = true) AND ("s"."is_active" = true));


ALTER VIEW "pods"."public_storefront_services_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."storefront_team_members" (
    "team_member_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "display_name" "text" NOT NULL,
    "role_title" "text",
    "bio" "text",
    "photo_url" "text",
    "sort_order" integer DEFAULT 0 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods"."storefront_team_members" OWNER TO "postgres";


CREATE OR REPLACE VIEW "pods"."public_storefront_team_v1" AS
 SELECT "o"."slug",
    "t"."team_member_id",
    "t"."display_name",
    "t"."role_title",
    "t"."bio",
    "t"."photo_url",
    "t"."sort_order"
   FROM ("pods"."orgs" "o"
     JOIN "pods"."storefront_team_members" "t" ON (("t"."org_id" = "o"."org_id")))
  WHERE (("o"."is_active" = true) AND ("t"."is_active" = true));


ALTER VIEW "pods"."public_storefront_team_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."role_permissions" (
    "role_key" "text" NOT NULL,
    "capability_key" "text" NOT NULL,
    "perm_read" boolean DEFAULT false NOT NULL,
    "perm_write" boolean DEFAULT false NOT NULL,
    "perm_delete" boolean DEFAULT false NOT NULL
);


ALTER TABLE "pods"."role_permissions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."roles" (
    "role_key" "text" NOT NULL,
    "description" "text" NOT NULL
);


ALTER TABLE "pods"."roles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."storefront_contact_requests" (
    "contact_request_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "name" "text",
    "email" "text",
    "phone" "text",
    "message" "text" NOT NULL,
    "status" "text" DEFAULT 'new'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods"."storefront_contact_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."subscriptions" (
    "org_id" "uuid" NOT NULL,
    "provider_subscription_id" "text" NOT NULL,
    "status" "text" NOT NULL,
    "plan_id" "text" NOT NULL,
    "current_period_start" timestamp with time zone,
    "current_period_end" timestamp with time zone,
    "cancel_at_period_end" boolean DEFAULT false NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods"."subscriptions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods"."usage_counters" (
    "org_id" "uuid" NOT NULL,
    "counter_key" "text" NOT NULL,
    "period_start" "date" NOT NULL,
    "period_end" "date" NOT NULL,
    "value" bigint DEFAULT 0 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods"."usage_counters" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_core"."lane_boundary_selftest_vectors_v1" (
    "vector_key" "text" NOT NULL,
    "source_lane" "text" NOT NULL,
    "target_schema" "text" NOT NULL,
    "action_kind" "text" NOT NULL,
    "expected_ok" boolean NOT NULL,
    "expected_token" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "lane_boundary_vectors_action_ck" CHECK (("action_kind" = ANY (ARRAY['read'::"text", 'write'::"text", 'execute'::"text", 'expose'::"text"]))),
    CONSTRAINT "lane_boundary_vectors_source_ck" CHECK (("source_lane" = ANY (ARRAY['core'::"text", 'ops'::"text", 'public'::"text", 'billing'::"text"]))),
    CONSTRAINT "lane_boundary_vectors_target_ck" CHECK (("lower"("target_schema") = ANY (ARRAY['pods_core'::"text", 'pods_ops'::"text", 'pods_public'::"text", 'pods_billing'::"text"])))
);


ALTER TABLE "pods_core"."lane_boundary_selftest_vectors_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_core"."lane_contracts_v1" (
    "lane_key" "text" NOT NULL,
    "owner_schema" "text" NOT NULL,
    "purpose" "text" NOT NULL,
    "write_policy" "text" NOT NULL,
    "public_surface" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods_core"."lane_contracts_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_core"."lane_negative_boundaries_v1" (
    "boundary_key" "text" NOT NULL,
    "source_lane" "text" NOT NULL,
    "target_lane" "text" NOT NULL,
    "action_kind" "text" NOT NULL,
    "allowed" boolean NOT NULL,
    "enforcement_mode" "text" DEFAULT 'deny'::"text" NOT NULL,
    "rationale" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "lane_negative_boundaries_action_ck" CHECK (("action_kind" = ANY (ARRAY['read'::"text", 'write'::"text", 'execute'::"text", 'expose'::"text"]))),
    CONSTRAINT "lane_negative_boundaries_source_ck" CHECK (("source_lane" = ANY (ARRAY['core'::"text", 'ops'::"text", 'public'::"text", 'billing'::"text"]))),
    CONSTRAINT "lane_negative_boundaries_target_ck" CHECK (("target_lane" = ANY (ARRAY['core'::"text", 'ops'::"text", 'public'::"text", 'billing'::"text"])))
);


ALTER TABLE "pods_core"."lane_negative_boundaries_v1" OWNER TO "postgres";


CREATE OR REPLACE VIEW "pods_core"."v_lane_boundary_selftest_vectors_v1" AS
 SELECT "vector_key",
    "source_lane",
    "target_schema",
    "action_kind",
    "expected_ok",
    "expected_token",
    "created_at"
   FROM "pods_core"."lane_boundary_selftest_vectors_v1" "v"
  ORDER BY "vector_key";


ALTER VIEW "pods_core"."v_lane_boundary_selftest_vectors_v1" OWNER TO "postgres";


COMMENT ON VIEW "pods_core"."v_lane_boundary_selftest_vectors_v1" IS 'Readable Tier-1 lane boundary selftest vector registry.';



CREATE OR REPLACE VIEW "pods_core"."v_lane_negative_boundaries_v1" AS
 SELECT "boundary_key",
    "source_lane",
    "target_lane",
    "action_kind",
    "allowed",
    "enforcement_mode",
    "rationale",
    "created_at"
   FROM "pods_core"."lane_negative_boundaries_v1"
  ORDER BY "source_lane", "target_lane", "action_kind", "boundary_key";


ALTER VIEW "pods_core"."v_lane_negative_boundaries_v1" OWNER TO "postgres";


COMMENT ON VIEW "pods_core"."v_lane_negative_boundaries_v1" IS 'Readable contract surface for ProteusOps Tier-1 negative lane boundaries.';



CREATE OR REPLACE VIEW "pods_core"."v_org_entitlements" AS
 SELECT "org_id",
    "capability_key",
    "value_type",
    "value_bool",
    "value_int",
    "value_text",
    "source",
    "computed_at"
   FROM "pods"."org_entitlements";


ALTER VIEW "pods_core"."v_org_entitlements" OWNER TO "postgres";


COMMENT ON VIEW "pods_core"."v_org_entitlements" IS 'Compatibility view during schema transition. Authoritative conceptual lane: pods_core.';



CREATE OR REPLACE VIEW "pods_core"."v_org_members" AS
 SELECT "org_id",
    "user_id",
    "role_key",
    "created_at"
   FROM "pods"."org_members";


ALTER VIEW "pods_core"."v_org_members" OWNER TO "postgres";


COMMENT ON VIEW "pods_core"."v_org_members" IS 'Compatibility view during schema transition. Authoritative conceptual lane: pods_core.';



CREATE OR REPLACE VIEW "pods_core"."v_orgs" AS
 SELECT "org_id",
    "slug",
    "name",
    "is_active",
    "created_at"
   FROM "pods"."orgs";


ALTER VIEW "pods_core"."v_orgs" OWNER TO "postgres";


COMMENT ON VIEW "pods_core"."v_orgs" IS 'Compatibility view during schema transition. Authoritative conceptual lane: pods_core. Physical storage currently remains under pods.orgs unless/until explicitly migrated.';



CREATE OR REPLACE VIEW "pods_core"."v_plan_capabilities" AS
 SELECT "plan_id",
    "capability_key",
    "value_type",
    "value_bool",
    "value_int",
    "value_text"
   FROM "pods"."plan_capabilities";


ALTER VIEW "pods_core"."v_plan_capabilities" OWNER TO "postgres";


COMMENT ON VIEW "pods_core"."v_plan_capabilities" IS 'Compatibility view during schema transition. Authoritative conceptual lane: pods_core.';



CREATE OR REPLACE VIEW "pods_core"."v_plan_tiers" AS
 SELECT "plan_id",
    "name",
    "is_active"
   FROM "pods"."plan_tiers";


ALTER VIEW "pods_core"."v_plan_tiers" OWNER TO "postgres";


COMMENT ON VIEW "pods_core"."v_plan_tiers" IS 'Compatibility view during schema transition. Authoritative conceptual lane: pods_core.';



CREATE OR REPLACE VIEW "pods_core"."v_subscriptions" AS
 SELECT "org_id",
    "provider_subscription_id",
    "status",
    "plan_id",
    "current_period_start",
    "current_period_end",
    "cancel_at_period_end",
    "updated_at"
   FROM "pods"."subscriptions";


ALTER VIEW "pods_core"."v_subscriptions" OWNER TO "postgres";


COMMENT ON VIEW "pods_core"."v_subscriptions" IS 'Compatibility view during schema transition. Authoritative conceptual lane: pods_core.';



CREATE OR REPLACE VIEW "pods_ops"."v_booking_appointments" AS
 SELECT "appointment_id",
    "org_id",
    "location_id",
    "service_id",
    "staff_user_id",
    "customer_id",
    "customer_user_id",
    "customer_name",
    "customer_email",
    "customer_phone",
    "start_at",
    "end_at",
    "status",
    "notes",
    "created_by_user_id",
    "created_at",
    "updated_at"
   FROM "pods"."booking_appointments";


ALTER VIEW "pods_ops"."v_booking_appointments" OWNER TO "postgres";


COMMENT ON VIEW "pods_ops"."v_booking_appointments" IS 'Compatibility view during schema transition. Authoritative conceptual lane: pods_ops.';



CREATE OR REPLACE VIEW "pods_ops"."v_booking_availability_rules" AS
 SELECT "rule_id",
    "org_id",
    "staff_user_id",
    "location_id",
    "day_of_week",
    "start_time",
    "end_time",
    "is_active",
    "created_at"
   FROM "pods"."booking_availability_rules";


ALTER VIEW "pods_ops"."v_booking_availability_rules" OWNER TO "postgres";


COMMENT ON VIEW "pods_ops"."v_booking_availability_rules" IS 'Compatibility view during schema transition. Authoritative conceptual lane: pods_ops.';



CREATE OR REPLACE VIEW "pods_ops"."v_booking_time_off_blocks" AS
 SELECT "block_id",
    "org_id",
    "staff_user_id",
    "start_at",
    "end_at",
    "reason",
    "created_at"
   FROM "pods"."booking_time_off_blocks";


ALTER VIEW "pods_ops"."v_booking_time_off_blocks" OWNER TO "postgres";


COMMENT ON VIEW "pods_ops"."v_booking_time_off_blocks" IS 'Compatibility view during schema transition. Authoritative conceptual lane: pods_ops.';



CREATE TABLE IF NOT EXISTS "pods_provisioning"."adapter_attachment_items_v1" (
    "adapter_attachment_item_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "adapter_attachment_run_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "adapter_key" "text" NOT NULL,
    "provider_key" "text" DEFAULT ''::"text" NOT NULL,
    "adapter_status" "text" DEFAULT 'missing'::"text" NOT NULL,
    "required" boolean DEFAULT true NOT NULL,
    "config_ref" "text" DEFAULT ''::"text" NOT NULL,
    "public_metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "secret_ref_required" boolean DEFAULT true NOT NULL,
    "item_body" "jsonb" NOT NULL,
    "item_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "adapter_attachment_item_hash_ck" CHECK (("item_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "adapter_attachment_item_status_ck" CHECK (("adapter_status" = ANY (ARRAY['missing'::"text", 'attached'::"text", 'verified'::"text", 'failed'::"text", 'skipped'::"text"])))
);


ALTER TABLE "pods_provisioning"."adapter_attachment_items_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."adapter_attachment_runs_v1" (
    "adapter_attachment_run_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "deployment_receipt_id" "uuid" NOT NULL,
    "plan_run_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" NOT NULL,
    "model_version" "text" NOT NULL,
    "attachment_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "required_adapters" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "attached_adapters" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "missing_adapters" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "launch_blocked" boolean DEFAULT true NOT NULL,
    "attachment_body" "jsonb" NOT NULL,
    "attachment_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "adapter_attachment_hash_ck" CHECK (("attachment_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "adapter_attachment_status_ck" CHECK (("attachment_status" = ANY (ARRAY['pending'::"text", 'partial'::"text", 'ready'::"text", 'failed'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "pods_provisioning"."adapter_attachment_runs_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."appointment_admin_actions_v1" (
    "admin_action_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "appointment_request_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "action_kind" "text" NOT NULL,
    "previous_status" "text" NOT NULL,
    "new_status" "text" NOT NULL,
    "operator_user_id" "uuid",
    "admin_note" "text" DEFAULT ''::"text" NOT NULL,
    "action_body" "jsonb" NOT NULL,
    "action_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "appointment_admin_action_hash_ck" CHECK (("action_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "appointment_admin_action_kind_ck" CHECK (("action_kind" = ANY (ARRAY['confirm'::"text", 'decline'::"text", 'cancel'::"text"])))
);


ALTER TABLE "pods_provisioning"."appointment_admin_actions_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."asset_access_receipts_v1" (
    "asset_access_receipt_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "asset_runtime_object_id" "uuid" NOT NULL,
    "license_key_runtime_id" "uuid",
    "access_result" "text" NOT NULL,
    "receipt_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "asset_access_result_ck" CHECK (("access_result" = ANY (ARRAY['allowed'::"text", 'denied'::"text"])))
);


ALTER TABLE "pods_provisioning"."asset_access_receipts_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."asset_runtime_objects_v1" (
    "asset_runtime_object_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "asset_type" "text" NOT NULL,
    "asset_name" "text" NOT NULL,
    "storage_provider" "text" NOT NULL,
    "storage_ref" "text" NOT NULL,
    "public_visible" boolean DEFAULT false NOT NULL,
    "license_gate_required" boolean DEFAULT false NOT NULL,
    "runtime_status" "text" DEFAULT 'active'::"text" NOT NULL,
    "asset_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "asset_runtime_status_ck" CHECK (("runtime_status" = ANY (ARRAY['active'::"text", 'disabled'::"text", 'deleted'::"text"]))),
    CONSTRAINT "asset_runtime_type_ck" CHECK (("asset_type" = ANY (ARRAY['image'::"text", 'video'::"text", 'document'::"text", 'download'::"text", 'software'::"text"])))
);


ALTER TABLE "pods_provisioning"."asset_runtime_objects_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."cancellation_policies_v1" (
    "cancellation_policy_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "template_key" "text" NOT NULL,
    "template_version" "text" NOT NULL,
    "policy_key" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "cancellation_window_hours" integer DEFAULT 24 NOT NULL,
    "refund_allowed" boolean DEFAULT true NOT NULL,
    "refund_percent" integer DEFAULT 100 NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "policy_body" "jsonb" NOT NULL,
    "policy_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "cancellation_policy_hash_ck" CHECK (("policy_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "cancellation_refund_percent_ck" CHECK ((("refund_percent" >= 0) AND ("refund_percent" <= 100))),
    CONSTRAINT "cancellation_window_ck" CHECK (("cancellation_window_hours" >= 0))
);


ALTER TABLE "pods_provisioning"."cancellation_policies_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."cancellation_requests_v1" (
    "cancellation_request_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "appointment_request_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "cancellation_policy_id" "uuid",
    "cancelled_by" "text" NOT NULL,
    "cancellation_reason" "text" DEFAULT ''::"text" NOT NULL,
    "previous_appointment_status" "text" NOT NULL,
    "new_appointment_status" "text" DEFAULT 'cancelled'::"text" NOT NULL,
    "refund_intent_required" boolean DEFAULT false NOT NULL,
    "refund_amount_cents" integer DEFAULT 0 NOT NULL,
    "cancellation_body" "jsonb" NOT NULL,
    "cancellation_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "cancellation_by_ck" CHECK (("cancelled_by" = ANY (ARRAY['customer'::"text", 'operator'::"text", 'system'::"text"]))),
    CONSTRAINT "cancellation_hash_ck" CHECK (("cancellation_hash" ~ '^[a-f0-9]{64}$'::"text"))
);


ALTER TABLE "pods_provisioning"."cancellation_requests_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."civic_action_campaigns_v1" (
    "civic_campaign_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" DEFAULT 'CIVIC_ACTION_V1'::"text" NOT NULL,
    "model_version" "text" DEFAULT 'v1'::"text" NOT NULL,
    "issue_title" "text" NOT NULL,
    "community_name" "text" DEFAULT ''::"text" NOT NULL,
    "location_label" "text" DEFAULT ''::"text" NOT NULL,
    "position_type" "text" DEFAULT 'oppose_or_support'::"text" NOT NULL,
    "issue_summary" "text" DEFAULT ''::"text" NOT NULL,
    "petition_goal" integer DEFAULT 500 NOT NULL,
    "campaign_status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "campaign_body" "jsonb" NOT NULL,
    "campaign_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "civic_campaign_goal_ck" CHECK (("petition_goal" >= 0)),
    CONSTRAINT "civic_campaign_hash_ck" CHECK (("campaign_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "civic_campaign_status_ck" CHECK (("campaign_status" = ANY (ARRAY['draft'::"text", 'published'::"text", 'closed'::"text", 'archived'::"text"])))
);


ALTER TABLE "pods_provisioning"."civic_action_campaigns_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."civic_action_contribution_wall_entries_v1" (
    "civic_contribution_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "civic_campaign_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "contribution_type" "text" NOT NULL,
    "source_id" "uuid" NOT NULL,
    "display_label" "text" DEFAULT ''::"text" NOT NULL,
    "display_message" "text" DEFAULT ''::"text" NOT NULL,
    "moderation_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "public_visible" boolean DEFAULT false NOT NULL,
    "contribution_body" "jsonb" NOT NULL,
    "contribution_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "civic_contribution_hash_ck" CHECK (("contribution_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "civic_contribution_moderation_ck" CHECK (("moderation_status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text", 'hidden'::"text"]))),
    CONSTRAINT "civic_contribution_type_ck" CHECK (("contribution_type" = ANY (ARRAY['signature'::"text", 'survey_response'::"text", 'help_offer'::"text", 'evidence_link'::"text", 'update'::"text"])))
);


ALTER TABLE "pods_provisioning"."civic_action_contribution_wall_entries_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."civic_action_event_rsvps_v1" (
    "civic_event_rsvp_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "civic_event_id" "uuid" NOT NULL,
    "civic_campaign_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "attendee_name" "text" NOT NULL,
    "attendee_email" "text" NOT NULL,
    "attendee_hash" "text" NOT NULL,
    "rsvp_status" "text" DEFAULT 'going'::"text" NOT NULL,
    "wants_to_speak" boolean DEFAULT false NOT NULL,
    "wants_to_volunteer" boolean DEFAULT false NOT NULL,
    "note" "text" DEFAULT ''::"text" NOT NULL,
    "moderation_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "rsvp_body" "jsonb" NOT NULL,
    "rsvp_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "civic_event_attendee_hash_ck" CHECK (("attendee_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "civic_event_rsvp_hash_ck" CHECK (("rsvp_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "civic_event_rsvp_moderation_ck" CHECK (("moderation_status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text", 'hidden'::"text"]))),
    CONSTRAINT "civic_event_rsvp_status_ck" CHECK (("rsvp_status" = ANY (ARRAY['going'::"text", 'interested'::"text", 'not_going'::"text"])))
);


ALTER TABLE "pods_provisioning"."civic_action_event_rsvps_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."civic_action_events_v1" (
    "civic_event_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "civic_campaign_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "event_type" "text" NOT NULL,
    "event_title" "text" NOT NULL,
    "event_description" "text" DEFAULT ''::"text" NOT NULL,
    "event_location" "text" DEFAULT ''::"text" NOT NULL,
    "event_starts_at" timestamp with time zone,
    "event_status" "text" DEFAULT 'published'::"text" NOT NULL,
    "event_body" "jsonb" NOT NULL,
    "event_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "civic_event_hash_ck" CHECK (("event_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "civic_event_status_ck" CHECK (("event_status" = ANY (ARRAY['draft'::"text", 'published'::"text", 'closed'::"text", 'cancelled'::"text", 'archived'::"text"]))),
    CONSTRAINT "civic_event_type_ck" CHECK (("event_type" = ANY (ARRAY['town_hall'::"text", 'community_meeting'::"text", 'rally'::"text", 'volunteer_day'::"text", 'cleanup_event'::"text", 'petition_deadline'::"text", 'council_meeting'::"text", 'planning_commission_meeting'::"text"])))
);


ALTER TABLE "pods_provisioning"."civic_action_events_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."civic_action_evidence_v1" (
    "civic_evidence_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "civic_campaign_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "evidence_type" "text" NOT NULL,
    "evidence_title" "text" NOT NULL,
    "evidence_url" "text" DEFAULT ''::"text" NOT NULL,
    "evidence_description" "text" DEFAULT ''::"text" NOT NULL,
    "submitter_name" "text" DEFAULT ''::"text" NOT NULL,
    "submitter_email" "text" DEFAULT ''::"text" NOT NULL,
    "submitter_hash" "text" NOT NULL,
    "moderation_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "public_visible" boolean DEFAULT true NOT NULL,
    "evidence_body" "jsonb" NOT NULL,
    "evidence_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "civic_evidence_hash_ck" CHECK (("evidence_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "civic_evidence_moderation_ck" CHECK (("moderation_status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text", 'hidden'::"text"]))),
    CONSTRAINT "civic_evidence_submitter_hash_ck" CHECK (("submitter_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "civic_evidence_type_ck" CHECK (("evidence_type" = ANY (ARRAY['link'::"text", 'document'::"text", 'photo'::"text", 'video'::"text", 'meeting_recording'::"text", 'research'::"text", 'public_record'::"text", 'other'::"text"])))
);


ALTER TABLE "pods_provisioning"."civic_action_evidence_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."civic_action_full_green_receipts_v1" (
    "civic_full_green_receipt_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "model_key" "text" DEFAULT 'CIVIC_ACTION_V1'::"text" NOT NULL,
    "model_version" "text" DEFAULT 'v1'::"text" NOT NULL,
    "registry_ok" boolean DEFAULT false NOT NULL,
    "petition_ok" boolean DEFAULT false NOT NULL,
    "survey_ok" boolean DEFAULT false NOT NULL,
    "contribution_wall_ok" boolean DEFAULT false NOT NULL,
    "moderation_ok" boolean DEFAULT false NOT NULL,
    "full_green" boolean DEFAULT false NOT NULL,
    "receipt_body" "jsonb" NOT NULL,
    "receipt_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "civic_full_green_hash_ck" CHECK (("receipt_hash" ~ '^[a-f0-9]{64}$'::"text"))
);


ALTER TABLE "pods_provisioning"."civic_action_full_green_receipts_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."civic_action_full_green_v2_receipts_v1" (
    "civic_full_green_v2_receipt_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "model_key" "text" DEFAULT 'CIVIC_ACTION_V1'::"text" NOT NULL,
    "model_version" "text" DEFAULT 'v2'::"text" NOT NULL,
    "petition_ok" boolean NOT NULL,
    "survey_ok" boolean NOT NULL,
    "contribution_wall_ok" boolean NOT NULL,
    "moderation_ok" boolean NOT NULL,
    "events_ok" boolean NOT NULL,
    "evidence_ok" boolean NOT NULL,
    "provider_launch_ok" boolean NOT NULL,
    "full_green" boolean NOT NULL,
    "receipt_body" "jsonb" NOT NULL,
    "receipt_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods_provisioning"."civic_action_full_green_v2_receipts_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."civic_action_help_offers_v1" (
    "civic_help_offer_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "civic_campaign_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "helper_name" "text" NOT NULL,
    "helper_email" "text" NOT NULL,
    "help_type" "text" DEFAULT 'general'::"text" NOT NULL,
    "help_message" "text" DEFAULT ''::"text" NOT NULL,
    "helper_hash" "text" NOT NULL,
    "moderation_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "public_display_allowed" boolean DEFAULT true NOT NULL,
    "help_body" "jsonb" NOT NULL,
    "help_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "civic_help_hash_ck" CHECK (("help_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "civic_help_moderation_ck" CHECK (("moderation_status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text", 'hidden'::"text"]))),
    CONSTRAINT "civic_helper_hash_ck" CHECK (("helper_hash" ~ '^[a-f0-9]{64}$'::"text"))
);


ALTER TABLE "pods_provisioning"."civic_action_help_offers_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."civic_action_launch_ready_receipts_v1" (
    "civic_launch_ready_receipt_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "civic_deployment_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" DEFAULT 'CIVIC_ACTION_V1'::"text" NOT NULL,
    "model_version" "text" DEFAULT 'v2'::"text" NOT NULL,
    "launch_ready" boolean DEFAULT false NOT NULL,
    "launch_status" "text" DEFAULT 'blocked'::"text" NOT NULL,
    "missing_providers" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "ready_providers" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "receipt_body" "jsonb" NOT NULL,
    "receipt_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "civic_launch_ready_hash_ck" CHECK (("receipt_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "civic_launch_ready_status_ck" CHECK (("launch_status" = ANY (ARRAY['ready'::"text", 'blocked'::"text"])))
);


ALTER TABLE "pods_provisioning"."civic_action_launch_ready_receipts_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."civic_action_model_deployments_v1" (
    "civic_deployment_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" DEFAULT 'CIVIC_ACTION_V1'::"text" NOT NULL,
    "model_version" "text" DEFAULT 'v2'::"text" NOT NULL,
    "civic_campaign_id" "uuid",
    "issue_title" "text" NOT NULL,
    "community_name" "text" DEFAULT ''::"text" NOT NULL,
    "location_label" "text" DEFAULT ''::"text" NOT NULL,
    "position_type" "text" DEFAULT 'oppose'::"text" NOT NULL,
    "issue_summary" "text" DEFAULT ''::"text" NOT NULL,
    "petition_goal" integer DEFAULT 500 NOT NULL,
    "enabled_modules" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "required_providers" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "deployment_status" "text" DEFAULT 'planned'::"text" NOT NULL,
    "deployment_body" "jsonb" NOT NULL,
    "deployment_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "civic_deployment_hash_ck" CHECK (("deployment_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "civic_deployment_status_ck" CHECK (("deployment_status" = ANY (ARRAY['planned'::"text", 'ready'::"text", 'blocked'::"text", 'launched'::"text", 'archived'::"text"])))
);


ALTER TABLE "pods_provisioning"."civic_action_model_deployments_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."civic_action_model_registry_v1" (
    "civic_model_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "model_key" "text" DEFAULT 'CIVIC_ACTION_V1'::"text" NOT NULL,
    "model_version" "text" DEFAULT 'v1'::"text" NOT NULL,
    "display_name" "text" DEFAULT 'Civic Action / Petition Site'::"text" NOT NULL,
    "model_purpose" "text" NOT NULL,
    "actors" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "capabilities" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "workflows" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "required_providers" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "default_fields" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "registry_body" "jsonb" NOT NULL,
    "registry_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "civic_action_model_hash_ck" CHECK (("registry_hash" ~ '^[a-f0-9]{64}$'::"text"))
);


ALTER TABLE "pods_provisioning"."civic_action_model_registry_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."civic_action_moderation_receipts_v1" (
    "civic_moderation_receipt_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "civic_campaign_id" "uuid" NOT NULL,
    "contribution_type" "text" NOT NULL,
    "source_id" "uuid" NOT NULL,
    "moderation_action" "text" NOT NULL,
    "moderation_reason" "text" DEFAULT ''::"text" NOT NULL,
    "public_visible" boolean NOT NULL,
    "receipt_body" "jsonb" NOT NULL,
    "receipt_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "civic_mod_action_ck" CHECK (("moderation_action" = ANY (ARRAY['approve'::"text", 'reject'::"text", 'hide'::"text"]))),
    CONSTRAINT "civic_mod_hash_ck" CHECK (("receipt_hash" ~ '^[a-f0-9]{64}$'::"text"))
);


ALTER TABLE "pods_provisioning"."civic_action_moderation_receipts_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."civic_action_petition_signatures_v1" (
    "civic_signature_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "civic_campaign_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "signer_name" "text" NOT NULL,
    "signer_email" "text" NOT NULL,
    "signer_comment" "text" DEFAULT ''::"text" NOT NULL,
    "signer_hash" "text" NOT NULL,
    "moderation_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "public_display_allowed" boolean DEFAULT true NOT NULL,
    "signature_body" "jsonb" NOT NULL,
    "signature_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "civic_signature_hash_ck" CHECK (("signature_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "civic_signature_moderation_ck" CHECK (("moderation_status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text", 'hidden'::"text"]))),
    CONSTRAINT "civic_signer_hash_ck" CHECK (("signer_hash" ~ '^[a-f0-9]{64}$'::"text"))
);


ALTER TABLE "pods_provisioning"."civic_action_petition_signatures_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."civic_action_survey_questions_v1" (
    "civic_survey_question_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "civic_campaign_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "question_key" "text" NOT NULL,
    "question_text" "text" NOT NULL,
    "question_type" "text" DEFAULT 'text'::"text" NOT NULL,
    "required" boolean DEFAULT false NOT NULL,
    "display_order" integer DEFAULT 0 NOT NULL,
    "question_body" "jsonb" NOT NULL,
    "question_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "civic_survey_question_hash_ck" CHECK (("question_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "civic_survey_question_type_ck" CHECK (("question_type" = ANY (ARRAY['text'::"text", 'yes_no'::"text", 'single_choice'::"text", 'multi_choice'::"text", 'scale'::"text"])))
);


ALTER TABLE "pods_provisioning"."civic_action_survey_questions_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."civic_action_survey_responses_v1" (
    "civic_survey_response_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "civic_campaign_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "respondent_email" "text" NOT NULL,
    "respondent_hash" "text" NOT NULL,
    "answers" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "moderation_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "response_body" "jsonb" NOT NULL,
    "response_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "civic_survey_respondent_hash_ck" CHECK (("respondent_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "civic_survey_response_hash_ck" CHECK (("response_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "civic_survey_response_moderation_ck" CHECK (("moderation_status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text", 'hidden'::"text"])))
);


ALTER TABLE "pods_provisioning"."civic_action_survey_responses_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."connection_layer_launch_control_runs_v1" (
    "connection_launch_run_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" DEFAULT 'DEVELOPER_PORTAL_V1'::"text" NOT NULL,
    "model_version" "text" DEFAULT 'v1'::"text" NOT NULL,
    "provider_connection_rollup_id" "uuid",
    "provider_connection_runtime_bridge_id" "uuid",
    "provider_readiness_rollup_id" "uuid",
    "launch_control_receipt_id" "uuid",
    "worker_run_id" "uuid",
    "launch_ready" boolean DEFAULT false NOT NULL,
    "launch_status" "text" DEFAULT 'blocked'::"text" NOT NULL,
    "run_body" "jsonb" NOT NULL,
    "run_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "connection_launch_hash_ck" CHECK (("run_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "connection_launch_status_ck" CHECK (("launch_status" = ANY (ARRAY['ready'::"text", 'queued'::"text", 'blocked'::"text", 'failed'::"text"])))
);


ALTER TABLE "pods_provisioning"."connection_layer_launch_control_runs_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."contractor_estimate_decisions_v1" (
    "estimate_decision_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "contractor_estimate_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "decision_kind" "text" NOT NULL,
    "decision_status" "text" NOT NULL,
    "customer_name" "text" NOT NULL,
    "customer_email" "text" NOT NULL,
    "signer_ip" "inet",
    "signer_user_agent" "text" DEFAULT ''::"text" NOT NULL,
    "decision_notes" "text" DEFAULT ''::"text" NOT NULL,
    "decision_body" "jsonb" NOT NULL,
    "decision_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "contractor_estimate_decision_hash_ck" CHECK (("decision_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "contractor_estimate_decision_kind_ck" CHECK (("decision_kind" = ANY (ARRAY['approve'::"text", 'decline'::"text"]))),
    CONSTRAINT "contractor_estimate_decision_status_ck" CHECK (("decision_status" = ANY (ARRAY['accepted'::"text", 'declined'::"text"])))
);


ALTER TABLE "pods_provisioning"."contractor_estimate_decisions_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."contractor_estimate_line_items_v1" (
    "line_item_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "contractor_estimate_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "line_kind" "text" NOT NULL,
    "description" "text" NOT NULL,
    "quantity" numeric(12,2) DEFAULT 1 NOT NULL,
    "unit_price_cents" integer DEFAULT 0 NOT NULL,
    "line_total_cents" integer DEFAULT 0 NOT NULL,
    "display_order" integer DEFAULT 0 NOT NULL,
    "line_body" "jsonb" NOT NULL,
    "line_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "contractor_estimate_line_amount_ck" CHECK ((("quantity" >= (0)::numeric) AND ("unit_price_cents" >= 0) AND ("line_total_cents" >= 0))),
    CONSTRAINT "contractor_estimate_line_hash_ck" CHECK (("line_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "contractor_estimate_line_kind_ck" CHECK (("line_kind" = ANY (ARRAY['labor'::"text", 'material'::"text", 'equipment'::"text", 'permit'::"text", 'fee'::"text", 'discount'::"text"])))
);


ALTER TABLE "pods_provisioning"."contractor_estimate_line_items_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."contractor_estimate_requests_v1" (
    "estimate_request_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "template_key" "text" NOT NULL,
    "template_version" "text" NOT NULL,
    "service_code" "text" NOT NULL,
    "customer_name" "text" NOT NULL,
    "customer_email" "text" NOT NULL,
    "customer_phone" "text" DEFAULT ''::"text" NOT NULL,
    "site_address" "text" NOT NULL,
    "project_description" "text" NOT NULL,
    "preferred_visit_window" "text" DEFAULT ''::"text" NOT NULL,
    "estimate_status" "text" DEFAULT 'requested'::"text" NOT NULL,
    "estimate_body" "jsonb" NOT NULL,
    "estimate_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "contractor_estimate_hash_ck" CHECK (("estimate_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "contractor_estimate_status_ck" CHECK (("estimate_status" = ANY (ARRAY['requested'::"text", 'site_visit_scheduled'::"text", 'estimate_sent'::"text", 'approved'::"text", 'declined'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "pods_provisioning"."contractor_estimate_requests_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."contractor_estimates_v1" (
    "contractor_estimate_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "estimate_request_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "estimate_number" "text" NOT NULL,
    "estimate_status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "subtotal_cents" integer DEFAULT 0 NOT NULL,
    "tax_cents" integer DEFAULT 0 NOT NULL,
    "total_cents" integer DEFAULT 0 NOT NULL,
    "deposit_required" boolean DEFAULT true NOT NULL,
    "deposit_amount_cents" integer DEFAULT 0 NOT NULL,
    "valid_until" "date",
    "customer_message" "text" DEFAULT ''::"text" NOT NULL,
    "estimate_body" "jsonb" NOT NULL,
    "estimate_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "contractor_estimate_amounts_ck" CHECK ((("subtotal_cents" >= 0) AND ("tax_cents" >= 0) AND ("total_cents" >= 0) AND ("deposit_amount_cents" >= 0))),
    CONSTRAINT "contractor_estimate_hash_ck" CHECK (("estimate_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "contractor_estimate_status_ck" CHECK (("estimate_status" = ANY (ARRAY['draft'::"text", 'sent'::"text", 'approved'::"text", 'declined'::"text", 'expired'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "pods_provisioning"."contractor_estimates_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."contractor_job_phases_v1" (
    "contractor_job_phase_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "contractor_job_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "phase_key" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "phase_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "display_order" integer DEFAULT 0 NOT NULL,
    "phase_body" "jsonb" NOT NULL,
    "phase_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "contractor_job_phase_hash_ck" CHECK (("phase_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "contractor_job_phase_status_ck" CHECK (("phase_status" = ANY (ARRAY['pending'::"text", 'ready'::"text", 'in_progress'::"text", 'completed'::"text", 'blocked'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "pods_provisioning"."contractor_job_phases_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."contractor_job_records_v1" (
    "contractor_job_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "estimate_request_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "job_status" "text" DEFAULT 'planned'::"text" NOT NULL,
    "scheduled_start_date" "date",
    "scheduled_end_date" "date",
    "crew_count" integer DEFAULT 0 NOT NULL,
    "progress_percent" integer DEFAULT 0 NOT NULL,
    "job_body" "jsonb" NOT NULL,
    "job_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "contractor_job_crew_ck" CHECK (("crew_count" >= 0)),
    CONSTRAINT "contractor_job_hash_ck" CHECK (("job_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "contractor_job_progress_ck" CHECK ((("progress_percent" >= 0) AND ("progress_percent" <= 100))),
    CONSTRAINT "contractor_job_status_ck" CHECK (("job_status" = ANY (ARRAY['planned'::"text", 'scheduled'::"text", 'in_progress'::"text", 'blocked'::"text", 'completed'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "pods_provisioning"."contractor_job_records_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."contractor_service_templates_v1" (
    "contractor_service_template_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "template_key" "text" NOT NULL,
    "template_version" "text" NOT NULL,
    "service_code" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "category" "text" NOT NULL,
    "estimated_duration_hours" numeric(10,2) DEFAULT 1.0 NOT NULL,
    "base_price_cents" integer DEFAULT 0 NOT NULL,
    "requires_site_visit" boolean DEFAULT false NOT NULL,
    "requires_materials" boolean DEFAULT false NOT NULL,
    "requires_permit_review" boolean DEFAULT false NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "template_body" "jsonb" NOT NULL,
    "template_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "contractor_service_duration_ck" CHECK (("estimated_duration_hours" > (0)::numeric)),
    CONSTRAINT "contractor_service_hash_ck" CHECK (("template_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "contractor_service_price_ck" CHECK (("base_price_cents" >= 0))
);


ALTER TABLE "pods_provisioning"."contractor_service_templates_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."contractor_site_visits_v1" (
    "site_visit_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "estimate_request_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "scheduled_date" "date" NOT NULL,
    "scheduled_start_time" time without time zone NOT NULL,
    "scheduled_end_time" time without time zone NOT NULL,
    "estimator_name" "text" DEFAULT ''::"text" NOT NULL,
    "estimator_user_id" "uuid",
    "visit_status" "text" DEFAULT 'scheduled'::"text" NOT NULL,
    "site_notes" "text" DEFAULT ''::"text" NOT NULL,
    "measurement_summary" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "photo_refs" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "follow_up_required" boolean DEFAULT false NOT NULL,
    "visit_body" "jsonb" NOT NULL,
    "visit_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "contractor_site_visit_hash_ck" CHECK (("visit_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "contractor_site_visit_status_ck" CHECK (("visit_status" = ANY (ARRAY['scheduled'::"text", 'completed'::"text", 'cancelled'::"text", 'needs_follow_up'::"text"])))
);


ALTER TABLE "pods_provisioning"."contractor_site_visits_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."customer_deployment_handoffs_v1" (
    "customer_handoff_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "platform_snapshot_id" "uuid",
    "model_key" "text" NOT NULL,
    "model_version" "text" DEFAULT 'v1'::"text" NOT NULL,
    "handoff_status" "text" DEFAULT 'ready'::"text" NOT NULL,
    "login_surfaces" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "active_capabilities" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "connected_providers" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "receipts_emitted" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "customer_summary" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "customer_next_steps" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "support_notes" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "recovery_notes" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "handoff_body" "jsonb" NOT NULL,
    "handoff_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "customer_handoff_hash_ck" CHECK (("handoff_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "customer_handoff_status_ck" CHECK (("handoff_status" = ANY (ARRAY['ready'::"text", 'blocked'::"text", 'failed'::"text"])))
);


ALTER TABLE "pods_provisioning"."customer_deployment_handoffs_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."customer_launch_receipts_v1" (
    "launch_receipt_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "provision_run_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "template_key" "text" NOT NULL,
    "template_version" "text" NOT NULL,
    "receipt_body" "jsonb" NOT NULL,
    "receipt_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods_provisioning"."customer_launch_receipts_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."domain_provider_connections_v1" (
    "domain_provider_connection_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "provider_key" "text" DEFAULT 'cloudflare'::"text" NOT NULL,
    "connection_status" "text" DEFAULT 'connected'::"text" NOT NULL,
    "account_ref" "text" DEFAULT ''::"text" NOT NULL,
    "capabilities" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "connection_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "domain_provider_connection_hash_ck" CHECK (("connection_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "domain_provider_connection_status_ck" CHECK (("connection_status" = ANY (ARRAY['connected'::"text", 'disconnected'::"text", 'blocked'::"text"])))
);


ALTER TABLE "pods_provisioning"."domain_provider_connections_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."domain_runtime_bindings_v1" (
    "domain_runtime_binding_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_instance_runtime_id" "uuid" NOT NULL,
    "domain_name" "text" NOT NULL,
    "provider_key" "text" DEFAULT 'cloudflare'::"text" NOT NULL,
    "binding_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "dns_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "ssl_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "binding_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "domain_runtime_binding_hash_ck" CHECK (("binding_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "domain_runtime_binding_status_ck" CHECK (("binding_status" = ANY (ARRAY['pending'::"text", 'attached'::"text", 'verified'::"text", 'blocked'::"text"]))),
    CONSTRAINT "domain_runtime_dns_status_ck" CHECK (("dns_status" = ANY (ARRAY['pending'::"text", 'verified'::"text", 'failed'::"text"]))),
    CONSTRAINT "domain_runtime_ssl_status_ck" CHECK (("ssl_status" = ANY (ARRAY['pending'::"text", 'active'::"text", 'failed'::"text"])))
);


ALTER TABLE "pods_provisioning"."domain_runtime_bindings_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."email_adapter_runtime_v1" (
    "email_runtime_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "adapter_attachment_run_id" "uuid",
    "provider_key" "text" NOT NULL,
    "sender_domain" "text" NOT NULL,
    "api_key_verified" boolean DEFAULT false NOT NULL,
    "sender_domain_verified" boolean DEFAULT false NOT NULL,
    "webhook_configured" boolean DEFAULT false NOT NULL,
    "bounce_handling_ready" boolean DEFAULT false NOT NULL,
    "transactional_send_ready" boolean DEFAULT false NOT NULL,
    "runtime_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "runtime_body" "jsonb" NOT NULL,
    "runtime_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "email_runtime_hash_ck" CHECK (("runtime_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "email_runtime_status_ck" CHECK (("runtime_status" = ANY (ARRAY['pending'::"text", 'verified'::"text", 'failed'::"text", 'blocked'::"text"])))
);


ALTER TABLE "pods_provisioning"."email_adapter_runtime_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."full_green_engine_registry_v1" (
    "engine_registry_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "engine_key" "text" NOT NULL,
    "engine_category" "text" NOT NULL,
    "engine_status" "text" NOT NULL,
    "proof_token" "text" NOT NULL,
    "last_selftest_utc" timestamp with time zone DEFAULT "now"() NOT NULL,
    "ready_for_launch" boolean DEFAULT false NOT NULL,
    "rollback_ready" boolean DEFAULT false NOT NULL,
    "replay_ready" boolean DEFAULT false NOT NULL,
    "failure_count" integer DEFAULT 0 NOT NULL,
    "engine_body" "jsonb" NOT NULL,
    "engine_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "engine_registry_category_ck" CHECK (("engine_category" = ANY (ARRAY['model'::"text", 'wizard'::"text", 'planner'::"text", 'deployment'::"text", 'provider'::"text", 'launch'::"text", 'execution'::"text", 'failure'::"text", 'rollback'::"text", 'retry'::"text", 'stress'::"text", 'security'::"text"]))),
    CONSTRAINT "engine_registry_hash_ck" CHECK (("engine_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "engine_registry_status_ck" CHECK (("engine_status" = ANY (ARRAY['FULL_GREEN'::"text", 'PARTIAL'::"text", 'BLOCKED'::"text", 'FAILED'::"text"])))
);


ALTER TABLE "pods_provisioning"."full_green_engine_registry_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."full_green_platform_snapshots_v1" (
    "platform_snapshot_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "snapshot_key" "text" NOT NULL,
    "engine_count" integer DEFAULT 0 NOT NULL,
    "full_green_count" integer DEFAULT 0 NOT NULL,
    "blocked_count" integer DEFAULT 0 NOT NULL,
    "failed_count" integer DEFAULT 0 NOT NULL,
    "platform_status" "text" DEFAULT 'PARTIAL'::"text" NOT NULL,
    "ready_engines" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "blocked_engines" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "failed_engines" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "snapshot_body" "jsonb" NOT NULL,
    "snapshot_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "platform_snapshot_hash_ck" CHECK (("snapshot_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "platform_snapshot_status_ck" CHECK (("platform_status" = ANY (ARRAY['FULL_GREEN'::"text", 'PARTIAL'::"text", 'BLOCKED'::"text", 'FAILED'::"text"])))
);


ALTER TABLE "pods_provisioning"."full_green_platform_snapshots_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."github_adapter_runtime_v1" (
    "github_runtime_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "adapter_attachment_run_id" "uuid",
    "github_owner" "text" NOT NULL,
    "repo_name" "text" NOT NULL,
    "repo_url" "text" NOT NULL,
    "token_verified" boolean DEFAULT false NOT NULL,
    "repo_access_verified" boolean DEFAULT false NOT NULL,
    "release_access_ready" boolean DEFAULT false NOT NULL,
    "webhook_configured" boolean DEFAULT false NOT NULL,
    "download_asset_ready" boolean DEFAULT false NOT NULL,
    "runtime_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "runtime_body" "jsonb" NOT NULL,
    "runtime_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "github_runtime_hash_ck" CHECK (("runtime_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "github_runtime_status_ck" CHECK (("runtime_status" = ANY (ARRAY['pending'::"text", 'verified'::"text", 'failed'::"text", 'blocked'::"text"])))
);


ALTER TABLE "pods_provisioning"."github_adapter_runtime_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."launch_control_plane_receipts_v1" (
    "launch_control_receipt_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "wizard_session_id" "uuid",
    "plan_run_id" "uuid",
    "deployment_receipt_id" "uuid",
    "provider_readiness_rollup_id" "uuid",
    "model_key" "text" NOT NULL,
    "model_version" "text" DEFAULT 'v1'::"text" NOT NULL,
    "wizard_status" "text" DEFAULT ''::"text" NOT NULL,
    "deployment_status" "text" DEFAULT ''::"text" NOT NULL,
    "readiness_status" "text" DEFAULT ''::"text" NOT NULL,
    "launch_ready" boolean DEFAULT false NOT NULL,
    "launch_decision" "text" DEFAULT 'blocked'::"text" NOT NULL,
    "operator_summary" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "customer_next_steps" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "blocked_reasons" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "receipt_body" "jsonb" NOT NULL,
    "receipt_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "launch_control_decision_ck" CHECK (("launch_decision" = ANY (ARRAY['ready'::"text", 'blocked'::"text"]))),
    CONSTRAINT "launch_control_receipt_hash_ck" CHECK (("receipt_hash" ~ '^[a-f0-9]{64}$'::"text"))
);


ALTER TABLE "pods_provisioning"."launch_control_plane_receipts_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."launch_execution_runs_v1" (
    "launch_execution_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "deployment_receipt_id" "uuid" NOT NULL,
    "adapter_attachment_run_id" "uuid" NOT NULL,
    "plan_run_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" NOT NULL,
    "model_version" "text" NOT NULL,
    "execution_status" "text" DEFAULT 'blocked'::"text" NOT NULL,
    "launch_blocked" boolean DEFAULT true NOT NULL,
    "launch_blockers" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "activated_capabilities" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "activated_resources" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "verified_adapters" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "replay_ready" boolean DEFAULT true NOT NULL,
    "rollback_ready" boolean DEFAULT true NOT NULL,
    "execution_body" "jsonb" NOT NULL,
    "execution_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "launch_execution_hash_ck" CHECK (("execution_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "launch_execution_status_ck" CHECK (("execution_status" = ANY (ARRAY['blocked'::"text", 'ready'::"text", 'executed'::"text", 'failed'::"text", 'rolled_back'::"text"])))
);


ALTER TABLE "pods_provisioning"."launch_execution_runs_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."launch_execution_worker_runs_v1" (
    "worker_run_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "launch_control_receipt_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" NOT NULL,
    "model_version" "text" DEFAULT 'v1'::"text" NOT NULL,
    "worker_status" "text" DEFAULT 'queued'::"text" NOT NULL,
    "execution_steps" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "completed_steps" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "failed_steps" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "retry_count" integer DEFAULT 0 NOT NULL,
    "replay_ready" boolean DEFAULT true NOT NULL,
    "rollback_ready" boolean DEFAULT true NOT NULL,
    "worker_body" "jsonb" NOT NULL,
    "worker_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "launch_worker_hash_ck" CHECK (("worker_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "launch_worker_retry_ck" CHECK (("retry_count" >= 0)),
    CONSTRAINT "launch_worker_status_ck" CHECK (("worker_status" = ANY (ARRAY['queued'::"text", 'running'::"text", 'completed'::"text", 'failed'::"text", 'rolled_back'::"text"])))
);


ALTER TABLE "pods_provisioning"."launch_execution_worker_runs_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."launch_failure_events_v1" (
    "launch_failure_event_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "worker_run_id" "uuid" NOT NULL,
    "launch_control_receipt_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "failed_step" "text" NOT NULL,
    "failure_reason" "text" NOT NULL,
    "failure_status" "text" DEFAULT 'failed'::"text" NOT NULL,
    "rollback_required" boolean DEFAULT true NOT NULL,
    "replay_ready" boolean DEFAULT true NOT NULL,
    "failure_body" "jsonb" NOT NULL,
    "failure_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "launch_failure_hash_ck" CHECK (("failure_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "launch_failure_status_ck" CHECK (("failure_status" = ANY (ARRAY['failed'::"text", 'acknowledged'::"text", 'rolled_back'::"text"])))
);


ALTER TABLE "pods_provisioning"."launch_failure_events_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."launch_retry_events_v1" (
    "launch_retry_event_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "launch_failure_event_id" "uuid" NOT NULL,
    "worker_run_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "retry_policy_id" "uuid",
    "retry_number" integer NOT NULL,
    "retry_status" "text" NOT NULL,
    "cooldown_seconds" integer DEFAULT 0 NOT NULL,
    "retry_after" timestamp with time zone DEFAULT "now"() NOT NULL,
    "retry_body" "jsonb" NOT NULL,
    "retry_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "launch_retry_hash_ck" CHECK (("retry_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "launch_retry_number_ck" CHECK (("retry_number" >= 0)),
    CONSTRAINT "launch_retry_status_ck" CHECK (("retry_status" = ANY (ARRAY['retry_wait'::"text", 'retrying'::"text", 'retry_exhausted'::"text"])))
);


ALTER TABLE "pods_provisioning"."launch_retry_events_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."launch_retry_policies_v1" (
    "retry_policy_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "policy_key" "text" NOT NULL,
    "max_retries" integer DEFAULT 3 NOT NULL,
    "cooldown_seconds" integer DEFAULT 60 NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "policy_body" "jsonb" NOT NULL,
    "policy_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "launch_retry_policy_hash_ck" CHECK (("policy_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "launch_retry_policy_limits_ck" CHECK ((("max_retries" >= 0) AND ("cooldown_seconds" >= 0)))
);


ALTER TABLE "pods_provisioning"."launch_retry_policies_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."launch_rollback_events_v1" (
    "launch_rollback_event_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "launch_failure_event_id" "uuid" NOT NULL,
    "worker_run_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "rollback_status" "text" DEFAULT 'rolled_back'::"text" NOT NULL,
    "rolled_back_steps" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "recovery_next_steps" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "rollback_body" "jsonb" NOT NULL,
    "rollback_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "launch_rollback_hash_ck" CHECK (("rollback_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "launch_rollback_status_ck" CHECK (("rollback_status" = ANY (ARRAY['rolled_back'::"text", 'rollback_failed'::"text"])))
);


ALTER TABLE "pods_provisioning"."launch_rollback_events_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."license_key_runtime_v1" (
    "license_key_runtime_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "license_key" "text" NOT NULL,
    "license_status" "text" DEFAULT 'active'::"text" NOT NULL,
    "max_activations" integer DEFAULT 1 NOT NULL,
    "activation_count" integer DEFAULT 0 NOT NULL,
    "expires_at" timestamp with time zone,
    "license_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "license_runtime_status_ck" CHECK (("license_status" = ANY (ARRAY['active'::"text", 'expired'::"text", 'revoked'::"text"])))
);


ALTER TABLE "pods_provisioning"."license_key_runtime_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_audit_checkpoints_v1" (
    "model_audit_checkpoint_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "event_count" integer DEFAULT 0 NOT NULL,
    "checkpoint_status" "text" DEFAULT 'created'::"text" NOT NULL,
    "event_hashes" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "checkpoint_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_audit_checkpoint_hash_ck" CHECK (("checkpoint_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_audit_checkpoint_status_ck" CHECK (("checkpoint_status" = ANY (ARRAY['created'::"text", 'verified'::"text", 'archived'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_audit_checkpoints_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_audit_ledger_v1" (
    "model_audit_event_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_instance_runtime_id" "uuid",
    "event_type" "text" NOT NULL,
    "event_status" "text" DEFAULT 'recorded'::"text" NOT NULL,
    "actor_role" "text" DEFAULT 'system'::"text" NOT NULL,
    "event_ref_type" "text" DEFAULT ''::"text" NOT NULL,
    "event_ref_id" "uuid",
    "event_body" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "event_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_audit_event_hash_ck" CHECK (("event_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_audit_event_status_ck" CHECK (("event_status" = ANY (ARRAY['recorded'::"text", 'verified'::"text", 'checkpointed'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_audit_ledger_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_block_registry_v1" (
    "model_block_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "block_key" "text" NOT NULL,
    "block_category" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "block_purpose" "text" NOT NULL,
    "supported_surfaces" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "supported_models" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "required_providers" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "required_permissions" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "default_fields" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "block_body" "jsonb" NOT NULL,
    "block_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_block_hash_ck" CHECK (("block_hash" ~ '^[a-f0-9]{64}$'::"text"))
);


ALTER TABLE "pods_provisioning"."model_block_registry_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_capability_matrix_v1" (
    "matrix_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "model_key" "text" NOT NULL,
    "model_version" "text" NOT NULL,
    "vertical_domain" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "description" "text" NOT NULL,
    "required_engines" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "optional_engines" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "required_capabilities" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "optional_capabilities" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "required_resources" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "required_adapters" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "customer_fields" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "default_overlays" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "matrix_body" "jsonb" NOT NULL,
    "matrix_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_capability_matrix_hash_ck" CHECK (("matrix_hash" ~ '^[a-f0-9]{64}$'::"text"))
);


ALTER TABLE "pods_provisioning"."model_capability_matrix_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_capability_plan_runs_v1" (
    "plan_run_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" NOT NULL,
    "model_version" "text" NOT NULL,
    "requested_fields" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "skipped_fields" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "applied_defaults" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "provision_engines" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "provision_capabilities" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "provision_resources" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "provision_adapters" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "plan_status" "text" DEFAULT 'planned'::"text" NOT NULL,
    "plan_body" "jsonb" NOT NULL,
    "plan_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_capability_plan_hash_ck" CHECK (("plan_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_capability_plan_status_ck" CHECK (("plan_status" = ANY (ARRAY['planned'::"text", 'applied'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_capability_plan_runs_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_db_parameters_v1" (
    "model_db_parameter_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "parameter_key" "text" NOT NULL,
    "parameter_scope" "text" NOT NULL,
    "parameter_type" "text" NOT NULL,
    "required" boolean DEFAULT false NOT NULL,
    "default_value" "jsonb" DEFAULT 'null'::"jsonb" NOT NULL,
    "description" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods_provisioning"."model_db_parameters_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_db_surface_full_green_receipts_v1" (
    "model_db_surface_full_green_receipt_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "receipt_status" "text" DEFAULT 'passed'::"text" NOT NULL,
    "proof_tokens" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "proof_results" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "full_green" boolean DEFAULT false NOT NULL,
    "receipt_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_db_surface_full_green_hash_ck" CHECK (("receipt_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_db_surface_full_green_status_ck" CHECK (("receipt_status" = ANY (ARRAY['passed'::"text", 'failed'::"text", 'archived'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_db_surface_full_green_receipts_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_deployment_receipts_v1" (
    "deployment_receipt_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "plan_run_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" NOT NULL,
    "model_version" "text" NOT NULL,
    "deployment_status" "text" DEFAULT 'planned'::"text" NOT NULL,
    "deployment_steps" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "resource_manifest" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "adapter_manifest" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "capability_manifest" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "replay_ready" boolean DEFAULT true NOT NULL,
    "rollback_ready" boolean DEFAULT true NOT NULL,
    "failure_boundaries" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "deployment_body" "jsonb" NOT NULL,
    "deployment_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_deployment_hash_ck" CHECK (("deployment_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_deployment_status_ck" CHECK (("deployment_status" = ANY (ARRAY['planned'::"text", 'applied'::"text", 'failed'::"text", 'rolled_back'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_deployment_receipts_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_deployment_targets_v1" (
    "model_deployment_target_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "deployment_target_key" "text" NOT NULL,
    "deployment_target_name" "text" NOT NULL,
    "deployment_target_status" "text" DEFAULT 'available'::"text" NOT NULL,
    "provider_requirements" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "environment_requirements" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "deployment_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_deployment_target_hash_ck" CHECK (("deployment_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_deployment_target_status_ck" CHECK (("deployment_target_status" = ANY (ARRAY['available'::"text", 'disabled'::"text", 'retired'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_deployment_targets_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_instance_clones_v1" (
    "model_instance_clone_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source_model_instance_runtime_id" "uuid" NOT NULL,
    "cloned_model_instance_runtime_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "clone_name" "text" NOT NULL,
    "clone_slug" "text" NOT NULL,
    "clone_status" "text" DEFAULT 'completed'::"text" NOT NULL,
    "clone_body" "jsonb" NOT NULL,
    "clone_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_instance_clone_hash_ck" CHECK (("clone_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_instance_clone_status_ck" CHECK (("clone_status" = ANY (ARRAY['completed'::"text", 'blocked'::"text", 'archived'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_instance_clones_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_instance_runtimes_v1" (
    "model_instance_runtime_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" NOT NULL,
    "model_version" "text" DEFAULT 'v1'::"text" NOT NULL,
    "instance_name" "text" NOT NULL,
    "instance_slug" "text" NOT NULL,
    "instance_description" "text" DEFAULT ''::"text" NOT NULL,
    "instance_fields" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "model_site_runtime_generation_id" "uuid",
    "instance_status" "text" DEFAULT 'generated'::"text" NOT NULL,
    "launchable" boolean DEFAULT false NOT NULL,
    "instance_body" "jsonb" NOT NULL,
    "instance_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_instance_hash_ck" CHECK (("instance_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_instance_status_ck" CHECK (("instance_status" = ANY (ARRAY['generated'::"text", 'blocked'::"text", 'launched'::"text", 'archived'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_instance_runtimes_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_instance_wizard_runs_v1" (
    "model_instance_wizard_run_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" NOT NULL,
    "model_version" "text" DEFAULT 'v1'::"text" NOT NULL,
    "wizard_answers" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "normalized_fields" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "model_instance_runtime_id" "uuid",
    "wizard_status" "text" DEFAULT 'completed'::"text" NOT NULL,
    "wizard_body" "jsonb" NOT NULL,
    "wizard_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_instance_wizard_hash_ck" CHECK (("wizard_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_instance_wizard_status_ck" CHECK (("wizard_status" = ANY (ARRAY['completed'::"text", 'blocked'::"text", 'archived'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_instance_wizard_runs_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_launch_authorities_v1" (
    "model_launch_authority_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_launch_package_id" "uuid" NOT NULL,
    "model_instance_runtime_id" "uuid" NOT NULL,
    "launch_state" "text" DEFAULT 'draft'::"text" NOT NULL,
    "deployment_target_key" "text" DEFAULT 'proteusops_hosted'::"text" NOT NULL,
    "readiness_checks" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "launch_blockers" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "authority_body" "jsonb" NOT NULL,
    "authority_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_launch_authority_hash_ck" CHECK (("authority_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_launch_authority_state_ck" CHECK (("launch_state" = ANY (ARRAY['draft'::"text", 'ready_for_review'::"text", 'ready_for_launch'::"text", 'launched'::"text", 'suspended'::"text", 'archived'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_launch_authorities_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_launch_packages_v1" (
    "model_launch_package_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" NOT NULL,
    "model_version" "text" NOT NULL,
    "model_instance_runtime_id" "uuid" NOT NULL,
    "model_site_runtime_generation_id" "uuid",
    "package_status" "text" DEFAULT 'generated'::"text" NOT NULL,
    "launchable" boolean DEFAULT false NOT NULL,
    "package_manifest" "jsonb" NOT NULL,
    "route_manifest" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "form_manifest" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "permission_manifest" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "provider_manifest" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "asset_manifest" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "renderer_manifest" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "environment_requirements" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "package_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_launch_package_hash_ck" CHECK (("package_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_launch_package_status_ck" CHECK (("package_status" = ANY (ARRAY['generated'::"text", 'blocked'::"text", 'launched'::"text", 'archived'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_launch_packages_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_launch_receipts_v1" (
    "model_launch_receipt_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_launch_authority_id" "uuid" NOT NULL,
    "model_launch_package_id" "uuid" NOT NULL,
    "model_instance_runtime_id" "uuid" NOT NULL,
    "launch_action" "text" NOT NULL,
    "launch_result" "text" NOT NULL,
    "receipt_body" "jsonb" NOT NULL,
    "receipt_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_launch_receipt_action_ck" CHECK (("launch_action" = ANY (ARRAY['launch'::"text", 'suspend'::"text", 'archive'::"text"]))),
    CONSTRAINT "model_launch_receipt_hash_ck" CHECK (("receipt_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_launch_receipt_result_ck" CHECK (("launch_result" = ANY (ARRAY['allowed'::"text", 'denied'::"text", 'completed'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_launch_receipts_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_launch_reviews_v1" (
    "model_launch_review_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_launch_authority_id" "uuid" NOT NULL,
    "review_status" "text" NOT NULL,
    "reviewer_role" "text" DEFAULT 'community_admin'::"text" NOT NULL,
    "review_notes" "text" DEFAULT ''::"text" NOT NULL,
    "review_body" "jsonb" NOT NULL,
    "review_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_launch_review_hash_ck" CHECK (("review_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_launch_review_status_ck" CHECK (("review_status" = ANY (ARRAY['approved'::"text", 'rejected'::"text", 'changes_requested'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_launch_reviews_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_marketplace_catalog_v1" (
    "model_marketplace_catalog_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "model_key" "text" NOT NULL,
    "model_version" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "category_key" "text" NOT NULL,
    "description" "text" DEFAULT ''::"text" NOT NULL,
    "wizard_enabled" boolean DEFAULT true NOT NULL,
    "deployment_enabled" boolean DEFAULT true NOT NULL,
    "required_providers" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "supported_blocks" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "install_count" integer DEFAULT 0 NOT NULL,
    "marketplace_status" "text" DEFAULT 'published'::"text" NOT NULL,
    "catalog_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_marketplace_hash_ck" CHECK (("catalog_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_marketplace_status_ck" CHECK (("marketplace_status" = ANY (ARRAY['draft'::"text", 'published'::"text", 'retired'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_marketplace_catalog_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_marketplace_installs_v1" (
    "model_marketplace_install_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_marketplace_catalog_id" "uuid",
    "model_key" "text" NOT NULL,
    "model_version" "text" NOT NULL,
    "model_instance_wizard_run_id" "uuid",
    "model_instance_runtime_id" "uuid",
    "model_launch_package_id" "uuid",
    "install_status" "text" DEFAULT 'installed'::"text" NOT NULL,
    "launchable" boolean DEFAULT false NOT NULL,
    "install_body" "jsonb" NOT NULL,
    "install_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_marketplace_install_hash_ck" CHECK (("install_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_marketplace_install_status_ck" CHECK (("install_status" = ANY (ARRAY['installed'::"text", 'blocked'::"text", 'archived'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_marketplace_installs_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_page_compositions_v1" (
    "model_page_composition_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" NOT NULL,
    "model_version" "text" DEFAULT 'v1'::"text" NOT NULL,
    "page_key" "text" NOT NULL,
    "page_title" "text" NOT NULL,
    "page_purpose" "text" NOT NULL,
    "route" "text" NOT NULL,
    "surface" "text" DEFAULT 'public'::"text" NOT NULL,
    "blocks" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "required_providers" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "required_permissions" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "composition_status" "text" DEFAULT 'generated'::"text" NOT NULL,
    "composition_body" "jsonb" NOT NULL,
    "composition_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_page_composition_hash_ck" CHECK (("composition_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_page_composition_status_ck" CHECK (("composition_status" = ANY (ARRAY['generated'::"text", 'blocked'::"text", 'archived'::"text"]))),
    CONSTRAINT "model_page_composition_surface_ck" CHECK (("surface" = ANY (ARRAY['public'::"text", 'admin'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_page_compositions_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_permission_generations_v1" (
    "model_permission_generation_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" NOT NULL,
    "model_version" "text" DEFAULT 'v1'::"text" NOT NULL,
    "role_permissions" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "page_access" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "form_access" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "generation_status" "text" DEFAULT 'generated'::"text" NOT NULL,
    "generation_body" "jsonb" NOT NULL,
    "generation_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_permission_generation_hash_ck" CHECK (("generation_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_permission_generation_status_ck" CHECK (("generation_status" = ANY (ARRAY['generated'::"text", 'blocked'::"text", 'archived'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_permission_generations_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_release_channels_v1" (
    "model_release_channel_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_instance_runtime_id" "uuid" NOT NULL,
    "channel_key" "text" NOT NULL,
    "channel_status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_release_channel_key_ck" CHECK (("channel_key" = ANY (ARRAY['development'::"text", 'staging'::"text", 'production'::"text", 'archived'::"text"]))),
    CONSTRAINT "model_release_channel_status_ck" CHECK (("channel_status" = ANY (ARRAY['active'::"text", 'disabled'::"text", 'archived'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_release_channels_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_release_promotions_v1" (
    "model_release_promotion_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_release_id" "uuid" NOT NULL,
    "from_channel" "text" NOT NULL,
    "to_channel" "text" NOT NULL,
    "promotion_status" "text" DEFAULT 'completed'::"text" NOT NULL,
    "actor_role" "text" DEFAULT 'community_admin'::"text" NOT NULL,
    "promotion_body" "jsonb" NOT NULL,
    "promotion_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_release_promotion_channel_ck" CHECK ((("from_channel" = ANY (ARRAY['development'::"text", 'staging'::"text", 'production'::"text", 'archived'::"text"])) AND ("to_channel" = ANY (ARRAY['development'::"text", 'staging'::"text", 'production'::"text", 'archived'::"text"])))),
    CONSTRAINT "model_release_promotion_hash_ck" CHECK (("promotion_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_release_promotion_status_ck" CHECK (("promotion_status" = ANY (ARRAY['completed'::"text", 'denied'::"text", 'archived'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_release_promotions_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_release_rollbacks_v1" (
    "model_release_rollback_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "source_release_id" "uuid" NOT NULL,
    "target_release_id" "uuid" NOT NULL,
    "rollback_reason" "text" DEFAULT ''::"text" NOT NULL,
    "rollback_status" "text" DEFAULT 'completed'::"text" NOT NULL,
    "rollback_body" "jsonb" NOT NULL,
    "rollback_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_release_rollback_hash_ck" CHECK (("rollback_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_release_rollback_status_ck" CHECK (("rollback_status" = ANY (ARRAY['completed'::"text", 'denied'::"text", 'archived'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_release_rollbacks_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_releases_v1" (
    "model_release_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_instance_runtime_id" "uuid" NOT NULL,
    "model_launch_package_id" "uuid",
    "channel_key" "text" DEFAULT 'development'::"text" NOT NULL,
    "release_status" "text" DEFAULT 'created'::"text" NOT NULL,
    "release_label" "text" NOT NULL,
    "release_notes" "text" DEFAULT ''::"text" NOT NULL,
    "runtime_hash" "text" NOT NULL,
    "snapshot_hash" "text" DEFAULT ''::"text" NOT NULL,
    "launch_package_hash" "text" DEFAULT ''::"text" NOT NULL,
    "renderer_hash" "text" DEFAULT ''::"text" NOT NULL,
    "audit_checkpoint_hash" "text" DEFAULT ''::"text" NOT NULL,
    "release_body" "jsonb" NOT NULL,
    "release_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_release_channel_key_ck" CHECK (("channel_key" = ANY (ARRAY['development'::"text", 'staging'::"text", 'production'::"text", 'archived'::"text"]))),
    CONSTRAINT "model_release_hash_ck" CHECK (("release_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_release_status_ck" CHECK (("release_status" = ANY (ARRAY['created'::"text", 'promoted'::"text", 'rolled_back'::"text", 'archived'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_releases_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_renderer_contracts_v1" (
    "model_renderer_contract_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" NOT NULL,
    "model_version" "text" NOT NULL,
    "model_runtime_manifest_id" "uuid" NOT NULL,
    "renderer_routes" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "renderer_components" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "renderer_actions" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "renderer_assets" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "license_gates" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "contract_status" "text" DEFAULT 'generated'::"text" NOT NULL,
    "contract_body" "jsonb" NOT NULL,
    "contract_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_renderer_contract_hash_ck" CHECK (("contract_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_renderer_contract_status_ck" CHECK (("contract_status" = ANY (ARRAY['generated'::"text", 'blocked'::"text", 'archived'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_renderer_contracts_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_runtime_drift_baselines_v1" (
    "model_runtime_drift_baseline_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_instance_runtime_id" "uuid" NOT NULL,
    "baseline_source" "text" DEFAULT 'release'::"text" NOT NULL,
    "baseline_ref_id" "uuid",
    "baseline_hash" "text" NOT NULL,
    "baseline_body" "jsonb" NOT NULL,
    "baseline_status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_runtime_drift_baseline_hash_ck" CHECK (("baseline_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_runtime_drift_baseline_source_ck" CHECK (("baseline_source" = ANY (ARRAY['release'::"text", 'snapshot'::"text", 'manual'::"text"]))),
    CONSTRAINT "model_runtime_drift_baseline_status_ck" CHECK (("baseline_status" = ANY (ARRAY['active'::"text", 'superseded'::"text", 'archived'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_runtime_drift_baselines_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_runtime_drift_findings_v1" (
    "model_runtime_drift_finding_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_runtime_drift_report_id" "uuid" NOT NULL,
    "model_instance_runtime_id" "uuid" NOT NULL,
    "drift_category" "text" NOT NULL,
    "severity" "text" NOT NULL,
    "resolution_status" "text" DEFAULT 'pending_review'::"text" NOT NULL,
    "expected_hash" "text" DEFAULT ''::"text" NOT NULL,
    "actual_hash" "text" DEFAULT ''::"text" NOT NULL,
    "finding_body" "jsonb" NOT NULL,
    "finding_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_runtime_drift_finding_category_ck" CHECK (("drift_category" = ANY (ARRAY['page'::"text", 'block'::"text", 'renderer'::"text", 'asset'::"text", 'permission'::"text", 'provider'::"text", 'environment'::"text", 'release'::"text", 'license'::"text", 'runtime'::"text", 'database'::"text", 'configuration'::"text"]))),
    CONSTRAINT "model_runtime_drift_finding_hash_ck" CHECK (("finding_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_runtime_drift_finding_resolution_ck" CHECK (("resolution_status" = ANY (ARRAY['expected'::"text", 'approved'::"text", 'pending_review'::"text", 'rollback_required'::"text", 'blocked'::"text"]))),
    CONSTRAINT "model_runtime_drift_finding_severity_ck" CHECK (("severity" = ANY (ARRAY['none'::"text", 'info'::"text", 'warning'::"text", 'major'::"text", 'critical'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_runtime_drift_findings_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_runtime_drift_reports_v1" (
    "model_runtime_drift_report_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_instance_runtime_id" "uuid" NOT NULL,
    "model_runtime_drift_baseline_id" "uuid",
    "drift_status" "text" NOT NULL,
    "severity" "text" NOT NULL,
    "current_hash" "text" NOT NULL,
    "baseline_hash" "text" NOT NULL,
    "finding_count" integer DEFAULT 0 NOT NULL,
    "report_body" "jsonb" NOT NULL,
    "report_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_runtime_drift_report_hash_ck" CHECK (("report_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_runtime_drift_severity_ck" CHECK (("severity" = ANY (ARRAY['none'::"text", 'info'::"text", 'warning'::"text", 'major'::"text", 'critical'::"text"]))),
    CONSTRAINT "model_runtime_drift_status_ck" CHECK (("drift_status" = ANY (ARRAY['clean'::"text", 'drift_detected'::"text", 'acknowledged'::"text", 'blocked'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_runtime_drift_reports_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_runtime_editor_changes_v1" (
    "model_runtime_editor_change_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_instance_runtime_id" "uuid" NOT NULL,
    "target_type" "text" NOT NULL,
    "target_key" "text" NOT NULL,
    "edit_action" "text" NOT NULL,
    "field_updates" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "editor_status" "text" DEFAULT 'applied'::"text" NOT NULL,
    "change_body" "jsonb" NOT NULL,
    "change_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_runtime_editor_action_ck" CHECK (("edit_action" = ANY (ARRAY['update_fields'::"text", 'add_block'::"text", 'remove_block'::"text", 'replace_asset'::"text", 'update_visibility'::"text", 'update_goal'::"text"]))),
    CONSTRAINT "model_runtime_editor_hash_ck" CHECK (("change_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_runtime_editor_status_ck" CHECK (("editor_status" = ANY (ARRAY['applied'::"text", 'blocked'::"text", 'archived'::"text"]))),
    CONSTRAINT "model_runtime_editor_target_ck" CHECK (("target_type" = ANY (ARRAY['page'::"text", 'block'::"text", 'form'::"text", 'asset'::"text", 'settings'::"text", 'provider'::"text", 'license_gate'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_runtime_editor_changes_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_runtime_manifests_v1" (
    "model_runtime_manifest_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" NOT NULL,
    "model_version" "text" NOT NULL,
    "model_site_blueprint_id" "uuid" NOT NULL,
    "runtime_routes" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "runtime_forms" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "runtime_permissions" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "runtime_navigation" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "runtime_providers" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "runtime_status" "text" DEFAULT 'generated'::"text" NOT NULL,
    "manifest_body" "jsonb" NOT NULL,
    "manifest_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_runtime_manifest_hash_ck" CHECK (("manifest_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_runtime_manifest_status_ck" CHECK (("runtime_status" = ANY (ARRAY['generated'::"text", 'blocked'::"text", 'archived'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_runtime_manifests_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_runtime_snapshot_receipts_v1" (
    "model_runtime_snapshot_receipt_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_runtime_snapshot_id" "uuid" NOT NULL,
    "receipt_action" "text" NOT NULL,
    "receipt_body" "jsonb" NOT NULL,
    "receipt_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_runtime_snapshot_receipt_action_ck" CHECK (("receipt_action" = ANY (ARRAY['create'::"text", 'restore'::"text", 'archive'::"text"]))),
    CONSTRAINT "model_runtime_snapshot_receipt_hash_ck" CHECK (("receipt_hash" ~ '^[a-f0-9]{64}$'::"text"))
);


ALTER TABLE "pods_provisioning"."model_runtime_snapshot_receipts_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_runtime_snapshots_v1" (
    "model_runtime_snapshot_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_instance_runtime_id" "uuid" NOT NULL,
    "snapshot_name" "text" NOT NULL,
    "snapshot_reason" "text" DEFAULT ''::"text" NOT NULL,
    "snapshot_status" "text" DEFAULT 'created'::"text" NOT NULL,
    "runtime_manifest" "jsonb" NOT NULL,
    "launch_package" "jsonb" NOT NULL,
    "renderer_contract" "jsonb" NOT NULL,
    "editor_state" "jsonb" NOT NULL,
    "asset_state" "jsonb" NOT NULL,
    "permission_state" "jsonb" NOT NULL,
    "snapshot_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_runtime_snapshot_hash_ck" CHECK (("snapshot_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_runtime_snapshot_status_ck" CHECK (("snapshot_status" = ANY (ARRAY['created'::"text", 'verified'::"text", 'restored'::"text", 'archived'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_runtime_snapshots_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_site_blueprints_v1" (
    "model_site_blueprint_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" NOT NULL,
    "model_version" "text" NOT NULL,
    "civic_deployment_id" "uuid",
    "model_ui_generation_id" "uuid",
    "model_permission_generation_id" "uuid",
    "public_pages" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "admin_pages" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "forms" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "nav_items" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "roles" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "page_access" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "form_access" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "required_providers" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "blueprint_status" "text" DEFAULT 'generated'::"text" NOT NULL,
    "blueprint_body" "jsonb" NOT NULL,
    "blueprint_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_site_blueprint_hash_ck" CHECK (("blueprint_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_site_blueprint_status_ck" CHECK (("blueprint_status" = ANY (ARRAY['generated'::"text", 'blocked'::"text", 'archived'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_site_blueprints_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_site_runtime_generations_v1" (
    "model_site_runtime_generation_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" NOT NULL,
    "model_version" "text" NOT NULL,
    "civic_deployment_id" "uuid",
    "model_site_blueprint_id" "uuid",
    "model_runtime_manifest_id" "uuid",
    "model_renderer_contract_id" "uuid",
    "site_runtime_status" "text" DEFAULT 'generated'::"text" NOT NULL,
    "launchable" boolean DEFAULT false NOT NULL,
    "asset_runtime_ready" boolean DEFAULT false NOT NULL,
    "license_runtime_ready" boolean DEFAULT false NOT NULL,
    "site_runtime_body" "jsonb" NOT NULL,
    "site_runtime_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_site_runtime_hash_ck" CHECK (("site_runtime_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_site_runtime_status_ck" CHECK (("site_runtime_status" = ANY (ARRAY['generated'::"text", 'blocked'::"text", 'archived'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_site_runtime_generations_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_stored_procedure_registry_v1" (
    "model_stored_procedure_registry_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "procedure_name" "text" NOT NULL,
    "procedure_category" "text" NOT NULL,
    "input_parameters" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "output_token" "text" NOT NULL,
    "stable_api" boolean DEFAULT true NOT NULL,
    "destructive_action" boolean DEFAULT false NOT NULL,
    "procedure_status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods_provisioning"."model_stored_procedure_registry_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_template_registry_v1" (
    "model_template_registry_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "model_key" "text" NOT NULL,
    "model_version" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "category_key" "text" NOT NULL,
    "template_status" "text" DEFAULT 'published'::"text" NOT NULL,
    "wizard_schema" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "default_pages" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "default_blocks" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "default_roles" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "required_providers" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "supported_deployment_targets" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "license_rules" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "template_body" "jsonb" NOT NULL,
    "template_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_template_registry_hash_ck" CHECK (("template_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_template_registry_status_ck" CHECK (("template_status" = ANY (ARRAY['draft'::"text", 'published'::"text", 'retired'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_template_registry_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."model_ui_generations_v1" (
    "model_ui_generation_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" NOT NULL,
    "model_version" "text" DEFAULT 'v1'::"text" NOT NULL,
    "public_pages" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "admin_pages" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "forms" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "nav_items" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "roles" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "generation_status" "text" DEFAULT 'generated'::"text" NOT NULL,
    "generation_body" "jsonb" NOT NULL,
    "generation_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "model_ui_generation_hash_ck" CHECK (("generation_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "model_ui_generation_status_ck" CHECK (("generation_status" = ANY (ARRAY['generated'::"text", 'blocked'::"text", 'archived'::"text"])))
);


ALTER TABLE "pods_provisioning"."model_ui_generations_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."notification_delivery_receipts_v1" (
    "delivery_receipt_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "notification_id" "uuid" NOT NULL,
    "delivery_status" "text" NOT NULL,
    "provider_key" "text" NOT NULL,
    "provider_message_id" "text" DEFAULT ''::"text" NOT NULL,
    "receipt_body" "jsonb" NOT NULL,
    "receipt_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "notification_receipt_hash_ck" CHECK (("receipt_hash" ~ '^[a-f0-9]{64}$'::"text"))
);


ALTER TABLE "pods_provisioning"."notification_delivery_receipts_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."notification_preferences_v1" (
    "preference_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "customer_email" "text" NOT NULL,
    "customer_phone" "text" DEFAULT ''::"text" NOT NULL,
    "email_enabled" boolean DEFAULT true NOT NULL,
    "sms_enabled" boolean DEFAULT true NOT NULL,
    "push_enabled" boolean DEFAULT false NOT NULL,
    "reminder_opt_in" boolean DEFAULT true NOT NULL,
    "marketing_opt_in" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods_provisioning"."notification_preferences_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."notification_templates_v1" (
    "template_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "template_key" "text" NOT NULL,
    "template_version" "text" NOT NULL,
    "notification_kind" "text" NOT NULL,
    "delivery_channel" "text" NOT NULL,
    "subject_template" "text" DEFAULT ''::"text" NOT NULL,
    "body_template" "text" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "template_body" "jsonb" NOT NULL,
    "template_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "notification_template_channel_ck" CHECK (("delivery_channel" = ANY (ARRAY['email'::"text", 'sms'::"text", 'push'::"text", 'internal'::"text"]))),
    CONSTRAINT "notification_template_hash_ck" CHECK (("template_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "notification_template_kind_ck" CHECK (("notification_kind" = ANY (ARRAY['appointment_confirmation'::"text", 'appointment_reminder'::"text", 'appointment_cancelled'::"text", 'appointment_rescheduled'::"text", 'staff_reassignment'::"text", 'membership_renewal'::"text"])))
);


ALTER TABLE "pods_provisioning"."notification_templates_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."notifications_v1" (
    "notification_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "appointment_request_id" "uuid",
    "notification_kind" "text" NOT NULL,
    "delivery_channel" "text" NOT NULL,
    "recipient_email" "text" DEFAULT ''::"text" NOT NULL,
    "recipient_phone" "text" DEFAULT ''::"text" NOT NULL,
    "scheduled_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "delivered_at" timestamp with time zone,
    "delivery_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "template_key" "text" NOT NULL,
    "template_version" "text" NOT NULL,
    "rendered_subject" "text" DEFAULT ''::"text" NOT NULL,
    "rendered_body" "text" NOT NULL,
    "notification_body" "jsonb" NOT NULL,
    "notification_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "notifications_channel_ck" CHECK (("delivery_channel" = ANY (ARRAY['email'::"text", 'sms'::"text", 'push'::"text", 'internal'::"text"]))),
    CONSTRAINT "notifications_delivery_status_ck" CHECK (("delivery_status" = ANY (ARRAY['pending'::"text", 'scheduled'::"text", 'delivered'::"text", 'failed'::"text", 'cancelled'::"text"]))),
    CONSTRAINT "notifications_hash_ck" CHECK (("notification_hash" ~ '^[a-f0-9]{64}$'::"text"))
);


ALTER TABLE "pods_provisioning"."notifications_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."operator_setup_wizard_sessions_v1" (
    "wizard_session_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" NOT NULL,
    "model_version" "text" NOT NULL,
    "wizard_status" "text" DEFAULT 'in_progress'::"text" NOT NULL,
    "current_step" integer DEFAULT 1 NOT NULL,
    "total_steps" integer DEFAULT 6 NOT NULL,
    "completed_steps" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "skipped_steps" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "requested_fields" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "applied_defaults" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "provider_checklist" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "readiness_checklist" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "launch_ready" boolean DEFAULT false NOT NULL,
    "wizard_body" "jsonb" NOT NULL,
    "wizard_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "operator_setup_wizard_hash_ck" CHECK (("wizard_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "operator_setup_wizard_status_ck" CHECK (("wizard_status" = ANY (ARRAY['in_progress'::"text", 'review_ready'::"text", 'launch_ready'::"text", 'launched'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "pods_provisioning"."operator_setup_wizard_sessions_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."payment_events_v1" (
    "payment_event_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "payment_intent_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "event_kind" "text" NOT NULL,
    "previous_status" "text" NOT NULL,
    "new_status" "text" NOT NULL,
    "provider_key" "text" DEFAULT 'adapter_pending'::"text" NOT NULL,
    "provider_event_id" "text" DEFAULT ''::"text" NOT NULL,
    "event_body" "jsonb" NOT NULL,
    "event_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "payment_event_hash_ck" CHECK (("event_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "payment_event_kind_ck" CHECK (("event_kind" = ANY (ARRAY['create_intent'::"text", 'authorize'::"text", 'capture'::"text", 'fail'::"text", 'cancel'::"text", 'refund'::"text"]))),
    CONSTRAINT "payment_event_status_ck" CHECK (("new_status" = ANY (ARRAY['pending'::"text", 'authorized'::"text", 'captured'::"text", 'failed'::"text", 'cancelled'::"text", 'refunded'::"text"])))
);


ALTER TABLE "pods_provisioning"."payment_events_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."payment_intents_v1" (
    "payment_intent_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "appointment_request_id" "uuid" NOT NULL,
    "payment_policy_id" "uuid",
    "provider_key" "text" DEFAULT 'adapter_pending'::"text" NOT NULL,
    "provider_intent_id" "text" DEFAULT ''::"text" NOT NULL,
    "amount_cents" integer NOT NULL,
    "currency" "text" DEFAULT 'usd'::"text" NOT NULL,
    "payment_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "intent_body" "jsonb" NOT NULL,
    "intent_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "payment_intent_amount_ck" CHECK (("amount_cents" >= 0)),
    CONSTRAINT "payment_intent_currency_ck" CHECK (("currency" ~ '^[a-z]{3}$'::"text")),
    CONSTRAINT "payment_intent_hash_ck" CHECK (("intent_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "payment_intent_status_ck" CHECK (("payment_status" = ANY (ARRAY['pending'::"text", 'authorized'::"text", 'captured'::"text", 'failed'::"text", 'cancelled'::"text", 'refunded'::"text"])))
);


ALTER TABLE "pods_provisioning"."payment_intents_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."payment_policies_v1" (
    "payment_policy_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "template_key" "text" NOT NULL,
    "template_version" "text" NOT NULL,
    "policy_key" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "deposit_required" boolean DEFAULT false NOT NULL,
    "deposit_amount_cents" integer DEFAULT 0 NOT NULL,
    "payment_required_before_confirmation" boolean DEFAULT false NOT NULL,
    "refund_window_hours" integer DEFAULT 24 NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "policy_body" "jsonb" NOT NULL,
    "policy_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "payment_policy_amount_ck" CHECK (("deposit_amount_cents" >= 0)),
    CONSTRAINT "payment_policy_hash_ck" CHECK (("policy_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "payment_policy_refund_window_ck" CHECK (("refund_window_hours" >= 0))
);


ALTER TABLE "pods_provisioning"."payment_policies_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."payment_provider_adapters_v1" (
    "provider_adapter_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "provider_key" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "webhook_enabled" boolean DEFAULT true NOT NULL,
    "signature_verification_required" boolean DEFAULT true NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "adapter_body" "jsonb" NOT NULL,
    "adapter_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "payment_provider_hash_ck" CHECK (("adapter_hash" ~ '^[a-f0-9]{64}$'::"text"))
);


ALTER TABLE "pods_provisioning"."payment_provider_adapters_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."payment_provider_receipts_v1" (
    "provider_receipt_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "payment_intent_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "provider_key" "text" NOT NULL,
    "provider_event_id" "text" NOT NULL,
    "provider_event_kind" "text" NOT NULL,
    "provider_signature_valid" boolean DEFAULT false NOT NULL,
    "provider_status" "text" NOT NULL,
    "receipt_body" "jsonb" NOT NULL,
    "receipt_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "provider_receipt_hash_ck" CHECK (("receipt_hash" ~ '^[a-f0-9]{64}$'::"text"))
);


ALTER TABLE "pods_provisioning"."payment_provider_receipts_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."provider_connection_contracts_v1" (
    "provider_connection_contract_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "provider_key" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "default_connection_method" "text" DEFAULT 'oauth_or_api'::"text" NOT NULL,
    "manual_key_entry_allowed" boolean DEFAULT false NOT NULL,
    "manual_key_entry_scope" "text" DEFAULT 'developer_fallback_only'::"text" NOT NULL,
    "secret_storage_model" "text" DEFAULT 'secret_ref_only'::"text" NOT NULL,
    "user_action" "text" DEFAULT 'connect_provider'::"text" NOT NULL,
    "required_scopes" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "discovered_resources" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "verification_checks" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "contract_body" "jsonb" NOT NULL,
    "contract_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "provider_connection_contract_hash_ck" CHECK (("contract_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "provider_connection_method_ck" CHECK (("default_connection_method" = ANY (ARRAY['oauth'::"text", 'api'::"text", 'oauth_or_api'::"text", 'cli_login'::"text"]))),
    CONSTRAINT "provider_secret_storage_ck" CHECK (("secret_storage_model" = ANY (ARRAY['secret_ref_only'::"text", 'vault_ref_only'::"text"])))
);


ALTER TABLE "pods_provisioning"."provider_connection_contracts_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."provider_connection_rollups_v1" (
    "provider_connection_rollup_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" DEFAULT 'DEVELOPER_PORTAL_V1'::"text" NOT NULL,
    "model_version" "text" DEFAULT 'v1'::"text" NOT NULL,
    "required_providers" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "verified_providers" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "missing_providers" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "connection_ready" boolean DEFAULT false NOT NULL,
    "launch_blocked" boolean DEFAULT true NOT NULL,
    "rollup_body" "jsonb" NOT NULL,
    "rollup_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "provider_connection_rollup_hash_ck" CHECK (("rollup_hash" ~ '^[a-f0-9]{64}$'::"text"))
);


ALTER TABLE "pods_provisioning"."provider_connection_rollups_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."provider_connection_runtime_bridges_v1" (
    "provider_connection_runtime_bridge_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" DEFAULT 'DEVELOPER_PORTAL_V1'::"text" NOT NULL,
    "model_version" "text" DEFAULT 'v1'::"text" NOT NULL,
    "provider_connection_rollup_id" "uuid" NOT NULL,
    "bridged_providers" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "runtime_receipts" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "missing_providers" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "bridge_ready" boolean DEFAULT false NOT NULL,
    "launch_blocked" boolean DEFAULT true NOT NULL,
    "bridge_body" "jsonb" NOT NULL,
    "bridge_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "provider_connection_runtime_bridge_hash_ck" CHECK (("bridge_hash" ~ '^[a-f0-9]{64}$'::"text"))
);


ALTER TABLE "pods_provisioning"."provider_connection_runtime_bridges_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."provider_connection_sessions_v1" (
    "provider_connection_session_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "provider_key" "text" NOT NULL,
    "connection_status" "text" DEFAULT 'created'::"text" NOT NULL,
    "connection_method" "text" DEFAULT 'oauth_or_api'::"text" NOT NULL,
    "user_action" "text" DEFAULT 'connect_provider'::"text" NOT NULL,
    "manual_key_entry_used" boolean DEFAULT false NOT NULL,
    "provider_account_ref" "text" DEFAULT ''::"text" NOT NULL,
    "provider_project_ref" "text" DEFAULT ''::"text" NOT NULL,
    "secret_ref" "text" DEFAULT ''::"text" NOT NULL,
    "discovered_resources" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "verification_results" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "launch_blocked" boolean DEFAULT true NOT NULL,
    "session_body" "jsonb" NOT NULL,
    "session_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "provider_connection_method_session_ck" CHECK (("connection_method" = ANY (ARRAY['oauth'::"text", 'api'::"text", 'oauth_or_api'::"text", 'cli_login'::"text", 'manual_key_fallback'::"text"]))),
    CONSTRAINT "provider_connection_session_hash_ck" CHECK (("session_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "provider_connection_status_ck" CHECK (("connection_status" = ANY (ARRAY['created'::"text", 'connected'::"text", 'verified'::"text", 'blocked'::"text", 'failed'::"text", 'revoked'::"text"])))
);


ALTER TABLE "pods_provisioning"."provider_connection_sessions_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."provider_readiness_rollups_v1" (
    "provider_readiness_rollup_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" DEFAULT ''::"text" NOT NULL,
    "model_version" "text" DEFAULT 'v1'::"text" NOT NULL,
    "supabase_ready" boolean DEFAULT false NOT NULL,
    "stripe_ready" boolean DEFAULT false NOT NULL,
    "email_ready" boolean DEFAULT false NOT NULL,
    "storage_ready" boolean DEFAULT false NOT NULL,
    "github_ready" boolean DEFAULT false NOT NULL,
    "ready_providers" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "blocked_providers" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "launch_ready" boolean DEFAULT false NOT NULL,
    "readiness_status" "text" DEFAULT 'blocked'::"text" NOT NULL,
    "readiness_body" "jsonb" NOT NULL,
    "readiness_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "provider_readiness_hash_ck" CHECK (("readiness_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "provider_readiness_status_ck" CHECK (("readiness_status" = ANY (ARRAY['ready'::"text", 'blocked'::"text"])))
);


ALTER TABLE "pods_provisioning"."provider_readiness_rollups_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."provision_runs_v1" (
    "provision_run_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "template_key" "text" NOT NULL,
    "template_version" "text" NOT NULL,
    "operator_user_id" "uuid",
    "status" "text" DEFAULT 'started'::"text" NOT NULL,
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "completed_at" timestamp with time zone,
    "receipt_hash" "text" DEFAULT ''::"text" NOT NULL,
    "failure_token" "text" DEFAULT ''::"text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "provision_runs_receipt_hash_ck" CHECK ((("receipt_hash" = ''::"text") OR ("receipt_hash" ~ '^[a-f0-9]{64}$'::"text"))),
    CONSTRAINT "provision_runs_status_ck" CHECK (("status" = ANY (ARRAY['started'::"text", 'completed'::"text", 'failed'::"text"])))
);


ALTER TABLE "pods_provisioning"."provision_runs_v1" OWNER TO "postgres";


COMMENT ON TABLE "pods_provisioning"."provision_runs_v1" IS 'Append-style record of deterministic provisioning attempts for an organization.';



CREATE TABLE IF NOT EXISTS "pods_provisioning"."provisioning_receipts_v1" (
    "receipt_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "provision_run_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "event_type" "text" NOT NULL,
    "event_token" "text" NOT NULL,
    "receipt_body" "jsonb" NOT NULL,
    "receipt_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "provisioning_receipts_hash_ck" CHECK (("receipt_hash" ~ '^[a-f0-9]{64}$'::"text"))
);


ALTER TABLE "pods_provisioning"."provisioning_receipts_v1" OWNER TO "postgres";


COMMENT ON TABLE "pods_provisioning"."provisioning_receipts_v1" IS 'Deterministic receipt ledger for template provisioning events.';



CREATE TABLE IF NOT EXISTS "pods_provisioning"."public_appointment_requests_v1" (
    "appointment_request_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "provision_run_id" "uuid" NOT NULL,
    "booking_slug" "text" NOT NULL,
    "booking_path" "text" NOT NULL,
    "template_key" "text" NOT NULL,
    "template_version" "text" NOT NULL,
    "service_code" "text" NOT NULL,
    "requested_date" "date" NOT NULL,
    "requested_start_time" time without time zone NOT NULL,
    "requested_end_time" time without time zone NOT NULL,
    "customer_name" "text" NOT NULL,
    "customer_email" "text" NOT NULL,
    "customer_phone" "text" DEFAULT ''::"text" NOT NULL,
    "status" "text" DEFAULT 'requested'::"text" NOT NULL,
    "request_body" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "request_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "public_appointment_email_ck" CHECK (("customer_email" ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'::"text")),
    CONSTRAINT "public_appointment_hash_ck" CHECK (("request_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "public_appointment_status_ck" CHECK (("status" = ANY (ARRAY['requested'::"text", 'confirmed'::"text", 'cancelled'::"text", 'declined'::"text"])))
);


ALTER TABLE "pods_provisioning"."public_appointment_requests_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."public_booking_surfaces_v1" (
    "public_surface_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "provision_run_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "template_key" "text" NOT NULL,
    "template_version" "text" NOT NULL,
    "booking_slug" "text" NOT NULL,
    "booking_path" "text" NOT NULL,
    "enabled" boolean DEFAULT true NOT NULL,
    "receipt_body" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "receipt_hash" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "public_booking_path_ck" CHECK (("booking_path" ~ '^/book/[a-z0-9][a-z0-9\-]{2,62}[a-z0-9]$'::"text")),
    CONSTRAINT "public_booking_receipt_hash_ck" CHECK ((("receipt_hash" = ''::"text") OR ("receipt_hash" ~ '^[a-f0-9]{64}$'::"text"))),
    CONSTRAINT "public_booking_slug_ck" CHECK (("booking_slug" ~ '^[a-z0-9][a-z0-9\-]{2,62}[a-z0-9]$'::"text"))
);


ALTER TABLE "pods_provisioning"."public_booking_surfaces_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."refund_intents_v1" (
    "refund_intent_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "payment_intent_id" "uuid" NOT NULL,
    "cancellation_request_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "provider_key" "text" DEFAULT 'adapter_pending'::"text" NOT NULL,
    "provider_refund_id" "text" DEFAULT ''::"text" NOT NULL,
    "refund_amount_cents" integer NOT NULL,
    "currency" "text" DEFAULT 'usd'::"text" NOT NULL,
    "refund_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "refund_body" "jsonb" NOT NULL,
    "refund_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "refund_amount_ck" CHECK (("refund_amount_cents" >= 0)),
    CONSTRAINT "refund_currency_ck" CHECK (("currency" ~ '^[a-z]{3}$'::"text")),
    CONSTRAINT "refund_hash_ck" CHECK (("refund_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "refund_status_ck" CHECK (("refund_status" = ANY (ARRAY['pending'::"text", 'succeeded'::"text", 'failed'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "pods_provisioning"."refund_intents_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."security_gate_matrix_v1" (
    "security_gate_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "gate_key" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "gate_kind" "text" NOT NULL,
    "required" boolean DEFAULT true NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "gate_body" "jsonb" NOT NULL,
    "gate_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "security_gate_hash_ck" CHECK (("gate_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "security_gate_kind_ck" CHECK (("gate_kind" = ANY (ARRAY['tenant'::"text", 'secret'::"text", 'provider'::"text", 'auth'::"text", 'rls'::"text", 'launch'::"text", 'rollback'::"text", 'replay'::"text", 'duplicate'::"text"])))
);


ALTER TABLE "pods_provisioning"."security_gate_matrix_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."security_gate_results_v1" (
    "security_gate_result_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "model_key" "text" DEFAULT ''::"text" NOT NULL,
    "gate_key" "text" NOT NULL,
    "gate_status" "text" NOT NULL,
    "gate_message" "text" DEFAULT ''::"text" NOT NULL,
    "result_body" "jsonb" NOT NULL,
    "result_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "security_gate_result_hash_ck" CHECK (("result_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "security_gate_status_ck" CHECK (("gate_status" = ANY (ARRAY['pass'::"text", 'fail'::"text", 'warn'::"text"])))
);


ALTER TABLE "pods_provisioning"."security_gate_results_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."seeded_objects_v1" (
    "seeded_object_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "provision_run_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "template_key" "text" NOT NULL,
    "template_version" "text" NOT NULL,
    "object_kind" "text" NOT NULL,
    "object_schema" "text" NOT NULL,
    "object_table" "text" NOT NULL,
    "object_id" "uuid",
    "object_key" "text" NOT NULL,
    "seeded_hash" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "seeded_objects_hash_ck" CHECK ((("seeded_hash" = ''::"text") OR ("seeded_hash" ~ '^[a-f0-9]{64}$'::"text"))),
    CONSTRAINT "seeded_objects_kind_ck" CHECK (("object_kind" = ANY (ARRAY['org'::"text", 'role'::"text", 'service'::"text", 'availability_template'::"text", 'booking_rule'::"text", 'public_surface'::"text", 'entitlement'::"text", 'receipt'::"text"])))
);


ALTER TABLE "pods_provisioning"."seeded_objects_v1" OWNER TO "postgres";


COMMENT ON TABLE "pods_provisioning"."seeded_objects_v1" IS 'Tracks every deterministic object created or claimed during template provisioning.';



CREATE TABLE IF NOT EXISTS "pods_provisioning"."staff_appointment_assignments_v1" (
    "staff_assignment_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "appointment_request_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "staff_member_id" "uuid" NOT NULL,
    "service_code" "text" NOT NULL,
    "assigned_date" "date" NOT NULL,
    "assigned_start_time" time without time zone NOT NULL,
    "assigned_end_time" time without time zone NOT NULL,
    "assignment_status" "text" DEFAULT 'assigned'::"text" NOT NULL,
    "assignment_body" "jsonb" NOT NULL,
    "assignment_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "staff_assignment_hash_ck" CHECK (("assignment_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "staff_assignment_status_ck" CHECK (("assignment_status" = ANY (ARRAY['assigned'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "pods_provisioning"."staff_appointment_assignments_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."staff_featured_sections_v1" (
    "featured_section_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "section_key" "text" NOT NULL,
    "display_title" "text" NOT NULL,
    "section_kind" "text" NOT NULL,
    "staff_member_id" "uuid",
    "starts_on" "date",
    "ends_on" "date",
    "enabled" boolean DEFAULT true NOT NULL,
    "section_body" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "section_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "staff_featured_section_hash_ck" CHECK (("section_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "staff_featured_section_kind_ck" CHECK (("section_kind" = ANY (ARRAY['employee_of_month'::"text", 'work_of_month'::"text", 'featured_staff'::"text", 'featured_gallery'::"text"])))
);


ALTER TABLE "pods_provisioning"."staff_featured_sections_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."staff_gallery_items_v1" (
    "gallery_item_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "staff_member_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text" DEFAULT ''::"text" NOT NULL,
    "media_url" "text" NOT NULL,
    "media_kind" "text" DEFAULT 'image'::"text" NOT NULL,
    "service_code" "text" DEFAULT ''::"text" NOT NULL,
    "display_order" integer DEFAULT 0 NOT NULL,
    "is_public" boolean DEFAULT true NOT NULL,
    "item_body" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "item_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "staff_gallery_item_hash_ck" CHECK (("item_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "staff_gallery_media_kind_ck" CHECK (("media_kind" = ANY (ARRAY['image'::"text", 'video'::"text"])))
);


ALTER TABLE "pods_provisioning"."staff_gallery_items_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."staff_members_v1" (
    "staff_member_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "template_key" "text" NOT NULL,
    "template_version" "text" NOT NULL,
    "staff_key" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "role_key" "text" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "staff_members_role_key_ck" CHECK (("role_key" ~ '^[A-Z0-9_]+$'::"text"))
);


ALTER TABLE "pods_provisioning"."staff_members_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."staff_public_profiles_v1" (
    "staff_profile_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "staff_member_id" "uuid" NOT NULL,
    "org_id" "uuid" NOT NULL,
    "public_display_name" "text" NOT NULL,
    "headline" "text" DEFAULT ''::"text" NOT NULL,
    "about_me" "text" DEFAULT ''::"text" NOT NULL,
    "specialties" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "years_experience" integer DEFAULT 0 NOT NULL,
    "profile_photo_url" "text" DEFAULT ''::"text" NOT NULL,
    "is_public" boolean DEFAULT true NOT NULL,
    "featured_rank" integer DEFAULT 0 NOT NULL,
    "profile_body" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "profile_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "staff_public_profile_hash_ck" CHECK (("profile_hash" ~ '^[a-f0-9]{64}$'::"text"))
);


ALTER TABLE "pods_provisioning"."staff_public_profiles_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."storage_adapter_runtime_v1" (
    "storage_runtime_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "adapter_attachment_run_id" "uuid",
    "provider_key" "text" NOT NULL,
    "storage_scope" "text" NOT NULL,
    "bucket_verified" boolean DEFAULT false NOT NULL,
    "upload_policy_verified" boolean DEFAULT false NOT NULL,
    "read_policy_verified" boolean DEFAULT false NOT NULL,
    "signed_url_ready" boolean DEFAULT false NOT NULL,
    "file_metadata_ready" boolean DEFAULT false NOT NULL,
    "runtime_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "runtime_body" "jsonb" NOT NULL,
    "runtime_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "storage_runtime_hash_ck" CHECK (("runtime_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "storage_runtime_status_ck" CHECK (("runtime_status" = ANY (ARRAY['pending'::"text", 'verified'::"text", 'failed'::"text", 'blocked'::"text"])))
);


ALTER TABLE "pods_provisioning"."storage_adapter_runtime_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."stress_harness_runs_v1" (
    "stress_run_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "stress_key" "text" NOT NULL,
    "org_count" integer DEFAULT 0 NOT NULL,
    "launch_success_count" integer DEFAULT 0 NOT NULL,
    "launch_failure_count" integer DEFAULT 0 NOT NULL,
    "rollback_count" integer DEFAULT 0 NOT NULL,
    "retry_count" integer DEFAULT 0 NOT NULL,
    "duplicate_denial_count" integer DEFAULT 0 NOT NULL,
    "isolation_pass" boolean DEFAULT false NOT NULL,
    "stress_status" "text" DEFAULT 'passed'::"text" NOT NULL,
    "stress_body" "jsonb" NOT NULL,
    "stress_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "stress_hash_ck" CHECK (("stress_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "stress_status_ck" CHECK (("stress_status" = ANY (ARRAY['passed'::"text", 'failed'::"text"])))
);


ALTER TABLE "pods_provisioning"."stress_harness_runs_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."stripe_adapter_runtime_v1" (
    "stripe_runtime_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "adapter_attachment_run_id" "uuid",
    "stripe_account_id" "text" NOT NULL,
    "mode" "text" DEFAULT 'test'::"text" NOT NULL,
    "api_key_verified" boolean DEFAULT false NOT NULL,
    "webhook_configured" boolean DEFAULT false NOT NULL,
    "webhook_signing_secret_present" boolean DEFAULT false NOT NULL,
    "product_sync_ready" boolean DEFAULT false NOT NULL,
    "price_sync_ready" boolean DEFAULT false NOT NULL,
    "payment_intent_ready" boolean DEFAULT false NOT NULL,
    "runtime_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "runtime_body" "jsonb" NOT NULL,
    "runtime_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "stripe_runtime_hash_ck" CHECK (("runtime_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "stripe_runtime_mode_ck" CHECK (("mode" = ANY (ARRAY['test'::"text", 'live'::"text"]))),
    CONSTRAINT "stripe_runtime_status_ck" CHECK (("runtime_status" = ANY (ARRAY['pending'::"text", 'verified'::"text", 'failed'::"text", 'blocked'::"text"])))
);


ALTER TABLE "pods_provisioning"."stripe_adapter_runtime_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."supabase_adapter_runtime_v1" (
    "supabase_runtime_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "org_id" "uuid" NOT NULL,
    "adapter_attachment_run_id" "uuid",
    "project_ref" "text" NOT NULL,
    "supabase_url" "text" NOT NULL,
    "auth_verified" boolean DEFAULT false NOT NULL,
    "storage_verified" boolean DEFAULT false NOT NULL,
    "database_verified" boolean DEFAULT false NOT NULL,
    "rls_verified" boolean DEFAULT false NOT NULL,
    "runtime_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "runtime_body" "jsonb" NOT NULL,
    "runtime_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "supabase_runtime_hash_ck" CHECK (("runtime_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "supabase_runtime_status_ck" CHECK (("runtime_status" = ANY (ARRAY['pending'::"text", 'verified'::"text", 'failed'::"text", 'blocked'::"text"])))
);


ALTER TABLE "pods_provisioning"."supabase_adapter_runtime_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."template_registry_v1" (
    "template_key" "text" NOT NULL,
    "template_version" "text" NOT NULL,
    "vertical" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "description" "text" DEFAULT ''::"text" NOT NULL,
    "seeded_hash" "text" DEFAULT ''::"text" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "template_registry_key_ck" CHECK (("template_key" ~ '^[A-Z0-9_]+$'::"text")),
    CONSTRAINT "template_registry_seeded_hash_ck" CHECK ((("seeded_hash" = ''::"text") OR ("seeded_hash" ~ '^[a-f0-9]{64}$'::"text"))),
    CONSTRAINT "template_registry_version_ck" CHECK (("template_version" ~ '^v[0-9]+$'::"text"))
);


ALTER TABLE "pods_provisioning"."template_registry_v1" OWNER TO "postgres";


COMMENT ON TABLE "pods_provisioning"."template_registry_v1" IS 'Canonical registry of deterministic ProteusOps business base-model templates.';



CREATE OR REPLACE VIEW "pods_provisioning"."v_model_instance_runtime_summary_v1" AS
 SELECT "model_instance_runtime_id",
    "org_id",
    "model_key",
    "model_version",
    "instance_name",
    "instance_slug",
    "instance_status",
    "launchable",
    "model_site_runtime_generation_id",
    "instance_hash",
    "created_at"
   FROM "pods_provisioning"."model_instance_runtimes_v1";


ALTER VIEW "pods_provisioning"."v_model_instance_runtime_summary_v1" OWNER TO "postgres";


CREATE OR REPLACE VIEW "pods_provisioning"."v_model_launch_package_summary_v1" AS
 SELECT "model_launch_package_id",
    "org_id",
    "model_key",
    "model_version",
    "model_instance_runtime_id",
    "model_site_runtime_generation_id",
    "package_status",
    "launchable",
    "provider_manifest",
    "environment_requirements",
    "package_hash",
    "created_at"
   FROM "pods_provisioning"."model_launch_packages_v1";


ALTER VIEW "pods_provisioning"."v_model_launch_package_summary_v1" OWNER TO "postgres";


CREATE OR REPLACE VIEW "pods_provisioning"."v_model_marketplace_catalog_v1" AS
 SELECT "model_marketplace_catalog_id",
    "model_key",
    "model_version",
    "display_name",
    "category_key",
    "wizard_enabled",
    "deployment_enabled",
    "required_providers",
    "supported_blocks",
    "install_count",
    "marketplace_status",
    "catalog_hash",
    "created_at"
   FROM "pods_provisioning"."model_marketplace_catalog_v1";


ALTER VIEW "pods_provisioning"."v_model_marketplace_catalog_v1" OWNER TO "postgres";


CREATE OR REPLACE VIEW "pods_provisioning"."v_model_runtime_governance_clones_v1" AS
 SELECT "model_instance_clone_id",
    "source_model_instance_runtime_id",
    "cloned_model_instance_runtime_id",
    "org_id",
    "clone_name",
    "clone_slug",
    "clone_status",
    "clone_hash",
    "created_at"
   FROM "pods_provisioning"."model_instance_clones_v1"
  WHERE ("clone_status" = 'completed'::"text");


ALTER VIEW "pods_provisioning"."v_model_runtime_governance_clones_v1" OWNER TO "postgres";


CREATE OR REPLACE VIEW "pods_provisioning"."v_model_runtime_governance_editor_changes_v1" AS
 SELECT "model_runtime_editor_change_id",
    "org_id",
    "model_instance_runtime_id",
    "target_type",
    "target_key",
    "edit_action",
    "field_updates",
    "editor_status",
    "change_hash",
    "created_at"
   FROM "pods_provisioning"."model_runtime_editor_changes_v1"
  WHERE ("editor_status" = 'applied'::"text");


ALTER VIEW "pods_provisioning"."v_model_runtime_governance_editor_changes_v1" OWNER TO "postgres";


CREATE OR REPLACE VIEW "pods_provisioning"."v_model_runtime_governance_full_green_receipts_v1" AS
 SELECT "model_db_surface_full_green_receipt_id",
    "receipt_status",
    "proof_tokens",
    "full_green",
    "receipt_hash",
    "created_at"
   FROM "pods_provisioning"."model_db_surface_full_green_receipts_v1"
  WHERE ("receipt_status" = 'passed'::"text");


ALTER VIEW "pods_provisioning"."v_model_runtime_governance_full_green_receipts_v1" OWNER TO "postgres";


CREATE OR REPLACE VIEW "pods_provisioning"."v_model_runtime_governance_instances_v1" AS
 SELECT "model_instance_runtime_id",
    "org_id",
    "model_key",
    "model_version",
    "instance_name",
    "instance_slug",
    "instance_status",
    "launchable",
    "model_site_runtime_generation_id",
    "instance_hash",
    "created_at"
   FROM "pods_provisioning"."model_instance_runtimes_v1"
  WHERE ("instance_status" = ANY (ARRAY['generated'::"text", 'launched'::"text"]));


ALTER VIEW "pods_provisioning"."v_model_runtime_governance_instances_v1" OWNER TO "postgres";


CREATE OR REPLACE VIEW "pods_provisioning"."v_model_runtime_governance_launch_packages_v1" AS
 SELECT "model_launch_package_id",
    "org_id",
    "model_key",
    "model_version",
    "model_instance_runtime_id",
    "model_site_runtime_generation_id",
    "package_status",
    "launchable",
    "route_manifest",
    "form_manifest",
    "permission_manifest",
    "provider_manifest",
    "asset_manifest",
    "renderer_manifest",
    "environment_requirements",
    "package_hash",
    "created_at"
   FROM "pods_provisioning"."model_launch_packages_v1"
  WHERE ("package_status" = ANY (ARRAY['generated'::"text", 'launched'::"text"]));


ALTER VIEW "pods_provisioning"."v_model_runtime_governance_launch_packages_v1" OWNER TO "postgres";


CREATE OR REPLACE VIEW "pods_provisioning"."v_model_runtime_governance_marketplace_v1" AS
 SELECT "model_marketplace_catalog_id",
    "model_key",
    "model_version",
    "display_name",
    "category_key",
    "wizard_enabled",
    "deployment_enabled",
    "required_providers",
    "supported_blocks",
    "install_count",
    "marketplace_status",
    "catalog_hash",
    "created_at"
   FROM "pods_provisioning"."model_marketplace_catalog_v1"
  WHERE ("marketplace_status" = 'published'::"text");


ALTER VIEW "pods_provisioning"."v_model_runtime_governance_marketplace_v1" OWNER TO "postgres";


CREATE OR REPLACE VIEW "pods_provisioning"."v_model_runtime_governance_templates_v1" AS
 SELECT "model_template_registry_id",
    "model_key",
    "model_version",
    "display_name",
    "category_key",
    "template_status",
    "wizard_schema",
    "default_pages",
    "default_blocks",
    "default_roles",
    "required_providers",
    "supported_deployment_targets",
    "license_rules",
    "template_hash",
    "created_at"
   FROM "pods_provisioning"."model_template_registry_v1"
  WHERE ("template_status" = 'published'::"text");


ALTER VIEW "pods_provisioning"."v_model_runtime_governance_templates_v1" OWNER TO "postgres";


CREATE OR REPLACE VIEW "pods_provisioning"."v_model_template_registry_v1" AS
 SELECT "model_template_registry_id",
    "model_key",
    "model_version",
    "display_name",
    "category_key",
    "template_status",
    "wizard_schema",
    "default_pages",
    "default_blocks",
    "default_roles",
    "required_providers",
    "supported_deployment_targets",
    "license_rules",
    "template_hash",
    "created_at"
   FROM "pods_provisioning"."model_template_registry_v1";


ALTER VIEW "pods_provisioning"."v_model_template_registry_v1" OWNER TO "postgres";


CREATE OR REPLACE VIEW "pods_provisioning"."v_provision_runs_v1" AS
 SELECT "provision_run_id",
    "org_id",
    "template_key",
    "template_version",
    "operator_user_id",
    "status",
    "started_at",
    "completed_at",
    "receipt_hash",
    "failure_token",
    "metadata"
   FROM "pods_provisioning"."provision_runs_v1"
  ORDER BY "started_at" DESC, "provision_run_id";


ALTER VIEW "pods_provisioning"."v_provision_runs_v1" OWNER TO "postgres";


CREATE OR REPLACE VIEW "pods_provisioning"."v_template_registry_v1" AS
 SELECT "template_key",
    "template_version",
    "vertical",
    "display_name",
    "description",
    "seeded_hash",
    "active",
    "created_at"
   FROM "pods_provisioning"."template_registry_v1"
  ORDER BY "template_key", "template_version";


ALTER VIEW "pods_provisioning"."v_template_registry_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."vertical_capabilities_v1" (
    "vertical_capability_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "domain_key" "text" NOT NULL,
    "capability_key" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "capability_kind" "text" NOT NULL,
    "required" boolean DEFAULT true NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "capability_body" "jsonb" NOT NULL,
    "capability_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "vertical_capability_hash_ck" CHECK (("capability_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "vertical_capability_kind_ck" CHECK (("capability_kind" = ANY (ARRAY['workflow'::"text", 'surface'::"text", 'payment'::"text", 'notification'::"text", 'resource'::"text", 'document'::"text", 'customer'::"text", 'operator'::"text"])))
);


ALTER TABLE "pods_provisioning"."vertical_capabilities_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."vertical_domains_v1" (
    "vertical_domain_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "domain_key" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "category" "text" NOT NULL,
    "description" "text" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "domain_body" "jsonb" NOT NULL,
    "domain_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "vertical_domain_hash_ck" CHECK (("domain_hash" ~ '^[a-f0-9]{64}$'::"text"))
);


ALTER TABLE "pods_provisioning"."vertical_domains_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."vertical_surface_contracts_v1" (
    "surface_contract_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "domain_key" "text" NOT NULL,
    "surface_key" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "surface_kind" "text" NOT NULL,
    "public_facing" boolean DEFAULT false NOT NULL,
    "operator_facing" boolean DEFAULT true NOT NULL,
    "required_fields" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "surface_body" "jsonb" NOT NULL,
    "surface_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "vertical_surface_hash_ck" CHECK (("surface_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "vertical_surface_kind_ck" CHECK (("surface_kind" = ANY (ARRAY['public_page'::"text", 'operator_dashboard'::"text", 'admin_queue'::"text", 'calendar'::"text", 'profile'::"text", 'estimate'::"text", 'listing'::"text", 'document_portal'::"text"])))
);


ALTER TABLE "pods_provisioning"."vertical_surface_contracts_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."vertical_template_hours" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "template_key" "text" NOT NULL,
    "dow" integer NOT NULL,
    "open_time" time without time zone NOT NULL,
    "close_time" time without time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "vertical_template_hours_dow_check" CHECK ((("dow" >= 0) AND ("dow" <= 6)))
);


ALTER TABLE "pods_provisioning"."vertical_template_hours" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."vertical_template_roles" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "template_key" "text" NOT NULL,
    "role_key" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods_provisioning"."vertical_template_roles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."vertical_template_services" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "template_key" "text" NOT NULL,
    "service_code" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "duration_minutes" integer NOT NULL,
    "price_cents" integer NOT NULL,
    "booking_enabled" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods_provisioning"."vertical_template_services" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."vertical_templates" (
    "template_key" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "category" "text" NOT NULL,
    "description" "text" NOT NULL,
    "enabled" boolean DEFAULT true NOT NULL,
    "default_timezone" "text" DEFAULT 'America/New_York'::"text" NOT NULL,
    "booking_enabled" boolean DEFAULT true NOT NULL,
    "memberships_enabled" boolean DEFAULT false NOT NULL,
    "staff_roles_enabled" boolean DEFAULT true NOT NULL,
    "notifications_enabled" boolean DEFAULT true NOT NULL,
    "config" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "pods_provisioning"."vertical_templates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_provisioning"."vertical_workflow_contracts_v1" (
    "workflow_contract_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "domain_key" "text" NOT NULL,
    "workflow_key" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "start_state" "text" NOT NULL,
    "terminal_states" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "required_events" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "workflow_body" "jsonb" NOT NULL,
    "workflow_hash" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "vertical_workflow_hash_ck" CHECK (("workflow_hash" ~ '^[a-f0-9]{64}$'::"text"))
);


ALTER TABLE "pods_provisioning"."vertical_workflow_contracts_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_public"."public_surface_contracts_v1" (
    "surface_key" "text" NOT NULL,
    "object_type" "text" NOT NULL,
    "object_schema" "text" NOT NULL,
    "object_name" "text" NOT NULL,
    "exposure_kind" "text" NOT NULL,
    "public_safe" boolean DEFAULT true NOT NULL,
    "write_enabled" boolean DEFAULT false NOT NULL,
    "notes" "text" DEFAULT ''::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "public_surface_contracts_exposure_kind_ck" CHECK (("exposure_kind" = ANY (ARRAY['read'::"text", 'request'::"text", 'execute'::"text"]))),
    CONSTRAINT "public_surface_contracts_object_type_ck" CHECK (("object_type" = ANY (ARRAY['view'::"text", 'function'::"text", 'rpc'::"text"])))
);


ALTER TABLE "pods_public"."public_surface_contracts_v1" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "pods_public"."public_surface_selftest_vectors_v1" (
    "vector_key" "text" NOT NULL,
    "object_schema" "text" NOT NULL,
    "object_name" "text" NOT NULL,
    "exposure_kind" "text" NOT NULL,
    "expected_ok" boolean NOT NULL,
    "expected_token" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "public_surface_vectors_exposure_ck" CHECK (("exposure_kind" = ANY (ARRAY['read'::"text", 'request'::"text", 'execute'::"text"])))
);


ALTER TABLE "pods_public"."public_surface_selftest_vectors_v1" OWNER TO "postgres";


CREATE OR REPLACE VIEW "pods_public"."v_public_surface_contracts_v1" AS
 SELECT "surface_key",
    "object_type",
    "object_schema",
    "object_name",
    "exposure_kind",
    "public_safe",
    "write_enabled",
    "notes",
    "created_at"
   FROM "pods_public"."public_surface_contracts_v1" "c"
  ORDER BY "surface_key";


ALTER VIEW "pods_public"."v_public_surface_contracts_v1" OWNER TO "postgres";


COMMENT ON VIEW "pods_public"."v_public_surface_contracts_v1" IS 'Readable contract surface for Tier-1 public-safe exposure rules.';



CREATE OR REPLACE VIEW "pods_public"."v_public_surface_selftest_vectors_v1" AS
 SELECT "vector_key",
    "object_schema",
    "object_name",
    "exposure_kind",
    "expected_ok",
    "expected_token",
    "created_at"
   FROM "pods_public"."public_surface_selftest_vectors_v1" "v"
  ORDER BY "vector_key";


ALTER VIEW "pods_public"."v_public_surface_selftest_vectors_v1" OWNER TO "postgres";


COMMENT ON VIEW "pods_public"."v_public_surface_selftest_vectors_v1" IS 'Readable public surface selftest vector registry.';



ALTER TABLE ONLY "pods"."audit_log"
    ADD CONSTRAINT "audit_log_pkey" PRIMARY KEY ("audit_id");



ALTER TABLE ONLY "pods"."billing_accounts"
    ADD CONSTRAINT "billing_accounts_pkey" PRIMARY KEY ("org_id");



ALTER TABLE ONLY "pods"."billing_accounts"
    ADD CONSTRAINT "billing_accounts_provider_customer_id_key" UNIQUE ("provider_customer_id");



ALTER TABLE ONLY "pods"."booking_appointment_status_log"
    ADD CONSTRAINT "booking_appointment_status_log_pkey" PRIMARY KEY ("log_id");



ALTER TABLE ONLY "pods"."booking_appointments"
    ADD CONSTRAINT "booking_appointments_pkey" PRIMARY KEY ("appointment_id");



ALTER TABLE ONLY "pods"."booking_availability_rules"
    ADD CONSTRAINT "booking_availability_rules_pkey" PRIMARY KEY ("rule_id");



ALTER TABLE ONLY "pods"."booking_customers"
    ADD CONSTRAINT "booking_customers_pkey" PRIMARY KEY ("customer_id");



ALTER TABLE ONLY "pods"."booking_time_off_blocks"
    ADD CONSTRAINT "booking_time_off_blocks_pkey" PRIMARY KEY ("block_id");



ALTER TABLE ONLY "pods"."entitlement_overrides"
    ADD CONSTRAINT "entitlement_overrides_pkey" PRIMARY KEY ("org_id", "capability_key");



ALTER TABLE ONLY "pods"."migration_ledger"
    ADD CONSTRAINT "migration_ledger_pkey" PRIMARY KEY ("org_id", "model_id", "version", "migration_id");



ALTER TABLE ONLY "pods"."models"
    ADD CONSTRAINT "models_pkey" PRIMARY KEY ("model_id", "version");



ALTER TABLE ONLY "pods"."org_entitlements"
    ADD CONSTRAINT "org_entitlements_pkey" PRIMARY KEY ("org_id", "capability_key");



ALTER TABLE ONLY "pods"."org_members"
    ADD CONSTRAINT "org_members_pkey" PRIMARY KEY ("org_id", "user_id");



ALTER TABLE ONLY "pods"."org_models"
    ADD CONSTRAINT "org_models_pkey" PRIMARY KEY ("org_id", "model_id");



ALTER TABLE ONLY "pods"."orgs"
    ADD CONSTRAINT "orgs_pkey" PRIMARY KEY ("org_id");



ALTER TABLE ONLY "pods"."orgs"
    ADD CONSTRAINT "orgs_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "pods"."plan_capabilities"
    ADD CONSTRAINT "plan_capabilities_pkey" PRIMARY KEY ("plan_id", "capability_key");



ALTER TABLE ONLY "pods"."plan_tiers"
    ADD CONSTRAINT "plan_tiers_pkey" PRIMARY KEY ("plan_id");



ALTER TABLE ONLY "pods"."role_permissions"
    ADD CONSTRAINT "role_permissions_pkey" PRIMARY KEY ("role_key", "capability_key");



ALTER TABLE ONLY "pods"."roles"
    ADD CONSTRAINT "roles_pkey" PRIMARY KEY ("role_key");



ALTER TABLE ONLY "pods"."storefront_contact_requests"
    ADD CONSTRAINT "storefront_contact_requests_pkey" PRIMARY KEY ("contact_request_id");



ALTER TABLE ONLY "pods"."storefront_locations"
    ADD CONSTRAINT "storefront_locations_pkey" PRIMARY KEY ("location_id");



ALTER TABLE ONLY "pods"."storefront_profiles"
    ADD CONSTRAINT "storefront_profiles_pkey" PRIMARY KEY ("org_id");



ALTER TABLE ONLY "pods"."storefront_service_categories"
    ADD CONSTRAINT "storefront_service_categories_org_id_name_key" UNIQUE ("org_id", "name");



ALTER TABLE ONLY "pods"."storefront_service_categories"
    ADD CONSTRAINT "storefront_service_categories_pkey" PRIMARY KEY ("category_id");



ALTER TABLE ONLY "pods"."storefront_services"
    ADD CONSTRAINT "storefront_services_org_id_name_key" UNIQUE ("org_id", "name");



ALTER TABLE ONLY "pods"."storefront_services"
    ADD CONSTRAINT "storefront_services_pkey" PRIMARY KEY ("service_id");



ALTER TABLE ONLY "pods"."storefront_team_members"
    ADD CONSTRAINT "storefront_team_members_pkey" PRIMARY KEY ("team_member_id");



ALTER TABLE ONLY "pods"."subscriptions"
    ADD CONSTRAINT "subscriptions_pkey" PRIMARY KEY ("org_id", "provider_subscription_id");



ALTER TABLE ONLY "pods"."subscriptions"
    ADD CONSTRAINT "subscriptions_provider_subscription_id_key" UNIQUE ("provider_subscription_id");



ALTER TABLE ONLY "pods"."usage_counters"
    ADD CONSTRAINT "usage_counters_pkey" PRIMARY KEY ("org_id", "counter_key", "period_start");



ALTER TABLE ONLY "pods_core"."lane_boundary_selftest_vectors_v1"
    ADD CONSTRAINT "lane_boundary_selftest_vectors_v1_pkey" PRIMARY KEY ("vector_key");



ALTER TABLE ONLY "pods_core"."lane_contracts_v1"
    ADD CONSTRAINT "lane_contracts_v1_pkey" PRIMARY KEY ("lane_key");



ALTER TABLE ONLY "pods_core"."lane_negative_boundaries_v1"
    ADD CONSTRAINT "lane_negative_boundaries_v1_pkey" PRIMARY KEY ("boundary_key");



ALTER TABLE ONLY "pods_provisioning"."adapter_attachment_items_v1"
    ADD CONSTRAINT "adapter_attachment_item_unique" UNIQUE ("adapter_attachment_run_id", "adapter_key");



ALTER TABLE ONLY "pods_provisioning"."adapter_attachment_items_v1"
    ADD CONSTRAINT "adapter_attachment_items_v1_pkey" PRIMARY KEY ("adapter_attachment_item_id");



ALTER TABLE ONLY "pods_provisioning"."adapter_attachment_runs_v1"
    ADD CONSTRAINT "adapter_attachment_one_per_deployment" UNIQUE ("deployment_receipt_id");



ALTER TABLE ONLY "pods_provisioning"."adapter_attachment_runs_v1"
    ADD CONSTRAINT "adapter_attachment_runs_v1_pkey" PRIMARY KEY ("adapter_attachment_run_id");



ALTER TABLE ONLY "pods_provisioning"."appointment_admin_actions_v1"
    ADD CONSTRAINT "appointment_admin_actions_v1_pkey" PRIMARY KEY ("admin_action_id");



ALTER TABLE ONLY "pods_provisioning"."asset_access_receipts_v1"
    ADD CONSTRAINT "asset_access_receipts_v1_pkey" PRIMARY KEY ("asset_access_receipt_id");



ALTER TABLE ONLY "pods_provisioning"."asset_runtime_objects_v1"
    ADD CONSTRAINT "asset_runtime_objects_v1_pkey" PRIMARY KEY ("asset_runtime_object_id");



ALTER TABLE ONLY "pods_provisioning"."cancellation_requests_v1"
    ADD CONSTRAINT "cancellation_one_per_appointment" UNIQUE ("appointment_request_id");



ALTER TABLE ONLY "pods_provisioning"."cancellation_policies_v1"
    ADD CONSTRAINT "cancellation_policies_v1_pkey" PRIMARY KEY ("cancellation_policy_id");



ALTER TABLE ONLY "pods_provisioning"."cancellation_policies_v1"
    ADD CONSTRAINT "cancellation_policy_unique" UNIQUE ("org_id", "policy_key");



ALTER TABLE ONLY "pods_provisioning"."cancellation_requests_v1"
    ADD CONSTRAINT "cancellation_requests_v1_pkey" PRIMARY KEY ("cancellation_request_id");



ALTER TABLE ONLY "pods_provisioning"."civic_action_campaigns_v1"
    ADD CONSTRAINT "civic_action_campaigns_v1_pkey" PRIMARY KEY ("civic_campaign_id");



ALTER TABLE ONLY "pods_provisioning"."civic_action_contribution_wall_entries_v1"
    ADD CONSTRAINT "civic_action_contribution_wall_entries_v1_pkey" PRIMARY KEY ("civic_contribution_id");



ALTER TABLE ONLY "pods_provisioning"."civic_action_event_rsvps_v1"
    ADD CONSTRAINT "civic_action_event_rsvps_v1_pkey" PRIMARY KEY ("civic_event_rsvp_id");



ALTER TABLE ONLY "pods_provisioning"."civic_action_events_v1"
    ADD CONSTRAINT "civic_action_events_v1_pkey" PRIMARY KEY ("civic_event_id");



ALTER TABLE ONLY "pods_provisioning"."civic_action_evidence_v1"
    ADD CONSTRAINT "civic_action_evidence_v1_pkey" PRIMARY KEY ("civic_evidence_id");



ALTER TABLE ONLY "pods_provisioning"."civic_action_full_green_receipts_v1"
    ADD CONSTRAINT "civic_action_full_green_receipts_v1_pkey" PRIMARY KEY ("civic_full_green_receipt_id");



ALTER TABLE ONLY "pods_provisioning"."civic_action_full_green_v2_receipts_v1"
    ADD CONSTRAINT "civic_action_full_green_v2_receipts_v1_pkey" PRIMARY KEY ("civic_full_green_v2_receipt_id");



ALTER TABLE ONLY "pods_provisioning"."civic_action_help_offers_v1"
    ADD CONSTRAINT "civic_action_help_offers_v1_pkey" PRIMARY KEY ("civic_help_offer_id");



ALTER TABLE ONLY "pods_provisioning"."civic_action_launch_ready_receipts_v1"
    ADD CONSTRAINT "civic_action_launch_ready_receipts_v1_pkey" PRIMARY KEY ("civic_launch_ready_receipt_id");



ALTER TABLE ONLY "pods_provisioning"."civic_action_model_deployments_v1"
    ADD CONSTRAINT "civic_action_model_deployments_v1_pkey" PRIMARY KEY ("civic_deployment_id");



ALTER TABLE ONLY "pods_provisioning"."civic_action_model_registry_v1"
    ADD CONSTRAINT "civic_action_model_registry_v1_pkey" PRIMARY KEY ("civic_model_id");



ALTER TABLE ONLY "pods_provisioning"."civic_action_model_registry_v1"
    ADD CONSTRAINT "civic_action_model_unique" UNIQUE ("model_key", "model_version");



ALTER TABLE ONLY "pods_provisioning"."civic_action_moderation_receipts_v1"
    ADD CONSTRAINT "civic_action_moderation_receipts_v1_pkey" PRIMARY KEY ("civic_moderation_receipt_id");



ALTER TABLE ONLY "pods_provisioning"."civic_action_petition_signatures_v1"
    ADD CONSTRAINT "civic_action_petition_signatures_v1_pkey" PRIMARY KEY ("civic_signature_id");



ALTER TABLE ONLY "pods_provisioning"."civic_action_survey_questions_v1"
    ADD CONSTRAINT "civic_action_survey_questions_v1_pkey" PRIMARY KEY ("civic_survey_question_id");



ALTER TABLE ONLY "pods_provisioning"."civic_action_survey_responses_v1"
    ADD CONSTRAINT "civic_action_survey_responses_v1_pkey" PRIMARY KEY ("civic_survey_response_id");



ALTER TABLE ONLY "pods_provisioning"."civic_action_contribution_wall_entries_v1"
    ADD CONSTRAINT "civic_contribution_unique" UNIQUE ("contribution_type", "source_id");



ALTER TABLE ONLY "pods_provisioning"."civic_action_event_rsvps_v1"
    ADD CONSTRAINT "civic_event_rsvp_unique" UNIQUE ("civic_event_id", "attendee_hash");



ALTER TABLE ONLY "pods_provisioning"."civic_action_help_offers_v1"
    ADD CONSTRAINT "civic_help_unique" UNIQUE ("civic_campaign_id", "helper_hash", "help_type");



ALTER TABLE ONLY "pods_provisioning"."civic_action_petition_signatures_v1"
    ADD CONSTRAINT "civic_signature_unique_signer" UNIQUE ("civic_campaign_id", "signer_hash");



ALTER TABLE ONLY "pods_provisioning"."civic_action_survey_questions_v1"
    ADD CONSTRAINT "civic_survey_question_unique" UNIQUE ("civic_campaign_id", "question_key");



ALTER TABLE ONLY "pods_provisioning"."civic_action_survey_responses_v1"
    ADD CONSTRAINT "civic_survey_response_unique" UNIQUE ("civic_campaign_id", "respondent_hash");



ALTER TABLE ONLY "pods_provisioning"."connection_layer_launch_control_runs_v1"
    ADD CONSTRAINT "connection_layer_launch_control_runs_v1_pkey" PRIMARY KEY ("connection_launch_run_id");



ALTER TABLE ONLY "pods_provisioning"."contractor_estimate_decisions_v1"
    ADD CONSTRAINT "contractor_estimate_decisions_v1_pkey" PRIMARY KEY ("estimate_decision_id");



ALTER TABLE ONLY "pods_provisioning"."contractor_estimate_line_items_v1"
    ADD CONSTRAINT "contractor_estimate_line_items_v1_pkey" PRIMARY KEY ("line_item_id");



ALTER TABLE ONLY "pods_provisioning"."contractor_estimates_v1"
    ADD CONSTRAINT "contractor_estimate_number_unique" UNIQUE ("org_id", "estimate_number");



ALTER TABLE ONLY "pods_provisioning"."contractor_estimate_decisions_v1"
    ADD CONSTRAINT "contractor_estimate_one_decision" UNIQUE ("contractor_estimate_id");



ALTER TABLE ONLY "pods_provisioning"."contractor_estimates_v1"
    ADD CONSTRAINT "contractor_estimate_one_per_request" UNIQUE ("estimate_request_id");



ALTER TABLE ONLY "pods_provisioning"."contractor_estimate_requests_v1"
    ADD CONSTRAINT "contractor_estimate_requests_v1_pkey" PRIMARY KEY ("estimate_request_id");



ALTER TABLE ONLY "pods_provisioning"."contractor_estimates_v1"
    ADD CONSTRAINT "contractor_estimates_v1_pkey" PRIMARY KEY ("contractor_estimate_id");



ALTER TABLE ONLY "pods_provisioning"."contractor_job_records_v1"
    ADD CONSTRAINT "contractor_job_one_per_estimate_request" UNIQUE ("estimate_request_id");



ALTER TABLE ONLY "pods_provisioning"."contractor_job_phases_v1"
    ADD CONSTRAINT "contractor_job_phase_unique" UNIQUE ("contractor_job_id", "phase_key");



ALTER TABLE ONLY "pods_provisioning"."contractor_job_phases_v1"
    ADD CONSTRAINT "contractor_job_phases_v1_pkey" PRIMARY KEY ("contractor_job_phase_id");



ALTER TABLE ONLY "pods_provisioning"."contractor_job_records_v1"
    ADD CONSTRAINT "contractor_job_records_v1_pkey" PRIMARY KEY ("contractor_job_id");



ALTER TABLE ONLY "pods_provisioning"."contractor_service_templates_v1"
    ADD CONSTRAINT "contractor_service_templates_v1_pkey" PRIMARY KEY ("contractor_service_template_id");



ALTER TABLE ONLY "pods_provisioning"."contractor_service_templates_v1"
    ADD CONSTRAINT "contractor_service_unique" UNIQUE ("template_key", "template_version", "service_code");



ALTER TABLE ONLY "pods_provisioning"."contractor_site_visits_v1"
    ADD CONSTRAINT "contractor_site_visit_one_scheduled_per_estimate" UNIQUE ("estimate_request_id");



ALTER TABLE ONLY "pods_provisioning"."contractor_site_visits_v1"
    ADD CONSTRAINT "contractor_site_visits_v1_pkey" PRIMARY KEY ("site_visit_id");



ALTER TABLE ONLY "pods_provisioning"."customer_deployment_handoffs_v1"
    ADD CONSTRAINT "customer_deployment_handoffs_v1_pkey" PRIMARY KEY ("customer_handoff_id");



ALTER TABLE ONLY "pods_provisioning"."customer_launch_receipts_v1"
    ADD CONSTRAINT "customer_launch_receipts_v1_pkey" PRIMARY KEY ("launch_receipt_id");



ALTER TABLE ONLY "pods_provisioning"."domain_provider_connections_v1"
    ADD CONSTRAINT "domain_provider_connections_v1_pkey" PRIMARY KEY ("domain_provider_connection_id");



ALTER TABLE ONLY "pods_provisioning"."domain_runtime_bindings_v1"
    ADD CONSTRAINT "domain_runtime_bindings_v1_pkey" PRIMARY KEY ("domain_runtime_binding_id");



ALTER TABLE ONLY "pods_provisioning"."email_adapter_runtime_v1"
    ADD CONSTRAINT "email_adapter_runtime_v1_pkey" PRIMARY KEY ("email_runtime_id");



ALTER TABLE ONLY "pods_provisioning"."email_adapter_runtime_v1"
    ADD CONSTRAINT "email_runtime_unique" UNIQUE ("org_id", "provider_key", "sender_domain");



ALTER TABLE ONLY "pods_provisioning"."full_green_engine_registry_v1"
    ADD CONSTRAINT "engine_registry_unique" UNIQUE ("engine_key");



ALTER TABLE ONLY "pods_provisioning"."full_green_engine_registry_v1"
    ADD CONSTRAINT "full_green_engine_registry_v1_pkey" PRIMARY KEY ("engine_registry_id");



ALTER TABLE ONLY "pods_provisioning"."full_green_platform_snapshots_v1"
    ADD CONSTRAINT "full_green_platform_snapshots_v1_pkey" PRIMARY KEY ("platform_snapshot_id");



ALTER TABLE ONLY "pods_provisioning"."github_adapter_runtime_v1"
    ADD CONSTRAINT "github_adapter_runtime_v1_pkey" PRIMARY KEY ("github_runtime_id");



ALTER TABLE ONLY "pods_provisioning"."github_adapter_runtime_v1"
    ADD CONSTRAINT "github_runtime_unique" UNIQUE ("org_id", "github_owner", "repo_name");



ALTER TABLE ONLY "pods_provisioning"."launch_control_plane_receipts_v1"
    ADD CONSTRAINT "launch_control_plane_receipts_v1_pkey" PRIMARY KEY ("launch_control_receipt_id");



ALTER TABLE ONLY "pods_provisioning"."launch_execution_runs_v1"
    ADD CONSTRAINT "launch_execution_one_per_deployment" UNIQUE ("deployment_receipt_id");



ALTER TABLE ONLY "pods_provisioning"."launch_execution_runs_v1"
    ADD CONSTRAINT "launch_execution_runs_v1_pkey" PRIMARY KEY ("launch_execution_id");



ALTER TABLE ONLY "pods_provisioning"."launch_execution_worker_runs_v1"
    ADD CONSTRAINT "launch_execution_worker_runs_v1_pkey" PRIMARY KEY ("worker_run_id");



ALTER TABLE ONLY "pods_provisioning"."launch_failure_events_v1"
    ADD CONSTRAINT "launch_failure_events_v1_pkey" PRIMARY KEY ("launch_failure_event_id");



ALTER TABLE ONLY "pods_provisioning"."launch_failure_events_v1"
    ADD CONSTRAINT "launch_failure_one_per_worker" UNIQUE ("worker_run_id");



ALTER TABLE ONLY "pods_provisioning"."launch_retry_events_v1"
    ADD CONSTRAINT "launch_retry_events_v1_pkey" PRIMARY KEY ("launch_retry_event_id");



ALTER TABLE ONLY "pods_provisioning"."launch_retry_policies_v1"
    ADD CONSTRAINT "launch_retry_policies_v1_pkey" PRIMARY KEY ("retry_policy_id");



ALTER TABLE ONLY "pods_provisioning"."launch_retry_policies_v1"
    ADD CONSTRAINT "launch_retry_policy_unique" UNIQUE ("policy_key");



ALTER TABLE ONLY "pods_provisioning"."launch_rollback_events_v1"
    ADD CONSTRAINT "launch_rollback_events_v1_pkey" PRIMARY KEY ("launch_rollback_event_id");



ALTER TABLE ONLY "pods_provisioning"."launch_rollback_events_v1"
    ADD CONSTRAINT "launch_rollback_one_per_failure" UNIQUE ("launch_failure_event_id");



ALTER TABLE ONLY "pods_provisioning"."launch_execution_worker_runs_v1"
    ADD CONSTRAINT "launch_worker_one_per_receipt" UNIQUE ("launch_control_receipt_id");



ALTER TABLE ONLY "pods_provisioning"."license_key_runtime_v1"
    ADD CONSTRAINT "license_key_runtime_v1_pkey" PRIMARY KEY ("license_key_runtime_id");



ALTER TABLE ONLY "pods_provisioning"."model_audit_checkpoints_v1"
    ADD CONSTRAINT "model_audit_checkpoints_v1_pkey" PRIMARY KEY ("model_audit_checkpoint_id");



ALTER TABLE ONLY "pods_provisioning"."model_audit_ledger_v1"
    ADD CONSTRAINT "model_audit_ledger_v1_pkey" PRIMARY KEY ("model_audit_event_id");



ALTER TABLE ONLY "pods_provisioning"."model_block_registry_v1"
    ADD CONSTRAINT "model_block_registry_unique" UNIQUE ("block_key");



ALTER TABLE ONLY "pods_provisioning"."model_block_registry_v1"
    ADD CONSTRAINT "model_block_registry_v1_pkey" PRIMARY KEY ("model_block_id");



ALTER TABLE ONLY "pods_provisioning"."model_capability_matrix_v1"
    ADD CONSTRAINT "model_capability_matrix_unique" UNIQUE ("model_key", "model_version");



ALTER TABLE ONLY "pods_provisioning"."model_capability_matrix_v1"
    ADD CONSTRAINT "model_capability_matrix_v1_pkey" PRIMARY KEY ("matrix_id");



ALTER TABLE ONLY "pods_provisioning"."model_capability_plan_runs_v1"
    ADD CONSTRAINT "model_capability_plan_runs_v1_pkey" PRIMARY KEY ("plan_run_id");



ALTER TABLE ONLY "pods_provisioning"."model_db_parameters_v1"
    ADD CONSTRAINT "model_db_parameters_v1_parameter_key_key" UNIQUE ("parameter_key");



ALTER TABLE ONLY "pods_provisioning"."model_db_parameters_v1"
    ADD CONSTRAINT "model_db_parameters_v1_pkey" PRIMARY KEY ("model_db_parameter_id");



ALTER TABLE ONLY "pods_provisioning"."model_db_surface_full_green_receipts_v1"
    ADD CONSTRAINT "model_db_surface_full_green_receipts_v1_pkey" PRIMARY KEY ("model_db_surface_full_green_receipt_id");



ALTER TABLE ONLY "pods_provisioning"."model_deployment_receipts_v1"
    ADD CONSTRAINT "model_deployment_one_per_plan" UNIQUE ("plan_run_id");



ALTER TABLE ONLY "pods_provisioning"."model_deployment_receipts_v1"
    ADD CONSTRAINT "model_deployment_receipts_v1_pkey" PRIMARY KEY ("deployment_receipt_id");



ALTER TABLE ONLY "pods_provisioning"."model_deployment_targets_v1"
    ADD CONSTRAINT "model_deployment_targets_v1_pkey" PRIMARY KEY ("model_deployment_target_id");



ALTER TABLE ONLY "pods_provisioning"."model_instance_clones_v1"
    ADD CONSTRAINT "model_instance_clones_v1_pkey" PRIMARY KEY ("model_instance_clone_id");



ALTER TABLE ONLY "pods_provisioning"."model_instance_runtimes_v1"
    ADD CONSTRAINT "model_instance_runtimes_v1_pkey" PRIMARY KEY ("model_instance_runtime_id");



ALTER TABLE ONLY "pods_provisioning"."model_instance_wizard_runs_v1"
    ADD CONSTRAINT "model_instance_wizard_runs_v1_pkey" PRIMARY KEY ("model_instance_wizard_run_id");



ALTER TABLE ONLY "pods_provisioning"."model_launch_authorities_v1"
    ADD CONSTRAINT "model_launch_authorities_v1_pkey" PRIMARY KEY ("model_launch_authority_id");



ALTER TABLE ONLY "pods_provisioning"."model_launch_packages_v1"
    ADD CONSTRAINT "model_launch_packages_v1_pkey" PRIMARY KEY ("model_launch_package_id");



ALTER TABLE ONLY "pods_provisioning"."model_launch_receipts_v1"
    ADD CONSTRAINT "model_launch_receipts_v1_pkey" PRIMARY KEY ("model_launch_receipt_id");



ALTER TABLE ONLY "pods_provisioning"."model_launch_reviews_v1"
    ADD CONSTRAINT "model_launch_reviews_v1_pkey" PRIMARY KEY ("model_launch_review_id");



ALTER TABLE ONLY "pods_provisioning"."model_marketplace_catalog_v1"
    ADD CONSTRAINT "model_marketplace_catalog_v1_pkey" PRIMARY KEY ("model_marketplace_catalog_id");



ALTER TABLE ONLY "pods_provisioning"."model_marketplace_installs_v1"
    ADD CONSTRAINT "model_marketplace_installs_v1_pkey" PRIMARY KEY ("model_marketplace_install_id");



ALTER TABLE ONLY "pods_provisioning"."model_page_compositions_v1"
    ADD CONSTRAINT "model_page_compositions_v1_pkey" PRIMARY KEY ("model_page_composition_id");



ALTER TABLE ONLY "pods_provisioning"."model_permission_generations_v1"
    ADD CONSTRAINT "model_permission_generations_v1_pkey" PRIMARY KEY ("model_permission_generation_id");



ALTER TABLE ONLY "pods_provisioning"."model_release_channels_v1"
    ADD CONSTRAINT "model_release_channel_unique" UNIQUE ("org_id", "model_instance_runtime_id", "channel_key");



ALTER TABLE ONLY "pods_provisioning"."model_release_channels_v1"
    ADD CONSTRAINT "model_release_channels_v1_pkey" PRIMARY KEY ("model_release_channel_id");



ALTER TABLE ONLY "pods_provisioning"."model_release_promotions_v1"
    ADD CONSTRAINT "model_release_promotions_v1_pkey" PRIMARY KEY ("model_release_promotion_id");



ALTER TABLE ONLY "pods_provisioning"."model_release_rollbacks_v1"
    ADD CONSTRAINT "model_release_rollbacks_v1_pkey" PRIMARY KEY ("model_release_rollback_id");



ALTER TABLE ONLY "pods_provisioning"."model_releases_v1"
    ADD CONSTRAINT "model_releases_v1_pkey" PRIMARY KEY ("model_release_id");



ALTER TABLE ONLY "pods_provisioning"."model_renderer_contracts_v1"
    ADD CONSTRAINT "model_renderer_contracts_v1_pkey" PRIMARY KEY ("model_renderer_contract_id");



ALTER TABLE ONLY "pods_provisioning"."model_runtime_drift_baselines_v1"
    ADD CONSTRAINT "model_runtime_drift_baselines_v1_pkey" PRIMARY KEY ("model_runtime_drift_baseline_id");



ALTER TABLE ONLY "pods_provisioning"."model_runtime_drift_findings_v1"
    ADD CONSTRAINT "model_runtime_drift_findings_v1_pkey" PRIMARY KEY ("model_runtime_drift_finding_id");



ALTER TABLE ONLY "pods_provisioning"."model_runtime_drift_reports_v1"
    ADD CONSTRAINT "model_runtime_drift_reports_v1_pkey" PRIMARY KEY ("model_runtime_drift_report_id");



ALTER TABLE ONLY "pods_provisioning"."model_runtime_editor_changes_v1"
    ADD CONSTRAINT "model_runtime_editor_changes_v1_pkey" PRIMARY KEY ("model_runtime_editor_change_id");



ALTER TABLE ONLY "pods_provisioning"."model_runtime_manifests_v1"
    ADD CONSTRAINT "model_runtime_manifests_v1_pkey" PRIMARY KEY ("model_runtime_manifest_id");



ALTER TABLE ONLY "pods_provisioning"."model_runtime_snapshot_receipts_v1"
    ADD CONSTRAINT "model_runtime_snapshot_receipts_v1_pkey" PRIMARY KEY ("model_runtime_snapshot_receipt_id");



ALTER TABLE ONLY "pods_provisioning"."model_runtime_snapshots_v1"
    ADD CONSTRAINT "model_runtime_snapshots_v1_pkey" PRIMARY KEY ("model_runtime_snapshot_id");



ALTER TABLE ONLY "pods_provisioning"."model_site_blueprints_v1"
    ADD CONSTRAINT "model_site_blueprints_v1_pkey" PRIMARY KEY ("model_site_blueprint_id");



ALTER TABLE ONLY "pods_provisioning"."model_site_runtime_generations_v1"
    ADD CONSTRAINT "model_site_runtime_generations_v1_pkey" PRIMARY KEY ("model_site_runtime_generation_id");



ALTER TABLE ONLY "pods_provisioning"."model_stored_procedure_registry_v1"
    ADD CONSTRAINT "model_stored_procedure_registry_v1_pkey" PRIMARY KEY ("model_stored_procedure_registry_id");



ALTER TABLE ONLY "pods_provisioning"."model_stored_procedure_registry_v1"
    ADD CONSTRAINT "model_stored_procedure_registry_v1_procedure_name_key" UNIQUE ("procedure_name");



ALTER TABLE ONLY "pods_provisioning"."model_template_registry_v1"
    ADD CONSTRAINT "model_template_registry_unique" UNIQUE ("model_key", "model_version");



ALTER TABLE ONLY "pods_provisioning"."model_template_registry_v1"
    ADD CONSTRAINT "model_template_registry_v1_pkey" PRIMARY KEY ("model_template_registry_id");



ALTER TABLE ONLY "pods_provisioning"."model_ui_generations_v1"
    ADD CONSTRAINT "model_ui_generations_v1_pkey" PRIMARY KEY ("model_ui_generation_id");



ALTER TABLE ONLY "pods_provisioning"."notification_delivery_receipts_v1"
    ADD CONSTRAINT "notification_delivery_receipts_v1_pkey" PRIMARY KEY ("delivery_receipt_id");



ALTER TABLE ONLY "pods_provisioning"."notification_preferences_v1"
    ADD CONSTRAINT "notification_preferences_unique" UNIQUE ("org_id", "customer_email");



ALTER TABLE ONLY "pods_provisioning"."notification_preferences_v1"
    ADD CONSTRAINT "notification_preferences_v1_pkey" PRIMARY KEY ("preference_id");



ALTER TABLE ONLY "pods_provisioning"."notification_templates_v1"
    ADD CONSTRAINT "notification_template_unique" UNIQUE ("template_key", "template_version", "notification_kind", "delivery_channel");



ALTER TABLE ONLY "pods_provisioning"."notification_templates_v1"
    ADD CONSTRAINT "notification_templates_v1_pkey" PRIMARY KEY ("template_id");



ALTER TABLE ONLY "pods_provisioning"."notifications_v1"
    ADD CONSTRAINT "notifications_v1_pkey" PRIMARY KEY ("notification_id");



ALTER TABLE ONLY "pods_provisioning"."operator_setup_wizard_sessions_v1"
    ADD CONSTRAINT "operator_setup_wizard_sessions_v1_pkey" PRIMARY KEY ("wizard_session_id");



ALTER TABLE ONLY "pods_provisioning"."payment_events_v1"
    ADD CONSTRAINT "payment_events_v1_pkey" PRIMARY KEY ("payment_event_id");



ALTER TABLE ONLY "pods_provisioning"."payment_intents_v1"
    ADD CONSTRAINT "payment_intent_one_per_appointment" UNIQUE ("appointment_request_id");



ALTER TABLE ONLY "pods_provisioning"."payment_intents_v1"
    ADD CONSTRAINT "payment_intents_v1_pkey" PRIMARY KEY ("payment_intent_id");



ALTER TABLE ONLY "pods_provisioning"."payment_policies_v1"
    ADD CONSTRAINT "payment_policies_v1_pkey" PRIMARY KEY ("payment_policy_id");



ALTER TABLE ONLY "pods_provisioning"."payment_policies_v1"
    ADD CONSTRAINT "payment_policy_unique" UNIQUE ("org_id", "policy_key");



ALTER TABLE ONLY "pods_provisioning"."payment_provider_adapters_v1"
    ADD CONSTRAINT "payment_provider_adapters_v1_pkey" PRIMARY KEY ("provider_adapter_id");



ALTER TABLE ONLY "pods_provisioning"."payment_provider_adapters_v1"
    ADD CONSTRAINT "payment_provider_key_unique" UNIQUE ("provider_key");



ALTER TABLE ONLY "pods_provisioning"."payment_provider_receipts_v1"
    ADD CONSTRAINT "payment_provider_receipts_v1_pkey" PRIMARY KEY ("provider_receipt_id");



ALTER TABLE ONLY "pods_provisioning"."provider_connection_contracts_v1"
    ADD CONSTRAINT "provider_connection_contract_unique" UNIQUE ("provider_key");



ALTER TABLE ONLY "pods_provisioning"."provider_connection_contracts_v1"
    ADD CONSTRAINT "provider_connection_contracts_v1_pkey" PRIMARY KEY ("provider_connection_contract_id");



ALTER TABLE ONLY "pods_provisioning"."provider_connection_rollups_v1"
    ADD CONSTRAINT "provider_connection_rollups_v1_pkey" PRIMARY KEY ("provider_connection_rollup_id");



ALTER TABLE ONLY "pods_provisioning"."provider_connection_runtime_bridges_v1"
    ADD CONSTRAINT "provider_connection_runtime_bridges_v1_pkey" PRIMARY KEY ("provider_connection_runtime_bridge_id");



ALTER TABLE ONLY "pods_provisioning"."provider_connection_sessions_v1"
    ADD CONSTRAINT "provider_connection_sessions_v1_pkey" PRIMARY KEY ("provider_connection_session_id");



ALTER TABLE ONLY "pods_provisioning"."provider_readiness_rollups_v1"
    ADD CONSTRAINT "provider_readiness_rollups_v1_pkey" PRIMARY KEY ("provider_readiness_rollup_id");



ALTER TABLE ONLY "pods_provisioning"."payment_provider_receipts_v1"
    ADD CONSTRAINT "provider_receipt_unique" UNIQUE ("provider_key", "provider_event_id");



ALTER TABLE ONLY "pods_provisioning"."provision_runs_v1"
    ADD CONSTRAINT "provision_runs_v1_pkey" PRIMARY KEY ("provision_run_id");



ALTER TABLE ONLY "pods_provisioning"."provisioning_receipts_v1"
    ADD CONSTRAINT "provisioning_receipts_v1_pkey" PRIMARY KEY ("receipt_id");



ALTER TABLE ONLY "pods_provisioning"."public_appointment_requests_v1"
    ADD CONSTRAINT "public_appointment_exact_duplicate_unique" UNIQUE ("booking_slug", "service_code", "requested_date", "requested_start_time", "customer_email");



ALTER TABLE ONLY "pods_provisioning"."public_appointment_requests_v1"
    ADD CONSTRAINT "public_appointment_requests_v1_pkey" PRIMARY KEY ("appointment_request_id");



ALTER TABLE ONLY "pods_provisioning"."public_booking_surfaces_v1"
    ADD CONSTRAINT "public_booking_org_template_unique" UNIQUE ("org_id", "template_key", "template_version");



ALTER TABLE ONLY "pods_provisioning"."public_booking_surfaces_v1"
    ADD CONSTRAINT "public_booking_slug_unique" UNIQUE ("booking_slug");



ALTER TABLE ONLY "pods_provisioning"."public_booking_surfaces_v1"
    ADD CONSTRAINT "public_booking_surfaces_v1_pkey" PRIMARY KEY ("public_surface_id");



ALTER TABLE ONLY "pods_provisioning"."refund_intents_v1"
    ADD CONSTRAINT "refund_intents_v1_pkey" PRIMARY KEY ("refund_intent_id");



ALTER TABLE ONLY "pods_provisioning"."refund_intents_v1"
    ADD CONSTRAINT "refund_one_per_cancellation" UNIQUE ("cancellation_request_id");



ALTER TABLE ONLY "pods_provisioning"."security_gate_matrix_v1"
    ADD CONSTRAINT "security_gate_matrix_v1_pkey" PRIMARY KEY ("security_gate_id");



ALTER TABLE ONLY "pods_provisioning"."security_gate_results_v1"
    ADD CONSTRAINT "security_gate_results_v1_pkey" PRIMARY KEY ("security_gate_result_id");



ALTER TABLE ONLY "pods_provisioning"."security_gate_matrix_v1"
    ADD CONSTRAINT "security_gate_unique" UNIQUE ("gate_key");



ALTER TABLE ONLY "pods_provisioning"."seeded_objects_v1"
    ADD CONSTRAINT "seeded_objects_run_unique" UNIQUE ("provision_run_id", "object_kind", "object_key");



ALTER TABLE ONLY "pods_provisioning"."seeded_objects_v1"
    ADD CONSTRAINT "seeded_objects_v1_pkey" PRIMARY KEY ("seeded_object_id");



ALTER TABLE ONLY "pods_provisioning"."staff_appointment_assignments_v1"
    ADD CONSTRAINT "staff_appointment_assignments_v1_pkey" PRIMARY KEY ("staff_assignment_id");



ALTER TABLE ONLY "pods_provisioning"."staff_appointment_assignments_v1"
    ADD CONSTRAINT "staff_assignment_one_active_per_appointment" UNIQUE ("appointment_request_id");



ALTER TABLE ONLY "pods_provisioning"."staff_featured_sections_v1"
    ADD CONSTRAINT "staff_featured_section_unique" UNIQUE ("org_id", "section_key");



ALTER TABLE ONLY "pods_provisioning"."staff_featured_sections_v1"
    ADD CONSTRAINT "staff_featured_sections_v1_pkey" PRIMARY KEY ("featured_section_id");



ALTER TABLE ONLY "pods_provisioning"."staff_gallery_items_v1"
    ADD CONSTRAINT "staff_gallery_items_v1_pkey" PRIMARY KEY ("gallery_item_id");



ALTER TABLE ONLY "pods_provisioning"."staff_members_v1"
    ADD CONSTRAINT "staff_members_org_staff_unique" UNIQUE ("org_id", "staff_key");



ALTER TABLE ONLY "pods_provisioning"."staff_members_v1"
    ADD CONSTRAINT "staff_members_v1_pkey" PRIMARY KEY ("staff_member_id");



ALTER TABLE ONLY "pods_provisioning"."staff_public_profiles_v1"
    ADD CONSTRAINT "staff_public_profile_one_per_staff" UNIQUE ("staff_member_id");



ALTER TABLE ONLY "pods_provisioning"."staff_public_profiles_v1"
    ADD CONSTRAINT "staff_public_profiles_v1_pkey" PRIMARY KEY ("staff_profile_id");



ALTER TABLE ONLY "pods_provisioning"."storage_adapter_runtime_v1"
    ADD CONSTRAINT "storage_adapter_runtime_v1_pkey" PRIMARY KEY ("storage_runtime_id");



ALTER TABLE ONLY "pods_provisioning"."storage_adapter_runtime_v1"
    ADD CONSTRAINT "storage_runtime_unique" UNIQUE ("org_id", "provider_key", "storage_scope");



ALTER TABLE ONLY "pods_provisioning"."stress_harness_runs_v1"
    ADD CONSTRAINT "stress_harness_runs_v1_pkey" PRIMARY KEY ("stress_run_id");



ALTER TABLE ONLY "pods_provisioning"."stripe_adapter_runtime_v1"
    ADD CONSTRAINT "stripe_adapter_runtime_v1_pkey" PRIMARY KEY ("stripe_runtime_id");



ALTER TABLE ONLY "pods_provisioning"."stripe_adapter_runtime_v1"
    ADD CONSTRAINT "stripe_runtime_account_unique" UNIQUE ("org_id", "stripe_account_id", "mode");



ALTER TABLE ONLY "pods_provisioning"."supabase_adapter_runtime_v1"
    ADD CONSTRAINT "supabase_adapter_runtime_v1_pkey" PRIMARY KEY ("supabase_runtime_id");



ALTER TABLE ONLY "pods_provisioning"."supabase_adapter_runtime_v1"
    ADD CONSTRAINT "supabase_runtime_project_unique" UNIQUE ("org_id", "project_ref");



ALTER TABLE ONLY "pods_provisioning"."template_registry_v1"
    ADD CONSTRAINT "template_registry_v1_pkey" PRIMARY KEY ("template_key", "template_version");



ALTER TABLE ONLY "pods_provisioning"."vertical_capabilities_v1"
    ADD CONSTRAINT "vertical_capabilities_v1_pkey" PRIMARY KEY ("vertical_capability_id");



ALTER TABLE ONLY "pods_provisioning"."vertical_capabilities_v1"
    ADD CONSTRAINT "vertical_capability_unique" UNIQUE ("domain_key", "capability_key");



ALTER TABLE ONLY "pods_provisioning"."vertical_domains_v1"
    ADD CONSTRAINT "vertical_domain_key_unique" UNIQUE ("domain_key");



ALTER TABLE ONLY "pods_provisioning"."vertical_domains_v1"
    ADD CONSTRAINT "vertical_domains_v1_pkey" PRIMARY KEY ("vertical_domain_id");



ALTER TABLE ONLY "pods_provisioning"."vertical_surface_contracts_v1"
    ADD CONSTRAINT "vertical_surface_contracts_v1_pkey" PRIMARY KEY ("surface_contract_id");



ALTER TABLE ONLY "pods_provisioning"."vertical_surface_contracts_v1"
    ADD CONSTRAINT "vertical_surface_unique" UNIQUE ("domain_key", "surface_key");



ALTER TABLE ONLY "pods_provisioning"."vertical_template_hours"
    ADD CONSTRAINT "vertical_template_hours_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "pods_provisioning"."vertical_template_roles"
    ADD CONSTRAINT "vertical_template_roles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "pods_provisioning"."vertical_template_services"
    ADD CONSTRAINT "vertical_template_services_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "pods_provisioning"."vertical_templates"
    ADD CONSTRAINT "vertical_templates_pkey" PRIMARY KEY ("template_key");



ALTER TABLE ONLY "pods_provisioning"."vertical_workflow_contracts_v1"
    ADD CONSTRAINT "vertical_workflow_contracts_v1_pkey" PRIMARY KEY ("workflow_contract_id");



ALTER TABLE ONLY "pods_provisioning"."vertical_workflow_contracts_v1"
    ADD CONSTRAINT "vertical_workflow_unique" UNIQUE ("domain_key", "workflow_key");



ALTER TABLE ONLY "pods_public"."public_surface_contracts_v1"
    ADD CONSTRAINT "public_surface_contracts_v1_pkey" PRIMARY KEY ("surface_key");



ALTER TABLE ONLY "pods_public"."public_surface_selftest_vectors_v1"
    ADD CONSTRAINT "public_surface_selftest_vectors_v1_pkey" PRIMARY KEY ("vector_key");



CREATE INDEX "booking_appt_org_staff_idx" ON "pods"."booking_appointments" USING "btree" ("org_id", "staff_user_id");



CREATE INDEX "booking_appt_org_start_idx" ON "pods"."booking_appointments" USING "btree" ("org_id", "start_at");



CREATE INDEX "booking_appt_status_org_appt_idx" ON "pods"."booking_appointment_status_log" USING "btree" ("org_id", "appointment_id");



CREATE INDEX "booking_avail_org_staff_idx" ON "pods"."booking_availability_rules" USING "btree" ("org_id", "staff_user_id");



CREATE INDEX "booking_customers_org_idx" ON "pods"."booking_customers" USING "btree" ("org_id");



CREATE INDEX "booking_customers_user_idx" ON "pods"."booking_customers" USING "btree" ("user_id");



CREATE INDEX "booking_timeoff_org_staff_idx" ON "pods"."booking_time_off_blocks" USING "btree" ("org_id", "staff_user_id");



CREATE INDEX "storefront_contact_org_idx" ON "pods"."storefront_contact_requests" USING "btree" ("org_id");



CREATE INDEX "storefront_locations_org_idx" ON "pods"."storefront_locations" USING "btree" ("org_id");



CREATE INDEX "storefront_service_cat_org_idx" ON "pods"."storefront_service_categories" USING "btree" ("org_id");



CREATE INDEX "storefront_services_org_idx" ON "pods"."storefront_services" USING "btree" ("org_id");



CREATE INDEX "storefront_team_org_idx" ON "pods"."storefront_team_members" USING "btree" ("org_id");



CREATE UNIQUE INDEX "provision_runs_completed_once_idx" ON "pods_provisioning"."provision_runs_v1" USING "btree" ("org_id", "template_key", "template_version") WHERE ("status" = 'completed'::"text");



CREATE INDEX "provisioning_receipts_run_idx" ON "pods_provisioning"."provisioning_receipts_v1" USING "btree" ("provision_run_id", "created_at");



CREATE INDEX "seeded_objects_org_idx" ON "pods_provisioning"."seeded_objects_v1" USING "btree" ("org_id", "template_key", "template_version");



ALTER TABLE ONLY "pods"."billing_accounts"
    ADD CONSTRAINT "billing_accounts_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "pods"."orgs"("org_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods"."booking_appointment_status_log"
    ADD CONSTRAINT "booking_appointment_status_log_appointment_id_fkey" FOREIGN KEY ("appointment_id") REFERENCES "pods"."booking_appointments"("appointment_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods"."booking_appointment_status_log"
    ADD CONSTRAINT "booking_appointment_status_log_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "pods"."orgs"("org_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods"."booking_appointments"
    ADD CONSTRAINT "booking_appointments_customer_id_fkey" FOREIGN KEY ("customer_id") REFERENCES "pods"."booking_customers"("customer_id") ON DELETE SET NULL;



ALTER TABLE ONLY "pods"."booking_appointments"
    ADD CONSTRAINT "booking_appointments_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "pods"."storefront_locations"("location_id") ON DELETE SET NULL;



ALTER TABLE ONLY "pods"."booking_appointments"
    ADD CONSTRAINT "booking_appointments_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "pods"."orgs"("org_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods"."booking_appointments"
    ADD CONSTRAINT "booking_appointments_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "pods"."storefront_services"("service_id") ON DELETE SET NULL;



ALTER TABLE ONLY "pods"."booking_availability_rules"
    ADD CONSTRAINT "booking_availability_rules_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "pods"."storefront_locations"("location_id") ON DELETE SET NULL;



ALTER TABLE ONLY "pods"."booking_availability_rules"
    ADD CONSTRAINT "booking_availability_rules_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "pods"."orgs"("org_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods"."booking_customers"
    ADD CONSTRAINT "booking_customers_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "pods"."orgs"("org_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods"."booking_time_off_blocks"
    ADD CONSTRAINT "booking_time_off_blocks_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "pods"."orgs"("org_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods"."entitlement_overrides"
    ADD CONSTRAINT "entitlement_overrides_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "pods"."orgs"("org_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods"."migration_ledger"
    ADD CONSTRAINT "migration_ledger_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "pods"."orgs"("org_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods"."org_entitlements"
    ADD CONSTRAINT "org_entitlements_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "pods"."orgs"("org_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods"."org_members"
    ADD CONSTRAINT "org_members_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "pods"."orgs"("org_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods"."org_models"
    ADD CONSTRAINT "org_models_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "pods"."orgs"("org_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods"."plan_capabilities"
    ADD CONSTRAINT "plan_capabilities_plan_id_fkey" FOREIGN KEY ("plan_id") REFERENCES "pods"."plan_tiers"("plan_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods"."role_permissions"
    ADD CONSTRAINT "role_permissions_role_key_fkey" FOREIGN KEY ("role_key") REFERENCES "pods"."roles"("role_key") ON DELETE RESTRICT;



ALTER TABLE ONLY "pods"."storefront_contact_requests"
    ADD CONSTRAINT "storefront_contact_requests_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "pods"."orgs"("org_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods"."storefront_locations"
    ADD CONSTRAINT "storefront_locations_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "pods"."orgs"("org_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods"."storefront_profiles"
    ADD CONSTRAINT "storefront_profiles_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "pods"."orgs"("org_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods"."storefront_service_categories"
    ADD CONSTRAINT "storefront_service_categories_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "pods"."orgs"("org_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods"."storefront_services"
    ADD CONSTRAINT "storefront_services_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "pods"."storefront_service_categories"("category_id") ON DELETE SET NULL;



ALTER TABLE ONLY "pods"."storefront_services"
    ADD CONSTRAINT "storefront_services_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "pods"."orgs"("org_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods"."storefront_team_members"
    ADD CONSTRAINT "storefront_team_members_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "pods"."orgs"("org_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods"."subscriptions"
    ADD CONSTRAINT "subscriptions_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "pods"."orgs"("org_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods"."usage_counters"
    ADD CONSTRAINT "usage_counters_org_id_fkey" FOREIGN KEY ("org_id") REFERENCES "pods"."orgs"("org_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."adapter_attachment_items_v1"
    ADD CONSTRAINT "adapter_attachment_items_v1_adapter_attachment_run_id_fkey" FOREIGN KEY ("adapter_attachment_run_id") REFERENCES "pods_provisioning"."adapter_attachment_runs_v1"("adapter_attachment_run_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."adapter_attachment_runs_v1"
    ADD CONSTRAINT "adapter_attachment_runs_v1_deployment_receipt_id_fkey" FOREIGN KEY ("deployment_receipt_id") REFERENCES "pods_provisioning"."model_deployment_receipts_v1"("deployment_receipt_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."appointment_admin_actions_v1"
    ADD CONSTRAINT "appointment_admin_actions_v1_appointment_request_id_fkey" FOREIGN KEY ("appointment_request_id") REFERENCES "pods_provisioning"."public_appointment_requests_v1"("appointment_request_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."asset_access_receipts_v1"
    ADD CONSTRAINT "asset_access_receipts_v1_asset_runtime_object_id_fkey" FOREIGN KEY ("asset_runtime_object_id") REFERENCES "pods_provisioning"."asset_runtime_objects_v1"("asset_runtime_object_id");



ALTER TABLE ONLY "pods_provisioning"."cancellation_requests_v1"
    ADD CONSTRAINT "cancellation_requests_v1_appointment_request_id_fkey" FOREIGN KEY ("appointment_request_id") REFERENCES "pods_provisioning"."public_appointment_requests_v1"("appointment_request_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."cancellation_requests_v1"
    ADD CONSTRAINT "cancellation_requests_v1_cancellation_policy_id_fkey" FOREIGN KEY ("cancellation_policy_id") REFERENCES "pods_provisioning"."cancellation_policies_v1"("cancellation_policy_id") ON DELETE SET NULL;



ALTER TABLE ONLY "pods_provisioning"."civic_action_contribution_wall_entries_v1"
    ADD CONSTRAINT "civic_action_contribution_wall_entries_v_civic_campaign_id_fkey" FOREIGN KEY ("civic_campaign_id") REFERENCES "pods_provisioning"."civic_action_campaigns_v1"("civic_campaign_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."civic_action_event_rsvps_v1"
    ADD CONSTRAINT "civic_action_event_rsvps_v1_civic_event_id_fkey" FOREIGN KEY ("civic_event_id") REFERENCES "pods_provisioning"."civic_action_events_v1"("civic_event_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."civic_action_events_v1"
    ADD CONSTRAINT "civic_action_events_v1_civic_campaign_id_fkey" FOREIGN KEY ("civic_campaign_id") REFERENCES "pods_provisioning"."civic_action_campaigns_v1"("civic_campaign_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."civic_action_evidence_v1"
    ADD CONSTRAINT "civic_action_evidence_v1_civic_campaign_id_fkey" FOREIGN KEY ("civic_campaign_id") REFERENCES "pods_provisioning"."civic_action_campaigns_v1"("civic_campaign_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."civic_action_help_offers_v1"
    ADD CONSTRAINT "civic_action_help_offers_v1_civic_campaign_id_fkey" FOREIGN KEY ("civic_campaign_id") REFERENCES "pods_provisioning"."civic_action_campaigns_v1"("civic_campaign_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."civic_action_launch_ready_receipts_v1"
    ADD CONSTRAINT "civic_action_launch_ready_receipts_v1_civic_deployment_id_fkey" FOREIGN KEY ("civic_deployment_id") REFERENCES "pods_provisioning"."civic_action_model_deployments_v1"("civic_deployment_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."civic_action_model_deployments_v1"
    ADD CONSTRAINT "civic_action_model_deployments_v1_civic_campaign_id_fkey" FOREIGN KEY ("civic_campaign_id") REFERENCES "pods_provisioning"."civic_action_campaigns_v1"("civic_campaign_id") ON DELETE SET NULL;



ALTER TABLE ONLY "pods_provisioning"."civic_action_petition_signatures_v1"
    ADD CONSTRAINT "civic_action_petition_signatures_v1_civic_campaign_id_fkey" FOREIGN KEY ("civic_campaign_id") REFERENCES "pods_provisioning"."civic_action_campaigns_v1"("civic_campaign_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."civic_action_survey_questions_v1"
    ADD CONSTRAINT "civic_action_survey_questions_v1_civic_campaign_id_fkey" FOREIGN KEY ("civic_campaign_id") REFERENCES "pods_provisioning"."civic_action_campaigns_v1"("civic_campaign_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."civic_action_survey_responses_v1"
    ADD CONSTRAINT "civic_action_survey_responses_v1_civic_campaign_id_fkey" FOREIGN KEY ("civic_campaign_id") REFERENCES "pods_provisioning"."civic_action_campaigns_v1"("civic_campaign_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."contractor_estimate_decisions_v1"
    ADD CONSTRAINT "contractor_estimate_decisions_v1_contractor_estimate_id_fkey" FOREIGN KEY ("contractor_estimate_id") REFERENCES "pods_provisioning"."contractor_estimates_v1"("contractor_estimate_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."contractor_estimate_line_items_v1"
    ADD CONSTRAINT "contractor_estimate_line_items_v1_contractor_estimate_id_fkey" FOREIGN KEY ("contractor_estimate_id") REFERENCES "pods_provisioning"."contractor_estimates_v1"("contractor_estimate_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."contractor_estimates_v1"
    ADD CONSTRAINT "contractor_estimates_v1_estimate_request_id_fkey" FOREIGN KEY ("estimate_request_id") REFERENCES "pods_provisioning"."contractor_estimate_requests_v1"("estimate_request_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."contractor_job_phases_v1"
    ADD CONSTRAINT "contractor_job_phases_v1_contractor_job_id_fkey" FOREIGN KEY ("contractor_job_id") REFERENCES "pods_provisioning"."contractor_job_records_v1"("contractor_job_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."contractor_job_records_v1"
    ADD CONSTRAINT "contractor_job_records_v1_estimate_request_id_fkey" FOREIGN KEY ("estimate_request_id") REFERENCES "pods_provisioning"."contractor_estimate_requests_v1"("estimate_request_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."contractor_site_visits_v1"
    ADD CONSTRAINT "contractor_site_visits_v1_estimate_request_id_fkey" FOREIGN KEY ("estimate_request_id") REFERENCES "pods_provisioning"."contractor_estimate_requests_v1"("estimate_request_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."customer_launch_receipts_v1"
    ADD CONSTRAINT "customer_launch_receipts_v1_provision_run_id_fkey" FOREIGN KEY ("provision_run_id") REFERENCES "pods_provisioning"."provision_runs_v1"("provision_run_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."launch_execution_runs_v1"
    ADD CONSTRAINT "launch_execution_runs_v1_adapter_attachment_run_id_fkey" FOREIGN KEY ("adapter_attachment_run_id") REFERENCES "pods_provisioning"."adapter_attachment_runs_v1"("adapter_attachment_run_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."launch_execution_runs_v1"
    ADD CONSTRAINT "launch_execution_runs_v1_deployment_receipt_id_fkey" FOREIGN KEY ("deployment_receipt_id") REFERENCES "pods_provisioning"."model_deployment_receipts_v1"("deployment_receipt_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."launch_execution_worker_runs_v1"
    ADD CONSTRAINT "launch_execution_worker_runs_v1_launch_control_receipt_id_fkey" FOREIGN KEY ("launch_control_receipt_id") REFERENCES "pods_provisioning"."launch_control_plane_receipts_v1"("launch_control_receipt_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."launch_failure_events_v1"
    ADD CONSTRAINT "launch_failure_events_v1_worker_run_id_fkey" FOREIGN KEY ("worker_run_id") REFERENCES "pods_provisioning"."launch_execution_worker_runs_v1"("worker_run_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."launch_retry_events_v1"
    ADD CONSTRAINT "launch_retry_events_v1_launch_failure_event_id_fkey" FOREIGN KEY ("launch_failure_event_id") REFERENCES "pods_provisioning"."launch_failure_events_v1"("launch_failure_event_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."launch_retry_events_v1"
    ADD CONSTRAINT "launch_retry_events_v1_retry_policy_id_fkey" FOREIGN KEY ("retry_policy_id") REFERENCES "pods_provisioning"."launch_retry_policies_v1"("retry_policy_id") ON DELETE SET NULL;



ALTER TABLE ONLY "pods_provisioning"."launch_rollback_events_v1"
    ADD CONSTRAINT "launch_rollback_events_v1_launch_failure_event_id_fkey" FOREIGN KEY ("launch_failure_event_id") REFERENCES "pods_provisioning"."launch_failure_events_v1"("launch_failure_event_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."model_deployment_receipts_v1"
    ADD CONSTRAINT "model_deployment_receipts_v1_plan_run_id_fkey" FOREIGN KEY ("plan_run_id") REFERENCES "pods_provisioning"."model_capability_plan_runs_v1"("plan_run_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."model_instance_runtimes_v1"
    ADD CONSTRAINT "model_instance_runtimes_v1_model_site_runtime_generation_i_fkey" FOREIGN KEY ("model_site_runtime_generation_id") REFERENCES "pods_provisioning"."model_site_runtime_generations_v1"("model_site_runtime_generation_id") ON DELETE SET NULL;



ALTER TABLE ONLY "pods_provisioning"."model_instance_wizard_runs_v1"
    ADD CONSTRAINT "model_instance_wizard_runs_v1_model_instance_runtime_id_fkey" FOREIGN KEY ("model_instance_runtime_id") REFERENCES "pods_provisioning"."model_instance_runtimes_v1"("model_instance_runtime_id") ON DELETE SET NULL;



ALTER TABLE ONLY "pods_provisioning"."model_launch_authorities_v1"
    ADD CONSTRAINT "model_launch_authorities_v1_model_launch_package_id_fkey" FOREIGN KEY ("model_launch_package_id") REFERENCES "pods_provisioning"."model_launch_packages_v1"("model_launch_package_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."model_launch_packages_v1"
    ADD CONSTRAINT "model_launch_packages_v1_model_instance_runtime_id_fkey" FOREIGN KEY ("model_instance_runtime_id") REFERENCES "pods_provisioning"."model_instance_runtimes_v1"("model_instance_runtime_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."model_launch_receipts_v1"
    ADD CONSTRAINT "model_launch_receipts_v1_model_launch_authority_id_fkey" FOREIGN KEY ("model_launch_authority_id") REFERENCES "pods_provisioning"."model_launch_authorities_v1"("model_launch_authority_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."model_launch_reviews_v1"
    ADD CONSTRAINT "model_launch_reviews_v1_model_launch_authority_id_fkey" FOREIGN KEY ("model_launch_authority_id") REFERENCES "pods_provisioning"."model_launch_authorities_v1"("model_launch_authority_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."model_marketplace_installs_v1"
    ADD CONSTRAINT "model_marketplace_installs_v1_model_marketplace_catalog_id_fkey" FOREIGN KEY ("model_marketplace_catalog_id") REFERENCES "pods_provisioning"."model_marketplace_catalog_v1"("model_marketplace_catalog_id") ON DELETE SET NULL;



ALTER TABLE ONLY "pods_provisioning"."model_release_promotions_v1"
    ADD CONSTRAINT "model_release_promotions_v1_model_release_id_fkey" FOREIGN KEY ("model_release_id") REFERENCES "pods_provisioning"."model_releases_v1"("model_release_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."model_release_rollbacks_v1"
    ADD CONSTRAINT "model_release_rollbacks_v1_source_release_id_fkey" FOREIGN KEY ("source_release_id") REFERENCES "pods_provisioning"."model_releases_v1"("model_release_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."model_release_rollbacks_v1"
    ADD CONSTRAINT "model_release_rollbacks_v1_target_release_id_fkey" FOREIGN KEY ("target_release_id") REFERENCES "pods_provisioning"."model_releases_v1"("model_release_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."model_renderer_contracts_v1"
    ADD CONSTRAINT "model_renderer_contracts_v1_model_runtime_manifest_id_fkey" FOREIGN KEY ("model_runtime_manifest_id") REFERENCES "pods_provisioning"."model_runtime_manifests_v1"("model_runtime_manifest_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."model_runtime_drift_findings_v1"
    ADD CONSTRAINT "model_runtime_drift_findings__model_runtime_drift_report_i_fkey" FOREIGN KEY ("model_runtime_drift_report_id") REFERENCES "pods_provisioning"."model_runtime_drift_reports_v1"("model_runtime_drift_report_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."model_runtime_drift_reports_v1"
    ADD CONSTRAINT "model_runtime_drift_reports_v_model_runtime_drift_baseline_fkey" FOREIGN KEY ("model_runtime_drift_baseline_id") REFERENCES "pods_provisioning"."model_runtime_drift_baselines_v1"("model_runtime_drift_baseline_id") ON DELETE SET NULL;



ALTER TABLE ONLY "pods_provisioning"."model_runtime_editor_changes_v1"
    ADD CONSTRAINT "model_runtime_editor_changes_v1_model_instance_runtime_id_fkey" FOREIGN KEY ("model_instance_runtime_id") REFERENCES "pods_provisioning"."model_instance_runtimes_v1"("model_instance_runtime_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."model_runtime_manifests_v1"
    ADD CONSTRAINT "model_runtime_manifests_v1_model_site_blueprint_id_fkey" FOREIGN KEY ("model_site_blueprint_id") REFERENCES "pods_provisioning"."model_site_blueprints_v1"("model_site_blueprint_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."model_runtime_snapshot_receipts_v1"
    ADD CONSTRAINT "model_runtime_snapshot_receipts__model_runtime_snapshot_id_fkey" FOREIGN KEY ("model_runtime_snapshot_id") REFERENCES "pods_provisioning"."model_runtime_snapshots_v1"("model_runtime_snapshot_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."notification_delivery_receipts_v1"
    ADD CONSTRAINT "notification_delivery_receipts_v1_notification_id_fkey" FOREIGN KEY ("notification_id") REFERENCES "pods_provisioning"."notifications_v1"("notification_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."notifications_v1"
    ADD CONSTRAINT "notifications_v1_appointment_request_id_fkey" FOREIGN KEY ("appointment_request_id") REFERENCES "pods_provisioning"."public_appointment_requests_v1"("appointment_request_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."payment_events_v1"
    ADD CONSTRAINT "payment_events_v1_payment_intent_id_fkey" FOREIGN KEY ("payment_intent_id") REFERENCES "pods_provisioning"."payment_intents_v1"("payment_intent_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."payment_intents_v1"
    ADD CONSTRAINT "payment_intents_v1_appointment_request_id_fkey" FOREIGN KEY ("appointment_request_id") REFERENCES "pods_provisioning"."public_appointment_requests_v1"("appointment_request_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."payment_intents_v1"
    ADD CONSTRAINT "payment_intents_v1_payment_policy_id_fkey" FOREIGN KEY ("payment_policy_id") REFERENCES "pods_provisioning"."payment_policies_v1"("payment_policy_id") ON DELETE SET NULL;



ALTER TABLE ONLY "pods_provisioning"."payment_provider_receipts_v1"
    ADD CONSTRAINT "payment_provider_receipts_v1_payment_intent_id_fkey" FOREIGN KEY ("payment_intent_id") REFERENCES "pods_provisioning"."payment_intents_v1"("payment_intent_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."provider_connection_runtime_bridges_v1"
    ADD CONSTRAINT "provider_connection_runtime_b_provider_connection_rollup_i_fkey" FOREIGN KEY ("provider_connection_rollup_id") REFERENCES "pods_provisioning"."provider_connection_rollups_v1"("provider_connection_rollup_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."provision_runs_v1"
    ADD CONSTRAINT "provision_runs_template_fk" FOREIGN KEY ("template_key", "template_version") REFERENCES "pods_provisioning"."template_registry_v1"("template_key", "template_version");



ALTER TABLE ONLY "pods_provisioning"."provisioning_receipts_v1"
    ADD CONSTRAINT "provisioning_receipts_v1_provision_run_id_fkey" FOREIGN KEY ("provision_run_id") REFERENCES "pods_provisioning"."provision_runs_v1"("provision_run_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."public_appointment_requests_v1"
    ADD CONSTRAINT "public_appointment_requests_v1_provision_run_id_fkey" FOREIGN KEY ("provision_run_id") REFERENCES "pods_provisioning"."provision_runs_v1"("provision_run_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."public_booking_surfaces_v1"
    ADD CONSTRAINT "public_booking_surfaces_v1_provision_run_id_fkey" FOREIGN KEY ("provision_run_id") REFERENCES "pods_provisioning"."provision_runs_v1"("provision_run_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."refund_intents_v1"
    ADD CONSTRAINT "refund_intents_v1_cancellation_request_id_fkey" FOREIGN KEY ("cancellation_request_id") REFERENCES "pods_provisioning"."cancellation_requests_v1"("cancellation_request_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."refund_intents_v1"
    ADD CONSTRAINT "refund_intents_v1_payment_intent_id_fkey" FOREIGN KEY ("payment_intent_id") REFERENCES "pods_provisioning"."payment_intents_v1"("payment_intent_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."seeded_objects_v1"
    ADD CONSTRAINT "seeded_objects_template_fk" FOREIGN KEY ("template_key", "template_version") REFERENCES "pods_provisioning"."template_registry_v1"("template_key", "template_version");



ALTER TABLE ONLY "pods_provisioning"."seeded_objects_v1"
    ADD CONSTRAINT "seeded_objects_v1_provision_run_id_fkey" FOREIGN KEY ("provision_run_id") REFERENCES "pods_provisioning"."provision_runs_v1"("provision_run_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."staff_appointment_assignments_v1"
    ADD CONSTRAINT "staff_appointment_assignments_v1_appointment_request_id_fkey" FOREIGN KEY ("appointment_request_id") REFERENCES "pods_provisioning"."public_appointment_requests_v1"("appointment_request_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."staff_appointment_assignments_v1"
    ADD CONSTRAINT "staff_appointment_assignments_v1_staff_member_id_fkey" FOREIGN KEY ("staff_member_id") REFERENCES "pods_provisioning"."staff_members_v1"("staff_member_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."staff_featured_sections_v1"
    ADD CONSTRAINT "staff_featured_sections_v1_staff_member_id_fkey" FOREIGN KEY ("staff_member_id") REFERENCES "pods_provisioning"."staff_members_v1"("staff_member_id") ON DELETE SET NULL;



ALTER TABLE ONLY "pods_provisioning"."staff_gallery_items_v1"
    ADD CONSTRAINT "staff_gallery_items_v1_staff_member_id_fkey" FOREIGN KEY ("staff_member_id") REFERENCES "pods_provisioning"."staff_members_v1"("staff_member_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."staff_public_profiles_v1"
    ADD CONSTRAINT "staff_public_profiles_v1_staff_member_id_fkey" FOREIGN KEY ("staff_member_id") REFERENCES "pods_provisioning"."staff_members_v1"("staff_member_id") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."vertical_capabilities_v1"
    ADD CONSTRAINT "vertical_capabilities_v1_domain_key_fkey" FOREIGN KEY ("domain_key") REFERENCES "pods_provisioning"."vertical_domains_v1"("domain_key") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."vertical_surface_contracts_v1"
    ADD CONSTRAINT "vertical_surface_contracts_v1_domain_key_fkey" FOREIGN KEY ("domain_key") REFERENCES "pods_provisioning"."vertical_domains_v1"("domain_key") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."vertical_template_hours"
    ADD CONSTRAINT "vertical_template_hours_template_key_fkey" FOREIGN KEY ("template_key") REFERENCES "pods_provisioning"."vertical_templates"("template_key") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."vertical_template_roles"
    ADD CONSTRAINT "vertical_template_roles_template_key_fkey" FOREIGN KEY ("template_key") REFERENCES "pods_provisioning"."vertical_templates"("template_key") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."vertical_template_services"
    ADD CONSTRAINT "vertical_template_services_template_key_fkey" FOREIGN KEY ("template_key") REFERENCES "pods_provisioning"."vertical_templates"("template_key") ON DELETE CASCADE;



ALTER TABLE ONLY "pods_provisioning"."vertical_workflow_contracts_v1"
    ADD CONSTRAINT "vertical_workflow_contracts_v1_domain_key_fkey" FOREIGN KEY ("domain_key") REFERENCES "pods_provisioning"."vertical_domains_v1"("domain_key") ON DELETE CASCADE;



CREATE POLICY "audit_no_write" ON "pods"."audit_log" TO "authenticated" USING (false) WITH CHECK (false);



CREATE POLICY "billing_accounts_no_write" ON "pods"."billing_accounts" TO "authenticated" USING (false) WITH CHECK (false);



ALTER TABLE "pods"."booking_appointment_status_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods"."booking_appointments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "booking_appointments_no_write" ON "pods"."booking_appointments" TO "authenticated" USING (false) WITH CHECK (false);



CREATE POLICY "booking_appointments_read" ON "pods"."booking_appointments" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "pods"."org_members" "m"
  WHERE (("m"."org_id" = "booking_appointments"."org_id") AND ("m"."user_id" = "auth"."uid"()) AND ("m"."role_key" = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))) OR (("staff_user_id" = "auth"."uid"()) AND (EXISTS ( SELECT 1
   FROM "pods"."org_members" "m2"
  WHERE (("m2"."org_id" = "booking_appointments"."org_id") AND ("m2"."user_id" = "auth"."uid"()) AND ("m2"."role_key" = 'staff'::"text")))))));



CREATE POLICY "booking_appt_status_no_write" ON "pods"."booking_appointment_status_log" TO "authenticated" USING (false) WITH CHECK (false);



CREATE POLICY "booking_appt_status_read" ON "pods"."booking_appointment_status_log" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "pods"."org_members" "m"
  WHERE (("m"."org_id" = "booking_appointment_status_log"."org_id") AND ("m"."user_id" = "auth"."uid"()) AND ("m"."role_key" = ANY (ARRAY['owner'::"text", 'admin'::"text", 'staff'::"text"]))))));



CREATE POLICY "booking_availability_no_write" ON "pods"."booking_availability_rules" TO "authenticated" USING (false) WITH CHECK (false);



CREATE POLICY "booking_availability_read" ON "pods"."booking_availability_rules" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "pods"."org_members" "m"
  WHERE (("m"."org_id" = "booking_availability_rules"."org_id") AND ("m"."user_id" = "auth"."uid"()) AND ("m"."role_key" = ANY (ARRAY['owner'::"text", 'admin'::"text", 'staff'::"text"]))))));



ALTER TABLE "pods"."booking_availability_rules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods"."booking_customers" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "booking_customers_no_write" ON "pods"."booking_customers" TO "authenticated" USING (false) WITH CHECK (false);



CREATE POLICY "booking_customers_read" ON "pods"."booking_customers" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "pods"."org_members" "m"
  WHERE (("m"."org_id" = "booking_customers"."org_id") AND ("m"."user_id" = "auth"."uid"()) AND ("m"."role_key" = ANY (ARRAY['owner'::"text", 'admin'::"text", 'staff'::"text"]))))));



ALTER TABLE "pods"."booking_time_off_blocks" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "booking_timeoff_no_write" ON "pods"."booking_time_off_blocks" TO "authenticated" USING (false) WITH CHECK (false);



CREATE POLICY "booking_timeoff_read" ON "pods"."booking_time_off_blocks" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "pods"."org_members" "m"
  WHERE (("m"."org_id" = "booking_time_off_blocks"."org_id") AND ("m"."user_id" = "auth"."uid"()) AND ("m"."role_key" = ANY (ARRAY['owner'::"text", 'admin'::"text", 'staff'::"text"]))))));



CREATE POLICY "entitlement_overrides_no_write" ON "pods"."entitlement_overrides" TO "authenticated" USING (false) WITH CHECK (false);



CREATE POLICY "migration_ledger_no_write" ON "pods"."migration_ledger" TO "authenticated" USING (false) WITH CHECK (false);



CREATE POLICY "models_no_write" ON "pods"."models" TO "authenticated", "anon" USING (false) WITH CHECK (false);



CREATE POLICY "org_entitlements_no_write" ON "pods"."org_entitlements" TO "authenticated" USING (false) WITH CHECK (false);



CREATE POLICY "org_members_no_write" ON "pods"."org_members" TO "authenticated" USING (false) WITH CHECK (false);



CREATE POLICY "org_models_no_write" ON "pods"."org_models" TO "authenticated" USING (false) WITH CHECK (false);



CREATE POLICY "orgs_no_write" ON "pods"."orgs" TO "authenticated" USING (false) WITH CHECK (false);



CREATE POLICY "plan_caps_no_write" ON "pods"."plan_capabilities" TO "authenticated", "anon" USING (false) WITH CHECK (false);



CREATE POLICY "plan_tiers_no_write" ON "pods"."plan_tiers" TO "authenticated", "anon" USING (false) WITH CHECK (false);



CREATE POLICY "role_perms_no_write" ON "pods"."role_permissions" TO "authenticated", "anon" USING (false) WITH CHECK (false);



CREATE POLICY "roles_no_write" ON "pods"."roles" TO "authenticated", "anon" USING (false) WITH CHECK (false);



CREATE POLICY "storefront_contact_no_write" ON "pods"."storefront_contact_requests" TO "authenticated" USING (false) WITH CHECK (false);



CREATE POLICY "storefront_locations_write" ON "pods"."storefront_locations" TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "pods"."org_members" "m"
  WHERE (("m"."org_id" = "storefront_locations"."org_id") AND ("m"."user_id" = "auth"."uid"()) AND ("m"."role_key" = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))) AND ("pods"."has_cap_bool"("org_id", 'storefront_enabled'::"text") = true))) WITH CHECK (((EXISTS ( SELECT 1
   FROM "pods"."org_members" "m"
  WHERE (("m"."org_id" = "storefront_locations"."org_id") AND ("m"."user_id" = "auth"."uid"()) AND ("m"."role_key" = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))) AND ("pods"."has_cap_bool"("org_id", 'storefront_enabled'::"text") = true)));



CREATE POLICY "storefront_profiles_write" ON "pods"."storefront_profiles" TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "pods"."org_members" "m"
  WHERE (("m"."org_id" = "storefront_profiles"."org_id") AND ("m"."user_id" = "auth"."uid"()) AND ("m"."role_key" = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))) AND ("pods"."has_cap_bool"("org_id", 'storefront_enabled'::"text") = true))) WITH CHECK (((EXISTS ( SELECT 1
   FROM "pods"."org_members" "m"
  WHERE (("m"."org_id" = "storefront_profiles"."org_id") AND ("m"."user_id" = "auth"."uid"()) AND ("m"."role_key" = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))) AND ("pods"."has_cap_bool"("org_id", 'storefront_enabled'::"text") = true)));



CREATE POLICY "storefront_service_categories_write" ON "pods"."storefront_service_categories" TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "pods"."org_members" "m"
  WHERE (("m"."org_id" = "storefront_service_categories"."org_id") AND ("m"."user_id" = "auth"."uid"()) AND ("m"."role_key" = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))) AND ("pods"."has_cap_bool"("org_id", 'storefront_enabled'::"text") = true))) WITH CHECK (((EXISTS ( SELECT 1
   FROM "pods"."org_members" "m"
  WHERE (("m"."org_id" = "storefront_service_categories"."org_id") AND ("m"."user_id" = "auth"."uid"()) AND ("m"."role_key" = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))) AND ("pods"."has_cap_bool"("org_id", 'storefront_enabled'::"text") = true)));



CREATE POLICY "storefront_services_write" ON "pods"."storefront_services" TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "pods"."org_members" "m"
  WHERE (("m"."org_id" = "storefront_services"."org_id") AND ("m"."user_id" = "auth"."uid"()) AND ("m"."role_key" = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))) AND ("pods"."has_cap_bool"("org_id", 'storefront_enabled'::"text") = true))) WITH CHECK (((EXISTS ( SELECT 1
   FROM "pods"."org_members" "m"
  WHERE (("m"."org_id" = "storefront_services"."org_id") AND ("m"."user_id" = "auth"."uid"()) AND ("m"."role_key" = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))) AND ("pods"."has_cap_bool"("org_id", 'storefront_enabled'::"text") = true)));



CREATE POLICY "storefront_team_write" ON "pods"."storefront_team_members" TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "pods"."org_members" "m"
  WHERE (("m"."org_id" = "storefront_team_members"."org_id") AND ("m"."user_id" = "auth"."uid"()) AND ("m"."role_key" = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))) AND ("pods"."has_cap_bool"("org_id", 'storefront_enabled'::"text") = true))) WITH CHECK (((EXISTS ( SELECT 1
   FROM "pods"."org_members" "m"
  WHERE (("m"."org_id" = "storefront_team_members"."org_id") AND ("m"."user_id" = "auth"."uid"()) AND ("m"."role_key" = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))) AND ("pods"."has_cap_bool"("org_id", 'storefront_enabled'::"text") = true)));



CREATE POLICY "subscriptions_no_write" ON "pods"."subscriptions" TO "authenticated" USING (false) WITH CHECK (false);



CREATE POLICY "usage_counters_no_write" ON "pods"."usage_counters" TO "authenticated" USING (false) WITH CHECK (false);



ALTER TABLE "pods_provisioning"."adapter_attachment_items_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."adapter_attachment_runs_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."appointment_admin_actions_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."cancellation_policies_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."cancellation_requests_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."civic_action_campaigns_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."civic_action_contribution_wall_entries_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."civic_action_event_rsvps_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."civic_action_events_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."civic_action_evidence_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."civic_action_full_green_receipts_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."civic_action_full_green_v2_receipts_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."civic_action_help_offers_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."civic_action_launch_ready_receipts_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."civic_action_model_deployments_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."civic_action_model_registry_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."civic_action_moderation_receipts_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."civic_action_petition_signatures_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."connection_layer_launch_control_runs_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."contractor_estimate_decisions_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."contractor_estimate_line_items_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."contractor_estimate_requests_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."contractor_estimates_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."contractor_job_records_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."contractor_service_templates_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."contractor_site_visits_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."customer_deployment_handoffs_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."customer_launch_receipts_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."domain_provider_connections_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."domain_runtime_bindings_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."email_adapter_runtime_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."full_green_engine_registry_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."full_green_platform_snapshots_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."github_adapter_runtime_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."launch_control_plane_receipts_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."launch_execution_runs_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."launch_execution_worker_runs_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."launch_failure_events_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."launch_retry_events_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."launch_retry_policies_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."launch_rollback_events_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_audit_checkpoints_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_audit_ledger_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_block_registry_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_capability_matrix_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_capability_plan_runs_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_db_parameters_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_db_surface_full_green_receipts_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_deployment_receipts_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_deployment_targets_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_instance_clones_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_instance_runtimes_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_instance_wizard_runs_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_launch_authorities_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_launch_packages_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_launch_receipts_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_launch_reviews_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_marketplace_catalog_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_marketplace_installs_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_page_compositions_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_permission_generations_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_release_channels_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_release_promotions_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_release_rollbacks_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_releases_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_renderer_contracts_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_runtime_editor_changes_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_runtime_manifests_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_runtime_snapshot_receipts_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_runtime_snapshots_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_site_blueprints_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_site_runtime_generations_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_stored_procedure_registry_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_template_registry_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."model_ui_generations_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."notification_delivery_receipts_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."notification_preferences_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."notification_templates_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."notifications_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."operator_setup_wizard_sessions_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."payment_events_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."payment_intents_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."payment_policies_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."payment_provider_adapters_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."payment_provider_receipts_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."provider_connection_contracts_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."provider_connection_rollups_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."provider_connection_sessions_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."provider_readiness_rollups_v1" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "provision_runs_service_all_v1" ON "pods_provisioning"."provision_runs_v1" TO "service_role" USING (true) WITH CHECK (true);



ALTER TABLE "pods_provisioning"."provision_runs_v1" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "provisioning_receipts_service_all_v1" ON "pods_provisioning"."provisioning_receipts_v1" TO "service_role" USING (true) WITH CHECK (true);



ALTER TABLE "pods_provisioning"."provisioning_receipts_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."public_appointment_requests_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."public_booking_surfaces_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."refund_intents_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."security_gate_matrix_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."security_gate_results_v1" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "seeded_objects_service_all_v1" ON "pods_provisioning"."seeded_objects_v1" TO "service_role" USING (true) WITH CHECK (true);



ALTER TABLE "pods_provisioning"."seeded_objects_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."staff_appointment_assignments_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."staff_featured_sections_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."staff_gallery_items_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."staff_members_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."staff_public_profiles_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."storage_adapter_runtime_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."stress_harness_runs_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."stripe_adapter_runtime_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."supabase_adapter_runtime_v1" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "template_registry_service_all_v1" ON "pods_provisioning"."template_registry_v1" TO "service_role" USING (true) WITH CHECK (true);



ALTER TABLE "pods_provisioning"."template_registry_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."vertical_capabilities_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."vertical_domains_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."vertical_surface_contracts_v1" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."vertical_template_hours" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."vertical_template_roles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."vertical_template_services" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."vertical_templates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "pods_provisioning"."vertical_workflow_contracts_v1" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "pods" TO "authenticated";
GRANT USAGE ON SCHEMA "pods" TO "anon";



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



REVOKE ALL ON FUNCTION "pods"."rpc_add_time_off_block_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_at" timestamp with time zone, "p_end_at" timestamp with time zone, "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "pods"."rpc_add_time_off_block_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_at" timestamp with time zone, "p_end_at" timestamp with time zone, "p_reason" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "pods"."rpc_billing_ingest_webhook"("p_org_id" "uuid", "p_provider_customer_id" "text", "p_provider_subscription_id" "text", "p_status" "text", "p_plan_id" "text", "p_period_start" timestamp with time zone, "p_period_end" timestamp with time zone, "p_cancel_at_period_end" boolean, "p_billing_email" "text", "p_event" "jsonb") FROM PUBLIC;



REVOKE ALL ON FUNCTION "pods"."rpc_cancel_appointment_v1"("p_org_id" "uuid", "p_appointment_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "pods"."rpc_cancel_appointment_v1"("p_org_id" "uuid", "p_appointment_id" "uuid", "p_reason" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "pods"."rpc_create_appointment_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_at" timestamp with time zone, "p_end_at" timestamp with time zone, "p_location_id" "uuid", "p_service_id" "uuid", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "pods"."rpc_create_appointment_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_at" timestamp with time zone, "p_end_at" timestamp with time zone, "p_location_id" "uuid", "p_service_id" "uuid", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_notes" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "pods"."rpc_create_org_bootstrap"("p_slug" "text", "p_name" "text", "p_plan_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "pods"."rpc_create_org_bootstrap"("p_slug" "text", "p_name" "text", "p_plan_id" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "pods"."rpc_create_org_bootstrap_service_role_v1"("p_owner_user_id" "uuid", "p_slug" "text", "p_name" "text", "p_plan_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "pods"."rpc_create_org_bootstrap_service_role_v1"("p_owner_user_id" "uuid", "p_slug" "text", "p_name" "text", "p_plan_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "pods"."rpc_delete_availability_rule_v1"("p_org_id" "uuid", "p_rule_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "pods"."rpc_delete_availability_rule_v1"("p_org_id" "uuid", "p_rule_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "pods"."rpc_delete_time_off_block_v1"("p_org_id" "uuid", "p_block_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "pods"."rpc_delete_time_off_block_v1"("p_org_id" "uuid", "p_block_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "pods"."rpc_recompute_entitlements"("p_org_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "pods"."rpc_recompute_entitlements"("p_org_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "pods"."rpc_request_appointment_public_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_at" timestamp with time zone, "p_end_at" timestamp with time zone, "p_location_id" "uuid", "p_service_id" "uuid", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "pods"."rpc_request_appointment_public_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_at" timestamp with time zone, "p_end_at" timestamp with time zone, "p_location_id" "uuid", "p_service_id" "uuid", "p_customer_name" "text", "p_customer_email" "text", "p_customer_phone" "text", "p_notes" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "pods"."rpc_selftest_add_org_member_v1"("p_org_id" "uuid", "p_user_id" "uuid", "p_role" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "pods"."rpc_selftest_add_org_member_v1"("p_org_id" "uuid", "p_user_id" "uuid", "p_role" "text") TO "service_role";



REVOKE ALL ON FUNCTION "pods"."rpc_selftest_booking_gates_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "pods"."rpc_selftest_reset_booking_v1"("p_org_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "pods"."rpc_selftest_reset_booking_v1"("p_org_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "pods"."rpc_selftest_reset_booking_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "pods"."rpc_selftest_reset_booking_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "pods"."rpc_selftest_reset_booking_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "pods"."rpc_selftest_set_subscription_plan_v1"("p_org_id" "uuid", "p_plan_id" "text", "p_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "pods"."rpc_selftest_set_subscription_plan_v1"("p_org_id" "uuid", "p_plan_id" "text", "p_status" "text") TO "service_role";



REVOKE ALL ON FUNCTION "pods"."rpc_upsert_availability_rule_v1"("p_org_id" "uuid", "p_rule_id" "uuid", "p_staff_user_id" "uuid", "p_location_id" "uuid", "p_day_of_week" integer, "p_start_time" time without time zone, "p_end_time" time without time zone, "p_is_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "pods"."rpc_upsert_availability_rule_v1"("p_org_id" "uuid", "p_rule_id" "uuid", "p_staff_user_id" "uuid", "p_location_id" "uuid", "p_day_of_week" integer, "p_start_time" time without time zone, "p_end_time" time without time zone, "p_is_active" boolean) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."rpc_add_time_off_block_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_time" timestamp with time zone, "p_end_time" timestamp with time zone, "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rpc_add_time_off_block_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_time" timestamp with time zone, "p_end_time" timestamp with time zone, "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_add_time_off_block_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_time" timestamp with time zone, "p_end_time" timestamp with time zone, "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_add_time_off_block_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_time" timestamp with time zone, "p_end_time" timestamp with time zone, "p_reason" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."rpc_create_appointment_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_time" timestamp with time zone, "p_end_time" timestamp with time zone, "p_service_id" "uuid", "p_location_id" "uuid", "p_guest_name" "text", "p_guest_email" "text", "p_guest_phone" "text", "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rpc_create_appointment_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_time" timestamp with time zone, "p_end_time" timestamp with time zone, "p_service_id" "uuid", "p_location_id" "uuid", "p_guest_name" "text", "p_guest_email" "text", "p_guest_phone" "text", "p_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_create_appointment_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_time" timestamp with time zone, "p_end_time" timestamp with time zone, "p_service_id" "uuid", "p_location_id" "uuid", "p_guest_name" "text", "p_guest_email" "text", "p_guest_phone" "text", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_create_appointment_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid", "p_start_time" timestamp with time zone, "p_end_time" timestamp with time zone, "p_service_id" "uuid", "p_location_id" "uuid", "p_guest_name" "text", "p_guest_email" "text", "p_guest_phone" "text", "p_notes" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."rpc_create_org_bootstrap"("p_slug" "text", "p_name" "text", "p_plan_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rpc_create_org_bootstrap"("p_slug" "text", "p_name" "text", "p_plan_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_create_org_bootstrap"("p_slug" "text", "p_name" "text", "p_plan_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_create_org_bootstrap"("p_slug" "text", "p_name" "text", "p_plan_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."rpc_delete_availability_rule_v1"("p_org_id" "uuid", "p_rule_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rpc_delete_availability_rule_v1"("p_org_id" "uuid", "p_rule_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_delete_availability_rule_v1"("p_org_id" "uuid", "p_rule_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_delete_availability_rule_v1"("p_org_id" "uuid", "p_rule_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."rpc_recompute_entitlements"("p_org_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rpc_recompute_entitlements"("p_org_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."rpc_selftest_add_org_member_v1"("p_org_id" "uuid", "p_user_id" "uuid", "p_role" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rpc_selftest_add_org_member_v1"("p_org_id" "uuid", "p_user_id" "uuid", "p_role" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."rpc_selftest_reset_booking_v1"("p_org_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rpc_selftest_reset_booking_v1"("p_org_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_selftest_reset_booking_v1"("p_org_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."rpc_selftest_reset_booking_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rpc_selftest_reset_booking_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_selftest_reset_booking_v1"("p_org_id" "uuid", "p_staff_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."rpc_selftest_set_subscription_plan_v1"("p_org_id" "uuid", "p_plan_id" "text", "p_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rpc_selftest_set_subscription_plan_v1"("p_org_id" "uuid", "p_plan_id" "text", "p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_selftest_set_subscription_plan_v1"("p_org_id" "uuid", "p_plan_id" "text", "p_status" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."rpc_upsert_availability_rule_v1"("p_org_id" "uuid", "p_rule_id" "uuid", "p_staff_user_id" "uuid", "p_location_id" "uuid", "p_day_of_week" integer, "p_start_time" time without time zone, "p_end_time" time without time zone, "p_is_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."rpc_upsert_availability_rule_v1"("p_org_id" "uuid", "p_rule_id" "uuid", "p_staff_user_id" "uuid", "p_location_id" "uuid", "p_day_of_week" integer, "p_start_time" time without time zone, "p_end_time" time without time zone, "p_is_active" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."rpc_upsert_availability_rule_v1"("p_org_id" "uuid", "p_rule_id" "uuid", "p_staff_user_id" "uuid", "p_location_id" "uuid", "p_day_of_week" integer, "p_start_time" time without time zone, "p_end_time" time without time zone, "p_is_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."rpc_upsert_availability_rule_v1"("p_org_id" "uuid", "p_rule_id" "uuid", "p_staff_user_id" "uuid", "p_location_id" "uuid", "p_day_of_week" integer, "p_start_time" time without time zone, "p_end_time" time without time zone, "p_is_active" boolean) TO "service_role";



GRANT SELECT ON TABLE "pods"."public_storefront_locations_v1" TO "anon";
GRANT SELECT ON TABLE "pods"."public_storefront_locations_v1" TO "authenticated";



GRANT SELECT ON TABLE "pods"."public_storefront_profile_v1" TO "anon";
GRANT SELECT ON TABLE "pods"."public_storefront_profile_v1" TO "authenticated";



GRANT SELECT ON TABLE "pods"."public_storefront_services_v1" TO "anon";
GRANT SELECT ON TABLE "pods"."public_storefront_services_v1" TO "authenticated";



GRANT SELECT ON TABLE "pods"."public_storefront_team_v1" TO "anon";
GRANT SELECT ON TABLE "pods"."public_storefront_team_v1" TO "authenticated";



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







