$ErrorActionPreference = "Continue"
$RepoRoot = "C:\dev\proteusops"; Set-Location $RepoRoot
$ts = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmssZ")
$out = Join-Path $RepoRoot ("proofs\audit\verify_slice6_" + $ts + ".txt")
$C = "supabase_db_proteusops"
function Log($m){ Add-Content -LiteralPath $out -Value $m }
Set-Content -LiteralPath $out -Value ("ProteusOps VERIFY slice 6 (LOCAL) " + $ts)
supabase db reset 2>&1 | ForEach-Object { Log $_ }
$sql = @'
\pset pager off
\echo :::ONE_TIME_ENTITLEMENT:::
select pods_provisioning.rpc_selftest_one_time_entitlement_v1();
\echo :::PAYMENT_IDEMPOTENCY:::
select pods_provisioning.rpc_selftest_payment_idempotency_v1()->>'token' as pay;
\echo :::REGRESSION:::
select pods_core.rpc_selftest_rls_fail_closed_v1()->>'token' as rls, pods_core.rpc_selftest_session_assurance_v1()->>'token' as sess, pods_provisioning.rpc_verify_authority_bindings_v1()->>'token' as bind, pods_provisioning.rpc_verify_platform_constitution_v1()->>'ok' as constitution_ok;
'@
Log "`n===== POST-RESET CHECKS ====="
$sql | docker exec -i $C psql -U postgres -d postgres -v ON_ERROR_STOP=0 -A -F " | " 2>&1 | ForEach-Object { Log $_ }
Log "`n===DONE==="; Log "===VERIFY_COMPLETE==="
Write-Host ("VERIFY_OUTPUT=" + $out); Write-Host "===VERIFY_COMPLETE==="
