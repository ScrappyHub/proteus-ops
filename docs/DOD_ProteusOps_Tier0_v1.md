ProteusOps is Tier-0 ship-ready when:

DB Authority Proven

RLS enabled on all tables

No UI-only gating exists for access control or billing

Direct writes to billing/subscription/entitlement tables are impossible from client roles

Subscription Sync + Enforcement

service-role webhook ingest updates billing mirror + recomputes entitlements

reconciler plan documented (job to prevent webhook gaps)

when unpaid/inactive, gated writes deterministically fail

Model Separation

storefront runs without booking

booking installs as separate model with dependency on core+storefront

upgrades are versioned; no per-client schema drift

Bootstrap + Audit

rpc_create_org_bootstrap creates org + owner + installs models + seeds profile

audit_log has deterministic entries for bootstrap + billing ingest + entitlement recompute

Selftests

a repeatable selftest script (later) proves:

unpaid FAIL token

paid PASS token

entitlements reflect billing status