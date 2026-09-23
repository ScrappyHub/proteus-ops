-- ProteusOps slice H3b — operator path to register accounts and store secrets safely (before the dashboard exists)
-- Problem: the client credential RPC needs a signed-in owner with an MFA (aal2) session, and there is no app UI yet.
-- Pasting secrets into the Supabase SQL editor is unsafe (queries are saved in history), and secrets must never go in git.
-- Solution: two service_role-only functions called by a local operator script over TLS
-- (scripts/_SET_hub_secret_v1.ps1). The script prompts for the service key and the secret without echoing,
-- keeps them only in memory, and prints back only the credential id + fingerprint.

create or replace function pods_provisioning.svc_hub_account_ensure_v1(
  p_org_slug text, p_provider_key text, p_display_name text, p_external_ref text, p_environment text, p_operator text)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare v_org uuid; v_id uuid; v_created boolean := false;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'HUB_OPERATOR_FORBIDDEN' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_operator,''))) < 2 then raise exception 'HUB_OPERATOR_NAME_REQUIRED'; end if;
  select org_id into v_org from pods.orgs where slug = p_org_slug and is_active;
  if v_org is null then raise exception 'HUB_WORKSPACE_NOT_FOUND'; end if;
  select account_id into v_id from pods_provisioning.hub_accounts_v1
   where org_id = v_org and provider_key = lower(p_provider_key) and external_ref = coalesce(p_external_ref,'')
     and environment = coalesce(p_environment,'shared');
  if v_id is null then
    insert into pods_provisioning.hub_accounts_v1(org_id, provider_key, display_name, external_ref, environment, notes)
    values (v_org, lower(p_provider_key), p_display_name, coalesce(p_external_ref,''), coalesce(p_environment,'shared'),
            'registered by operator '||btrim(p_operator))
    returning account_id into v_id;
    v_created := true;
    insert into pods.audit_log(org_id, actor_role_key, action_key, entity_table, entity_id, details)
    values (v_org, 'operator', 'hub.account_upsert', 'hub_accounts_v1', v_id::text,
            jsonb_build_object('provider', lower(p_provider_key), 'external_ref', p_external_ref, 'operator', btrim(p_operator)));
  end if;
  return jsonb_build_object('account_id', v_id, 'org_id', v_org, 'created', v_created);
end $fn$;

create or replace function pods_provisioning.svc_hub_credential_put_v1(
  p_account_id uuid, p_purpose text, p_environment text, p_secret_value text, p_rotates_at timestamptz,
  p_justification text, p_operator text)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare a pods_provisioning.hub_accounts_v1%rowtype; c pods_provisioning.hub_credentials_v1%rowtype;
  v_id uuid := gen_random_uuid(); v_vault uuid; v_fp text; v_action text;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'HUB_OPERATOR_FORBIDDEN' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_operator,''))) < 2 then raise exception 'HUB_OPERATOR_NAME_REQUIRED'; end if;
  select * into a from pods_provisioning.hub_accounts_v1 where account_id = p_account_id;
  if not found or a.status <> 'active' then raise exception 'HUB_ACCOUNT_NOT_FOUND'; end if;
  perform pods_provisioning._hub_require_justification_v1(p_justification);
  perform pods_provisioning._hub_check_env_v1(a.environment, p_environment);
  perform pods_provisioning._hub_check_rotation_v1(p_environment, p_rotates_at);
  if p_secret_value is null or length(p_secret_value) not between 8 and 16384 then raise exception 'HUB_SECRET_VALUE_INVALID'; end if;
  v_fp := pods_provisioning._hub_fingerprint_v1(p_secret_value);

  select * into c from pods_provisioning.hub_credentials_v1
   where account_id = p_account_id and purpose = lower(p_purpose) and environment = p_environment and project_id is null
     and status <> 'revoked' for update;
  if found then
    if c.fingerprint = v_fp then raise exception 'HUB_ROTATION_SAME_VALUE'; end if;
    perform vault.update_secret(c.vault_secret_id, p_secret_value);
    update pods_provisioning.hub_credentials_v1 set fingerprint = v_fp, rotates_at = p_rotates_at, last_rotated_at = now(),
      status = 'pending_verification', status_detail = null, justification = btrim(p_justification), updated_at = now()
     where credential_id = c.credential_id;
    v_id := c.credential_id; v_action := 'hub.credential_rotate';
  else
    v_vault := vault.create_secret(p_secret_value, 'proteus/cred/'||v_id::text, 'ProteusOps credential '||v_id::text);
    insert into pods_provisioning.hub_credentials_v1(credential_id, org_id, account_id, purpose, environment, storage_kind,
      vault_secret_id, fingerprint, rotates_at, last_rotated_at, justification)
    values (v_id, a.org_id, p_account_id, lower(p_purpose), p_environment, 'vault', v_vault, v_fp, p_rotates_at, now(), btrim(p_justification));
    v_action := 'hub.credential_put';
  end if;
  insert into pods.audit_log(org_id, actor_role_key, action_key, entity_table, entity_id, details)
  values (a.org_id, 'operator', v_action, 'hub_credentials_v1', v_id::text, jsonb_build_object('account_id', p_account_id,
    'purpose', lower(p_purpose), 'environment', p_environment, 'fingerprint', v_fp, 'operator', btrim(p_operator),
    'justification', btrim(p_justification)));
  return jsonb_build_object('credential_id', v_id, 'fingerprint', v_fp, 'status', 'pending_verification',
                            'action', case when v_action = 'hub.credential_put' then 'created' else 'rotated' end);
end $fn$;

create or replace function public.svc_hub_account_ensure_v1(p_org_slug text, p_provider_key text, p_display_name text,
  p_external_ref text, p_environment text, p_operator text)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.svc_hub_account_ensure_v1(p_org_slug, p_provider_key, p_display_name, p_external_ref, p_environment, p_operator) $fn$;
create or replace function public.svc_hub_credential_put_v1(p_account_id uuid, p_purpose text, p_environment text, p_secret_value text,
  p_rotates_at timestamptz, p_justification text, p_operator text)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.svc_hub_credential_put_v1(p_account_id, p_purpose, p_environment, p_secret_value, p_rotates_at, p_justification, p_operator) $fn$;
do $$ declare s text; begin
  foreach s in array array[
    'pods_provisioning.svc_hub_account_ensure_v1(text,text,text,text,text,text)',
    'pods_provisioning.svc_hub_credential_put_v1(uuid,text,text,text,timestamp with time zone,text,text)',
    'public.svc_hub_account_ensure_v1(text,text,text,text,text,text)',
    'public.svc_hub_credential_put_v1(uuid,text,text,text,timestamp with time zone,text,text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', s);
    execute format('grant execute on function %s to service_role', s);
  end loop;
end $$;

create or replace function pods_provisioning.rpc_selftest_hub_operator_v1()
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, vault, public as $fn$
declare v_sfx text := replace(gen_random_uuid()::text,'-',''); v_org uuid; r jsonb; r2 jsonb; a1 uuid; a2 uuid; v text;
  s1 text := 'whsec_selftest_one_' || v_sfx; s2 text := 'whsec_selftest_two_' || v_sfx; v_ids uuid[];
  t_client bool := false; t_ensure bool := false; t_idem bool := false; t_put bool := false; t_rotate bool := false;
  t_same bool := false; t_plain bool := false; t_live bool := false; t_audit bool := false; t_cleanup bool := false; v_ok bool;
begin
  insert into pods.orgs(slug, name) values ('selftest-op-'||v_sfx, 'selftest operator') returning org_id into v_org;
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',gen_random_uuid(),'aal','aal2')::text, true);
  begin perform pods_provisioning.svc_hub_account_ensure_v1('selftest-op-'||v_sfx, 'github', 'x', 'x', 'shared', 'selftest');
  exception when others then t_client := sqlerrm like '%HUB_OPERATOR_FORBIDDEN%'; end;
  t_client := t_client and not has_function_privilege('authenticated','public.svc_hub_credential_put_v1(uuid,text,text,text,timestamp with time zone,text,text)','execute')
                       and not has_function_privilege('anon','public.svc_hub_account_ensure_v1(text,text,text,text,text,text)','execute');
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  r := public.svc_hub_account_ensure_v1('selftest-op-'||v_sfx, 'GitHub', 'Acme GitHub', 'acme', 'shared', 'selftest');
  a1 := (r->>'account_id')::uuid; t_ensure := a1 is not null and (r->>'created')::boolean;
  r := public.svc_hub_account_ensure_v1('selftest-op-'||v_sfx, 'github', 'Acme GitHub', 'acme', 'shared', 'selftest');
  t_idem := (r->>'account_id')::uuid = a1 and not (r->>'created')::boolean;
  r := public.svc_hub_credential_put_v1(a1, 'webhook', 'test', s1, now() + interval '90 days', 'GitHub webhook signing secret', 'selftest');
  t_put := r->>'action' = 'created';
  begin perform public.svc_hub_credential_put_v1(a1, 'webhook', 'test', s1, now() + interval '90 days', 'same value again', 'selftest');
  exception when others then t_same := sqlerrm like '%HUB_ROTATION_SAME_VALUE%'; end;
  r2 := public.svc_hub_credential_put_v1(a1, 'webhook', 'test', s2, now() + interval '90 days', 'rotating the webhook secret', 'selftest');
  t_rotate := r2->>'action' = 'rotated' and r2->>'credential_id' = r->>'credential_id' and r2->>'fingerprint' <> r->>'fingerprint'
          and (select count(*) from pods_provisioning.hub_credentials_v1 where account_id = a1) = 1
          and public.svc_hub_credential_secret_v1((r2->>'credential_id')::uuid, 'selftest') = s2;
  a2 := (public.svc_hub_account_ensure_v1('selftest-op-'||v_sfx, 'aws', 'Prod', '111', 'live', 'selftest')->>'account_id')::uuid;
  begin perform public.svc_hub_credential_put_v1(a2, 'api', 'live', s1, null, 'live key without rotation date', 'selftest');
  exception when others then t_live := sqlerrm like '%HUB_ROTATION_REQUIRED%'; end;
  perform set_config('request.jwt.claims', '', true);
  t_plain := not exists (select 1 from pods_provisioning.hub_credentials_v1 c where c::text like '%selftest_one_%' or c::text like '%selftest_two_%')
         and not exists (select 1 from pods.audit_log l where l.org_id = v_org and (l.details::text like '%'||s1||'%' or l.details::text like '%'||s2||'%'));
  t_audit := (select count(*) from pods.audit_log where org_id = v_org and actor_role_key = 'operator'
              and action_key in ('hub.account_upsert','hub.credential_put','hub.credential_rotate')) = 4;
  select array_agg(vault_secret_id) into v_ids from pods_provisioning.hub_credentials_v1 where org_id = v_org;
  delete from pods.audit_log where org_id = v_org;
  delete from pods.orgs where org_id = v_org;
  t_cleanup := not exists (select 1 from vault.secrets where id = any(v_ids));
  v_ok := t_client and t_ensure and t_idem and t_put and t_same and t_rotate and t_live and t_plain and t_audit and t_cleanup;
  return jsonb_build_object('ok', v_ok, 'token', case when v_ok then 'PROTEUSOPS_HUB_OPERATOR_OK' else 'PROTEUSOPS_HUB_OPERATOR_FAIL' end,
    'clients_blocked', t_client, 'ensure_account', t_ensure, 'ensure_idempotent', t_idem, 'put', t_put, 'same_value_refused', t_same,
    'rerun_rotates', t_rotate, 'live_needs_rotation', t_live, 'no_plaintext', t_plain, 'audited_as_operator', t_audit,
    'vault_cleaned', t_cleanup);
end $fn$;
revoke all on function pods_provisioning.rpc_selftest_hub_operator_v1() from public, anon, authenticated;

select pods_provisioning.rpc_selftest_hub_operator_v1();
