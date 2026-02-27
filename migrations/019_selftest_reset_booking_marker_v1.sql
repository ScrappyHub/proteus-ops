begin;

-- Authenticated selftest reset: user can only reset their own staff rows
create or replace function pods.rpc_selftest_reset_booking_v1(
  p_org_id uuid,
  p_staff_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = pods, public
as $$
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

revoke all on function pods.rpc_selftest_reset_booking_v1(uuid, uuid) from public;
revoke all on function pods.rpc_selftest_reset_booking_v1(uuid, uuid) from anon;
grant execute on function pods.rpc_selftest_reset_booking_v1(uuid, uuid) to authenticated;

-- Public wrapper (PostgREST exposed)
create or replace function public.rpc_selftest_reset_booking_v1(
  p_org_id uuid,
  p_staff_user_id uuid
)
returns void
language sql
security definer
set search_path = pods, public
as $$
  select pods.rpc_selftest_reset_booking_v1(p_org_id, p_staff_user_id);
$$;

revoke all on function public.rpc_selftest_reset_booking_v1(uuid, uuid) from public;
revoke all on function public.rpc_selftest_reset_booking_v1(uuid, uuid) from anon;
grant execute on function public.rpc_selftest_reset_booking_v1(uuid, uuid) to authenticated;

commit;