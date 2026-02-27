$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }

function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)){
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $t = $Text -replace "`r`n","`n"
  $t = $t -replace "`r","`n"
  if(-not $t.EndsWith("`n")){ $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path,$t,$enc)
}

$RepoRoot = (Resolve-Path -LiteralPath ".").Path

$m022 = Join-Path $RepoRoot "migrations\022_selftest_add_org_member_v1.sql"
$sql = @'
begin;

create or replace function pods.rpc_selftest_add_org_member_v1(
  p_org_id uuid,
  p_user_id uuid,
  p_role text default 'owner'
)
returns void
language plpgsql
security definer
set search_path = pods, public
as $function$
declare
  v_has_role_key boolean := false;
  v_has_role     boolean := false;
  v_sql text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED';
  end if;

  select exists(
    select 1 from information_schema.columns
    where table_schema='pods' and table_name='org_members' and column_name='role_key'
  ) into v_has_role_key;

  select exists(
    select 1 from information_schema.columns
    where table_schema='pods' and table_name='org_members' and column_name='role'
  ) into v_has_role;

  if v_has_role_key then
    v_sql := 'insert into pods.org_members(org_id, user_id, role_key) values ($1,$2,$3) on conflict do nothing';
    execute v_sql using p_org_id, p_user_id, p_role;
    return;
  end if;

  if v_has_role then
    v_sql := 'insert into pods.org_members(org_id, user_id, role) values ($1,$2,$3) on conflict do nothing';
    execute v_sql using p_org_id, p_user_id, p_role;
    return;
  end if;

  v_sql := 'insert into pods.org_members(org_id, user_id) values ($1,$2) on conflict do nothing';
  execute v_sql using p_org_id, p_user_id;
end;
$function$;

revoke all on function pods.rpc_selftest_add_org_member_v1(uuid, uuid, text) from public;
revoke all on function pods.rpc_selftest_add_org_member_v1(uuid, uuid, text) from anon;
revoke all on function pods.rpc_selftest_add_org_member_v1(uuid, uuid, text) from authenticated;
grant execute on function pods.rpc_selftest_add_org_member_v1(uuid, uuid, text) to service_role;

create or replace function public.rpc_selftest_add_org_member_v1(
  p_org_id uuid,
  p_user_id uuid,
  p_role text default 'owner'
)
returns void
language sql
security definer
set search_path = pods, public
as $sql$
  select pods.rpc_selftest_add_org_member_v1(p_org_id, p_user_id, p_role);
$sql$;

revoke all on function public.rpc_selftest_add_org_member_v1(uuid, uuid, text) from public;
revoke all on function public.rpc_selftest_add_org_member_v1(uuid, uuid, text) from anon;
revoke all on function public.rpc_selftest_add_org_member_v1(uuid, uuid, text) from authenticated;
grant execute on function public.rpc_selftest_add_org_member_v1(uuid, uuid, text) to service_role;

commit;
@'

Write-Utf8NoBomLf $m022 $sql
Write-Host ("WROTE+SQL_UTF8_LF_OK: " + $m022) -ForegroundColor Green

$js1 = Join-Path $RepoRoot "selftest_booking.js"
$js = @'
import { createClient } from "@supabase/supabase-js";

const url = process.env.SUPABASE_URL;
const anon = process.env.SUPABASE_ANON_KEY;
const service = process.env.SUPABASE_SERVICE_ROLE_KEY;
const email = process.env.TEST_EMAIL;
const password = process.env.TEST_PASSWORD;
const ORG_ID = process.env.ORG_ID;

function req(name, v) {
  if (!v || !String(v).trim()) throw new Error(`MISSING_ENV_${name}`);
  return v;
}

async function rpc(supabase, fn, args) {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw error;
  return data;
}

function pickInsideAvailabilityLocal() {
  const now = new Date();
  let startLocal = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 10, 0, 0, 0);
  if (startLocal.getTime() <= now.getTime()) {
    startLocal = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1, 10, 0, 0, 0);
  }
  const endLocal = new Date(startLocal.getTime() + 60 * 60 * 1000);
  return { startLocal, endLocal };
}

async function main() {
  req("SUPABASE_URL", url);
  req("SUPABASE_ANON_KEY", anon);
  req("SUPABASE_SERVICE_ROLE_KEY", service);
  req("TEST_EMAIL", email);
  req("TEST_PASSWORD", password);
  req("ORG_ID", ORG_ID);

  const user = createClient(url, anon);
  const svc = createClient(url, service);

  const { data: authData, error: authErr } = await user.auth.signInWithPassword({ email, password });
  if (authErr) throw authErr;

  const userId = authData.user.id;
  console.log("AUTH_OK user_id=", userId);
  console.log("ORG_ID=", ORG_ID);

  await rpc(svc, "rpc_selftest_add_org_member_v1", { p_org_id: ORG_ID, p_user_id: userId, p_role: "owner" });
  console.log("SELFTEST_MEMBERSHIP_OK");

  await rpc(user, "rpc_selftest_reset_booking_v1", { p_org_id: ORG_ID, p_staff_user_id: userId });
  console.log("SELFTEST_RESET_OK");

  const { startLocal, endLocal } = pickInsideAvailabilityLocal();
  const dow = startLocal.getDay();

  const ruleId = await rpc(user, "rpc_upsert_availability_rule_v1", {
    p_org_id: ORG_ID, p_rule_id: null, p_staff_user_id: userId, p_location_id: null,
    p_day_of_week: dow, p_start_time: "09:00:00", p_end_time: "17:00:00", p_is_active: true,
  });
  console.log("AVAILABILITY_OK rule_id=", ruleId, "dow=", dow);

  const apptId1 = await rpc(user, "rpc_create_appointment_v1", {
    p_org_id: ORG_ID, p_staff_user_id: userId,
    p_start_time: startLocal.toISOString(), p_end_time: endLocal.toISOString(),
    p_service_id: null, p_location_id: null,
    p_guest_name: "Guest One", p_guest_email: "guest@example.com", p_guest_phone: "555-0100",
    p_notes: "selftest:booking",
  });
  console.log("APPOINTMENT_CREATE_OK appointment_id=", apptId1);

  try {
    await rpc(user, "rpc_create_appointment_v1", {
      p_org_id: ORG_ID, p_staff_user_id: userId,
      p_start_time: startLocal.toISOString(), p_end_time: endLocal.toISOString(),
      p_service_id: null, p_location_id: null,
      p_guest_name: "Guest Two", p_guest_email: "guest2@example.com", p_guest_phone: "555-0101",
      p_notes: "selftest:overlap",
    });
    console.log("OVERLAP_TEST_UNEXPECTED_OK");
    process.exit(2);
  } catch (e) {
    console.log("OVERLAP_TEST_EXPECTED_FAIL token=", e?.message || String(e));
  }

  const startTO = new Date(endLocal.getTime() + 30 * 60 * 1000);
  const endTO = new Date(startTO.getTime() + 60 * 60 * 1000);
  const startOff = new Date(startTO.getTime() - 15 * 60 * 1000);
  const endOff = new Date(endTO.getTime() + 15 * 60 * 1000);

  const blockId = await rpc(user, "rpc_add_time_off_block_v1", {
    p_org_id: ORG_ID, p_staff_user_id: userId,
    p_start_time: startOff.toISOString(), p_end_time: endOff.toISOString(),
    p_reason: "selftest:timeoff",
  });
  console.log("TIMEOFF_OK block_id=", blockId);

  try {
    await rpc(user, "rpc_create_appointment_v1", {
      p_org_id: ORG_ID, p_staff_user_id: userId,
      p_start_time: startTO.toISOString(), p_end_time: endTO.toISOString(),
      p_service_id: null, p_location_id: null,
      p_guest_name: "Guest Three", p_guest_email: "guest3@example.com", p_guest_phone: "555-0102",
      p_notes: "selftest:timeoff-test",
    });
    console.log("TIMEOFF_TEST_UNEXPECTED_OK");
    process.exit(3);
  } catch (e) {
    console.log("TIMEOFF_TEST_EXPECTED_FAIL token=", e?.message || String(e));
  }

  console.log("SELFTEST_DONE");
}

main().catch((e) => {
  console.error("SELFTEST_FATAL:", e);
  process.exit(1);
});
@'

Write-Utf8NoBomLf $js1 $js
Write-Host ("WROTE+JS_UTF8_LF_OK: " + $js1) -ForegroundColor Green

Write-Host "PATCH_V4_OK (apply migration 022, then rerun scripts\selftest_all.ps1)" -ForegroundColor Green
