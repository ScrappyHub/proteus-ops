-- ProteusOps slice 6b — recompute merges entitlement overrides
-- Defect (pre-existing): pods.rpc_recompute_entitlements rebuilt org_entitlements from the plan
-- only; entitlement_overrides was never read, so overrides (incl. one-time purchase grants from
-- slice 6) had no effect. This version: paid flag (system) -> plan capabilities -> non-expired
-- overrides win per capability_key. 'paid_active' remains system-derived and cannot be overridden.
-- value_text is now materialized too. Behavior for orgs without overrides is unchanged.
create or replace function pods.rpc_recompute_entitlements(p_org_id uuid)
returns void language plpgsql security definer
set search_path = pods, public as $fn$
declare v_plan_id text; v_paid boolean := false;
begin
  select s.plan_id, (s.status in ('active','trialing'))
    into v_plan_id, v_paid
  from pods.subscriptions s where s.org_id = p_org_id
  order by s.updated_at desc limit 1;
  if v_plan_id is null then v_plan_id := 'proteusops_s_v1'; v_paid := false; end if;

  delete from pods.org_entitlements where org_id = p_org_id;

  insert into pods.org_entitlements(org_id, capability_key, value_type, value_bool, value_int, value_text, source)
  values (p_org_id, 'paid_active', 'bool', v_paid, null, null, 'system');

  insert into pods.org_entitlements(org_id, capability_key, value_type, value_bool, value_int, value_text, source)
  select p_org_id, c.capability_key, c.value_type, c.value_bool, c.value_int, c.value_text, 'plan'
  from pods.plan_capabilities c
  where c.plan_id = v_plan_id and c.capability_key <> 'paid_active';

  insert into pods.org_entitlements(org_id, capability_key, value_type, value_bool, value_int, value_text, source)
  select o.org_id, o.capability_key, o.value_type, o.value_bool, o.value_int, o.value_text, 'override'
  from pods.entitlement_overrides o
  where o.org_id = p_org_id and o.capability_key <> 'paid_active'
    and (o.expires_at is null or o.expires_at > now())
  on conflict (org_id, capability_key) do update
    set value_type = excluded.value_type, value_bool = excluded.value_bool,
        value_int = excluded.value_int, value_text = excluded.value_text,
        source = 'override', computed_at = now();
end $fn$;

-- Behavioral selftest: throwaway org, grant via override, recompute, assert, clean up.
create or replace function pods.rpc_selftest_entitlement_overrides_v1()
returns jsonb language plpgsql security definer
set search_path = pods, public as $fn$
declare v_org uuid; v_granted boolean; v_src text; v_expired boolean; v_paid_forged boolean; v_ok boolean;
begin
  insert into pods.orgs(slug, name) values ('selftest-overrides-'||replace(gen_random_uuid()::text,'-',''), 'selftest overrides')
  returning org_id into v_org;
  insert into pods.entitlement_overrides(org_id, capability_key, value_type, value_bool, reason)
    values (v_org, 'selftest.feature', 'bool', true, 'selftest');
  insert into pods.entitlement_overrides(org_id, capability_key, value_type, value_bool, reason, expires_at)
    values (v_org, 'selftest.expired', 'bool', true, 'selftest', now() - interval '1 day');
  insert into pods.entitlement_overrides(org_id, capability_key, value_type, value_bool, reason)
    values (v_org, 'paid_active', 'bool', true, 'selftest forged');
  perform pods.rpc_recompute_entitlements(v_org);

  v_granted := pods.has_cap_bool(v_org, 'selftest.feature');
  select source into v_src from pods.org_entitlements where org_id=v_org and capability_key='selftest.feature';
  v_expired := pods.has_cap_bool(v_org, 'selftest.expired');
  v_paid_forged := pods.has_cap_bool(v_org, 'paid_active');
  delete from pods.orgs where org_id = v_org;  -- cascades overrides + entitlements

  v_ok := v_granted and v_src = 'override' and not v_expired and not v_paid_forged;
  return jsonb_build_object('ok', v_ok,
    'token', case when v_ok then 'PROTEUSOPS_ENTITLEMENT_OVERRIDES_OK' else 'PROTEUSOPS_ENTITLEMENT_OVERRIDES_FAIL' end,
    'override_granted', v_granted, 'source', v_src, 'expired_ignored', not v_expired, 'paid_active_not_forgeable', not v_paid_forged);
end $fn$;

select pods.rpc_selftest_entitlement_overrides_v1();
