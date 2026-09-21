$ErrorActionPreference = "Continue"
$RepoRoot = "C:\dev\proteusops"; Set-Location $RepoRoot
$ts = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmssZ")
$out = Join-Path $RepoRoot ("proofs\audit\apply_constitution_hosted_v3_" + $ts + ".txt")
function Log($m){ Add-Content -LiteralPath $out -Value $m }
Set-Content -LiteralPath $out -Value ("ProteusOps APPLY CONSTITUTION TO HOSTED v3  " + $ts)

# Idempotent: ensure stale baselines are reverted (safe if already reverted)
supabase migration repair 20260721222534 20260721225911 --status reverted 2>&1 | ForEach-Object { Log $_ }

Log "`n===== migration list BEFORE PUSH ====="
supabase migration list --linked 2>&1 | ForEach-Object { Log $_ }

# Push runs INTERACTIVELY (prompt visible in your terminal). Answer y when asked.
Write-Host ""
Write-Host ">>> About to push the constitution to HOSTED. Answer 'y' at the prompt below. <<<"
Write-Host ""
supabase db push
Write-Host ""
Write-Host ">>> push exit code: $LASTEXITCODE <<<"

Log "`n===== migration list AFTER PUSH ====="
supabase migration list --linked 2>&1 | ForEach-Object { Log $_ }
Log "`n===== DONE ====="; Log "===APPLY_COMPLETE==="
Write-Host ("APPLY_OUTPUT=" + $out); Write-Host "===APPLY_COMPLETE==="
