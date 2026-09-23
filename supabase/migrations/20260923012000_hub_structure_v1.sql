-- ProteusOps slice H1b — Workspace Hub structure: nested systems/projects, accounts, dependencies with justifications
-- Operator requirement 2026-09-23: the hub must understand organizations -> accounts -> projects, projects living
-- inside projects/systems, and let users declare their own dependencies with justifications.
--   * hub_projects_v1 becomes a tree: node_kind (system|project|component|service|environment), parent_project_id,
--     same-workspace parents only, cycle-proof, max depth 8.
--   * hub_accounts_v1: external accounts the workspace owns (AWS account, GitHub org, Cloudflare account, ...).
--     Identity/metadata only — never secrets (credentials land in H2 as Vault references).
--   * hub_project_accounts_v1: which project uses which account, for what role, and WHY (justification required).
--   * hub_dependencies_v1: project -> project | account | external dependency, typed, with criticality,
--     owner, review date and a required justification. Inbound/impact queries included.
-- Security: RPC-only (RLS on, no table grants). Owners/admins write, staff read. Changes touching a LIVE account
-- or a project in launch_review/active require MFA (aal2). Every write is audited.

-- ---------- tree ----------
alter table pods_provisioning.hub_projects_v1
  add column if not exists parent_project_id uuid references pods_provisioning.hub_projects_v1(project_id) on delete restrict,
  add column if not exists node_kind text not null default 'project',
  add column if not exists description text not null default '';
alter table pods_provisioning.hub_projects_v1 drop constraint if exists hub_project_node_kind_ck;
alter table pods_provisioning.hub_projects_v1 add constraint hub_project_node_kind_ck
  check (node_kind in ('system','project','component','service','environment'));
alter table pods_provisioning.hub_projects_v1 drop constraint if exists hub_project_description_ck;
alter table pods_provisioning.hub_projects_v1 add constraint hub_project_description_ck check (length(description) <= 4000);
create index if not exists hub_projects_v1_parent_idx on pods_provisioning.hub_projects_v1(parent_project_id);

create or replace function pods_provisioning._hub_tree_guard_v1()
returns trigger language plpgsql security definer set search_path = pods_provisioning, public as $fn$
declare v_cur uuid; v_org uuid; v_depth int := 0;
begin
  if new.parent_project_id is null then return new; end if;
  if new.parent_project_id = new.project_id then raise exception 'HUB_TREE_CYCLE'; end if;
  select org_id into v_org from pods_provisioning.hub_projects_v1 where project_id = new.parent_project_id;
  if v_org is null then raise exception 'HUB_PARENT_NOT_FOUND'; end if;
  if v_org <> new.org_id then raise exception 'HUB_PARENT_OTHER_WORKSPACE' using errcode = '42501'; end if;
  v_cur := new.parent_project_id;
  while v_cur is not null loop
    v_depth := v_depth + 1;
    if v_cur = new.project_id then raise exception 'HUB_TREE_CYCLE'; end if;
    if v_depth > 8 then raise exception 'HUB_TREE_TOO_DEEP'; end if;
    select parent_project_id into v_cur from pods_provisioning.hub_projects_v1 where project_id = v_cur;
  end loop;
  return new;
end $fn$;
drop trigger if exists hub_projects_tree_guard on pods_provisioning.hub_projects_v1;
create trigger hub_projects_tree_guard before insert or update of parent_project_id, org_id
  on pods_provisioning.hub_projects_v1 for each row execute function pods_provisioning._hub_tree_guard_v1();

-- archive requires no active children
insert into pods_provisioning.hub_stage_requirements_v1(stage_key, requirement_key, description) values
  ('archived','no_active_children','All child nodes are archived first')
on conflict (stage_key, requirement_key) do update set description = excluded.description;

-- ---------- accounts ----------
create table if not exists pods_provisioning.hub_accounts_v1 (
  account_id uuid primary key default gen_random_uuid(),
  org_id uuid not null references pods.orgs(org_id) on delete cascade,
  provider_key text not null check (provider_key ~ '^[a-z0-9][a-z0-9_-]{1,31}$'),
  display_name text not null check (length(btrim(display_name)) between 1 and 200),
  external_ref text not null default '' check (length(external_ref) <= 300),
  environment text not null default 'shared' check (environment in ('test','live','shared')),
  owner_user_id uuid,
  notes text not null default '' check (length(notes) <= 4000),
  status text not null default 'active' check (status in ('active','archived')),
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, provider_key, external_ref, environment)
);
create index if not exists hub_accounts_v1_org_idx on pods_provisioning.hub_accounts_v1(org_id);

create table if not exists pods_provisioning.hub_project_accounts_v1 (
  project_id uuid not null references pods_provisioning.hub_projects_v1(project_id) on delete cascade,
  account_id uuid not null references pods_provisioning.hub_accounts_v1(account_id) on delete cascade,
  usage_role text not null check (usage_role ~ '^[a-z][a-z0-9_]{1,31}$'),
  justification text not null check (length(btrim(justification)) between 10 and 4000),
  created_by uuid,
  created_at timestamptz not null default now(),
  primary key (project_id, account_id, usage_role)
);

-- ---------- dependencies ----------
create table if not exists pods_provisioning.hub_dependencies_v1 (
  dependency_id uuid primary key default gen_random_uuid(),
  org_id uuid not null references pods.orgs(org_id) on delete cascade,
  from_project_id uuid not null references pods_provisioning.hub_projects_v1(project_id) on delete cascade,
  target_kind text not null check (target_kind in ('project','account','external')),
  target_project_id uuid references pods_provisioning.hub_projects_v1(project_id) on delete restrict,
  target_account_id uuid references pods_provisioning.hub_accounts_v1(account_id) on delete restrict,
  target_external text check (target_external is null or length(btrim(target_external)) between 2 and 300),
  dependency_type text not null check (dependency_type in ('runtime','build','data','auth','billing','dns','email','storage','monitoring','other')),
  criticality text not null default 'medium' check (criticality in ('critical','high','medium','low')),
  justification text not null check (length(btrim(justification)) between 10 and 4000),
  owner_user_id uuid,
  review_by date,
  status text not null default 'active' check (status in ('active','retired')),
  retired_reason text,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint hub_dependency_target_ck check (
    (target_kind = 'project'  and target_project_id is not null and target_account_id is null and target_external is null) or
    (target_kind = 'account'  and target_account_id is not null and target_project_id is null and target_external is null) or
    (target_kind = 'external' and target_external   is not null and target_project_id is null and target_account_id is null)),
  constraint hub_dependency_no_self_ck check (target_project_id is distinct from from_project_id)
);
create index if not exists hub_dependencies_v1_from_idx on pods_provisioning.hub_dependencies_v1(from_project_id) where status = 'active';
create index if not exists hub_dependencies_v1_tproj_idx on pods_provisioning.hub_dependencies_v1(target_project_id) where status = 'active';
create index if not exists hub_dependencies_v1_tacct_idx on pods_provisioning.hub_dependencies_v1(target_account_id) where status = 'active';
create unique index if not exists hub_dependencies_v1_active_uq on pods_provisioning.hub_dependencies_v1
  (from_project_id, target_kind, coalesce(target_project_id::text, target_account_id::text, lower(target_external)), dependency_type)
  where status = 'active';

-- same-workspace guard for links and dependencies (defense in depth behind the RPCs)
create or replace function pods_provisioning._hub_same_org_guard_v1()
returns trigger language plpgsql security definer set search_path = pods_provisioning, public as $fn$
declare v_a uuid; v_b uuid;
begin
  if tg_table_name = 'hub_project_accounts_v1' then
    select org_id into v_a from pods_provisioning.hub_projects_v1 where project_id = new.project_id;
    select org_id into v_b from pods_provisioning.hub_accounts_v1 where account_id = new.account_id;
    if v_a is distinct from v_b then raise exception 'HUB_CROSS_WORKSPACE_LINK' using errcode = '42501'; end if;
  else
    select org_id into v_a from pods_provisioning.hub_projects_v1 where project_id = new.from_project_id;
    if v_a is distinct from new.org_id then raise exception 'HUB_CROSS_WORKSPACE_LINK' using errcode = '42501'; end if;
    if new.target_project_id is not null then
      select org_id into v_b from pods_provisioning.hub_projects_v1 where project_id = new.target_project_id;
      if v_b is distinct from new.org_id then raise exception 'HUB_CROSS_WORKSPACE_LINK' using errcode = '42501'; end if;
    end if;
    if new.target_account_id is not null then
      select org_id into v_b from pods_provisioning.hub_accounts_v1 where account_id = new.target_account_id;
      if v_b is distinct from new.org_id then raise exception 'HUB_CROSS_WORKSPACE_LINK' using errcode = '42501'; end if;
    end if;
  end if;
  return new;
end $fn$;
drop trigger if exists hub_project_accounts_org_guard on pods_provisioning.hub_project_accounts_v1;
create trigger hub_project_accounts_org_guard before insert or update on pods_provisioning.hub_project_accounts_v1
  for each row execute function pods_provisioning._hub_same_org_guard_v1();
drop trigger if exists hub_dependencies_org_guard on pods_provisioning.hub_dependencies_v1;
create trigger hub_dependencies_org_guard before insert or update on pods_provisioning.hub_dependencies_v1
  for each row execute function pods_provisioning._hub_same_org_guard_v1();

alter table pods_provisioning.hub_accounts_v1         enable row level security;
alter table pods_provisioning.hub_project_accounts_v1 enable row level security;
alter table pods_provisioning.hub_dependencies_v1     enable row level security;
revoke all on pods_provisioning.hub_accounts_v1, pods_provisioning.hub_project_accounts_v1,
  pods_provisioning.hub_dependencies_v1 from anon, authenticated;

-- ---------- helpers ----------
create or replace function pods_provisioning._hub_is_protected_project_v1(p_project_id uuid)
returns boolean language sql stable security definer set search_path = pods_provisioning, public as $fn$
  select coalesce((select current_stage in ('launch_review','active') from pods_provisioning.hub_projects_v1 where project_id = p_project_id), false) $fn$;

create or replace function pods_provisioning._hub_audit_v1(p_org uuid, p_role text, p_action text, p_table text, p_id text, p_details jsonb)
returns void language sql security definer set search_path = pods, public as $fn$
  insert into pods.audit_log(org_id, actor_user_id, actor_role_key, action_key, entity_table, entity_id, details)
  values (p_org, auth.uid(), p_role, p_action, p_table, p_id, coalesce(p_details,'{}'::jsonb)) $fn$;

create or replace function pods_provisioning._hub_require_justification_v1(p text)
returns void language plpgsql immutable set search_path = pg_catalog as $fn$
begin
  if length(btrim(coalesce(p,''))) < 10 then raise exception 'HUB_JUSTIFICATION_REQUIRED'; end if;
end $fn$;

-- requirement evaluator: add no_active_children (rest unchanged)
create or replace function pods_provisioning._hub_eval_requirement_v1(p_project_id uuid, p_requirement_key text, p_reason text)
returns jsonb language plpgsql stable security definer set search_path = pods_provisioning, pods, public as $fn$
declare p pods_provisioning.hub_projects_v1%rowtype; v_ok boolean := false; v_detail text; v_n int; v_m int;
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
    else
      v_ok := false; v_detail := 'not yet verifiable (evaluator pending) - fails closed';
  end case;
  return jsonb_build_object('key', p_requirement_key, 'ok', v_ok, 'detail', v_detail);
end $fn$;

-- ---------- node RPCs ----------
create or replace function pods_provisioning.rpc_hub_node_create_v2(
  p_org_id uuid, p_name text, p_slug text, p_origin text, p_model_instance_runtime_id uuid,
  p_parent_project_id uuid, p_node_kind text, p_description text)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare v_role text; v_id uuid; v_n int;
begin
  v_role := pods_provisioning._hub_authorize_v1(p_org_id, array['owner','admin']);
  if p_parent_project_id is not null and pods_provisioning._hub_is_protected_project_v1(p_parent_project_id) then
    perform pods_core.require_aal2();
  end if;
  if p_model_instance_runtime_id is not null then
    select count(*) into v_n from pods_provisioning.model_instance_runtimes_v1
     where model_instance_runtime_id = p_model_instance_runtime_id and org_id = p_org_id;
    if v_n = 0 then raise exception 'HUB_MODEL_INSTANCE_NOT_IN_WORKSPACE' using errcode = '42501'; end if;
  end if;
  insert into pods_provisioning.hub_projects_v1(org_id, name, slug, origin, model_instance_runtime_id, created_by,
      parent_project_id, node_kind, description)
  values (p_org_id, p_name, p_slug, p_origin, p_model_instance_runtime_id, auth.uid(),
      p_parent_project_id, coalesce(p_node_kind,'project'), coalesce(p_description,''))
  returning project_id into v_id;
  perform pods_provisioning._hub_audit_v1(p_org_id, v_role, 'hub.node_create', 'hub_projects_v1', v_id::text,
    jsonb_build_object('slug', p_slug, 'origin', p_origin, 'kind', coalesce(p_node_kind,'project'), 'parent', p_parent_project_id));
  return jsonb_build_object('project_id', v_id, 'stage', 'draft');
end $fn$;

create or replace function pods_provisioning.rpc_hub_node_move_v1(p_project_id uuid, p_new_parent_id uuid)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare v_org uuid; v_old uuid; v_role text;
begin
  select org_id, parent_project_id into v_org, v_old from pods_provisioning.hub_projects_v1 where project_id = p_project_id for update;
  if v_org is null then raise exception 'HUB_PROJECT_NOT_FOUND'; end if;
  v_role := pods_provisioning._hub_authorize_v1(v_org, array['owner','admin']);
  if pods_provisioning._hub_is_protected_project_v1(p_project_id)
     or (p_new_parent_id is not null and pods_provisioning._hub_is_protected_project_v1(p_new_parent_id))
     or (v_old is not null and pods_provisioning._hub_is_protected_project_v1(v_old)) then
    perform pods_core.require_aal2();
  end if;
  update pods_provisioning.hub_projects_v1 set parent_project_id = p_new_parent_id, updated_at = now() where project_id = p_project_id;
  perform pods_provisioning._hub_audit_v1(v_org, v_role, 'hub.node_move', 'hub_projects_v1', p_project_id::text,
    jsonb_build_object('from_parent', v_old, 'to_parent', p_new_parent_id));
  return jsonb_build_object('project_id', p_project_id, 'parent_project_id', p_new_parent_id);
end $fn$;

create or replace function pods_provisioning.rpc_hub_tree_v1(p_org_id uuid)
returns jsonb language plpgsql stable security definer set search_path = pods_provisioning, pods, public as $fn$
begin
  perform pods_provisioning._hub_authorize_v1(p_org_id, array['owner','admin','staff']);
  return coalesce((
    with recursive t as (
      select p.project_id, p.parent_project_id, 0 as depth, array[p.name] as path
        from pods_provisioning.hub_projects_v1 p where p.org_id = p_org_id and p.parent_project_id is null
      union all
      select c.project_id, c.parent_project_id, t.depth + 1, t.path || c.name
        from pods_provisioning.hub_projects_v1 c join t on c.parent_project_id = t.project_id
       where t.depth < 8)
    select jsonb_agg(jsonb_build_object(
      'project_id', p.project_id, 'parent_project_id', p.parent_project_id, 'depth', t.depth, 'path', to_jsonb(t.path),
      'name', p.name, 'slug', p.slug, 'kind', p.node_kind, 'origin', p.origin, 'stage', p.current_stage,
      'description', p.description,
      'accounts', coalesce((select jsonb_agg(jsonb_build_object('account_id', a.account_id, 'provider', a.provider_key,
                     'name', a.display_name, 'environment', a.environment, 'role', pa.usage_role, 'justification', pa.justification))
                   from pods_provisioning.hub_project_accounts_v1 pa join pods_provisioning.hub_accounts_v1 a on a.account_id = pa.account_id
                  where pa.project_id = p.project_id), '[]'::jsonb),
      'dependencies_out', (select count(*) from pods_provisioning.hub_dependencies_v1 d where d.from_project_id = p.project_id and d.status = 'active'),
      'dependents_in', (select count(*) from pods_provisioning.hub_dependencies_v1 d where d.target_project_id = p.project_id and d.status = 'active'))
      order by t.path)
    from t join pods_provisioning.hub_projects_v1 p on p.project_id = t.project_id), '[]'::jsonb);
end $fn$;

-- ---------- account RPCs ----------
create or replace function pods_provisioning.rpc_hub_account_upsert_v1(
  p_org_id uuid, p_account_id uuid, p_provider_key text, p_display_name text, p_external_ref text,
  p_environment text, p_owner_user_id uuid, p_notes text)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare v_role text; v_id uuid; v_old_env text; v_org uuid;
begin
  v_role := pods_provisioning._hub_authorize_v1(p_org_id, array['owner','admin']);
  if p_account_id is not null then
    select org_id, environment into v_org, v_old_env from pods_provisioning.hub_accounts_v1 where account_id = p_account_id for update;
    if v_org is null or v_org <> p_org_id then raise exception 'HUB_ACCOUNT_NOT_FOUND'; end if;
  end if;
  if coalesce(p_environment,'shared') = 'live' or v_old_env = 'live' then perform pods_core.require_aal2(); end if;
  if p_owner_user_id is not null and not exists (select 1 from pods.org_members where org_id = p_org_id and user_id = p_owner_user_id) then
    raise exception 'HUB_OWNER_NOT_MEMBER';
  end if;
  if p_account_id is null then
    insert into pods_provisioning.hub_accounts_v1(org_id, provider_key, display_name, external_ref, environment, owner_user_id, notes, created_by)
    values (p_org_id, lower(p_provider_key), p_display_name, coalesce(p_external_ref,''), coalesce(p_environment,'shared'),
            p_owner_user_id, coalesce(p_notes,''), auth.uid())
    returning account_id into v_id;
  else
    update pods_provisioning.hub_accounts_v1 set provider_key = lower(p_provider_key), display_name = p_display_name,
      external_ref = coalesce(p_external_ref,''), environment = coalesce(p_environment,'shared'),
      owner_user_id = p_owner_user_id, notes = coalesce(p_notes,''), updated_at = now()
     where account_id = p_account_id returning account_id into v_id;
  end if;
  perform pods_provisioning._hub_audit_v1(p_org_id, v_role, 'hub.account_upsert', 'hub_accounts_v1', v_id::text,
    jsonb_build_object('provider', lower(p_provider_key), 'environment', coalesce(p_environment,'shared'), 'created', p_account_id is null));
  return jsonb_build_object('account_id', v_id);
end $fn$;

create or replace function pods_provisioning.rpc_hub_account_archive_v1(p_account_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare v_org uuid; v_env text; v_role text; v_deps int;
begin
  select org_id, environment into v_org, v_env from pods_provisioning.hub_accounts_v1 where account_id = p_account_id for update;
  if v_org is null then raise exception 'HUB_ACCOUNT_NOT_FOUND'; end if;
  v_role := pods_provisioning._hub_authorize_v1(v_org, array['owner','admin']);
  if v_env = 'live' then perform pods_core.require_aal2(); end if;
  perform pods_provisioning._hub_require_justification_v1(p_reason);
  select count(*) into v_deps from pods_provisioning.hub_dependencies_v1 where target_account_id = p_account_id and status = 'active';
  if v_deps > 0 then raise exception 'HUB_ACCOUNT_HAS_ACTIVE_DEPENDENTS'; end if;
  update pods_provisioning.hub_accounts_v1 set status = 'archived', updated_at = now() where account_id = p_account_id;
  perform pods_provisioning._hub_audit_v1(v_org, v_role, 'hub.account_archive', 'hub_accounts_v1', p_account_id::text,
    jsonb_build_object('reason', p_reason));
  return jsonb_build_object('account_id', p_account_id, 'status', 'archived');
end $fn$;

create or replace function pods_provisioning.rpc_hub_accounts_list_v1(p_org_id uuid)
returns jsonb language plpgsql stable security definer set search_path = pods_provisioning, pods, public as $fn$
begin
  perform pods_provisioning._hub_authorize_v1(p_org_id, array['owner','admin','staff']);
  return coalesce((select jsonb_agg(jsonb_build_object('account_id', a.account_id, 'provider', a.provider_key,
      'name', a.display_name, 'external_ref', a.external_ref, 'environment', a.environment, 'owner_user_id', a.owner_user_id,
      'notes', a.notes, 'status', a.status,
      'used_by', coalesce((select jsonb_agg(jsonb_build_object('project_id', pa.project_id, 'role', pa.usage_role))
                  from pods_provisioning.hub_project_accounts_v1 pa where pa.account_id = a.account_id), '[]'::jsonb))
      order by a.provider_key, a.display_name)
    from pods_provisioning.hub_accounts_v1 a where a.org_id = p_org_id), '[]'::jsonb);
end $fn$;

create or replace function pods_provisioning.rpc_hub_project_account_link_v1(p_project_id uuid, p_account_id uuid, p_usage_role text, p_justification text)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare v_org uuid; v_role text; v_env text; v_status text;
begin
  select org_id into v_org from pods_provisioning.hub_projects_v1 where project_id = p_project_id;
  if v_org is null then raise exception 'HUB_PROJECT_NOT_FOUND'; end if;
  v_role := pods_provisioning._hub_authorize_v1(v_org, array['owner','admin']);
  select environment, status into v_env, v_status from pods_provisioning.hub_accounts_v1 where account_id = p_account_id and org_id = v_org;
  if v_env is null then raise exception 'HUB_ACCOUNT_NOT_FOUND'; end if;
  if v_status <> 'active' then raise exception 'HUB_ACCOUNT_ARCHIVED'; end if;
  if v_env = 'live' or pods_provisioning._hub_is_protected_project_v1(p_project_id) then perform pods_core.require_aal2(); end if;
  perform pods_provisioning._hub_require_justification_v1(p_justification);
  insert into pods_provisioning.hub_project_accounts_v1(project_id, account_id, usage_role, justification, created_by)
  values (p_project_id, p_account_id, lower(p_usage_role), btrim(p_justification), auth.uid())
  on conflict (project_id, account_id, usage_role) do update set justification = excluded.justification;
  perform pods_provisioning._hub_audit_v1(v_org, v_role, 'hub.account_link', 'hub_project_accounts_v1', p_project_id::text,
    jsonb_build_object('account_id', p_account_id, 'role', lower(p_usage_role), 'justification', btrim(p_justification)));
  return jsonb_build_object('project_id', p_project_id, 'account_id', p_account_id, 'role', lower(p_usage_role));
end $fn$;

create or replace function pods_provisioning.rpc_hub_project_account_unlink_v1(p_project_id uuid, p_account_id uuid, p_usage_role text, p_reason text)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare v_org uuid; v_role text; v_env text;
begin
  select org_id into v_org from pods_provisioning.hub_projects_v1 where project_id = p_project_id;
  if v_org is null then raise exception 'HUB_PROJECT_NOT_FOUND'; end if;
  v_role := pods_provisioning._hub_authorize_v1(v_org, array['owner','admin']);
  select environment into v_env from pods_provisioning.hub_accounts_v1 where account_id = p_account_id;
  if v_env = 'live' or pods_provisioning._hub_is_protected_project_v1(p_project_id) then perform pods_core.require_aal2(); end if;
  perform pods_provisioning._hub_require_justification_v1(p_reason);
  delete from pods_provisioning.hub_project_accounts_v1 where project_id = p_project_id and account_id = p_account_id and usage_role = lower(p_usage_role);
  perform pods_provisioning._hub_audit_v1(v_org, v_role, 'hub.account_unlink', 'hub_project_accounts_v1', p_project_id::text,
    jsonb_build_object('account_id', p_account_id, 'role', lower(p_usage_role), 'reason', p_reason));
  return jsonb_build_object('ok', true);
end $fn$;

-- ---------- dependency RPCs ----------
create or replace function pods_provisioning.rpc_hub_dependency_upsert_v1(
  p_dependency_id uuid, p_from_project_id uuid, p_target_kind text, p_target_project_id uuid, p_target_account_id uuid,
  p_target_external text, p_dependency_type text, p_criticality text, p_justification text, p_owner_user_id uuid, p_review_by date)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare v_org uuid; v_role text; v_id uuid; v_env text; v_from uuid;
begin
  if p_dependency_id is not null then
    select from_project_id into v_from from pods_provisioning.hub_dependencies_v1 where dependency_id = p_dependency_id and status = 'active' for update;
    if v_from is null then raise exception 'HUB_DEPENDENCY_NOT_FOUND'; end if;
    if v_from <> p_from_project_id then raise exception 'HUB_DEPENDENCY_SOURCE_IMMUTABLE'; end if;
  end if;
  select org_id into v_org from pods_provisioning.hub_projects_v1 where project_id = p_from_project_id;
  if v_org is null then raise exception 'HUB_PROJECT_NOT_FOUND'; end if;
  v_role := pods_provisioning._hub_authorize_v1(v_org, array['owner','admin']);
  if p_target_account_id is not null then
    select environment into v_env from pods_provisioning.hub_accounts_v1 where account_id = p_target_account_id;
  end if;
  if pods_provisioning._hub_is_protected_project_v1(p_from_project_id) or v_env = 'live' then perform pods_core.require_aal2(); end if;
  perform pods_provisioning._hub_require_justification_v1(p_justification);
  if p_owner_user_id is not null and not exists (select 1 from pods.org_members where org_id = v_org and user_id = p_owner_user_id) then
    raise exception 'HUB_OWNER_NOT_MEMBER';
  end if;
  if p_dependency_id is null then
    insert into pods_provisioning.hub_dependencies_v1(org_id, from_project_id, target_kind, target_project_id, target_account_id,
      target_external, dependency_type, criticality, justification, owner_user_id, review_by, created_by)
    values (v_org, p_from_project_id, p_target_kind, p_target_project_id, p_target_account_id, nullif(btrim(p_target_external),''),
      p_dependency_type, coalesce(p_criticality,'medium'), btrim(p_justification), p_owner_user_id, p_review_by, auth.uid())
    returning dependency_id into v_id;
  else
    update pods_provisioning.hub_dependencies_v1 set target_kind = p_target_kind, target_project_id = p_target_project_id,
      target_account_id = p_target_account_id, target_external = nullif(btrim(p_target_external),''), dependency_type = p_dependency_type,
      criticality = coalesce(p_criticality,'medium'), justification = btrim(p_justification), owner_user_id = p_owner_user_id,
      review_by = p_review_by, updated_at = now()
     where dependency_id = p_dependency_id returning dependency_id into v_id;
  end if;
  perform pods_provisioning._hub_audit_v1(v_org, v_role, 'hub.dependency_upsert', 'hub_dependencies_v1', v_id::text,
    jsonb_build_object('from', p_from_project_id, 'kind', p_target_kind, 'type', p_dependency_type,
                       'criticality', coalesce(p_criticality,'medium'), 'justification', btrim(p_justification)));
  return jsonb_build_object('dependency_id', v_id);
end $fn$;

create or replace function pods_provisioning.rpc_hub_dependency_retire_v1(p_dependency_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare d pods_provisioning.hub_dependencies_v1%rowtype; v_role text; v_env text;
begin
  select * into d from pods_provisioning.hub_dependencies_v1 where dependency_id = p_dependency_id and status = 'active' for update;
  if not found then raise exception 'HUB_DEPENDENCY_NOT_FOUND'; end if;
  v_role := pods_provisioning._hub_authorize_v1(d.org_id, array['owner','admin']);
  if d.target_account_id is not null then select environment into v_env from pods_provisioning.hub_accounts_v1 where account_id = d.target_account_id; end if;
  if pods_provisioning._hub_is_protected_project_v1(d.from_project_id) or v_env = 'live' then perform pods_core.require_aal2(); end if;
  perform pods_provisioning._hub_require_justification_v1(p_reason);
  update pods_provisioning.hub_dependencies_v1 set status = 'retired', retired_reason = btrim(p_reason), updated_at = now()
   where dependency_id = p_dependency_id;
  perform pods_provisioning._hub_audit_v1(d.org_id, v_role, 'hub.dependency_retire', 'hub_dependencies_v1', p_dependency_id::text,
    jsonb_build_object('reason', btrim(p_reason)));
  return jsonb_build_object('dependency_id', p_dependency_id, 'status', 'retired');
end $fn$;

-- outbound (what this node and its descendants rely on) + inbound (who relies on it) + transitive impact
create or replace function pods_provisioning.rpc_hub_dependencies_v1(p_project_id uuid, p_include_descendants boolean default true)
returns jsonb language plpgsql stable security definer set search_path = pods_provisioning, pods, public as $fn$
declare v_org uuid;
begin
  select org_id into v_org from pods_provisioning.hub_projects_v1 where project_id = p_project_id;
  if v_org is null then raise exception 'HUB_PROJECT_NOT_FOUND'; end if;
  perform pods_provisioning._hub_authorize_v1(v_org, array['owner','admin','staff']);
  return (
    with recursive scope as (
      select p_project_id as project_id, 0 as depth
      union all
      select c.project_id, s.depth + 1 from pods_provisioning.hub_projects_v1 c join scope s on c.parent_project_id = s.project_id
       where p_include_descendants and s.depth < 8),
    impact as (
      select d.from_project_id as project_id, 1 as hops, array[p_project_id, d.from_project_id] as trail
        from pods_provisioning.hub_dependencies_v1 d where d.target_project_id = p_project_id and d.status = 'active'
      union all
      select d.from_project_id, i.hops + 1, i.trail || d.from_project_id
        from pods_provisioning.hub_dependencies_v1 d join impact i on d.target_project_id = i.project_id
       where d.status = 'active' and i.hops < 8 and not (d.from_project_id = any(i.trail)))
    select jsonb_build_object(
      'project_id', p_project_id,
      'outbound', coalesce((select jsonb_agg(jsonb_build_object('dependency_id', d.dependency_id, 'from_project_id', d.from_project_id,
          'target_kind', d.target_kind, 'target_project_id', d.target_project_id, 'target_account_id', d.target_account_id,
          'target_external', d.target_external, 'type', d.dependency_type, 'criticality', d.criticality,
          'justification', d.justification, 'owner_user_id', d.owner_user_id, 'review_by', d.review_by,
          'review_overdue', d.review_by is not null and d.review_by < current_date) order by d.criticality, d.created_at)
        from pods_provisioning.hub_dependencies_v1 d join scope s on s.project_id = d.from_project_id where d.status = 'active'), '[]'::jsonb),
      'inbound', coalesce((select jsonb_agg(jsonb_build_object('dependency_id', d.dependency_id, 'from_project_id', d.from_project_id,
          'type', d.dependency_type, 'criticality', d.criticality, 'justification', d.justification))
        from pods_provisioning.hub_dependencies_v1 d where d.target_project_id = p_project_id and d.status = 'active'), '[]'::jsonb),
      'impact', coalesce((select jsonb_agg(distinct i.project_id) from impact i), '[]'::jsonb),
      'cycle_detected', exists (select 1 from impact i where i.project_id = p_project_id)));
end $fn$;

-- ---------- grants + public wrappers ----------
do $$ declare s text; begin
  foreach s in array array[
    'pods_provisioning._hub_tree_guard_v1()', 'pods_provisioning._hub_same_org_guard_v1()',
    'pods_provisioning._hub_is_protected_project_v1(uuid)', 'pods_provisioning._hub_audit_v1(uuid,text,text,text,text,jsonb)',
    'pods_provisioning._hub_require_justification_v1(text)', 'pods_provisioning._hub_eval_requirement_v1(uuid,text,text)',
    'pods_provisioning.rpc_hub_node_create_v2(uuid,text,text,text,uuid,uuid,text,text)', 'pods_provisioning.rpc_hub_node_move_v1(uuid,uuid)',
    'pods_provisioning.rpc_hub_tree_v1(uuid)', 'pods_provisioning.rpc_hub_account_upsert_v1(uuid,uuid,text,text,text,text,uuid,text)',
    'pods_provisioning.rpc_hub_account_archive_v1(uuid,text)', 'pods_provisioning.rpc_hub_accounts_list_v1(uuid)',
    'pods_provisioning.rpc_hub_project_account_link_v1(uuid,uuid,text,text)', 'pods_provisioning.rpc_hub_project_account_unlink_v1(uuid,uuid,text,text)',
    'pods_provisioning.rpc_hub_dependency_upsert_v1(uuid,uuid,text,uuid,uuid,text,text,text,text,uuid,date)',
    'pods_provisioning.rpc_hub_dependency_retire_v1(uuid,text)', 'pods_provisioning.rpc_hub_dependencies_v1(uuid,boolean)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', s);
    execute format('grant execute on function %s to service_role', s);
  end loop;
end $$;

create or replace function public.rpc_hub_node_create_v2(p_org_id uuid, p_name text, p_slug text, p_origin text, p_model_instance_runtime_id uuid,
  p_parent_project_id uuid, p_node_kind text, p_description text)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_node_create_v2(p_org_id, p_name, p_slug, p_origin, p_model_instance_runtime_id, p_parent_project_id, p_node_kind, p_description) $fn$;
create or replace function public.rpc_hub_node_move_v1(p_project_id uuid, p_new_parent_id uuid)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_node_move_v1(p_project_id, p_new_parent_id) $fn$;
create or replace function public.rpc_hub_tree_v1(p_org_id uuid)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_tree_v1(p_org_id) $fn$;
create or replace function public.rpc_hub_account_upsert_v1(p_org_id uuid, p_account_id uuid, p_provider_key text, p_display_name text,
  p_external_ref text, p_environment text, p_owner_user_id uuid, p_notes text)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_account_upsert_v1(p_org_id, p_account_id, p_provider_key, p_display_name, p_external_ref, p_environment, p_owner_user_id, p_notes) $fn$;
create or replace function public.rpc_hub_account_archive_v1(p_account_id uuid, p_reason text)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_account_archive_v1(p_account_id, p_reason) $fn$;
create or replace function public.rpc_hub_accounts_list_v1(p_org_id uuid)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_accounts_list_v1(p_org_id) $fn$;
create or replace function public.rpc_hub_project_account_link_v1(p_project_id uuid, p_account_id uuid, p_usage_role text, p_justification text)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_project_account_link_v1(p_project_id, p_account_id, p_usage_role, p_justification) $fn$;
create or replace function public.rpc_hub_project_account_unlink_v1(p_project_id uuid, p_account_id uuid, p_usage_role text, p_reason text)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_project_account_unlink_v1(p_project_id, p_account_id, p_usage_role, p_reason) $fn$;
create or replace function public.rpc_hub_dependency_upsert_v1(p_dependency_id uuid, p_from_project_id uuid, p_target_kind text,
  p_target_project_id uuid, p_target_account_id uuid, p_target_external text, p_dependency_type text, p_criticality text,
  p_justification text, p_owner_user_id uuid, p_review_by date)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_dependency_upsert_v1(p_dependency_id, p_from_project_id, p_target_kind, p_target_project_id,
    p_target_account_id, p_target_external, p_dependency_type, p_criticality, p_justification, p_owner_user_id, p_review_by) $fn$;
create or replace function public.rpc_hub_dependency_retire_v1(p_dependency_id uuid, p_reason text)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_dependency_retire_v1(p_dependency_id, p_reason) $fn$;
create or replace function public.rpc_hub_dependencies_v1(p_project_id uuid, p_include_descendants boolean default true)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_dependencies_v1(p_project_id, p_include_descendants) $fn$;

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
    'public.rpc_hub_dependencies_v1(uuid,boolean)'
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
create or replace function pods_provisioning.rpc_selftest_hub_structure_v1()
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare v_sfx text := replace(gen_random_uuid()::text,'-',''); v_org uuid; v_org2 uuid;
  u_owner uuid := gen_random_uuid(); u_staff uuid := gen_random_uuid(); u_out uuid := gen_random_uuid();
  v_sys uuid; v_web uuid; v_api uuid; v_db uuid; v_other uuid; a_gh uuid; a_aws uuid; a_other uuid; d1 uuid; d2 uuid; r jsonb;
  t_tree bool := false; t_cycle bool := false; t_cross_parent bool := false; t_depth bool := false;
  t_acct bool := false; t_live_aal bool := false; t_link_just bool := false; t_link bool := false; t_cross_link bool := false;
  t_dep_just bool := false; t_dep bool := false; t_dep_dup bool := false; t_impact bool := false; t_staff_ro bool := false;
  t_outsider bool := false; t_archive_children bool := false; t_acct_dependents bool := false; t_retire bool := false;
  t_protected_aal bool := false; t_audit bool := false; t_rls bool := false; v_ok bool; v_n int; v_prev uuid; i int;
begin
  insert into pods.orgs(slug, name) values ('selftest-hs-'||v_sfx, 'selftest hub structure') returning org_id into v_org;
  insert into pods.orgs(slug, name) values ('selftest-hs2-'||v_sfx, 'selftest hub other') returning org_id into v_org2;
  insert into pods.org_members(org_id, user_id, role_key) values (v_org, u_owner, 'owner'), (v_org, u_staff, 'staff'), (v_org2, u_out, 'owner');
  insert into pods_provisioning.hub_projects_v1(org_id, name, slug, origin) values (v_org2, 'Other', 'other', 'imported') returning project_id into v_other;
  insert into pods_provisioning.hub_accounts_v1(org_id, provider_key, display_name) values (v_org2, 'github', 'other gh') returning account_id into a_other;

  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_owner,'aal','aal1')::text, true);
  v_sys := (public.rpc_hub_node_create_v2(v_org, 'Platform', 'platform', 'imported', null, null, 'system', 'top-level system')->>'project_id')::uuid;
  v_web := (public.rpc_hub_node_create_v2(v_org, 'Web', 'web', 'imported', null, v_sys, 'project', '')->>'project_id')::uuid;
  v_api := (public.rpc_hub_node_create_v2(v_org, 'API', 'api', 'imported', null, v_sys, 'service', '')->>'project_id')::uuid;
  v_db  := (public.rpc_hub_node_create_v2(v_org, 'DB', 'db', 'imported', null, v_api, 'component', '')->>'project_id')::uuid;
  r := public.rpc_hub_tree_v1(v_org);
  t_tree := jsonb_array_length(r) = 4 and exists (select 1 from jsonb_array_elements(r) x where x->>'slug' = 'db' and (x->>'depth')::int = 2);

  begin perform public.rpc_hub_node_move_v1(v_sys, v_db); exception when others then t_cycle := sqlerrm like '%HUB_TREE_CYCLE%'; end;
  begin perform public.rpc_hub_node_create_v2(v_org, 'X', 'x-cross', 'imported', null, v_other, 'project', '');
  exception when others then t_cross_parent := sqlerrm like '%HUB_PARENT_OTHER_WORKSPACE%'; end;
  v_prev := v_db;
  begin
    for i in 1..8 loop
      v_prev := (public.rpc_hub_node_create_v2(v_org, 'L'||i, 'deep-'||i, 'imported', null, v_prev, 'component', '')->>'project_id')::uuid;
    end loop;
  exception when others then t_depth := sqlerrm like '%HUB_TREE_TOO_DEEP%'; end;

  a_gh := (public.rpc_hub_account_upsert_v1(v_org, null, 'GitHub', 'Acme GitHub org', 'acme', 'shared', u_owner, '')->>'account_id')::uuid;
  t_acct := a_gh is not null;
  begin perform public.rpc_hub_account_upsert_v1(v_org, null, 'aws', 'Prod AWS', '123456789012', 'live', null, '');
  exception when others then t_live_aal := sqlerrm like '%MFA_REQUIRED%'; end;
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_owner,'aal','aal2')::text, true);
  a_aws := (public.rpc_hub_account_upsert_v1(v_org, null, 'aws', 'Prod AWS', '123456789012', 'live', null, '')->>'account_id')::uuid;
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_owner,'aal','aal1')::text, true);

  begin perform public.rpc_hub_project_account_link_v1(v_web, a_gh, 'source', 'short');
  exception when others then t_link_just := sqlerrm like '%HUB_JUSTIFICATION_REQUIRED%'; end;
  perform public.rpc_hub_project_account_link_v1(v_web, a_gh, 'source', 'Web app source lives in the Acme GitHub org');
  t_link := exists (select 1 from jsonb_array_elements(public.rpc_hub_tree_v1(v_org)) x
                    where x->>'slug' = 'web' and jsonb_array_length(x->'accounts') = 1);
  begin perform public.rpc_hub_project_account_link_v1(v_web, a_other, 'source', 'Trying to link another workspace account');
  exception when others then t_cross_link := sqlerrm like '%HUB_ACCOUNT_NOT_FOUND%'; end;

  begin perform public.rpc_hub_dependency_upsert_v1(null, v_web, 'project', v_api, null, null, 'runtime', 'critical', 'nope', null, null);
  exception when others then t_dep_just := sqlerrm like '%HUB_JUSTIFICATION_REQUIRED%'; end;
  d1 := (public.rpc_hub_dependency_upsert_v1(null, v_web, 'project', v_api, null, null, 'runtime', 'critical',
         'Web calls the API for every page render', u_owner, current_date - 1)->>'dependency_id')::uuid;
  d2 := (public.rpc_hub_dependency_upsert_v1(null, v_api, 'external', null, null, 'api.stripe.com', 'billing', 'high',
         'API creates Stripe checkout sessions', null, null)->>'dependency_id')::uuid;
  t_dep := d1 is not null and d2 is not null;
  begin perform public.rpc_hub_dependency_upsert_v1(null, v_web, 'project', v_api, null, null, 'runtime', 'low',
         'Duplicate of an existing active dependency', null, null);
  exception when others then t_dep_dup := true; end;
  r := public.rpc_hub_dependencies_v1(v_api, false);
  t_impact := jsonb_array_length(r->'inbound') = 1 and (r->'impact') @> to_jsonb(array[v_web]) and jsonb_array_length(r->'outbound') = 1;
  r := public.rpc_hub_dependencies_v1(v_sys, true);
  t_impact := t_impact and jsonb_array_length(r->'outbound') = 2
          and exists (select 1 from jsonb_array_elements(r->'outbound') x where (x->>'review_overdue')::boolean);

  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_staff,'aal','aal2')::text, true);
  begin perform public.rpc_hub_dependency_retire_v1(d1, 'staff should not be able to retire');
  exception when others then t_staff_ro := sqlerrm like '%FORBIDDEN_ROLE%'; end;
  t_staff_ro := t_staff_ro and jsonb_array_length(public.rpc_hub_tree_v1(v_org)) >= 4;
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_out,'aal','aal2')::text, true);
  begin perform public.rpc_hub_dependencies_v1(v_api, true); exception when others then t_outsider := sqlerrm like '%NOT_ORG_MEMBER%'; end;

  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_owner,'aal','aal1')::text, true);
  r := public.rpc_hub_transition_v1(v_sys, 'archived', 'retire the whole platform');
  t_archive_children := not (r->>'allowed')::boolean and exists (select 1 from jsonb_array_elements(r->'requirements') x
                          where x->>'key' = 'no_active_children' and not (x->>'ok')::boolean);
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_owner,'aal','aal2')::text, true);
  perform public.rpc_hub_dependency_upsert_v1(null, v_api, 'account', null, a_aws, null, 'runtime', 'critical',
          'API runs on the production AWS account', null, null);
  begin perform public.rpc_hub_account_archive_v1(a_aws, 'decommissioning this account');
  exception when others then t_acct_dependents := sqlerrm like '%HUB_ACCOUNT_HAS_ACTIVE_DEPENDENTS%'; end;
  perform public.rpc_hub_dependency_retire_v1(d2, 'moved billing to a separate service');
  t_retire := jsonb_array_length(public.rpc_hub_dependencies_v1(v_api, false)->'outbound') = 1;

  -- protected (active) project: changes need aal2
  perform set_config('request.jwt.claims', '', true);
  update pods_provisioning.hub_projects_v1 set current_stage = 'active' where project_id = v_web;
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_owner,'aal','aal1')::text, true);
  begin perform public.rpc_hub_dependency_retire_v1(d1, 'aal1 must not change a live project');
  exception when others then t_protected_aal := sqlerrm like '%MFA_REQUIRED%'; end;
  perform set_config('request.jwt.claims', '', true);

  select count(*) into v_n from pods.audit_log where org_id = v_org and action_key like 'hub.%';
  t_audit := v_n >= 10;
  select bool_and(c.relrowsecurity) and bool_and(not has_table_privilege('authenticated', c.oid, 'select'))
    into t_rls from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'pods_provisioning' and c.relname like 'hub\_%' and c.relkind = 'r';

  delete from pods.audit_log where org_id in (v_org, v_org2);
  delete from pods_provisioning.hub_dependencies_v1 where org_id in (v_org, v_org2);
  update pods_provisioning.hub_projects_v1 set parent_project_id = null where org_id in (v_org, v_org2);
  delete from pods.orgs where org_id in (v_org, v_org2);

  v_ok := t_tree and t_cycle and t_cross_parent and t_depth and t_acct and t_live_aal and t_link_just and t_link
      and t_cross_link and t_dep_just and t_dep and t_dep_dup and t_impact and t_staff_ro and t_outsider
      and t_archive_children and t_acct_dependents and t_retire and t_protected_aal and t_audit and coalesce(t_rls,false);
  return jsonb_build_object('ok', v_ok,
    'token', case when v_ok then 'PROTEUSOPS_HUB_STRUCTURE_OK' else 'PROTEUSOPS_HUB_STRUCTURE_FAIL' end,
    'tree', t_tree, 'cycle_blocked', t_cycle, 'cross_workspace_parent_blocked', t_cross_parent, 'depth_limited', t_depth,
    'account_created', t_acct, 'live_account_needs_mfa', t_live_aal, 'link_needs_justification', t_link_just,
    'account_linked', t_link, 'cross_workspace_account_blocked', t_cross_link, 'dependency_needs_justification', t_dep_just,
    'dependencies_created', t_dep, 'duplicate_dependency_blocked', t_dep_dup, 'impact_and_review', t_impact,
    'staff_read_only', t_staff_ro, 'outsider_blocked', t_outsider, 'archive_needs_children_archived', t_archive_children,
    'account_with_dependents_not_archivable', t_acct_dependents, 'retire', t_retire, 'protected_project_needs_mfa', t_protected_aal,
    'audited', t_audit, 'rls_on_no_grants', t_rls);
end $fn$;
revoke all on function pods_provisioning.rpc_selftest_hub_structure_v1() from public, anon, authenticated;

select pods_provisioning.rpc_selftest_hub_structure_v1();
