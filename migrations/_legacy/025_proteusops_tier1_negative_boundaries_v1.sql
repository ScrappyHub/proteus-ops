begin;

create table if not exists pods_core.lane_negative_boundaries_v1 (
  boundary_key text primary key,
  source_lane text not null,
  target_lane text not null,
  action_kind text not null,
  allowed boolean not null,
  enforcement_mode text not null default 'deny',
  rationale text not null,
  created_at timestamptz not null default now(),
  constraint lane_negative_boundaries_source_ck
    check (source_lane in ('core','ops','public','billing')),
  constraint lane_negative_boundaries_target_ck
    check (target_lane in ('core','ops','public','billing')),
  constraint lane_negative_boundaries_action_ck
    check (action_kind in ('read','write','execute','expose'))
);

insert into pods_core.lane_negative_boundaries_v1
  (boundary_key, source_lane, target_lane, action_kind, allowed, enforcement_mode, rationale)
values
  ('public_to_core_write','public','core','write',false,'deny','public lane must not write core truth directly'),
  ('public_to_ops_write','public','ops','write',false,'deny','public lane must not write operational truth directly'),
  ('public_to_billing_write','public','billing','write',false,'deny','public lane must not write billing truth directly'),
  ('ops_to_core_write','ops','core','write',false,'deny','ops lane must not mutate core roots directly'),
  ('ops_to_billing_write','ops','billing','write',false,'deny','ops lane must not mutate billing truth directly'),
  ('billing_to_ops_write','billing','ops','write',false,'deny','billing lane must not mutate appointments or operational rows directly'),
  ('billing_to_core_write','billing','core','write',false,'deny','billing lane must not mutate org/membership truth directly'),
  ('core_to_ops_write','core','ops','write',false,'deny','core lane must not bypass ops rpc boundary for operational rows'),
  ('core_to_public_write','core','public','write',false,'deny','core lane must not use public surfaces as write path'),
  ('ops_to_public_expose','ops','public','expose',false,'deny','ops lane must not expose base operational truth directly'),
  ('billing_to_public_expose','billing','public','expose',false,'deny','billing lane must not expose billing internals directly'),
  ('public_to_core_read','public','core','read',false,'deny','public lane must not directly read protected core internals'),
  ('public_to_billing_read','public','billing','read',false,'deny','public lane must not directly read billing internals'),
  ('public_to_public_execute','public','public','execute',true,'allow','public wrappers may execute public-safe wrapper routines'),
  ('core_to_core_execute','core','core','execute',true,'allow','core internal routines may execute within core boundary'),
  ('ops_to_ops_execute','ops','ops','execute',true,'allow','ops internal routines may execute within ops boundary'),
  ('billing_to_billing_execute','billing','billing','execute',true,'allow','billing internal routines may execute within billing boundary')
on conflict (boundary_key) do update
set source_lane = excluded.source_lane,
    target_lane = excluded.target_lane,
    action_kind = excluded.action_kind,
    allowed = excluded.allowed,
    enforcement_mode = excluded.enforcement_mode,
    rationale = excluded.rationale;

create or replace function pods_core.get_lane_for_schema_v1(p_schema text)
returns text
language sql
stable
as $$
  select case lower(coalesce(p_schema,''))
    when 'pods_core' then 'core'
    when 'pods_ops' then 'ops'
    when 'pods_public' then 'public'
    when 'pods_billing' then 'billing'
    else null
  end
$$;

create or replace function pods_core.assert_lane_boundary_v1(
  p_source_lane text,
  p_target_schema text,
  p_action_kind text
)
returns boolean
language plpgsql
stable
as $$
declare
  v_source text;
  v_target text;
  v_allowed boolean;
begin
  v_source := lower(coalesce(p_source_lane,''));
  v_target := pods_core.get_lane_for_schema_v1(p_target_schema);

  if v_source not in ('core','ops','public','billing') then
    raise exception 'LANE_BOUNDARY_UNKNOWN_SOURCE:%', coalesce(p_source_lane,'<null>');
  end if;

  if v_target is null then
    raise exception 'LANE_BOUNDARY_UNKNOWN_TARGET_SCHEMA:%', coalesce(p_target_schema,'<null>');
  end if;

  if lower(coalesce(p_action_kind,'')) not in ('read','write','execute','expose') then
    raise exception 'LANE_BOUNDARY_UNKNOWN_ACTION:%', coalesce(p_action_kind,'<null>');
  end if;

  select b.allowed
    into v_allowed
  from pods_core.lane_negative_boundaries_v1 b
  where b.source_lane = v_source
    and b.target_lane = v_target
    and b.action_kind = lower(p_action_kind)
  limit 1;

  if v_allowed is null then
    if v_source = v_target then
      return true;
    end if;
    raise exception 'LANE_BOUNDARY_RULE_MISSING:%:%:%', v_source, v_target, lower(p_action_kind);
  end if;

  if v_allowed = false then
    raise exception 'LANE_BOUNDARY_DENY:%:%:%', v_source, v_target, lower(p_action_kind);
  end if;

  return true;
end
$$;

comment on function pods_core.assert_lane_boundary_v1(text,text,text) is
'Asserts Tier-1 lane boundary rules. Raises deterministic deny/missing tokens for illegal cross-lane actions.';

create or replace view pods_core.v_lane_negative_boundaries_v1 as
select
  boundary_key,
  source_lane,
  target_lane,
  action_kind,
  allowed,
  enforcement_mode,
  rationale,
  created_at
from pods_core.lane_negative_boundaries_v1
order by source_lane, target_lane, action_kind, boundary_key;

comment on view pods_core.v_lane_negative_boundaries_v1 is
'Readable contract surface for ProteusOps Tier-1 negative lane boundaries.';

commit;