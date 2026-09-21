$ErrorActionPreference = "Continue"
$RepoRoot = "C:\dev\proteusops"
Set-Location $RepoRoot
$ref = "ytwjyemqlbbebysiopzd"
$ts  = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmssZ")
$dir = Join-Path $RepoRoot "proofs\audit"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$log  = Join-Path $dir ("hosted_audit_" + $ts + ".txt")
$dump = Join-Path $dir ("hosted_schema_" + $ts + ".sql")

function Log([string]$m){ Add-Content -LiteralPath $log -Value $m }
Set-Content -LiteralPath $log -Value ("ProteusOps HOSTED AUDIT  " + $ts + "  ref=" + $ref)

Log "`n===== LINK (you will be prompted for the hosted DB password) ====="
supabase link --project-ref $ref 2>&1 | ForEach-Object { Log $_ }

Log "`n===== REMOTE MIGRATION HISTORY (supabase migration list) ====="
supabase migration list --linked 2>&1 | ForEach-Object { Log $_ }

Log "`n===== SCHEMA-ONLY DUMP (no data) ====="
supabase db dump --linked --schema public,pods,pods_core,pods_billing,pods_ops,pods_provisioning,pods_public -f $dump 2>&1 | ForEach-Object { Log $_ }
if (Test-Path $dump) {
  Log ("dump_bytes=" + (Get-Item $dump).Length)
} else {
  Log "DUMP NOT PRODUCED (password blank/incorrect, or connection blocked)"
}

Log "`n===== DONE ====="
Log "===AUDIT_COMPLETE==="
Write-Host ("HOSTED_LOG=" + $log)
Write-Host ("HOSTED_DUMP=" + $dump)
Write-Host "===AUDIT_COMPLETE==="
