# migrations/ — SUPERSEDED (legacy)

As of 2026-09-21 (Path A, canonical baseline adoption) the reproduction path is the
Supabase CLI migration set in `supabase/migrations/`:

1. `20260721230000_hosted_baseline_v1.sql` — canonical hosted schema baseline
2. `20260721231000_platform_constitution_v1.sql` — governance layer

The numbered files `001-048` in `_legacy/` are the older, PowerShell-runner-applied set.
`001-031` are real DDL now subsumed by the baseline; `032-048` were proof-comment stubs
(no DDL). They are retained for history only and are NOT part of `supabase db reset`.
Old runner scripts under `scripts/` that reference `migrations\0NN_*.sql` are likewise
superseded and will not find these paths.
