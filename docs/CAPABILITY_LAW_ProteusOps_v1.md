# CAPABILITY LAW — ProteusOps v1

Status: Locked  
Scope: ProteusOps governance, entitlements, and operational permission model  
Purpose: Define the canonical law by which commercial state becomes operational permission

---

# Core principle

ProteusOps is a governed service-business meta-infrastructure system.

It does not enable product behavior directly from UI state.

It enables product behavior through a deterministic governance chain:

Plans -> Capabilities -> Entitlements -> Operational permission

This chain is the canonical law surface for ProteusOps.

---

# Canonical chain

## 1. Subscription state

A governed owner object (org/group/business owner) has subscription state.

Examples:

- no subscription
- inactive subscription
- trialing subscription
- active subscription
- canceled / expired subscription

Subscription state alone does not directly grant operational power.

It only establishes the commercial basis from which plan interpretation may occur.

---

## 2. Plan tier

A subscription references a plan tier.

Examples:

- `proteusops_s_v1`
- `proteusops_sb_v1`

The plan tier defines the commercial package.

A plan tier does not directly authorize an RPC call by itself.

It is an input into capability materialization.

---

## 3. Plan capabilities

A plan tier expands into plan capabilities.

Examples:

- `storefront_enabled = true`
- `booking_enabled = false`
- `paid_active = true`
- future:
  - `staff_count_max`
  - `location_count_max`
  - `can_collect_online_payment`
  - `can_use_waitlist`
  - `can_use_packages`
  - `can_use_marketplace_surface`

These are canonical policy facts attached to the plan.

They are not UI flags.

They are not advisory metadata.

They are governance law inputs.

---

## 4. Entitlement materialization

Plan capability facts are materialized into org entitlements.

Canonical object:

- `pods.org_entitlements`
- conceptually classified under `pods_core`

Materialized entitlements are the authoritative runtime facts used by operational RPCs.

This means operational surfaces do not need to reinterpret commercial logic every time.

Instead, they query materialized entitlement state.

---

## 5. Operational permission

Operational RPCs are allowed or denied based on entitlement facts.

Examples:

- booking appointment creation
- public booking request
- storefront exposure
- schedule management
- future staff/location expansion
- future package/payment/waitlist/marketplace actions

Operational permission is therefore the result of governance law,
not the result of application convenience.

---

# Canonical law statement

The canonical ProteusOps permission chain is:

1. owner has subscription state  
2. subscription references plan tier  
3. plan tier defines plan capabilities  
4. recompute materializes entitlements  
5. operational RPC checks entitlements  
6. action is allowed or denied deterministically

If any runtime surface bypasses this chain, it is out of spec.

---

# Canonical objects

## Owner object

ProteusOps operates on a governed owner object.

Current shape:

- org

Future shape may generalize toward group/owner semantics,
but the law remains the same.

The owner object is the root subject for:

- subscriptions
- memberships
- entitlements
- operational lanes

---

## Subscription object

Subscription is a commercial-state object.

Responsibilities:

- identify current plan
- identify status
- anchor billing/commercial state

Subscription is necessary but not sufficient for permission.

---

## Plan tier object

Plan tier represents a named commercial package.

Responsibilities:

- define plan identity
- serve as the expansion source for capability law

Plan tiers must be stable, versioned identifiers.

---

## Plan capability object

Plan capability is a typed policy fact.

Examples of supported kinds:

- boolean capability
- integer capability
- text capability
- future structured capability if deliberately introduced

Capability keys must be stable and semantically clear.

Examples:

- `storefront_enabled`
- `booking_enabled`
- `paid_active`
- `max_monthly_appointments`

---

## Org entitlement object

Entitlements are the runtime materialization layer.

Responsibilities:

- flatten or materialize effective capability state for an owner
- provide deterministic lookup to operational surfaces
- reduce repeated commercial interpretation in ops RPCs

Entitlements are authoritative runtime permission facts.

---

# Canonical operational enforcement rule

No operational RPC may rely solely on:

- UI state
- client claims
- inferred plan name without entitlements
- unmaterialized assumptions

Operational permission must be based on authoritative entitlement facts.

---

# Example law flow

## Booking enabled example

Given:

- org subscription status = `trialing`
- plan tier = `proteusops_sb_v1`
- plan capabilities contain:
  - `booking_enabled = true`

Then:

- recompute writes an entitlement for booking capability
- booking RPC checks entitlement
- booking mutation is allowed if all other rules also pass

Those other rules may include:

- valid membership
- valid staff relation
- no overlap
- no time-off conflict
- valid time window

Capability law grants eligibility to attempt the action.
Operational law determines whether the specific action instance is valid.

---

## Booking disabled example

Given:

- org subscription status = `trialing`
- plan tier = `proteusops_s_v1`
- plan capabilities contain:
  - `booking_enabled = false`

Then:

- recompute writes booking entitlement as disabled
- booking RPC checks entitlement
- booking RPC fails deterministically with the expected token

This is the correct law behavior.

---

# Canonical distinction: capability law vs operational law

## Capability law answers:
Is this lane allowed at all for this owner?

Examples:

- can this org use booking?
- can this org expose storefront?
- can this org use public booking?
- can this org use waitlist?

## Operational law answers:
Is this specific operation valid right now?

Examples:

- is this timeslot free?
- is staff on time off?
- does this overlap another appointment?
- is this user authorized to mutate this row?

Both laws are required.

Capability law comes first.

---

# Deterministic recompute law

`rpc_recompute_entitlements(uuid)` is a canonical governance function.

Responsibilities:

- inspect authoritative commercial state
- read plan tier
- read plan capability definitions
- materialize effective entitlements for the owner

Requirements:

- deterministic for the same underlying inputs
- no hidden client-side assumptions
- no dependency on UI state
- output must be authoritative for operational surfaces

If entitlements drift from plan/subscription state, the system is out of spec.

---

# Capability key law

Capability keys must obey these rules:

1. stable name
2. explicit meaning
3. lane relevance must be obvious
4. typed value must be clear
5. no ambiguous “feature switch” language

Good examples:

- `booking_enabled`
- `storefront_enabled`
- `paid_active`
- `staff_count_max`
- `location_count_max`

Bad examples:

- `premium_mode`
- `pro_tools`
- `advanced_features`

ProteusOps requires governance-grade naming, not marketing shorthand.

---

# Lane relationship to capability law

## pods_core

Authoritative home for:

- subscriptions
- plan tiers
- plan capabilities
- entitlements
- recompute logic

## pods_ops

Consumes capability law.

Examples:

- booking RPCs read entitlements before mutating state

## pods_public

Exposes only what capability law allows.

Examples:

- public booking request only if public booking capability is enabled
- storefront projections only if storefront capability is enabled

---

# Future capability expansion

ProteusOps is intended to become a real meta-infrastructure substrate.

Therefore capability law must scale beyond current booking/storefront examples.

Future categories include:

## Governance/commercial
- `paid_active`
- `subscription_required`
- `trial_allowed`

## Booking lane
- `booking_enabled`
- `can_use_public_booking`
- `max_monthly_appointments`
- `waitlist_enabled`

## Storefront lane
- `storefront_enabled`
- `can_publish_public_catalog`
- `can_sell_packages`

## Operations expansion
- `staff_count_max`
- `location_count_max`
- `can_collect_online_payment`
- `can_use_memberships`
- `can_use_packages`
- `can_use_marketplace_surface`

These must still materialize through the same law chain.

---

# Selftest law

Capability law must be proven by deterministic selftests.

Current proof examples:

- plan flip to disabled booking plan
- entitlement recompute
- booking attempt fails with expected token
- restore plan
- booking re-enabled

This is the correct shape of proof.

Future selftests must validate:

- storefront capability gating
- public request capability gating
- future staff/location cap enforcement
- future waitlist/package/payment capability enforcement

---

# Canonical restore-phase idea

ProteusOps should adopt a restore/sane-state discipline.

Purpose:

- return the project to a known-good governance/runtime state
- reduce drift between experiments
- make deterministic selftests reproducible
- support future sealed restore workflows

Recommended restore phases:

## Restore Phase A — schema sanity
- required schemas exist
- required tables/views/functions exist
- authoritative wrappers exist

## Restore Phase B — governance sanity
- required plan tiers exist
- required capability keys exist
- test org exists
- test membership exists
- recompute path is valid

## Restore Phase C — operational sanity
- booking test fixtures reset cleanly
- availability state reset
- time-off state reset
- test appointments removed

## Restore Phase D — selftest sanity
- env/secret inputs resolvable
- authoritative selftest surface runs
- authoritative runner surface runs

This restore-phase model is strongly aligned with deterministic system law
and should be adopted as ProteusOps matures.

---

# Scope discipline

ProteusOps should not try to become “all of Supabase” right now.

That would be premature and would risk architectural noise.

Canonical guidance:

- keep ProteusOps focused on governed service-business infrastructure
- preserve Supabase as substrate/runtime
- build only the governance and lane abstractions ProteusOps actually needs
- do not expand faster than deterministic proof coverage

In other words:

ProteusOps should gain the governance shape needed to use Supabase well,
not attempt to reimplement Supabase itself.

---

# Definition of Done for capability law phase

This phase is complete when:

- the capability chain is locked in documentation
- plan -> capability -> entitlement -> permission is the accepted law
- operational RPCs are understood as entitlement consumers
- recompute is recognized as authoritative governance logic
- future capability keys follow stable naming law
- restore-phase discipline is recognized as canonical future work

---

# Canonical summary

ProteusOps is governed by the following law:

Plans define capabilities.  
Capabilities are materialized as entitlements.  
Entitlements authorize operational lanes.  
Operational RPCs must not bypass entitlement law.

This is the mechanism by which ProteusOps becomes a real
governed meta-infrastructure system rather than a feature-driven app.
