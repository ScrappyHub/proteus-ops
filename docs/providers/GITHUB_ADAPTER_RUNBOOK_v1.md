# GitHub adapter runbook v1 (Workspace Hub H3)

Two edge functions, one database contract. Nothing about GitHub is stored in git; all secrets are hub
credentials held in Supabase Vault and read only by these functions (every read is audited).

## 1. Register the GitHub account in the hub (once per GitHub org/user)
`rpc_hub_account_upsert_v1(org_id, null, 'github', '<display name>', '<github org or username>', 'shared', <owner_user_id>, '')`
→ returns `account_id`. `external_ref` = the GitHub org (or username) whose repos to inventory.

## 2. Webhook (change feed)
1. Generate a random secret (e.g. `openssl rand -hex 32`). Do not paste it anywhere except the two places below.
2. Store it (owner/admin, MFA session):
   `rpc_hub_credential_put_v1(account_id, null, 'webhook', 'test'|'live', '[]', 'vault', '<secret>', null, <rotates_at>, '<justification>')`
   (account environment `shared` accepts either; live needs a rotation date.)
3. GitHub → Org (or repo) Settings → Webhooks → Add webhook:
   - Payload URL: `https://ytwjyemqlbbebysiopzd.functions.supabase.co/github-webhook?account=<account_id>`
   - Content type: `application/json`; Secret: the same secret; SSL verification on.
   - Events: push, pull_request, release, deployment_status, workflow_run, repository, branch_protection_rule,
     secret_scanning_alert, code_scanning_alert, dependabot_alert, member, organization, team.
4. GitHub sends `ping` → the function verifies the HMAC and marks the webhook credential **valid**.
Unknown account, missing credential and bad signature all return the same 401 (no oracle).
Deliveries are idempotent on `X-GitHub-Delivery`. Payloads that look like they contain secrets are rejected and audited.

## 3. Discovery sync (resource inventory + API credential verification)
1. Create a **fine-grained** GitHub token: resource owner = the org/user, repository access = all (or selected),
   permissions: Metadata **read-only** (nothing else needed). Expiry ≤ 90 days.
2. Store it: `rpc_hub_credential_put_v1(account_id, null, 'api', ..., 'vault', '<token>', null, <rotates_at = token expiry>, '<justification>')`.
3. Invoke (service role only): `POST https://ytwjyemqlbbebysiopzd.functions.supabase.co/github-sync` with
   `Authorization: Bearer <service_role key>` (body `{}` or `{"account_id":"..."}`).
   Repos are upserted into the inventory; repos no longer returned are marked **missing** (a `resource.missing`
   event appears in the feed). 200 → credential valid; 401/403 → credential **invalid** (critical if live).

## 4. What shows up in the feed
push / force-push (warning) / branch deleted, PR opened/merged/closed, releases, deploy success/failure,
failed CI runs, repository created/deleted/renamed/publicized (critical), branch-protection changes,
secret-scanning (critical) / code-scanning / Dependabot alerts, membership/team changes; plus ProteusOps'
own stage changes, credential added/rotated/revoked/invalid, and resources going missing.
