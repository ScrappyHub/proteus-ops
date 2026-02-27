begin;

create or replace function pods.rpc_request_appointment_public_v1(
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

revoke all on function pods.rpc_request_appointment_public_v1(
  uuid, uuid, timestamptz, timestamptz, uuid, uuid, text, text, text, text
) from public;

-- Choose ONE:
-- Option A (recommended for v1): only authenticated can request
grant execute on function pods.rpc_request_appointment_public_v1(
  uuid, uuid, timestamptz, timestamptz, uuid, uuid, text, text, text, text
) to authenticated;

-- Option B (true public booking): uncomment
-- grant execute on function pods.rpc_request_appointment_public_v1(...) to anon;

commit;