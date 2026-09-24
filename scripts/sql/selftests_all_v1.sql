\pset pager off
\echo :::SECURITY:::
select pods_core.rpc_selftest_api_surface_v1();
select pods.rpc_selftest_billing_integrity_v1();
select pods_provisioning.rpc_selftest_hub_structure_v1();
select pods_provisioning.rpc_selftest_hub_credentials_v1();
select pods_provisioning.rpc_selftest_hub_feed_v1();
select pods_provisioning.rpc_selftest_hub_operator_v1();
select pods_provisioning.rpc_selftest_hub_feed_urls_v1();
select pods_provisioning.rpc_selftest_hub_pod_link_v1();
\echo :::ALL_TOKENS:::
select t from (values
  (pods_core.rpc_selftest_api_surface_v1()->>'token'),
  (pods.rpc_selftest_billing_integrity_v1()->>'token'),
  (pods_provisioning.rpc_selftest_hub_structure_v1()->>'token'),
  (pods_provisioning.rpc_selftest_hub_credentials_v1()->>'token'),
  (pods_provisioning.rpc_selftest_hub_feed_v1()->>'token'),
  (pods_provisioning.rpc_selftest_hub_operator_v1()->>'token'),
  (pods_provisioning.rpc_selftest_hub_feed_urls_v1()->>'token'),
  (pods.rpc_selftest_no_unbacked_trials_v1()->>'token'),
  (pods.rpc_selftest_billing_grace_v1()->>'token'),
  (pods_provisioning.rpc_selftest_hub_lifecycle_v1()->>'token'),
  (pods_provisioning.rpc_selftest_hub_pod_link_v1()->>'token'),
  (pods.rpc_selftest_subscription_lapse_v1()->>'token'),
  (pods.rpc_selftest_entitlement_overrides_v1()->>'token'),
  (pods_provisioning.rpc_selftest_stripe_ingest_wrappers_v1()->>'token'),
  (pods_provisioning.rpc_selftest_one_time_entitlement_v1()->>'token'),
  (pods_provisioning.rpc_selftest_payment_idempotency_v1()->>'token'),
  (pods_core.rpc_selftest_rls_fail_closed_v1()->>'token'),
  (pods_core.rpc_selftest_session_assurance_v1()->>'token'),
  (pods_provisioning.rpc_verify_authority_bindings_v1()->>'token'),
  (case when (pods_provisioning.rpc_verify_platform_constitution_v1()->>'ok')::boolean
        then 'PROTEUSOPS_PLATFORM_CONSTITUTION_OK' else 'PROTEUSOPS_PLATFORM_CONSTITUTION_FAIL' end)
) v(t);
