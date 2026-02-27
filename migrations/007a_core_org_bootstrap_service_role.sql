begin;

create or replace function pods.rpc_create_org_bootstrap_service_role_v1(
  p_owner_user_id uuid,
  p_slug text,
  p_name text,
  p_plan_id text
)
returns uuid
language plpgsql
security definer
set search_path = pods, public
as $$
declare
  v_org_id uuid;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED';
  end if;

  insert into pods.orgs(slug, name, is_active)
  values (p_slug, p_name, true)
  returning org_id into v_org_id;

  insert into pods.org_members(org_id, user_id, role_key)
  values (v_org_id, p_owner_user_id, 'owner');

  -- Install models for this org
  insert into pods.org_models(org_id, model_id, version)
  values
    (v_org_id, 'pods.core', '1.0.0'),
    (v_org_id, 'pods.storefront', '1.0.0'),
    (v_org_id, 'pods.booking', '1.0.0')
  on conflict do nothing;

  -- Create an active subscription record (simulated)
  insert into pods.subscriptions(
    org_id,
    provider_subscription_id,
    status,
    plan_id,
    current_period_start,
    current_period_end,
    cancel_at_period_end,
    updated_at
  )
  values (
    v_org_id,
    ('bootstrap_' || v_org_id::text),
    'active',
    p_plan_id,
    now(),
    now() + interval '30 days',
    false,
    now()
  )
  on conflict (provider_subscription_id) do nothing;

  -- Recompute entitlements from subscription
  perform pods.rpc_recompute_entitlements(v_org_id);

  -- Ensure storefront profile exists
  insert into pods.storefront_profiles(org_id, display_name)
  values (v_org_id, p_name)
  on conflict (org_id) do update set display_name = excluded.display_name;

  insert into pods.audit_log(org_id, actor_user_id, actor_role_key, action_key, details)
  values (
    v_org_id, null, 'service_role', 'org.bootstrap.service_role',
    jsonb_build_object('slug', p_slug, 'owner_user_id', p_owner_user_id, 'plan_id', p_plan_id)
  );

  return v_org_id;
end;
$$;

revoke all on function pods.rpc_create_org_bootstrap_service_role_v1(uuid, text, text, text) from public;
grant execute on function pods.rpc_create_org_bootstrap_service_role_v1(uuid, text, text, text) to service_role;

commit;