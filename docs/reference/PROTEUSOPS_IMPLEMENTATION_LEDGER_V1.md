# ProteusOps Implementation Ledger v1

- Artifact: `PROTEUSOPS_IMPLEMENTATION_LEDGER_V1`
- Generated (UTC): 2026-09-21
- Method: repository introspection (device shell) + live database introspection
  (`docker exec supabase_db_proteusops psql`, non-destructive) + hosted link attempt.
- Verification principle (per Atlas SHARED_INVARIANTS / AGENT_POLICY): stored claims are
  recomputed, not trusted. A model explanation is not proof. Planned is distinguished from
  implemented; local is distinguished from hosted.
- Evidence files: `proofs/audit/live_local_audit_20260921_192504Z.txt` (redacted),
  `proofs/audit/hosted_audit_20260921_19*.txt`, `scripts/_AUDIT_live_local_v1.ps1`,
  `scripts/_AUDIT_hosted_v1.ps1`.

## Verdict

The Platform Constitution is GREEN and live-verified on the LOCAL stack (hashes reproduce
exactly). But the most advanced actual implementation lives in the HOSTED project
(`ytwjyemqlbbebysiopzd`): 186 tables/views and 247 functions across the `pods*` schemas,
covering essentially all declared authorities plus verticals. Hosted, however, has NO
constitution/governance layer and is NOT reproducible from the repo's migrations (only two
`remote_schema` baselines). The repo's committed migrations are a partial, divergent
representation (001-031 real; 032-048 proof-comment stubs). The governance layer (local) and
the application (hosted) have never been unified, and the hosted schema is not captured as
versioned source.


## 1. Live-verified GREEN (local)

`select pods_provisioning.rpc_verify_platform_constitution_v1();` against the running
`supabase_db_proteusops` stack (port 54322) returned:

- `ok: true`, token `PROTEUSOPS_PLATFORM_CONSTITUTION_OK`
- active_authority_count = 9, planned_authority_count = 4
- constitution_hash `bcb9fcbfefdec5417501d3c87569ec7ae63b866b6df83ce0e6c98aedf337e042`
- verification_hash `62af32b8965d81695a8a17f213610be918ee60eb8367c1f5d43670dea380eb62`
- platform_migration_lock_id `47e01e74-f453-491b-a12f-462627fb83f8`

These hashes reproduce the values recorded in the canonical handoff exactly — the
constitution is deterministic and reproducible.

## 2. Decisive finding — the running local database is ONLY the constitution

Live introspection of the `proteusops` database:

- Schemas present: `pods_provisioning`, `public` — nothing else.
- Objects: 3 tables, 3 functions, 0 RLS policies (all in `pods_provisioning`).
- `supabase_migrations.schema_migrations`: one row — `20260721231000 platform_constitution_v1`.
- Historical table probe (`to_regclass`): `pods.organizations`, `pods.appointments`,
  `pods.memberships`, `pods.subscriptions` all NULL / do not exist.
- Schema lanes `pods`, `pods_core`, `pods_billing`, `pods_ops`, `pods_public` do not exist.

The `migrations/001-031` schema (39 tables, 53 functions, 82 policies) is present as SQL in
the repo but is NOT applied to the running database. No captured DB snapshot of the
historical work exists in the repo (the `proofs/recovery/supabase_pre_reinit_*` folder only
preserved the `supabase/` config directory, which already held just the constitution).

There are two disconnected application paths: the Supabase CLI folder
(`supabase/migrations/`) applies ONLY the constitution; the historical set is applied
separately by the PowerShell tier runners, which top out around migration 023. A fresh
`supabase db reset` therefore cannot contain the historical work by construction.

## 3. Authority ledger (constitution registry vs implementation)

Registry status = the row seeded by the constitution (declared). Verified status = what
actually exists, recomputed.

| # | Authority | Category | Registry | Implementation evidence | Verified status |
|---|---|---|---|---|---|
| 10 | MODEL_REGISTRY | runtime | active | repo 030/031 vertical *template* registry (real DDL); not in running DB | PARTIAL — repo only, scope-narrow |
| 20 | MARKETPLACE | commerce | active | none | MISSING |
| 30 | RUNTIME_GENERATOR | runtime | active | repo 028 provisioning lane + 029 bootstrap script; not in running DB | PARTIAL — repo only |
| 40 | LAUNCH_AUTHORITY | deployment | active | repo 032 = comment-only stub | MISSING |
| 50 | SNAPSHOT_ENGINE | operations | active | none | MISSING |
| 60 | AUDIT_LEDGER | governance | active | none | MISSING |
| 70 | RELEASE_GOVERNANCE | deployment | active | none | MISSING |
| 80 | RUNTIME_DRIFT | operations | active | none | MISSING |
| 90 | DOMAIN_PROVIDER_AUTHORITY | provider | active | none | MISSING |
| 100 | DEPLOYMENT_PROVIDER_AUTHORITY | provider | planned | none | PLANNED (correct) |
| 110 | ENVIRONMENT_AUTHORITY | provider | planned | none | PLANNED (correct) |
| 120 | BILLING_ENTITLEMENT_AUTHORITY | commerce | planned | none | PLANNED (correct) |
| 130 | DEVELOPER_MARKETPLACE_AUTHORITY | ecosystem | planned | none | PLANNED (correct) |

Note: the verify RPC only COUNTS registry rows (active >= 9, planned >= 4). It does not
check that any authority's tables/RPCs/selftests exist. "9 active authorities" means 9
declared rows, not 9 implemented authorities. Registration is not implementation.

## 4. Implemented but unregistered (historical PODS work — repo only, not in running DB)

These are real, substantial migrations in `migrations/` that the constitution's authority
list does not name. They map to WBS 4/5 and a booking vertical, not to the platform
authorities above.

| Domain | Migrations | Objects | State |
|---|---|---|---|
| Org / tenant / roles / entitlements | 001-004, 007 | tables + RPCs + RLS | REAL SQL, not in running DB |
| Storefront | 005-006, 014 | tables + RLS + views | REAL SQL, not in running DB |
| Booking (appointments, availability, timeoff) | 008-013, 016 | 5 tables + 11+ RPCs + RLS | REAL SQL, not in running DB |
| Schema lanes + lane selftests | 023-027 | lane views + guards + selftests | REAL SQL, not in running DB |
| Provisioning lane | 028 | 4 tables + RLS | REAL SQL, not in running DB |
| Vertical template registry | 030-031 | 4 tables + provision RPC | REAL SQL, not in running DB |

## 5. Proof-comment stubs (no DDL)

Migrations 032-048 (customer launch receipt, public booking bootstrap, availability engine,
appointment queue, operator calendar, notifications, payment lifecycle, payment adapter
receipts, vertical domain contracts, contractor template/site-visit/estimate flows) are
`begin; -- narrated proof results; commit;` with zero SQL statements. They record CLAIMED
proof results as comments in git history. They implement nothing.

## 6. Hosted (Supabase) — LIVE-VERIFIED 2026-09-21

Project "Proteus Ops", ref `ytwjyemqlbbebysiopzd`, region us-east-2, created 2026-02-25.
Resumed from paused and introspected live via the dashboard SQL editor. This section reverses
the local-only picture.

Hosted is the most advanced ProteusOps implementation by far:

- pods* tables + views: 186 (pods=30, pods_core=11, pods_ops=3, pods_provisioning=138, pods_public=4).
- pods* functions: 247.
- Application layer broadly present: orgs/members/roles/entitlements/billing, storefront,
  booking, a contractor vertical, and a `civic_action_*` vertical.
- The constitution's declared authorities exist here as real schema (not just registry rows):
  model_template_registry / model_marketplace_catalog / model_instance_runtimes /
  model_launch_authorities / model_runtime_snapshots / model_audit_ledger / model_releases /
  model_runtime_drift_* / domain_provider_connections, plus payment_*, provider_connection_*,
  and stripe/supabase/github/email/storage adapter runtimes.

Critical caveats:

- The constitution/governance layer is ABSENT on hosted:
  `to_regclass('pods_provisioning.platform_authority_registry_v1')` = NULL and
  `platform_constitution_versions_v1` = NULL. Hosted runs the application but is NOT governed
  by the constitution.
- Hosted migration history is only two `remote_schema` baselines (20260721222534,
  20260721225911). The 186 objects / 247 functions are NOT built from the repo's numbered
  migrations and are NOT reproducible from versioned source — a violation of the Atlas
  determinism invariant and a disaster-recovery / bus-factor risk.

Net: the three surfaces have never been unified.

| Surface | Constitution/governance | Application | Reproducible from repo |
|---|---|---|---|
| HOSTED `ytwjyemqlbbebysiopzd` | ABSENT | FULL (186 objects, 247 funcs) | NO (2 remote_schema baselines) |
| LOCAL `proteusops` | PRESENT, verified GREEN | ABSENT (3 tables) | constitution only |
| REPO migrations 001-048 | constitution present | PARTIAL (001-031 real, 032-048 stubs) | diverges from hosted |

Evidence: `proofs/audit/hosted_findings_20260921.md`.

### 6a. Authoritative divergence (schema dump vs repo migrations)

Source: `proofs/audit/hosted_schema_20260921_200007Z.sql` (pg_dump schema-only, 937 KB,
secret-scanned clean) diffed against `proofs/audit/repo_objects_v1.txt`. Full lists in
`proofs/audit/divergence_hosted_vs_repo_v1.md`.

- In both surfaces: 104 objects (the base app: pods / pods_core / pods_ops / pods_public,
  plus tier1/provisioning/vertical-template objects that DO have repo migrations).
- Hosted-only (no repo migration): 337 objects — 117 tables, 11 views, 208 functions, all in
  `pods_provisioning`, plus 1 `public` function. This is the entire uncaptured platform layer.
- Repo-only (absent on hosted): exactly 5 — the constitution governance layer only:
  tables `platform_authority_registry_v1`, `platform_constitution_versions_v1`,
  `platform_migration_lock_v1`; functions `rpc_seed_platform_constitution_v1`,
  `rpc_verify_platform_constitution_v1`.

Reading: the base application and the tier1/provisioning/vertical-template scaffolding are
reproducible from repo and present on hosted. The 337 hosted-only objects are the real,
uncaptured platform implementation. The constitution is the only thing repo/local hold that
hosted does not. Migration-history level confirms the same split: remote has baselines
20260721222534 + 20260721225911; local has 20260721231000 (constitution); neither side has
the other's.


## 7. Repository / hygiene state

- Docs: 66 `.md` on disk; `documentation_manifest_v1.json` governs 22 canonical
  (`DOCUMENT_COUNT=22`, consistent).
- Git: last commit `6f965d4` (2026-06-07). The constitution migration, migrations 024-048,
  and most canonical docs are UNTRACKED (~74 untracked, 9 modified). Substantial work is
  uncommitted.
- A stale `.git/index.lock` is present and may block the next commit.
- No frontend/application code exists (only `bootstrap_org.js` and two selftest scripts).
  WBS 17/18 (dashboard, customer experience) is at zero.
- `docs/canonical/` contains only `ECOSYSTEM_INTEGRATION.md` (+ a pipeline zip); the
  `IDENTITY.md` / `SPEC.md` / `CURRENT_STATE.md` referenced by CLAUDE.md/AGENTS.md are
  absent there (a `docs/reference/CURRENT_STATE.md` does exist).

## 8. Recommended next move

The existing-state reconciliation (WBS 3) is now complete across repo + local + hosted. The
top priority is NOT a new authority migration and NOT rebuilding WBS 4 from scratch — the work
largely exists in hosted. It is to close the divergence:

1. Capture the hosted schema as versioned source (`supabase db dump --linked`) so the 186
   objects / 247 functions become reproducible instead of living only in a running project.
2. Decide the source of truth: reconcile hosted schema against repo migrations 001-048 and
   determine what is canonical, what is superseded, and what the numbered migrations should
   become.
3. Bring the hosted application under the constitution (the governance layer that currently
   exists only on local), or decide the constitution is re-based onto the hosted reality.

Only after the hosted schema is captured and a single source of truth is chosen should new
authority work proceed.


## Provenance

Re-run the local verification at any time:
`docker exec -i supabase_db_proteusops psql -U postgres -d postgres -c "select pods_provisioning.rpc_verify_platform_constitution_v1();"`
Expected token: `PROTEUSOPS_PLATFORM_CONSTITUTION_OK`.

## 9. Progress log

### 2026-09-21 — Path A phase 1 (baseline adoption) — GREEN
- Adopted hosted schema as canonical baseline migration
  `supabase/migrations/20260721230000_hosted_baseline_v1.sql` (from the 2026-09-21 dump),
  ordered before the constitution.
- `supabase db reset` applies baseline -> constitution cleanly (benign "already exists"
  notices only). Local now reproduces hosted + governance from versioned migrations:
  pods=30, pods_core=11, pods_ops=3, pods_provisioning=141 (138 app + 3 constitution),
  pods_public=4; 249 functions; `rpc_verify_platform_constitution_v1()` = ok:true
  (hashes bcb9fcbf…, 62af32b8…). Verified via `scripts/_AUDIT_verify_baseline_reset_v1.ps1`
  (evidence: `proofs/audit/baseline_reset_verify_20260921_203905Z.txt`).
- Reproducibility gap closed on LOCAL. Remaining Path A: (2) reconcile numbered
  migrations/001-048 vs the baseline; (3) apply the constitution to HOSTED (production).
