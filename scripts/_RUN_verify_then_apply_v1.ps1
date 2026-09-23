# ProteusOps — verify locally, then (only if every selftest is green) push pending migrations to HOSTED.
# Usage: powershell -ExecutionPolicy Bypass -File .\scripts\_RUN_verify_then_apply_v1.ps1
$ErrorActionPreference = "Continue"
$RepoRoot = "C:\dev\proteusops"; Set-Location $RepoRoot
$ts = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmssZ")
$out = Join-Path $RepoRoot ("proofs\audit\verify_apply_" + $ts + ".txt")
$C = "supabase_db_proteusops"
function Log($m){ Add-Content -LiteralPath $out -Value $m }
Set-Content -LiteralPath $out -Value ("ProteusOps VERIFY+APPLY " + $ts)
Write-Host ">>> [1/2] local reset + all selftests ..."
supabase db reset 2>&1 | ForEach-Object { Log $_ }
$sql = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\sql\selftests_all_v1.sql")
Log "`n===== POST-RESET CHECKS ====="
$sql | docker exec -i $C psql -U postgres -d postgres -v ON_ERROR_STOP=0 -A -F " | " 2>&1 | ForEach-Object { Log $_ }
$txt = Get-Content -Raw -LiteralPath $out
$fails = ([regex]::Matches($txt, 'PROTEUSOPS_[A-Z_]+_FAIL(?![A-Z_])')).Count + ([regex]::Matches($txt, '(?m)^(psql:.*)?ERROR:')).Count
$oks = ([regex]::Matches($txt, '(?m)^PROTEUSOPS_[A-Z_]+_OK\s*$')).Count
Log "`nfail_or_error_count=$fails ok_tokens=$oks"
Write-Host ("VERIFY_OUTPUT=" + $out); Write-Host ("FAIL_OR_ERROR_COUNT=" + $fails + "  OK_TOKENS=" + $oks)
if ($fails -ne 0 -or $oks -lt 19) { Write-Host "!!! NOT APPLYING: local verification is not fully green. Send the VERIFY_OUTPUT file."; exit 1 }
Write-Host ">>> [2/2] all green. Pushing pending migrations to HOSTED. Answer 'y' at the prompt."
supabase db push
Log "`npush exit code: $LASTEXITCODE"
Write-Host (">>> push exit code: " + $LASTEXITCODE)
Write-Host "===VERIFY_APPLY_COMPLETE==="
