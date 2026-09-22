$ErrorActionPreference = "Continue"
$RepoRoot = "C:\dev\proteusops"; Set-Location $RepoRoot
$ts = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmssZ")
$out = Join-Path $RepoRoot ("proofs\audit\apply_slice45_hosted_" + $ts + ".txt")
function Log($m){ Add-Content -LiteralPath $out -Value $m }
Set-Content -LiteralPath $out -Value ("ProteusOps APPLY slices 4+5 TO HOSTED " + $ts)
Log "`n===== migration list BEFORE ====="
supabase migration list --linked 2>&1 | ForEach-Object { Log $_ }
Write-Host ""
Write-Host ">>> Pushing payment-idempotency + authority-binding migrations to HOSTED."
Write-Host ">>> Additive/idempotent. Answer 'y' at the prompt below. <<<"
Write-Host ""
supabase db push
Write-Host (">>> push exit code: " + $LASTEXITCODE + " <<<")
Log "`n===== migration list AFTER ====="
supabase migration list --linked 2>&1 | ForEach-Object { Log $_ }
Log "`n===DONE==="; Log "===APPLY_COMPLETE==="
Write-Host ("APPLY_OUTPUT=" + $out); Write-Host "===APPLY_COMPLETE==="
