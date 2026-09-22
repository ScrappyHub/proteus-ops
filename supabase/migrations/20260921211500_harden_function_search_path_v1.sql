-- ProteusOps security hardening v1 — fixed search_path on SECURITY DEFINER functions
-- Closes a systemic privilege-escalation vector: a SECURITY DEFINER function with no
-- fixed search_path can be exploited by a caller who manipulates search_path to shadow
-- objects the function references. This sets a FIXED search_path on every SECURITY DEFINER
-- function in the pods* schemas that does not already declare one. Behavior-preserving
-- (all lanes remain resolvable); idempotent (skips functions that already set search_path,
-- e.g. the constitution RPCs). Follow-up: tighten each function to a minimal path.
do $harden$
declare
  r record;
  n int := 0;
begin
  for r in
    select p.oid, np.nspname, p.proname,
           pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    join pg_namespace np on np.oid = p.pronamespace
    where np.nspname like 'pods%'
      and p.prosecdef
      and not exists (
        select 1 from unnest(coalesce(p.proconfig, '{}'::text[])) c
        where c like 'search_path=%'
      )
  loop
    execute format(
      'alter function %I.%I(%s) set search_path = pods, pods_core, pods_billing, pods_ops, pods_provisioning, pods_public, public, extensions',
      r.nspname, r.proname, r.args
    );
    n := n + 1;
  end loop;
  raise notice 'PROTEUSOPS_HARDEN_SEARCH_PATH: set fixed search_path on % functions', n;
end
$harden$;
