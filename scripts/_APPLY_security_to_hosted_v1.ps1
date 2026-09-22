$ErrorActionPreference = "Continue"
$RepoRoot = "C:\dev\proteusops"; Set-Location $RepoRoot
$ts = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmssZ")
$out = Join-Path $RepoRoot ("proofs\audit\apply_security_hosted_" + $ts + ".txt")
function Log($m){ Add-Content -LiteralPath $out -Value $m }
Set-Content -LiteralPath $out -Value ("ProteusOps APPLY SECURITY BATCH TO HOSTED " + $ts)
Log "`n===== migration list BEFORE ====="
supabase migration list --linked 2>&1 | ForEach-Object { Log $_ }
Write-Host ""
Write-Host ">>> Pushing the 3 security migrations (search_path, RLS, session-assurance) to HOSTED."
Write-Host ">>> These are additive/idempotent. Answer 'y' at the prompt below. <<<"
Write-Host ""
supabase db push
Write-Host ""
Write-Host (">>> push exit code: " + $LASTEXITCODE + " <<<")
Log "`n===== migration list AFTER ====="
supabase migration list --linked 2>&1 | ForEach-Object { Log $_ }
Log "`n===DONE==="; Log "===APPLY_COMPLETE==="
Write-Host ("APPLY_OUTPUT=" + $out); Write-Host "===APPLY_COMPLETE==="
