// ProteusOps — Stripe webhook (verified ingestion boundary): subscriptions + one-time.
// Deploy:  supabase functions deploy stripe-webhook
// Secrets: supabase secrets set STRIPE_WEBHOOK_SECRET=whsec_...
// Conventions (set these in Stripe; the mapping reads them):
//   - org_id: on the Customer / Subscription / Checkout Session / PaymentIntent metadata (key "org_id")
//   - one-time grant: on the Price/Product or Checkout Session metadata:
//       capability_key (required), value_type ("bool"|"int"|"text", default "bool"),
//       value_bool / value_int / value_text (optional; default value_bool=true)
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const enc = new TextEncoder();

async function verifyStripeSignature(payload: string, sigHeader: string, secret: string, toleranceSec = 300): Promise<boolean> {
  const parts: Record<string, string> = {};
  for (const kv of sigHeader.split(",")) { const [k, v] = kv.split("="); if (k && v) parts[k.trim()] = v.trim(); }
  const t = parts["t"], v1 = parts["v1"];
  if (!t || !v1) return false;
  if (Math.abs(Math.floor(Date.now() / 1000) - Number(t)) > toleranceSec) return false;
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, enc.encode(`${t}.${payload}`));
  const expected = Array.from(new Uint8Array(mac)).map((b) => b.toString(16).padStart(2, "0")).join("");
  if (expected.length !== v1.length) return false;
  let diff = 0; for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ v1.charCodeAt(i);
  return diff === 0;
}

const iso = (s?: number) => (s ? new Date(s * 1000).toISOString() : null);

Deno.serve(async (req) => {
  const secret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (!secret) return new Response("misconfigured", { status: 500 });
  const sig = req.headers.get("Stripe-Signature") ?? "";
  const body = await req.text();
  if (!(await verifyStripeSignature(body, sig, secret))) return new Response("invalid signature", { status: 400 });

  const event = JSON.parse(body);
  const obj = event?.data?.object ?? {};
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const orgId = obj?.metadata?.org_id ?? null;

  try {
    switch (event.type) {
      // ---- Subscriptions ----
      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.deleted": {
        if (!orgId) return new Response("missing org_id metadata", { status: 202 });
        const item = obj?.items?.data?.[0];
        const price = item?.price;
        // API >= 2025-03-31.basil moved billing periods onto subscription items; fall back for older versions.
        const periodStart = item?.current_period_start ?? obj.current_period_start;
        const periodEnd = item?.current_period_end ?? obj.current_period_end;
        const { error } = await supabase.rpc("rpc_billing_ingest_webhook", {
          p_org_id: orgId,
          p_provider_customer_id: obj.customer,
          p_provider_subscription_id: obj.id,
          p_status: event.type === "customer.subscription.deleted" ? "canceled" : obj.status,
          p_plan_id: price?.id ?? "",
          p_period_start: iso(periodStart),
          p_period_end: iso(periodEnd),
          p_cancel_at_period_end: !!obj.cancel_at_period_end,
          p_billing_email: null,
          p_event: event,
        });
        if (error) throw error;
        break;
      }
      // ---- One-time ----
      case "checkout.session.completed": {
        if (obj.mode !== "payment") break; // subscriptions handled via subscription.* events
        const m = obj.metadata ?? {};
        if (!orgId || !m.capability_key) return new Response("missing org_id/capability_key metadata", { status: 202 });
        const { error } = await supabase.rpc("rpc_grant_one_time_entitlement_v1", {
          p_org_id: orgId, p_provider_key: "stripe",
          p_provider_payment_id: obj.payment_intent ?? obj.id,
          p_capability_key: m.capability_key, p_value_type: m.value_type ?? "bool",
          p_value_bool: m.value_type ? (m.value_bool === "true") : true,
          p_value_int: m.value_int ? Number(m.value_int) : null,
          p_value_text: m.value_text ?? null, p_event: event,
        });
        if (error) throw error;
        break;
      }
      case "payment_intent.succeeded": {
        const m = obj.metadata ?? {};
        if (!orgId || !m.capability_key) return new Response("ignored (no capability metadata)", { status: 202 });
        const { error } = await supabase.rpc("rpc_grant_one_time_entitlement_v1", {
          p_org_id: orgId, p_provider_key: "stripe", p_provider_payment_id: obj.id,
          p_capability_key: m.capability_key, p_value_type: m.value_type ?? "bool",
          p_value_bool: m.value_type ? (m.value_bool === "true") : true,
          p_value_int: m.value_int ? Number(m.value_int) : null,
          p_value_text: m.value_text ?? null, p_event: event,
        });
        if (error) throw error;
        break;
      }
      default:
        return new Response(JSON.stringify({ received: true, ignored: event.type }), { headers: { "content-type": "application/json" } });
    }
  } catch (e) {
    console.error("ingest error", event.type, String(e));
    return new Response("ingest error", { status: 500 }); // Stripe will retry
  }
  return new Response(JSON.stringify({ received: true, type: event.type, id: event.id }), { headers: { "content-type": "application/json" } });
});
