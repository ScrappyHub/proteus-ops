begin;

create or replace function pods.rpc_selftest_booking_gates_v1(p_org_id uuid, p_staff_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pods, public
as $$
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

revoke all on function pods.rpc_selftest_booking_gates_v1(uuid, uuid) from public;
revoke all on function pods.rpc_selftest_booking_gates_v1(uuid, uuid) from anon;
revoke all on function pods.rpc_selftest_booking_gates_v1(uuid, uuid) from authenticated;

-- In Supabase:
-- grant execute on function pods.rpc_selftest_booking_gates_v1(uuid, uuid) to service_role;

commit;