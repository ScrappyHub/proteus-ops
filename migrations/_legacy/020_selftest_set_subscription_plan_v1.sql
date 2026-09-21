begin;

create or replace function pods.rpc_selftest_set_subscription_plan_v1(
  p_org_id uuid,
  p_plan_id text,
  p_status text
)
returns void
language plpgsql
security definer
set search_path = pods, public
as $$
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED';
  end if;

  update pods.subscriptions
  set plan_id = p_plan_id,
      status = p_status,
      updated_at = now()
  where org_id = p_org_id;

  if not found then
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
      p_org_id,
      'selftest_' || p_org_id::text,
      p_status,
      p_plan_id,
      now(),
      now() + interval '30 days',
      false,
      now()
    );
  end if;
end;
$$;

revoke all on function pods.rpc_selftest_set_subscription_plan_v1(uuid,text,text) from public;
revoke all on function pods.rpc_selftest_set_subscription_plan_v1(uuid,text,text) from anon;
grant execute on function pods.rpc_selftest_set_subscription_plan_v1(uuid,text,text) to service_role;

create or replace function public.rpc_selftest_set_subscription_plan_v1(
  p_org_id uuid,
  p_plan_id text,
  p_status text
)
returns void
language sql
security definer
set search_path = pods, public
as $$
  select pods.rpc_selftest_set_subscription_plan_v1(p_org_id, p_plan_id, p_status);
$$;

revoke all on function public.rpc_selftest_set_subscription_plan_v1(uuid,text,text) from public;
revoke all on function public.rpc_selftest_set_subscription_plan_v1(uuid,text,text) from anon;
grant execute on function public.rpc_selftest_set_subscription_plan_v1(uuid,text,text) to service_role;

commit;