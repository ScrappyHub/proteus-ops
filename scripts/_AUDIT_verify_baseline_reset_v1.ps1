$ErrorActionPreference = "Continue"
$RepoRoot = "C:\dev\proteusops"; Set-Location $RepoRoot
$ts = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmssZ")
$out = Join-Path $RepoRoot ("proofs\audit\baseline_reset_verify_" + $ts + ".txt")
$C = "supabase_db_proteusops"
function Log($m){ Add-Content -LiteralPath $out -Value $m }
Set-Content -LiteralPath $out -Value ("ProteusOps BASELINE RESET VERIFY  " + $ts)

Log "`n===== supabase db reset (LOCAL only; rebuilds from supabase/migrations) ====="
supabase db reset 2>&1 | ForEach-Object { Log $_ }

$sql = @'
\pset pager off
\echo :::OBJECT_COUNTS_BY_SCHEMA:::
select table_schema, count(*) from information_schema.tables where table_schema like 'pods%' group by 1 order by 1;
\echo :::FUNCTION_COUNT:::
select count(*) as pods_functions from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname like 'pods%';
\echo :::CONSTITUTION_TABLES_PRESENT:::
select to_regclass('pods_provisioning.platform_authority_registry_v1') as authreg, to_regclass('pods_provisioning.platform_constitution_versions_v1') as constver;
\echo :::CONSTITUTION_VERIFY_RPC:::
select pods_provisioning.rpc_verify_platform_constitution_v1();
'@
Log "`n===== LOCAL DB INTROSPECTION (post-reset) ====="
$sql | docker exec -i $C psql -U postgres -d postgres -v ON_ERROR_STOP=0 -A -F " | " 2>&1 | ForEach-Object { Log $_ }

Log "`n===== DONE ====="; Log "===VERIFY_COMPLETE==="
Write-Host ("VERIFY_OUTPUT=" + $out); Write-Host "===VERIFY_COMPLETE==="
