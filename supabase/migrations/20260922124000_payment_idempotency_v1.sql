-- ProteusOps slice 4 — payment event idempotency guard
-- payment_provider_receipts_v1 already enforces UNIQUE(provider_key, provider_event_id);
-- payment_events_v1 did not, so a replayed Stripe webhook could double-process an event.
-- Add a PARTIAL unique index (only for real provider event ids; internal events use '').
-- Authority separation: Stripe signals "payment happened"; entitlement is computed in the DB
-- (pods.rpc_recompute_entitlements). Verified events reach the DB only via the service-role
-- edge function (supabase/functions/stripe-webhook) — see docs/proposals/PAYMENTS_STRIPE_RUNBOOK_v1.md.
create unique index if not exists payment_events_provider_event_uak
  on pods_provisioning.payment_events_v1 (provider_key, provider_event_id)
  where provider_event_id <> '';

create or replace function pods_provisioning.rpc_selftest_payment_idempotency_v1()
returns jsonb language plpgsql
security definer set search_path = pods_provisioning, pods, public as $fn$
declare v_events_idx int; v_receipts_uc int;
begin
  select count(*) into v_events_idx
    from pg_indexes
    where schemaname='pods_provisioning' and tablename='payment_events_v1'
      and indexdef ilike '%unique%' and indexdef ilike '%provider_event_id%';
  select count(*) into v_receipts_uc
    from pg_constraint where conname='provider_receipt_unique';
  if v_events_idx >= 1 and v_receipts_uc >= 1 then
    return jsonb_build_object('ok',true,'token','PROTEUSOPS_PAYMENT_IDEMPOTENCY_OK',
      'events_unique_index',v_events_idx,'receipts_unique_constraint',v_receipts_uc);
  end if;
  return jsonb_build_object('ok',false,'token','PROTEUSOPS_PAYMENT_IDEMPOTENCY_FAIL',
    'events_unique_index',v_events_idx,'receipts_unique_constraint',v_receipts_uc);
end $fn$;

select pods_provisioning.rpc_selftest_payment_idempotency_v1();
