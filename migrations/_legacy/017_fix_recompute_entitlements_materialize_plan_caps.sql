begin;

create or replace function pods.rpc_recompute_entitlements(p_org_id uuid)
returns void
language plpgsql
security definer
set search_path = pods, public
as $$
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

revoke all on function pods.rpc_recompute_entitlements(uuid) from public;
grant execute on function pods.rpc_recompute_entitlements(uuid) to service_role;

commit;