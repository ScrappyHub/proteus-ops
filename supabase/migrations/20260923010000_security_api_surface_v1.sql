-- ProteusOps security slice S1 — API surface hardening (docs/reference/SECURITY_AUDIT_2026-09-22_v2.md)
-- C1  org bootstrap can no longer self-grant a plan/trial (paid access only via Stripe ingest).
-- M3  selftest / reset functions removed from client reach.
-- M4  default privileges: new public/pods* functions, tables, sequences are NOT auto-granted.
-- M5  every SECURITY DEFINER function in pods* is service_role-only unless allowlisted.
-- L1  public storefront views only show workspaces with storefront_enabled.
-- Selftest PROTEUSOPS_API_SURFACE_OK enforces the allowlist going forward.

-- ---------- C1: bootstrap without self-granted plans ----------
create or replace function pods.rpc_create_org_bootstrap(p_slug text, p_name text, p_plan_id text default null)
returns uuid language plpgsql security definer set search_path = pods, public as $function$
declare v_org_id uuid; v_uid uuid; v_owned int;
begin
  v_uid := auth.uid();
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode = '42501'; end if;
  if p_slug is null or p_slug !~ '^[a-z0-9][a-z0-9-]{1,62}$' then raise exception 'INVALID_SLUG'; end if;
  if p_name is null or length(btrim(p_name)) not between 1 and 200 then raise exception 'INVALID_NAME'; end if;
  select count(*) into v_owned from pods.org_members where user_id = v_uid and role_key = 'owner';
  if v_owned >= 10 then raise exception 'ORG_LIMIT_REACHED' using errcode = '42501'; end if;

  insert into pods.orgs(slug, name) values (p_slug, p_name) returning org_id into v_org_id;
  insert into pods.org_members(org_id, user_id, role_key) values (v_org_id, v_uid, 'owner');
  insert into pods.org_models(org_id, model_id, version)
  values (v_org_id, 'pods.core', '1.0.0'), (v_org_id, 'pods.storefront', '1.0.0') on conflict do nothing;

  -- p_plan_id is accepted for API compatibility but IGNORED: plans/trials come only from verified billing.
  perform pods.rpc_recompute_entitlements(v_org_id);
  insert into pods.storefront_profiles(org_id, display_name) values (v_org_id, p_name);
  insert into pods.audit_log(org_id, actor_user_id, actor_role_key, action_key, details)
  values (v_org_id, v_uid, 'owner', 'org.bootstrap',
          jsonb_build_object('slug', p_slug, 'requested_plan_id_ignored', p_plan_id));
  return v_org_id;
end $function$;

-- ---------- M4: stop auto-granting new objects ----------
alter default privileges for role postgres in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;
do $$ declare s text; begin
  foreach s in array array['pods','pods_core','pods_provisioning','pods_public','pods_ops','pods_billing'] loop
    if exists (select 1 from pg_namespace where nspname = s) then
      execute format('alter default privileges for role postgres in schema %I revoke execute on functions from public, anon, authenticated', s);
      execute format('alter default privileges for role postgres in schema %I revoke all on tables from anon, authenticated', s);
    end if;
  end loop;
end $$;

-- ---------- M3 + M5: function grants ----------
-- Stable, schema-qualified signature (regprocedure::text drops the schema for search_path-visible functions).
create or replace function pods_core.fn_sig(p_oid oid)
returns text language sql stable set search_path = pg_catalog as $fn$
  select n.nspname||'.'||p.proname||'('||replace(oidvectortypes(p.proargtypes), ', ', ',')||')'
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace where p.oid = p_oid $fn$;

-- Client allowlist: the ONLY SECURITY DEFINER functions authenticated users may execute.
create or replace function pods_core.api_client_allowlist_v1()
returns text[] language sql immutable set search_path = pods_core, public as $fn$
  select array[
    'public.rpc_create_org_bootstrap(text,text,text)',
    'public.rpc_create_appointment_v1(uuid,uuid,timestamp with time zone,timestamp with time zone,uuid,uuid,text,text,text,text)',
    'public.rpc_add_time_off_block_v1(uuid,uuid,timestamp with time zone,timestamp with time zone,text)',
    'public.rpc_delete_availability_rule_v1(uuid,uuid)',
    'public.rpc_upsert_availability_rule_v1(uuid,uuid,uuid,uuid,integer,time without time zone,time without time zone,boolean)',
    'public.rpc_selftest_reset_booking_v1(uuid,uuid)',
    'public.rpc_hub_project_create_v1(uuid,text,text,text,uuid)',
    'public.rpc_hub_projects_list_v1(uuid)',
    'public.rpc_hub_evaluate_gate_v1(uuid,text,text)',
    'public.rpc_hub_transition_v1(uuid,text,text)'
  ]::text[] $fn$;

do $$ declare r record; v_allow text[] := pods_core.api_client_allowlist_v1(); begin
  for r in
    select p.oid, pods_core.fn_sig(p.oid) sig, n.nspname, p.prosecdef
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where p.prokind = 'f'
       and (n.nspname in ('public','pods','pods_core','pods_provisioning','pods_public','pods_ops','pods_billing'))
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')   -- skip extension-owned
  loop
    execute format('revoke execute on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
    if r.prosecdef then
      if r.sig = any(v_allow) then
        execute format('grant execute on function %s to authenticated', r.sig);
      else
        execute format('revoke execute on function %s from authenticated', r.sig);
      end if;
    elsif r.nspname in ('pods','public') then
      -- invoker helpers (has_cap_bool, org_role, ...) run with the caller's own privileges; RLS policies use them
      execute format('grant execute on function %s to authenticated', r.sig);
    else
      execute format('revoke execute on function %s from authenticated', r.sig);
    end if;
  end loop;
end $$;

-- ---------- L1: storefront views only for storefront-enabled workspaces ----------
create or replace view pods.public_storefront_profile_v1 as
 select o.slug, o.name as org_name, p.display_name, p.tagline, p.description, p.website_url, p.phone, p.email
   from pods.orgs o join pods.storefront_profiles p on p.org_id = o.org_id
  where o.is_active and exists (select 1 from pods.org_entitlements e where e.org_id = o.org_id
          and e.capability_key = 'storefront_enabled' and e.value_bool);
create or replace view pods.public_storefront_locations_v1 as
 select o.slug, l.location_id, l.name, l.address_line1, l.address_line2, l.city, l.region, l.postal_code,
        l.country, l.latitude, l.longitude, l.hours_json
   from pods.orgs o join pods.storefront_locations l on l.org_id = o.org_id
  where o.is_active and l.is_active and exists (select 1 from pods.org_entitlements e where e.org_id = o.org_id
          and e.capability_key = 'storefront_enabled' and e.value_bool);
create or replace view pods.public_storefront_services_v1 as
 select o.slug, s.service_id, s.name, s.description, s.price_cents, s.duration_mins, s.sort_order, c.name as category_name
   from pods.orgs o join pods.storefront_services s on s.org_id = o.org_id
   left join pods.storefront_service_categories c on c.category_id = s.category_id
  where o.is_active and s.is_active and exists (select 1 from pods.org_entitlements e where e.org_id = o.org_id
          and e.capability_key = 'storefront_enabled' and e.value_bool);
create or replace view pods.public_storefront_team_v1 as
 select o.slug, t.team_member_id, t.display_name, t.role_title, t.bio, t.photo_url, t.sort_order
   from pods.orgs o join pods.storefront_team_members t on t.org_id = o.org_id
  where o.is_active and t.is_active and exists (select 1 from pods.org_entitlements e where e.org_id = o.org_id
          and e.capability_key = 'storefront_enabled' and e.value_bool);

-- ---------- selftest ----------
create or replace function pods_core.rpc_selftest_api_surface_v1()
returns jsonb language plpgsql security definer set search_path = pods_core, pods, public as $fn$
declare v_anon_secdef text[]; v_auth_extra text[]; v_allow_missing text[]; v_default_leak int;
  v_org uuid; v_uid uuid := gen_random_uuid(); v_paid boolean; v_subs int; v_ok boolean;
begin
  select coalesce(array_agg(pods_core.fn_sig(p.oid)), '{}') into v_anon_secdef
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where p.prosecdef and n.nspname in ('public','pods','pods_core','pods_provisioning','pods_public','pods_ops','pods_billing')
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
     and has_function_privilege('anon', p.oid, 'execute');
  select coalesce(array_agg(pods_core.fn_sig(p.oid)), '{}') into v_auth_extra
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where p.prosecdef and n.nspname in ('public','pods','pods_core','pods_provisioning','pods_public','pods_ops','pods_billing')
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
     and has_function_privilege('authenticated', p.oid, 'execute')
     and not (pods_core.fn_sig(p.oid) = any(pods_core.api_client_allowlist_v1()));
  select coalesce(array_agg(a), '{}') into v_allow_missing from unnest(pods_core.api_client_allowlist_v1()) a
   where to_regprocedure(a) is null;
  select count(*) into v_default_leak from pg_default_acl d
   where pg_get_userbyid(d.defaclrole) = 'postgres'
     and d.defaclnamespace in (select oid from pg_namespace where nspname in ('public','pods','pods_core','pods_provisioning','pods_public','pods_ops','pods_billing'))
     and (d.defaclacl::text ~ '(^|[{,])anon=' or d.defaclacl::text ~ '(^|[{,])authenticated=');

  -- C1 behaviour: bootstrap with a paid plan request yields NO subscription and NOT paid
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',v_uid,'aal','aal1')::text, true);
  v_org := pods.rpc_create_org_bootstrap('selftest-boot-'||substr(replace(v_uid::text,'-',''),1,12), 'selftest boot', 'proteusops_sb_v1');
  perform set_config('request.jwt.claims', '', true);
  select count(*) into v_subs from pods.subscriptions where org_id = v_org;
  v_paid := coalesce(pods.has_cap_bool(v_org, 'paid_active'), false);
  delete from pods.audit_log where org_id = v_org;
  delete from pods.orgs where org_id = v_org;

  v_ok := cardinality(v_anon_secdef) = 0 and cardinality(v_auth_extra) = 0 and cardinality(v_allow_missing) = 0
          and v_default_leak = 0 and v_subs = 0 and not v_paid;
  return jsonb_build_object('ok', v_ok,
    'token', case when v_ok then 'PROTEUSOPS_API_SURFACE_OK' else 'PROTEUSOPS_API_SURFACE_FAIL' end,
    'anon_secdef', v_anon_secdef, 'authenticated_secdef_not_allowlisted', v_auth_extra,
    'allowlist_missing', v_allow_missing, 'default_acl_leaks', v_default_leak,
    'bootstrap_self_grant_blocked', v_subs = 0 and not v_paid);
end $fn$;
revoke all on function pods_core.rpc_selftest_api_surface_v1() from public, anon, authenticated;
revoke all on function pods_core.api_client_allowlist_v1() from public, anon, authenticated;
revoke all on function pods_core.fn_sig(oid) from public, anon, authenticated;

select pods_core.rpc_selftest_api_surface_v1();
