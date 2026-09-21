begin;

create table if not exists pods_public.public_surface_contracts_v1 (
  surface_key text primary key,
  object_type text not null,
  object_schema text not null,
  object_name text not null,
  exposure_kind text not null,
  public_safe boolean not null default true,
  write_enabled boolean not null default false,
  notes text not null default '',
  created_at timestamptz not null default now(),
  constraint public_surface_contracts_object_type_ck
    check (object_type in ('view','function','rpc')),
  constraint public_surface_contracts_exposure_kind_ck
    check (exposure_kind in ('read','request','execute'))
);

insert into pods_public.public_surface_contracts_v1
  (surface_key, object_type, object_schema, object_name, exposure_kind, public_safe, write_enabled, notes)
values
  ('public.rpc_request_booking_v1','function','public','rpc_request_booking_v1','request',true,true,'Public booking request wrapper only.'),
  ('public.rpc_recompute_entitlements_v1','function','public','rpc_recompute_entitlements_v1','execute',false,false,'Not public-safe; wrapper exists for controlled internal use only.'),
  ('public.rpc_selftest_add_org_member_v1','function','public','rpc_selftest_add_org_member_v1','execute',false,false,'Selftest/admin surface only; never public-safe.'),
  ('pods_core.v_lane_negative_boundaries_v1','view','pods_core','v_lane_negative_boundaries_v1','read',false,false,'Internal boundary contract view, not public-safe.'),
  ('pods_core.v_lane_boundary_selftest_vectors_v1','view','pods_core','v_lane_boundary_selftest_vectors_v1','read',false,false,'Internal selftest vector view, not public-safe.')
on conflict (surface_key) do update
set object_type = excluded.object_type,
    object_schema = excluded.object_schema,
    object_name = excluded.object_name,
    exposure_kind = excluded.exposure_kind,
    public_safe = excluded.public_safe,
    write_enabled = excluded.write_enabled,
    notes = excluded.notes;

create or replace function pods_public.assert_public_surface_allowed_v1(
  p_object_schema text,
  p_object_name text,
  p_exposure_kind text
)
returns boolean
language plpgsql
stable
as $$
declare
  v_surface_key text;
  v_public_safe boolean;
  v_exposure_kind text;
begin
  v_surface_key := lower(coalesce(p_object_schema,'')) || '.' || lower(coalesce(p_object_name,''));
  v_exposure_kind := lower(coalesce(p_exposure_kind,''));

  if v_exposure_kind not in ('read','request','execute') then
    raise exception 'PUBLIC_SURFACE_UNKNOWN_EXPOSURE:%', coalesce(p_exposure_kind,'<null>');
  end if;

  select c.public_safe
    into v_public_safe
  from pods_public.public_surface_contracts_v1 c
  where lower(c.object_schema) = lower(coalesce(p_object_schema,''))
    and lower(c.object_name) = lower(coalesce(p_object_name,''))
    and lower(c.exposure_kind) = v_exposure_kind
  limit 1;

  if v_public_safe is null then
    raise exception 'PUBLIC_SURFACE_RULE_MISSING:%', v_surface_key;
  end if;

  if v_public_safe = false then
    raise exception 'PUBLIC_SURFACE_DENY:%:%', v_surface_key, v_exposure_kind;
  end if;

  return true;
end
$$;

comment on function pods_public.assert_public_surface_allowed_v1(text,text,text) is
'Asserts whether a named public surface is allowed for public-safe exposure. Raises deterministic deny/missing tokens.';

create or replace function pods_public.rpc_selftest_public_surface_v1(
  p_object_schema text,
  p_object_name text,
  p_exposure_kind text,
  p_expected_token text
)
returns jsonb
language plpgsql
security definer
set search_path = pods_public, public
as $$
declare
  v_ok boolean;
  v_msg text;
begin
  begin
    v_ok := pods_public.assert_public_surface_allowed_v1(
      p_object_schema,
      p_object_name,
      p_exposure_kind
    );

    if coalesce(v_ok,false) is true then
      return jsonb_build_object(
        'ok', true,
        'object_schema', lower(coalesce(p_object_schema,'')),
        'object_name', lower(coalesce(p_object_name,'')),
        'exposure_kind', lower(coalesce(p_exposure_kind,'')),
        'token', 'PUBLIC_SURFACE_ALLOW'
      );
    end if;

    return jsonb_build_object(
      'ok', false,
      'object_schema', lower(coalesce(p_object_schema,'')),
      'object_name', lower(coalesce(p_object_name,'')),
      'exposure_kind', lower(coalesce(p_exposure_kind,'')),
      'token', 'PUBLIC_SURFACE_UNEXPECTED_FALSE'
    );
  exception
    when others then
      v_msg := sqlerrm;

      if p_expected_token is not null and position(p_expected_token in v_msg) > 0 then
        return jsonb_build_object(
          'ok', true,
          'object_schema', lower(coalesce(p_object_schema,'')),
          'object_name', lower(coalesce(p_object_name,'')),
          'exposure_kind', lower(coalesce(p_exposure_kind,'')),
          'token', p_expected_token,
          'message', v_msg
        );
      end if;

      return jsonb_build_object(
        'ok', false,
        'object_schema', lower(coalesce(p_object_schema,'')),
        'object_name', lower(coalesce(p_object_name,'')),
        'exposure_kind', lower(coalesce(p_exposure_kind,'')),
        'token', 'PUBLIC_SURFACE_UNEXPECTED_EXCEPTION',
        'message', v_msg
      );
  end;
end
$$;

comment on function pods_public.rpc_selftest_public_surface_v1(text,text,text,text) is
'Runs deterministic public surface allow/deny checks and returns structured pass/fail JSON.';

create table if not exists pods_public.public_surface_selftest_vectors_v1 (
  vector_key text primary key,
  object_schema text not null,
  object_name text not null,
  exposure_kind text not null,
  expected_ok boolean not null,
  expected_token text not null,
  created_at timestamptz not null default now(),
  constraint public_surface_vectors_exposure_ck
    check (exposure_kind in ('read','request','execute'))
);

insert into pods_public.public_surface_selftest_vectors_v1
  (vector_key, object_schema, object_name, exposure_kind, expected_ok, expected_token)
values
  ('public_request_booking_allowed', 'public', 'rpc_request_booking_v1', 'request', true, 'PUBLIC_SURFACE_ALLOW'),
  ('public_recompute_entitlements_denied', 'public', 'rpc_recompute_entitlements_v1', 'execute', true, 'PUBLIC_SURFACE_DENY'),
  ('public_selftest_add_org_member_denied', 'public', 'rpc_selftest_add_org_member_v1', 'execute', true, 'PUBLIC_SURFACE_DENY'),
  ('pods_core_lane_boundaries_view_denied', 'pods_core', 'v_lane_negative_boundaries_v1', 'read', true, 'PUBLIC_SURFACE_DENY'),
  ('pods_core_lane_selftest_vectors_view_denied', 'pods_core', 'v_lane_boundary_selftest_vectors_v1', 'read', true, 'PUBLIC_SURFACE_DENY')
on conflict (vector_key) do update
set object_schema = excluded.object_schema,
    object_name = excluded.object_name,
    exposure_kind = excluded.exposure_kind,
    expected_ok = excluded.expected_ok,
    expected_token = excluded.expected_token;

create or replace function pods_public.rpc_selftest_public_surfaces_all_v1()
returns table(
  vector_key text,
  ok boolean,
  token text,
  message text
)
language plpgsql
security definer
set search_path = pods_public, public
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
      v.object_schema,
      v.object_name,
      v.exposure_kind,
      v.expected_ok,
      v.expected_token
    from pods_public.public_surface_selftest_vectors_v1 v
    order by v.vector_key
  loop
    j := pods_public.rpc_selftest_public_surface_v1(
      r.object_schema,
      r.object_name,
      r.exposure_kind,
      case
        when r.expected_token = 'PUBLIC_SURFACE_ALLOW' then null
        else r.expected_token
      end
    );

    v_ok := coalesce((j ->> 'ok')::boolean, false);
    v_token := coalesce(j ->> 'token', '');
    v_message := coalesce(j ->> 'message', '');

    if r.expected_token = 'PUBLIC_SURFACE_ALLOW' then
      if not (v_ok = true and v_token = 'PUBLIC_SURFACE_ALLOW') then
        raise exception 'PUBLIC_SURFACE_SELFTEST_FAIL:%:%', r.vector_key, coalesce(v_token,'<null>');
      end if;
    else
      if not (v_ok = true and position(r.expected_token in v_token) > 0) then
        raise exception 'PUBLIC_SURFACE_SELFTEST_FAIL:%:%', r.vector_key, coalesce(v_token,'<null>');
      end if;
    end if;

    rpc_selftest_public_surfaces_all_v1.vector_key := r.vector_key;
    rpc_selftest_public_surfaces_all_v1.ok := v_ok;
    rpc_selftest_public_surfaces_all_v1.token := v_token;
    rpc_selftest_public_surfaces_all_v1.message := v_message;
    return next;
  end loop;

  return;
end
$$;

comment on function pods_public.rpc_selftest_public_surfaces_all_v1() is
'Executes all Tier-1 public surface vectors and raises deterministic failure tokens if any vector deviates from expected behavior.';

create or replace view pods_public.v_public_surface_contracts_v1 as
select
  c.surface_key,
  c.object_type,
  c.object_schema,
  c.object_name,
  c.exposure_kind,
  c.public_safe,
  c.write_enabled,
  c.notes,
  c.created_at
from pods_public.public_surface_contracts_v1 c
order by c.surface_key;

comment on view pods_public.v_public_surface_contracts_v1 is
'Readable contract surface for Tier-1 public-safe exposure rules.';

create or replace view pods_public.v_public_surface_selftest_vectors_v1 as
select
  v.vector_key,
  v.object_schema,
  v.object_name,
  v.exposure_kind,
  v.expected_ok,
  v.expected_token,
  v.created_at
from pods_public.public_surface_selftest_vectors_v1 v
order by v.vector_key;

comment on view pods_public.v_public_surface_selftest_vectors_v1 is
'Readable public surface selftest vector registry.';

commit;