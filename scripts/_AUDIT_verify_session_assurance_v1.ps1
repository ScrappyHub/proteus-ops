$ErrorActionPreference = "Continue"
$RepoRoot = "C:\dev\proteusops"; Set-Location $RepoRoot
$ts = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmssZ")
$out = Join-Path $RepoRoot ("proofs\audit\verify_session_assurance_" + $ts + ".txt")
$C = "supabase_db_proteusops"
function Log($m){ Add-Content -LiteralPath $out -Value $m }
Set-Content -LiteralPath $out -Value ("ProteusOps VERIFY SESSION ASSURANCE (LOCAL) " + $ts)
Log "`n===== supabase db reset (baseline+constitution+hardening+rls+session_assurance) ====="
supabase db reset 2>&1 | ForEach-Object { Log $_ }
$sql = @'
\pset pager off
\echo :::SESSION_ASSURANCE_SELFTEST:::
select pods_core.rpc_selftest_session_assurance_v1();
\echo :::RLS_SELFTEST:::
select pods_core.rpc_selftest_rls_fail_closed_v1()->>'token' as rls_token;
\echo :::CONSTITUTION_OK:::
select pods_provisioning.rpc_verify_platform_constitution_v1()->>'ok' as ok;
'@
Log "`n===== POST-RESET CHECKS ====="
$sql | docker exec -i $C psql -U postgres -d postgres -v ON_ERROR_STOP=0 -A -F " | " 2>&1 | ForEach-Object { Log $_ }
Log "`n===DONE==="; Log "===VERIFY_COMPLETE==="
Write-Host ("VERIFY_OUTPUT=" + $out); Write-Host "===VERIFY_COMPLETE==="
