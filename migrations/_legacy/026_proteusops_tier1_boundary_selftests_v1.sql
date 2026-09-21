begin;

create or replace function pods_core.rpc_selftest_lane_boundary_v1(
  p_source_lane text,
  p_target_schema text,
  p_action_kind text,
  p_expected_token text
)
returns jsonb
language plpgsql
security definer
set search_path = pods_core, public
as $$
declare
  v_ok boolean;
  v_msg text;
begin
  begin
    v_ok := pods_core.assert_lane_boundary_v1(
      p_source_lane,
      p_target_schema,
      p_action_kind
    );

    if coalesce(v_ok,false) is true then
      return jsonb_build_object(
        'ok', true,
        'source_lane', lower(coalesce(p_source_lane,'')),
        'target_schema', lower(coalesce(p_target_schema,'')),
        'action_kind', lower(coalesce(p_action_kind,'')),
        'token', 'LANE_BOUNDARY_ALLOW'
      );
    end if;

    return jsonb_build_object(
      'ok', false,
      'source_lane', lower(coalesce(p_source_lane,'')),
      'target_schema', lower(coalesce(p_target_schema,'')),
      'action_kind', lower(coalesce(p_action_kind,'')),
      'token', 'LANE_BOUNDARY_UNEXPECTED_FALSE'
    );
  exception
    when others then
      v_msg := sqlerrm;

      if p_expected_token is not null and position(p_expected_token in v_msg) > 0 then
        return jsonb_build_object(
          'ok', true,
          'source_lane', lower(coalesce(p_source_lane,'')),
          'target_schema', lower(coalesce(p_target_schema,'')),
          'action_kind', lower(coalesce(p_action_kind,'')),
          'token', p_expected_token,
          'message', v_msg
        );
      end if;

      return jsonb_build_object(
        'ok', false,
        'source_lane', lower(coalesce(p_source_lane,'')),
        'target_schema', lower(coalesce(p_target_schema,'')),
        'action_kind', lower(coalesce(p_action_kind,'')),
        'token', 'LANE_BOUNDARY_UNEXPECTED_EXCEPTION',
        'message', v_msg
      );
  end;
end
$$;

comment on function pods_core.rpc_selftest_lane_boundary_v1(text,text,text,text) is
'Runs deterministic Tier-1 lane boundary checks and returns structured pass/fail JSON.';

create table if not exists pods_core.lane_boundary_selftest_vectors_v1 (
  vector_key text primary key,
  source_lane text not null,
  target_schema text not null,
  action_kind text not null,
  expected_ok boolean not null,
  expected_token text not null,
  created_at timestamptz not null default now(),
  constraint lane_boundary_vectors_source_ck
    check (source_lane in ('core','ops','public','billing')),
  constraint lane_boundary_vectors_target_ck
    check (lower(target_schema) in ('pods_core','pods_ops','pods_public','pods_billing')),
  constraint lane_boundary_vectors_action_ck
    check (action_kind in ('read','write','execute','expose'))
);

insert into pods_core.lane_boundary_selftest_vectors_v1
  (vector_key, source_lane, target_schema, action_kind, expected_ok, expected_token)
values
  ('public_to_core_write_denied',   'public',  'pods_core',    'write',   true, 'LANE_BOUNDARY_DENY'),
  ('public_to_ops_write_denied',    'public',  'pods_ops',     'write',   true, 'LANE_BOUNDARY_DENY'),
  ('public_to_billing_write_denied','public',  'pods_billing', 'write',   true, 'LANE_BOUNDARY_DENY'),
  ('ops_to_core_write_denied',      'ops',     'pods_core',    'write',   true, 'LANE_BOUNDARY_DENY'),
  ('ops_to_billing_write_denied',   'ops',     'pods_billing', 'write',   true, 'LANE_BOUNDARY_DENY'),
  ('billing_to_ops_write_denied',   'billing', 'pods_ops',     'write',   true, 'LANE_BOUNDARY_DENY'),
  ('billing_to_core_write_denied',  'billing', 'pods_core',    'write',   true, 'LANE_BOUNDARY_DENY'),
  ('core_to_ops_write_denied',      'core',    'pods_ops',     'write',   true, 'LANE_BOUNDARY_DENY'),
  ('core_to_public_write_denied',   'core',    'pods_public',  'write',   true, 'LANE_BOUNDARY_DENY'),
  ('ops_to_public_expose_denied',   'ops',     'pods_public',  'expose',  true, 'LANE_BOUNDARY_DENY'),
  ('billing_to_public_expose_denied','billing','pods_public',  'expose',  true, 'LANE_BOUNDARY_DENY'),
  ('public_to_core_read_denied',    'public',  'pods_core',    'read',    true, 'LANE_BOUNDARY_DENY'),
  ('public_to_billing_read_denied', 'public',  'pods_billing', 'read',    true, 'LANE_BOUNDARY_DENY'),
  ('public_to_public_execute_allowed','public','pods_public',  'execute', true, 'LANE_BOUNDARY_ALLOW'),
  ('core_to_core_execute_allowed',  'core',    'pods_core',    'execute', true, 'LANE_BOUNDARY_ALLOW'),
  ('ops_to_ops_execute_allowed',    'ops',     'pods_ops',     'execute', true, 'LANE_BOUNDARY_ALLOW'),
  ('billing_to_billing_execute_allowed','billing','pods_billing','execute',true, 'LANE_BOUNDARY_ALLOW')
on conflict (vector_key) do update
set source_lane = excluded.source_lane,
    target_schema = excluded.target_schema,
    action_kind = excluded.action_kind,
    expected_ok = excluded.expected_ok,
    expected_token = excluded.expected_token;

create or replace function pods_core.rpc_selftest_lane_boundaries_all_v1()
returns table(
  vector_key text,
  ok boolean,
  token text,
  message text
)
language plpgsql
security definer
set search_path = pods_core, public
as $$
declare
  r record;
  j jsonb;
  v_ok boolean;
  v_token text;
  v_message text;
begin
  for r in
    select
      v.vector_key,
      v.source_lane,
      v.target_schema,
      v.action_kind,
      v.expected_ok,
      v.expected_token
    from pods_core.lane_boundary_selftest_vectors_v1 v
    order by v.vector_key
  loop
    j := pods_core.rpc_selftest_lane_boundary_v1(
      r.source_lane,
      r.target_schema,
      r.action_kind,
      case
        when r.expected_token = 'LANE_BOUNDARY_ALLOW' then null
        else r.expected_token
      end
    );

    v_ok := coalesce((j ->> 'ok')::boolean, false);
    v_token := coalesce(j ->> 'token', '');
    v_message := coalesce(j ->> 'message', '');

    if r.expected_token = 'LANE_BOUNDARY_ALLOW' then
      if not (v_ok = true and v_token = 'LANE_BOUNDARY_ALLOW') then
        raise exception 'LANE_SELFTEST_FAIL:%:%', r.vector_key, coalesce(v_token,'<null>');
      end if;
    else
      if not (v_ok = true and position(r.expected_token in v_token) > 0) then
        raise exception 'LANE_SELFTEST_FAIL:%:%', r.vector_key, coalesce(v_token,'<null>');
      end if;
    end if;

    rpc_selftest_lane_boundaries_all_v1.vector_key := r.vector_key;
    rpc_selftest_lane_boundaries_all_v1.ok := v_ok;
    rpc_selftest_lane_boundaries_all_v1.token := v_token;
    rpc_selftest_lane_boundaries_all_v1.message := v_message;
    return next;
  end loop;

  return;
end
$$;

comment on function pods_core.rpc_selftest_lane_boundaries_all_v1() is
'Executes all Tier-1 lane boundary vectors and raises deterministic failure tokens if any vector deviates from expected behavior.';

create or replace view pods_core.v_lane_boundary_selftest_vectors_v1 as
select
  v.vector_key,
  v.source_lane,
  v.target_schema,
  v.action_kind,
  v.expected_ok,
  v.expected_token,
  v.created_at
from pods_core.lane_boundary_selftest_vectors_v1 v
order by v.vector_key;

comment on view pods_core.v_lane_boundary_selftest_vectors_v1 is
'Readable Tier-1 lane boundary selftest vector registry.';

commit;