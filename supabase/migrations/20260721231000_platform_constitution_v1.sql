create schema if not exists pods_provisioning;
create schema if not exists extensions;

create extension if not exists pgcrypto
with schema extensions;

create or replace function pods_provisioning._sha256_text_v1(
  p_text text
)
returns text
language sql
immutable
strict
parallel safe
set search_path = pg_catalog, extensions
as $function$
  select encode(
    extensions.digest(
      pg_catalog.convert_to(p_text, 'UTF8'),
      'sha256'
    ),
    'hex'
  );
$function$;
begin;

create table if not exists pods_provisioning.platform_constitution_versions_v1 (
  platform_constitution_version_id uuid primary key default gen_random_uuid(),
  constitution_key text not null unique,
  constitution_version text not null,
  constitution_status text not null default 'active',
  constitution_body jsonb not null,
  constitution_hash text not null,
  created_at timestamptz not null default now(),
  constraint platform_constitution_status_ck
    check (constitution_status in ('active','superseded','archived')),
  constraint platform_constitution_hash_ck
    check (constitution_hash ~ '^[a-f0-9]{64}$')
);

create table if not exists pods_provisioning.platform_authority_registry_v1 (
  platform_authority_registry_id uuid primary key default gen_random_uuid(),
  authority_key text not null unique,
  authority_version text not null default 'v1',
  authority_status text not null default 'active',
  authority_category text not null,
  required_surfaces jsonb not null default '[]'::jsonb,
  proof_token text not null,
  canonical_order integer not null,
  created_at timestamptz not null default now(),
  constraint platform_authority_registry_status_ck
    check (authority_status in ('active','planned','archived'))
);

create table if not exists pods_provisioning.platform_migration_lock_v1 (
  platform_migration_lock_id uuid primary key default gen_random_uuid(),
  migration_key text not null unique,
  migration_status text not null default 'applied',
  required_token text not null,
  verification_body jsonb not null default '{}'::jsonb,
  verification_hash text not null,
  created_at timestamptz not null default now(),
  constraint platform_migration_lock_status_ck
    check (migration_status in ('applied','verified','failed','archived')),
  constraint platform_migration_lock_hash_ck
    check (verification_hash ~ '^[a-f0-9]{64}$')
);

create or replace function pods_provisioning.rpc_seed_platform_constitution_v1()
returns jsonb
language plpgsql
security definer
set search_path = pods_provisioning, public
as $$
declare
  v_body jsonb;
  v_hash text;
begin
  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PLATFORM_CONSTITUTION_OK',
    'constitution_key', 'PROTEUSOPS_PLATFORM_CONSTITUTION_V1',
    'constitution_version', 'v1',
    'platform_identity', 'governed_application_platform',
    'primary_user_flow', jsonb_build_array(
      'choose_model',
      'purchase_or_entitle_model',
      'create_account_or_org',
      'connect_providers',
      'buy_or_connect_domain',
      'provision_database',
      'run_migrations',
      'deploy_frontend',
      'operate_from_dashboard'
    ),
    'authority_pattern', jsonb_build_array(
      'tables',
      'views',
      'parameters',
      'stored_procedures',
      'receipts',
      'selftests',
      'audit',
      'runtime_integration',
      'marketplace_integration'
    ),
    'commercial_future', jsonb_build_object(
      'figma_product_design', true,
      'stripe_payment_provider', true,
      'proteusops_entitlement_authority', true,
      'cloudflare_domain_dns_ssl_provider', true,
      'vercel_deployment_provider', true,
      'developer_marketplace_coming_soon', true
    )
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.platform_constitution_versions_v1(
    constitution_key,
    constitution_version,
    constitution_status,
    constitution_body,
    constitution_hash
  )
  values (
    'PROTEUSOPS_PLATFORM_CONSTITUTION_V1',
    'v1',
    'active',
    v_body,
    v_hash
  )
  on conflict (constitution_key) do update
  set constitution_version = excluded.constitution_version,
      constitution_status = excluded.constitution_status,
      constitution_body = excluded.constitution_body,
      constitution_hash = excluded.constitution_hash;

  insert into pods_provisioning.platform_authority_registry_v1(
    authority_key,
    authority_version,
    authority_status,
    authority_category,
    required_surfaces,
    proof_token,
    canonical_order
  )
  values
    ('MODEL_REGISTRY','v1','active','runtime',jsonb_build_array('tables','rpc','selftest'),'PROTEUSOPS_MODEL_TEMPLATE_REGISTRY_OK',10),
    ('MARKETPLACE','v1','active','commerce',jsonb_build_array('tables','rpc','selftest'),'PROTEUSOPS_MODEL_MARKETPLACE_OK',20),
    ('RUNTIME_GENERATOR','v1','active','runtime',jsonb_build_array('tables','rpc','selftest'),'PROTEUSOPS_MODEL_INSTANCE_RUNTIME_OK',30),
    ('LAUNCH_AUTHORITY','v1','active','deployment',jsonb_build_array('tables','rpc','receipts','selftest'),'PROTEUSOPS_MODEL_LAUNCH_AUTHORITY_OK',40),
    ('SNAPSHOT_ENGINE','v1','active','operations',jsonb_build_array('tables','rpc','receipts','selftest'),'PROTEUSOPS_MODEL_RUNTIME_SNAPSHOT_OK',50),
    ('AUDIT_LEDGER','v1','active','governance',jsonb_build_array('tables','rpc','checkpoint','selftest'),'PROTEUSOPS_MODEL_AUDIT_LEDGER_OK',60),
    ('RELEASE_GOVERNANCE','v1','active','deployment',jsonb_build_array('tables','rpc','history','rollback','selftest'),'PROTEUSOPS_MODEL_RELEASE_GOVERNANCE_OK',70),
    ('RUNTIME_DRIFT','v1','active','operations',jsonb_build_array('tables','rpc','findings','selftest'),'PROTEUSOPS_RUNTIME_DRIFT_OK',80),
    ('DOMAIN_PROVIDER_AUTHORITY','v1','active','provider',jsonb_build_array('tables','rpc','dns','ssl','selftest'),'PROTEUSOPS_DOMAIN_PROVIDER_AUTHORITY_OK',90),
    ('DEPLOYMENT_PROVIDER_AUTHORITY','v1','planned','provider',jsonb_build_array('tables','rpc','jobs','receipts','selftest'),'PROTEUSOPS_DEPLOYMENT_PROVIDER_AUTHORITY_OK',100),
    ('ENVIRONMENT_AUTHORITY','v1','planned','provider',jsonb_build_array('tables','rpc','bindings','selftest'),'PROTEUSOPS_ENVIRONMENT_AUTHORITY_OK',110),
    ('BILLING_ENTITLEMENT_AUTHORITY','v1','planned','commerce',jsonb_build_array('tables','rpc','stripe','entitlements','selftest'),'PROTEUSOPS_BILLING_ENTITLEMENT_AUTHORITY_OK',120),
    ('DEVELOPER_MARKETPLACE_AUTHORITY','v1','planned','ecosystem',jsonb_build_array('tables','rpc','portfolio','payouts','selftest'),'PROTEUSOPS_DEVELOPER_MARKETPLACE_AUTHORITY_OK',130)
  on conflict (authority_key) do update
  set authority_version = excluded.authority_version,
      authority_status = excluded.authority_status,
      authority_category = excluded.authority_category,
      required_surfaces = excluded.required_surfaces,
      proof_token = excluded.proof_token,
      canonical_order = excluded.canonical_order;

  return v_body || jsonb_build_object('constitution_hash', v_hash);
end;
$$;

create or replace function pods_provisioning.rpc_verify_platform_constitution_v1()
returns jsonb
language plpgsql
security definer
set search_path = pods_provisioning, public
as $$
declare
  v_seed jsonb;
  v_active_count int;
  v_planned_count int;
  v_body jsonb;
  v_hash text;
  v_id uuid;
begin
  v_seed := pods_provisioning.rpc_seed_platform_constitution_v1();

  select count(*)
  into v_active_count
  from pods_provisioning.platform_authority_registry_v1
  where authority_status = 'active';

  select count(*)
  into v_planned_count
  from pods_provisioning.platform_authority_registry_v1
  where authority_status = 'planned';

  if v_active_count < 9 then
    raise exception 'PLATFORM_CONSTITUTION_ACTIVE_AUTHORITY_COUNT_FAIL:%', v_active_count;
  end if;

  if v_planned_count < 4 then
    raise exception 'PLATFORM_CONSTITUTION_PLANNED_AUTHORITY_COUNT_FAIL:%', v_planned_count;
  end if;

  v_body := jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PLATFORM_CONSTITUTION_OK',
    'active_authority_count', v_active_count,
    'planned_authority_count', v_planned_count,
    'seed', v_seed
  );

  v_hash := pods_provisioning._sha256_text_v1(v_body::text);

  insert into pods_provisioning.platform_migration_lock_v1(
    migration_key,
    migration_status,
    required_token,
    verification_body,
    verification_hash
  )
  values (
    '20260721231000_platform_constitution_v1',
    'verified',
    'PROTEUSOPS_PLATFORM_CONSTITUTION_OK',
    v_body,
    v_hash
  )
  on conflict (migration_key) do update
  set migration_status = excluded.migration_status,
      required_token = excluded.required_token,
      verification_body = excluded.verification_body,
      verification_hash = excluded.verification_hash
  returning platform_migration_lock_id
  into v_id;

  return v_body || jsonb_build_object(
    'platform_migration_lock_id', v_id,
    'verification_hash', v_hash
  );
end;
$$;

commit;

select pods_provisioning.rpc_verify_platform_constitution_v1();
