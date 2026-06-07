# ProteusOps CLI Connect Provider Scaffold — v1

## Status

GREEN

## Token

PROTEUSOPS_CLI_CONNECT_PROVIDER_SCAFFOLD_OK

## Command

cli\proteus.ps1 connect -Provider supabase -Json

## Provider Pattern

Same connection model will apply to:

- Supabase
- Stripe
- GitHub
- Figma
- Email
- Storage

## Current Implemented Provider

Supabase

## Safety Boundary

- no destructive actions
- local config only
- secrets are not printed
- receipts are emitted locally
- missing values produce clean blocked state

## Next Target

PROTEUSOPS_CLI_CONNECT_SUPABASE_READY_OK