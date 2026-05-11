# ProteusOps Tier-1 Witness — v1

## Status

Tier-1 achieved FULL GREEN.

Canonical success token:

PROTEUSOPS_TIER1_FULL_GREEN_OK

Canonical run:

RUN_ID=20260511_204015Z

---

## Proven Surfaces

### Tier-0 Runtime

Validated:

- restore sane runner
- selftest pipeline
- deterministic receipts
- deterministic sha256sums
- append-only NDJSON receipt logging

Canonical token:

TIER0_OK

---

### Lane Boundary Enforcement

Validated:

- billing → core denied
- billing → ops denied
- billing → public denied
- core → ops denied
- core → public denied
- ops → billing denied
- ops → core denied
- ops → public denied
- public → billing denied
- public → core denied
- public → ops denied

Allowed surfaces verified:

- billing → billing execute
- core → core execute
- ops → ops execute
- public → public execute

Canonical token:

LANE_OK

---

### Public Surface Hardening

Validated:

- public execute denied for privileged surfaces
- public read denied for internal lane views
- public request_booking allowed

Canonical token:

PUBLIC_OK

---

## Deterministic Evidence

Primary receipt directory:

proofs/receipts/proteusops_tier1/20260511_204015Z/

Artifacts:

- tier0_stdout.txt
- tier0_stderr.txt
- lane_stdout.txt
- lane_stderr.txt
- public_stdout.txt
- public_stderr.txt
- sha256sums.txt

Append-only ledger:

proofs/receipts/proteusops_tier1.ndjson

---

## Critical Engineering Corrections Proven

### Secret Auto-Ingestion

Tier-1 runner now force-loads secrets from:

proofs/secrets/

No dependence on stale inherited process environment.

Validated variables:

- SUPABASE_SERVICE_ROLE_KEY
- SUPABASE_ANON_KEY
- SUPABASE_URL
- DATABASE_URL
- TEST_EMAIL
- TEST_PASSWORD
- ORG_ID

---

### IPv4 Compatibility Correction

Direct Supabase hostname failed on IPv4-only resolution.

Broken host:

db.ytwjyemqlbbebysiopzd.supabase.co

Correct Tier-1 host:

aws-1-us-east-2.pooler.supabase.com

Tier-1 runner now validates against accidental direct-host regression.

---

### PowerShell Invocation Stability

Resolved deterministic invocation defect:

-ArgumentList $Args

Corrected to:

-ArgumentList $ArgString

This removed null binding instability during Start-Process execution.

---

## Tier-1 Definition of Done

Achieved:

- deterministic Tier-0 execution
- deterministic lane boundary verification
- deterministic public surface verification
- deterministic receipts
- deterministic sha256 evidence
- append-only witness logging
- parse-gated runners
- repo-local secret loading
- pooler-based PostgreSQL connectivity
- fully reproducible FULL_GREEN execution

---

## Canonical Final Token

PROTEUSOPS_TIER1_FULL_GREEN_OK
