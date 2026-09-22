# Proposal — Workspace Hub v1 (operational control plane for customer projects)

- Status: PROPOSED (staged; nothing applied to hosted until approved)
- Date: 2026-09-22
- Rollout policy: same as SECURITY_AUTH_PAYMENTS_PROVIDERS_v1 — migration -> local verify ->
  propose -> approve -> hosted, positive AND negative selftests per slice.
- Secrets boundary: unchanged. ProteusOps stores secret *references and metadata*, never values.

## 0. Intent
ProteusOps already deploys ready-to-run businesses (model instances). The hub is what the
customer lives in afterwards: one Stripe-dashboard-style place per workspace that holds every
project, every connected provider (GitHub, GitLab, Supabase, Cloudflare, Squarespace, Vultr,
AWS/SES, Google, Figma, OSF, CoStar, Stripe, ...), shows *what changed*, tracks keys and
deployments, and changes its rules as a project moves draft -> staging -> launch -> active.
Customers fill in simple fields; ProteusOps gathers what each provider needs, verifies it, and
keeps it sustained.

## 1. What already exists (reuse, do not rebuild)
| Need | Existing hosted object |
|---|---|
| Workspace / tenant | `pods.orgs` + roles + `org_entitlements` (proven today) |
| Project | `pods_provisioning.model_instance_runtimes_v1` (status generated/blocked/launched/archived) |
| "Easy fields" intake | `model_instance_wizard_runs_v1` (wizard_answers -> normalized_fields) |
| Provider contract | `provider_connection_contracts_v1` (oauth default, `secret_ref_only`/`vault_ref_only`, manual key = developer fallback only) |
| Per-org connection | `provider_connection_sessions_v1` (status, account/project ref, `secret_ref`, discovered_resources, verification_results) |
| Readiness | `provider_readiness_rollups_v1`, `provider_connection_rollups_v1`, `launch_blocked` flags |
| Domains | `domain_provider_connections_v1`, `domain_runtime_bindings_v1` (dns/ssl status) |
| Launch pipeline | `launch_execution_runs_v1`, `launch_failure/retry/rollback_events_v1`, launch receipts |
| Idempotent event ingest | pattern from `payment_events_v1` + one-time receipts (proven today) |
| Audit, MFA step-up | `pods.audit_log`, SESSION_ASSURANCE (aal2) |

The hub is mostly GOVERN + WIRE + SURFACE. Five gaps need new objects (section 2).

## 2. New objects (gaps)
1. **Project lifecycle** — `project_lifecycle_v1` (current stage per project) and
   `stage_transitions_v1` (who/when/why, gate result). Stages:
   `draft -> build -> staging -> launch_review -> active -> paused -> archived`.
   Transitions only via RPC; a transition that fails its gate is refused and receipted.
2. **Stage policies** — `stage_policies_v1`: declarative requirements per stage (section 3).
   Evaluated by `rpc_evaluate_stage_gate_v1(project_id, target_stage)` -> pass/fail + reasons.
3. **Credential references** — `credential_refs_v1`: one row per secret the project depends on:
   provider, purpose, environment (`test`|`live`), storage (`vault`|`provider_oauth`|
   `operator_env`), vault handle, scopes, created_by, `rotates_at`, `last_verified_at`,
   status (`valid`|`expiring`|`invalid`|`revoked`). **Never the value.** Values live in
   Supabase Vault (or the provider's OAuth grant), readable only by service-role edge functions.
4. **Resource inventory** — `provider_resources_v1`: what each connection actually controls —
   repos, branches, DNS zones/records, deployments, buckets, SES identities, Figma files, OSF
   projects — with external id, kind, environment, status, `last_seen_at`. Populated by
   discovery on connect and refreshed by events/polling.
5. **Change feed** — `provider_change_events_v1`: normalized "what changed" timeline
   (provider, resource, change_type, summary, actor if known, occurred_at, source
   `webhook|poll|manual`, `dedupe_key` UNIQUE). Plus `watch_rules_v1`: what each user wants
   to track (provider/resource/change_type -> in-app | email), so the feed can be filtered to
   "recent updates I care about".

All five: RLS fail-closed, org-scoped read RPCs, writes via service-role ingest only, audit rows.

## 3. Lifecycle gates (the "dynamic system")
Illustrative defaults; exact rules are data in `stage_policies_v1`, not code.

| Stage | Requires to enter | Tightens once there |
|---|---|---|
| draft | project + wizard fields | nothing |
| build | required providers connected (readiness rollup) | test credentials only |
| staging | domain bound on a staging host, test payments proven | change feed on, drift alerts on |
| launch_review | all required credentials `valid` and `live` refs present, backups verified, owners have MFA | transitions need aal2 |
| active | launch receipt, DNS+SSL verified, Stripe live webhook healthy | every privileged action aal2; expiring keys raise alerts; drift = incident |
| paused / archived | reason recorded | billing-lapse (6e) can force `paused` automatically |

## 4. Provider matrix (first pass — each row is verified in its own slice)
| Provider | Preferred connection | Change source | Notes |
|---|---|---|---|
| GitHub | GitHub App / OAuth | webhooks | repos, deployments, releases |
| GitLab | OAuth | webhooks | |
| Supabase | OAuth / Management API | poll | projects, migrations, edge functions |
| Cloudflare | scoped API token (vault) | poll + notifications | zones, DNS, SSL |
| Stripe | restricted key + webhook | webhooks | done: ingest + entitlements |
| Google | OAuth | poll | auth + Workspace resources |
| Figma | OAuth | webhooks | files, versions |
| AWS / SES | IAM role assumption (external id), no long-lived keys | EventBridge/SNS or poll | identities, sending status |
| Vultr | API key (vault) | poll | instances |
| Squarespace | limited API; OAuth where offered | poll / manual | may be partly manual |
| OSF | OAuth / personal token | poll | projects, files |
| CoStar | likely no open API — partner agreement or manual entry | manual | confirm before promising |

Rule: prefer OAuth / role assumption; a pasted key is the fallback, goes straight to Vault,
and gets a `rotates_at`.

## 5. Dashboard (surface, built after the data layer)
Workspace overview -> projects with stage + readiness + "what changed since you last looked";
per project: Connections, Resources, Keys & secrets (metadata + rotation), Change feed,
Launch checklist (live gate evaluation), Billing/entitlements. Everything reads through the
RPCs above; the UI holds no authority.

## 6. Sequenced slices
- **H1** lifecycle + stage policies + gate RPC + selftests (no providers needed).
- **H2** credential refs (Vault-backed) + resource inventory; wire existing connection sessions.
- **H3** change feed + dedupe + watch rules; first adapters: GitHub, Supabase, Cloudflare
  (Stripe events also land in the feed).
- **H4** notifications (in-app first, email via SES later).
- **H5** dashboard UI.
- **H6+** remaining providers one per slice, each with a verified matrix row.

## 7. Operator decisions (2026-09-22)
1. Project = EITHER a ProteusOps model instance OR an imported project (origin `proteus_model` |
   `imported`; a model project must link its instance, an imported one must not).
2. Stage names/order as in section 3 (implemented in H1 as data).
3. H3 provider order: GitHub (GitLab shares the adapter shape, follows) -> Supabase -> Cloudflare -> AWS/SES.
4. past_due: keep paid features for a 7-day grace window, then lapse to baseline (slice 6g;
   `billing_in_grace` capability for a UI banner). Auto-pausing an active project after grace
   lands with H3/H4 notifications.

## 7a. Build status
- 6g `20260922210000_billing_past_due_grace_v1` — PROTEUSOPS_BILLING_GRACE_OK (staged)
- H1 `20260922211000_hub_lifecycle_v1` — PROTEUSOPS_HUB_LIFECYCLE_OK (staged). Evaluators live now:
  source_linked, providers_ready, workspace_paid, owners_mfa_enrolled, reason_recorded. Declared
  and failing closed until H2/H3: credentials_valid_live, domain_dns_ssl_verified, launch_receipt.

## 8. Guardrails
No secret values in DB, git, logs or UI. No client-trusted authority. Every provider call
server-side with least-privilege scopes. Test and live credentials never share a ref.
No hosted change without approval.
