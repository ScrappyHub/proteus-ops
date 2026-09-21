$ErrorActionPreference = "Continue"
$RepoRoot = "C:\dev\proteusops"
Set-Location $RepoRoot
$ts  = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmssZ")
$out = Join-Path $RepoRoot ("proofs\audit\live_local_audit_" + $ts + ".txt")
$C   = "supabase_db_proteusops"

function Log([string]$m){ Add-Content -LiteralPath $out -Value $m }
function Sec([string]$m){ Add-Content -LiteralPath $out -Value ("`n===== " + $m + " =====") }

Set-Content -LiteralPath $out -Value ("ProteusOps LIVE LOCAL AUDIT  " + $ts)

Sec "TOOLCHAIN"
Log ("docker: "   + (try { (docker --version) 2>&1 } catch { "MISSING" }))
Log ("supabase: " + (try { (supabase --version) 2>&1 } catch { "MISSING" }))

Sec "DOCKER PS (proteus/supabase)"
Log ((docker ps -a --format "{{.Names}}`t{{.Status}}`t{{.Ports}}" 2>&1 | Select-String -Pattern "proteus|supabase") -join "`n")

Sec "SUPABASE STATUS (pre)"
Log ((supabase status 2>&1) -join "`n")

# Bring the stack up non-destructively if the db container is not running
$running = (docker ps --format "{{.Names}}" 2>&1 | Select-String -Pattern ([regex]::Escape($C)))
if (-not $running) {
  Sec "SUPABASE START (non-destructive; existing volume preserved)"
  Log ((supabase start 2>&1) -join "`n")
}

Sec "DOCKER PS (post)"
Log ((docker ps --format "{{.Names}}`t{{.Status}}" 2>&1 | Select-String -Pattern "proteus|supabase") -join "`n")

$sql = @'
\pset pager off
\echo :::LIVE_VERIFY_RPC:::
select pods_provisioning.rpc_verify_platform_constitution_v1();
\echo :::SCHEMAS:::
select nspname from pg_namespace where nspname like 'pods%' or nspname='public' order by 1;
\echo :::TABLE_COUNTS_BY_SCHEMA:::
select table_schema, count(*) from information_schema.tables where table_schema like 'pods%' or table_schema='public' group by 1 order by 1;
\echo :::FUNCTION_COUNTS_BY_SCHEMA:::
select n.nspname, count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname like 'pods%' or n.nspname='public' group by 1 order by 1;
\echo :::POLICY_COUNTS_BY_SCHEMA:::
select schemaname, count(*) from pg_policies where schemaname like 'pods%' or schemaname='public' group by 1 order by 1;
\echo :::AUTHORITY_REGISTRY:::
select authority_key, authority_status, canonical_order, proof_token from pods_provisioning.platform_authority_registry_v1 order by canonical_order;
\echo :::MIGRATION_LOCK:::
select migration_key, migration_status, required_token, left(verification_hash,16) as vhash16 from pods_provisioning.platform_migration_lock_v1;
\echo :::CONSTITUTION_ROW:::
select constitution_key, constitution_version, constitution_status, left(constitution_hash,16) as chash16 from pods_provisioning.platform_constitution_versions_v1;
\echo :::HISTORICAL_TABLE_PROBE:::
select
  to_regclass('pods.organizations')                         as pods_organizations,
  to_regclass('pods.appointments')                          as pods_appointments,
  to_regclass('pods.memberships')                           as pods_memberships,
  to_regclass('pods.subscriptions')                         as pods_subscriptions,
  to_regclass('pods_provisioning.platform_authority_registry_v1') as authority_registry;
\echo :::ALL_PODS_TABLES:::
select table_schema||'.'||table_name from information_schema.tables where table_schema like 'pods%' order by 1;
\echo :::SUPABASE_MIGRATION_HISTORY:::
select version, name from supabase_migrations.schema_migrations order by version;
'@

Sec "LIVE DB INTROSPECTION (docker exec psql)"
$dbrun = $running -or (docker ps --format "{{.Names}}" 2>&1 | Select-String -Pattern ([regex]::Escape($C)))
if ($dbrun) {
  $sql | docker exec -i $C psql -U postgres -d postgres -v ON_ERROR_STOP=0 -A -F " | " 2>&1 | ForEach-Object { Log $_ }
} else {
  Log "DB CONTAINER NOT RUNNING; introspection skipped"
}

Sec "HOSTED CONFIG (values redacted; booleans only)"
try {
  $cfg = Get-Content -Raw -Path (Join-Path $RepoRoot "proteus.config.json") | ConvertFrom-Json
  Log ("supabase_url set/non-placeholder: " + (($cfg.supabase_url) -and ($cfg.supabase_url -notmatch "YOUR_PROJECT")))
  Log ("supabase_url value: " + ($cfg.supabase_url))
  Log ("service_role_key present: " + [bool]($cfg.service_role_key))
  Log ("anon_key present: " + [bool]($cfg.anon_key))
} catch { Log ("config read error: " + $_.Exception.Message) }
Sec "SUPABASE LINK / PROJECTS"
Log ("linked project ref file: " + (Test-Path (Join-Path $RepoRoot "supabase\.temp\project-ref")))
Log ((supabase projects list 2>&1 | Select-Object -First 15) -join "`n")

Sec "DONE"
Log "===AUDIT_COMPLETE==="
Write-Host ("AUDIT_OUTPUT=" + $out)
Write-Host "===AUDIT_COMPLETE==="
