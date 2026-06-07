# ProteusOps CLI Connect Supabase Interactive — v1

## Status

GREEN

## Token

PROTEUSOPS_CLI_CONNECT_SUPABASE_INTERACTIVE_OK

## Command

cli\proteus.ps1 connect -Provider supabase

## Behavior

- prompts for Supabase project URL
- prompts for key using SecureString
- writes proteus.config.json locally
- does not print secrets
- reruns Supabase execution readiness check
- emits CLI receipt

## JSON Mode

In JSON mode, it does not prompt. It reports blocked state until local config is filled.

## Safety

- no destructive actions
- local config only
- secret_printed=false
- proteus.config.json must remain ignored

## Next Target

PROTEUSOPS_CLI_CONNECT_SUPABASE_READY_OK