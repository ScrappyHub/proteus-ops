# Security audit v2 — 2026-09-22 (hosted ytwjyemqlbbebysiopzd + repo @ 5b9610a)

Method: read-only SQL against hosted (grants, SECURITY DEFINER bodies, policies, views, default
ACLs, schema USAGE), Supabase dashboard (Data API, Auth providers, MFA, attack protection),
edge function source review, git history secret scan (59 commits). Supabase MCP advisor API was
not permitted for this token; equivalent checks were done in SQL.

## Facts established
- Data API exposes 2 of 8 schemas (public + graphql_public). anon/authenticated have USAGE only
  on `public` and `pods`; none on pods_core / pods_provisioning / pods_public / pods_ops / pods_billing.
- No table in public/pods is granted to anon/authenticated except 4 storefront views (anon SELECT).
  All pods* tables RLS-enabled (fail-closed selftest green). No storage buckets.
- Default ACLs in `public`: new tables/functions/sequences are auto-granted to anon + authenticated
  ("Automatically expose new tables" = ON).
- 217 pods_provisioning functions (215 SECURITY DEFINER) are EXECUTE-able by PUBLIC (latent:
  schema not exposed, no USAGE).
- Auth: email sign-up open, confirm-email ON, anonymous OFF, manual linking OFF; TOTP MFA enabled;
  Google provider DISABLED; CAPTCHA OFF; AAL1 session time-limit OFF.
- MFA (aal2) enforced only on hub stage edges.
- No secrets in tracked files or git history. No CI.

## Findings (ranked)
| ID | Sev | Finding | Fix slice |
|---|---|---|---|
| C1 | CRITICAL | `public.rpc_create_org_bootstrap(slug,name,plan_id)` — any signed-up user can create a workspace on ANY plan with a 30-day `trialing` subscription row → paid_active + paid features without paying. Reachable today via REST. | S1 |
| H1 | HIGH | Stripe subscription events applied in arrival order: a delayed older `updated(active)` after `deleted` resurrects a canceled subscription. | S2 |
| H2 | HIGH | org_id is taken from Stripe metadata with no customer↔org binding: a mis-tagged subscription can attach to / re-bind another workspace's billing account. | S2 |
| H3 | HIGH | One-time grants trust free-form metadata (capability, value); no catalog, amount or currency check. | S2 + S3 |
| M1 | MED | Refunds / disputes do not revoke one-time grants. | S2 + S3 |
| M2 | MED | Unknown/inactive plan_id → paid with zero plan capabilities (below baseline). | S2 |
| M3 | MED | Selftest/reset functions reachable by authenticated via public wrappers; `pods.rpc_selftest_entitlement_overrides_v1` (creates/deletes orgs) executable by anon/authenticated. | S1 |
| M4 | MED | Default ACLs auto-grant every new public function/table to anon/authenticated. | S1 |
| M5 | MED | Internal SECURITY DEFINER helpers (e.g. `pods._increment_usage_counter`, 215 pods_provisioning fns) EXECUTE-able by PUBLIC; one config change from exposure. | S1 |
| M6 | MED | aal2 enforced only on hub edges; credential/billing/admin writes will need it (H2 onward). | H2 |
| M7 | MED | Auth config: Google off, CAPTCHA off, AAL1 session limit off, leaked-password protection unverified. | Operator |
| L1 | LOW | Public storefront views list every active org (incl. test orgs) regardless of storefront_enabled. | S1 |
| L2 | LOW | Webhook signature parser keeps only the last `v1` (breaks during secret rotation). | S3 |
| L3 | LOW | Full Stripe event (customer email etc.) stored in audit_log / receipts. | S2 |
| L4 | LOW | No CI secret scan. | S4 |
| C1a | HIGH | Existing hosted row from the C1 path: workspace `demo-barber` has subscription `bootstrap_674f8344…` = `trialing` on `proteusops_sb_v1` with no Stripe backing, so it holds paid features indefinitely (recompute never checks period end). | Operator decision |
| L5 | LOW | TEST ONLY org + Stripe sandbox objects present on hosted. | Operator-approved cleanup |

## Remediation order (and why)
1. **S1 API surface** (C1, M3, M4, M5, L1) — C1 is exploitable now; closing the surface first
   means later slices can't be bypassed through old paths. Selftest: allowlist of every
   SECURITY DEFINER function authenticated may execute; zero for anon.
2. **S2 billing integrity** (H1, H2, H3-db, M1-db, M2, L3) — DB rules the edge function relies on.
3. **S3 edge function** (H3/M1 wiring, L2) + add `charge.refunded`, `charge.dispute.created` to the Stripe destination.
4. **S4 CI secret scan** (L4).
5. **Operator config** (M7) — Google OAuth client, CAPTCHA, AAL1 limit, password policy.
6. **H2** credentials (Vault refs, aal2 on writes — M6) + resource inventory; **H3** change feed + adapters
   GitHub → Supabase → Cloudflare → AWS/SES; **H4** notifications. UI only after these.

## Status (2026-09-23)
- S1 `20260923010000_security_api_surface_v1` + S2 `20260923011000_billing_integrity_v1` staged; selftests
  PROTEUSOPS_API_SURFACE_OK / PROTEUSOPS_BILLING_INTEGRITY_OK. S3 edge function hardened in repo (not deployed).
- S4: `scripts/sql/selftests_all_v1.sql` (all tokens) + `ci/ci.yml` (gitleaks full history + DB selftests on
  every push/PR) — move to `.github/workflows/ci.yml` (protected path; operator moves it).
