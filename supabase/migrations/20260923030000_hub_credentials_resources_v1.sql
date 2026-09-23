-- ProteusOps slice H2 — credentials (Vault-backed references) + resource inventory (docs/proposals/WORKSPACE_HUB_v1.md)
-- Credentials: ProteusOps tables hold METADATA ONLY (purpose, environment, scopes, rotation, status, a short
-- non-reversible fingerprint). Secret values live in Supabase Vault (encrypted at rest), readable only by
-- service_role through an audited function. Clients can write a value (over TLS) but can never read one back.
-- Every credential change requires owner/admin + MFA (aal2) and a justification; every read by a service is audited.
-- Resources: what each account controls (repos, DNS zones, deployments, SES identities, ...), attachable to projects,
-- manually or by service-side discovery (H3 adapters). Attributes may not carry secret-looking keys.
-- Launch gate: 'credentials_valid_live' is now evaluated for real (was fail-closed placeholder).

-- ---------- credentials ----------
create table if not exists pods_provisioning.hub_credentials_v1 (
  credential_id uuid primary key default gen_random_uuid(),
  org_id uuid not null references pods.orgs(org_id) on delete cascade,
  account_id uuid not null references pods_provisioning.hub_accounts_v1(account_id) on delete cascade,
  project_id uuid references pods_provisioning.hub_projects_v1(project_id) on delete set null,
  purpose text not null check (purpose ~ '^[a-z][a-z0-9_.-]{1,63}$'),
  environment text not null check (environment in ('test','live')),
  scopes jsonb not null default '[]'::jsonb check (jsonb_typeof(scopes) = 'array' and length(scopes::text) <= 4000),
  storage_kind text not null check (storage_kind in ('vault','operator_env','provider_oauth')),
  vault_secret_id uuid,
  external_handle text check (external_handle is null or external_handle ~ '^[A-Za-z0-9_./:-]{1,200}$'),
  fingerprint text,
  status text not null default 'pending_verification' check (status in ('pending_verification','valid','invalid','revoked')),
  status_detail text check (status_detail is null or length(status_detail) <= 1000),
  rotates_at timestamptz,
  last_rotated_at timestamptz,
  last_verified_at timestamptz,
  justification text not null check (length(btrim(justification)) between 10 and 4000),
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint hub_credential_storage_ck check (
    (storage_kind = 'vault' and vault_secret_id is not null) or
    (storage_kind = 'operator_env' and vault_secret_id is null and external_handle is not null) or
    (storage_kind = 'provider_oauth' and vault_secret_id is not null) or
    status = 'revoked'),
  constraint hub_credential_live_rotation_ck check (environment <> 'live' or rotates_at is not null or status = 'revoked')
);
create index if not exists hub_credentials_v1_account_idx on pods_provisioning.hub_credentials_v1(account_id);
create index if not exists hub_credentials_v1_project_idx on pods_provisioning.hub_credentials_v1(project_id);
create unique index if not exists hub_credentials_v1_active_uq on pods_provisioning.hub_credentials_v1
  (account_id, purpose, environment, coalesce(project_id::text,'-')) where status <> 'revoked';

create or replace function pods_provisioning._hub_credential_org_guard_v1()
returns trigger language plpgsql security definer set search_path = pods_provisioning, public as $fn$
declare v_a uuid; v_p uuid;
begin
  select org_id into v_a from pods_provisioning.hub_accounts_v1 where account_id = new.account_id;
  if v_a is distinct from new.org_id then raise exception 'HUB_CROSS_WORKSPACE_LINK' using errcode = '42501'; end if;
  if new.project_id is not null then
    select org_id into v_p from pods_provisioning.hub_projects_v1 where project_id = new.project_id;
    if v_p is distinct from new.org_id then raise exception 'HUB_CROSS_WORKSPACE_LINK' using errcode = '42501'; end if;
  end if;
  return new;
end $fn$;
drop trigger if exists hub_credentials_org_guard on pods_provisioning.hub_credentials_v1;
create trigger hub_credentials_org_guard before insert or update on pods_provisioning.hub_credentials_v1
  for each row execute function pods_provisioning._hub_credential_org_guard_v1();

-- a deleted credential row (incl. org/account cascade) never leaves an orphaned Vault secret
create or replace function pods_provisioning._hub_credential_vault_cleanup_v1()
returns trigger language plpgsql security definer set search_path = pods_provisioning, vault, public as $fn$
begin
  if old.vault_secret_id is not null then delete from vault.secrets where id = old.vault_secret_id; end if;
  return old;
end $fn$;
drop trigger if exists hub_credentials_vault_cleanup on pods_provisioning.hub_credentials_v1;
create trigger hub_credentials_vault_cleanup after delete on pods_provisioning.hub_credentials_v1
  for each row execute function pods_provisioning._hub_credential_vault_cleanup_v1();

-- ---------- resources ----------
create table if not exists pods_provisioning.hub_resources_v1 (
  resource_id uuid primary key default gen_random_uuid(),
  org_id uuid not null references pods.orgs(org_id) on delete cascade,
  account_id uuid not null references pods_provisioning.hub_accounts_v1(account_id) on delete cascade,
  project_id uuid references pods_provisioning.hub_projects_v1(project_id) on delete set null,
  kind text not null check (kind in ('repo','branch','dns_zone','dns_record','domain','deployment','environment','database',
    'edge_function','bucket','ses_identity','email_domain','compute_instance','figma_file','osf_project','webhook','other')),
  external_id text not null check (length(btrim(external_id)) between 1 and 400),
  display_name text not null check (length(btrim(display_name)) between 1 and 200),
  environment text not null default 'shared' check (environment in ('test','live','shared')),
  status text not null default 'active' check (status in ('active','missing','archived')),
  source text not null default 'manual' check (source in ('manual','discovery')),
  attributes jsonb not null default '{}'::jsonb check (jsonb_typeof(attributes) = 'object' and length(attributes::text) <= 16384),
  notes text not null default '' check (length(notes) <= 4000),
  last_seen_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (account_id, kind, external_id)
);
create index if not exists hub_resources_v1_org_idx on pods_provisioning.hub_resources_v1(org_id);
create index if not exists hub_resources_v1_project_idx on pods_provisioning.hub_resources_v1(project_id);

create or replace function pods_provisioning._hub_attrs_have_secret_keys_v1(p jsonb)
returns boolean language sql immutable set search_path = pg_catalog as $fn$
  select coalesce(p::text, '') ~* '"[^"]*(secret|token|passw|private[_-]?key|api[_-]?key|apikey|credential|bearer|session[_-]?id)[^"]*"\s*:' $fn$;

create or replace function pods_provisioning._hub_resource_guard_v1()
returns trigger language plpgsql security definer set search_path = pods_provisioning, public as $fn$
declare v_a uuid; v_p uuid;
begin
  if pods_provisioning._hub_attrs_have_secret_keys_v1(new.attributes) then
    raise exception 'HUB_RESOURCE_ATTRIBUTES_LOOK_SECRET';
  end if;
  select org_id into v_a from pods_provisioning.hub_accounts_v1 where account_id = new.account_id;
  if v_a is distinct from new.org_id then raise exception 'HUB_CROSS_WORKSPACE_LINK' using errcode = '42501'; end if;
  if new.project_id is not null then
    select org_id into v_p from pods_provisioning.hub_projects_v1 where project_id = new.project_id;
    if v_p is distinct from new.org_id then raise exception 'HUB_CROSS_WORKSPACE_LINK' using errcode = '42501'; end if;
  end if;
  return new;
end $fn$;
drop trigger if exists hub_resources_guard on pods_provisioning.hub_resources_v1;
create trigger hub_resources_guard before insert or update on pods_provisioning.hub_resources_v1
  for each row execute function pods_provisioning._hub_resource_guard_v1();

alter table pods_provisioning.hub_credentials_v1 enable row level security;
alter table pods_provisioning.hub_resources_v1   enable row level security;
revoke all on pods_provisioning.hub_credentials_v1, pods_provisioning.hub_resources_v1 from anon, authenticated;

-- ---------- helpers ----------
create or replace function pods_provisioning._hub_fingerprint_v1(p_value text)
returns text language sql immutable set search_path = pg_catalog as $fn$
  select 'sha256:' || left(encode(extensions.digest(p_value, 'sha256'), 'hex'), 8) $fn$;

create or replace function pods_provisioning._hub_credential_effective_status_v1(c pods_provisioning.hub_credentials_v1)
returns text language sql stable set search_path = pg_catalog as $fn$
  select case
    when c.status in ('revoked','invalid') then c.status
    when c.rotates_at is not null and c.rotates_at <= now() then 'expired'
    when c.status = 'pending_verification' then 'pending_verification'
    when c.last_verified_at is null or c.last_verified_at < now() - interval '30 days' then 'stale'
    when c.rotates_at is not null and c.rotates_at <= now() + interval '14 days' then 'expiring'
    else 'valid' end $fn$;

create or replace function pods_provisioning._hub_check_env_v1(p_account_env text, p_cred_env text)
returns void language plpgsql immutable set search_path = pg_catalog as $fn$
begin
  if p_account_env <> 'shared' and p_account_env <> p_cred_env then raise exception 'HUB_CREDENTIAL_ENV_MISMATCH'; end if;
end $fn$;

create or replace function pods_provisioning._hub_check_rotation_v1(p_env text, p_rotates_at timestamptz)
returns void language plpgsql stable set search_path = pg_catalog as $fn$
begin
  if p_env = 'live' and p_rotates_at is null then raise exception 'HUB_ROTATION_REQUIRED'; end if;
  if p_rotates_at is not null and (p_rotates_at <= now() or p_rotates_at > now() + interval '400 days') then
    raise exception 'HUB_ROTATION_OUT_OF_RANGE';
  end if;
end $fn$;

-- ---------- credential RPCs (clients) ----------
create or replace function pods_provisioning.rpc_hub_credential_put_v1(
  p_account_id uuid, p_project_id uuid, p_purpose text, p_environment text, p_scopes jsonb,
  p_storage_kind text, p_secret_value text, p_external_handle text, p_rotates_at timestamptz, p_justification text)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare a pods_provisioning.hub_accounts_v1%rowtype; v_role text; v_id uuid := gen_random_uuid(); v_vault uuid; v_fp text;
begin
  select * into a from pods_provisioning.hub_accounts_v1 where account_id = p_account_id;
  if not found then raise exception 'HUB_ACCOUNT_NOT_FOUND'; end if;
  v_role := pods_provisioning._hub_authorize_v1(a.org_id, array['owner','admin']);
  perform pods_core.require_aal2();
  if a.status <> 'active' then raise exception 'HUB_ACCOUNT_ARCHIVED'; end if;
  perform pods_provisioning._hub_require_justification_v1(p_justification);
  perform pods_provisioning._hub_check_env_v1(a.environment, p_environment);
  perform pods_provisioning._hub_check_rotation_v1(p_environment, p_rotates_at);
  if p_storage_kind = 'vault' then
    if p_secret_value is null or length(p_secret_value) not between 8 and 16384 then raise exception 'HUB_SECRET_VALUE_INVALID'; end if;
    v_vault := vault.create_secret(p_secret_value, 'proteus/cred/'||v_id::text, 'ProteusOps credential '||v_id::text);
    v_fp := pods_provisioning._hub_fingerprint_v1(p_secret_value);
  elsif p_storage_kind = 'operator_env' then
    if p_secret_value is not null then raise exception 'HUB_SECRET_VALUE_NOT_ALLOWED'; end if;
    if p_external_handle is null then raise exception 'HUB_EXTERNAL_HANDLE_REQUIRED'; end if;
  else
    raise exception 'HUB_STORAGE_KIND_NOT_ALLOWED';   -- provider_oauth is written only by service adapters
  end if;
  insert into pods_provisioning.hub_credentials_v1(credential_id, org_id, account_id, project_id, purpose, environment, scopes,
    storage_kind, vault_secret_id, external_handle, fingerprint, rotates_at, last_rotated_at, justification, created_by)
  values (v_id, a.org_id, p_account_id, p_project_id, lower(p_purpose), p_environment, coalesce(p_scopes,'[]'::jsonb),
    p_storage_kind, v_vault, p_external_handle, v_fp, p_rotates_at, now(), btrim(p_justification), auth.uid());
  perform pods_provisioning._hub_audit_v1(a.org_id, v_role, 'hub.credential_put', 'hub_credentials_v1', v_id::text,
    jsonb_build_object('account_id', p_account_id, 'project_id', p_project_id, 'purpose', lower(p_purpose),
      'environment', p_environment, 'storage', p_storage_kind, 'fingerprint', v_fp, 'justification', btrim(p_justification)));
  return jsonb_build_object('credential_id', v_id, 'fingerprint', v_fp, 'status', 'pending_verification');
end $fn$;

create or replace function pods_provisioning.rpc_hub_credential_rotate_v1(
  p_credential_id uuid, p_secret_value text, p_rotates_at timestamptz, p_reason text)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare c pods_provisioning.hub_credentials_v1%rowtype; v_role text; v_fp text;
begin
  select * into c from pods_provisioning.hub_credentials_v1 where credential_id = p_credential_id for update;
  if not found then raise exception 'HUB_CREDENTIAL_NOT_FOUND'; end if;
  v_role := pods_provisioning._hub_authorize_v1(c.org_id, array['owner','admin']);
  perform pods_core.require_aal2();
  if c.status = 'revoked' then raise exception 'HUB_CREDENTIAL_REVOKED'; end if;
  perform pods_provisioning._hub_require_justification_v1(p_reason);
  perform pods_provisioning._hub_check_rotation_v1(c.environment, p_rotates_at);
  if c.storage_kind = 'vault' then
    if p_secret_value is null or length(p_secret_value) not between 8 and 16384 then raise exception 'HUB_SECRET_VALUE_INVALID'; end if;
    perform vault.update_secret(c.vault_secret_id, p_secret_value);
    v_fp := pods_provisioning._hub_fingerprint_v1(p_secret_value);
    if v_fp = c.fingerprint then raise exception 'HUB_ROTATION_SAME_VALUE'; end if;
  elsif p_secret_value is not null then
    raise exception 'HUB_SECRET_VALUE_NOT_ALLOWED';
  end if;
  update pods_provisioning.hub_credentials_v1 set fingerprint = coalesce(v_fp, fingerprint), rotates_at = p_rotates_at,
    last_rotated_at = now(), status = 'pending_verification', status_detail = null, updated_at = now()
   where credential_id = p_credential_id;
  perform pods_provisioning._hub_audit_v1(c.org_id, v_role, 'hub.credential_rotate', 'hub_credentials_v1', p_credential_id::text,
    jsonb_build_object('fingerprint_old', c.fingerprint, 'fingerprint_new', v_fp, 'rotates_at', p_rotates_at, 'reason', btrim(p_reason)));
  return jsonb_build_object('credential_id', p_credential_id, 'fingerprint', coalesce(v_fp, c.fingerprint), 'status', 'pending_verification');
end $fn$;

create or replace function pods_provisioning.rpc_hub_credential_revoke_v1(p_credential_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare c pods_provisioning.hub_credentials_v1%rowtype; v_role text;
begin
  select * into c from pods_provisioning.hub_credentials_v1 where credential_id = p_credential_id for update;
  if not found then raise exception 'HUB_CREDENTIAL_NOT_FOUND'; end if;
  v_role := pods_provisioning._hub_authorize_v1(c.org_id, array['owner','admin']);
  perform pods_core.require_aal2();
  perform pods_provisioning._hub_require_justification_v1(p_reason);
  if c.status = 'revoked' then return jsonb_build_object('credential_id', p_credential_id, 'status', 'revoked', 'already', true); end if;
  update pods_provisioning.hub_credentials_v1 set status = 'revoked', status_detail = btrim(p_reason), vault_secret_id = null,
    updated_at = now() where credential_id = p_credential_id;
  if c.vault_secret_id is not null then delete from vault.secrets where id = c.vault_secret_id; end if;
  perform pods_provisioning._hub_audit_v1(c.org_id, v_role, 'hub.credential_revoke', 'hub_credentials_v1', p_credential_id::text,
    jsonb_build_object('fingerprint', c.fingerprint, 'reason', btrim(p_reason), 'secret_destroyed', c.vault_secret_id is not null));
  return jsonb_build_object('credential_id', p_credential_id, 'status', 'revoked');
end $fn$;

create or replace function pods_provisioning.rpc_hub_credentials_list_v1(p_org_id uuid, p_project_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = pods_provisioning, pods, public as $fn$
begin
  perform pods_provisioning._hub_authorize_v1(p_org_id, array['owner','admin','staff']);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'credential_id', c.credential_id, 'account_id', c.account_id, 'provider', a.provider_key, 'account_name', a.display_name,
      'project_id', c.project_id, 'purpose', c.purpose, 'environment', c.environment, 'scopes', c.scopes,
      'storage', c.storage_kind, 'external_handle', c.external_handle, 'fingerprint', c.fingerprint,
      'status', pods_provisioning._hub_credential_effective_status_v1(c), 'status_detail', c.status_detail,
      'rotates_at', c.rotates_at, 'last_rotated_at', c.last_rotated_at, 'last_verified_at', c.last_verified_at,
      'justification', c.justification) order by a.provider_key, c.purpose, c.environment)
    from pods_provisioning.hub_credentials_v1 c join pods_provisioning.hub_accounts_v1 a on a.account_id = c.account_id
   where c.org_id = p_org_id and (p_project_id is null or c.project_id = p_project_id or c.project_id is null)), '[]'::jsonb);
end $fn$;

-- ---------- service-only credential functions (edge functions / adapters) ----------
create or replace function pods_provisioning.svc_hub_credential_secret_v1(p_credential_id uuid, p_purpose_of_use text)
returns text language plpgsql security definer set search_path = pods_provisioning, pods, vault, public as $fn$
declare c pods_provisioning.hub_credentials_v1%rowtype; v text;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'HUB_SECRET_READ_FORBIDDEN' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_purpose_of_use,''))) < 3 then raise exception 'HUB_PURPOSE_OF_USE_REQUIRED'; end if;
  select * into c from pods_provisioning.hub_credentials_v1 where credential_id = p_credential_id;
  if not found or c.status in ('revoked','invalid') or c.vault_secret_id is null then raise exception 'HUB_CREDENTIAL_UNAVAILABLE'; end if;
  if c.rotates_at is not null and c.rotates_at <= now() then raise exception 'HUB_CREDENTIAL_EXPIRED'; end if;
  select decrypted_secret into v from vault.decrypted_secrets where id = c.vault_secret_id;
  insert into pods.audit_log(org_id, actor_role_key, action_key, entity_table, entity_id, details)
  values (c.org_id, 'service', 'hub.credential_read', 'hub_credentials_v1', p_credential_id::text,
          jsonb_build_object('purpose_of_use', btrim(p_purpose_of_use), 'fingerprint', c.fingerprint));
  return v;
end $fn$;

create or replace function pods_provisioning.svc_hub_credential_mark_verified_v1(p_credential_id uuid, p_ok boolean, p_detail text)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare c pods_provisioning.hub_credentials_v1%rowtype;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'HUB_VERIFY_FORBIDDEN' using errcode = '42501'; end if;
  select * into c from pods_provisioning.hub_credentials_v1 where credential_id = p_credential_id for update;
  if not found or c.status = 'revoked' then raise exception 'HUB_CREDENTIAL_UNAVAILABLE'; end if;
  update pods_provisioning.hub_credentials_v1 set status = case when p_ok then 'valid' else 'invalid' end,
    status_detail = left(p_detail, 1000), last_verified_at = now(), updated_at = now() where credential_id = p_credential_id;
  insert into pods.audit_log(org_id, actor_role_key, action_key, entity_table, entity_id, details)
  values (c.org_id, 'service', case when p_ok then 'hub.credential_verified' else 'hub.credential_invalid' end,
          'hub_credentials_v1', p_credential_id::text, jsonb_build_object('detail', left(p_detail, 1000)));
  return jsonb_build_object('credential_id', p_credential_id, 'status', case when p_ok then 'valid' else 'invalid' end);
end $fn$;

-- ---------- resource RPCs ----------
create or replace function pods_provisioning.rpc_hub_resource_upsert_v1(
  p_resource_id uuid, p_account_id uuid, p_project_id uuid, p_kind text, p_external_id text, p_display_name text,
  p_environment text, p_attributes jsonb, p_notes text)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare a pods_provisioning.hub_accounts_v1%rowtype; v_role text; v_id uuid; v_env text; v_old_env text;
begin
  select * into a from pods_provisioning.hub_accounts_v1 where account_id = p_account_id;
  if not found then raise exception 'HUB_ACCOUNT_NOT_FOUND'; end if;
  v_role := pods_provisioning._hub_authorize_v1(a.org_id, array['owner','admin']);
  v_env := coalesce(p_environment, a.environment);
  if p_resource_id is not null then
    select environment into v_old_env from pods_provisioning.hub_resources_v1 where resource_id = p_resource_id and org_id = a.org_id for update;
    if v_old_env is null then raise exception 'HUB_RESOURCE_NOT_FOUND'; end if;
  end if;
  if v_env = 'live' or v_old_env = 'live' or a.environment = 'live'
     or (p_project_id is not null and pods_provisioning._hub_is_protected_project_v1(p_project_id)) then
    perform pods_core.require_aal2();
  end if;
  if p_resource_id is null then
    insert into pods_provisioning.hub_resources_v1(org_id, account_id, project_id, kind, external_id, display_name, environment,
      attributes, notes, source, last_seen_at, created_by)
    values (a.org_id, p_account_id, p_project_id, p_kind, btrim(p_external_id), btrim(p_display_name), v_env,
      coalesce(p_attributes,'{}'::jsonb), coalesce(p_notes,''), 'manual', now(), auth.uid())
    returning resource_id into v_id;
  else
    update pods_provisioning.hub_resources_v1 set account_id = p_account_id, project_id = p_project_id, kind = p_kind,
      external_id = btrim(p_external_id), display_name = btrim(p_display_name), environment = v_env,
      attributes = coalesce(p_attributes,'{}'::jsonb), notes = coalesce(p_notes,''), status = 'active', updated_at = now()
     where resource_id = p_resource_id returning resource_id into v_id;
  end if;
  perform pods_provisioning._hub_audit_v1(a.org_id, v_role, 'hub.resource_upsert', 'hub_resources_v1', v_id::text,
    jsonb_build_object('kind', p_kind, 'external_id', btrim(p_external_id), 'environment', v_env, 'project_id', p_project_id));
  return jsonb_build_object('resource_id', v_id);
end $fn$;

create or replace function pods_provisioning.rpc_hub_resource_archive_v1(p_resource_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare r pods_provisioning.hub_resources_v1%rowtype; v_role text;
begin
  select * into r from pods_provisioning.hub_resources_v1 where resource_id = p_resource_id for update;
  if not found then raise exception 'HUB_RESOURCE_NOT_FOUND'; end if;
  v_role := pods_provisioning._hub_authorize_v1(r.org_id, array['owner','admin']);
  if r.environment = 'live' or (r.project_id is not null and pods_provisioning._hub_is_protected_project_v1(r.project_id)) then
    perform pods_core.require_aal2();
  end if;
  perform pods_provisioning._hub_require_justification_v1(p_reason);
  update pods_provisioning.hub_resources_v1 set status = 'archived', updated_at = now() where resource_id = p_resource_id;
  perform pods_provisioning._hub_audit_v1(r.org_id, v_role, 'hub.resource_archive', 'hub_resources_v1', p_resource_id::text,
    jsonb_build_object('reason', btrim(p_reason)));
  return jsonb_build_object('resource_id', p_resource_id, 'status', 'archived');
end $fn$;

create or replace function pods_provisioning.rpc_hub_resources_list_v1(p_org_id uuid, p_project_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = pods_provisioning, pods, public as $fn$
begin
  perform pods_provisioning._hub_authorize_v1(p_org_id, array['owner','admin','staff']);
  return coalesce((select jsonb_agg(jsonb_build_object('resource_id', r.resource_id, 'account_id', r.account_id,
      'provider', a.provider_key, 'project_id', r.project_id, 'kind', r.kind, 'external_id', r.external_id,
      'name', r.display_name, 'environment', r.environment, 'status', r.status, 'source', r.source,
      'attributes', r.attributes, 'notes', r.notes, 'last_seen_at', r.last_seen_at) order by a.provider_key, r.kind, r.display_name)
    from pods_provisioning.hub_resources_v1 r join pods_provisioning.hub_accounts_v1 a on a.account_id = r.account_id
   where r.org_id = p_org_id and (p_project_id is null or r.project_id = p_project_id)), '[]'::jsonb);
end $fn$;

-- discovery sync (service only): upsert what the provider reports; discovered rows not reported become 'missing'
create or replace function pods_provisioning.svc_hub_resource_sync_v1(p_account_id uuid, p_items jsonb)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare a pods_provisioning.hub_accounts_v1%rowtype; it jsonb; v_seen text[] := '{}'; v_up int := 0; v_missing int := 0;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'HUB_SYNC_FORBIDDEN' using errcode = '42501'; end if;
  select * into a from pods_provisioning.hub_accounts_v1 where account_id = p_account_id;
  if not found or a.status <> 'active' then raise exception 'HUB_ACCOUNT_NOT_FOUND'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 5000 then raise exception 'HUB_SYNC_INVALID'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    insert into pods_provisioning.hub_resources_v1(org_id, account_id, kind, external_id, display_name, environment, attributes, source, last_seen_at)
    values (a.org_id, p_account_id, it->>'kind', it->>'external_id', coalesce(it->>'display_name', it->>'external_id'),
            coalesce(it->>'environment', a.environment), coalesce(it->'attributes','{}'::jsonb), 'discovery', now())
    on conflict (account_id, kind, external_id) do update set display_name = excluded.display_name,
      attributes = excluded.attributes, last_seen_at = now(), updated_at = now(),
      status = case when pods_provisioning.hub_resources_v1.status = 'archived' then 'archived' else 'active' end;
    v_seen := v_seen || ((it->>'kind')||'|'||(it->>'external_id'));
    v_up := v_up + 1;
  end loop;
  update pods_provisioning.hub_resources_v1 set status = 'missing', updated_at = now()
   where account_id = p_account_id and source = 'discovery' and status = 'active' and not ((kind||'|'||external_id) = any(v_seen));
  get diagnostics v_missing = row_count;
  insert into pods.audit_log(org_id, actor_role_key, action_key, entity_table, entity_id, details)
  values (a.org_id, 'service', 'hub.resource_sync', 'hub_accounts_v1', p_account_id::text,
          jsonb_build_object('reported', v_up, 'marked_missing', v_missing));
  return jsonb_build_object('reported', v_up, 'marked_missing', v_missing);
end $fn$;

-- ---------- launch gate evaluator: credentials_valid_live now real ----------
create or replace function pods_provisioning._hub_eval_requirement_v1(p_project_id uuid, p_requirement_key text, p_reason text)
returns jsonb language plpgsql stable security definer set search_path = pods_provisioning, pods, public as $fn$
declare p pods_provisioning.hub_projects_v1%rowtype; v_ok boolean := false; v_detail text; v_n int; v_m int; v_bad int;
begin
  select * into p from pods_provisioning.hub_projects_v1 where project_id = p_project_id;
  case p_requirement_key
    when 'source_linked' then
      if p.origin = 'imported' then v_ok := true; v_detail := 'imported project';
      else
        select count(*) into v_n from pods_provisioning.model_instance_runtimes_v1
         where model_instance_runtime_id = p.model_instance_runtime_id and org_id = p.org_id and instance_status <> 'blocked';
        v_ok := v_n = 1; v_detail := case when v_ok then 'model instance linked' else 'model instance missing, blocked, or in another workspace' end;
      end if;
    when 'providers_ready' then
      select coalesce((select launch_ready from pods_provisioning.provider_readiness_rollups_v1
                        where org_id = p.org_id order by created_at desc limit 1), false) into v_ok;
      v_detail := case when v_ok then 'latest readiness roll-up is launch_ready' else 'no launch_ready provider roll-up for this workspace' end;
    when 'workspace_paid' then
      v_ok := coalesce(pods.has_cap_bool(p.org_id, 'paid_active'), false);
      v_detail := case when v_ok then 'paid_active' else 'workspace has no active paid subscription' end;
    when 'owners_mfa_enrolled' then
      select count(*), count(*) filter (where exists (
               select 1 from auth.mfa_factors f where f.user_id = m.user_id and f.status = 'verified'))
        into v_n, v_m from pods.org_members m where m.org_id = p.org_id and m.role_key = 'owner';
      v_ok := v_n > 0 and v_m = v_n;
      v_detail := format('%s of %s owners have verified MFA', v_m, v_n);
    when 'reason_recorded' then
      v_ok := length(btrim(coalesce(p_reason,''))) >= 3;
      v_detail := case when v_ok then 'reason recorded' else 'a reason is required' end;
    when 'no_active_children' then
      select count(*) into v_n from pods_provisioning.hub_projects_v1 where parent_project_id = p_project_id and current_stage <> 'archived';
      v_ok := v_n = 0;
      v_detail := format('%s child node(s) not archived', v_n);
    when 'credentials_valid_live' then
      -- every LIVE account this project uses must have >= 1 valid, verified (<=30d), unexpired live credential
      -- scoped to this project or account-wide; and no live credential scoped to this project may be invalid/expired.
      select count(*),
             count(*) filter (where not exists (
               select 1 from pods_provisioning.hub_credentials_v1 c
                where c.account_id = a.account_id and c.environment = 'live'
                  and (c.project_id is null or c.project_id = p_project_id)
                  and pods_provisioning._hub_credential_effective_status_v1(c) in ('valid','expiring')))
        into v_n, v_m
        from (select distinct pa.account_id from pods_provisioning.hub_project_accounts_v1 pa
                join pods_provisioning.hub_accounts_v1 ac on ac.account_id = pa.account_id
               where pa.project_id = p_project_id and ac.environment = 'live' and ac.status = 'active') a;
      select count(*) into v_bad from pods_provisioning.hub_credentials_v1 c
       where c.project_id = p_project_id and c.environment = 'live'
         and pods_provisioning._hub_credential_effective_status_v1(c) in ('invalid','expired');
      v_ok := v_n > 0 and v_m = 0 and v_bad = 0;
      v_detail := case when v_n = 0 then 'no live account linked to this project'
                       else format('%s of %s live accounts lack a valid verified credential; %s invalid/expired project credentials', v_m, v_n, v_bad) end;
    else
      v_ok := false; v_detail := 'not yet verifiable (evaluator pending) - fails closed';
  end case;
  return jsonb_build_object('key', p_requirement_key, 'ok', v_ok, 'detail', v_detail);
end $fn$;

-- ---------- grants + public wrappers ----------
do $$ declare s text; begin
  foreach s in array array[
    'pods_provisioning._hub_credential_org_guard_v1()', 'pods_provisioning._hub_credential_vault_cleanup_v1()',
    'pods_provisioning._hub_attrs_have_secret_keys_v1(jsonb)', 'pods_provisioning._hub_resource_guard_v1()',
    'pods_provisioning._hub_fingerprint_v1(text)', 'pods_provisioning._hub_credential_effective_status_v1(pods_provisioning.hub_credentials_v1)',
    'pods_provisioning._hub_check_env_v1(text,text)', 'pods_provisioning._hub_check_rotation_v1(text,timestamp with time zone)',
    'pods_provisioning.rpc_hub_credential_put_v1(uuid,uuid,text,text,jsonb,text,text,text,timestamp with time zone,text)',
    'pods_provisioning.rpc_hub_credential_rotate_v1(uuid,text,timestamp with time zone,text)',
    'pods_provisioning.rpc_hub_credential_revoke_v1(uuid,text)', 'pods_provisioning.rpc_hub_credentials_list_v1(uuid,uuid)',
    'pods_provisioning.svc_hub_credential_secret_v1(uuid,text)', 'pods_provisioning.svc_hub_credential_mark_verified_v1(uuid,boolean,text)',
    'pods_provisioning.rpc_hub_resource_upsert_v1(uuid,uuid,uuid,text,text,text,text,jsonb,text)',
    'pods_provisioning.rpc_hub_resource_archive_v1(uuid,text)', 'pods_provisioning.rpc_hub_resources_list_v1(uuid,uuid)',
    'pods_provisioning.svc_hub_resource_sync_v1(uuid,jsonb)', 'pods_provisioning._hub_eval_requirement_v1(uuid,text,text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', s);
    execute format('grant execute on function %s to service_role', s);
  end loop;
end $$;

create or replace function public.rpc_hub_credential_put_v1(p_account_id uuid, p_project_id uuid, p_purpose text, p_environment text,
  p_scopes jsonb, p_storage_kind text, p_secret_value text, p_external_handle text, p_rotates_at timestamptz, p_justification text)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_credential_put_v1(p_account_id, p_project_id, p_purpose, p_environment, p_scopes,
    p_storage_kind, p_secret_value, p_external_handle, p_rotates_at, p_justification) $fn$;
create or replace function public.rpc_hub_credential_rotate_v1(p_credential_id uuid, p_secret_value text, p_rotates_at timestamptz, p_reason text)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_credential_rotate_v1(p_credential_id, p_secret_value, p_rotates_at, p_reason) $fn$;
create or replace function public.rpc_hub_credential_revoke_v1(p_credential_id uuid, p_reason text)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_credential_revoke_v1(p_credential_id, p_reason) $fn$;
create or replace function public.rpc_hub_credentials_list_v1(p_org_id uuid, p_project_id uuid default null)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_credentials_list_v1(p_org_id, p_project_id) $fn$;
create or replace function public.rpc_hub_resource_upsert_v1(p_resource_id uuid, p_account_id uuid, p_project_id uuid, p_kind text,
  p_external_id text, p_display_name text, p_environment text, p_attributes jsonb, p_notes text)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_resource_upsert_v1(p_resource_id, p_account_id, p_project_id, p_kind, p_external_id,
    p_display_name, p_environment, p_attributes, p_notes) $fn$;
create or replace function public.rpc_hub_resource_archive_v1(p_resource_id uuid, p_reason text)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_resource_archive_v1(p_resource_id, p_reason) $fn$;
create or replace function public.rpc_hub_resources_list_v1(p_org_id uuid, p_project_id uuid default null)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_resources_list_v1(p_org_id, p_project_id) $fn$;
-- service-only wrappers (edge functions call supabase.rpc with the service role key)
create or replace function public.svc_hub_credential_secret_v1(p_credential_id uuid, p_purpose_of_use text)
returns text language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.svc_hub_credential_secret_v1(p_credential_id, p_purpose_of_use) $fn$;
create or replace function public.svc_hub_credential_mark_verified_v1(p_credential_id uuid, p_ok boolean, p_detail text)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.svc_hub_credential_mark_verified_v1(p_credential_id, p_ok, p_detail) $fn$;
create or replace function public.svc_hub_resource_sync_v1(p_account_id uuid, p_items jsonb)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.svc_hub_resource_sync_v1(p_account_id, p_items) $fn$;
do $$ declare s text; begin
  foreach s in array array['public.svc_hub_credential_secret_v1(uuid,text)', 'public.svc_hub_credential_mark_verified_v1(uuid,boolean,text)',
                           'public.svc_hub_resource_sync_v1(uuid,jsonb)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', s);
    execute format('grant execute on function %s to service_role', s);
  end loop;
end $$;

create or replace function pods_core.api_client_allowlist_v1()
returns text[] language sql immutable set search_path = pods_core, public as $fn$
  select array[
    'public.rpc_create_org_bootstrap(text,text,text)',
    'public.rpc_create_appointment_v1(uuid,uuid,timestamp with time zone,timestamp with time zone,uuid,uuid,text,text,text,text)',
    'public.rpc_add_time_off_block_v1(uuid,uuid,timestamp with time zone,timestamp with time zone,text)',
    'public.rpc_delete_availability_rule_v1(uuid,uuid)',
    'public.rpc_upsert_availability_rule_v1(uuid,uuid,uuid,uuid,integer,time without time zone,time without time zone,boolean)',
    'public.rpc_selftest_reset_booking_v1(uuid,uuid)',
    'public.rpc_hub_project_create_v1(uuid,text,text,text,uuid)',
    'public.rpc_hub_projects_list_v1(uuid)',
    'public.rpc_hub_evaluate_gate_v1(uuid,text,text)',
    'public.rpc_hub_transition_v1(uuid,text,text)',
    'public.rpc_hub_node_create_v2(uuid,text,text,text,uuid,uuid,text,text)',
    'public.rpc_hub_node_move_v1(uuid,uuid)',
    'public.rpc_hub_tree_v1(uuid)',
    'public.rpc_hub_account_upsert_v1(uuid,uuid,text,text,text,text,uuid,text)',
    'public.rpc_hub_account_archive_v1(uuid,text)',
    'public.rpc_hub_accounts_list_v1(uuid)',
    'public.rpc_hub_project_account_link_v1(uuid,uuid,text,text)',
    'public.rpc_hub_project_account_unlink_v1(uuid,uuid,text,text)',
    'public.rpc_hub_dependency_upsert_v1(uuid,uuid,text,uuid,uuid,text,text,text,text,uuid,date)',
    'public.rpc_hub_dependency_retire_v1(uuid,text)',
    'public.rpc_hub_dependencies_v1(uuid,boolean)',
    'public.rpc_hub_credential_put_v1(uuid,uuid,text,text,jsonb,text,text,text,timestamp with time zone,text)',
    'public.rpc_hub_credential_rotate_v1(uuid,text,timestamp with time zone,text)',
    'public.rpc_hub_credential_revoke_v1(uuid,text)',
    'public.rpc_hub_credentials_list_v1(uuid,uuid)',
    'public.rpc_hub_resource_upsert_v1(uuid,uuid,uuid,text,text,text,text,jsonb,text)',
    'public.rpc_hub_resource_archive_v1(uuid,text)',
    'public.rpc_hub_resources_list_v1(uuid,uuid)'
  ]::text[] $fn$;
revoke all on function pods_core.api_client_allowlist_v1() from public, anon, authenticated;
do $$ declare a text; begin
  foreach a in array pods_core.api_client_allowlist_v1() loop
    if a like 'public.rpc_hub_%' then
      execute format('revoke all on function %s from public, anon', a);
      execute format('grant execute on function %s to authenticated, service_role', a);
    end if;
  end loop;
end $$;

-- ---------- selftest ----------
create or replace function pods_provisioning.rpc_selftest_hub_credentials_v1()
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, vault, public as $fn$
declare v_sfx text := replace(gen_random_uuid()::text,'-',''); v_org uuid; v_org2 uuid;
  u_owner uuid := gen_random_uuid(); u_staff uuid := gen_random_uuid(); u_out uuid := gen_random_uuid();
  a_gh uuid; a_aws uuid; a_other uuid; v_proj uuid; c1 uuid; c2 uuid; c_env uuid; r jsonb; v text; v_vault uuid; v_n int;
  secret1 text := 'ghp_SELFTEST_' || v_sfx; secret2 text := 'AKIA_SELFTEST_' || v_sfx; secret3 text := 'ROTATED_' || v_sfx;
  t_aal1 bool := false; t_put bool := false; t_no_plain bool := false; t_vault bool := false; t_client_cannot_read bool := false;
  t_env bool := false; t_rotation bool := false; t_openv bool := false; t_openv_value bool := false; t_oauth_client bool := false;
  t_staff bool := false; t_outsider bool := false; t_svc_read bool := false; t_svc_read_client bool := false; t_rotate bool := false;
  t_same bool := false; t_gate_pending bool := false; t_gate_ok bool := false; t_expiring bool := false; t_revoke bool := false;
  t_gate_after bool := false; t_res_secret bool := false; t_res bool := false; t_sync bool := false; t_res_cross bool := false;
  t_cascade bool := false; t_read_audited bool := false; v_ok bool; v_ids uuid[];
begin
  insert into pods.orgs(slug, name) values ('selftest-cred-'||v_sfx, 'selftest cred') returning org_id into v_org;
  insert into pods.orgs(slug, name) values ('selftest-cred2-'||v_sfx, 'selftest cred2') returning org_id into v_org2;
  insert into pods.org_members(org_id, user_id, role_key) values (v_org, u_owner, 'owner'), (v_org, u_staff, 'staff'), (v_org2, u_out, 'owner');
  insert into pods_provisioning.hub_accounts_v1(org_id, provider_key, display_name, environment) values (v_org, 'github', 'gh', 'shared') returning account_id into a_gh;
  insert into pods_provisioning.hub_accounts_v1(org_id, provider_key, display_name, external_ref, environment) values (v_org, 'aws', 'aws prod', '111', 'live') returning account_id into a_aws;
  insert into pods_provisioning.hub_accounts_v1(org_id, provider_key, display_name) values (v_org2, 'github', 'other') returning account_id into a_other;
  insert into pods_provisioning.hub_projects_v1(org_id, name, slug, origin) values (v_org, 'Web', 'web', 'imported') returning project_id into v_proj;
  insert into pods_provisioning.hub_project_accounts_v1(project_id, account_id, usage_role, justification) values (v_proj, a_aws, 'hosting', 'web runs on the prod AWS account');

  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_owner,'aal','aal1')::text, true);
  begin perform public.rpc_hub_credential_put_v1(a_gh, null, 'deploy', 'test', '["repo"]', 'vault', secret1, null, null, 'CI deploys from GitHub');
  exception when others then t_aal1 := sqlerrm like '%MFA_REQUIRED%'; end;

  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_owner,'aal','aal2')::text, true);
  r := public.rpc_hub_credential_put_v1(a_gh, null, 'deploy', 'test', '["repo"]', 'vault', secret1, null, null, 'CI deploys from GitHub');
  c1 := (r->>'credential_id')::uuid;
  t_put := c1 is not null and r->>'fingerprint' like 'sha256:%' and r->>'status' = 'pending_verification';
  select vault_secret_id into v_vault from pods_provisioning.hub_credentials_v1 where credential_id = c1;
  t_no_plain := not exists (select 1 from pods_provisioning.hub_credentials_v1 c where c::text like '%'||secret1||'%')
            and not exists (select 1 from pods.audit_log l where l.org_id = v_org and l.details::text like '%'||secret1||'%')
            and not (public.rpc_hub_credentials_list_v1(v_org, null)::text like '%'||secret1||'%');
  select decrypted_secret into v from vault.decrypted_secrets where id = v_vault;
  t_vault := v = secret1;
  t_client_cannot_read := not has_table_privilege('authenticated','vault.decrypted_secrets','select')
    and not has_function_privilege('authenticated','public.svc_hub_credential_secret_v1(uuid,text)','execute')
    and not has_function_privilege('anon','public.svc_hub_credential_secret_v1(uuid,text)','execute')
    and not has_table_privilege('authenticated','pods_provisioning.hub_credentials_v1','select');

  begin perform public.rpc_hub_credential_put_v1(a_aws, v_proj, 'deploy', 'test', '[]', 'vault', secret2, null, null, 'wrong environment test');
  exception when others then t_env := sqlerrm like '%HUB_CREDENTIAL_ENV_MISMATCH%'; end;
  begin perform public.rpc_hub_credential_put_v1(a_aws, v_proj, 'deploy', 'live', '[]', 'vault', secret2, null, null, 'live key with no rotation');
  exception when others then t_rotation := sqlerrm like '%HUB_ROTATION_REQUIRED%'; end;
  r := public.rpc_hub_credential_put_v1(a_gh, null, 'webhook', 'test', '[]', 'operator_env', null, 'GITHUB_WEBHOOK_SECRET', null, 'secret lives in edge function env');
  c_env := (r->>'credential_id')::uuid; t_openv := c_env is not null;
  begin perform public.rpc_hub_credential_put_v1(a_gh, null, 'webhook2', 'test', '[]', 'operator_env', 'shouldnotbehere', 'X', null, 'value must be rejected');
  exception when others then t_openv_value := sqlerrm like '%HUB_SECRET_VALUE_NOT_ALLOWED%'; end;
  begin perform public.rpc_hub_credential_put_v1(a_gh, null, 'oauth', 'test', '[]', 'provider_oauth', secret2, null, null, 'clients cannot write oauth');
  exception when others then t_oauth_client := sqlerrm like '%HUB_STORAGE_KIND_NOT_ALLOWED%'; end;
  c2 := (public.rpc_hub_credential_put_v1(a_aws, v_proj, 'deploy', 'live', '["ec2"]', 'vault', secret2, null, now() + interval '90 days',
         'prod deploy role for the web project')->>'credential_id')::uuid;

  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_staff,'aal','aal2')::text, true);
  begin perform public.rpc_hub_credential_revoke_v1(c1, 'staff should not revoke'); exception when others then t_staff := sqlerrm like '%FORBIDDEN_ROLE%'; end;
  t_staff := t_staff and jsonb_array_length(public.rpc_hub_credentials_list_v1(v_org, null)) = 3;
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_out,'aal','aal2')::text, true);
  begin perform public.rpc_hub_credentials_list_v1(v_org, null); exception when others then t_outsider := sqlerrm like '%NOT_ORG_MEMBER%'; end;
  begin perform pods_provisioning.svc_hub_credential_secret_v1(c1, 'outsider attempt'); exception when others then t_svc_read_client := sqlerrm like '%HUB_SECRET_READ_FORBIDDEN%'; end;

  -- gate before verification
  perform set_config('request.jwt.claims', '', true);
  t_gate_pending := not (pods_provisioning._hub_eval_requirement_v1(v_proj, 'credentials_valid_live', null)->>'ok')::boolean;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  v := public.svc_hub_credential_secret_v1(c2, 'selftest verification');
  t_svc_read := v = secret2;
  perform public.svc_hub_credential_mark_verified_v1(c2, true, 'sts:GetCallerIdentity ok');
  perform set_config('request.jwt.claims', '', true);
  t_gate_ok := (pods_provisioning._hub_eval_requirement_v1(v_proj, 'credentials_valid_live', null)->>'ok')::boolean;
  select count(*) into v_n from pods.audit_log where org_id = v_org and action_key = 'hub.credential_read';
  t_read_audited := v_n = 1;

  -- rotate (aal2 owner), same value refused, service reads new value, gate drops back to pending
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_owner,'aal','aal2')::text, true);
  begin perform public.rpc_hub_credential_rotate_v1(c2, secret2, now() + interval '90 days', 'rotating with same value');
  exception when others then t_same := sqlerrm like '%HUB_ROTATION_SAME_VALUE%'; end;
  perform public.rpc_hub_credential_rotate_v1(c2, secret3, now() + interval '10 days', 'scheduled 90-day rotation');
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  t_rotate := public.svc_hub_credential_secret_v1(c2, 'post-rotation check') = secret3;
  perform public.svc_hub_credential_mark_verified_v1(c2, true, 'ok');
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_owner,'aal','aal2')::text, true);
  t_expiring := exists (select 1 from jsonb_array_elements(public.rpc_hub_credentials_list_v1(v_org, v_proj)) x
                        where (x->>'credential_id')::uuid = c2 and x->>'status' = 'expiring');

  select vault_secret_id into v_vault from pods_provisioning.hub_credentials_v1 where credential_id = c2;
  perform public.rpc_hub_credential_revoke_v1(c2, 'key leaked in a screenshot');
  t_revoke := not exists (select 1 from vault.secrets where id = v_vault)
          and (select status from pods_provisioning.hub_credentials_v1 where credential_id = c2) = 'revoked';
  perform set_config('request.jwt.claims', '', true);
  t_gate_after := not (pods_provisioning._hub_eval_requirement_v1(v_proj, 'credentials_valid_live', null)->>'ok')::boolean;

  -- resources
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_owner,'aal','aal1')::text, true);
  begin perform public.rpc_hub_resource_upsert_v1(null, a_gh, v_proj, 'repo', 'acme/web', 'acme/web', 'shared', '{"api_token":"x"}', '');
  exception when others then t_res_secret := sqlerrm like '%HUB_RESOURCE_ATTRIBUTES_LOOK_SECRET%'; end;
  t_res := (public.rpc_hub_resource_upsert_v1(null, a_gh, v_proj, 'repo', 'acme/web', 'acme/web', 'shared', '{"default_branch":"main"}', '')->>'resource_id') is not null;
  begin perform public.rpc_hub_resource_upsert_v1(null, a_other, null, 'repo', 'x/y', 'x/y', 'shared', '{}', '');
  exception when others then t_res_cross := sqlerrm like '%NOT_ORG_MEMBER%' or sqlerrm like '%HUB_ACCOUNT_NOT_FOUND%'; end;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  perform public.svc_hub_resource_sync_v1(a_gh, '[{"kind":"repo","external_id":"acme/api"},{"kind":"repo","external_id":"acme/old"}]');
  r := public.svc_hub_resource_sync_v1(a_gh, '[{"kind":"repo","external_id":"acme/api"}]');
  t_sync := (r->>'marked_missing')::int = 1
        and (select status from pods_provisioning.hub_resources_v1 where account_id = a_gh and external_id = 'acme/old') = 'missing'
        and (select status from pods_provisioning.hub_resources_v1 where account_id = a_gh and external_id = 'acme/web') = 'active';
  perform set_config('request.jwt.claims', '', true);

  -- cascade: deleting the workspace destroys remaining Vault secrets
  select array_agg(vault_secret_id) into v_ids from pods_provisioning.hub_credentials_v1 where org_id = v_org and vault_secret_id is not null;
  delete from pods.audit_log where org_id in (v_org, v_org2);
  delete from pods.orgs where org_id in (v_org, v_org2);
  t_cascade := coalesce(cardinality(v_ids),0) >= 1 and not exists (select 1 from vault.secrets where id = any(v_ids));

  v_ok := t_aal1 and t_put and t_no_plain and t_vault and t_client_cannot_read and t_env and t_rotation and t_openv and t_openv_value
      and t_oauth_client and t_staff and t_outsider and t_svc_read_client and t_gate_pending and t_svc_read and t_gate_ok
      and t_read_audited and t_same and t_rotate and t_expiring and t_revoke and t_gate_after and t_res_secret and t_res
      and t_res_cross and t_sync and t_cascade;
  return jsonb_build_object('ok', v_ok,
    'token', case when v_ok then 'PROTEUSOPS_HUB_CREDENTIALS_OK' else 'PROTEUSOPS_HUB_CREDENTIALS_FAIL' end,
    'aal1_blocked', t_aal1, 'put', t_put, 'no_plaintext_outside_vault', t_no_plain, 'vault_holds_value', t_vault,
    'clients_cannot_read', t_client_cannot_read, 'env_mismatch_blocked', t_env, 'live_needs_rotation', t_rotation,
    'operator_env', t_openv, 'operator_env_value_rejected', t_openv_value, 'client_oauth_blocked', t_oauth_client,
    'staff_read_only', t_staff, 'outsider_blocked', t_outsider, 'svc_read_denied_to_users', t_svc_read_client,
    'gate_blocks_unverified', t_gate_pending, 'service_read', t_svc_read, 'gate_passes_verified', t_gate_ok,
    'reads_audited', t_read_audited, 'same_value_rotation_refused', t_same, 'rotation', t_rotate, 'expiring_flag', t_expiring,
    'revoke_destroys_secret', t_revoke, 'gate_blocks_after_revoke', t_gate_after, 'resource_secret_attrs_blocked', t_res_secret,
    'resource_upsert', t_res, 'resource_cross_workspace_blocked', t_res_cross, 'discovery_sync_missing', t_sync,
    'workspace_delete_destroys_secrets', t_cascade);
end $fn$;
revoke all on function pods_provisioning.rpc_selftest_hub_credentials_v1() from public, anon, authenticated;

select pods_provisioning.rpc_selftest_hub_credentials_v1();
