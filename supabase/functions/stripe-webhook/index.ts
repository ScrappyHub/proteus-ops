// ProteusOps — Stripe webhook (verified ingestion boundary): subscriptions, one-time purchases, refunds/disputes.
// Deploy:  supabase functions deploy stripe-webhook --no-verify-jwt
// Secrets: STRIPE_WEBHOOK_SECRET=whsec_...  (optional) EXPECT_LIVEMODE=true|false
// Conventions (docs/proposals/PAYMENTS_STRIPE_RUNBOOK_v1.md):
//   - org_id (uuid) in metadata of the Subscription / Checkout Session / PaymentIntent.
//   - Subscriptions: plan = Price lookup_key (must match pods.plan_tiers.plan_id).
//   - One-time: metadata.product_key must exist in pods_provisioning.one_time_catalog_v1; the DB checks
//     amount + currency against the catalog. Capabilities are NEVER taken from metadata.
//   - Full refunds (charge.refunded with refunded=true) and disputes (charge.dispute.created) revoke the grant.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const enc = new TextEncoder();
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// DB rejections that retries can never fix: acknowledge (no retry storm), log loudly, audit where possible.
const PERMANENT = ["BILLING_CUSTOMER_BOUND_TO_OTHER_ORG", "BILLING_ORG_BOUND_TO_OTHER_CUSTOMER",
  "BILLING_SUBSCRIPTION_BOUND_TO_OTHER_ORG", "BILLING_UNKNOWN_ORG", "BILLING_INGEST_INVALID",
  "ONE_TIME_UNKNOWN_PRODUCT", "ONE_TIME_AMOUNT_MISMATCH"];

async function hmacHex(secret: string, msg: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, enc.encode(msg));
  return Array.from(new Uint8Array(mac)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
function safeEq(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
// Accepts any v1 signature in the header (Stripe sends several during secret rotation).
async function verifyStripeSignature(payload: string, sigHeader: string, secret: string, toleranceSec = 300): Promise<boolean> {
  let t = ""; const v1s: string[] = [];
  for (const kv of sigHeader.split(",")) {
    const i = kv.indexOf("="); if (i < 0) continue;
    const k = kv.slice(0, i).trim(), v = kv.slice(i + 1).trim();
    if (k === "t") t = v; else if (k === "v1" && v) v1s.push(v);
  }
  if (!t || v1s.length === 0 || !/^\d+$/.test(t)) return false;
  if (Math.abs(Math.floor(Date.now() / 1000) - Number(t)) > toleranceSec) return false;
  const expected = await hmacHex(secret, `${t}.${payload}`);
  let ok = false; for (const v of v1s) ok = safeEq(expected, v) || ok;
  return ok;
}

const iso = (s?: number) => (s ? new Date(s * 1000).toISOString() : null);
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  const secret = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (!secret) return new Response("misconfigured", { status: 500 });
  const body = await req.text();
  if (body.length > 1_000_000) return new Response("payload too large", { status: 413 });
  if (!(await verifyStripeSignature(body, req.headers.get("Stripe-Signature") ?? "", secret))) {
    return new Response("invalid signature", { status: 400 });
  }

  const event = JSON.parse(body);
  const expectLive = Deno.env.get("EXPECT_LIVEMODE");
  if (expectLive === "true" || expectLive === "false") {
    if (Boolean(event.livemode) !== (expectLive === "true")) return new Response("livemode mismatch", { status: 400 });
  }
  const obj = event?.data?.object ?? {};
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const rawOrg = obj?.metadata?.org_id ?? null;
  const orgId = typeof rawOrg === "string" && UUID.test(rawOrg) ? rawOrg : null;

  const call = async (fn: string, args: Record<string, unknown>) => {
    const { data, error } = await supabase.rpc(fn, args);
    if (error) throw error;
    return data;
  };

  try {
    switch (event.type) {
      case "customer.subscription.created":
      case "customer.subscription.updated":
      case "customer.subscription.deleted": {
        if (!orgId) return json({ received: true, ignored: "missing/invalid org_id metadata" }, 202);
        const item = obj?.items?.data?.[0];
        const price = item?.price;
        const periodStart = item?.current_period_start ?? obj.current_period_start;
        const periodEnd = item?.current_period_end ?? obj.current_period_end;
        await call("rpc_billing_ingest_webhook", {
          p_org_id: orgId,
          p_provider_customer_id: typeof obj.customer === "string" ? obj.customer : obj.customer?.id,
          p_provider_subscription_id: obj.id,
          p_status: event.type === "customer.subscription.deleted" ? "canceled" : obj.status,
          p_plan_id: price?.lookup_key ?? price?.metadata?.plan_id ?? price?.id ?? "",
          p_period_start: iso(periodStart),
          p_period_end: iso(periodEnd),
          p_cancel_at_period_end: !!obj.cancel_at_period_end,
          p_billing_email: null,
          p_event: event, // DB keeps only id/type/created
        });
        break;
      }
      case "checkout.session.completed":
      case "checkout.session.async_payment_succeeded": {
        if (obj.mode !== "payment") break;
        if (obj.payment_status !== "paid") return json({ received: true, ignored: "not paid yet" }, 202);
        const productKey = obj?.metadata?.product_key;
        if (!orgId || !productKey) return json({ received: true, ignored: "missing org_id/product_key metadata" }, 202);
        const r = await call("rpc_grant_one_time_purchase_v2", {
          p_org_id: orgId, p_provider_payment_id: obj.payment_intent ?? obj.id, p_product_key: productKey,
          p_amount_minor: obj.amount_total, p_currency: obj.currency, p_event: event,
        });
        if (r?.rejected) { console.error("grant rejected", event.id, r.rejected); return json({ received: true, rejected: r.rejected }); }
        break;
      }
      case "payment_intent.succeeded": {
        const productKey = obj?.metadata?.product_key;
        if (!orgId || !productKey) return json({ received: true, ignored: "no product metadata" }, 202);
        const r = await call("rpc_grant_one_time_purchase_v2", {
          p_org_id: orgId, p_provider_payment_id: obj.id, p_product_key: productKey,
          p_amount_minor: obj.amount_received, p_currency: obj.currency, p_event: event,
        });
        if (r?.rejected) { console.error("grant rejected", event.id, r.rejected); return json({ received: true, rejected: r.rejected }); }
        break;
      }
      case "charge.refunded": {
        if (!obj.refunded || !obj.payment_intent) return json({ received: true, ignored: "partial refund or no payment_intent" }, 202);
        await call("rpc_revoke_one_time_purchase_v1", { p_provider_payment_id: obj.payment_intent, p_reason: "refund", p_event: event });
        break;
      }
      case "charge.dispute.created": {
        if (!obj.payment_intent) return json({ received: true, ignored: "no payment_intent" }, 202);
        await call("rpc_revoke_one_time_purchase_v1", { p_provider_payment_id: obj.payment_intent, p_reason: "dispute", p_event: event });
        break;
      }
      default:
        return json({ received: true, ignored: event.type });
    }
  } catch (e) {
    const msg = String((e as { message?: string })?.message ?? e);
    const code = PERMANENT.find((c) => msg.includes(c));
    if (code) {
      console.error("ingest rejected", event.type, event.id, code);
      return json({ received: true, rejected: code });
    }
    console.error("ingest error", event.type, event.id, msg);
    return new Response("ingest error", { status: 500 }); // transient: Stripe retries
  }
  return json({ received: true, type: event.type, id: event.id });
});
