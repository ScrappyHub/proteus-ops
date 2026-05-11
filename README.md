# ProteusOps

ProteusOps is a deterministic operational orchestration and governance platform focused on reproducible workflows, lane isolation, entitlement enforcement, and verifiable execution.

The system is designed around:

- deterministic execution
- schema lane isolation
- hardened public surfaces
- append-only evidence receipts
- reproducible selftests
- deterministic operational runners
- verifiable boundary enforcement

---

## Core Capabilities

### Operational Scheduling

ProteusOps supports:

- appointment creation
- overlap prevention
- availability rules
- time-off enforcement
- organization-scoped scheduling flows

Validated through deterministic selftests.

---

### Schema Lane Isolation

Tier-1 introduces strict operational lane boundaries between:

- billing
- core
- ops
- public

Boundary verification includes:

- denied cross-lane writes
- denied privileged public access
- deterministic enforcement vectors
- append-only verification evidence

---

### Public Surface Hardening

Public RPC and view exposure is constrained through deterministic verification rules.

Validated protections include:

- denied privileged public execution
- denied internal surface reads
- explicit allowed public booking surfaces

---

## Deterministic Engineering Model

ProteusOps follows deterministic operational laws:

- UTF-8 no BOM + LF
- parse-gated runners
- append-only receipts
- deterministic sha256 evidence
- reproducible selftests
- repo-local secret ingestion
- isolated runner execution

---

## Evidence

Receipts and execution evidence are emitted under:

proofs/receipts/

Tier-1 witness:

docs/TIER1_WITNESS_ProteusOps_v1.md

---

## Current Proven State

Canonical success tokens:

PROTEUSOPS_TIER0_FULL_GREEN_OK

PROTEUSOPS_TIER1_FULL_GREEN_OK

PROTEUSOPS_TIER1_WITNESS_LOCK_OK
