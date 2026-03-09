# ProteusOps — Architecture Overview

ProteusOps is a governed service-business meta-infrastructure system designed to support operational lanes such as booking and storefront under a deterministic governance model.

The system is intentionally structured around **governance first**, not UI-first application logic.

This document describes the canonical architecture that ProteusOps follows.

---

# Core architectural principle

ProteusOps separates system concerns into three layers:

1. Governance
2. Operational lanes
3. Public surfaces

This prevents operational code from redefining governance law and allows the system to scale safely into multiple vertical capabilities.

---

# Canonical governance chain

All operational permission flows through a deterministic governance chain.


Subscription
↓
Plan Tier
↓
Plan Capabilities
↓
Org Entitlements
↓
Operational Permission


This is referred to as **Capability Law**.

Operational behavior must never bypass this chain.

---

# Schema lane architecture

ProteusOps is transitioning to a lane-based schema architecture.

## pods_core

Governance and system authority.

Responsibilities:

- owner objects (org)
- memberships
- subscription state
- plan tiers
- plan capabilities
- entitlement materialization
- governance RPC surfaces

Examples of tables:


pods.orgs
pods.org_members
pods.subscriptions
pods.plan_tiers
pods.plan_capabilities
pods.org_entitlements


---

## pods_ops

Operational execution surfaces.

Responsibilities:

- service records
- booking operations
- scheduling
- time-off
- staff/location management
- operational mutation RPCs

Examples:


pods.booking_appointments
pods.booking_availability_rules
pods.booking_time_off_blocks


---

## pods_public

Public request or projection surfaces.

Responsibilities:

- public booking requests
- storefront projections
- public discovery endpoints

Public surfaces never hold governance authority.

They are request boundaries or projections.

---

# RPC classification

Every RPC in ProteusOps belongs to one lane.

## pods_core RPCs

Governance surfaces.

Examples:

- `rpc_recompute_entitlements`
- `rpc_selftest_set_subscription_plan_v1`
- `rpc_selftest_add_org_member_v1`

These modify or materialize governance state.

---

## pods_ops RPCs

Operational mutation surfaces.

Examples:

- `rpc_create_appointment_v1`
- `rpc_upsert_availability_rule_v1`
- `rpc_add_time_off_block_v1`

These enforce operational constraints but must respect entitlement law.

---

## pods_public RPCs

Public request surfaces.

Examples:

- `rpc_request_booking_v1`

These are externally callable request entry points.

They must still enforce capability and entitlement checks.

---

# Capability law

ProteusOps does not enable product features directly through UI logic.

Instead, operational permission flows through the capability system.

Example capability keys:


booking_enabled
storefront_enabled
paid_active
staff_count_max
location_count_max


Capabilities are defined at the plan level.

They are materialized into org entitlements via recompute.

Operational RPCs check entitlements before allowing mutation.

---

# Entitlement recompute

Entitlements are produced by:


rpc_recompute_entitlements(uuid)


Responsibilities:

- inspect subscription state
- determine plan tier
- read plan capabilities
- materialize effective entitlements

This provides a deterministic runtime permission layer for operational RPCs.

---

# Operational law

Capability law answers:


Is this lane allowed for this owner?


Operational law answers:


Is this specific operation valid right now?


Example booking validation:

- capability `booking_enabled` must be true
- membership must exist
- time slot must be valid
- no overlap with existing appointments
- no conflict with time-off

Both laws must pass for an operation to succeed.

---

# Deterministic engineering discipline

ProteusOps follows strict deterministic engineering practices.

These include:

- canonical runner surfaces
- parse-gated PowerShell scripts
- deterministic selftests
- UTF-8 no BOM file encoding
- LF line endings
- environment-resolved secrets
- stable success tokens

The goal is to make system behavior reproducible.

---

# Runner architecture

ProteusOps exposes two canonical execution surfaces.

Selftest runner:


scripts/selftest_all.ps1


Tier-0 full-green runner:


scripts/_RUN_proteusops_tier0_full_green_v7.ps1


The selftest validates behavior.

The full-green runner produces deterministic evidence.

---

# Restore discipline

ProteusOps is intended to support a **restore-phase model**.

Restore phases allow the project to return to a known sane state.

Recommended restore phases:

### Restore A — schema sanity

- schemas exist
- required tables exist
- compatibility views exist

### Restore B — governance sanity

- required plan tiers exist
- capability keys exist
- test org exists
- test membership exists

### Restore C — operational sanity

- booking fixtures reset
- availability rules reset
- time-off blocks reset

### Restore D — selftest sanity

- secrets available
- canonical runner executes
- deterministic proof surfaces pass

This restore discipline aligns with deterministic system engineering.

---

# Role of Supabase

ProteusOps currently runs on Supabase.

Supabase provides:

- PostgreSQL
- authentication
- storage
- API exposure

ProteusOps does **not attempt to replace Supabase**.

Instead, ProteusOps introduces a governance and capability architecture
that sits on top of Supabase to support service-business infrastructure.

---

# Long-term vision

ProteusOps is intended to evolve into a reusable operational substrate
for service businesses.

Possible operational lanes include:

- booking
- storefront
- scheduling
- staff/location management
- memberships
- packages
- payments
- waitlists
- marketplace surfaces

All lanes must still respect the same governance and capability law.

---

# Summary

ProteusOps is built around three architectural ideas:

1. Governance before operations  
2. Capability law before feature toggles  
3. Deterministic infrastructure before product expansion

This architecture allows ProteusOps to evolve from a booking/storefront
prototype into a full service-business infrastructure layer.
