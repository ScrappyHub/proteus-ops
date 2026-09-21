$ErrorActionPreference = "Continue"
$RepoRoot = "C:\dev\proteusops"; Set-Location $RepoRoot
$ts = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmssZ")
$out = Join-Path $RepoRoot ("proofs\audit\apply_constitution_hosted_" + $ts + ".txt")
function Log($m){ Add-Content -LiteralPath $out -Value $m }
Set-Content -LiteralPath $out -Value ("ProteusOps APPLY CONSTITUTION TO HOSTED  " + $ts)

Log "`n===== migration list BEFORE ====="
supabase migration list --linked 2>&1 | ForEach-Object { Log $_ }

Log "`n===== repair: mark baseline 20260721230000 as already applied on remote ====="
supabase migration repair 20260721230000 --status applied 2>&1 | ForEach-Object { Log $_ }

Log "`n===== db push (applies ONLY the constitution 20260721231000) ====="
Log "(you will be asked to confirm the push, and for the DB password if prompted)"
supabase db push 2>&1 | ForEach-Object { Log $_ }

Log "`n===== migration list AFTER ====="
supabase migration list --linked 2>&1 | ForEach-Object { Log $_ }

Log "`n===== DONE ====="; Log "===APPLY_COMPLETE==="
Write-Host ("APPLY_OUTPUT=" + $out); Write-Host "===APPLY_COMPLETE==="
