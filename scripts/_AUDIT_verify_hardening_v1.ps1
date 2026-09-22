$ErrorActionPreference = "Continue"
$RepoRoot = "C:\dev\proteusops"; Set-Location $RepoRoot
$ts = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmssZ")
$out = Join-Path $RepoRoot ("proofs\audit\verify_hardening_" + $ts + ".txt")
$C = "supabase_db_proteusops"
function Log($m){ Add-Content -LiteralPath $out -Value $m }
Set-Content -LiteralPath $out -Value ("ProteusOps VERIFY HARDENING (LOCAL) " + $ts)
Log "`n===== supabase db reset (LOCAL; applies baseline + constitution + hardening) ====="
supabase db reset 2>&1 | ForEach-Object { Log $_ }
$sql = @'
\pset pager off
\echo :::SECDEF_WITHOUT_SEARCH_PATH (expect 0):::
select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname like 'pods%' and p.prosecdef
and not exists (select 1 from unnest(coalesce(p.proconfig,'{}'::text[])) c where c like 'search_path=%');
\echo :::SECDEF_TOTAL:::
select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname like 'pods%' and p.prosecdef;
\echo :::CONSTITUTION_VERIFY (expect ok true):::
select pods_provisioning.rpc_verify_platform_constitution_v1()->>'ok' as ok;
'@
Log "`n===== POST-RESET CHECKS ====="
$sql | docker exec -i $C psql -U postgres -d postgres -v ON_ERROR_STOP=0 -A -F " | " 2>&1 | ForEach-Object { Log $_ }
Log "`n===== DONE ====="; Log "===VERIFY_COMPLETE==="
Write-Host ("VERIFY_OUTPUT=" + $out); Write-Host "===VERIFY_COMPLETE==="
