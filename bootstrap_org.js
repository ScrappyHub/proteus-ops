import { createClient } from "@supabase/supabase-js";

const url = process.env.SUPABASE_URL;
const anon = process.env.SUPABASE_ANON_KEY;
const email = process.env.TEST_EMAIL;
const password = process.env.TEST_PASSWORD;

function req(name, v) {
  if (!v || !String(v).trim()) throw new Error(`MISSING_ENV_${name}`);
  return v;
}

async function main() {
  req("SUPABASE_URL", url);
  req("SUPABASE_ANON_KEY", anon);
  req("TEST_EMAIL", email);
  req("TEST_PASSWORD", password);

  const supabase = createClient(url, anon);

  const { data: authData, error: authErr } =
    await supabase.auth.signInWithPassword({ email, password });

  if (authErr) throw authErr;

  console.log("AUTH_OK user_id=", authData.user?.id);

  // Call the PUBLIC wrapper you created
  const { data, error } = await supabase.rpc("rpc_create_org_bootstrap", {
    p_slug: "demo-barber",
    p_name: "Demo Barber",
    p_plan_id: "proteusops_sb_v1",
  });

  if (error) {
    console.error("RPC_ERROR:", error);
    process.exit(1);
  }

  console.log("ORG_ID:", data);

  // quick verify via API that org exists (no RLS bypass)
  const { data: orgRows, error: orgErr } = await supabase
    .from("orgs")
    .select("org_id,slug,name")
    .eq("slug", "demo-barber");

  if (orgErr) {
    console.error("ORG_SELECT_ERROR:", orgErr);
    process.exit(1);
  }

  console.log("ORG_ROWS:", orgRows);
}

main().catch((e) => {
  console.error("FATAL:", e);
  process.exit(1);
});