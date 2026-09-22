-- ProteusOps slice 6f — make the subscription-lapse selftest self-contained
-- The 6e selftest relied on seeded plan rows (proteusops_sb_v1) that exist on hosted but not in a
-- fresh local reset, so it reported FAIL locally (hosted: PROTEUSOPS_SUBSCRIPTION_LAPSE_OK). It now
-- creates its own temporary plan tier + capabilities and removes them afterwards. No behaviour change
-- to rpc_recompute_entitlements.
create or replace function pods.rpc_selftest_subscription_lapse_v1()
returns jsonb language plpgsql security definer set search_path = pods, public as $fn$
declare v_org uuid; v_sfx text := replace(gen_random_uuid()::text,'-','');
  v_plan text := 'selftest_plan_'||v_sfx; v_sub text := 'sub_selftest_'||v_sfx;
  a_paid bool; a_feat bool; a_max bigint; c_paid bool; c_feat bool; c_max bigint; c_ovr bool; v_ok bool;
begin
  insert into pods.plan_tiers(plan_id, name, is_active) values (v_plan, 'selftest plan', true);
  insert into pods.plan_capabilities(plan_id, capability_key, value_type, value_bool, value_int) values
    (v_plan, 'selftest.plan_feature', 'bool', true, null),
    (v_plan, 'selftest.plan_limit',   'int',  null, 200);
  insert into pods.orgs(slug, name) values ('selftest-lapse-'||v_sfx, 'selftest lapse') returning org_id into v_org;
  insert into pods.entitlement_overrides(org_id, capability_key, value_type, value_bool, reason)
    values (v_org, 'selftest.keep', 'bool', true, 'selftest');
  insert into pods.subscriptions(org_id, provider_subscription_id, status, plan_id, current_period_start, current_period_end, cancel_at_period_end, updated_at)
    values (v_org, v_sub, 'active', v_plan, now(), now() + interval '30 days', false, now());
  perform pods.rpc_recompute_entitlements(v_org);
  a_paid := coalesce(pods.has_cap_bool(v_org,'paid_active'), false);
  a_feat := coalesce(pods.has_cap_bool(v_org,'selftest.plan_feature'), false);
  select value_int into a_max from pods.org_entitlements where org_id=v_org and capability_key='selftest.plan_limit';

  update pods.subscriptions set status='canceled', updated_at=now() where provider_subscription_id=v_sub;
  perform pods.rpc_recompute_entitlements(v_org);
  c_paid := coalesce(pods.has_cap_bool(v_org,'paid_active'), false);
  c_feat := coalesce(pods.has_cap_bool(v_org,'selftest.plan_feature'), false);
  select value_int into c_max from pods.org_entitlements where org_id=v_org and capability_key='selftest.plan_limit';
  c_ovr := coalesce(pods.has_cap_bool(v_org,'selftest.keep'), false);

  delete from pods.orgs where org_id = v_org;          -- cascades subscriptions, overrides, entitlements
  delete from pods.plan_tiers where plan_id = v_plan;  -- cascades plan_capabilities

  v_ok := a_paid and a_feat and coalesce(a_max,0) = 200 and not c_paid and not c_feat and c_max is null and c_ovr;
  return jsonb_build_object('ok', v_ok,
    'token', case when v_ok then 'PROTEUSOPS_SUBSCRIPTION_LAPSE_OK' else 'PROTEUSOPS_SUBSCRIPTION_LAPSE_FAIL' end,
    'active', jsonb_build_object('paid', a_paid, 'plan_feature', a_feat, 'plan_limit', a_max),
    'canceled', jsonb_build_object('paid', c_paid, 'plan_feature', c_feat, 'plan_limit', c_max, 'override_kept', c_ovr));
end $fn$;
revoke all on function pods.rpc_selftest_subscription_lapse_v1() from public, anon, authenticated;

select pods.rpc_selftest_subscription_lapse_v1();
