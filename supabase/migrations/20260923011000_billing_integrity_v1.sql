-- ProteusOps security slice S2 — billing integrity (docs/reference/SECURITY_AUDIT_2026-09-22_v2.md)
-- H1  stale / out-of-order Stripe subscription events are ignored; canceled is terminal.
-- H2  customer <-> workspace binding enforced (no silent re-binding, no cross-org attachment).
-- H3  one-time purchases resolve through a server-side catalog with amount + currency checks.
-- M1  refunds / disputes revoke one-time grants (idempotent).
-- M2  unknown / inactive plan ids fall back to baseline capabilities.
-- L3  audit + receipts store event id/type/created only (no customer PII).

alter table pods.subscriptions add column if not exists last_event_at timestamptz;
alter table pods_provisioning.one_time_purchase_receipts_v1
  add column if not exists product_key text,
  add column if not exists amount_minor bigint,
  add column if not exists currency text,
  add column if not exists revoked_at timestamptz,
  add column if not exists revoke_reason text;

create or replace function pods.billing_event_digest(p_event jsonb)
returns jsonb language sql immutable set search_path = pods, public as $fn$
  select jsonb_strip_nulls(jsonb_build_object('id', p_event->>'id', 'type', p_event->>'type',
         'created', p_event->>'created', 'livemode', p_event->'livemode')) $fn$;

create or replace function pods.billing_status_rank(p_status text)
returns int language sql immutable set search_path = pods, public as $fn$
  select case p_status when 'canceled' then 4 when 'active' then 3 when 'past_due' then 3 when 'unpaid' then 3
         when 'paused' then 3 when 'trialing' then 2 else 1 end $fn$;

-- ---------- subscription ingest ----------
create or replace function pods.rpc_billing_ingest_webhook(
  p_org_id uuid, p_provider_customer_id text, p_provider_subscription_id text, p_status text,
  p_plan_id text, p_period_start timestamptz, p_period_end timestamptz,
  p_cancel_at_period_end boolean, p_billing_email text, p_event jsonb
) returns void language plpgsql security definer set search_path = pods, public as $function$
declare v_event_at timestamptz; v_digest jsonb := pods.billing_event_digest(coalesce(p_event,'{}'::jsonb));
  e_org uuid; e_status text; e_last timestamptz; v_found boolean;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'BILLING_INGEST_FORBIDDEN'; end if;
  if p_org_id is null or coalesce(p_provider_subscription_id,'') = '' or coalesce(p_provider_customer_id,'') = '' then
    raise exception 'BILLING_INGEST_INVALID';
  end if;
  if not exists (select 1 from pods.orgs where org_id = p_org_id) then raise exception 'BILLING_UNKNOWN_ORG'; end if;
  v_event_at := case when p_event ? 'created' then to_timestamp((p_event->>'created')::double precision) else now() end;

  -- H2: binding
  if exists (select 1 from pods.billing_accounts b where b.provider_customer_id = p_provider_customer_id and b.org_id <> p_org_id) then
    raise exception 'BILLING_CUSTOMER_BOUND_TO_OTHER_ORG';
  end if;
  if exists (select 1 from pods.billing_accounts b where b.org_id = p_org_id and b.provider_customer_id <> ''
             and b.provider_customer_id <> p_provider_customer_id) then
    raise exception 'BILLING_ORG_BOUND_TO_OTHER_CUSTOMER';
  end if;

  select org_id, status, last_event_at into e_org, e_status, e_last
    from pods.subscriptions where provider_subscription_id = p_provider_subscription_id for update;
  v_found := found;
  if v_found then
    if e_org <> p_org_id then raise exception 'BILLING_SUBSCRIPTION_BOUND_TO_OTHER_ORG'; end if;
    -- H1: ordering
    if e_last is not null and (v_event_at < e_last or
        (v_event_at = e_last and pods.billing_status_rank(p_status) < pods.billing_status_rank(e_status))) then
      insert into pods.audit_log(org_id, actor_role_key, action_key, details)
      values (p_org_id, 'system', 'billing.ingest_stale_ignored',
              v_digest || jsonb_build_object('subscription_id', p_provider_subscription_id, 'status', p_status, 'current_status', e_status));
      return;
    end if;
    if e_status = 'canceled' and p_status <> 'canceled' then
      insert into pods.audit_log(org_id, actor_role_key, action_key, details)
      values (p_org_id, 'system', 'billing.ingest_resurrect_refused',
              v_digest || jsonb_build_object('subscription_id', p_provider_subscription_id, 'status', p_status));
      return;
    end if;
  end if;

  insert into pods.billing_accounts(org_id, provider, provider_customer_id, billing_email, status, updated_at)
  values (p_org_id, 'stripe', p_provider_customer_id, p_billing_email, p_status, now())
  on conflict (org_id) do update set billing_email = coalesce(excluded.billing_email, pods.billing_accounts.billing_email),
    status = excluded.status, updated_at = excluded.updated_at;

  insert into pods.subscriptions(org_id, provider_subscription_id, status, plan_id, current_period_start,
    current_period_end, cancel_at_period_end, updated_at, past_due_since, last_event_at)
  values (p_org_id, p_provider_subscription_id, p_status, p_plan_id, p_period_start, p_period_end,
    coalesce(p_cancel_at_period_end,false), now(), case when p_status = 'past_due' then now() end, v_event_at)
  on conflict (provider_subscription_id) do update set
    status = excluded.status, plan_id = excluded.plan_id,
    current_period_start = excluded.current_period_start, current_period_end = excluded.current_period_end,
    cancel_at_period_end = excluded.cancel_at_period_end, updated_at = excluded.updated_at,
    past_due_since = case when excluded.status = 'past_due' then coalesce(pods.subscriptions.past_due_since, now()) end,
    last_event_at = excluded.last_event_at;

  perform pods.rpc_recompute_entitlements(p_org_id);

  insert into pods.audit_log(org_id, actor_role_key, action_key, details)
  values (p_org_id, 'system', 'billing.ingest', v_digest || jsonb_build_object('customer_id', p_provider_customer_id,
    'subscription_id', p_provider_subscription_id, 'status', p_status, 'plan_id', p_plan_id,
    'plan_known', exists (select 1 from pods.plan_tiers where plan_id = p_plan_id and is_active)));
end; $function$;

-- ---------- recompute: unknown plan -> baseline ----------
create or replace function pods.rpc_recompute_entitlements(p_org_id uuid)
returns void language plpgsql security definer set search_path = pods, public as $function$
declare v_plan_id text; v_status text; v_pd_since timestamptz; v_paid boolean := false; v_grace boolean := false;
begin
  select s.plan_id, s.status, s.past_due_since into v_plan_id, v_status, v_pd_since
    from pods.subscriptions s where s.org_id = p_org_id
    order by s.updated_at desc, s.provider_subscription_id limit 1;
  v_grace := coalesce(v_status = 'past_due' and v_pd_since is not null
                      and v_pd_since > now() - pods.billing_grace_period(), false);
  v_paid := coalesce(v_status in ('active','trialing'), false) or v_grace;
  if v_plan_id is null or not v_paid
     or not exists (select 1 from pods.plan_tiers t where t.plan_id = v_plan_id and t.is_active) then
    v_plan_id := 'proteusops_s_v1';
  end if;

  delete from pods.org_entitlements where org_id = p_org_id;
  insert into pods.org_entitlements(org_id, capability_key, value_type, value_bool, value_int, value_text, source)
  values (p_org_id, 'paid_active', 'bool', v_paid, null, null, 'system'),
         (p_org_id, 'billing_in_grace', 'bool', v_grace, null, null, 'system');
  insert into pods.org_entitlements(org_id, capability_key, value_type, value_bool, value_int, value_text, source)
  select p_org_id, c.capability_key, c.value_type, c.value_bool, c.value_int, c.value_text, 'plan'
    from pods.plan_capabilities c
   where c.plan_id = v_plan_id and c.capability_key not in ('paid_active','billing_in_grace');
  insert into pods.org_entitlements(org_id, capability_key, value_type, value_bool, value_int, value_text, source)
  select o.org_id, o.capability_key, o.value_type, o.value_bool, o.value_int, o.value_text, 'override'
    from pods.entitlement_overrides o
   where o.org_id = p_org_id and o.capability_key not in ('paid_active','billing_in_grace')
     and (o.expires_at is null or o.expires_at > now())
  on conflict (org_id, capability_key) do update
    set value_type = excluded.value_type, value_bool = excluded.value_bool, value_int = excluded.value_int,
        value_text = excluded.value_text, source = 'override', computed_at = now();
end $function$;

-- ---------- one-time catalog ----------
create table if not exists pods_provisioning.one_time_catalog_v1 (
  product_key text primary key check (product_key ~ '^[a-z0-9][a-z0-9_.-]{1,62}$'),
  display_name text not null,
  capability_key text not null check (capability_key not in ('paid_active','billing_in_grace')),
  value_type text not null default 'bool' check (value_type in ('bool','int','text')),
  value_bool boolean, value_int bigint, value_text text,
  amount_minor bigint not null check (amount_minor > 0),
  currency text not null check (currency ~ '^[a-z]{3}$'),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table pods_provisioning.one_time_catalog_v1 enable row level security;
revoke all on pods_provisioning.one_time_catalog_v1 from anon, authenticated;

create or replace function pods.rpc_grant_one_time_purchase_v2(
  p_org_id uuid, p_provider_payment_id text, p_product_key text, p_amount_minor bigint, p_currency text, p_event jsonb)
returns jsonb language plpgsql security definer set search_path = pods, pods_provisioning, public as $fn$
declare c pods_provisioning.one_time_catalog_v1%rowtype; r jsonb; v_digest jsonb := pods.billing_event_digest(coalesce(p_event,'{}'::jsonb));
begin
  if auth.role() is distinct from 'service_role' then raise exception 'ONE_TIME_GRANT_FORBIDDEN'; end if;
  if not exists (select 1 from pods.orgs where org_id = p_org_id) then raise exception 'BILLING_UNKNOWN_ORG'; end if;
  select * into c from pods_provisioning.one_time_catalog_v1 where product_key = p_product_key and active;
  if not found then raise exception 'ONE_TIME_UNKNOWN_PRODUCT'; end if;
  if p_amount_minor is null or p_amount_minor < c.amount_minor or lower(coalesce(p_currency,'')) <> c.currency then
    insert into pods.audit_log(org_id, actor_role_key, action_key, details)
    values (p_org_id, 'system', 'entitlement.one_time_amount_mismatch', v_digest || jsonb_build_object(
      'product_key', p_product_key, 'paid', p_amount_minor, 'currency', p_currency, 'expected', c.amount_minor, 'expected_currency', c.currency));
    raise exception 'ONE_TIME_AMOUNT_MISMATCH';
  end if;
  r := pods.rpc_grant_one_time_entitlement_v1(p_org_id, 'stripe', p_provider_payment_id, c.capability_key,
         c.value_type, c.value_bool, c.value_int, c.value_text, v_digest);
  update pods_provisioning.one_time_purchase_receipts_v1
     set product_key = p_product_key, amount_minor = p_amount_minor, currency = lower(p_currency)
   where provider_key = 'stripe' and provider_payment_id = p_provider_payment_id and product_key is null;
  return r || jsonb_build_object('product_key', p_product_key);
end $fn$;

create or replace function pods.rpc_revoke_one_time_purchase_v1(p_provider_payment_id text, p_reason text, p_event jsonb)
returns jsonb language plpgsql security definer set search_path = pods, pods_provisioning, public as $fn$
declare rc pods_provisioning.one_time_purchase_receipts_v1%rowtype; v_others int; v_removed boolean := false;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'ONE_TIME_REVOKE_FORBIDDEN'; end if;
  select * into rc from pods_provisioning.one_time_purchase_receipts_v1
   where provider_key = 'stripe' and provider_payment_id = p_provider_payment_id for update;
  if not found then return jsonb_build_object('ok', true, 'found', false); end if;
  if rc.revoked_at is not null then return jsonb_build_object('ok', true, 'found', true, 'already_revoked', true); end if;
  update pods_provisioning.one_time_purchase_receipts_v1 set revoked_at = now(), revoke_reason = p_reason
   where one_time_purchase_receipt_id = rc.one_time_purchase_receipt_id;
  select count(*) into v_others from pods_provisioning.one_time_purchase_receipts_v1
   where org_id = rc.org_id and capability_key = rc.capability_key and revoked_at is null;
  if v_others = 0 then
    delete from pods.entitlement_overrides where org_id = rc.org_id and capability_key = rc.capability_key
       and reason like 'one_time_purchase:%';
    v_removed := found;
  end if;
  perform pods.rpc_recompute_entitlements(rc.org_id);
  insert into pods.audit_log(org_id, actor_role_key, action_key, details)
  values (rc.org_id, 'system', 'entitlement.one_time_revoke', pods.billing_event_digest(coalesce(p_event,'{}'::jsonb))
          || jsonb_build_object('payment_id', p_provider_payment_id, 'reason', p_reason, 'capability_key', rc.capability_key,
                                'override_removed', v_removed, 'other_active_receipts', v_others));
  return jsonb_build_object('ok', true, 'found', true, 'revoked', true, 'override_removed', v_removed);
end $fn$;

-- scrub PII already stored
update pods_provisioning.one_time_purchase_receipts_v1 set event = pods.billing_event_digest(event) where event ? 'data';
update pods.audit_log set details = (details - 'event') || jsonb_build_object('event', pods.billing_event_digest(details->'event'))
 where action_key in ('billing.ingest','entitlement.one_time_grant') and details ? 'event' and (details->'event') ? 'data';

-- public wrappers (service_role only)
create or replace function public.rpc_grant_one_time_purchase_v2(p_org_id uuid, p_provider_payment_id text, p_product_key text, p_amount_minor bigint, p_currency text, p_event jsonb)
returns jsonb language sql security definer set search_path = pods, public as $fn$
  select pods.rpc_grant_one_time_purchase_v2(p_org_id, p_provider_payment_id, p_product_key, p_amount_minor, p_currency, p_event) $fn$;
create or replace function public.rpc_revoke_one_time_purchase_v1(p_provider_payment_id text, p_reason text, p_event jsonb)
returns jsonb language sql security definer set search_path = pods, public as $fn$
  select pods.rpc_revoke_one_time_purchase_v1(p_provider_payment_id, p_reason, p_event) $fn$;
do $$ declare s text; begin
  foreach s in array array[
    'pods.billing_event_digest(jsonb)', 'pods.billing_status_rank(text)',
    'pods.rpc_grant_one_time_purchase_v2(uuid,text,text,bigint,text,jsonb)', 'pods.rpc_revoke_one_time_purchase_v1(text,text,jsonb)',
    'public.rpc_grant_one_time_purchase_v2(uuid,text,text,bigint,text,jsonb)', 'public.rpc_revoke_one_time_purchase_v1(text,text,jsonb)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', s);
    execute format('grant execute on function %s to service_role', s);
  end loop;
end $$;

-- ---------- selftest ----------
create or replace function pods.rpc_selftest_billing_integrity_v1()
returns jsonb language plpgsql security definer set search_path = pods, pods_provisioning, public as $fn$
declare v_sfx text := replace(gen_random_uuid()::text,'-',''); v_org uuid; v_org2 uuid;
  v_plan text := 'selftest_plan_'||v_sfx; v_prod text := 'selftest-prod-'||substr(v_sfx,1,12);
  v_sub text := 'sub_selftest_'||v_sfx; v_cus text := 'cus_selftest_'||v_sfx; v_st text;
  t0 bigint := extract(epoch from now())::bigint;
  t_stale bool := false; t_tie bool := false; t_terminal bool := false; t_bind_cus bool := false; t_bind_org bool := false;
  t_unknown_plan bool := false; t_cat_unknown bool := false; t_cat_under bool := false; t_cat_currency bool := false;
  t_cat_ok bool := false; t_refund bool := false; t_refund_idem bool := false; t_multi bool := false; t_pii bool := false; v_ok bool;
  ev jsonb;
begin
  insert into pods.plan_tiers(plan_id, name, is_active) values (v_plan, 'selftest plan', true);
  insert into pods.plan_capabilities(plan_id, capability_key, value_type, value_bool) values (v_plan, 'selftest.plan_feature', 'bool', true);
  insert into pods_provisioning.one_time_catalog_v1(product_key, display_name, capability_key, value_type, value_bool, amount_minor, currency)
    values (v_prod, 'selftest product', 'selftest.addon', 'bool', true, 2000, 'usd');
  insert into pods.orgs(slug, name) values ('selftest-bi-'||v_sfx, 'selftest bi') returning org_id into v_org;
  insert into pods.orgs(slug, name) values ('selftest-bi2-'||v_sfx, 'selftest bi2') returning org_id into v_org2;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);

  ev := jsonb_build_object('id','evt_1','type','customer.subscription.updated','created', t0 + 100,
          'data', jsonb_build_object('object', jsonb_build_object('customer_email','pii@example.com')));
  perform pods.rpc_billing_ingest_webhook(v_org, v_cus, v_sub, 'active', v_plan, now(), now()+interval '30 days', false, null, ev);
  -- older event arrives late -> ignored
  perform pods.rpc_billing_ingest_webhook(v_org, v_cus, v_sub, 'incomplete', v_plan, now(), now()+interval '30 days', false, null,
          jsonb_build_object('id','evt_0','type','customer.subscription.created','created', t0 + 50));
  select status into v_st from pods.subscriptions where provider_subscription_id = v_sub;
  t_stale := v_st = 'active';
  -- same-second lower-rank status -> ignored
  perform pods.rpc_billing_ingest_webhook(v_org, v_cus, v_sub, 'trialing', v_plan, now(), now()+interval '30 days', false, null,
          jsonb_build_object('id','evt_1b','type','customer.subscription.updated','created', t0 + 100));
  select status into v_st from pods.subscriptions where provider_subscription_id = v_sub;
  t_tie := v_st = 'active';
  -- cancel, then a NEWER non-canceled event must not resurrect
  perform pods.rpc_billing_ingest_webhook(v_org, v_cus, v_sub, 'canceled', v_plan, now(), now()+interval '30 days', false, null,
          jsonb_build_object('id','evt_2','type','customer.subscription.deleted','created', t0 + 200));
  perform pods.rpc_billing_ingest_webhook(v_org, v_cus, v_sub, 'active', v_plan, now(), now()+interval '30 days', false, null,
          jsonb_build_object('id','evt_3','type','customer.subscription.updated','created', t0 + 300));
  select status into v_st from pods.subscriptions where provider_subscription_id = v_sub;
  t_terminal := v_st = 'canceled' and not coalesce(pods.has_cap_bool(v_org,'paid_active'), false);
  -- binding: same customer to another org / another customer to this org
  begin perform pods.rpc_billing_ingest_webhook(v_org2, v_cus, v_sub||'x', 'active', v_plan, now(), now(), false, null, '{}'::jsonb);
  exception when others then t_bind_cus := sqlerrm like '%BILLING_CUSTOMER_BOUND_TO_OTHER_ORG%'; end;
  begin perform pods.rpc_billing_ingest_webhook(v_org, v_cus||'x', v_sub||'y', 'active', v_plan, now(), now(), false, null, '{}'::jsonb);
  exception when others then t_bind_org := sqlerrm like '%BILLING_ORG_BOUND_TO_OTHER_CUSTOMER%'; end;
  -- unknown plan -> paid but baseline caps (storefront from baseline, no plan feature)
  perform pods.rpc_billing_ingest_webhook(v_org2, v_cus||'2', v_sub||'2', 'active', 'no_such_plan_'||v_sfx, now(), now(), false, null, '{}'::jsonb);
  t_unknown_plan := coalesce(pods.has_cap_bool(v_org2,'paid_active'),false)
    and not coalesce(pods.has_cap_bool(v_org2,'selftest.plan_feature'),false)
    and (select count(*) from pods.org_entitlements e where e.org_id = v_org2 and e.source = 'plan')
      = (select count(*) from pods.plan_capabilities where plan_id = 'proteusops_s_v1' and capability_key not in ('paid_active','billing_in_grace'));
  -- catalog
  begin perform pods.rpc_grant_one_time_purchase_v2(v_org, 'pi_u_'||v_sfx, 'no-such-product', 2000, 'usd', '{}'::jsonb);
  exception when others then t_cat_unknown := sqlerrm like '%ONE_TIME_UNKNOWN_PRODUCT%'; end;
  begin perform pods.rpc_grant_one_time_purchase_v2(v_org, 'pi_l_'||v_sfx, v_prod, 1999, 'usd', '{}'::jsonb);
  exception when others then t_cat_under := sqlerrm like '%ONE_TIME_AMOUNT_MISMATCH%'; end;
  begin perform pods.rpc_grant_one_time_purchase_v2(v_org, 'pi_c_'||v_sfx, v_prod, 2000, 'eur', '{}'::jsonb);
  exception when others then t_cat_currency := sqlerrm like '%ONE_TIME_AMOUNT_MISMATCH%'; end;
  perform pods.rpc_grant_one_time_purchase_v2(v_org, 'pi_a_'||v_sfx, v_prod, 2000, 'USD',
          jsonb_build_object('id','evt_pi','type','payment_intent.succeeded','created',t0,'data',jsonb_build_object('object',jsonb_build_object('receipt_email','pii@example.com'))));
  t_cat_ok := coalesce(pods.has_cap_bool(v_org,'selftest.addon'),false);
  t_pii := not exists (select 1 from pods_provisioning.one_time_purchase_receipts_v1 where org_id = v_org and event ? 'data')
       and not exists (select 1 from pods.audit_log where org_id = v_org and details::text like '%pii@example.com%');
  -- second purchase of the same capability, refund the first -> still granted; refund second -> revoked
  perform pods.rpc_grant_one_time_purchase_v2(v_org, 'pi_b_'||v_sfx, v_prod, 2500, 'usd', '{}'::jsonb);
  perform pods.rpc_revoke_one_time_purchase_v1('pi_a_'||v_sfx, 'refund', '{}'::jsonb);
  t_multi := coalesce(pods.has_cap_bool(v_org,'selftest.addon'),false);
  perform pods.rpc_revoke_one_time_purchase_v1('pi_b_'||v_sfx, 'dispute', '{}'::jsonb);
  t_refund := not coalesce(pods.has_cap_bool(v_org,'selftest.addon'),false);
  t_refund_idem := (pods.rpc_revoke_one_time_purchase_v1('pi_b_'||v_sfx, 'refund', '{}'::jsonb)->>'already_revoked')::boolean;
  perform set_config('request.jwt.claims', '', true);

  delete from pods_provisioning.one_time_purchase_receipts_v1 where org_id in (v_org, v_org2);
  delete from pods.audit_log where org_id in (v_org, v_org2);
  delete from pods.orgs where org_id in (v_org, v_org2);
  delete from pods_provisioning.one_time_catalog_v1 where product_key = v_prod;
  delete from pods.plan_tiers where plan_id = v_plan;

  v_ok := t_stale and t_tie and t_terminal and t_bind_cus and t_bind_org and t_unknown_plan and t_cat_unknown
      and t_cat_under and t_cat_currency and t_cat_ok and t_multi and t_refund and t_refund_idem and t_pii;
  return jsonb_build_object('ok', v_ok,
    'token', case when v_ok then 'PROTEUSOPS_BILLING_INTEGRITY_OK' else 'PROTEUSOPS_BILLING_INTEGRITY_FAIL' end,
    'stale_ignored', t_stale, 'same_second_lower_rank_ignored', t_tie, 'canceled_terminal', t_terminal,
    'customer_bound', t_bind_cus, 'org_bound', t_bind_org, 'unknown_plan_baseline', t_unknown_plan,
    'catalog_unknown_rejected', t_cat_unknown, 'underpayment_rejected', t_cat_under, 'currency_rejected', t_cat_currency,
    'catalog_grant', t_cat_ok, 'partial_refund_keeps_other', t_multi, 'refund_revokes', t_refund,
    'revoke_idempotent', t_refund_idem, 'no_pii_stored', t_pii);
end $fn$;
revoke all on function pods.rpc_selftest_billing_integrity_v1() from public, anon, authenticated;

select pods.rpc_selftest_billing_integrity_v1();
