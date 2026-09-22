# Runbook — Stripe payments & entitlement (operator steps)

Status: PROPOSED. DB idempotency guard + selftest are staged (migration
20260922124000_payment_idempotency_v1). The webhook edge function is staged code, not
deployed. All secrets are provisioned by the operator, never in git.

## Authority separation (non-negotiable)
- Stripe = "a payment/subscription event happened."
- ProteusOps = "org X is entitled to capability/model Y" — computed in the DB
  (pods.rpc_recompute_entitlements), never from client state or a Stripe success redirect.

## Operator steps
1. Stripe Dashboard -> Developers -> Webhooks -> Add endpoint:
   https://ytwjyemqlbbebysiopzd.functions.supabase.co/stripe-webhook
   Select the events you handle (e.g. invoice.payment_succeeded, customer.subscription.updated).
2. Copy the endpoint's Signing secret (whsec_...).
3. Set function secrets (never in git):
   supabase secrets set STRIPE_WEBHOOK_SECRET=whsec_...
4. Deploy: supabase functions deploy stripe-webhook
5. Complete the TODO in supabase/functions/stripe-webhook/index.ts: map your Stripe events to
   pods.rpc_billing_ingest_webhook(...) for your product/price model.
6. Test with the Stripe CLI: stripe listen --forward-to <endpoint>; trigger sample events;
   confirm a duplicate event id is rejected by the idempotency guard.

## Guarantees (DB-enforced)
- Signature verified before any DB effect (edge function).
- Idempotency: payment_events_provider_event_uak + provider_receipt_unique reject duplicate
  provider_event_id (selftest: rpc_selftest_payment_idempotency_v1 -> PROTEUSOPS_PAYMENT_IDEMPOTENCY_OK).
- Ingestion is service-role only; entitlement is recomputed server-side.

## DoD
Paid event grants exactly the entitled capability; spoofed/duplicate/absent event grants nothing.

## Metadata conventions (required by the edge function mapping)
- org_id: set on the Stripe Customer AND on each Subscription / Checkout Session / PaymentIntent
  metadata as "org_id" (the ProteusOps org uuid). Subscription events read obj.metadata.org_id.
- Subscriptions: plan_id = the Stripe Price id; seed pods.plan_capabilities with rows keyed by
  that Price id so rpc_recompute_entitlements grants the right capabilities.
- One-time (mode=payment / payment_intent): set on the Checkout Session / PaymentIntent metadata:
  capability_key (required), value_type ("bool"|"int"|"text", default bool), and value_bool/int/text.
- Events handled: customer.subscription.created|updated|deleted, checkout.session.completed
  (mode=payment), payment_intent.succeeded. Duplicate deliveries are rejected idempotently
  (payment_events / one_time_receipt unique guards).
