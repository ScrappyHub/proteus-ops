-- ProteusOps slice 6g — past_due grace period (operator decision 2026-09-22: pause after a grace period)
-- A failed renewal (Stripe status past_due) keeps paid features for pods.billing_grace_period()
-- (7 days) while Stripe retries the card, then falls back to the baseline plan like any lapse.
-- The clock starts when the subscription FIRST enters past_due (past_due_since); repeated
-- past_due events do not extend it; any other status clears it.
-- New system capability billing_in_grace=true during the window (for a UI warning banner).

alter table pods.subscriptions add column if not exists past_due_since timestamptz;

create or replace function pods.billing_grace_period()
returns interval language sql immutable set search_path = pods, public as $fn$ select interval '7 days' $fn$;

create or replace function pods.rpc_billing_ingest_webhook(
  p_org_id uuid, p_provider_customer_id text, p_provider_subscription_id text, p_status text,
  p_plan_id text, p_period_start timestamptz, p_period_end timestamptz,
  p_cancel_at_period_end boolean, p_billing_email text, p_event jsonb
) returns void language plpgsql security definer set search_path = pods, public as $function$
begin
  if auth.role() is distinct from 'service_role' then raise exception 'BILLING_INGEST_FORBIDDEN'; end if;

  insert into pods.billing_accounts(org_id, provider, provider_customer_id, billing_email, status, updated_at)
  values (p_org_id, 'stripe', p_provider_customer_id, p_billing_email, p_status, now())
  on conflict (org_id) do update set provider_customer_id = excluded.provider_customer_id,
    billing_email = excluded.billing_email, status = excluded.status, updated_at = excluded.updated_at;

  insert into pods.subscriptions(org_id, provider_subscription_id, status, plan_id, current_period_start,
    current_period_end, cancel_at_period_end, updated_at, past_due_since)
  values (p_org_id, p_provider_subscription_id, p_status, p_plan_id, p_period_start, p_period_end,
    coalesce(p_cancel_at_period_end,false), now(), case when p_status = 'past_due' then now() end)
  on conflict (provider_subscription_id) do update set
    status = excluded.status, plan_id = excluded.plan_id,
    current_period_start = excluded.current_period_start, current_period_end = excluded.current_period_end,
    cancel_at_period_end = excluded.cancel_at_period_end, updated_at = excluded.updated_at,
    past_due_since = case when excluded.status = 'past_due'
                          then coalesce(pods.subscriptions.past_due_since, now()) end;

  perform pods.rpc_recompute_entitlements(p_org_id);

  insert into pods.audit_log(org_id, actor_user_id, actor_role_key, action_key, details)
  values (p_org_id, null, 'system', 'billing.ingest', jsonb_build_object('provider','stripe',
    'customer_id', p_provider_customer_id, 'subscription_id', p_provider_subscription_id,
    'status', p_status, 'plan_id', p_plan_id, 'event', coalesce(p_event,'{}'::jsonb)));
end; $function$;

create or replace function pods.rpc_recompute_entitlements(p_org_id uuid)
returns void language plpgsql security definer set search_path = pods, public as $function$
declare v_plan_id text; v_status text; v_pd_since timestamptz; v_paid boolean := false; v_grace boolean := false;
begin
  select s.plan_id, s.status, s.past_due_since into v_plan_id, v_status, v_pd_since
    from pods.subscriptions s where s.org_id = p_org_id
    order by s.updated_at desc, s.provider_subscription_id limit 1;
  v_grace := coalesce(v_status = 'past_due' and v_pd_since is not null
                      and v_pd_since > now() - pods.billing_grace_period(), false);
  v_paid := coalesce(v_status in ('active','trialing'), false) or v_grace;
  if v_plan_id is null or not v_paid then v_plan_id := 'proteusops_s_v1'; end if;

  delete from pods.org_entitlements where org_id = p_org_id;
  insert into pods.org_entitlements(org_id, capability_key, value_type, value_bool, value_int, value_text, source)
  values (p_org_id, 'paid_active', 'bool', v_paid, null, null, 'system'),
         (p_org_id, 'billing_in_grace', 'bool', v_grace, null, null, 'system');

  insert into pods.org_entitlements(org_id, capability_key, value_type, value_bool, value_int, value_text, source)
  select p_org_id, c.capability_key, c.value_type, c.value_bool, c.value_int, c.value_text, 'plan'
    from pods.plan_capabilities c
   where c.plan_id = v_plan_id and c.capability_key not in ('paid_active','billing_in_grace');

  insert into pods.org_entitlements(org_id, capability_key, value_type, value_bool, value_int, value_text, source)
  select o.org_id, o.capability_key, o.value_type, o.value_bool, o.value_int, o.value_text, 'override'
    from pods.entitlement_overrides o
   where o.org_id = p_org_id and o.capability_key not in ('paid_active','billing_in_grace')
     and (o.expires_at is null or o.expires_at > now())
  on conflict (org_id, capability_key) do update
    set value_type = excluded.value_type, value_bool = excluded.value_bool, value_int = excluded.value_int,
        value_text = excluded.value_text, source = 'override', computed_at = now();
end $function$;

-- Selftest: grace window via the real ingest path, clock not extended by repeat events, expiry, recovery.
create or replace function pods.rpc_selftest_billing_grace_v1()
returns jsonb language plpgsql security definer set search_path = pods, public as $fn$
declare v_org uuid; v_sfx text := replace(gen_random_uuid()::text,'-','');
  v_plan text := 'selftest_plan_'||v_sfx; v_sub text := 'sub_selftest_'||v_sfx;
  t1 timestamptz; t2 timestamptz;
  g_paid bool; g_flag bool; g_feat bool; clock_kept bool; x_paid bool; x_feat bool; x_flag bool;
  r_paid bool; r_flag bool; r_cleared bool; v_ok bool;
begin
  insert into pods.plan_tiers(plan_id, name, is_active) values (v_plan, 'selftest plan', true);
  insert into pods.plan_capabilities(plan_id, capability_key, value_type, value_bool) values (v_plan, 'selftest.plan_feature', 'bool', true);
  insert into pods.orgs(slug, name) values ('selftest-grace-'||v_sfx, 'selftest grace') returning org_id into v_org;

  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform pods.rpc_billing_ingest_webhook(v_org, 'cus_selftest', v_sub, 'active',   v_plan, now(), now()+interval '30 days', false, null, '{}'::jsonb);
  perform pods.rpc_billing_ingest_webhook(v_org, 'cus_selftest', v_sub, 'past_due', v_plan, now(), now()+interval '30 days', false, null, '{}'::jsonb);
  select past_due_since into t1 from pods.subscriptions where provider_subscription_id = v_sub;
  g_paid := coalesce(pods.has_cap_bool(v_org,'paid_active'), false);
  g_flag := coalesce(pods.has_cap_bool(v_org,'billing_in_grace'), false);
  g_feat := coalesce(pods.has_cap_bool(v_org,'selftest.plan_feature'), false);

  perform pods.rpc_billing_ingest_webhook(v_org, 'cus_selftest', v_sub, 'past_due', v_plan, now(), now()+interval '30 days', false, null, '{}'::jsonb);
  select past_due_since into t2 from pods.subscriptions where provider_subscription_id = v_sub;
  clock_kept := t1 is not null and t2 = t1;

  update pods.subscriptions set past_due_since = now() - pods.billing_grace_period() - interval '1 hour'
   where provider_subscription_id = v_sub;
  perform pods.rpc_recompute_entitlements(v_org);
  x_paid := coalesce(pods.has_cap_bool(v_org,'paid_active'), false);
  x_feat := coalesce(pods.has_cap_bool(v_org,'selftest.plan_feature'), false);
  x_flag := coalesce(pods.has_cap_bool(v_org,'billing_in_grace'), false);

  perform pods.rpc_billing_ingest_webhook(v_org, 'cus_selftest', v_sub, 'active', v_plan, now(), now()+interval '30 days', false, null, '{}'::jsonb);
  r_paid := coalesce(pods.has_cap_bool(v_org,'paid_active'), false);
  r_flag := coalesce(pods.has_cap_bool(v_org,'billing_in_grace'), false);
  select past_due_since is null into r_cleared from pods.subscriptions where provider_subscription_id = v_sub;
  perform set_config('request.jwt.claims', '', true);

  delete from pods.audit_log where org_id = v_org;
  delete from pods.orgs where org_id = v_org;
  delete from pods.plan_tiers where plan_id = v_plan;

  v_ok := g_paid and g_flag and g_feat and clock_kept and not x_paid and not x_feat and not x_flag
          and r_paid and not r_flag and r_cleared;
  return jsonb_build_object('ok', v_ok,
    'token', case when v_ok then 'PROTEUSOPS_BILLING_GRACE_OK' else 'PROTEUSOPS_BILLING_GRACE_FAIL' end,
    'in_grace', jsonb_build_object('paid', g_paid, 'flag', g_flag, 'plan_feature', g_feat, 'clock_not_extended', clock_kept),
    'expired', jsonb_build_object('paid', x_paid, 'plan_feature', x_feat, 'flag', x_flag),
    'recovered', jsonb_build_object('paid', r_paid, 'flag', r_flag, 'clock_cleared', r_cleared));
end $fn$;
revoke all on function pods.rpc_selftest_billing_grace_v1() from public, anon, authenticated;

select pods.rpc_selftest_billing_grace_v1();
