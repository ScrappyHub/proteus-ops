# Hosted findings — Proteus Ops (ytwjyemqlbbebysiopzd) — 2026-09-21

Method: live introspection via Supabase dashboard SQL editor (project resumed from paused).

## Counts
- pods* tables + views: 186  (pods=30, pods_core=11, pods_ops=3, pods_provisioning=138, pods_public=4)
- pods* functions: 247
- Supabase migration history: 2 rows, both `remote_schema` (20260721222534, 20260721225911)

## Constitution presence on hosted
- to_regclass('pods_provisioning.platform_authority_registry_v1')     = NULL  (ABSENT)
- to_regclass('pods_provisioning.platform_constitution_versions_v1')  = NULL  (ABSENT)

## Implication
Hosted holds the real, most-advanced application implementation (orgs/members/entitlements/
billing, storefront, booking, contractor vertical, civic_action vertical, model registry/
marketplace/runtime/launch/snapshot/audit/release/drift, domain_provider_connections,
payment + provider + stripe/supabase/github/email/storage adapter runtimes) — but WITHOUT the
constitution/governance layer, and NOT reproducible from the repo's numbered migrations
(only two remote_schema baselines track ~186 objects + 247 functions).

Reproduce: dashboard SQL editor, query on information_schema.tables / pg_proc filtered to
schema like 'pods%'; or `supabase link --project-ref ytwjyemqlbbebysiopzd` then
`supabase db dump --linked` for a versioned schema capture.
