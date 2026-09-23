$ErrorActionPreference = "Continue"
$RepoRoot = "C:\dev\proteusops"; Set-Location $RepoRoot
$ts = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmssZ")
$out = Join-Path $RepoRoot ("proofs\audit\verify_slice8_security_" + $ts + ".txt")
$C = "supabase_db_proteusops"
function Log($m){ Add-Content -LiteralPath $out -Value $m }
Set-Content -LiteralPath $out -Value ("ProteusOps VERIFY slice 8 security S1+S2 (LOCAL) " + $ts)
supabase db reset 2>&1 | ForEach-Object { Log $_ }
$sql = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\sql\selftests_all_v1.sql")
Log "`n===== POST-RESET CHECKS ====="
$sql | docker exec -i $C psql -U postgres -d postgres -v ON_ERROR_STOP=0 -A -F " | " 2>&1 | ForEach-Object { Log $_ }
$txt = Get-Content -Raw -LiteralPath $out
$fails = ([regex]::Matches($txt, 'PROTEUSOPS_[A-Z_]+_FAIL')).Count + ([regex]::Matches($txt, 'ERROR:')).Count
Log "`n===DONE=== fail_or_error_count=$fails"
Write-Host ("VERIFY_OUTPUT=" + $out); Write-Host ("FAIL_OR_ERROR_COUNT=" + $fails); Write-Host "===VERIFY_COMPLETE==="
