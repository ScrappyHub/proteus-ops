-- ProteusOps slice 6d — service-role-only public wrappers for the Stripe ingest RPCs
-- Defect: the stripe-webhook edge function calls supabase.rpc(), which PostgREST resolves in the
-- exposed `public` schema only. The ingest functions live in `pods`, so every tagged Stripe event
-- failed with 500 "ingest error" (Stripe retries; nothing lost). Follows the repo's existing
-- public-wrapper pattern. EXECUTE is granted to service_role only — anon/authenticated cannot call
-- these; the inner pods functions additionally enforce auth.role() = 'service_role'.
create or replace function public.rpc_billing_ingest_webhook(
  p_org_id uuid, p_provider_customer_id text, p_provider_subscription_id text, p_status text,
  p_plan_id text, p_period_start timestamptz, p_period_end timestamptz,
  p_cancel_at_period_end boolean, p_billing_email text, p_event jsonb
) returns void language sql security definer set search_path = pods, public as $fn$
  select pods.rpc_billing_ingest_webhook(p_org_id, p_provider_customer_id, p_provider_subscription_id,
    p_status, p_plan_id, p_period_start, p_period_end, p_cancel_at_period_end, p_billing_email, p_event);
$fn$;

create or replace function public.rpc_grant_one_time_entitlement_v1(
  p_org_id uuid, p_provider_key text, p_provider_payment_id text, p_capability_key text,
  p_value_type text, p_value_bool boolean, p_value_int bigint, p_value_text text, p_event jsonb
) returns jsonb language sql security definer set search_path = pods, pods_provisioning, public as $fn$
  select pods.rpc_grant_one_time_entitlement_v1(p_org_id, p_provider_key, p_provider_payment_id,
    p_capability_key, p_value_type, p_value_bool, p_value_int, p_value_text, p_event);
$fn$;

revoke all on function public.rpc_billing_ingest_webhook(uuid,text,text,text,text,timestamptz,timestamptz,boolean,text,jsonb) from public, anon, authenticated;
revoke all on function public.rpc_grant_one_time_entitlement_v1(uuid,text,text,text,text,boolean,bigint,text,jsonb) from public, anon, authenticated;
grant execute on function public.rpc_billing_ingest_webhook(uuid,text,text,text,text,timestamptz,timestamptz,boolean,text,jsonb) to service_role;
grant execute on function public.rpc_grant_one_time_entitlement_v1(uuid,text,text,text,text,boolean,bigint,text,jsonb) to service_role;

-- Selftest: wrappers exist, service_role can execute, anon/authenticated cannot.
create or replace function pods_provisioning.rpc_selftest_stripe_ingest_wrappers_v1()
returns jsonb language plpgsql security definer set search_path = pods_provisioning, public as $fn$
declare b_svc bool; g_svc bool; b_anon bool; g_anon bool; b_auth bool; g_auth bool; v_ok bool;
begin
  b_svc  := has_function_privilege('service_role','public.rpc_billing_ingest_webhook(uuid,text,text,text,text,timestamptz,timestamptz,boolean,text,jsonb)','execute');
  g_svc  := has_function_privilege('service_role','public.rpc_grant_one_time_entitlement_v1(uuid,text,text,text,text,boolean,bigint,text,jsonb)','execute');
  b_anon := has_function_privilege('anon','public.rpc_billing_ingest_webhook(uuid,text,text,text,text,timestamptz,timestamptz,boolean,text,jsonb)','execute');
  g_anon := has_function_privilege('anon','public.rpc_grant_one_time_entitlement_v1(uuid,text,text,text,text,boolean,bigint,text,jsonb)','execute');
  b_auth := has_function_privilege('authenticated','public.rpc_billing_ingest_webhook(uuid,text,text,text,text,timestamptz,timestamptz,boolean,text,jsonb)','execute');
  g_auth := has_function_privilege('authenticated','public.rpc_grant_one_time_entitlement_v1(uuid,text,text,text,text,boolean,bigint,text,jsonb)','execute');
  v_ok := b_svc and g_svc and not b_anon and not g_anon and not b_auth and not g_auth;
  return jsonb_build_object('ok', v_ok,
    'token', case when v_ok then 'PROTEUSOPS_STRIPE_INGEST_WRAPPERS_OK' else 'PROTEUSOPS_STRIPE_INGEST_WRAPPERS_FAIL' end,
    'service_role_can_call', b_svc and g_svc, 'anon_blocked', not (b_anon or g_anon), 'authenticated_blocked', not (b_auth or g_auth));
end $fn$;

select pods_provisioning.rpc_selftest_stripe_ingest_wrappers_v1();
