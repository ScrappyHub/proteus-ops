-- ProteusOps slice 6 — one-time purchase entitlement (idempotent grant)
-- Subscriptions already flow through pods.rpc_billing_ingest_webhook. One-time purchases
-- grant a durable capability via pods.entitlement_overrides, made idempotent by recording
-- the provider payment id. Verified events reach this only via the service-role edge function.
create table if not exists pods_provisioning.one_time_purchase_receipts_v1 (
  one_time_purchase_receipt_id uuid primary key default gen_random_uuid(),
  org_id uuid not null,
  provider_key text not null default 'stripe',
  provider_payment_id text not null,
  capability_key text not null,
  value_type text not null default 'bool',
  value_bool boolean, value_int bigint, value_text text,
  event jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint one_time_receipt_value_type_ck check (value_type in ('bool','int','text')),
  constraint one_time_receipt_unique unique (provider_key, provider_payment_id)
);
alter table pods_provisioning.one_time_purchase_receipts_v1 enable row level security;

create or replace function pods.rpc_grant_one_time_entitlement_v1(
  p_org_id uuid, p_provider_key text, p_provider_payment_id text,
  p_capability_key text, p_value_type text,
  p_value_bool boolean, p_value_int bigint, p_value_text text, p_event jsonb
) returns jsonb language plpgsql
security definer set search_path = pods, pods_provisioning, public as $fn$
declare v_rows int; v_new boolean;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'ONE_TIME_GRANT_FORBIDDEN'; end if;
  insert into pods_provisioning.one_time_purchase_receipts_v1(
    org_id, provider_key, provider_payment_id, capability_key, value_type, value_bool, value_int, value_text, event)
  values (p_org_id, coalesce(p_provider_key,'stripe'), p_provider_payment_id, p_capability_key,
          coalesce(p_value_type,'bool'), p_value_bool, p_value_int, p_value_text, coalesce(p_event,'{}'::jsonb))
  on conflict (provider_key, provider_payment_id) do nothing;
  get diagnostics v_rows = row_count; v_new := v_rows > 0;
  if v_new then
    if exists (select 1 from pods.entitlement_overrides where org_id=p_org_id and capability_key=p_capability_key) then
      update pods.entitlement_overrides
        set value_type=coalesce(p_value_type,'bool'), value_bool=p_value_bool, value_int=p_value_int,
            value_text=p_value_text, reason='one_time_purchase:'||p_provider_payment_id
        where org_id=p_org_id and capability_key=p_capability_key;
    else
      insert into pods.entitlement_overrides(org_id, capability_key, value_type, value_bool, value_int, value_text, reason)
      values (p_org_id, p_capability_key, coalesce(p_value_type,'bool'), p_value_bool, p_value_int, p_value_text,
              'one_time_purchase:'||p_provider_payment_id);
    end if;
    perform pods.rpc_recompute_entitlements(p_org_id);
    insert into pods.audit_log(org_id, actor_user_id, actor_role_key, action_key, details)
    values (p_org_id, null, 'system', 'entitlement.one_time_grant',
      jsonb_build_object('capability_key',p_capability_key,'payment_id',p_provider_payment_id,'event',coalesce(p_event,'{}'::jsonb)));
  end if;
  return jsonb_build_object('ok',true,'granted',v_new,'org_id',p_org_id,'capability_key',p_capability_key);
end $fn$;

create or replace function pods_provisioning.rpc_selftest_one_time_entitlement_v1()
returns jsonb language plpgsql
security definer set search_path = pods_provisioning, pods, public as $fn$
declare v_fn int; v_uq int; v_rls boolean;
begin
  select count(*) into v_fn from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='pods' and p.proname='rpc_grant_one_time_entitlement_v1';
  select count(*) into v_uq from pg_constraint where conname='one_time_receipt_unique';
  select c.relrowsecurity into v_rls from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='pods_provisioning' and c.relname='one_time_purchase_receipts_v1';
  if v_fn=1 and v_uq=1 and v_rls then
    return jsonb_build_object('ok',true,'token','PROTEUSOPS_ONE_TIME_ENTITLEMENT_OK','grant_fn',v_fn,'unique',v_uq,'rls',v_rls);
  end if;
  return jsonb_build_object('ok',false,'token','PROTEUSOPS_ONE_TIME_ENTITLEMENT_FAIL','grant_fn',v_fn,'unique',v_uq,'rls',v_rls);
end $fn$;

select pods_provisioning.rpc_selftest_one_time_entitlement_v1();
