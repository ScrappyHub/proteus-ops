# Proposal — Security, Auth, Payments & Provider Linking v1

- Status: PROPOSED (staged; nothing applied to hosted until approved)
- Date: 2026-09-21
- Rollout policy: stage as migrations + verify locally + propose; apply to hosted only on
  explicit per-batch approval. Positive AND negative tests per slice (Atlas AGENT_POLICY).
- Secrets boundary: this program designs schema, RLS, enforcement and wiring. All secrets
  (Stripe keys, Google OAuth client secret, Cloudflare/Squarespace API tokens, service-role
  keys) are provisioned by the operator in the provider dashboards / environment, never in git.

## 0. Why now
The reconciliation captured hosted as reproducible source of truth. Security posture audit
(`proofs/audit/security_posture_v1.md`) then found: only 9/156 app tables have RLS+policy,
36 tables have no RLS, 111 have RLS but no policy, and all 240 SECURITY DEFINER functions
lacked a fixed search_path. Harden before extending.

## 1. Workstream A — Security hardening (FIRST)
A1. Fixed search_path on SECURITY DEFINER functions — DONE (staged):
    `supabase/migrations/20260921211500_harden_function_search_path_v1.sql` (idempotent,
    behavior-preserving). Verify: 0 SECURITY DEFINER pods* functions without search_path.
A2. RLS access-model decision + repair (NEXT): classify every table as
    (a) client-reachable (needs tenant-scoped policy), or (b) RPC/service-role-only
    (RLS enabled, no client grants — fail closed). Concretely:
    - 36 no-RLS tables: enable RLS; where no anon/authenticated grant exists, this is pure
      defense-in-depth (no behavior change); where such grants exist, add tenant-scoped
      policies first, then enable.
    - 111 RLS-enabled/no-policy: confirm they are RPC-only; add explicit "no direct client
      access" comment + a negative selftest proving anon/authenticated get 0 rows.
    - 2 pods_public + 4 anon-granted storefront surfaces: confirm they expose only public
      columns; add positive tests.
    DoD: a boundary selftest proves cross-tenant reads/writes fail closed on every lane.
A3. Secrets & config hygiene: confirm .gitignore covers proofs/secrets, env, *.local.json
    (it does); add a pre-commit/CI secret scan; keep service-role usage server-side only.

## 2. Workstream B — Auth: Google SSO + MFA
Supabase Auth is the identity provider; ProteusOps governs authorization (org/role/entitlement).
B1. Enable Google as an OAuth provider (operator sets Client ID/Secret in Supabase dashboard;
    redirect URLs per environment). No secret in repo.
B2. MFA (TOTP): enable in Auth; add enrollment flow; enforce step-up for privileged actions.
B3. DB-side enforcement: gate sensitive RPCs/policies on assurance level
    (`auth.jwt()->>'aal' = 'aal2'`) and on org role. New authority: SESSION_ASSURANCE — a
    helper `pods_core.require_aal2()` used by admin/billing RPCs.
    DoD: unauthenticated and aal1 sessions are rejected from privileged RPCs (negative tests);
    Google sign-in + TOTP round-trip verified in a non-prod environment.

## 3. Workstream C — Payments + entitlement (activates BILLING_ENTITLEMENT_AUTHORITY)
Hosted already has payment_intents_v1, payment_events_v1, payment_policies_v1,
payment_provider_adapters_v1, payment_provider_receipts_v1, stripe_adapter_runtime_v1,
refund_intents_v1 — so this is GOVERN + WIRE, not greenfield.
C1. Separation of authority: Stripe = "payment happened"; ProteusOps = "org X is entitled to
    capability/model Y under rules Z". Entitlement is computed/enforced in the DB, never from
    client state or a Stripe success redirect.
C2. Webhook integrity: verify Stripe signature server-side (Edge Function / service-role);
    map verified events -> payment_events_v1 -> entitlement effects. Idempotent by event id.
C3. Enforcement: entitlement checks in RLS/RPC gates; the constitution's
    BILLING_ENTITLEMENT_AUTHORITY (currently planned) moves to active only when its tables,
    RPCs, selftests and receipts exist and pass.
    DoD: a paid event grants exactly the entitled capability; a spoofed/duplicate/absent
    event grants nothing (negative tests); entitlement answerable without trusting the client.

## 4. Workstream D — Provider linking framework
Hosted already has provider_connection_contracts_v1, provider_connection_sessions_v1,
provider_connection_runtime_bridges_v1, provider_readiness_rollups_v1,
domain_provider_connections_v1, domain_runtime_bindings_v1, supabase/stripe/github/email/
storage adapter runtimes — again GOVERN + WIRE.
D1. Connection contract per provider: declares required credentials (by reference, never
    stored in git), capabilities, health, and receipts. Secrets live in a secrets store /
    env, referenced by handle from the DB.
D2. Providers in scope: Supabase (DB/backend), Cloudflare (domains/DNS/SSL), Squarespace
    (domains/site), plus Stripe (payments, Workstream C) and Google (auth, Workstream B).
D3. Authority binding: connect each declared constitution authority (MODEL_REGISTRY,
    DOMAIN_PROVIDER_AUTHORITY, etc.) to its real hosted tables + a selftest + receipts, so
    "9 active authorities" means 9 verified authorities.
    DoD: provider connection state is distinguishable from capability state and from
    ProteusOps interpretation; missing/invalid credentials fail closed with an explicit state.

## 5. Sequenced slices (each: migration -> local verify -> propose -> approve -> hosted)
1. A1 search_path hardening (staged now)         <- verify pending
2. A2 RLS access-model + boundary selftests
3. B  Google SSO + MFA + SESSION_ASSURANCE gates
4. C  Stripe webhook integrity + entitlement enforcement
5. D  provider connection contracts + authority binding + receipts
6. Cross-cutting: audit ledger coverage, negative-test suite, secret-scan in CI

## 6. Non-goals / guardrails
- No secrets in git or docs. No client-trusted authorization. No frontend-only security.
- No hosted change without approval. No weakening of existing green behavior (Atlas invariant).
