// ProteusOps — Stripe webhook (verified ingestion boundary)
// Deploy:  supabase functions deploy stripe-webhook
// Secrets: supabase secrets set STRIPE_WEBHOOK_SECRET=whsec_... (SUPABASE_URL and
//          SUPABASE_SERVICE_ROLE_KEY are injected automatically in Edge Functions)
// Security: verifies the Stripe signature BEFORE any DB effect. Only verified events reach
// the DB, via the service-role billing ingest RPC. No secret is stored in the repo.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const enc = new TextEncoder();

async function verifyStripeSignature(payload: string, sigHeader: string, secret: string, toleranceSec = 300): Promise<boolean> {
  const parts: Record<string, string> = {};
  for (const kv of sigHeader.split(",")) { const [k, v] = kv.split("="); if (k && v) parts[k.trim()] = v.trim(); }
  const t = parts["t"], v1 = parts["v1"];
  if (!t || !v1) return false;
  if (Math.abs(Math.floor(Date.now() / 1000) - Number(t)) > toleranceSec) return false; // replay window
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, enc.encode(`${t}.${payload}`));
  const expected = Array.from(new Uint8Array(mac)).map((b) => b.toString(16).padStart(2, "0")).join("");
  if (expected.length !== v1.length) return false;
  let diff = 0; for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ v1.charCodeAt(i); // constant-time
  return diff === 0;
}

Deno.serve(async (req) => {
  const secret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (!secret) return new Response("misconfigured", { status: 500 });
  const sig = req.headers.get("Stripe-Signature") ?? "";
  const body = await req.text();
  if (!(await verifyStripeSignature(body, sig, secret))) {
    return new Response("invalid signature", { status: 400 });
  }
  const event = JSON.parse(body);
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // Verified event -> DB. The DB enforces idempotency (payment_events_provider_event_uak /
  // provider_receipt_unique) and computes entitlement (pods.rpc_recompute_entitlements).
  // TODO(operator): map Stripe event types to pods.rpc_billing_ingest_webhook(...) params for
  // your product/price model, e.g. customer.subscription.updated / invoice.payment_succeeded.
  //   const s = event.data.object;
  //   await supabase.rpc("rpc_billing_ingest_webhook", {
  //     p_org_id: /* resolve from customer/metadata */, p_provider_customer_id: s.customer,
  //     p_provider_subscription_id: s.id, p_status: s.status, p_plan_id: s.items?.data?.[0]?.price?.id,
  //     p_period_start: new Date(s.current_period_start*1000).toISOString(),
  //     p_period_end: new Date(s.current_period_end*1000).toISOString(),
  //     p_cancel_at_period_end: s.cancel_at_period_end, p_billing_email: null, p_event: event });

  return new Response(JSON.stringify({ received: true, id: event.id, type: event.type }), {
    headers: { "content-type": "application/json" },
  });
});
