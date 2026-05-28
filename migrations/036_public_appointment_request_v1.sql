begin;

-- Canonical proof:
-- PROTEUSOPS_PUBLIC_APPOINTMENT_REQUEST_OK

-- Proven:
-- public appointment request capture
-- booking slug lookup
-- service duration calculation
-- customer-facing confirmation payload
-- deterministic request hash
-- duplicate appointment request denial

-- Proof result:
-- booking_path=/book/appt-test-4f5d912f
-- service_code=BARBER_CUT
-- requested_date=2026-05-29
-- requested_start_time=09:00
-- requested_end_time=09:45
-- duplicate_denied=true
-- request_hash=ba0ffd5c51bf4c775dd9ca9602328dca83975c4ee9d79301c750e85b874d61a4

commit;
