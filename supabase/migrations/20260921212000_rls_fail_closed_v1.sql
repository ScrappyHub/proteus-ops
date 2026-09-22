-- ProteusOps security hardening v2 — RLS fail-closed on all pods* base tables
-- Confirmed access model: clients (anon/authenticated) never touch base tables directly;
-- all access is via SECURITY DEFINER RPCs and views. This ENABLES (not FORCES) row level
-- security on every pods* base table that lacks it, so any accidental future client grant is
-- denied by default. ENABLE (not FORCE) is deliberate: SECURITY DEFINER functions run as the
-- table owner and continue to bypass RLS, so existing RPC behavior is unchanged. Idempotent.
do $rls$
declare r record; n int := 0;
begin
  for r in
    select np.nspname, c.relname
    from pg_class c join pg_namespace np on np.oid = c.relnamespace
    where c.relkind = 'r' and np.nspname like 'pods%' and not c.relrowsecurity
  loop
    execute format('alter table %I.%I enable row level security', r.nspname, r.relname);
    n := n + 1;
  end loop;
  raise notice 'PROTEUSOPS_RLS_FAIL_CLOSED: enabled RLS on % base tables', n;
end
$rls$;

-- Structural fail-closed selftest: every pods* base table has RLS and none is granted to
-- client roles. Recomputes from the live catalog (never trusts stored state).
create or replace function pods_core.rpc_selftest_rls_fail_closed_v1()
returns jsonb
language plpgsql
security definer
set search_path = pods_core, pods, pods_billing, pods_ops, pods_provisioning, pods_public, public
as $fn$
declare
  v_total int; v_no_rls int; v_client_grant int;
begin
  select count(*) into v_total
    from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where c.relkind='r' and n.nspname like 'pods%';
  select count(*) into v_no_rls
    from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where c.relkind='r' and n.nspname like 'pods%' and not c.relrowsecurity;
  select count(*) into v_client_grant from (
    select g.table_schema, g.table_name
    from information_schema.role_table_grants g
    where g.table_schema like 'pods%'
      and g.grantee in ('anon','authenticated')
      and g.privilege_type in ('SELECT','INSERT','UPDATE','DELETE')
      and exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                  where c.relkind='r' and n.nspname=g.table_schema and c.relname=g.table_name)
    group by 1,2
  ) x;
  if v_no_rls > 0 or v_client_grant > 0 then
    return jsonb_build_object('ok',false,'token','PROTEUSOPS_RLS_FAIL_CLOSED_FAIL',
      'base_tables',v_total,'tables_without_rls',v_no_rls,'base_tables_client_granted',v_client_grant);
  end if;
  return jsonb_build_object('ok',true,'token','PROTEUSOPS_RLS_FAIL_CLOSED_OK',
    'base_tables',v_total,'tables_without_rls',0,'base_tables_client_granted',0);
end
$fn$;

select pods_core.rpc_selftest_rls_fail_closed_v1();
