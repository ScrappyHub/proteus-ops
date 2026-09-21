begin;

create or replace function pods.rpc_add_time_off_block_v1(
  p_org_id uuid,
  p_staff_user_id uuid,
  p_start_at timestamptz,
  p_end_at timestamptz,
  p_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = pods, public
as $$
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

revoke all on function pods.rpc_add_time_off_block_v1(uuid, uuid, timestamptz, timestamptz, text) from public;
grant execute on function pods.rpc_add_time_off_block_v1(uuid, uuid, timestamptz, timestamptz, text) to authenticated;

create or replace function pods.rpc_delete_time_off_block_v1(
  p_org_id uuid,
  p_block_id uuid
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

revoke all on function pods.rpc_delete_time_off_block_v1(uuid, uuid) from public;
grant execute on function pods.rpc_delete_time_off_block_v1(uuid, uuid) to authenticated;

commit;