begin;

-- Canonical proof:
-- PROTEUSOPS_APPOINTMENT_ADMIN_QUEUE_OK

-- Proven:
-- admin appointment queue
-- requested-status queue lookup
-- confirmed-status queue lookup
-- appointment status transitions
-- confirm workflow
-- deterministic admin action hashing
-- admin action receipts

-- Proof result:
-- queue_before_count=1
-- confirmed_queue_count=1
-- action_kind=confirm
-- previous_status=requested
-- new_status=confirmed
-- service_code=BARBER_CUT

commit;
