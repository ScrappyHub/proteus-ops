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

async function main() {
  req("SUPABASE_URL", url);
  req("SUPABASE_ANON_KEY", anon);
  req("SUPABASE_SERVICE_ROLE_KEY", service);
  req("TEST_EMAIL", email);
  req("TEST_PASSWORD", password);
  req("ORG_ID", ORG_ID);

  const svc = createClient(url, service); // service-role context (RPC-only)
  const user = createClient(url, anon);   // user context (auth + booking RPC)

  const { data: authData, error: authErr } = await user.auth.signInWithPassword({ email, password });
  if (authErr) throw authErr;
  const userId = authData.user.id;
  console.log("AUTH_OK user_id=", userId);
  console.log("ORG_ID=", ORG_ID);

  // 1) Flip plan to S (booking disabled) via service-role RPC and recompute
  await rpc(svc, "rpc_selftest_set_subscription_plan_v1", {
    p_org_id: ORG_ID,
    p_plan_id: "proteusops_s_v1",
    p_status: "trialing",
  });
  await rpc(svc, "rpc_recompute_entitlements", { p_org_id: ORG_ID });
  console.log("PLAN_FLIP_OK plan_id=proteusops_s_v1 recompute=ok");

  // 2) Attempt booking and assert BOOKING_DISABLED
  try {
    await rpc(user, "rpc_create_appointment_v1", {
      p_org_id: ORG_ID,
      p_staff_user_id: userId,
      p_start_time: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(),
      p_end_time: new Date(Date.now() + 25 * 60 * 60 * 1000).toISOString(),
      p_service_id: null,
      p_location_id: null,
      p_guest_name: "Guest Disabled",
      p_guest_email: "disabled@example.com",
      p_guest_phone: "555-0999",
      p_notes: "selftest:disabled",
    });
    console.log("BOOKING_DISABLED_TEST_UNEXPECTED_OK");
    process.exit(2);
  } catch (e) {
    const msg = e?.message || String(e);
    if (msg !== "BOOKING_DISABLED") {
      console.log("BOOKING_DISABLED_TEST_FAIL wrong_token=", msg);
      process.exit(3);
    }
    console.log("BOOKING_DISABLED_TEST_EXPECTED_FAIL token=BOOKING_DISABLED");
  }

  // 3) Restore plan to SB and recompute
  await rpc(svc, "rpc_selftest_set_subscription_plan_v1", {
    p_org_id: ORG_ID,
    p_plan_id: "proteusops_sb_v1",
    p_status: "trialing",
  });
  await rpc(svc, "rpc_recompute_entitlements", { p_org_id: ORG_ID });
  console.log("PLAN_RESTORE_OK plan_id=proteusops_sb_v1 recompute=ok");

  console.log("SELFTEST_DONE");
}

main().catch((e) => {
  console.error("SELFTEST_FATAL:", e);
  process.exit(1);
});
