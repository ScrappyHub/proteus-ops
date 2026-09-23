-- ProteusOps fix S2b — one-time purchase rejections are RECORDED, not rolled back
-- Found by the hosted Stripe e2e (2026-09-23): an underpayment (pi_3UIiKCAVBD1O6C8C213rBO9F) was correctly NOT
-- granted, but the 'entitlement.one_time_amount_mismatch' audit row was lost because the function raised after
-- inserting it (the exception rolls back the insert). Rejections now write the audit row and RETURN
-- {ok:false, rejected:<code>}; nothing is granted. The edge function treats `rejected` as final (no retry).
create or replace function pods.rpc_grant_one_time_purchase_v2(
  p_org_id uuid, p_provider_payment_id text, p_product_key text, p_amount_minor bigint, p_currency text, p_event jsonb)
returns jsonb language plpgsql security definer set search_path = pods, pods_provisioning, public as $fn$
declare c pods_provisioning.one_time_catalog_v1%rowtype; r jsonb; v_digest jsonb := pods.billing_event_digest(coalesce(p_event,'{}'::jsonb));
begin
  if auth.role() is distinct from 'service_role' then raise exception 'ONE_TIME_GRANT_FORBIDDEN'; end if;
  if not exists (select 1 from pods.orgs where org_id = p_org_id) then raise exception 'BILLING_UNKNOWN_ORG'; end if;
  select * into c from pods_provisioning.one_time_catalog_v1 where product_key = p_product_key and active;
  if not found then
    insert into pods.audit_log(org_id, actor_role_key, action_key, details)
    values (p_org_id, 'system', 'entitlement.one_time_unknown_product', v_digest || jsonb_build_object(
      'product_key', p_product_key, 'payment_id', p_provider_payment_id, 'paid', p_amount_minor, 'currency', p_currency));
    return jsonb_build_object('ok', false, 'rejected', 'ONE_TIME_UNKNOWN_PRODUCT', 'product_key', p_product_key);
  end if;
  if p_amount_minor is null or p_amount_minor < c.amount_minor or lower(coalesce(p_currency,'')) <> c.currency then
    insert into pods.audit_log(org_id, actor_role_key, action_key, details)
    values (p_org_id, 'system', 'entitlement.one_time_amount_mismatch', v_digest || jsonb_build_object(
      'product_key', p_product_key, 'payment_id', p_provider_payment_id, 'paid', p_amount_minor, 'currency', p_currency,
      'expected', c.amount_minor, 'expected_currency', c.currency));
    return jsonb_build_object('ok', false, 'rejected', 'ONE_TIME_AMOUNT_MISMATCH', 'product_key', p_product_key);
  end if;
  r := pods.rpc_grant_one_time_entitlement_v1(p_org_id, 'stripe', p_provider_payment_id, c.capability_key,
         c.value_type, c.value_bool, c.value_int, c.value_text, v_digest);
  update pods_provisioning.one_time_purchase_receipts_v1
     set product_key = p_product_key, amount_minor = p_amount_minor, currency = lower(p_currency)
   where provider_key = 'stripe' and provider_payment_id = p_provider_payment_id and product_key is null;
  return r || jsonb_build_object('product_key', p_product_key);
end $fn$;

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
  t_cat_unknown := pods.rpc_grant_one_time_purchase_v2(v_org, 'pi_u_'||v_sfx, 'no-such-product', 2000, 'usd', '{}'::jsonb)->>'rejected' = 'ONE_TIME_UNKNOWN_PRODUCT'
    and exists (select 1 from pods.audit_log where org_id = v_org and action_key = 'entitlement.one_time_unknown_product');
  t_cat_under := pods.rpc_grant_one_time_purchase_v2(v_org, 'pi_l_'||v_sfx, v_prod, 1999, 'usd', '{}'::jsonb)->>'rejected' = 'ONE_TIME_AMOUNT_MISMATCH'
    and not coalesce(pods.has_cap_bool(v_org,'selftest.addon'), false)
    and not exists (select 1 from pods_provisioning.one_time_purchase_receipts_v1 where provider_payment_id = 'pi_l_'||v_sfx);
  t_cat_currency := pods.rpc_grant_one_time_purchase_v2(v_org, 'pi_c_'||v_sfx, v_prod, 2000, 'eur', '{}'::jsonb)->>'rejected' = 'ONE_TIME_AMOUNT_MISMATCH'
    and (select count(*) from pods.audit_log where org_id = v_org and action_key = 'entitlement.one_time_amount_mismatch') = 2;
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
