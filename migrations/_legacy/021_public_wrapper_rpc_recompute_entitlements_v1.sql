begin;

-- Ensure pods function exists (it does in your output)
-- pods.rpc_recompute_entitlements(p_org_id uuid)

create or replace function public.rpc_recompute_entitlements(
  p_org_id uuid
)
returns void
language sql
security definer
set search_path = pods, public
as $$
  select pods.rpc_recompute_entitlements(p_org_id);
$$;

revoke all on function public.rpc_recompute_entitlements(uuid) from public;
revoke all on function public.rpc_recompute_entitlements(uuid) from anon;
revoke all on function public.rpc_recompute_entitlements(uuid) from authenticated;
grant execute on function public.rpc_recompute_entitlements(uuid) to service_role;

commit;