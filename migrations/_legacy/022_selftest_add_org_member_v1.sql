begin;

create or replace function pods.rpc_selftest_add_org_member_v1(
  p_org_id uuid,
  p_user_id uuid,
  p_role text default 'owner'
)
returns void
language plpgsql
security definer
set search_path = pods, public
as $function$
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
$function$;

revoke all on function pods.rpc_selftest_add_org_member_v1(uuid, uuid, text) from public;
revoke all on function pods.rpc_selftest_add_org_member_v1(uuid, uuid, text) from anon;
revoke all on function pods.rpc_selftest_add_org_member_v1(uuid, uuid, text) from authenticated;
grant execute on function pods.rpc_selftest_add_org_member_v1(uuid, uuid, text) to service_role;

create or replace function public.rpc_selftest_add_org_member_v1(
  p_org_id uuid,
  p_user_id uuid,
  p_role text default 'owner'
)
returns void
language sql
security definer
set search_path = pods, public
as $sql$
  select pods.rpc_selftest_add_org_member_v1(p_org_id, p_user_id, p_role);
$sql$;

revoke all on function public.rpc_selftest_add_org_member_v1(uuid, uuid, text) from public;
revoke all on function public.rpc_selftest_add_org_member_v1(uuid, uuid, text) from anon;
revoke all on function public.rpc_selftest_add_org_member_v1(uuid, uuid, text) from authenticated;
grant execute on function public.rpc_selftest_add_org_member_v1(uuid, uuid, text) to service_role;

commit;
