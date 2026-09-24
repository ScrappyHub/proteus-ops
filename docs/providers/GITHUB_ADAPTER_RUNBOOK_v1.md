# GitHub adapter runbook v1 (Workspace Hub H3)

> **Where secrets go (no dashboard yet):** run `scripts/_SET_hub_secret_v1.ps1`. It prompts for the Supabase
> service key and the secret without echoing, sends them only to Supabase over TLS, stores the secret in Vault,
> and prints back an id + fingerprint. Never put a secret in git, in a file, in the SQL editor, or in chat.
> The `rpc_hub_*` names below are database functions (called by the future dashboard), not web links.
> The webhook URL is POST-only: opening it in a browser correctly answers "method not allowed".


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
1. Create a **fine-grained** GitHub token (github.com -> Settings -> Developer settings -> Personal access tokens ->
   Fine-grained tokens): resource owner = the org/user, repository access = all (or selected),
   permissions: Repository -> **Metadata: read-only** (nothing else). Expiry <= 90 days. Classic `ghp_` tokens are refused.
2. Store it (prompts; never echoed or written anywhere):
   `powershell -ExecutionPolicy Bypass -File .\scripts\_SET_hub_secret_v1.ps1 -Workspace <slug> -Provider github -AccountName "<name>" -ExternalRef <org/user> -Purpose api -Environment test -RotateInDays 90 -Justification "Read-only GitHub token for repository inventory"`
3. Sync runs automatically every 30 minutes once the scheduler is set up (one-time, no secret involved, SQL editor):
   `select pods_provisioning.svc_hub_sync_setup_v1('https://ytwjyemqlbbebysiopzd.functions.supabase.co', true);`
   The database generates a 256-bit machine key, keeps it only in Vault, and pg_cron + pg_net call `github-sync`
   with it (`x-proteus-sync-key`). No person handles that key. Rotate any time by re-running the setup.
   Run once now: `select pods_provisioning._hub_sync_dispatch_v1('github');`  then check (a few seconds later):
   `select pods_provisioning.svc_hub_sync_status_v1();`
   Repos are upserted into the inventory; repos no longer returned are marked **missing** (a `resource.missing`
   event appears in the feed). 200 -> credential valid; 401/403 -> credential **invalid** (critical if live).

## 4. What shows up in the feed
push / force-push (warning) / branch deleted, PR opened/merged/closed, releases, deploy success/failure,
failed CI runs, repository created/deleted/renamed/publicized (critical), branch-protection changes,
secret-scanning (critical) / code-scanning / Dependabot alerts, membership/team changes; plus ProteusOps'
own stage changes, credential added/rotated/revoked/invalid, and resources going missing.
