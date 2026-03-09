# RUNNER CONSOLIDATION — ProteusOps Tier-0 v1

Status: Locked  
Scope: ProteusOps deterministic test and Tier-0 runner surfaces  
Purpose: Eliminate runner drift and establish a single authoritative execution path

---

# Background

During the early ProteusOps bootstrap phase, multiple runner and patch scripts
were created in order to resolve environment loading, quoting issues, strict-mode
violations, and deterministic execution problems.

This created a temporary condition where multiple files appeared to be
"current" execution surfaces.

This document defines the **canonical consolidation rules** so that ProteusOps
remains deterministic and maintainable.

This follows the platform law:

> Reduce noise. One bug → one fix.  
> Prefer overwrite-with-known-good runners instead of spawning new runners.

---

# Canonical execution surfaces

After consolidation, ProteusOps must expose exactly **two execution surfaces**.

## Authoritative selftest


scripts\selftest_all.ps1


Purpose:

Runs the deterministic Node test suite used by ProteusOps.

Responsibilities:

- load required secrets if process environment is empty
- resolve repository root deterministically
- run the Node selftests
- fail hard on any Node failure
- print a single success token

Success token:


FULL_GREEN_SELFTEST_OK


This script **does not produce receipts or artifacts**.

It is strictly responsible for validating behavior.

---

## Authoritative Tier-0 runner


scripts_RUN_proteusops_tier0_full_green_v7.ps1


Purpose:

Deterministic Tier-0 orchestration runner.

Responsibilities:

1. Parse-gate authoritative scripts
2. Load required environment variables if missing
3. Execute `selftest_all.ps1`
4. Capture stdout and stderr deterministically
5. Verify the success token
6. Emit evidence artifacts
7. Append deterministic receipts

Expected final success token:


PROTEUSOPS_TIER0_FULL_GREEN_OK


This runner is the **only authoritative Tier-0 execution entry point**.

---

# Node test components

The following files are not runners but deterministic test components:


selftest_booking.js
selftest_booking_disabled.js


These are invoked by `selftest_all.ps1`.

They must not be executed as standalone entry points for Tier-0 validation.

---

# Retired runner policy

Any runner that is not the authoritative runner must be retired.

Examples include:


scripts_RUN_proteusops_tier0_full_green_v1.ps1
scripts_RUN_proteusops_tier0_full_green_v2.ps1
scripts_RUN_proteusops_tier0_full_green_v3.ps1
scripts_RUN_proteusops_tier0_full_green_v4.ps1
scripts_RUN_proteusops_tier0_full_green_v5.ps1
scripts_RUN_proteusops_tier0_full_green_v6.ps1
scripts_RUN_proteusops_tier0_full_green_v6b.ps1


These must be moved to:


scripts_scratch_dead\


They must not remain in the live `scripts` directory.

---

# Patch script policy

Temporary patch scripts used to repair quoting or environment loading issues
must also be retired once their fixes are incorporated into the canonical
runner.

Examples:


_PATCH_runner_v7_load_supabase_url_v1.ps1
_PATCH_overwrite_selftest_all_v1.ps1
_PATCH_overwrite_selftest_all_load_secrets_v1.ps1


If a patch script remains useful as a recovery tool,
only **one known-good overwrite patch** may remain.

All other patch scripts must be moved to:


scripts_scratch_dead\


---

# Anti-drift rules

ProteusOps must follow these runner discipline rules.

1. Exactly one authoritative selftest
2. Exactly one authoritative Tier-0 runner
3. All legacy runners moved to `_scratch/_dead`
4. New runner versions must retire the previous runner
5. Runner changes must overwrite the authoritative file, not fork it
6. Documentation must always reference the canonical runner

These rules ensure that ProteusOps remains deterministic and
maintainable as the system evolves.

---

# Deterministic execution chain

The canonical Tier-0 execution chain is:


_RUN_proteusops_tier0_full_green_v7.ps1
↓
selftest_all.ps1
↓
selftest_booking.js
selftest_booking_disabled.js


No other execution path is considered canonical.

---

# Definition of completion

Runner consolidation is complete when:

- exactly one authoritative selftest exists
- exactly one authoritative Tier-0 runner exists
- no legacy runners remain in the live scripts directory
- documentation references only the canonical pair
- the authoritative runner executes successfully
- deterministic evidence artifacts are produced

---

# Result

After consolidation, ProteusOps maintains a **single deterministic execution
surface**, eliminating ambiguity and preventing runner drift.

This prepares the system for stable Tier-0 sealing and future
meta-infrastructure expansion.
