# ProteusOps CLI Launch Sequence — v1

## Status

GREEN

## Token

PROTEUSOPS_CLI_LAUNCH_SEQUENCE_OK

## Command

proteus launch

## Required Arguments

- OrgId
- WizardSessionId
- PlanRunId
- DeploymentReceiptId
- ProviderReadinessRollupId

## RPCs

- rpc_emit_customer_deployment_handoff_v1
- rpc_emit_launch_control_plane_receipt_v1

## Next Target

PROTEUSOPS_CLI_LAUNCH_WORKER_SEQUENCE_OK