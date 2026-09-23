-- ProteusOps slice H3a — change feed + watch rules (docs/proposals/WORKSPACE_HUB_v1.md §2.5)
-- One normalized "what changed" timeline per workspace, fed by provider adapters (GitHub first) and by
-- ProteusOps itself (stage transitions, credential/resource changes). Events are idempotent on
-- (provider_key, dedupe_key). Summaries/details are size-capped and refused if they look like they carry
-- secrets. Watch rules let each member choose what they want surfaced; the feed can be filtered to "mine".
-- Writes: service_role only (adapters). Reads: workspace members via RPC. RLS on, no table grants.

create table if not exists pods_provisioning.hub_change_events_v1 (
  event_id uuid primary key default gen_random_uuid(),
  org_id uuid not null references pods.orgs(org_id) on delete cascade,
  account_id uuid references pods_provisioning.hub_accounts_v1(account_id) on delete set null,
  resource_id uuid references pods_provisioning.hub_resources_v1(resource_id) on delete set null,
  project_id uuid references pods_provisioning.hub_projects_v1(project_id) on delete set null,
  provider_key text not null check (provider_key ~ '^[a-z0-9][a-z0-9_-]{1,31}$'),
  change_type text not null check (change_type ~ '^[a-z][a-z0-9_.]{1,63}$'),
  severity text not null default 'info' check (severity in ('info','notice','warning','critical')),
  summary text not null check (length(btrim(summary)) between 1 and 500),
  actor text check (actor is null or length(actor) <= 200),
  url text check (url is null or url ~ '^https://[^\s]{1,1000}$'),
  details jsonb not null default '{}'::jsonb check (jsonb_typeof(details) = 'object' and length(details::text) <= 16384),
  source text not null check (source in ('webhook','poll','manual','system')),
  dedupe_key text not null check (length(dedupe_key) between 1 and 300),
  occurred_at timestamptz not null,
  received_at timestamptz not null default now(),
  unique (provider_key, dedupe_key)
);
create index if not exists hub_change_events_v1_org_time_idx on pods_provisioning.hub_change_events_v1(org_id, occurred_at desc);
create index if not exists hub_change_events_v1_project_idx on pods_provisioning.hub_change_events_v1(project_id, occurred_at desc);

create table if not exists pods_provisioning.hub_watch_rules_v1 (
  watch_rule_id uuid primary key default gen_random_uuid(),
  org_id uuid not null references pods.orgs(org_id) on delete cascade,
  user_id uuid not null,
  provider_key text,
  change_type_prefix text check (change_type_prefix is null or change_type_prefix ~ '^[a-z][a-z0-9_.]{0,63}$'),
  project_id uuid references pods_provisioning.hub_projects_v1(project_id) on delete cascade,
  min_severity text not null default 'info' check (min_severity in ('info','notice','warning','critical')),
  channel text not null default 'in_app' check (channel in ('in_app','email')),
  created_at timestamptz not null default now()
);
create index if not exists hub_watch_rules_v1_user_idx on pods_provisioning.hub_watch_rules_v1(org_id, user_id);

create table if not exists pods_provisioning.hub_feed_cursors_v1 (
  org_id uuid not null references pods.orgs(org_id) on delete cascade,
  user_id uuid not null,
  last_seen_at timestamptz not null default now(),
  primary key (org_id, user_id)
);

alter table pods_provisioning.hub_change_events_v1 enable row level security;
alter table pods_provisioning.hub_watch_rules_v1   enable row level security;
alter table pods_provisioning.hub_feed_cursors_v1  enable row level security;
revoke all on pods_provisioning.hub_change_events_v1, pods_provisioning.hub_watch_rules_v1,
  pods_provisioning.hub_feed_cursors_v1 from anon, authenticated;

create or replace function pods_provisioning._hub_severity_rank_v1(p text)
returns int language sql immutable set search_path = pg_catalog as $fn$
  select case p when 'critical' then 4 when 'warning' then 3 when 'notice' then 2 else 1 end $fn$;

create or replace function pods_provisioning._hub_text_looks_secret_v1(p text)
returns boolean language sql immutable set search_path = pg_catalog as $fn$
  select coalesce(p,'') ~ '(ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk_(live|test)_[A-Za-z0-9]{10,}|rk_live_[A-Za-z0-9]{10,}|whsec_[A-Za-z0-9]{10,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.)' $fn$;

-- ---------- ingest (service) ----------
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
      left(e->>'summary', 500), left(e->>'actor', 200), e->>'url', coalesce(e->'details','{}'::jsonb),
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

-- ProteusOps' own events (called from other hub functions / triggers)
create or replace function pods_provisioning._hub_system_event_v1(p_org uuid, p_project uuid, p_type text, p_severity text, p_summary text, p_details jsonb)
returns void language sql security definer set search_path = pods_provisioning, public as $fn$
  insert into pods_provisioning.hub_change_events_v1(org_id, project_id, provider_key, change_type, severity, summary, details, source, dedupe_key, occurred_at)
  values (p_org, p_project, 'proteusops', p_type, p_severity, left(p_summary, 500), coalesce(p_details,'{}'::jsonb), 'system',
          gen_random_uuid()::text, now()) $fn$;

create or replace function pods_provisioning._hub_transition_event_trg_v1()
returns trigger language plpgsql security definer set search_path = pods_provisioning, public as $fn$
begin
  perform pods_provisioning._hub_system_event_v1(new.org_id, new.project_id,
    case when new.decision = 'allowed' then 'stage.changed' else 'stage.refused' end,
    case when new.decision = 'allowed' and new.to_stage in ('active','launch_review','paused') then 'notice'
         when new.decision = 'refused' then 'warning' else 'info' end,
    format('%s: %s -> %s', case when new.decision = 'allowed' then 'Stage changed' else 'Stage change refused' end, new.from_stage, new.to_stage),
    jsonb_build_object('transition_id', new.transition_id));
  return new;
end $fn$;
drop trigger if exists hub_transition_event on pods_provisioning.hub_stage_transitions_v1;
create trigger hub_transition_event after insert on pods_provisioning.hub_stage_transitions_v1
  for each row execute function pods_provisioning._hub_transition_event_trg_v1();

create or replace function pods_provisioning._hub_credential_event_trg_v1()
returns trigger language plpgsql security definer set search_path = pods_provisioning, public as $fn$
begin
  if tg_op = 'INSERT' then
    perform pods_provisioning._hub_system_event_v1(new.org_id, new.project_id, 'credential.added', 'notice',
      format('Credential added: %s (%s)', new.purpose, new.environment), jsonb_build_object('credential_id', new.credential_id, 'fingerprint', new.fingerprint));
  elsif new.status is distinct from old.status and new.status in ('revoked','invalid') then
    perform pods_provisioning._hub_system_event_v1(new.org_id, new.project_id, 'credential.'||new.status,
      case when new.environment = 'live' then 'critical' else 'warning' end,
      format('Credential %s: %s (%s)', new.status, new.purpose, new.environment), jsonb_build_object('credential_id', new.credential_id));
  elsif new.fingerprint is distinct from old.fingerprint then
    perform pods_provisioning._hub_system_event_v1(new.org_id, new.project_id, 'credential.rotated', 'notice',
      format('Credential rotated: %s (%s)', new.purpose, new.environment), jsonb_build_object('credential_id', new.credential_id, 'fingerprint', new.fingerprint));
  end if;
  return new;
end $fn$;
drop trigger if exists hub_credential_event on pods_provisioning.hub_credentials_v1;
create trigger hub_credential_event after insert or update on pods_provisioning.hub_credentials_v1
  for each row execute function pods_provisioning._hub_credential_event_trg_v1();

create or replace function pods_provisioning._hub_resource_event_trg_v1()
returns trigger language plpgsql security definer set search_path = pods_provisioning, public as $fn$
begin
  if new.status = 'missing' and old.status is distinct from 'missing' then
    perform pods_provisioning._hub_system_event_v1(new.org_id, new.project_id, 'resource.missing',
      case when new.environment = 'live' then 'critical' else 'warning' end,
      format('Resource no longer reported by provider: %s %s', new.kind, new.display_name), jsonb_build_object('resource_id', new.resource_id));
  end if;
  return new;
end $fn$;
drop trigger if exists hub_resource_event on pods_provisioning.hub_resources_v1;
create trigger hub_resource_event after update on pods_provisioning.hub_resources_v1
  for each row execute function pods_provisioning._hub_resource_event_trg_v1();

-- ---------- member RPCs ----------
create or replace function pods_provisioning.rpc_hub_feed_v1(p_org_id uuid, p_project_id uuid, p_only_watched boolean,
  p_min_severity text, p_before timestamptz, p_limit int)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare v_uid uuid := auth.uid(); v_last timestamptz; v_lim int := least(greatest(coalesce(p_limit, 50), 1), 200); v_out jsonb;
begin
  perform pods_provisioning._hub_authorize_v1(p_org_id, array['owner','admin','staff']);
  select last_seen_at into v_last from pods_provisioning.hub_feed_cursors_v1 where org_id = p_org_id and user_id = v_uid;
  select coalesce(jsonb_agg(x order by (x->>'occurred_at') desc), '[]'::jsonb) into v_out from (
    select jsonb_build_object('event_id', e.event_id, 'provider', e.provider_key, 'type', e.change_type, 'severity', e.severity,
      'summary', e.summary, 'actor', e.actor, 'url', e.url, 'project_id', e.project_id, 'resource_id', e.resource_id,
      'account_id', e.account_id, 'occurred_at', e.occurred_at, 'details', e.details,
      'unread', v_last is null or e.received_at > v_last) x
      from pods_provisioning.hub_change_events_v1 e
     where e.org_id = p_org_id
       and (p_project_id is null or e.project_id = p_project_id
            or e.project_id in (with recursive d as (select p_project_id pid union all
                   select c.project_id from pods_provisioning.hub_projects_v1 c join d on c.parent_project_id = d.pid) select pid from d))
       and pods_provisioning._hub_severity_rank_v1(e.severity) >= pods_provisioning._hub_severity_rank_v1(coalesce(p_min_severity,'info'))
       and (p_before is null or e.occurred_at < p_before)
       and (not coalesce(p_only_watched,false) or exists (select 1 from pods_provisioning.hub_watch_rules_v1 w
             where w.org_id = p_org_id and w.user_id = v_uid
               and (w.provider_key is null or w.provider_key = e.provider_key)
               and (w.change_type_prefix is null or e.change_type like w.change_type_prefix || '%')
               and (w.project_id is null or w.project_id = e.project_id)
               and pods_provisioning._hub_severity_rank_v1(e.severity) >= pods_provisioning._hub_severity_rank_v1(w.min_severity)))
     order by e.occurred_at desc limit v_lim) s;
  return jsonb_build_object('events', v_out, 'last_seen_at', v_last);
end $fn$;

create or replace function pods_provisioning.rpc_hub_feed_mark_seen_v1(p_org_id uuid)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
begin
  perform pods_provisioning._hub_authorize_v1(p_org_id, array['owner','admin','staff']);
  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = '42501'; end if;
  insert into pods_provisioning.hub_feed_cursors_v1(org_id, user_id, last_seen_at) values (p_org_id, auth.uid(), now())
  on conflict (org_id, user_id) do update set last_seen_at = now();
  return jsonb_build_object('last_seen_at', now());
end $fn$;

create or replace function pods_provisioning.rpc_hub_watch_rule_set_v1(p_org_id uuid, p_watch_rule_id uuid, p_provider_key text,
  p_change_type_prefix text, p_project_id uuid, p_min_severity text, p_channel text, p_delete boolean)
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare v_id uuid; v_n int;
begin
  perform pods_provisioning._hub_authorize_v1(p_org_id, array['owner','admin','staff']);
  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = '42501'; end if;
  if p_project_id is not null and not exists (select 1 from pods_provisioning.hub_projects_v1 where project_id = p_project_id and org_id = p_org_id) then
    raise exception 'HUB_PROJECT_NOT_FOUND';
  end if;
  if coalesce(p_delete,false) then
    delete from pods_provisioning.hub_watch_rules_v1 where watch_rule_id = p_watch_rule_id and org_id = p_org_id and user_id = auth.uid();
    return jsonb_build_object('deleted', found);
  end if;
  if p_watch_rule_id is null then
    select count(*) into v_n from pods_provisioning.hub_watch_rules_v1 where org_id = p_org_id and user_id = auth.uid();
    if v_n >= 100 then raise exception 'HUB_WATCH_RULE_LIMIT'; end if;
    insert into pods_provisioning.hub_watch_rules_v1(org_id, user_id, provider_key, change_type_prefix, project_id, min_severity, channel)
    values (p_org_id, auth.uid(), lower(p_provider_key), p_change_type_prefix, p_project_id, coalesce(p_min_severity,'info'), coalesce(p_channel,'in_app'))
    returning watch_rule_id into v_id;
  else
    update pods_provisioning.hub_watch_rules_v1 set provider_key = lower(p_provider_key), change_type_prefix = p_change_type_prefix,
      project_id = p_project_id, min_severity = coalesce(p_min_severity,'info'), channel = coalesce(p_channel,'in_app')
     where watch_rule_id = p_watch_rule_id and org_id = p_org_id and user_id = auth.uid() returning watch_rule_id into v_id;
    if v_id is null then raise exception 'HUB_WATCH_RULE_NOT_FOUND'; end if;
  end if;
  return jsonb_build_object('watch_rule_id', v_id);
end $fn$;

create or replace function pods_provisioning.rpc_hub_watch_rules_list_v1(p_org_id uuid)
returns jsonb language plpgsql stable security definer set search_path = pods_provisioning, pods, public as $fn$
begin
  perform pods_provisioning._hub_authorize_v1(p_org_id, array['owner','admin','staff']);
  return coalesce((select jsonb_agg(jsonb_build_object('watch_rule_id', watch_rule_id, 'provider', provider_key,
    'change_type_prefix', change_type_prefix, 'project_id', project_id, 'min_severity', min_severity, 'channel', channel) order by created_at)
    from pods_provisioning.hub_watch_rules_v1 where org_id = p_org_id and user_id = auth.uid()), '[]'::jsonb);
end $fn$;

-- ---------- adapter helpers (service) ----------
-- find the account + its active webhook credential for an inbound provider webhook
create or replace function pods_provisioning.svc_hub_webhook_target_v1(p_account_id uuid, p_provider_key text)
returns jsonb language plpgsql stable security definer set search_path = pods_provisioning, public as $fn$
declare a pods_provisioning.hub_accounts_v1%rowtype; v_cred uuid;
begin
  if auth.role() is distinct from 'service_role' then raise exception 'HUB_WEBHOOK_FORBIDDEN' using errcode = '42501'; end if;
  select * into a from pods_provisioning.hub_accounts_v1 where account_id = p_account_id and provider_key = p_provider_key and status = 'active';
  if not found then return jsonb_build_object('found', false); end if;
  select credential_id into v_cred from pods_provisioning.hub_credentials_v1
   where account_id = p_account_id and purpose = 'webhook' and storage_kind = 'vault' and status <> 'revoked'
     and (rotates_at is null or rotates_at > now()) order by created_at desc limit 1;
  return jsonb_build_object('found', true, 'org_id', a.org_id, 'credential_id', v_cred);
end $fn$;

-- list accounts of a provider that have a usable API credential (for scheduled sync)
create or replace function pods_provisioning.svc_hub_sync_targets_v1(p_provider_key text)
returns jsonb language plpgsql stable security definer set search_path = pods_provisioning, public as $fn$
begin
  if auth.role() is distinct from 'service_role' then raise exception 'HUB_SYNC_FORBIDDEN' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('account_id', a.account_id, 'org_id', a.org_id, 'external_ref', a.external_ref,
      'credential_id', c.credential_id))
    from pods_provisioning.hub_accounts_v1 a
    join lateral (select credential_id from pods_provisioning.hub_credentials_v1 c
                   where c.account_id = a.account_id and c.purpose = 'api' and c.storage_kind in ('vault','provider_oauth')
                     and c.status <> 'revoked' and (c.rotates_at is null or c.rotates_at > now())
                   order by c.created_at desc limit 1) c on true
   where a.provider_key = p_provider_key and a.status = 'active'), '[]'::jsonb);
end $fn$;

-- ---------- grants + wrappers ----------
do $$ declare s text; begin
  foreach s in array array[
    'pods_provisioning._hub_severity_rank_v1(text)', 'pods_provisioning._hub_text_looks_secret_v1(text)',
    'pods_provisioning.svc_hub_change_ingest_v1(uuid,jsonb)', 'pods_provisioning._hub_system_event_v1(uuid,uuid,text,text,text,jsonb)',
    'pods_provisioning._hub_transition_event_trg_v1()', 'pods_provisioning._hub_credential_event_trg_v1()', 'pods_provisioning._hub_resource_event_trg_v1()',
    'pods_provisioning.rpc_hub_feed_v1(uuid,uuid,boolean,text,timestamp with time zone,integer)', 'pods_provisioning.rpc_hub_feed_mark_seen_v1(uuid)',
    'pods_provisioning.rpc_hub_watch_rule_set_v1(uuid,uuid,text,text,uuid,text,text,boolean)', 'pods_provisioning.rpc_hub_watch_rules_list_v1(uuid)',
    'pods_provisioning.svc_hub_webhook_target_v1(uuid,text)', 'pods_provisioning.svc_hub_sync_targets_v1(text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', s);
    execute format('grant execute on function %s to service_role', s);
  end loop;
end $$;

create or replace function public.rpc_hub_feed_v1(p_org_id uuid, p_project_id uuid default null, p_only_watched boolean default false,
  p_min_severity text default 'info', p_before timestamptz default null, p_limit int default 50)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_feed_v1(p_org_id, p_project_id, p_only_watched, p_min_severity, p_before, p_limit) $fn$;
create or replace function public.rpc_hub_feed_mark_seen_v1(p_org_id uuid)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_feed_mark_seen_v1(p_org_id) $fn$;
create or replace function public.rpc_hub_watch_rule_set_v1(p_org_id uuid, p_watch_rule_id uuid, p_provider_key text, p_change_type_prefix text,
  p_project_id uuid, p_min_severity text, p_channel text, p_delete boolean default false)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_watch_rule_set_v1(p_org_id, p_watch_rule_id, p_provider_key, p_change_type_prefix, p_project_id, p_min_severity, p_channel, p_delete) $fn$;
create or replace function public.rpc_hub_watch_rules_list_v1(p_org_id uuid)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.rpc_hub_watch_rules_list_v1(p_org_id) $fn$;
create or replace function public.svc_hub_change_ingest_v1(p_account_id uuid, p_events jsonb)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.svc_hub_change_ingest_v1(p_account_id, p_events) $fn$;
create or replace function public.svc_hub_webhook_target_v1(p_account_id uuid, p_provider_key text)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.svc_hub_webhook_target_v1(p_account_id, p_provider_key) $fn$;
create or replace function public.svc_hub_sync_targets_v1(p_provider_key text)
returns jsonb language sql security definer set search_path = pods_provisioning, public as $fn$
  select pods_provisioning.svc_hub_sync_targets_v1(p_provider_key) $fn$;
do $$ declare s text; begin
  foreach s in array array['public.svc_hub_change_ingest_v1(uuid,jsonb)', 'public.svc_hub_webhook_target_v1(uuid,text)', 'public.svc_hub_sync_targets_v1(text)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', s);
    execute format('grant execute on function %s to service_role', s);
  end loop;
end $$;

do $$ declare v text[]; begin
  v := pods_core.api_client_allowlist_v1() || array[
    'public.rpc_hub_feed_v1(uuid,uuid,boolean,text,timestamp with time zone,integer)',
    'public.rpc_hub_feed_mark_seen_v1(uuid)',
    'public.rpc_hub_watch_rule_set_v1(uuid,uuid,text,text,uuid,text,text,boolean)',
    'public.rpc_hub_watch_rules_list_v1(uuid)'];
  execute format($f$create or replace function pods_core.api_client_allowlist_v1() returns text[] language sql immutable
    set search_path = pods_core, public as $b$ select %L::text[] $b$ $f$, (select array_agg(distinct x order by x) from unnest(v) x));
end $$;
revoke all on function pods_core.api_client_allowlist_v1() from public, anon, authenticated;
do $$ declare a text; begin
  foreach a in array array['public.rpc_hub_feed_v1(uuid,uuid,boolean,text,timestamp with time zone,integer)','public.rpc_hub_feed_mark_seen_v1(uuid)',
    'public.rpc_hub_watch_rule_set_v1(uuid,uuid,text,text,uuid,text,text,boolean)','public.rpc_hub_watch_rules_list_v1(uuid)'] loop
    execute format('revoke all on function %s from public, anon', a);
    execute format('grant execute on function %s to authenticated, service_role', a);
  end loop;
end $$;

-- ---------- selftest ----------
create or replace function pods_provisioning.rpc_selftest_hub_feed_v1()
returns jsonb language plpgsql security definer set search_path = pods_provisioning, pods, public as $fn$
declare v_sfx text := replace(gen_random_uuid()::text,'-',''); v_org uuid; v_org2 uuid;
  u_owner uuid := gen_random_uuid(); u_staff uuid := gen_random_uuid(); u_out uuid := gen_random_uuid();
  a_gh uuid; v_sys uuid; v_web uuid; v_res uuid; r jsonb; f jsonb; v_n int;
  t_ingest bool := false; t_dedupe bool := false; t_secret bool := false; t_link bool := false; t_client_ingest bool := false;
  t_feed bool := false; t_subtree bool := false; t_sev bool := false; t_watch bool := false; t_unread bool := false;
  t_outsider bool := false; t_system_stage bool := false; t_system_missing bool := false; t_webhook_target bool := false;
  t_watch_isolation bool := false; v_ok bool; w1 uuid;
begin
  insert into pods.orgs(slug, name) values ('selftest-feed-'||v_sfx, 'selftest feed') returning org_id into v_org;
  insert into pods.orgs(slug, name) values ('selftest-feed2-'||v_sfx, 'selftest feed2') returning org_id into v_org2;
  insert into pods.org_members(org_id, user_id, role_key) values (v_org, u_owner, 'owner'), (v_org, u_staff, 'staff'), (v_org2, u_out, 'owner');
  insert into pods_provisioning.hub_accounts_v1(org_id, provider_key, display_name, external_ref) values (v_org, 'github', 'acme', 'acme') returning account_id into a_gh;
  insert into pods_provisioning.hub_projects_v1(org_id, name, slug, origin, node_kind) values (v_org, 'Platform', 'platform', 'imported', 'system') returning project_id into v_sys;
  insert into pods_provisioning.hub_projects_v1(org_id, name, slug, origin, parent_project_id) values (v_org, 'Web', 'web', 'imported', v_sys) returning project_id into v_web;
  insert into pods_provisioning.hub_resources_v1(org_id, account_id, project_id, kind, external_id, display_name, source)
    values (v_org, a_gh, v_web, 'repo', 'acme/web', 'acme/web', 'discovery') returning resource_id into v_res;

  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_owner,'aal','aal2')::text, true);
  begin perform pods_provisioning.svc_hub_change_ingest_v1(a_gh, '[]'); exception when others then t_client_ingest := sqlerrm like '%HUB_INGEST_FORBIDDEN%'; end;
  t_client_ingest := t_client_ingest and not has_function_privilege('authenticated','public.svc_hub_change_ingest_v1(uuid,jsonb)','execute');

  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  r := public.svc_hub_change_ingest_v1(a_gh, jsonb_build_array(
    jsonb_build_object('change_type','repo.push','summary','3 commits pushed to main','dedupe_key','gh:d1','resource_kind','repo','resource_external_id','acme/web','occurred_at', now() - interval '2 minutes'),
    jsonb_build_object('change_type','repo.release','severity','notice','summary','v1.2.0 released','dedupe_key','gh:d2','occurred_at', now() - interval '1 minute'),
    jsonb_build_object('change_type','repo.push','summary','leaked ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345 in msg','dedupe_key','gh:d3')));
  t_ingest := (r->>'inserted')::int = 2;
  t_secret := (r->>'rejected_secret_like')::int = 1;
  r := public.svc_hub_change_ingest_v1(a_gh, jsonb_build_array(jsonb_build_object('change_type','repo.push','summary','dup','dedupe_key','gh:d1')));
  t_dedupe := (r->>'duplicates')::int = 1 and (r->>'inserted')::int = 0;
  t_link := exists (select 1 from pods_provisioning.hub_change_events_v1 where dedupe_key = 'gh:d1' and resource_id = v_res and project_id = v_web);
  t_webhook_target := (public.svc_hub_webhook_target_v1(a_gh, 'github')->>'found')::boolean
                  and not (public.svc_hub_webhook_target_v1(a_gh, 'gitlab')->>'found')::boolean;
  -- system events: stage transition + resource missing
  update pods_provisioning.hub_resources_v1 set status = 'missing' where resource_id = v_res;
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_owner,'aal','aal2')::text, true);
  perform public.rpc_hub_transition_v1(v_web, 'build', null);
  t_system_stage := exists (select 1 from pods_provisioning.hub_change_events_v1 where org_id = v_org and change_type = 'stage.changed' and project_id = v_web);
  t_system_missing := exists (select 1 from pods_provisioning.hub_change_events_v1 where org_id = v_org and change_type = 'resource.missing');

  f := public.rpc_hub_feed_v1(v_org, null, false, 'info', null, 50);
  t_feed := jsonb_array_length(f->'events') = 4 and (f->'events'->0->>'unread')::boolean;
  t_subtree := jsonb_array_length(public.rpc_hub_feed_v1(v_org, v_sys, false, 'info', null, 50)->'events') = 3;
  -- notice+: the release (notice) and resource.missing (warning); push and stage.changed->build are info
  t_sev := jsonb_array_length(public.rpc_hub_feed_v1(v_org, null, false, 'notice', null, 50)->'events') = 2;
  w1 := (public.rpc_hub_watch_rule_set_v1(v_org, null, 'github', 'repo.release', null, 'info', 'in_app', false)->>'watch_rule_id')::uuid;
  f := public.rpc_hub_feed_v1(v_org, null, true, 'info', null, 50);
  t_watch := jsonb_array_length(f->'events') = 1 and f->'events'->0->>'type' = 'repo.release';
  perform public.rpc_hub_feed_mark_seen_v1(v_org);
  perform set_config('request.jwt.claims', '', true);
  update pods_provisioning.hub_feed_cursors_v1 set last_seen_at = now() + interval '1 second' where org_id = v_org and user_id = u_owner;
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_owner,'aal','aal2')::text, true);
  t_unread := not exists (select 1 from jsonb_array_elements(public.rpc_hub_feed_v1(v_org, null, false, 'info', null, 50)->'events') x where (x->>'unread')::boolean);

  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_staff,'aal','aal1')::text, true);
  t_watch_isolation := jsonb_array_length(public.rpc_hub_watch_rules_list_v1(v_org)) = 0
    and not (public.rpc_hub_watch_rule_set_v1(v_org, w1, null, null, null, null, null, true)->>'deleted')::boolean;
  perform set_config('request.jwt.claims', json_build_object('role','authenticated','sub',u_out,'aal','aal2')::text, true);
  begin perform public.rpc_hub_feed_v1(v_org, null, false, 'info', null, 50); exception when others then t_outsider := sqlerrm like '%NOT_ORG_MEMBER%'; end;
  perform set_config('request.jwt.claims', '', true);

  delete from pods.audit_log where org_id in (v_org, v_org2);
  update pods_provisioning.hub_projects_v1 set parent_project_id = null where org_id in (v_org, v_org2);
  delete from pods.orgs where org_id in (v_org, v_org2);

  v_ok := t_client_ingest and t_ingest and t_secret and t_dedupe and t_link and t_webhook_target and t_system_stage and t_system_missing
      and t_feed and t_subtree and t_sev and t_watch and t_unread and t_watch_isolation and t_outsider;
  return jsonb_build_object('ok', v_ok, 'token', case when v_ok then 'PROTEUSOPS_HUB_FEED_OK' else 'PROTEUSOPS_HUB_FEED_FAIL' end,
    'client_ingest_blocked', t_client_ingest, 'ingest', t_ingest, 'secret_like_rejected', t_secret, 'dedupe', t_dedupe,
    'resource_project_link', t_link, 'webhook_target', t_webhook_target, 'system_stage_event', t_system_stage,
    'system_missing_event', t_system_missing, 'feed', t_feed, 'subtree_filter', t_subtree, 'severity_filter', t_sev,
    'watch_filter', t_watch, 'mark_seen', t_unread, 'watch_rules_private', t_watch_isolation, 'outsider_blocked', t_outsider);
end $fn$;
revoke all on function pods_provisioning.rpc_selftest_hub_feed_v1() from public, anon, authenticated;

select pods_provisioning.rpc_selftest_hub_feed_v1();
