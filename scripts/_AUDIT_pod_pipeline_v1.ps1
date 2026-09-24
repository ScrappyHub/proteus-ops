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
$i = $txt.IndexOf(":::POD_AUDIT_SUMMARY:::"); $j = $txt.IndexOf(":::POD_AUDIT_PASS:::")
if ($i -ge 0) { if ($j -gt $i) { Write-Host $txt.Substring($i, $j - $i) } else { Write-Host $txt.Substring($i) } }
$g = [regex]::Match($txt, "POD_AUDIT_TOTAL=\d+ POD_AUDIT_NON_PASS_COUNT=\d+"); if ($g.Success) { Write-Host $g.Value }
Write-Host ("AUDIT_OUTPUT=" + $out); Write-Host "===POD_AUDIT_COMPLETE==="
