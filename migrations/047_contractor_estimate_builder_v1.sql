begin;

-- Canonical proof:
-- PROTEUSOPS_CONTRACTOR_ESTIMATE_BUILDER_OK

-- Proven:
-- contractor estimate builder
-- completed site visit requirement
-- labor/material line items
-- subtotal calculation
-- deposit calculation
-- customer-facing estimate payload
-- approval readiness
-- decline readiness
-- estimate evidence references
-- duplicate estimate denial

-- Proof result:
-- template_key=CONTRACTOR_V1
-- service_code=ROOF_REPLACEMENT
-- labor_cents=450000
-- material_cents=650000
-- subtotal_cents=1100000
-- total_cents=1100000
-- deposit_percent=20
-- deposit_amount_cents=220000
-- line_item_count=2
-- estimate_status=sent
-- approval_ready=true
-- decline_ready=true
-- duplicate_denied=true

commit;
