begin;

-- -------------------------------
-- Helpers (internal)
-- -------------------------------

create or replace function pods._require_member_role(p_org_id uuid, p_roles text[])
returns text
language plpgsql
security invoker
set search_path = pods, public
as $$
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

create or replace function pods._require_booking_enabled(p_org_id uuid)
returns void
language plpgsql
security invoker
set search_path = pods, public
as $$
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

-- Monthly usage counter helper
create or replace function pods._usage_period_bounds(p_now timestamptz)
returns table(period_start date, period_end date)
language sql
stable
as $$
  select date_trunc('month', p_now)::date as period_start,
         (date_trunc('month', p_now) + interval '1 month')::date as period_end
$$;

create or replace function pods._increment_usage_counter(p_org_id uuid, p_counter_key text, p_now timestamptz)
returns void
language plpgsql
security definer
set search_path = pods, public
as $$
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

-- Usage limit check: compares current counter against entitlement int cap (if set)
create or replace function pods._assert_under_usage_cap(
  p_org_id uuid,
  p_counter_key text,
  p_capability_key text,
  p_now timestamptz
)
returns void
language plpgsql
security invoker
set search_path = pods, public
as $$
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

-- Overlap check: disallow overlapping requested/confirmed appointments for same staff
create or replace function pods._assert_no_overlap(
  p_org_id uuid,
  p_staff_user_id uuid,
  p_start_at timestamptz,
  p_end_at timestamptz
)
returns void
language plpgsql
security invoker
set search_path = pods, public
as $$
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

-- Time off block check
create or replace function pods._assert_not_in_timeoff(
  p_org_id uuid,
  p_staff_user_id uuid,
  p_start_at timestamptz,
  p_end_at timestamptz
)
returns void
language plpgsql
security invoker
set search_path = pods, public
as $$
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

-- Availability rule check (minimal v1):
-- Require at least one active weekly rule whose day/time window covers start/end.
create or replace function pods._assert_within_availability(
  p_org_id uuid,
  p_staff_user_id uuid,
  p_start_at timestamptz,
  p_end_at timestamptz
)
returns void
language plpgsql
security invoker
set search_path = pods, public
as $$
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

-- Staff membership check: must be org member with role staff/admin/owner
create or replace function pods._assert_staff_is_member(p_org_id uuid, p_staff_user_id uuid)
returns void
language plpgsql
security invoker
set search_path = pods, public
as $$
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

-- -------------------------------
-- RPC: Create appointment (RPC-only write surface)
-- -------------------------------
create or replace function pods.rpc_create_appointment_v1(
  p_org_id uuid,
  p_staff_user_id uuid,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_location_id uuid default null,
  p_service_id uuid default null,
  p_customer_name text default null,
  p_customer_email text default null,
  p_customer_phone text default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = pods, public
as $$
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

revoke all on function pods.rpc_create_appointment_v1(
  uuid, uuid, timestamptz, timestamptz, uuid, uuid, text, text, text, text
) from public;
grant execute on function pods.rpc_create_appointment_v1(
  uuid, uuid, timestamptz, timestamptz, uuid, uuid, text, text, text, text
) to authenticated;

-- -------------------------------
-- RPC: Cancel appointment (RPC-only)
-- owner/admin can cancel any; staff can cancel their own; customer later via separate RPC
-- -------------------------------
create or replace function pods.rpc_cancel_appointment_v1(
  p_org_id uuid,
  p_appointment_id uuid,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = pods, public
as $$
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

revoke all on function pods.rpc_cancel_appointment_v1(uuid, uuid, text) from public;
grant execute on function pods.rpc_cancel_appointment_v1(uuid, uuid, text) to authenticated;

commit;