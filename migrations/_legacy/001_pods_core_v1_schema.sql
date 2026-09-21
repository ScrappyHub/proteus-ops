-- pods.core.v1 — schema + core tables
-- Supabase/Postgres
-- NOTE: keep all PODS core objects in schema "pods" to avoid pollution.

begin;

create schema if not exists pods;

-- Ensure minimal privileges: no public create in pods schema
revoke all on schema pods from public;

-- Optional: allow "authenticated" to use the schema (needed to call functions / access via RLS)
grant usage on schema pods to authenticated;
grant usage on schema pods to anon;

-- -------------------------------------------------------------------
-- ORGS + MEMBERSHIP
-- -------------------------------------------------------------------

create table if not exists pods.orgs (
  org_id      uuid primary key default gen_random_uuid(),
  slug        text not null unique,
  name        text not null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists pods.org_members (
  org_id      uuid not null references pods.orgs(org_id) on delete cascade,
  user_id     uuid not null,
  role_key    text not null,
  created_at  timestamptz not null default now(),
  primary key (org_id, user_id)
);

-- Canonical role set (locked)
create table if not exists pods.roles (
  role_key     text primary key,
  description  text not null
);

insert into pods.roles(role_key, description) values
  ('owner','Organization owner'),
  ('admin','Organization admin'),
  ('staff','Staff member'),
  ('customer','Customer'),
  ('system','System actor')
on conflict (role_key) do nothing;

-- Role -> capability permissions (model-controlled)
create table if not exists pods.role_permissions (
  role_key       text not null references pods.roles(role_key) on delete restrict,
  capability_key text not null,
  perm_read      boolean not null default false,
  perm_write     boolean not null default false,
  perm_delete    boolean not null default false,
  primary key (role_key, capability_key)
);

-- -------------------------------------------------------------------
-- BILLING MIRROR (Stripe) + PLANS + ENTITLEMENTS
-- -------------------------------------------------------------------

create table if not exists pods.billing_accounts (
  org_id               uuid primary key references pods.orgs(org_id) on delete cascade,
  provider             text not null default 'stripe',
  provider_customer_id text not null unique,
  billing_email        text null,
  status               text not null default 'inactive',
  updated_at           timestamptz not null default now()
);

create table if not exists pods.subscriptions (
  org_id                  uuid not null references pods.orgs(org_id) on delete cascade,
  provider_subscription_id text not null unique,
  status                  text not null,
  plan_id                 text not null,
  current_period_start    timestamptz null,
  current_period_end      timestamptz null,
  cancel_at_period_end    boolean not null default false,
  updated_at              timestamptz not null default now(),
  primary key (org_id, provider_subscription_id)
);

create table if not exists pods.plan_tiers (
  plan_id    text primary key,
  name       text not null,
  is_active  boolean not null default true
);

-- capability values are typed (bool|int|text)
create table if not exists pods.plan_capabilities (
  plan_id        text not null references pods.plan_tiers(plan_id) on delete cascade,
  capability_key text not null,
  value_type     text not null check (value_type in ('bool','int','text')),
  value_bool     boolean null,
  value_int      bigint null,
  value_text     text null,
  primary key (plan_id, capability_key)
);

create table if not exists pods.entitlement_overrides (
  org_id         uuid not null references pods.orgs(org_id) on delete cascade,
  capability_key text not null,
  value_type     text not null check (value_type in ('bool','int','text')),
  value_bool     boolean null,
  value_int      bigint null,
  value_text     text null,
  reason         text not null,
  expires_at     timestamptz null,
  created_at     timestamptz not null default now(),
  primary key (org_id, capability_key)
);

-- Materialized effective entitlements (enforcement surface)
create table if not exists pods.org_entitlements (
  org_id         uuid not null references pods.orgs(org_id) on delete cascade,
  capability_key text not null,
  value_type     text not null check (value_type in ('bool','int','text')),
  value_bool     boolean null,
  value_int      bigint null,
  value_text     text null,
  source         text not null check (source in ('plan','override','system')),
  computed_at    timestamptz not null default now(),
  primary key (org_id, capability_key)
);

-- Usage counters (plan limits)
create table if not exists pods.usage_counters (
  org_id       uuid not null references pods.orgs(org_id) on delete cascade,
  counter_key  text not null,
  period_start date not null,
  period_end   date not null,
  value        bigint not null default 0,
  updated_at   timestamptz not null default now(),
  primary key (org_id, counter_key, period_start)
);

-- -------------------------------------------------------------------
-- AUDIT LOG (append-only)
-- -------------------------------------------------------------------

create table if not exists pods.audit_log (
  audit_id       uuid primary key default gen_random_uuid(),
  org_id         uuid null,
  actor_user_id  uuid null,
  actor_role_key text null,
  action_key     text not null,
  entity_table   text null,
  entity_id      text null,
  details        jsonb not null default '{}'::jsonb,
  created_at     timestamptz not null default now()
);

-- -------------------------------------------------------------------
-- MODEL REGISTRY + MIGRATION LEDGER
-- -------------------------------------------------------------------

create table if not exists pods.models (
  model_id    text not null,
  version     text not null,
  depends_on  jsonb not null default '[]'::jsonb,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  primary key (model_id, version)
);

create table if not exists pods.org_models (
  org_id       uuid not null references pods.orgs(org_id) on delete cascade,
  model_id     text not null,
  version      text not null,
  installed_at timestamptz not null default now(),
  primary key (org_id, model_id)
);

create table if not exists pods.migration_ledger (
  org_id      uuid not null references pods.orgs(org_id) on delete cascade,
  model_id    text not null,
  version     text not null,
  migration_id text not null,
  applied_at  timestamptz not null default now(),
  applied_by  text not null default 'system',
  primary key (org_id, model_id, version, migration_id)
);

commit;