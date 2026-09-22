-- ProteusOps slice 5 — authority binding: make "active authority" mean "verified authority"
-- The constitution declares 9 active authorities but only counts registry rows. This binds
-- each active authority to a representative implementing object and verifies it EXISTS, so
-- verification proves implementation, not just declaration.
create table if not exists pods_provisioning.authority_binding_map_v1 (
  authority_key text not null references pods_provisioning.platform_authority_registry_v1(authority_key),
  bound_object text not null,           -- schema.object that must exist
  object_kind text not null default 'table',
  primary key (authority_key, bound_object),
  constraint authority_binding_kind_ck check (object_kind in ('table','view','function'))
);

-- Keep the fail-closed invariant: new base table is RLS-enabled (RPC-only, no client grant).
alter table pods_provisioning.authority_binding_map_v1 enable row level security;

insert into pods_provisioning.authority_binding_map_v1(authority_key, bound_object, object_kind) values
  ('MODEL_REGISTRY','pods_provisioning.model_template_registry_v1','table'),
  ('MARKETPLACE','pods_provisioning.model_marketplace_catalog_v1','table'),
  ('RUNTIME_GENERATOR','pods_provisioning.model_instance_runtimes_v1','table'),
  ('LAUNCH_AUTHORITY','pods_provisioning.model_launch_authorities_v1','table'),
  ('SNAPSHOT_ENGINE','pods_provisioning.model_runtime_snapshots_v1','table'),
  ('AUDIT_LEDGER','pods_provisioning.model_audit_ledger_v1','table'),
  ('RELEASE_GOVERNANCE','pods_provisioning.model_releases_v1','table'),
  ('RUNTIME_DRIFT','pods_provisioning.model_runtime_drift_reports_v1','table'),
  ('DOMAIN_PROVIDER_AUTHORITY','pods_provisioning.domain_provider_connections_v1','table')
on conflict (authority_key, bound_object) do nothing;

-- Verify: every ACTIVE authority has at least one binding, and every bound object exists.
create or replace function pods_provisioning.rpc_verify_authority_bindings_v1()
returns jsonb language plpgsql
security definer set search_path = pods_provisioning, public as $fn$
declare
  v_active int; v_bound_active int; v_missing_binding text[]; v_missing_object text[];
begin
  select count(*) into v_active
    from pods_provisioning.platform_authority_registry_v1 where authority_status='active';

  -- active authorities lacking any binding
  select coalesce(array_agg(a.authority_key order by a.canonical_order), '{}')
    into v_missing_binding
    from pods_provisioning.platform_authority_registry_v1 a
    where a.authority_status='active'
      and not exists (select 1 from pods_provisioning.authority_binding_map_v1 m where m.authority_key=a.authority_key);

  -- bound objects (for active authorities) that do not exist
  select coalesce(array_agg(m.authority_key||' -> '||m.bound_object), '{}')
    into v_missing_object
    from pods_provisioning.authority_binding_map_v1 m
    join pods_provisioning.platform_authority_registry_v1 a on a.authority_key=m.authority_key and a.authority_status='active'
    where to_regclass(m.bound_object) is null;

  select count(distinct m.authority_key) into v_bound_active
    from pods_provisioning.authority_binding_map_v1 m
    join pods_provisioning.platform_authority_registry_v1 a on a.authority_key=m.authority_key and a.authority_status='active'
    where to_regclass(m.bound_object) is not null;

  if array_length(v_missing_binding,1) is null and array_length(v_missing_object,1) is null then
    return jsonb_build_object('ok',true,'token','PROTEUSOPS_AUTHORITY_BINDINGS_OK',
      'active_authorities',v_active,'active_authorities_backed',v_bound_active,
      'missing_bindings','[]'::jsonb,'missing_objects','[]'::jsonb);
  end if;
  return jsonb_build_object('ok',false,'token','PROTEUSOPS_AUTHORITY_BINDINGS_FAIL',
    'active_authorities',v_active,'active_authorities_backed',v_bound_active,
    'missing_bindings',to_jsonb(v_missing_binding),'missing_objects',to_jsonb(v_missing_object));
end $fn$;

select pods_provisioning.rpc_verify_authority_bindings_v1();
