begin;

-- Canonical proof:
-- PROTEUSOPS_PAYMENT_LIFECYCLE_OK

-- Proven:
-- payment policy seed
-- deposit-required policy
-- adapter-pending provider abstraction
-- payment intent creation
-- pending payment lifecycle state
-- payment event receipt creation
-- duplicate payment intent denial

-- Proof result:
-- template_key=BARBER_NAIL_V1
-- policy_key=default-deposit
-- deposit_required=true
-- deposit_amount_cents=1000
-- currency=usd
-- payment_status=pending
-- provider_key=adapter_pending
-- duplicate_denied=true

commit;
