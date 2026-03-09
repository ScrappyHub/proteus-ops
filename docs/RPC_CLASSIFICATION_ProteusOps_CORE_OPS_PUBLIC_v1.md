# RPC CLASSIFICATION — ProteusOps CORE / OPS / PUBLIC v1

## Status

Canonical RPC lane classification for ProteusOps after introduction of the
`pods_core`, `pods_ops`, and `pods_public` schema lanes.

This document maps every current RPC into the canonical lane architecture.

This is a **classification document**, not a migration.  
No runtime behavior changes are introduced by this document.

---

# Canonical lane definitions

## pods_core

Governance, tenancy, commercial state, membership, capability law,
and entitlement materialization.

Examples:

- owner creation / bootstrap
- membership mutation
- plan assignment
- capability recompute
- billing ingestion
- internal service-role maintenance

---

## pods_ops

Operational execution surfaces.

Examples:

- booking
- scheduling
- time off
- staff assignment
- operational resets
- operational state mutation

---

## pods_public

Public-facing request or projection surfaces.

Examples:

- public booking request
- public storefront listing
- public read projections
- public discovery endpoints

Public surfaces **must not be the authority** for governance or mutation law.

---

# Canonical RPC classification

## pods_core RPCs

These functions govern owners, memberships, plans, and entitlements.

### rpc_recompute_entitlements(uuid)

Lane: `pods_core`

Purpose:

Materializes capability entitlements based on:

- subscription
- plan tier
- plan capability definitions

This is a governance function.

---

### rpc_selftest_set_subscription_plan_v1(uuid, text, text)

Lane: `pods_core`

Purpose:

Used by deterministic selftests to change subscription plan state
and validate entitlement recompute behavior.

---

### rpc_selftest_add_org_member_v1(uuid, uuid, text)

Lane: `pods_core`

Purpose:

Internal helper used by selftests to attach a user to an org
for governance and membership testing.

---

### rpc_org_bootstrap_v1(...)  *(if present)*

Lane: `pods_core`

Purpose:

Creates the governed owner object and initial administrative membership.

---

### rpc_billing_ingest_v1(...) *(if present)*

Lane: `pods_core`

Purpose:

Consumes billing events and applies subscription state changes.

---

# pods_ops RPCs

These functions mutate operational records.

## Booking lane

### rpc_upsert_availability_rule_v1(...)

Lane: `pods_ops`

Purpose:

Creates or updates availability rules for staff scheduling.

---

### rpc_create_appointment_v1(...)

Lane: `pods_ops`

Purpose:

Creates a booking appointment.

This function enforces:

- capability checks
- availability overlap
- time-off collision
- membership scope

---

### rpc_add_time_off_block_v1(...)

Lane: `pods_ops`

Purpose:

Adds a time-off block preventing booking conflicts.

---

### rpc_selftest_reset_booking_v1(...)

Lane: `pods_ops`

Purpose:

Used by deterministic selftests to reset booking state
to a clean environment.

---

# pods_public RPCs

Public request or projection surfaces.

## Public booking request

### rpc_request_booking_v1(...) *(if present)*

Lane: `pods_public`

Purpose:

Public booking request endpoint.

Must enforce:

- capability checks
- booking lane enablement
- schedule validation

This surface must remain **strictly capability-gated**.

---

# Service-role maintenance surfaces

Some RPCs exist solely for internal maintenance
or deterministic test harnesses.

Examples:

- org membership helpers
- booking reset helpers
- subscription test mutations

These may appear in the `public` schema for PostgREST compatibility
but remain **conceptually classified under pods_core or pods_ops**.

---

# Classification invariants

Every RPC must answer the following:

1. Which owner governs this action?
2. Which lane does this RPC belong to?
3. Which capability permits execution?
4. Which membership or role authorizes the caller?
5. Is the surface internal, authenticated, or public?
6. What deterministic selftest validates this RPC?

If any RPC cannot answer these questions clearly,
it must be refactored.

---

# Future RPC classification requirements

All future RPCs must be declared under one lane:

- pods_core
- pods_ops
- pods_public

The lane must be documented in:

- migration comments
- RPC documentation
- schema transition docs

---

# Canonical enforcement rule

Governance always wins.

If an RPC appears to belong to both governance and operations,
it belongs in **pods_core**.

Operational mutation functions must rely on governance facts
but must not redefine them.

---

# Result

With this classification in place, ProteusOps now has:

- canonical lane architecture
- schema boundaries
- operational lane separation
- governance-first RPC classification

This establishes the structural foundation for ProteusOps
to evolve as a **true service-business meta infrastructure system**
rather than a single-purpose application.
