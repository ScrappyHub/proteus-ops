begin;

create schema if not exists pods_provisioning;

comment on schema pods_provisioning is
'Tier-2 ProteusOps provisioning lane for deterministic business base-model deployment.';

create table if not exists pods_provisioning.template_registry_v1 (
  template_key text not null,
  template_version text not null,
  vertical text not null,
  display_name text not null,
  description text not null default '',
  seeded_hash text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (template_key, template_version),
  constraint template_registry_key_ck
    check (template_key ~ '^[A-Z0-9_]+$'),
  constraint template_registry_version_ck
    check (template_version ~ '^v[0-9]+$'),
  constraint template_registry_seeded_hash_ck
    check (seeded_hash = '' or seeded_hash ~ '^[a-f0-9]{64}$')
);

comment on table pods_provisioning.template_registry_v1 is
'Canonical registry of deterministic ProteusOps business base-model templates.';

create table if not exists pods_provisioning.provision_runs_v1 (
  provision_run_id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  template_key text not null,
  template_version text not null,
  operator_user_id uuid,
  status text not null default 'started',
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  receipt_hash text not null default '',
  failure_token text not null default '',
  metadata jsonb not null default '{}'::jsonb,
  constraint provision_runs_status_ck
    check (status in ('started','completed','failed')),
  constraint provision_runs_receipt_hash_ck
    check (receipt_hash = '' or receipt_hash ~ '^[a-f0-9]{64}$'),
  constraint provision_runs_template_fk
    foreign key (template_key, template_version)
    references pods_provisioning.template_registry_v1(template_key, template_version)
);

comment on table pods_provisioning.provision_runs_v1 is
'Append-style record of deterministic provisioning attempts for an organization.';

create table if not exists pods_provisioning.seeded_objects_v1 (
  seeded_object_id uuid primary key default gen_random_uuid(),
  provision_run_id uuid not null references pods_provisioning.provision_runs_v1(provision_run_id) on delete cascade,
  org_id uuid not null,
  template_key text not null,
  template_version text not null,
  object_kind text not null,
  object_schema text not null,
  object_table text not null,
  object_id uuid,
  object_key text not null,
  seeded_hash text not null default '',
  created_at timestamptz not null default now(),
  constraint seeded_objects_kind_ck
    check (object_kind in ('org','role','service','availability_template','booking_rule','public_surface','entitlement','receipt')),
  constraint seeded_objects_hash_ck
    check (seeded_hash = '' or seeded_hash ~ '^[a-f0-9]{64}$'),
  constraint seeded_objects_template_fk
    foreign key (template_key, template_version)
    references pods_provisioning.template_registry_v1(template_key, template_version),
  constraint seeded_objects_run_unique
    unique (provision_run_id, object_kind, object_key)
);

comment on table pods_provisioning.seeded_objects_v1 is
'Tracks every deterministic object created or claimed during template provisioning.';

create table if not exists pods_provisioning.provisioning_receipts_v1 (
  receipt_id uuid primary key default gen_random_uuid(),
  provision_run_id uuid not null references pods_provisioning.provision_runs_v1(provision_run_id) on delete cascade,
  org_id uuid not null,
  event_type text not null,
  event_token text not null,
  receipt_body jsonb not null,
  receipt_hash text not null,
  created_at timestamptz not null default now(),
  constraint provisioning_receipts_hash_ck
    check (receipt_hash ~ '^[a-f0-9]{64}$')
);

comment on table pods_provisioning.provisioning_receipts_v1 is
'Deterministic receipt ledger for template provisioning events.';

create unique index if not exists provision_runs_completed_once_idx
on pods_provisioning.provision_runs_v1(org_id, template_key, template_version)
where status = 'completed';

create index if not exists seeded_objects_org_idx
on pods_provisioning.seeded_objects_v1(org_id, template_key, template_version);

create index if not exists provisioning_receipts_run_idx
on pods_provisioning.provisioning_receipts_v1(provision_run_id, created_at);

alter table pods_provisioning.template_registry_v1 enable row level security;
alter table pods_provisioning.provision_runs_v1 enable row level security;
alter table pods_provisioning.seeded_objects_v1 enable row level security;
alter table pods_provisioning.provisioning_receipts_v1 enable row level security;

drop policy if exists template_registry_service_all_v1 on pods_provisioning.template_registry_v1;
create policy template_registry_service_all_v1
on pods_provisioning.template_registry_v1
for all
to service_role
using (true)
with check (true);

drop policy if exists provision_runs_service_all_v1 on pods_provisioning.provision_runs_v1;
create policy provision_runs_service_all_v1
on pods_provisioning.provision_runs_v1
for all
to service_role
using (true)
with check (true);

drop policy if exists seeded_objects_service_all_v1 on pods_provisioning.seeded_objects_v1;
create policy seeded_objects_service_all_v1
on pods_provisioning.seeded_objects_v1
for all
to service_role
using (true)
with check (true);

drop policy if exists provisioning_receipts_service_all_v1 on pods_provisioning.provisioning_receipts_v1;
create policy provisioning_receipts_service_all_v1
on pods_provisioning.provisioning_receipts_v1
for all
to service_role
using (true)
with check (true);

create or replace view pods_provisioning.v_template_registry_v1 as
select
  template_key,
  template_version,
  vertical,
  display_name,
  description,
  seeded_hash,
  active,
  created_at
from pods_provisioning.template_registry_v1
order by template_key, template_version;

create or replace view pods_provisioning.v_provision_runs_v1 as
select
  provision_run_id,
  org_id,
  template_key,
  template_version,
  operator_user_id,
  status,
  started_at,
  completed_at,
  receipt_hash,
  failure_token,
  metadata
from pods_provisioning.provision_runs_v1
order by started_at desc, provision_run_id;

create or replace function pods_provisioning.rpc_selftest_provisioning_lane_v1()
returns jsonb
language plpgsql
security definer
set search_path = pods_provisioning, public
as $$
declare
  v_schema_exists boolean;
  v_template_table_exists boolean;
  v_runs_table_exists boolean;
  v_seeded_table_exists boolean;
  v_receipts_table_exists boolean;
begin
  select exists (
    select 1
    from information_schema.schemata s
    where s.schema_name = 'pods_provisioning'
  ) into v_schema_exists;

  select exists (
    select 1
    from information_schema.tables t
    where t.table_schema = 'pods_provisioning'
      and t.table_name = 'template_registry_v1'
  ) into v_template_table_exists;

  select exists (
    select 1
    from information_schema.tables t
    where t.table_schema = 'pods_provisioning'
      and t.table_name = 'provision_runs_v1'
  ) into v_runs_table_exists;

  select exists (
    select 1
    from information_schema.tables t
    where t.table_schema = 'pods_provisioning'
      and t.table_name = 'seeded_objects_v1'
  ) into v_seeded_table_exists;

  select exists (
    select 1
    from information_schema.tables t
    where t.table_schema = 'pods_provisioning'
      and t.table_name = 'provisioning_receipts_v1'
  ) into v_receipts_table_exists;

  if not (
    v_schema_exists
    and v_template_table_exists
    and v_runs_table_exists
    and v_seeded_table_exists
    and v_receipts_table_exists
  ) then
    raise exception 'PROVISIONING_LANE_SELFTEST_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_TIER2_PROVISIONING_LANE_OK',
    'schema', 'pods_provisioning',
    'template_registry', v_template_table_exists,
    'provision_runs', v_runs_table_exists,
    'seeded_objects', v_seeded_table_exists,
    'provisioning_receipts', v_receipts_table_exists
  );
end
$$;

comment on function pods_provisioning.rpc_selftest_provisioning_lane_v1() is
'Selftest proving the Tier-2 provisioning lane substrate exists.';

commit;
