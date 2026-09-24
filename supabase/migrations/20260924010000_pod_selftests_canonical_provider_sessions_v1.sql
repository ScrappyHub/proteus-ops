-- Pod selftests: align with the canonical provider path.
-- rpc_provider_readiness_rollup_v1 / rpc_provider_connection_rollup_v1 count ONLY verified provider
-- connection sessions that hold a secret:// reference. Several older selftests still prepared orgs via the
-- legacy adapter-runtime verifiers alone (and one omitted the required 'storage' provider), so they could
-- never reach 'ready'. Production logic is unchanged; only selftest fixtures are corrected.

create or replace function pods_provisioning._selftest_connect_providers_v1(p_org_id uuid, p_providers text[])
returns void
language plpgsql
set search_path to 'pods_provisioning', 'public'
as $f$
declare
  v_provider text;
  v_session jsonb;
begin
  if p_org_id is null then
    raise exception 'SELFTEST_CONNECT_ORG_REQUIRED';
  end if;
  foreach v_provider in array p_providers loop
    v_session := pods_provisioning.rpc_start_provider_connection_session_v1(p_org_id, v_provider, null);
    perform pods_provisioning.rpc_complete_provider_connection_session_v1(
      (v_session->>'provider_connection_session_id')::uuid,
      'acct_selftest_' || v_provider,
      'project_selftest_' || v_provider,
      'secret://proteusops/selftest/' || v_provider,
      jsonb_build_array(jsonb_build_object('resource_key','provider','value',v_provider)),
      jsonb_build_array(jsonb_build_object('check_key','verified','status','pass'))
    );
  end loop;
end;
$f$;

revoke all on function pods_provisioning._selftest_connect_providers_v1(uuid, text[]) from public, anon, authenticated;
grant execute on function pods_provisioning._selftest_connect_providers_v1(uuid, text[]) to service_role;

CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_customer_deployment_handoff_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_full_green jsonb;
  v_rollup jsonb;
  v_handoff jsonb;
begin
  v_full_green := pods_provisioning.rpc_selftest_full_green_engine_registry_v1();

  if v_full_green->>'platform_status' <> 'FULL_GREEN' then
    raise exception 'CUSTOMER_HANDOFF_FULL_GREEN_DEPENDENCY_FAIL';
  end if;

  perform pods_provisioning.rpc_verify_supabase_adapter_runtime_v1(
    v_org_id,
    'handoff-project-ref',
    'https://handoff-project-ref.supabase.co',
    true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_stripe_adapter_runtime_v1(
    v_org_id,
    'acct_handoff',
    'test',
    true,true,true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_email_adapter_runtime_v1(
    v_org_id,
    'resend',
    'handoff.example.com',
    true,true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_storage_adapter_runtime_v1(
    v_org_id,
    'supabase_storage',
    'handoff_downloads',
    true,true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_github_adapter_runtime_v1(
    v_org_id,
    'example',
    'handoff-runtime',
    'https://github.com/example/handoff-runtime',
    true,true,true,true,true,null
  );

  perform pods_provisioning._selftest_connect_providers_v1(v_org_id, array['supabase','stripe','github','email','storage']);

  v_rollup := pods_provisioning.rpc_provider_readiness_rollup_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    'v1'
  );

  if v_rollup->>'readiness_status' <> 'ready' then
    raise exception 'CUSTOMER_HANDOFF_PROVIDER_READY_FAIL';
  end if;

  v_handoff := pods_provisioning.rpc_emit_customer_deployment_handoff_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    'v1'
  );

  if v_handoff->>'token' <> 'PROTEUSOPS_CUSTOMER_DEPLOYMENT_HANDOFF_OK' then
    raise exception 'CUSTOMER_HANDOFF_TOKEN_FAIL';
  end if;

  if v_handoff->>'handoff_status' <> 'ready' then
    raise exception 'CUSTOMER_HANDOFF_STATUS_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_CUSTOMER_DEPLOYMENT_HANDOFF_OK',
    'org_id', v_org_id,
    'handoff', v_handoff
  );
end;
$$;

CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_launch_control_plane_receipt_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();

  v_seed jsonb;
  v_wizard jsonb;
  v_plan jsonb;
  v_deploy jsonb;
  v_rollup jsonb;
  v_receipt jsonb;
begin
  v_seed := pods_provisioning.rpc_seed_developer_portal_model_v1();

  v_wizard := pods_provisioning.rpc_start_operator_setup_wizard_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    jsonb_build_object(
      'product_name','Control Plane Product',
      'github_url','https://github.com/example/control-plane',
      'download_url','https://example.com/downloads/control-plane',
      'support_email','support@example.com'
    )
  );

  v_plan := pods_provisioning.rpc_plan_model_capabilities_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    jsonb_build_object(
      'product_name','Control Plane Product',
      'github_url','https://github.com/example/control-plane',
      'download_url','https://example.com/downloads/control-plane',
      'support_email','support@example.com'
    )
  );

  v_deploy := pods_provisioning.rpc_create_model_deployment_receipt_v1(
    (v_plan->>'plan_run_id')::uuid
  );

  perform pods_provisioning.rpc_verify_supabase_adapter_runtime_v1(
    v_org_id,
    'control-plane-project-ref',
    'https://control-plane-project-ref.supabase.co',
    true,
    true,
    true,
    true,
    null
  );

  perform pods_provisioning.rpc_verify_stripe_adapter_runtime_v1(
    v_org_id,
    'acct_control_plane',
    'test',
    true,
    true,
    true,
    true,
    true,
    true,
    null
  );

  perform pods_provisioning.rpc_verify_email_adapter_runtime_v1(
    v_org_id,
    'resend',
    'control.example.com',
    true,
    true,
    true,
    true,
    true,
    null
  );

  perform pods_provisioning.rpc_verify_storage_adapter_runtime_v1(
    v_org_id,
    'supabase_storage',
    'control_plane_downloads',
    true,
    true,
    true,
    true,
    true,
    null
  );

  perform pods_provisioning.rpc_verify_github_adapter_runtime_v1(
    v_org_id,
    'example',
    'control-plane',
    'https://github.com/example/control-plane',
    true,
    true,
    true,
    true,
    true,
    null
  );

  perform pods_provisioning._selftest_connect_providers_v1(v_org_id, array['supabase','stripe','github','email','storage']);

  v_rollup := pods_provisioning.rpc_provider_readiness_rollup_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    'v1'
  );

  if v_rollup->>'readiness_status' <> 'ready' then
    raise exception 'LAUNCH_CONTROL_READINESS_NOT_READY';
  end if;

  v_receipt := pods_provisioning.rpc_emit_launch_control_plane_receipt_v1(
    v_org_id,
    (v_wizard->>'wizard_session_id')::uuid,
    (v_plan->>'plan_run_id')::uuid,
    (v_deploy->>'deployment_receipt_id')::uuid,
    (v_rollup->>'provider_readiness_rollup_id')::uuid
  );

  if v_receipt->>'token' <> 'PROTEUSOPS_LAUNCH_CONTROL_PLANE_RECEIPT_OK' then
    raise exception 'LAUNCH_CONTROL_RECEIPT_TOKEN_FAIL';
  end if;

  if v_receipt->>'launch_decision' <> 'ready' then
    raise exception 'LAUNCH_CONTROL_DECISION_NOT_READY';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_LAUNCH_CONTROL_PLANE_RECEIPT_OK',
    'org_id', v_org_id,
    'wizard', v_wizard,
    'deployment_receipt', v_deploy,
    'provider_readiness', v_rollup,
    'launch_control_receipt', v_receipt
  );
end;
$$;

CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_launch_execution_worker_runtime_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();

  v_seed jsonb;
  v_wizard jsonb;
  v_plan jsonb;
  v_deploy jsonb;
  v_rollup jsonb;
  v_control jsonb;
  v_worker jsonb;
  v_complete jsonb;

  v_duplicate_ok boolean := false;
begin
  v_seed := pods_provisioning.rpc_seed_developer_portal_model_v1();

  v_wizard := pods_provisioning.rpc_start_operator_setup_wizard_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    jsonb_build_object(
      'product_name','Worker Runtime Product',
      'github_url','https://github.com/example/worker-runtime',
      'download_url','https://example.com/downloads/worker-runtime',
      'support_email','support@example.com'
    )
  );

  v_plan := pods_provisioning.rpc_plan_model_capabilities_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    jsonb_build_object(
      'product_name','Worker Runtime Product',
      'github_url','https://github.com/example/worker-runtime',
      'download_url','https://example.com/downloads/worker-runtime',
      'support_email','support@example.com'
    )
  );

  v_deploy := pods_provisioning.rpc_create_model_deployment_receipt_v1(
    (v_plan->>'plan_run_id')::uuid
  );

  perform pods_provisioning.rpc_verify_supabase_adapter_runtime_v1(
    v_org_id,
    'worker-project-ref',
    'https://worker-project-ref.supabase.co',
    true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_stripe_adapter_runtime_v1(
    v_org_id,
    'acct_worker',
    'test',
    true,true,true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_email_adapter_runtime_v1(
    v_org_id,
    'resend',
    'worker.example.com',
    true,true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_storage_adapter_runtime_v1(
    v_org_id,
    'supabase_storage',
    'worker_downloads',
    true,true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_github_adapter_runtime_v1(
    v_org_id,
    'example',
    'worker-runtime',
    'https://github.com/example/worker-runtime',
    true,true,true,true,true,null
  );

  perform pods_provisioning._selftest_connect_providers_v1(v_org_id, array['supabase','stripe','github','email','storage']);

  v_rollup := pods_provisioning.rpc_provider_readiness_rollup_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    'v1'
  );

  v_control := pods_provisioning.rpc_emit_launch_control_plane_receipt_v1(
    v_org_id,
    (v_wizard->>'wizard_session_id')::uuid,
    (v_plan->>'plan_run_id')::uuid,
    (v_deploy->>'deployment_receipt_id')::uuid,
    (v_rollup->>'provider_readiness_rollup_id')::uuid
  );

  if v_control->>'launch_decision' <> 'ready' then
    raise exception 'LAUNCH_WORKER_CONTROL_NOT_READY';
  end if;

  v_worker := pods_provisioning.rpc_queue_launch_execution_worker_v1(
    (v_control->>'launch_control_receipt_id')::uuid
  );

  if v_worker->>'token' <> 'PROTEUSOPS_LAUNCH_EXECUTION_WORKER_OK' then
    raise exception 'LAUNCH_WORKER_QUEUE_TOKEN_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_queue_launch_execution_worker_v1(
      (v_control->>'launch_control_receipt_id')::uuid
    );
  exception
    when others then
      if sqlerrm like 'LAUNCH_WORKER_DUPLICATE_DENY:%' then
        v_duplicate_ok := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_ok then
    raise exception 'LAUNCH_WORKER_DUPLICATE_VECTOR_FAIL';
  end if;

  v_complete := pods_provisioning.rpc_complete_launch_execution_worker_v1(
    (v_worker->>'worker_run_id')::uuid
  );

  if v_complete->>'token' <> 'PROTEUSOPS_LAUNCH_EXECUTION_WORKER_COMPLETE_OK' then
    raise exception 'LAUNCH_WORKER_COMPLETE_TOKEN_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_LAUNCH_EXECUTION_WORKER_OK',
    'org_id', v_org_id,
    'launch_control_receipt', v_control,
    'worker_run', v_worker,
    'worker_completion', v_complete,
    'duplicate_denied', v_duplicate_ok
  );
end;
$$;

CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_launch_failure_and_rollback_runtime_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();

  v_seed jsonb;
  v_wizard jsonb;
  v_plan jsonb;
  v_deploy jsonb;
  v_rollup jsonb;
  v_control jsonb;
  v_worker jsonb;
  v_failure jsonb;
  v_rollback jsonb;

  v_duplicate_failure_ok boolean := false;
  v_duplicate_rollback_ok boolean := false;
begin
  v_seed := pods_provisioning.rpc_seed_developer_portal_model_v1();

  v_wizard := pods_provisioning.rpc_start_operator_setup_wizard_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    jsonb_build_object(
      'product_name','Failure Runtime Product',
      'github_url','https://github.com/example/failure-runtime',
      'download_url','https://example.com/downloads/failure-runtime',
      'support_email','support@example.com'
    )
  );

  v_plan := pods_provisioning.rpc_plan_model_capabilities_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    jsonb_build_object(
      'product_name','Failure Runtime Product',
      'github_url','https://github.com/example/failure-runtime',
      'download_url','https://example.com/downloads/failure-runtime',
      'support_email','support@example.com'
    )
  );

  v_deploy := pods_provisioning.rpc_create_model_deployment_receipt_v1(
    (v_plan->>'plan_run_id')::uuid
  );

  perform pods_provisioning.rpc_verify_supabase_adapter_runtime_v1(
    v_org_id,'failure-project-ref','https://failure-project-ref.supabase.co',true,true,true,true,null
  );
  perform pods_provisioning.rpc_verify_stripe_adapter_runtime_v1(
    v_org_id,'acct_failure','test',true,true,true,true,true,true,null
  );
  perform pods_provisioning.rpc_verify_email_adapter_runtime_v1(
    v_org_id,'resend','failure.example.com',true,true,true,true,true,null
  );
  perform pods_provisioning.rpc_verify_storage_adapter_runtime_v1(
    v_org_id,'supabase_storage','failure_downloads',true,true,true,true,true,null
  );
  perform pods_provisioning.rpc_verify_github_adapter_runtime_v1(
    v_org_id,'example','failure-runtime','https://github.com/example/failure-runtime',true,true,true,true,true,null
  );

  perform pods_provisioning._selftest_connect_providers_v1(v_org_id, array['supabase','stripe','github','email','storage']);

  v_rollup := pods_provisioning.rpc_provider_readiness_rollup_v1(
    v_org_id,'DEVELOPER_PORTAL_V1','v1'
  );

  v_control := pods_provisioning.rpc_emit_launch_control_plane_receipt_v1(
    v_org_id,
    (v_wizard->>'wizard_session_id')::uuid,
    (v_plan->>'plan_run_id')::uuid,
    (v_deploy->>'deployment_receipt_id')::uuid,
    (v_rollup->>'provider_readiness_rollup_id')::uuid
  );

  v_worker := pods_provisioning.rpc_queue_launch_execution_worker_v1(
    (v_control->>'launch_control_receipt_id')::uuid
  );

  v_failure := pods_provisioning.rpc_fail_launch_execution_worker_v1(
    (v_worker->>'worker_run_id')::uuid,
    'activate_resources',
    'Selftest simulated resource activation failure'
  );

  if v_failure->>'token' <> 'PROTEUSOPS_LAUNCH_FAILURE_RUNTIME_OK' then
    raise exception 'LAUNCH_FAILURE_TOKEN_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_fail_launch_execution_worker_v1(
      (v_worker->>'worker_run_id')::uuid,
      'activate_resources',
      'Duplicate failure'
    );
  exception
    when others then
      if sqlerrm like 'LAUNCH_FAILURE_WORKER_STATUS_INVALID:%'
        or sqlerrm like 'LAUNCH_FAILURE_DUPLICATE_DENY:%' then
        v_duplicate_failure_ok := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_failure_ok then
    raise exception 'LAUNCH_FAILURE_DUPLICATE_VECTOR_FAIL';
  end if;

  v_rollback := pods_provisioning.rpc_rollback_failed_launch_v1(
    (v_failure->>'launch_failure_event_id')::uuid
  );

  if v_rollback->>'token' <> 'PROTEUSOPS_LAUNCH_ROLLBACK_RUNTIME_OK' then
    raise exception 'LAUNCH_ROLLBACK_TOKEN_FAIL';
  end if;

  begin
    perform pods_provisioning.rpc_rollback_failed_launch_v1(
      (v_failure->>'launch_failure_event_id')::uuid
    );
  exception
    when others then
      if sqlerrm like 'LAUNCH_ROLLBACK_ALREADY_DONE:%'
        or sqlerrm like 'LAUNCH_ROLLBACK_DUPLICATE_DENY:%' then
        v_duplicate_rollback_ok := true;
      else
        raise;
      end if;
  end;

  if not v_duplicate_rollback_ok then
    raise exception 'LAUNCH_ROLLBACK_DUPLICATE_VECTOR_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_LAUNCH_FAILURE_AND_ROLLBACK_RUNTIME_OK',
    'org_id', v_org_id,
    'worker_run', v_worker,
    'failure', v_failure,
    'rollback', v_rollback,
    'duplicate_failure_denied', v_duplicate_failure_ok,
    'duplicate_rollback_denied', v_duplicate_rollback_ok
  );
end;
$$;

CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_provider_readiness_rollup_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_ready_org uuid := gen_random_uuid();
  v_blocked_org uuid := gen_random_uuid();

  v_ready_rollup jsonb;
  v_blocked_rollup jsonb;
begin
  perform pods_provisioning.rpc_verify_supabase_adapter_runtime_v1(
    v_ready_org,
    'ready-project-ref',
    'https://ready-project-ref.supabase.co',
    true,
    true,
    true,
    true,
    null
  );

  perform pods_provisioning.rpc_verify_stripe_adapter_runtime_v1(
    v_ready_org,
    'acct_ready',
    'test',
    true,
    true,
    true,
    true,
    true,
    true,
    null
  );

  perform pods_provisioning.rpc_verify_email_adapter_runtime_v1(
    v_ready_org,
    'resend',
    'ready.example.com',
    true,
    true,
    true,
    true,
    true,
    null
  );

  perform pods_provisioning.rpc_verify_storage_adapter_runtime_v1(
    v_ready_org,
    'supabase_storage',
    'ready_downloads',
    true,
    true,
    true,
    true,
    true,
    null
  );

  perform pods_provisioning.rpc_verify_github_adapter_runtime_v1(
    v_ready_org,
    'example',
    'ready-product',
    'https://github.com/example/ready-product',
    true,
    true,
    true,
    true,
    true,
    null
  );

  perform pods_provisioning._selftest_connect_providers_v1(v_ready_org, array['supabase','stripe','github','email','storage']);

  v_ready_rollup := pods_provisioning.rpc_provider_readiness_rollup_v1(
    v_ready_org,
    'DEVELOPER_PORTAL_V1',
    'v1'
  );

  if v_ready_rollup->>'token' <> 'PROTEUSOPS_PROVIDER_READINESS_ROLLUP_OK' then
    raise exception 'PROVIDER_READINESS_ROLLUP_TOKEN_FAIL';
  end if;

  if v_ready_rollup->>'readiness_status' <> 'ready' then
    raise exception 'PROVIDER_READINESS_SHOULD_BE_READY';
  end if;

  perform pods_provisioning.rpc_verify_supabase_adapter_runtime_v1(
    v_blocked_org,
    'blocked-project-ref',
    'https://blocked-project-ref.supabase.co',
    true,
    true,
    true,
    false,
    null
  );

  v_blocked_rollup := pods_provisioning.rpc_provider_readiness_rollup_v1(
    v_blocked_org,
    'DEVELOPER_PORTAL_V1',
    'v1'
  );

  if v_blocked_rollup->>'readiness_status' <> 'blocked' then
    raise exception 'PROVIDER_READINESS_SHOULD_BE_BLOCKED';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PROVIDER_READINESS_ROLLUP_OK',
    'ready_rollup', v_ready_rollup,
    'blocked_rollup', v_blocked_rollup
  );
end;
$$;

CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_security_gate_matrix_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_org_id uuid := gen_random_uuid();
  v_seed jsonb;
  v_stress jsonb;
  v_rollup jsonb;
  v_result jsonb;
begin
  v_seed := pods_provisioning.rpc_seed_security_gate_matrix_v1();

  if v_seed->>'token' <> 'PROTEUSOPS_SECURITY_GATE_MATRIX_OK' then
    raise exception 'SECURITY_GATE_SEED_FAIL';
  end if;

  v_stress := pods_provisioning.rpc_selftest_stress_harness_v1();

  if v_stress->>'token' <> 'PROTEUSOPS_STRESS_HARNESS_OK' then
    raise exception 'SECURITY_GATE_STRESS_DEPENDENCY_FAIL';
  end if;

  perform pods_provisioning.rpc_verify_supabase_adapter_runtime_v1(
    v_org_id,
    'security-project-ref',
    'https://security-project-ref.supabase.co',
    true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_stripe_adapter_runtime_v1(
    v_org_id,
    'acct_security',
    'test',
    true,true,true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_email_adapter_runtime_v1(
    v_org_id,
    'resend',
    'security.example.com',
    true,true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_storage_adapter_runtime_v1(
    v_org_id,
    'supabase_storage',
    'security_downloads',
    true,true,true,true,true,null
  );

  perform pods_provisioning.rpc_verify_github_adapter_runtime_v1(
    v_org_id,
    'example',
    'security-runtime',
    'https://github.com/example/security-runtime',
    true,true,true,true,true,null
  );

  perform pods_provisioning._selftest_connect_providers_v1(v_org_id, array['supabase','stripe','github','email','storage']);

  v_rollup := pods_provisioning.rpc_provider_readiness_rollup_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1',
    'v1'
  );

  if v_rollup->>'readiness_status' <> 'ready' then
    raise exception 'SECURITY_GATE_PROVIDER_ROLLUP_NOT_READY';
  end if;

  v_result := pods_provisioning.rpc_run_security_gate_matrix_v1(
    v_org_id,
    'DEVELOPER_PORTAL_V1'
  );

  if v_result->>'security_status' <> 'passed' then
    raise exception 'SECURITY_GATE_MATRIX_NOT_PASSED';
  end if;

  return v_result;
end;
$$;

CREATE OR REPLACE FUNCTION "pods_provisioning"."rpc_selftest_provider_connection_rollup_v1"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pods_provisioning', 'public'
    AS $$
declare
  v_ready_org uuid := gen_random_uuid();
  v_blocked_org uuid := gen_random_uuid();

  v_provider text;
  v_session jsonb;
  v_ready_rollup jsonb;
  v_blocked_rollup jsonb;
begin
  perform pods_provisioning.rpc_seed_provider_oauth_connection_contracts_v1();

  foreach v_provider in array array['supabase','stripe','github','email','storage']
  loop
    v_session := pods_provisioning.rpc_start_provider_connection_session_v1(
      v_ready_org,
      v_provider,
      null
    );

    perform pods_provisioning.rpc_complete_provider_connection_session_v1(
      (v_session->>'provider_connection_session_id')::uuid,
      'acct_' || v_provider,
      'project_' || v_provider,
      'secret://proteusops/' || v_provider || '/ready',
      jsonb_build_array(jsonb_build_object('resource_key','provider','value',v_provider)),
      jsonb_build_array(jsonb_build_object('check_key','verified','status','pass'))
    );
  end loop;

  v_ready_rollup := pods_provisioning.rpc_provider_connection_rollup_v1(
    v_ready_org,
    'DEVELOPER_PORTAL_V1',
    'v1'
  );

  if v_ready_rollup->>'token' <> 'PROTEUSOPS_PROVIDER_CONNECTION_ROLLUP_OK' then
    raise exception 'PROVIDER_CONNECTION_ROLLUP_TOKEN_FAIL';
  end if;

  if v_ready_rollup->>'connection_ready' <> 'true' then
    raise exception 'PROVIDER_CONNECTION_READY_ROLLUP_FAIL';
  end if;

  v_session := pods_provisioning.rpc_start_provider_connection_session_v1(
    v_blocked_org,
    'supabase',
    null
  );

  perform pods_provisioning.rpc_complete_provider_connection_session_v1(
    (v_session->>'provider_connection_session_id')::uuid,
    'acct_supabase',
    'project_supabase',
    'secret://proteusops/supabase/blocked-partial',
    jsonb_build_array(jsonb_build_object('resource_key','provider','value','supabase')),
    jsonb_build_array(jsonb_build_object('check_key','verified','status','pass'))
  );

  v_blocked_rollup := pods_provisioning.rpc_provider_connection_rollup_v1(
    v_blocked_org,
    'DEVELOPER_PORTAL_V1',
    'v1'
  );

  if v_blocked_rollup->>'connection_ready' <> 'false' then
    raise exception 'PROVIDER_CONNECTION_BLOCKED_ROLLUP_FAIL';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_PROVIDER_CONNECTION_ROLLUP_OK',
    'ready_rollup', v_ready_rollup,
    'blocked_rollup', v_blocked_rollup
  );
end;
$$;
