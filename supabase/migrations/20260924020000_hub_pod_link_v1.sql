-- ProteusOps slice H4 — link the Workspace Hub to the deployment pods.
--  * One hub project per model instance (unique link).
--  * Launch-gate evaluators that were failing closed now evaluate real evidence:
--      domain_dns_ssl_verified : pod domain bindings (model projects) | provider-DISCOVERED live domain resources (imported)
--      launch_receipt          : latest pod launch receipt is a completed launch (model) | owner launch attestation (imported)
--  * Pod events (launch/suspend/archive, domain attach/verify/fail) flow into the hub change feed for linked projects.
--  * rpc_hub_project_pod_status_v1: one read of a project's deployment-pod state (members only).
--  * rpc_hub_launch_attest_v1 / rpc_hub_launch_attestation_revoke_v1: owner-only, MFA (aal2), justified, hashed, audited.
-- RLS on, no client table grants; internal functions service_role-only; public wrappers authenticated-only (allowlisted).

-- ---------- one project per model instance ----------
do $$ begin
  if exists (select 1 from pods_provisioning.hub_projects_v1 where model_instance_runtime_id is not null
              group by model_instance_runtime_id having count(*) > 1) then
    raise exception 'HUB_POD_LINK_PRECONDITION: more than one hub project links the same model instance; resolve before applying';
  end if;
end $$;
create unique index if not exists hub_projects_v1_instance_uq
  on pods_provisioning.hub_projects_v1(model_instance_runtime_id) where model_instance_runtime_id is not null;

-- ---------- imported-project launch attestations ----------
create table if not exists pods_provisioning.hub_launch_attestations_v1 (
  attestation_id uuid primary key default gen_random_uuid(),
  org_id uuid not null references pods.orgs(org_id) on delete cascade,
  project_id uuid not null references pods_provisioning.hub_projects_v1(project_id) on delete cascade,
  evidence_url text not null check (length(evidence_url) <= 1000 and evidence_url ~ '^https://\S+$'),
  justification text not null check (length(btrim(justification)) between 10 and 2000),
  attestation_hash text not null check (attestation_hash ~ '^[a-f0-9]{64}$'),
  attested_by uuid,
  attested_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_by uuid,
  revoke_reason text check (revoke_reason is null or length(btrim(revoke_reason)) between 3 and 2000)
);
create index if not exists hub_launch_attestations_v1_project_idx on pods_provisioning.hub_launch_attestations_v1(project_id, attested_at desc);
alter table pods_provisioning.hub_launch_attestations_v1 enable row level security;
revoke all on pods_provisioning.hub_launch_attestations_v1 from anon, authenticated;

-- ---------- requirement evaluator (all prior keys unchanged; two pending keys now evaluated) ----------
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
    when 'domain_dns_ssl_verified' then
      if p.origin = 'proteus_model' then
        -- pod path: the linked model instance has >=1 domain binding with DNS verified + SSL active, and none failed/blocked
        select count(*) filter (where b.dns_status = 'verified' and b.ssl_status = 'active' and b.binding_status = 'verified'),
               count(*) filter (where b.dns_status = 'failed' or b.ssl_status = 'failed' or b.binding_status = 'blocked')
          into v_n, v_bad
          from pods_provisioning.domain_runtime_bindings_v1 b
         where b.model_instance_runtime_id = p.model_instance_runtime_id and b.org_id = p.org_id;
        v_ok := v_n > 0 and v_bad = 0;
        v_detail := format('%s verified domain binding(s), %s failed/blocked', v_n, v_bad);
      else
        -- imported path: a LIVE domain resource on this project reported by provider discovery (never manual entry)
        select count(*) into v_n from pods_provisioning.hub_resources_v1 r
         where r.project_id = p_project_id and r.kind = 'domain' and r.environment = 'live' and r.status = 'active'
           and r.source = 'discovery' and r.attributes->>'dns_status' = 'verified' and r.attributes->>'ssl_status' = 'active';
        v_ok := v_n > 0;
        v_detail := case when v_ok then format('%s provider-verified live domain(s)', v_n)
                         else 'no provider-discovered live domain with DNS verified and SSL active (manual entries do not count)' end;
      end if;
    when 'launch_receipt' then
      if p.origin = 'proteus_model' then
        -- pod path: a completed 'launch' receipt exists for the instance AND its launch authority is still 'launched'
        -- and the instance is still 'launched' (a later suspend/archive flips these, so the evidence is revoked)
        select count(*) into v_n
          from pods_provisioning.model_launch_receipts_v1 r
          join pods_provisioning.model_launch_authorities_v1 a on a.model_launch_authority_id = r.model_launch_authority_id
          join pods_provisioning.model_instance_runtimes_v1 i on i.model_instance_runtime_id = r.model_instance_runtime_id
         where r.model_instance_runtime_id = p.model_instance_runtime_id and r.org_id = p.org_id
           and r.launch_action = 'launch' and r.launch_result = 'completed'
           and a.launch_state = 'launched' and i.instance_status = 'launched' and i.org_id = p.org_id;
        v_ok := v_n > 0;
        v_detail := case when v_ok then 'completed pod launch receipt; site currently launched'
                         else 'no current pod launch (never launched, or suspended/archived since)' end;
      else
        select count(*) into v_n from pods_provisioning.hub_launch_attestations_v1 a
         where a.project_id = p_project_id and a.revoked_at is null;
        v_ok := v_n > 0;
        v_detail := case when v_ok then 'owner launch attestation on record' else 'no unrevoked owner launch attestation (imported projects)' end;
      end if;
    else
      v_ok := false; v_detail := 'not yet verifiable (evaluator pending) - fails closed';
  end case;
  return jsonb_build_object('key', p_requirement_key, 'ok', v_ok, 'detail', v_detail);
end $fn$;

-- ---------- pod -> hub change feed ----------
create or replace function pods_provisioning._hub_pod_launch_event_trg_v1()
returns trigger language plpgsql security definer set search_path = pods_provisioning, public as $fn$
declare r record;
begin
  for r in select project_id, org_id, current_stage from pods_provisioning.hub_projects_v1
            where model_instance_runtime_id = new.model_instance_runtime_id and org_id = new.org_id loop
    perform pods_provisioning._hub_system_event_v1(r.org_id, r.project_id, 'pod.' || new.launch_action,
      case when new.launch_action = 'launch' then 'notice'
           when r.current_stage = 'active' then 'critical' else 'warning' end,
      format('Deployment pod %s: %s', new.launch_action, new.launch_result),
      jsonb_build_object('model_launch_receipt_id', new.model_launch_receipt_id, 'launch_result', new.launch_result,
                         'receipt_hash', new.receipt_hash));
  end loop;
  return new;
end $fn$;
drop trigger if exists hub_pod_launch_event on pods_provisioning.model_launch_receipts_v1;
create trigger hub_pod_launch_event after insert on pods_provisioning.model_launch_receipts_v1
  for each row execute function pods_provisioning._hub_pod_launch_event_trg_v1();

create or replace function pods_provisioning._hub_pod_domain_event_trg_v1()
returns trigger language plpgsql security definer set search_path = pods_provisioning, public as $fn$
declare r record; v_type text; v_sev text; v_now_ok boolean; v_was_ok boolean; v_failed boolean;
begin
  v_now_ok := new.dns_status = 'verified' and new.ssl_status = 'active' and new.binding_status = 'verified';
  v_failed := new.dns_status = 'failed' or new.ssl_status = 'failed' or new.binding_status = 'blocked';
  if tg_op = 'INSERT' then
    v_type := 'pod.domain.attached'; v_sev := 'info';
  else
    v_was_ok := old.dns_status = 'verified' and old.ssl_status = 'active' and old.binding_status = 'verified';
    if v_failed and not (old.dns_status = 'failed' or old.ssl_status = 'failed' or old.binding_status = 'blocked') then
      v_type := 'pod.domain.failed'; v_sev := 'warning';
    elsif v_now_ok and not v_was_ok then
      v_type := 'pod.domain.verified'; v_sev := 'notice';
    else
      return new;
    end if;
  end if;
  for r in select project_id, org_id, current_stage from pods_provisioning.hub_projects_v1
            where model_instance_runtime_id = new.model_instance_runtime_id and org_id = new.org_id loop
    perform pods_provisioning._hub_system_event_v1(r.org_id, r.project_id, v_type,
      case when v_type = 'pod.domain.failed' and r.current_stage = 'active' then 'critical' else v_sev end,
      format('Domain %s: %s (dns %s, ssl %s)', replace(v_type, 'pod.domain.', ''), new.domain_name, new.dns_status, new.ssl_status),
      jsonb_build_object('domain_runtime_binding_id', new.domain_runtime_binding_id, 'domain', new.domain_name,
                         'dns_status', new.dns_status, 'ssl_status', new.ssl_status, 'binding_status', new.binding_status));
  end loop;
  return new;
end $fn$;
drop trigger if exists hub_pod_domain_event on pods_provisioning.domain_runtime_bindings_v1;
create trigger hub_pod_domain_event after insert or update on pods_provisioning.domain_runtime_bindings_v1
  for each row execute function pods_provisioning._hub_pod_domain_event_trg_v1();

-- ---------- member RPCs ----------
create or replace function pods_provisioning.rpc_hub_project_pod_status_v1(p_project_id uuid)
returns jsonb language plpgsql stable security definer set search_path = pods_provisioning, pods, public as $fn$
declare p pods_provisioning.hub_projects_v1%rowtype; v_inst jsonb; v_launch jsonb; v_domains jsonb; v_ready jsonb;
  v_control jsonb; v_attest jsonb; v_next text;
begin
  select * into p from pods_provisioning.hub_projects_v1 where project_id = p_project_id;
  if not found then raise exception 'HUB_PROJECT_NOT_FOUND'; end if;
  perform pods_provisioning._hub_authorize_v1(p.org_id, array['owner','admin','staff']);

  if p.origin = 'proteus_model' then
    select jsonb_build_object('model_instance_runtime_id', i.model_instance_runtime_id, 'model_key', i.model_key,
             'model_version', i.model_version, 'instance_name', i.instance_name, 'instance_status', i.instance_status,
             'launchable', i.launchable, 'created_at', i.created_at)
      into v_inst from pods_provisioning.model_instance_runtimes_v1 i
     where i.model_instance_runtime_id = p.model_instance_runtime_id and i.org_id = p.org_id;
    select coalesce(jsonb_agg(jsonb_build_object('action', r.launch_action, 'result', r.launch_result,
             'receipt_hash', r.receipt_hash, 'at', r.created_at) order by r.created_at desc), '[]'::jsonb)
      into v_launch from (select * from pods_provisioning.model_launch_receipts_v1
                           where model_instance_runtime_id = p.model_instance_runtime_id and org_id = p.org_id
                           order by created_at desc limit 20) r;
    select coalesce(jsonb_agg(jsonb_build_object('domain', b.domain_name, 'provider', b.provider_key,
             'binding_status', b.binding_status, 'dns_status', b.dns_status, 'ssl_status', b.ssl_status, 'at', b.created_at)
             order by b.created_at), '[]'::jsonb)
      into v_domains from pods_provisioning.domain_runtime_bindings_v1 b
     where b.model_instance_runtime_id = p.model_instance_runtime_id and b.org_id = p.org_id;
    select jsonb_build_object('launch_decision', c.launch_decision, 'launch_ready', c.launch_ready,
             'blocked_reasons', c.blocked_reasons, 'at', c.created_at)
      into v_control from pods_provisioning.launch_control_plane_receipts_v1 c
     where c.org_id = p.org_id and c.model_key = v_inst->>'model_key'
     order by c.created_at desc limit 1;
  else
    select coalesce(jsonb_agg(jsonb_build_object('domain', r.display_name, 'environment', r.environment, 'status', r.status,
             'source', r.source, 'dns_status', r.attributes->>'dns_status', 'ssl_status', r.attributes->>'ssl_status',
             'last_seen_at', r.last_seen_at) order by r.display_name), '[]'::jsonb)
      into v_domains from pods_provisioning.hub_resources_v1 r
     where r.project_id = p_project_id and r.kind = 'domain' and r.status <> 'archived';
    select coalesce(jsonb_agg(jsonb_build_object('attestation_id', a.attestation_id, 'evidence_url', a.evidence_url,
             'justification', a.justification, 'attestation_hash', a.attestation_hash, 'attested_at', a.attested_at,
             'revoked_at', a.revoked_at, 'revoke_reason', a.revoke_reason) order by a.attested_at desc), '[]'::jsonb)
      into v_attest from pods_provisioning.hub_launch_attestations_v1 a where a.project_id = p_project_id;
  end if;

  select jsonb_build_object('launch_ready', r.launch_ready, 'readiness_status', r.readiness_status,
           'blocked_providers', r.blocked_providers, 'at', r.created_at)
    into v_ready from pods_provisioning.provider_readiness_rollups_v1 r
   where r.org_id = p.org_id order by r.created_at desc limit 1;

  select e.to_stage into v_next from pods_provisioning.hub_stage_edges_v1 e
    join pods_provisioning.hub_stages_v1 s on s.stage_key = e.to_stage
   where e.from_stage = p.current_stage and e.to_stage not in ('paused','archived')
     and s.ordinal > (select ordinal from pods_provisioning.hub_stages_v1 where stage_key = p.current_stage)
   order by s.ordinal limit 1;

  return jsonb_build_object('project_id', p.project_id, 'org_id', p.org_id, 'name', p.name, 'origin', p.origin,
    'stage', p.current_stage, 'instance', v_inst, 'launch_receipts', coalesce(v_launch, '[]'::jsonb),
    'domains', coalesce(v_domains, '[]'::jsonb), 'launch_attestations', coalesce(v_attest, '[]'::jsonb),
    'provider_readiness', v_ready, 'launch_control', v_control, 'next_stage', v_next,
    'next_stage_gate', case when v_next is null then null else pods_provisioning._hub_evaluate_v1(p_project_id, v_next, null) end);
end $fn$;

create or replace function pods_provisioning.rpc_hub_launch_attest_v1(p_project_id uuid, p_evidence_url text, p_justification text)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare p pods_provisioning.hub_projects_v1%rowtype; v_role text; v_id uuid; v_hash text; v_url text := btrim(coalesce(p_evidence_url,''));
begin
  select * into p from pods_provisioning.hub_projects_v1 where project_id = p_project_id for update;
  if not found then raise exception 'HUB_PROJECT_NOT_FOUND'; end if;
  v_role := pods_provisioning._hub_authorize_v1(p.org_id, array['owner']);
  perform pods_core.require_aal2();
  if p.origin <> 'imported' then raise exception 'HUB_ATTEST_MODEL_PROJECT_USES_POD_RECEIPT'; end if;
  if p.current_stage not in ('launch_review','active') then raise exception 'HUB_ATTEST_STAGE_INVALID:%', p.current_stage; end if;
  perform pods_provisioning._hub_require_justification_v1(p_justification);
  if length(btrim(p_justification)) > 2000 then raise exception 'HUB_JUSTIFICATION_TOO_LONG'; end if;
  if length(v_url) > 1000 or v_url !~ '^https://\S+$' then raise exception 'HUB_ATTEST_EVIDENCE_URL_INVALID'; end if;
  if pods_provisioning._hub_text_looks_secret_v1(v_url) or pods_provisioning._hub_text_looks_secret_v1(p_justification) then
    raise exception 'HUB_ATTEST_LOOKS_SECRET';
  end if;
  v_hash := pods_provisioning._sha256_text_v1(jsonb_build_object('project_id', p_project_id, 'evidence_url', v_url,
              'justification', btrim(p_justification), 'actor', auth.uid(), 'at', clock_timestamp())::text);
  insert into pods_provisioning.hub_launch_attestations_v1(org_id, project_id, evidence_url, justification, attestation_hash, attested_by)
  values (p.org_id, p_project_id, v_url, btrim(p_justification), v_hash, auth.uid()) returning attestation_id into v_id;
  perform pods_provisioning._hub_audit_v1(p.org_id, v_role, 'hub.launch_attest', 'hub_launch_attestations_v1', v_id::text,
    jsonb_build_object('project_id', p_project_id, 'attestation_hash', v_hash));
  perform pods_provisioning._hub_system_event_v1(p.org_id, p_project_id, 'launch.attested', 'notice',
    'Owner attested launch for imported project', jsonb_build_object('attestation_id', v_id, 'attestation_hash', v_hash));
  return jsonb_build_object('attestation_id', v_id, 'attestation_hash', v_hash);
end $fn$;

create or replace function pods_provisioning.rpc_hub_launch_attestation_revoke_v1(p_attestation_id uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare a pods_provisioning.hub_launch_attestations_v1%rowtype; v_role text;
begin
  select * into a from pods_provisioning.hub_launch_attestations_v1 where attestation_id = p_attestation_id for update;
  if not found then raise exception 'HUB_ATTESTATION_NOT_FOUND'; end if;
  v_role := pods_provisioning._hub_authorize_v1(a.org_id, array['owner']);
  perform pods_core.require_aal2();
  if a.revoked_at is not null then raise exception 'HUB_ATTESTATION_ALREADY_REVOKED'; end if;
  if length(btrim(coalesce(p_reason,''))) < 3 then raise exception 'HUB_REASON_REQUIRED'; end if;
  update pods_provisioning.hub_launch_attestations_v1
     set revoked_at = now(), revoked_by = auth.uid(), revoke_reason = left(btrim(p_reason), 2000)
   where attestation_id = p_attestation_id;
  perform pods_provisioning._hub_audit_v1(a.org_id, v_role, 'hub.launch_attest_revoke', 'hub_launch_attestations_v1',
    a.attestation_id::text, jsonb_build_object('project_id', a.project_id));
  perform pods_provisioning._hub_system_event_v1(a.org_id, a.project_id, 'launch.attestation_revoked', 'warning',
    'Launch attestation revoked', jsonb_build_object('attestation_id', a.attestation_id));
  return jsonb_build_object('attestation_id', a.attestation_id, 'revoked', true);
end $fn$;

-- ---------- public wrappers ----------
create or replace function public.rpc_hub_project_pod_status_v1(p_project_id uuid)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_project_pod_status_v1(p_project_id) $fn$;
create or replace function public.rpc_hub_launch_attest_v1(p_project_id uuid, p_evidence_url text, p_justification text)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_launch_attest_v1(p_project_id, p_evidence_url, p_justification) $fn$;
create or replace function public.rpc_hub_launch_attestation_revoke_v1(p_attestation_id uuid, p_reason text)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_launch_attestation_revoke_v1(p_attestation_id, p_reason) $fn$;

-- ---------- grants ----------
do $$ declare s text; begin
  foreach s in array array[
    'pods_provisioning._hub_eval_requirement_v1(uuid,text,text)',
    'pods_provisioning._hub_pod_launch_event_trg_v1()', 'pods_provisioning._hub_pod_domain_event_trg_v1()',
    'pods_provisioning.rpc_hub_project_pod_status_v1(uuid)', 'pods_provisioning.rpc_hub_launch_attest_v1(uuid,text,text)',
    'pods_provisioning.rpc_hub_launch_attestation_revoke_v1(uuid,text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', s);
    execute format('grant execute on function %s to service_role', s);
  end loop;
  foreach s in array array['public.rpc_hub_project_pod_status_v1(uuid)', 'public.rpc_hub_launch_attest_v1(uuid,text,text)',
    'public.rpc_hub_launch_attestation_revoke_v1(uuid,text)'] loop
    execute format('revoke all on function %s from public, anon', s);
    execute format('grant execute on function %s to authenticated, service_role', s);
  end loop;
end $$;

do $$ declare v text[]; begin
  v := pods_core.api_client_allowlist_v1() || array[
    'public.rpc_hub_project_pod_status_v1(uuid)', 'public.rpc_hub_launch_attest_v1(uuid,text,text)',
    'public.rpc_hub_launch_attestation_revoke_v1(uuid,text)'];
  execute format($f$create or replace function pods_core.api_client_allowlist_v1() returns text[] language sql immutable
    set search_path = pods_core, public as $b$ select %L::text[] $b$ $f$, (select array_agg(distinct x order by x) from unnest(v) x));
end $$;
revoke all on function pods_core.api_client_allowlist_v1() from public, anon, authenticated;

-- ---------- selftest ----------
create or replace function pods_provisioning.rpc_selftest_hub_pod_link_v1()
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare v_org uuid; v_org2 uuid; v_sfx text := replace(gen_random_uuid()::text,'-','');
  u_owner uuid := gen_random_uuid(); u_admin uuid := gen_random_uuid(); u_staff uuid := gen_random_uuid(); u_out uuid := gen_random_uuid();
  v_install jsonb; v_inst uuid; v_pkg uuid; v_auth uuid; v_proj uuid; v_imp uuid; v_bind uuid; v_acct uuid; v_att uuid;
  r jsonb; v_n int; v_ok boolean;
  t_link bool := false; t_unique bool := false; t_cross bool := false;
  t_dom_pending bool := false; t_dom_dns_only bool := false; t_dom_ok bool := false; t_dom_event bool := false;
  t_launch_pending bool := false; t_launch_ok bool := false; t_launch_event bool := false;
  t_suspend_revokes bool := false; t_suspend_event bool := false;
  t_status_staff bool := false; t_status_outsider bool := false; t_anon bool := false;
  t_att_aal1 bool := false; t_att_admin bool := false; t_att_stage bool := false; t_att_model bool := false;
  t_att_short bool := false; t_att_url bool := false; t_att_ok bool := false; t_att_revoke bool := false;
  t_imp_dom_manual bool := false; t_imp_dom_disc bool := false; t_rls bool := false; t_allow bool := false;
begin
  insert into pods.orgs(slug, name) values ('selftest-podlink-'||v_sfx, 'selftest pod link') returning org_id into v_org;
  insert into pods.orgs(slug, name) values ('selftest-podlink2-'||v_sfx, 'selftest pod link other') returning org_id into v_org2;
  insert into pods.org_members(org_id, user_id, role_key) values
    (v_org, u_owner, 'owner'), (v_org, u_admin, 'admin'), (v_org, u_staff, 'staff'), (v_org2, u_out, 'owner');

  -- a real deployment-pod instance in this workspace (system path)
  perform set_config('request.jwt.claims', '', true);
  v_install := pods_provisioning.rpc_install_marketplace_model_v1(v_org, 'CIVIC_ACTION_V1', 'v2', jsonb_build_object(
    'issue_title','Pod Link Civic Site','community_name','Link Borough','location_label','Link Corridor','position_type','oppose',
    'issue_summary','Hub pod link selftest.','petition_goal',1000,'enable_petition',true,'enable_survey',true,'enable_events',true,
    'enable_evidence',true,'enable_volunteers',true,'moderation_required',true));
  v_inst := (v_install->>'model_instance_runtime_id')::uuid;
  v_pkg := (v_install->>'model_launch_package_id')::uuid;

  -- owner links a hub project to the instance; a second link and a cross-workspace link are refused
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_owner,'aal','aal1')::text, true);
  r := public.rpc_hub_node_create_v2(v_org, 'Pod site', 'pod-site', 'proteus_model', v_inst, null, 'project', 'linked to pod');
  v_proj := (r->>'project_id')::uuid; t_link := v_proj is not null;
  begin perform public.rpc_hub_node_create_v2(v_org, 'Dup', 'pod-site-dup', 'proteus_model', v_inst, null, 'project', '');
  exception when unique_violation then t_unique := true; end;
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_out,'aal','aal2')::text, true);
  begin perform public.rpc_hub_node_create_v2(v_org2, 'Steal', 'steal', 'proteus_model', v_inst, null, 'project', '');
  exception when others then t_cross := sqlerrm like '%HUB_MODEL_INSTANCE_NOT_IN_WORKSPACE%'; end;

  -- gates fail closed before evidence exists
  perform set_config('request.jwt.claims', '', true);
  r := pods_provisioning._hub_eval_requirement_v1(v_proj, 'domain_dns_ssl_verified', null);
  t_dom_pending := not (r->>'ok')::boolean;
  r := pods_provisioning._hub_eval_requirement_v1(v_proj, 'launch_receipt', null);
  t_launch_pending := not (r->>'ok')::boolean;

  -- domain through the pod path: attach -> dns -> ssl
  perform pods_provisioning.rpc_connect_domain_provider_v1(v_org, 'cloudflare', 'cf_selftest_account');
  r := pods_provisioning.rpc_attach_domain_to_runtime_v1(v_inst, 'podlink-'||left(v_sfx,12)||'.test', 'cloudflare');
  v_bind := (r->>'domain_runtime_binding_id')::uuid;
  perform pods_provisioning.rpc_verify_domain_dns_v1(v_bind);
  r := pods_provisioning._hub_eval_requirement_v1(v_proj, 'domain_dns_ssl_verified', null);
  t_dom_dns_only := not (r->>'ok')::boolean;
  perform pods_provisioning.rpc_verify_domain_ssl_v1(v_bind);
  r := pods_provisioning._hub_eval_requirement_v1(v_proj, 'domain_dns_ssl_verified', null);
  t_dom_ok := (r->>'ok')::boolean;
  select count(*) into v_n from pods_provisioning.hub_change_events_v1 where project_id = v_proj and change_type = 'pod.domain.verified';
  t_dom_event := v_n = 1;

  -- launch through the pod path: readiness -> review -> launch
  r := pods_provisioning.rpc_check_launch_readiness_v1(v_pkg, 'proteusops_hosted');
  v_auth := (r->>'model_launch_authority_id')::uuid;
  perform pods_provisioning.rpc_submit_launch_review_v1(v_auth, 'approved', 'Hub pod link selftest approval.');
  perform pods_provisioning.rpc_launch_site_v1(v_auth);
  r := pods_provisioning._hub_eval_requirement_v1(v_proj, 'launch_receipt', null);
  t_launch_ok := (r->>'ok')::boolean;
  select count(*) into v_n from pods_provisioning.hub_change_events_v1 where project_id = v_proj and change_type = 'pod.launch';
  t_launch_event := v_n = 1;

  -- suspension revokes the launch evidence and raises an event
  perform pods_provisioning.rpc_suspend_site_v1(v_auth, 'Hub pod link selftest suspension.');
  r := pods_provisioning._hub_eval_requirement_v1(v_proj, 'launch_receipt', null);
  t_suspend_revokes := not (r->>'ok')::boolean;
  select count(*) into v_n from pods_provisioning.hub_change_events_v1
   where project_id = v_proj and change_type = 'pod.suspend' and severity in ('warning','critical');
  t_suspend_event := v_n = 1;

  -- pod status: staff can read, outsider cannot; anon and direct internal calls have no execute
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_staff,'aal','aal1')::text, true);
  r := public.rpc_hub_project_pod_status_v1(v_proj);
  t_status_staff := r->'instance'->>'model_instance_runtime_id' = v_inst::text and jsonb_array_length(r->'domains') = 1
                    and jsonb_array_length(r->'launch_receipts') = 2 and r->>'next_stage' = 'build';
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_out,'aal','aal2')::text, true);
  begin perform public.rpc_hub_project_pod_status_v1(v_proj); exception when others then t_status_outsider := true; end;
  t_anon := not has_function_privilege('anon', 'public.rpc_hub_project_pod_status_v1(uuid)', 'execute')
        and not has_function_privilege('anon', 'public.rpc_hub_launch_attest_v1(uuid,text,text)', 'execute')
        and not has_function_privilege('authenticated', 'pods_provisioning.rpc_hub_launch_attest_v1(uuid,text,text)', 'execute');

  -- imported project: attestation rules
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_owner,'aal','aal1')::text, true);
  r := public.rpc_hub_node_create_v2(v_org, 'Imported site', 'imported-site', 'imported', null, null, 'project', '');
  v_imp := (r->>'project_id')::uuid;
  begin perform public.rpc_hub_launch_attest_v1(v_imp, 'https://example.com/launch', 'Launched per runbook step 9');
  exception when others then t_att_aal1 := sqlerrm like '%MFA_REQUIRED%'; end;
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_admin,'aal','aal2')::text, true);
  begin perform public.rpc_hub_launch_attest_v1(v_imp, 'https://example.com/launch', 'Launched per runbook step 9');
  exception when others then t_att_admin := sqlerrm like '%FORBIDDEN_ROLE%'; end;
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_owner,'aal','aal2')::text, true);
  begin perform public.rpc_hub_launch_attest_v1(v_imp, 'https://example.com/launch', 'Launched per runbook step 9');
  exception when others then t_att_stage := sqlerrm like '%HUB_ATTEST_STAGE_INVALID%'; end;
  begin perform public.rpc_hub_launch_attest_v1(v_proj, 'https://example.com/launch', 'Launched per runbook step 9');
  exception when others then t_att_model := sqlerrm like '%HUB_ATTEST_MODEL_PROJECT_USES_POD_RECEIPT%'; end;
  perform set_config('request.jwt.claims', '', true);
  update pods_provisioning.hub_projects_v1 set current_stage = 'launch_review' where project_id = v_imp;
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_owner,'aal','aal2')::text, true);
  begin perform public.rpc_hub_launch_attest_v1(v_imp, 'https://example.com/launch', 'short');
  exception when others then t_att_short := sqlerrm like '%HUB_JUSTIFICATION_REQUIRED%'; end;
  begin perform public.rpc_hub_launch_attest_v1(v_imp, 'http://example.com/launch', 'Launched per runbook step 9');
  exception when others then t_att_url := sqlerrm like '%HUB_ATTEST_EVIDENCE_URL_INVALID%'; end;
  r := public.rpc_hub_launch_attest_v1(v_imp, 'https://example.com/launch', 'Launched per runbook step 9');
  v_att := (r->>'attestation_id')::uuid;
  perform set_config('request.jwt.claims', '', true);
  r := pods_provisioning._hub_eval_requirement_v1(v_imp, 'launch_receipt', null);
  t_att_ok := v_att is not null and (r->>'ok')::boolean;
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_owner,'aal','aal2')::text, true);
  perform public.rpc_hub_launch_attestation_revoke_v1(v_att, 'selftest revoke');
  perform set_config('request.jwt.claims', '', true);
  r := pods_provisioning._hub_eval_requirement_v1(v_imp, 'launch_receipt', null);
  t_att_revoke := not (r->>'ok')::boolean;

  -- imported domain: a manual entry never satisfies the gate; provider discovery does
  insert into pods_provisioning.hub_accounts_v1(org_id, provider_key, display_name, external_ref, environment)
  values (v_org, 'cloudflare', 'selftest cf', 'cf-selftest', 'live') returning account_id into v_acct;
  insert into pods_provisioning.hub_resources_v1(org_id, account_id, project_id, kind, external_id, display_name, environment, source, attributes)
  values (v_org, v_acct, v_imp, 'domain', 'manual.example.test', 'manual.example.test', 'live', 'manual',
          jsonb_build_object('dns_status','verified','ssl_status','active'));
  r := pods_provisioning._hub_eval_requirement_v1(v_imp, 'domain_dns_ssl_verified', null);
  t_imp_dom_manual := not (r->>'ok')::boolean;
  insert into pods_provisioning.hub_resources_v1(org_id, account_id, project_id, kind, external_id, display_name, environment, source, attributes)
  values (v_org, v_acct, v_imp, 'domain', 'disc.example.test', 'disc.example.test', 'live', 'discovery',
          jsonb_build_object('dns_status','verified','ssl_status','active'));
  r := pods_provisioning._hub_eval_requirement_v1(v_imp, 'domain_dns_ssl_verified', null);
  t_imp_dom_disc := (r->>'ok')::boolean;

  select c.relrowsecurity into t_rls from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'pods_provisioning' and c.relname = 'hub_launch_attestations_v1';
  t_allow := 'public.rpc_hub_project_pod_status_v1(uuid)' = any(pods_core.api_client_allowlist_v1());

  delete from pods.audit_log where org_id in (v_org, v_org2);
  delete from pods.orgs where org_id in (v_org, v_org2);

  v_ok := t_link and t_unique and t_cross and t_dom_pending and t_dom_dns_only and t_dom_ok and t_dom_event
      and t_launch_pending and t_launch_ok and t_launch_event and t_suspend_revokes and t_suspend_event
      and t_status_staff and t_status_outsider and t_anon and t_att_aal1 and t_att_admin and t_att_stage and t_att_model
      and t_att_short and t_att_url and t_att_ok and t_att_revoke and t_imp_dom_manual and t_imp_dom_disc
      and coalesce(t_rls,false) and t_allow;
  return jsonb_build_object('ok', v_ok,
    'token', case when v_ok then 'PROTEUSOPS_HUB_POD_LINK_OK' else 'PROTEUSOPS_HUB_POD_LINK_FAIL' end,
    'link', t_link, 'one_project_per_instance', t_unique, 'cross_workspace_link_blocked', t_cross,
    'domain_gate_fails_closed', t_dom_pending, 'dns_only_not_enough', t_dom_dns_only, 'domain_gate_passes', t_dom_ok,
    'domain_event', t_dom_event, 'launch_gate_fails_closed', t_launch_pending, 'launch_gate_passes', t_launch_ok,
    'launch_event', t_launch_event, 'suspend_revokes_launch', t_suspend_revokes, 'suspend_event', t_suspend_event,
    'status_staff_read', t_status_staff, 'status_outsider_blocked', t_status_outsider, 'anon_and_direct_blocked', t_anon,
    'attest_needs_mfa', t_att_aal1, 'attest_owner_only', t_att_admin, 'attest_stage_checked', t_att_stage,
    'attest_imported_only', t_att_model, 'attest_needs_justification', t_att_short, 'attest_https_only', t_att_url,
    'attest_satisfies_gate', t_att_ok, 'attest_revoke_reopens_gate', t_att_revoke,
    'imported_manual_domain_rejected', t_imp_dom_manual, 'imported_discovered_domain_accepted', t_imp_dom_disc,
    'rls_on', t_rls, 'allowlisted', t_allow);
end $fn$;
revoke all on function pods_provisioning.rpc_selftest_hub_pod_link_v1() from public, anon, authenticated;
grant execute on function pods_provisioning.rpc_selftest_hub_pod_link_v1() to service_role;
