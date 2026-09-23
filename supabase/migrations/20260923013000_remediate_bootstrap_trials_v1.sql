-- ProteusOps remediation R1 — cancel unbacked bootstrap trials created through the C1 path (operator-approved 2026-09-23)
-- Rows with provider_subscription_id 'bootstrap_<org>' were written by the old rpc_create_org_bootstrap(plan_id)
-- and have no Stripe subscription behind them. They are marked canceled (kept for history), entitlements are
-- recomputed, and each change is audited. Hosted at time of writing: 1 row (workspace demo-barber).
do $$ declare r record; begin
  for r in select org_id, provider_subscription_id, plan_id, status from pods.subscriptions
            where provider_subscription_id like 'bootstrap\_%' and status <> 'canceled' loop
    update pods.subscriptions set status = 'canceled', updated_at = now(), past_due_since = null
     where provider_subscription_id = r.provider_subscription_id;
    perform pods.rpc_recompute_entitlements(r.org_id);
    insert into pods.audit_log(org_id, actor_role_key, action_key, details)
    values (r.org_id, 'system', 'billing.remediate_unbacked_trial', jsonb_build_object(
      'subscription_id', r.provider_subscription_id, 'plan_id', r.plan_id, 'previous_status', r.status,
      'reason', 'SECURITY_AUDIT_2026-09-22_v2 C1a: trial self-granted via org bootstrap, no Stripe backing'));
  end loop;
end $$;

create or replace function pods.rpc_selftest_no_unbacked_trials_v1()
returns jsonb language plpgsql stable security definer set search_path = pods, public as $fn$
declare v_n int;
begin
  select count(*) into v_n from pods.subscriptions where provider_subscription_id like 'bootstrap\_%' and status <> 'canceled';
  return jsonb_build_object('ok', v_n = 0, 'token', case when v_n = 0 then 'PROTEUSOPS_NO_UNBACKED_TRIALS_OK' else 'PROTEUSOPS_NO_UNBACKED_TRIALS_FAIL' end,
    'unbacked_active', v_n);
end $fn$;
revoke all on function pods.rpc_selftest_no_unbacked_trials_v1() from public, anon, authenticated;
select pods.rpc_selftest_no_unbacked_trials_v1();
