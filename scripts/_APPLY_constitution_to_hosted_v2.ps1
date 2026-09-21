$ErrorActionPreference = "Continue"
$RepoRoot = "C:\dev\proteusops"; Set-Location $RepoRoot
$ts = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmssZ")
$out = Join-Path $RepoRoot ("proofs\audit\apply_constitution_hosted_v2_" + $ts + ".txt")
function Log($m){ Add-Content -LiteralPath $out -Value $m }
Set-Content -LiteralPath $out -Value ("ProteusOps APPLY CONSTITUTION TO HOSTED v2  " + $ts)

Log "`n===== repair: mark stale remote-only baselines as reverted (metadata only; no schema change) ====="
supabase migration repair 20260721222534 20260721225911 --status reverted 2>&1 | ForEach-Object { Log $_ }

Log "`n===== migration list AFTER REVERT ====="
supabase migration list --linked 2>&1 | ForEach-Object { Log $_ }

Log "`n===== db push (applies ONLY the constitution 20260721231000) ====="
Log "(confirm the push when prompted; enter DB password if asked)"
supabase db push 2>&1 | ForEach-Object { Log $_ }

Log "`n===== migration list AFTER PUSH ====="
supabase migration list --linked 2>&1 | ForEach-Object { Log $_ }

Log "`n===== DONE ====="; Log "===APPLY_COMPLETE==="
Write-Host ("APPLY_OUTPUT=" + $out); Write-Host "===APPLY_COMPLETE==="
