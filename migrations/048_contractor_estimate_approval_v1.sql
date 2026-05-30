begin;

-- Canonical proof:
-- PROTEUSOPS_CONTRACTOR_ESTIMATE_APPROVAL_OK

-- Proven:
-- contractor estimate approval decision
-- customer signer/contact capture
-- accepted decision status
-- decision hash
-- duplicate decision denial
-- job creation readiness
-- payment handoff readiness
-- estimate approval status transition

-- Proof result:
-- decision_kind=approve
-- decision_status=accepted
-- customer_email=approval.customer@example.com
-- deposit_required=true
-- deposit_amount_cents=325000
-- job_creation_ready=true
-- payment_handoff_ready=true
-- duplicate_denied=true

commit;
