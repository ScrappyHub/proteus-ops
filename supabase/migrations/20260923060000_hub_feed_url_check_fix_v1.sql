-- ProteusOps fix H3c — change-feed URL check used an invalid regex repetition count
-- Found live (2026-09-23): GitHub workflow_run delivery 7518b880... -> 500 "invalid regular expression: invalid
-- repetition count(s)" (SQLSTATE 2201B). The url CHECK used [^\s]{1,1000}; PostgreSQL caps bounded repetition at 255.
-- The selftest never ingested an event carrying a url, so it was not caught. Fix: length() + unbounded \S+ ;
-- ingest now drops (nulls) a malformed/non-https url instead of failing the whole delivery; selftest covers urls.
do $$ declare c text; begin
  for c in select conname from pg_constraint where conrelid = 'pods_provisioning.hub_change_events_v1'::regclass
            and contype = 'c' and pg_get_constraintdef(oid) like '%url%' loop
    execute format('alter table pods_provisioning.hub_change_events_v1 drop constraint %I', c);
  end loop;
end $$;
alter table pods_provisioning.hub_change_events_v1 add constraint hub_change_events_url_ck
  check (url is null or (length(url) <= 1000 and url ~ '^https://\S+$'));

create or replace function pods_provisioning.svc_hub_change_ingest_v1(p_account_id uuid, p_events jsonb)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare a pods_provisioning.hub_accounts_v1%rowtype; e jsonb; v_res uuid; v_proj uuid; v_ins int := 0; v_dup int := 0; v_rej int := 0; n int;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'HUB_INGEST_FORBIDDEN' using errcode = '42501'; end if;
  select * into a from pods_provisioning.hub_accounts_v1 where account_id = p_account_id;
  if not found or a.status <> 'active' then raise exception 'HUB_ACCOUNT_NOT_FOUND'; end if;
  if jsonb_typeof(p_events) <> 'array' or jsonb_array_length(p_events) > 500 then raise exception 'HUB_INGEST_INVALID'; end if;
  for e in select * from jsonb_array_elements(p_events) loop
    if pods_provisioning._hub_text_looks_secret_v1(e::text) then v_rej := v_rej + 1; continue; end if;
    v_res := null; v_proj := null;
    if e ? 'resource_kind' and e ? 'resource_external_id' then
      select resource_id, project_id into v_res, v_proj from pods_provisioning.hub_resources_v1
       where account_id = p_account_id and kind = e->>'resource_kind' and external_id = e->>'resource_external_id';
    end if;
    insert into pods_provisioning.hub_change_events_v1(org_id, account_id, resource_id, project_id, provider_key, change_type,
      severity, summary, actor, url, details, source, dedupe_key, occurred_at)
    values (a.org_id, p_account_id, v_res, v_proj, a.provider_key, e->>'change_type', coalesce(e->>'severity','info'),
      left(e->>'summary', 500), left(e->>'actor', 200),
      case when length(e->>'url') <= 1000 and e->>'url' ~ '^https://\S+$' then e->>'url' end, coalesce(e->'details','{}'::jsonb),
      coalesce(e->>'source','webhook'), e->>'dedupe_key', coalesce((e->>'occurred_at')::timestamptz, now()))
    on conflict (provider_key, dedupe_key) do nothing;
    get diagnostics n = row_count;
    if n = 1 then v_ins := v_ins + 1; else v_dup := v_dup + 1; end if;
  end loop;
  if v_rej > 0 then
    insert into pods.audit_log(org_id, actor_role_key, action_key, entity_table, entity_id, details)
    values (a.org_id, 'service', 'hub.change_rejected_secret_like', 'hub_accounts_v1', p_account_id::text, jsonb_build_object('count', v_rej));
  end if;
  return jsonb_build_object('inserted', v_ins, 'duplicates', v_dup, 'rejected_secret_like', v_rej);
end $fn$;

create or replace function pods_provisioning.rpc_selftest_hub_feed_urls_v1()
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare v_sfx text := replace(gen_random_uuid()::text,'-',''); v_org uuid; a uuid; r jsonb; long_url text;
  t_ok_url bool; t_long bool; t_bad bool; t_len bool; v_ok bool;
begin
  insert into pods.orgs(slug, name) values ('selftest-url-'||v_sfx, 'selftest url') returning org_id into v_org;
  insert into pods_provisioning.hub_accounts_v1(org_id, provider_key, display_name) values (v_org, 'github', 'x') returning account_id into a;
  long_url := 'https://github.com/acme/web/compare/' || repeat('a', 900);
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  r := public.svc_hub_change_ingest_v1(a, jsonb_build_array(
    jsonb_build_object('change_type','ci.failure','summary','ci failed','dedupe_key','u1:'||v_sfx,'url','https://github.com/acme/web/actions/runs/1'),
    jsonb_build_object('change_type','repo.push','summary','push','dedupe_key','u2:'||v_sfx,'url', long_url),
    jsonb_build_object('change_type','repo.push','summary','push','dedupe_key','u3:'||v_sfx,'url','javascript:alert(1)'),
    jsonb_build_object('change_type','repo.push','summary','push','dedupe_key','u4:'||v_sfx,'url','https://x.test/'||repeat('b', 1200))));
  perform set_config('request.jwt.claims', '', true);
  t_ok_url := (select url from pods_provisioning.hub_change_events_v1 where dedupe_key = 'u1:'||v_sfx) = 'https://github.com/acme/web/actions/runs/1';
  t_long := (select url from pods_provisioning.hub_change_events_v1 where dedupe_key = 'u2:'||v_sfx) = long_url;
  t_bad := (select url is null from pods_provisioning.hub_change_events_v1 where dedupe_key = 'u3:'||v_sfx);
  t_len := (select url is null from pods_provisioning.hub_change_events_v1 where dedupe_key = 'u4:'||v_sfx) and (r->>'inserted')::int = 4;
  delete from pods.orgs where org_id = v_org;
  v_ok := coalesce(t_ok_url,false) and coalesce(t_long,false) and coalesce(t_bad,false) and coalesce(t_len,false);
  return jsonb_build_object('ok', v_ok, 'token', case when v_ok then 'PROTEUSOPS_HUB_FEED_URLS_OK' else 'PROTEUSOPS_HUB_FEED_URLS_FAIL' end,
    'https_kept', t_ok_url, 'long_https_kept', t_long, 'non_https_dropped', t_bad, 'over_1000_dropped_batch_ok', t_len);
end $fn$;
revoke all on function pods_provisioning.rpc_selftest_hub_feed_urls_v1() from public, anon, authenticated;

select pods_provisioning.rpc_selftest_hub_feed_urls_v1();
