# ProteusOps CLI Supabase Execution Check — v1

## Status

GREEN

## Token

PROTEUSOPS_CLI_SUPABASE_EXECUTION_CHECK_OK

## Command

cli\proteus.ps1 check-supabase -Config .\proteus.config.json -Json

## Meaning

The CLI can now call the Supabase execution adapter readiness check.

## Safety Boundary

This command performs no destructive provider automation.

It checks:

- config file exists
- Supabase URL present
- Supabase key present
- migrations directory exists
- migrations count
- RPC client exists
- Supabase CLI availability

## Next Target

PROTEUSOPS_REAL_SUPABASE_CONFIG_READY_OK