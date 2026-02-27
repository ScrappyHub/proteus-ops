begin;

-- Wrapper: availability upsert
create or replace function public.rpc_upsert_availability_rule_v1(
  p_org_id uuid,
  p_rule_id uuid,
  p_staff_user_id uuid,
  p_location_id uuid,
  p_day_of_week int,
  p_start_time time,
  p_end_time time,
  p_is_active boolean
)
returns uuid
language sql
security definer
set search_path = pods, public
as $$
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

revoke all on function public.rpc_upsert_availability_rule_v1(uuid, uuid, uuid, uuid, int, time, time, boolean) from public;
grant execute on function public.rpc_upsert_availability_rule_v1(uuid, uuid, uuid, uuid, int, time, time, boolean) to authenticated;

-- Wrapper: delete availability
create or replace function public.rpc_delete_availability_rule_v1(
  p_org_id uuid,
  p_rule_id uuid
)
returns void
language sql
security definer
set search_path = pods, public
as $$
  select pods.rpc_delete_availability_rule_v1(p_org_id, p_rule_id);
$$;

revoke all on function public.rpc_delete_availability_rule_v1(uuid, uuid) from public;
grant execute on function public.rpc_delete_availability_rule_v1(uuid, uuid) to authenticated;

-- Wrapper: add time off
create or replace function public.rpc_add_time_off_block_v1(
  p_org_id uuid,
  p_staff_user_id uuid,
  p_start_time timestamptz,
  p_end_time timestamptz,
  p_reason text
)
returns uuid
language sql
security definer
set search_path = pods, public
as $$
  select pods.rpc_add_time_off_block_v1(p_org_id, p_staff_user_id, p_start_time, p_end_time, p_reason);
$$;

revoke all on function public.rpc_add_time_off_block_v1(uuid, uuid, timestamptz, timestamptz, text) from public;
grant execute on function public.rpc_add_time_off_block_v1(uuid, uuid, timestamptz, timestamptz, text) to authenticated;

-- Wrapper: create appointment
create or replace function public.rpc_create_appointment_v1(
  p_org_id uuid,
  p_staff_user_id uuid,
  p_start_time timestamptz,
  p_end_time timestamptz,
  p_service_id uuid,
  p_location_id uuid,
  p_guest_name text,
  p_guest_email text,
  p_guest_phone text,
  p_notes text
)
returns uuid
language sql
security definer
set search_path = pods, public
as $$
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

revoke all on function public.rpc_create_appointment_v1(uuid, uuid, timestamptz, timestamptz, uuid, uuid, text, text, text, text) from public;
grant execute on function public.rpc_create_appointment_v1(uuid, uuid, timestamptz, timestamptz, uuid, uuid, text, text, text, text) to authenticated;

commit;