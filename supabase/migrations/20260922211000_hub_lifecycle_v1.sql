-- ProteusOps slice H1 — Workspace Hub: projects + lifecycle stages + gates (docs/proposals/WORKSPACE_HUB_v1.md)
-- Operator decisions 2026-09-22: a project is EITHER a ProteusOps model instance OR an imported
-- project; providers order GitHub -> Supabase -> Cloudflare -> AWS (H3); past_due grace (6g).
-- Model: stages and their entry requirements are DATA (seeded here). Transitions happen only via
-- RPC, are evaluated against the target stage's requirements, and every attempt (allowed or
-- refused) is recorded + audited. Requirements that later slices will verify (credentials, DNS/SSL,
-- launch receipt) are declared now and FAIL CLOSED until their evaluator lands.
-- All tables: RLS on, no client policies (RPC-only). All functions: SECURITY DEFINER + fixed search_path.

-- ---------- catalog ----------
create table if not exists pods_provisioning.hub_stages_v1 (
  stage_key text primary key,
  ordinal int not null unique,
  description text not null
);
create table if not exists pods_provisioning.hub_stage_edges_v1 (
  from_stage text not null references pods_provisioning.hub_stages_v1(stage_key),
  to_stage   text not null references pods_provisioning.hub_stages_v1(stage_key),
  requires_aal2 boolean not null default false,
  primary key (from_stage, to_stage),
  check (from_stage <> to_stage)
);
create table if not exists pods_provisioning.hub_stage_requirements_v1 (
  stage_key text not null references pods_provisioning.hub_stages_v1(stage_key),
  requirement_key text not null,
  description text not null,
  active boolean not null default true,
  primary key (stage_key, requirement_key)
);

insert into pods_provisioning.hub_stages_v1(stage_key, ordinal, description) values
  ('draft',1,'Project created; fields being filled in'),
  ('build',2,'Being built; test credentials only'),
  ('staging',3,'Running on a staging host with providers connected'),
  ('launch_review',4,'Pre-launch checks; privileged actions need MFA'),
  ('active',5,'Live in production; every privileged action needs MFA'),
  ('paused',6,'Temporarily stopped (manual, or billing lapse)'),
  ('archived',7,'Retired; read-only')
on conflict (stage_key) do update set ordinal = excluded.ordinal, description = excluded.description;

insert into pods_provisioning.hub_stage_edges_v1(from_stage, to_stage, requires_aal2) values
  ('draft','build',false), ('build','draft',false), ('build','staging',false), ('staging','build',false),
  ('staging','launch_review',true), ('launch_review','staging',true), ('launch_review','active',true),
  ('active','paused',true), ('paused','active',true),
  ('draft','archived',false), ('build','archived',false), ('staging','archived',true), ('paused','archived',true)
on conflict (from_stage, to_stage) do update set requires_aal2 = excluded.requires_aal2;

insert into pods_provisioning.hub_stage_requirements_v1(stage_key, requirement_key, description) values
  ('build','source_linked','ProteusOps model instance exists and is not blocked, or project is imported'),
  ('staging','providers_ready','Latest provider readiness roll-up for the workspace is launch_ready'),
  ('launch_review','workspace_paid','Workspace has paid_active (includes billing grace)'),
  ('launch_review','owners_mfa_enrolled','Every owner has a verified MFA factor (at least one owner)'),
  ('launch_review','credentials_valid_live','All required live credential refs are valid (evaluator lands in H2)'),
  ('active','workspace_paid','Workspace has paid_active (includes billing grace)'),
  ('active','owners_mfa_enrolled','Every owner has a verified MFA factor (at least one owner)'),
  ('active','domain_dns_ssl_verified','Production domain binding has DNS and SSL verified (evaluator lands in H3)'),
  ('active','launch_receipt','A launch receipt exists for the project (evaluator lands in H3)'),
  ('paused','reason_recorded','A reason of at least 3 characters is recorded'),
  ('archived','reason_recorded','A reason of at least 3 characters is recorded')
on conflict (stage_key, requirement_key) do update set description = excluded.description;

-- ---------- projects ----------
create table if not exists pods_provisioning.hub_projects_v1 (
  project_id uuid primary key default gen_random_uuid(),
  org_id uuid not null references pods.orgs(org_id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 200),
  slug text not null check (slug ~ '^[a-z0-9][a-z0-9-]{0,62}$'),
  origin text not null check (origin in ('proteus_model','imported')),
  model_instance_runtime_id uuid references pods_provisioning.model_instance_runtimes_v1(model_instance_runtime_id) on delete restrict,
  current_stage text not null default 'draft' references pods_provisioning.hub_stages_v1(stage_key),
  stage_changed_at timestamptz not null default now(),
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, slug),
  constraint hub_project_origin_link_ck check (
    (origin = 'proteus_model' and model_instance_runtime_id is not null) or
    (origin = 'imported' and model_instance_runtime_id is null))
);
create index if not exists hub_projects_v1_org_idx on pods_provisioning.hub_projects_v1(org_id);

create table if not exists pods_provisioning.hub_stage_transitions_v1 (
  transition_id uuid primary key default gen_random_uuid(),
  project_id uuid not null references pods_provisioning.hub_projects_v1(project_id) on delete cascade,
  org_id uuid not null,
  from_stage text not null,
  to_stage text not null,
  decision text not null check (decision in ('allowed','refused')),
  evaluation jsonb not null,
  reason text,
  actor_user_id uuid,
  created_at timestamptz not null default now()
);
create index if not exists hub_stage_transitions_v1_project_idx on pods_provisioning.hub_stage_transitions_v1(project_id, created_at desc);

alter table pods_provisioning.hub_stages_v1             enable row level security;
alter table pods_provisioning.hub_stage_edges_v1        enable row level security;
alter table pods_provisioning.hub_stage_requirements_v1 enable row level security;
alter table pods_provisioning.hub_projects_v1           enable row level security;
alter table pods_provisioning.hub_stage_transitions_v1  enable row level security;
revoke all on pods_provisioning.hub_stages_v1, pods_provisioning.hub_stage_edges_v1,
  pods_provisioning.hub_stage_requirements_v1, pods_provisioning.hub_projects_v1,
  pods_provisioning.hub_stage_transitions_v1 from anon, authenticated;

-- ---------- authorization ----------
-- Returns the caller's org role, 'system' for trusted backend callers (no JWT claims / service_role).
create or replace function pods_provisioning._hub_authorize_v1(p_org_id uuid, p_roles text[])
returns text language plpgsql stable security definer set search_path = pods_provisioning, pods, public as $fn$
declare v jsonb; v_role text;
begin
  v := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  if v is null or (v->>'role') = 'service_role' then return 'system'; end if;
  perform pods_core.require_authenticated();
  v_role := pods.org_role(p_org_id);
  if v_role is null then raise exception 'NOT_ORG_MEMBER' using errcode = '42501'; end if;
  if not (v_role = any(p_roles)) then raise exception 'FORBIDDEN_ROLE' using errcode = '42501'; end if;
  return v_role;
end $fn$;

-- ---------- requirement evaluators ----------
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
    else
      v_ok := false; v_detail := 'not yet verifiable (evaluator pending) - fails closed';
  end case;
  return jsonb_build_object('key', p_requirement_key, 'ok', v_ok, 'detail', v_detail);
end $fn$;

create or replace function pods_provisioning._hub_evaluate_v1(p_project_id uuid, p_target_stage text, p_reason text)
returns jsonb language plpgsql stable security definer set search_path = pods_provisioning, pods, public as $fn$
declare p pods_provisioning.hub_projects_v1%rowtype; e pods_provisioning.hub_stage_edges_v1%rowtype;
  v_reqs jsonb := '[]'::jsonb; v_all boolean := true; r record; v_res jsonb;
begin
  select * into p from pods_provisioning.hub_projects_v1 where project_id = p_project_id;
  if not found then raise exception 'HUB_PROJECT_NOT_FOUND'; end if;
  select * into e from pods_provisioning.hub_stage_edges_v1 where from_stage = p.current_stage and to_stage = p_target_stage;
  for r in select requirement_key from pods_provisioning.hub_stage_requirements_v1
            where stage_key = p_target_stage and active order by requirement_key loop
    v_res := pods_provisioning._hub_eval_requirement_v1(p_project_id, r.requirement_key, p_reason);
    v_reqs := v_reqs || v_res;
    v_all := v_all and (v_res->>'ok')::boolean;
  end loop;
  return jsonb_build_object('project_id', p_project_id, 'org_id', p.org_id, 'from_stage', p.current_stage,
    'to_stage', p_target_stage, 'edge_allowed', e.from_stage is not null, 'requires_aal2', coalesce(e.requires_aal2,false),
    'requirements', v_reqs, 'allowed', (e.from_stage is not null) and v_all);
end $fn$;

-- ---------- client RPCs ----------
create or replace function pods_provisioning.rpc_hub_project_create_v1(
  p_org_id uuid, p_name text, p_slug text, p_origin text, p_model_instance_runtime_id uuid default null)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare v_role text; v_id uuid; v_n int;
begin
  v_role := pods_provisioning._hub_authorize_v1(p_org_id, array['owner','admin']);
  if p_model_instance_runtime_id is not null then
    select count(*) into v_n from pods_provisioning.model_instance_runtimes_v1
     where model_instance_runtime_id = p_model_instance_runtime_id and org_id = p_org_id;
    if v_n = 0 then raise exception 'HUB_MODEL_INSTANCE_NOT_IN_WORKSPACE' using errcode = '42501'; end if;
  end if;
  insert into pods_provisioning.hub_projects_v1(org_id, name, slug, origin, model_instance_runtime_id, created_by)
  values (p_org_id, p_name, p_slug, p_origin, p_model_instance_runtime_id, auth.uid())
  returning project_id into v_id;
  insert into pods.audit_log(org_id, actor_user_id, actor_role_key, action_key, entity_table, entity_id, details)
  values (p_org_id, auth.uid(), v_role, 'hub.project_create', 'hub_projects_v1', v_id::text,
          jsonb_build_object('slug', p_slug, 'origin', p_origin));
  return jsonb_build_object('project_id', v_id, 'stage', 'draft');
end $fn$;

create or replace function pods_provisioning.rpc_hub_projects_list_v1(p_org_id uuid)
returns jsonb language plpgsql stable security definer set search_path = pods_provisioning, pods, public as $fn$
begin
  perform pods_provisioning._hub_authorize_v1(p_org_id, array['owner','admin','staff']);
  return coalesce((select jsonb_agg(jsonb_build_object('project_id', project_id, 'name', name, 'slug', slug,
            'origin', origin, 'stage', current_stage, 'stage_changed_at', stage_changed_at) order by created_at)
          from pods_provisioning.hub_projects_v1 where org_id = p_org_id), '[]'::jsonb);
end $fn$;

create or replace function pods_provisioning.rpc_hub_evaluate_gate_v1(p_project_id uuid, p_target_stage text, p_reason text default null)
returns jsonb language plpgsql stable security definer set search_path = pods_provisioning, pods, public as $fn$
declare v_org uuid;
begin
  select org_id into v_org from pods_provisioning.hub_projects_v1 where project_id = p_project_id;
  if v_org is null then raise exception 'HUB_PROJECT_NOT_FOUND'; end if;
  perform pods_provisioning._hub_authorize_v1(v_org, array['owner','admin','staff']);
  return pods_provisioning._hub_evaluate_v1(p_project_id, p_target_stage, p_reason);
end $fn$;

create or replace function pods_provisioning.rpc_hub_transition_v1(p_project_id uuid, p_target_stage text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare v_org uuid; v_role text; v_eval jsonb; v_allowed boolean;
begin
  select org_id into v_org from pods_provisioning.hub_projects_v1 where project_id = p_project_id for update;
  if v_org is null then raise exception 'HUB_PROJECT_NOT_FOUND'; end if;
  v_role := pods_provisioning._hub_authorize_v1(v_org, array['owner','admin']);
  v_eval := pods_provisioning._hub_evaluate_v1(p_project_id, p_target_stage, p_reason);
  if (v_eval->>'requires_aal2')::boolean then perform pods_core.require_aal2(); end if;
  v_allowed := (v_eval->>'allowed')::boolean;

  insert into pods_provisioning.hub_stage_transitions_v1(project_id, org_id, from_stage, to_stage, decision, evaluation, reason, actor_user_id)
  values (p_project_id, v_org, v_eval->>'from_stage', p_target_stage,
          case when v_allowed then 'allowed' else 'refused' end, v_eval, p_reason, auth.uid());
  if v_allowed then
    update pods_provisioning.hub_projects_v1
       set current_stage = p_target_stage, stage_changed_at = now(), updated_at = now()
     where project_id = p_project_id;
  end if;
  insert into pods.audit_log(org_id, actor_user_id, actor_role_key, action_key, entity_table, entity_id, details)
  values (v_org, auth.uid(), v_role, case when v_allowed then 'hub.stage_transition' else 'hub.stage_transition_refused' end,
          'hub_projects_v1', p_project_id::text, v_eval);
  return v_eval;
end $fn$;

revoke all on function pods_provisioning._hub_authorize_v1(uuid,text[]) from public, anon, authenticated;
revoke all on function pods_provisioning._hub_eval_requirement_v1(uuid,text,text) from public, anon, authenticated;
revoke all on function pods_provisioning._hub_evaluate_v1(uuid,text,text) from public, anon, authenticated;
revoke all on function pods_provisioning.rpc_hub_project_create_v1(uuid,text,text,text,uuid) from public, anon;
revoke all on function pods_provisioning.rpc_hub_projects_list_v1(uuid) from public, anon;
revoke all on function pods_provisioning.rpc_hub_evaluate_gate_v1(uuid,text,text) from public, anon;
revoke all on function pods_provisioning.rpc_hub_transition_v1(uuid,text,text) from public, anon;

-- public wrappers (PostgREST exposes public only); authenticated + service_role, never anon
create or replace function public.rpc_hub_project_create_v1(p_org_id uuid, p_name text, p_slug text, p_origin text, p_model_instance_runtime_id uuid default null)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_project_create_v1(p_org_id, p_name, p_slug, p_origin, p_model_instance_runtime_id) $fn$;
create or replace function public.rpc_hub_projects_list_v1(p_org_id uuid)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_projects_list_v1(p_org_id) $fn$;
create or replace function public.rpc_hub_evaluate_gate_v1(p_project_id uuid, p_target_stage text, p_reason text default null)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_evaluate_gate_v1(p_project_id, p_target_stage, p_reason) $fn$;
create or replace function public.rpc_hub_transition_v1(p_project_id uuid, p_target_stage text, p_reason text default null)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_transition_v1(p_project_id, p_target_stage, p_reason) $fn$;
revoke all on function public.rpc_hub_project_create_v1(uuid,text,text,text,uuid) from public, anon;
revoke all on function public.rpc_hub_projects_list_v1(uuid) from public, anon;
revoke all on function public.rpc_hub_evaluate_gate_v1(uuid,text,text) from public, anon;
revoke all on function public.rpc_hub_transition_v1(uuid,text,text) from public, anon;
grant execute on function public.rpc_hub_project_create_v1(uuid,text,text,text,uuid) to authenticated, service_role;
grant execute on function public.rpc_hub_projects_list_v1(uuid) to authenticated, service_role;
grant execute on function public.rpc_hub_evaluate_gate_v1(uuid,text,text) to authenticated, service_role;
grant execute on function public.rpc_hub_transition_v1(uuid,text,text) to authenticated, service_role;

-- ---------- selftest ----------
create or replace function pods_provisioning.rpc_selftest_hub_lifecycle_v1()
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare v_org uuid; v_org2 uuid; v_sfx text := replace(gen_random_uuid()::text,'-','');
  u_owner uuid := gen_random_uuid(); u_staff uuid := gen_random_uuid(); u_out uuid := gen_random_uuid();
  v_proj uuid; r jsonb; v_stage text; v_n int;
  t_create bool := false; t_bad_origin bool := false; t_draft_build bool := false; t_skip_refused bool := false;
  t_staging_refused bool := false; t_refusal_recorded bool := false; t_staff_blocked bool := false;
  t_outsider_blocked bool := false; t_anon_blocked bool := false; t_aal1_blocked bool := false;
  t_mfa_gate bool := false; t_pending_fail_closed bool := false; t_archive_needs_reason bool := false;
  t_archive_ok bool := false; t_audit bool := false; t_rls bool := false; v_ok bool;
begin
  insert into pods.orgs(slug, name) values ('selftest-hub-'||v_sfx, 'selftest hub') returning org_id into v_org;
  insert into pods.orgs(slug, name) values ('selftest-hub2-'||v_sfx, 'selftest hub other') returning org_id into v_org2;
  insert into pods.org_members(org_id, user_id, role_key) values (v_org, u_owner, 'owner'), (v_org, u_staff, 'staff'), (v_org2, u_out, 'owner');

  -- owner (aal1) creates an imported project
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_owner,'aal','aal1')::text, true);
  r := public.rpc_hub_project_create_v1(v_org, 'Selftest site', 'selftest-site', 'imported', null);
  v_proj := (r->>'project_id')::uuid; t_create := v_proj is not null and r->>'stage' = 'draft';

  begin perform public.rpc_hub_project_create_v1(v_org, 'Bad', 'bad-origin', 'proteus_model', null);
  exception when others then t_bad_origin := true; end;

  r := public.rpc_hub_transition_v1(v_proj, 'build', null);
  t_draft_build := (r->>'allowed')::boolean;

  r := public.rpc_hub_transition_v1(v_proj, 'active', null);           -- no build->active edge
  t_skip_refused := not (r->>'allowed')::boolean and not (r->>'edge_allowed')::boolean;

  r := public.rpc_hub_transition_v1(v_proj, 'staging', null);          -- no provider readiness
  t_staging_refused := not (r->>'allowed')::boolean and (r->>'edge_allowed')::boolean;
  select count(*) into v_n from pods_provisioning.hub_stage_transitions_v1 where project_id = v_proj and decision = 'refused';
  t_refusal_recorded := v_n = 2;

  -- staff can read, not transition
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_staff,'aal','aal2')::text, true);
  begin perform public.rpc_hub_transition_v1(v_proj, 'draft', null); exception when others then t_staff_blocked := true; end;
  t_staff_blocked := t_staff_blocked and jsonb_array_length(public.rpc_hub_projects_list_v1(v_org)) = 1;

  -- owner of another workspace cannot read or evaluate
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_out,'aal','aal2')::text, true);
  begin perform public.rpc_hub_projects_list_v1(v_org); exception when others then t_outsider_blocked := true; end;

  -- anon cannot call even through the function body
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  begin perform pods_provisioning.rpc_hub_projects_list_v1(v_org); exception when others then t_anon_blocked := true; end;
  t_anon_blocked := t_anon_blocked and not has_function_privilege('anon','public.rpc_hub_projects_list_v1(uuid)','execute');

  -- aal2-gated edge: force project to staging as system, then owner at aal1 is blocked
  perform set_config('request.jwt.claims', '', true);
  update pods_provisioning.hub_projects_v1 set current_stage = 'staging' where project_id = v_proj;
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_owner,'aal','aal1')::text, true);
  begin perform public.rpc_hub_transition_v1(v_proj, 'launch_review', null); exception when others then t_aal1_blocked := sqlerrm like '%MFA_REQUIRED%'; end;

  -- owner at aal2: launch_review refused because owner has no verified MFA factor + unpaid + pending evaluator
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_owner,'aal','aal2')::text, true);
  r := public.rpc_hub_transition_v1(v_proj, 'launch_review', null);
  t_mfa_gate := not (r->>'allowed')::boolean and exists (select 1 from jsonb_array_elements(r->'requirements') x
                  where x->>'key' = 'owners_mfa_enrolled' and not (x->>'ok')::boolean);
  t_pending_fail_closed := exists (select 1 from jsonb_array_elements(r->'requirements') x
                  where x->>'key' = 'credentials_valid_live' and not (x->>'ok')::boolean);

  r := public.rpc_hub_transition_v1(v_proj, 'archived', '');
  t_archive_needs_reason := not (r->>'allowed')::boolean;
  r := public.rpc_hub_transition_v1(v_proj, 'archived', 'selftest retire');
  select current_stage into v_stage from pods_provisioning.hub_projects_v1 where project_id = v_proj;
  t_archive_ok := (r->>'allowed')::boolean and v_stage = 'archived';
  perform set_config('request.jwt.claims', '', true);

  select count(*) into v_n from pods.audit_log where org_id = v_org and action_key like 'hub.%';
  t_audit := v_n >= 7;
  select bool_and(c.relrowsecurity) into t_rls from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'pods_provisioning' and c.relname like 'hub\_%' and c.relkind = 'r';

  delete from pods.audit_log where org_id in (v_org, v_org2);
  delete from pods.orgs where org_id in (v_org, v_org2);

  v_ok := t_create and t_bad_origin and t_draft_build and t_skip_refused and t_staging_refused and t_refusal_recorded
      and t_staff_blocked and t_outsider_blocked and t_anon_blocked and t_aal1_blocked and t_mfa_gate
      and t_pending_fail_closed and t_archive_needs_reason and t_archive_ok and t_audit and coalesce(t_rls,false);
  return jsonb_build_object('ok', v_ok,
    'token', case when v_ok then 'PROTEUSOPS_HUB_LIFECYCLE_OK' else 'PROTEUSOPS_HUB_LIFECYCLE_FAIL' end,
    'create', t_create, 'origin_link_enforced', t_bad_origin, 'draft_to_build', t_draft_build,
    'stage_skip_refused', t_skip_refused, 'staging_needs_providers', t_staging_refused,
    'refusals_recorded', t_refusal_recorded, 'staff_read_only', t_staff_blocked, 'cross_workspace_blocked', t_outsider_blocked,
    'anon_blocked', t_anon_blocked, 'aal1_blocked_on_mfa_edge', t_aal1_blocked, 'owner_mfa_gate', t_mfa_gate,
    'pending_evaluator_fails_closed', t_pending_fail_closed, 'archive_needs_reason', t_archive_needs_reason,
    'archive_with_reason', t_archive_ok, 'audited', t_audit, 'rls_on', t_rls);
end $fn$;
revoke all on function pods_provisioning.rpc_selftest_hub_lifecycle_v1() from public, anon, authenticated;

select pods_provisioning.rpc_selftest_hub_lifecycle_v1();
