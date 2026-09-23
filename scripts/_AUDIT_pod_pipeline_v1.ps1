# ProteusOps — full deployment-pod pipeline audit on a FRESH LOCAL database (never hosted).
$ErrorActionPreference = "Continue"
$RepoRoot = "C:\dev\proteusops"; Set-Location $RepoRoot
$ts = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmssZ")
$out = Join-Path $RepoRoot ("proofs\audit\pod_pipeline_audit_" + $ts + ".txt")
Set-Content -LiteralPath $out -Value ("ProteusOps POD PIPELINE AUDIT (LOCAL) " + $ts)
Write-Host ">>> local reset ..."
supabase db reset 2>&1 | ForEach-Object { Add-Content -LiteralPath $out -Value $_ }
Write-Host ">>> running every pods* selftest/verify function ..."
Get-Content -Raw -LiteralPath (Join-Path $RepoRoot "scripts\sql\pod_pipeline_audit_v1.sql") |
  docker exec -i supabase_db_proteusops psql -U postgres -d postgres -v ON_ERROR_STOP=0 2>&1 |
  ForEach-Object { Add-Content -LiteralPath $out -Value $_ }
$txt = Get-Content -Raw -LiteralPath $out
$i = $txt.IndexOf(":::POD_AUDIT_SUMMARY:::"); if ($i -ge 0) { Write-Host $txt.Substring($i, [Math]::Min(400, $txt.Length - $i)) }
Write-Host ("AUDIT_OUTPUT=" + $out); Write-Host "===POD_AUDIT_COMPLETE==="
