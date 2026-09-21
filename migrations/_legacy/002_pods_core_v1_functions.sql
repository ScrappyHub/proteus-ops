-- pods.core.v1 — helper functions + entitlement recompute
begin;

-- -------------------------------------------------------------------
-- Helper: current user's role in an org
-- Supabase provides auth.uid()
-- Returns NULL if not a member.
-- -------------------------------------------------------------------
create or replace function pods.org_role(p_org_id uuid)
returns text
language sql
stable
security invoker
set search_path = pods, public
as $$
  select m.role_key
  from pods.org_members m
  where m.org_id = p_org_id
    and m.user_id = auth.uid()
  limit 1
$$;

-- -------------------------------------------------------------------
-- Helper: capability lookup (bool/int/text)
-- Use these as building blocks; enforcement usually happens in RPC/constraints.
-- -------------------------------------------------------------------
create or replace function pods.has_cap_bool(p_org_id uuid, p_capability_key text)
returns boolean
language sql
stable
security invoker
set search_path = pods, public
as $$
  select coalesce(e.value_bool, false)
  from pods.org_entitlements e
  where e.org_id = p_org_id
    and e.capability_key = p_capability_key
    and e.value_type = 'bool'
  limit 1
$$;

create or replace function pods.cap_int(p_org_id uuid, p_capability_key text)
returns bigint
language sql
stable
security invoker
set search_path = pods, public
as $$
  select e.value_int
  from pods.org_entitlements e
  where e.org_id = p_org_id
    and e.capability_key = p_capability_key
    and e.value_type = 'int'
  limit 1
$$;

-- -------------------------------------------------------------------
-- Active subscription predicate (policy knob)
-- You can adjust allowed statuses & grace in one place.
-- -------------------------------------------------------------------
create or replace function pods.is_paid_active(p_org_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = pods, public
as $$
  select exists (
    select 1
    from pods.subscriptions s
    where s.org_id = p_org_id
      and s.status in ('active','trialing') -- conservative v1
      and (s.current_period_end is null or s.current_period_end >= now())
  )
$$;

-- -------------------------------------------------------------------
-- Recompute entitlements: materialize org_entitlements from plan + overrides
-- SECURITY DEFINER so it can update materialized table even if called server-side.
-- Restrict execution via GRANT in RLS migration.
-- -------------------------------------------------------------------
create or replace function pods.rpc_recompute_entitlements(p_org_id uuid)
returns void
language plpgsql
security definer
set search_path = pods, public
as $$
declare
  v_plan_id text;
begin
  -- Determine active plan (choose newest updated subscription)
  select s.plan_id into v_plan_id
  from pods.subscriptions s
  where s.org_id = p_org_id
  order by s.updated_at desc
  limit 1;

  -- Clear existing
  delete from pods.org_entitlements where org_id = p_org_id;

  -- Apply plan capabilities (if plan exists)
  if v_plan_id is not null then
    insert into pods.org_entitlements(org_id, capability_key, value_type, value_bool, value_int, value_text, source, computed_at)
    select
      p_org_id,
      pc.capability_key,
      pc.value_type,
      pc.value_bool,
      pc.value_int,
      pc.value_text,
      'plan',
      now()
    from pods.plan_capabilities pc
    where pc.plan_id = v_plan_id;
  end if;

  -- Apply overrides (non-expired) on top (upsert)
  insert into pods.org_entitlements(org_id, capability_key, value_type, value_bool, value_int, value_text, source, computed_at)
  select
    o.org_id,
    o.capability_key,
    o.value_type,
    o.value_bool,
    o.value_int,
    o.value_text,
    'override',
    now()
  from pods.entitlement_overrides o
  where o.org_id = p_org_id
    and (o.expires_at is null or o.expires_at > now())
  on conflict (org_id, capability_key) do update set
    value_type  = excluded.value_type,
    value_bool  = excluded.value_bool,
    value_int   = excluded.value_int,
    value_text  = excluded.value_text,
    source      = excluded.source,
    computed_at = excluded.computed_at;

  -- System-enforced caps (optional hooks). Example: hard-disable everything when not paid-active
  -- You can implement conservative gating by writing required caps here.
  if not pods.is_paid_active(p_org_id) then
    -- Example: enforce paid-required features off by default. Keep this minimal in v1; expand later.
    insert into pods.org_entitlements(org_id, capability_key, value_type, value_bool, source, computed_at)
    values
      (p_org_id, 'paid_active', 'bool', false, 'system', now())
    on conflict (org_id, capability_key) do update set
      value_type='bool', value_bool=false, source='system', computed_at=now();
  else
    insert into pods.org_entitlements(org_id, capability_key, value_type, value_bool, source, computed_at)
    values
      (p_org_id, 'paid_active', 'bool', true, 'system', now())
    on conflict (org_id, capability_key) do update set
      value_type='bool', value_bool=true, source='system', computed_at=now();
  end if;

  -- Audit
  insert into pods.audit_log(org_id, actor_user_id, actor_role_key, action_key, details)
  values (p_org_id, null, 'system', 'entitlements.recompute', jsonb_build_object('plan_id', v_plan_id));

end;
$$;

commit;