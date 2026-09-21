-- pods.core.v1 — Billing ingest RPC (service-role only) + safety checks
begin;

-- In Supabase, auth.role() returns the JWT role (anon/authenticated/service_role).
-- We hard-require service_role here for maximum enforceability.
create or replace function pods.rpc_billing_ingest_webhook(
  p_org_id uuid,
  p_provider_customer_id text,
  p_provider_subscription_id text,
  p_status text,
  p_plan_id text,
  p_period_start timestamptz,
  p_period_end timestamptz,
  p_cancel_at_period_end boolean,
  p_billing_email text,
  p_event jsonb
)
returns void
language plpgsql
security definer
set search_path = pods, public
as $$
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'BILLING_INGEST_FORBIDDEN';
  end if;

  -- Upsert billing account
  insert into pods.billing_accounts(org_id, provider, provider_customer_id, billing_email, status, updated_at)
  values (p_org_id, 'stripe', p_provider_customer_id, p_billing_email, p_status, now())
  on conflict (org_id) do update set
    provider_customer_id = excluded.provider_customer_id,
    billing_email        = excluded.billing_email,
    status               = excluded.status,
    updated_at           = excluded.updated_at;

  -- Upsert subscription row
  insert into pods.subscriptions(
    org_id, provider_subscription_id, status, plan_id,
    current_period_start, current_period_end, cancel_at_period_end, updated_at
  )
  values (
    p_org_id, p_provider_subscription_id, p_status, p_plan_id,
    p_period_start, p_period_end, coalesce(p_cancel_at_period_end,false), now()
  )
  on conflict (provider_subscription_id) do update set
    status               = excluded.status,
    plan_id              = excluded.plan_id,
    current_period_start = excluded.current_period_start,
    current_period_end   = excluded.current_period_end,
    cancel_at_period_end = excluded.cancel_at_period_end,
    updated_at           = excluded.updated_at;

  -- Recompute entitlements (materialize enforcement surface)
  perform pods.rpc_recompute_entitlements(p_org_id);

  -- Audit
  insert into pods.audit_log(org_id, actor_user_id, actor_role_key, action_key, details)
  values (
    p_org_id, null, 'system', 'billing.ingest',
    jsonb_build_object(
      'provider','stripe',
      'customer_id', p_provider_customer_id,
      'subscription_id', p_provider_subscription_id,
      'status', p_status,
      'plan_id', p_plan_id,
      'event', coalesce(p_event,'{}'::jsonb)
    )
  );

end;
$$;

-- Lock down execution (no anon/authenticated)
revoke all on function pods.rpc_billing_ingest_webhook(
  uuid, text, text, text, text, timestamptz, timestamptz, boolean, text, jsonb
) from public;
revoke all on function pods.rpc_billing_ingest_webhook(
  uuid, text, text, text, text, timestamptz, timestamptz, boolean, text, jsonb
) from anon;
revoke all on function pods.rpc_billing_ingest_webhook(
  uuid, text, text, text, text, timestamptz, timestamptz, boolean, text, jsonb
) from authenticated;

-- In Supabase you should grant to service_role:
-- grant execute on function pods.rpc_billing_ingest_webhook(...) to service_role;

commit;