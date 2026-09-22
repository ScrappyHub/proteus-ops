$ErrorActionPreference = "Continue"
$RepoRoot = "C:\dev\proteusops"; Set-Location $RepoRoot
$ts = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmssZ")
$out = Join-Path $RepoRoot ("proofs\audit\verify_rls_" + $ts + ".txt")
$C = "supabase_db_proteusops"
function Log($m){ Add-Content -LiteralPath $out -Value $m }
Set-Content -LiteralPath $out -Value ("ProteusOps VERIFY RLS FAIL-CLOSED (LOCAL) " + $ts)
Log "`n===== supabase db reset (applies baseline + constitution + hardening + rls) ====="
supabase db reset 2>&1 | ForEach-Object { Log $_ }
$sql = @'
\pset pager off
\echo :::RLS_FAIL_CLOSED_SELFTEST:::
select pods_core.rpc_selftest_rls_fail_closed_v1();
\echo :::REMAINING_NO_RLS (expect 0):::
select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind='r' and n.nspname like 'pods%' and not c.relrowsecurity;
\echo :::CONSTITUTION_OK:::
select pods_provisioning.rpc_verify_platform_constitution_v1()->>'ok' as ok;
'@
Log "`n===== POST-RESET CHECKS ====="
$sql | docker exec -i $C psql -U postgres -d postgres -v ON_ERROR_STOP=0 -A -F " | " 2>&1 | ForEach-Object { Log $_ }
Log "`n===DONE==="; Log "===VERIFY_COMPLETE==="
Write-Host ("VERIFY_OUTPUT=" + $out); Write-Host "===VERIFY_COMPLETE==="
