-- ProteusOps slice 6c — fix entitlement-overrides selftest NULL handling
-- has_cap_bool returns NULL (no row) for an absent capability; the 6b selftest treated NULL as
-- unknown, so a correctly-ignored expired override reported ok=null. Coalesce to false. The
-- recompute fix itself is unchanged.
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

  v_granted := coalesce(pods.has_cap_bool(v_org, 'selftest.feature'), false);
  select source into v_src from pods.org_entitlements where org_id=v_org and capability_key='selftest.feature';
  v_expired := coalesce(pods.has_cap_bool(v_org, 'selftest.expired'), false);
  v_paid_forged := coalesce(pods.has_cap_bool(v_org, 'paid_active'), false);
  delete from pods.orgs where org_id = v_org;  -- cascades overrides + entitlements

  v_ok := v_granted and coalesce(v_src,'') = 'override' and not v_expired and not v_paid_forged;
  return jsonb_build_object('ok', v_ok,
    'token', case when v_ok then 'PROTEUSOPS_ENTITLEMENT_OVERRIDES_OK' else 'PROTEUSOPS_ENTITLEMENT_OVERRIDES_FAIL' end,
    'override_granted', v_granted, 'source', v_src, 'expired_ignored', not v_expired, 'paid_active_not_forgeable', not v_paid_forged);
end $fn$;

select pods.rpc_selftest_entitlement_overrides_v1();
