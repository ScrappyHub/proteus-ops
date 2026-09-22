-- ProteusOps slice 6e — a lapsed subscription must not keep paid plan capabilities
-- Defect (found by the hosted Stripe e2e cancel test): rpc_recompute_entitlements materialized the
-- capabilities of the latest subscription's plan regardless of status. After cancel, paid_active went
-- false but booking_enabled / max_monthly_appointments from the paid plan stayed granted.
-- Fix: only an active/trialing subscription selects its plan; any other status (canceled, unpaid,
-- past_due, incomplete, incomplete_expired, paused) falls back to the baseline plan proteusops_s_v1,
-- exactly like an org with no subscription. Overrides still merge on top; paid_active still unforgeable.
create or replace function pods.rpc_recompute_entitlements(p_org_id uuid)
returns void language plpgsql security definer set search_path = pods, public as $function$
declare v_plan_id text; v_status text; v_paid boolean := false;
begin
  select s.plan_id, s.status into v_plan_id, v_status
    from pods.subscriptions s where s.org_id = p_org_id
    order by s.updated_at desc, s.provider_subscription_id limit 1;
  v_paid := coalesce(v_status in ('active','trialing'), false);
  if v_plan_id is null or not v_paid then
    v_plan_id := 'proteusops_s_v1';
  end if;

  delete from pods.org_entitlements where org_id = p_org_id;

  insert into pods.org_entitlements(org_id, capability_key, value_type, value_bool, value_int, value_text, source)
  values (p_org_id, 'paid_active', 'bool', v_paid, null, null, 'system');

  insert into pods.org_entitlements(org_id, capability_key, value_type, value_bool, value_int, value_text, source)
  select p_org_id, c.capability_key, c.value_type, c.value_bool, c.value_int, c.value_text, 'plan'
    from pods.plan_capabilities c where c.plan_id = v_plan_id and c.capability_key <> 'paid_active';

  insert into pods.org_entitlements(org_id, capability_key, value_type, value_bool, value_int, value_text, source)
  select o.org_id, o.capability_key, o.value_type, o.value_bool, o.value_int, o.value_text, 'override'
    from pods.entitlement_overrides o
   where o.org_id = p_org_id and o.capability_key <> 'paid_active'
     and (o.expires_at is null or o.expires_at > now())
  on conflict (org_id, capability_key) do update
    set value_type = excluded.value_type, value_bool = excluded.value_bool, value_int = excluded.value_int,
        value_text = excluded.value_text, source = 'override', computed_at = now();
end $function$;

-- Selftest: active sb plan grants booking; cancel drops to baseline; override survives the downgrade.
create or replace function pods.rpc_selftest_subscription_lapse_v1()
returns jsonb language plpgsql security definer set search_path = pods, public as $fn$
declare v_org uuid; v_sub text := 'sub_selftest_'||replace(gen_random_uuid()::text,'-','');
  a_paid bool; a_book bool; a_max bigint; c_paid bool; c_book bool; c_max bigint; c_ovr bool; v_ok bool;
begin
  insert into pods.orgs(slug, name) values ('selftest-lapse-'||replace(gen_random_uuid()::text,'-',''), 'selftest lapse')
  returning org_id into v_org;
  insert into pods.entitlement_overrides(org_id, capability_key, value_type, value_bool, reason)
    values (v_org, 'selftest.keep', 'bool', true, 'selftest');
  insert into pods.subscriptions(org_id, provider_subscription_id, status, plan_id, current_period_start, current_period_end, cancel_at_period_end, updated_at)
    values (v_org, v_sub, 'active', 'proteusops_sb_v1', now(), now() + interval '30 days', false, now());
  perform pods.rpc_recompute_entitlements(v_org);
  a_paid := coalesce(pods.has_cap_bool(v_org,'paid_active'), false);
  a_book := coalesce(pods.has_cap_bool(v_org,'booking_enabled'), false);
  select value_int into a_max from pods.org_entitlements where org_id=v_org and capability_key='max_monthly_appointments';

  update pods.subscriptions set status='canceled', updated_at=now() where provider_subscription_id=v_sub;
  perform pods.rpc_recompute_entitlements(v_org);
  c_paid := coalesce(pods.has_cap_bool(v_org,'paid_active'), false);
  c_book := coalesce(pods.has_cap_bool(v_org,'booking_enabled'), false);
  select value_int into c_max from pods.org_entitlements where org_id=v_org and capability_key='max_monthly_appointments';
  c_ovr := coalesce(pods.has_cap_bool(v_org,'selftest.keep'), false);
  delete from pods.orgs where org_id = v_org;  -- cascades subscriptions, overrides, entitlements

  v_ok := a_paid and a_book and coalesce(a_max,0) = 200 and not c_paid and not c_book and c_max is null and c_ovr;
  return jsonb_build_object('ok', v_ok,
    'token', case when v_ok then 'PROTEUSOPS_SUBSCRIPTION_LAPSE_OK' else 'PROTEUSOPS_SUBSCRIPTION_LAPSE_FAIL' end,
    'active', jsonb_build_object('paid', a_paid, 'booking', a_book, 'max_appts', a_max),
    'canceled', jsonb_build_object('paid', c_paid, 'booking', c_book, 'max_appts', c_max, 'override_kept', c_ovr));
end $fn$;
revoke all on function pods.rpc_selftest_subscription_lapse_v1() from public, anon, authenticated;

select pods.rpc_selftest_subscription_lapse_v1();
