# SELFTEST — ProteusOps v0.1 (Storefront + Booking)

## Purpose (Tier-0 proof)

Prove (deterministically) that ProteusOps enforces:

- Billing entitlements in the database (no UI tricks)
- Feature gating in the database (booking_enabled + paid_active)
- Booking integrity in the database (availability / overlap / time-off with stable failure tokens)
- “No direct writes” posture for booking tables (RPC-only surfaces)

This selftest is a proof-run, not a product UX.

---

## Important Note (Supabase SQL Editor)

Supabase SQL Editor runs without an authenticated user context:

- auth.uid() is null
- auth.role() is typically not authenticated
- Any RPC that requires auth.uid() will raise AUTH_REQUIRED

Therefore the official Tier-0 selftest path for authenticated behavior is Node scripts, not SQL Editor.

---

## Canonical selftest entry points

A) Authenticated selftest (positive booking gates)
- node selftest_booking.js

B) Service-role selftest (plan flip → BOOKING_DISABLED → restore)
- node selftest_booking_disabled.js

C) One-command FULL_GREEN runner
- powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File scripts\selftest_all.ps1

---

## Preconditions

### Required environment variables (Process env)

- SUPABASE_URL
- SUPABASE_ANON_KEY
- TEST_EMAIL
- TEST_PASSWORD
- ORG_ID
- SUPABASE_SERVICE_ROLE_KEY (required only for selftest_booking_disabled.js / selftest_all.ps1)

### Required database surfaces

Public (PostgREST exposed) wrappers must exist:
- public.rpc_selftest_reset_booking_v1(uuid, uuid)
- public.rpc_upsert_availability_rule_v1(...)
- public.rpc_create_appointment_v1(...)
- public.rpc_add_time_off_block_v1(...)
- public.rpc_recompute_entitlements(uuid)
- public.rpc_selftest_set_subscription_plan_v1(uuid, text, text)  (service-role only)

Plans/capabilities must exist and recompute must materialize them into pods.org_entitlements.

---

## Expected tokens

selftest_booking.js (positive path):
- SELFTEST_RESET_OK
- AVAILABILITY_OK
- APPOINTMENT_CREATE_OK
- OVERLAP_TEST_EXPECTED_FAIL token=APPOINTMENT_OVERLAP
- TIMEOFF_OK
- TIMEOFF_TEST_EXPECTED_FAIL token=STAFF_TIME_OFF_BLOCK
- SELFTEST_DONE

selftest_booking_disabled.js (negative plan flip):
- PLAN_FLIP_OK plan_id=proteusops_s_v1 recompute=ok
- BOOKING_DISABLED_TEST_EXPECTED_FAIL token=BOOKING_DISABLED
- PLAN_RESTORE_OK plan_id=proteusops_sb_v1 recompute=ok
- SELFTEST_DONE

---

## Notes

- These tests intentionally prove DB enforcement (RLS + RPC gates + entitlement recompute).
- SQL Editor is not used for authenticated paths because auth.uid() is null there.
