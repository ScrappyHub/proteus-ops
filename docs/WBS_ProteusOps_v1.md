WBS-01 Repo + Discipline

01.01 Repo created C:\dev\proteusops

01.02 migrations folder + monotonic naming

01.03 docs folder + model catalog

WBS-02 Core Model (pods.core.v1)

02.01 schema + tables

02.02 helper functions (org_role, has_cap)

02.03 entitlement materialization RPC

02.04 billing ingest RPC (service-role only)

02.05 baseline RLS (no client writes to billing/entitlements)

WBS-03 Storefront Model (pods.storefront.v1)

03.01 schema tables (profile, team, services, locations, inquiries)

03.02 RLS policies (member read, owner/admin write + entitlement gate)

03.03 org bootstrap RPC (create org + owner + install models)

03.04 minimal plan seed + entitlement check

WBS-04 Booking Model (pods.booking.v1)

04.01 schema tables (availability, appointments, customers)

04.02 RPC-only appointment create/cancel + overlap prevention

04.03 booking entitlement + usage counters enforcement

04.04 RLS policies for staff/customer views

WBS-05 Payments + Marketplace (later)

05.01 pods.payments.v1 ledger + reconciliation markers

05.02 pods.marketplace.v1 (orders, listings, accounts)

WBS-06 Selftests + Proof

06.01 unpaid: gated write fails (deterministic token)

06.02 paid: gated write succeeds

06.03 billing webhook sync triggers entitlement recompute

06.04 receipts/audit log entries present for bootstrap + billing ingest + recompute

WBS-07 Release Discipline

07.01 Model catalog finalized

07.02 Tag v0.1 (core + storefront)

07.03 Tag v0.2 (booking)