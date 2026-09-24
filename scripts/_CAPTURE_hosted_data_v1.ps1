# ProteusOps — capture hosted pods* DATA (not schema) into _local_private/ (git-ignored) so reference/catalog rows
# (templates, provider contracts, models, targets, policies...) can be turned into the local/CI seed.
# Nothing is committed by this script. The dump stays on this machine.
$ErrorActionPreference = "Continue"
Set-Location "C:\dev\proteusops"
New-Item -ItemType Directory -Force "_local_private" | Out-Null
$ts = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmssZ")
$f = "_local_private\hosted_pods_data_$ts.sql"
supabase db dump --linked --data-only --schema pods,pods_core,pods_provisioning,pods_public -f $f
Write-Host (">>> exit " + $LASTEXITCODE)
if (Test-Path $f) { Write-Host ("DATA_DUMP=" + $f + "  bytes=" + (Get-Item $f).Length) }
git check-ignore -q $f; if ($LASTEXITCODE -eq 0) { Write-Host "git: ignored (safe)" } else { Write-Host "!!! NOT IGNORED - do not commit" }
