begin;

-- Drop broken variants if any exist
drop function if exists pods.rpc_upsert_availability_rule_v1(uuid, uuid, uuid, uuid, int, time, time, boolean);
drop function if exists pods.rpc_delete_availability_rule_v1(uuid, uuid);

-- IMPORTANT: no defaulted args mid-signature.
-- Caller passes NULL for p_rule_id to create and NULL for p_location_id if unused.
create or replace function pods.rpc_upsert_availability_rule_v1(
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
language plpgsql
security definer
set search_path = pods, public
as $$
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

revoke all on function pods.rpc_upsert_availability_rule_v1(uuid, uuid, uuid, uuid, int, time, time, boolean) from public;
grant execute on function pods.rpc_upsert_availability_rule_v1(uuid, uuid, uuid, uuid, int, time, time, boolean) to authenticated;

create or replace function pods.rpc_delete_availability_rule_v1(
  p_org_id uuid,
  p_rule_id uuid
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

revoke all on function pods.rpc_delete_availability_rule_v1(uuid, uuid) from public;
grant execute on function pods.rpc_delete_availability_rule_v1(uuid, uuid) to authenticated;

commit;