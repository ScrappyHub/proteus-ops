begin;

create or replace function pods.rpc_create_org_bootstrap(
  p_slug text,
  p_name text,
  p_plan_id text default null
)
returns uuid
language plpgsql
security definer
set search_path = pods, public
as $$
declare
  v_org_id uuid;
  v_uid uuid;
begin
  v_uid := auth.uid();
  if v_uid is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  insert into pods.orgs(slug, name) values (p_slug, p_name)
  returning org_id into v_org_id;

  insert into pods.org_members(org_id, user_id, role_key)
  values (v_org_id, v_uid, 'owner');

  -- install core + storefront for this org (version lock for v1)
  insert into pods.org_models(org_id, model_id, version)
  values
    (v_org_id, 'pods.core', '1.0.0'),
    (v_org_id, 'pods.storefront', '1.0.0')
  on conflict do nothing;

  -- Optional: attach a plan_id placeholder (subscription sync will override later)
  if p_plan_id is not null then
    insert into pods.subscriptions(
      org_id, provider_subscription_id, status, plan_id,
      current_period_start, current_period_end, cancel_at_period_end, updated_at
    )
    values (
      v_org_id, ('bootstrap_' || v_org_id::text), 'trialing', p_plan_id,
      now(), now() + interval '30 days', false, now()
    )
    on conflict (provider_subscription_id) do nothing;
  end if;

  -- recompute entitlements (service definer)
  perform pods.rpc_recompute_entitlements(v_org_id);

  -- create initial storefront profile
  insert into pods.storefront_profiles(org_id, display_name)
  values (v_org_id, p_name);

  insert into pods.audit_log(org_id, actor_user_id, actor_role_key, action_key, details)
  values (v_org_id, v_uid, 'owner', 'org.bootstrap', jsonb_build_object('slug', p_slug, 'plan_id', p_plan_id));

  return v_org_id;
end;
$$;

revoke all on function pods.rpc_create_org_bootstrap(text, text, text) from public;
grant execute on function pods.rpc_create_org_bootstrap(text, text, text) to authenticated;

commit;