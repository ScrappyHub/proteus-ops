-- ProteusOps slice 3 — session assurance primitives (auth + MFA enforcement)
-- DB-side gates used by privileged RPCs. Identity/MFA are provisioned in Supabase Auth
-- by the operator (Google OAuth client + TOTP MFA — see docs/proposals/
-- AUTH_GOOGLE_SSO_MFA_RUNBOOK_v1.md). These helpers enforce, they do not authenticate.
-- Trusted server-side/direct callers (no JWT claims) and service_role bypass; end-user
-- (authenticated) callers must satisfy the gate.

create or replace function pods_core.require_authenticated()
returns void language plpgsql stable
security definer set search_path = pods_core, public as $fn$
declare v jsonb;
begin
  v := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  if v is null then return; end if;                       -- trusted direct/backend
  if (v->>'role') = 'service_role' then return; end if;
  if coalesce(v->>'sub','') = '' then
    raise exception 'PROTEUSOPS_AUTH_REQUIRED' using errcode = '42501';
  end if;
end $fn$;

create or replace function pods_core.require_aal2()
returns void language plpgsql stable
security definer set search_path = pods_core, public as $fn$
declare v jsonb;
begin
  v := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  if v is null then return; end if;                       -- trusted direct/backend
  if (v->>'role') = 'service_role' then return; end if;
  if coalesce(v->>'aal','aal1') <> 'aal2' then
    raise exception 'PROTEUSOPS_MFA_REQUIRED' using errcode = '42501';
  end if;
end $fn$;

-- Positive + negative selftest of the MFA gate (simulates JWT claims).
create or replace function pods_core.rpc_selftest_session_assurance_v1()
returns jsonb language plpgsql
security definer set search_path = pods_core, public as $fn$
declare aal1_blocked bool := false; aal2_ok bool := false; svc_ok bool := false; anon_blocked bool := false;
begin
  perform set_config('request.jwt.claims','{"role":"authenticated","aal":"aal1","sub":"u1"}', true);
  begin perform pods_core.require_aal2(); exception when others then aal1_blocked := true; end;

  perform set_config('request.jwt.claims','{"role":"authenticated","aal":"aal2","sub":"u1"}', true);
  begin perform pods_core.require_aal2(); aal2_ok := true; exception when others then aal2_ok := false; end;

  perform set_config('request.jwt.claims','{"role":"service_role"}', true);
  begin perform pods_core.require_aal2(); svc_ok := true; exception when others then svc_ok := false; end;

  perform set_config('request.jwt.claims','{"role":"anon"}', true);
  begin perform pods_core.require_authenticated(); exception when others then anon_blocked := true; end;

  perform set_config('request.jwt.claims','', true);
  if aal1_blocked and aal2_ok and svc_ok and anon_blocked then
    return jsonb_build_object('ok',true,'token','PROTEUSOPS_SESSION_ASSURANCE_OK',
      'aal1_blocked',true,'aal2_allowed',true,'service_role_allowed',true,'anon_blocked',true);
  end if;
  return jsonb_build_object('ok',false,'token','PROTEUSOPS_SESSION_ASSURANCE_FAIL',
    'aal1_blocked',aal1_blocked,'aal2_allowed',aal2_ok,'service_role_allowed',svc_ok,'anon_blocked',anon_blocked);
end $fn$;

select pods_core.rpc_selftest_session_assurance_v1();
