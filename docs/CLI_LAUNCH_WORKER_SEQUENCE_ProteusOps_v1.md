# ProteusOps CLI Launch Worker Sequence — v1

## Status

GREEN

## Token

PROTEUSOPS_CLI_LAUNCH_WORKER_SEQUENCE_OK

## Meaning

proteus launch now runs:

1. rpc_emit_customer_deployment_handoff_v1
2. rpc_emit_launch_control_plane_receipt_v1
3. rpc_queue_launch_execution_worker_v1

## Result

The CLI can now move from operator launch receipt to queued execution worker.

## Next Target

PROTEUSOPS_CLI_RECEIPTS_EXPORT_OK
