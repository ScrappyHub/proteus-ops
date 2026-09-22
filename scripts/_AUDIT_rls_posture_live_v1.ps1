$ErrorActionPreference = "Continue"
$RepoRoot = "C:\dev\proteusops"; Set-Location $RepoRoot
$ts = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmssZ")
$out = Join-Path $RepoRoot ("proofs\audit\rls_posture_live_" + $ts + ".txt")
$C = "supabase_db_proteusops"
function Log($m){ Add-Content -LiteralPath $out -Value $m }
Set-Content -LiteralPath $out -Value ("ProteusOps RLS POSTURE (LIVE catalog) " + $ts)
$sql = @'
\pset pager off
with t as (
  select n.nspname as sch, c.relname as tbl, c.oid, c.relrowsecurity as rls,
    (select count(*) from pg_policies p where p.schemaname=n.nspname and p.tablename=c.relname) as pols,
    exists(select 1 from information_schema.role_table_grants g
           where g.table_schema=n.nspname and g.table_name=c.relname
             and g.grantee in ('anon','authenticated')
             and g.privilege_type in ('SELECT','INSERT','UPDATE','DELETE')) as client_grant
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where c.relkind='r' and n.nspname like 'pods%'
)
select
  case when not rls then 'NO_RLS'
       when rls and pols=0 then 'RLS_NO_POLICY'
       else 'RLS_WITH_POLICY' end as category,
  client_grant,
  count(*) as tables
from t group by 1,2 order by 1,2;
\echo :::REAL_RISK_no_rls_with_client_grant:::
select n.nspname||'.'||c.relname
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where c.relkind='r' and n.nspname like 'pods%' and not c.relrowsecurity
  and exists(select 1 from information_schema.role_table_grants g
             where g.table_schema=n.nspname and g.table_name=c.relname
               and g.grantee in ('anon','authenticated')
               and g.privilege_type in ('SELECT','INSERT','UPDATE','DELETE'))
order by 1;
\echo :::NO_RLS_all (defense-in-depth candidates):::
select n.nspname||'.'||c.relname
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where c.relkind='r' and n.nspname like 'pods%' and not c.relrowsecurity order by 1;
'@
$sql | docker exec -i $C psql -U postgres -d postgres -v ON_ERROR_STOP=0 -A -F " | " 2>&1 | ForEach-Object { Log $_ }
Log "`n===DONE==="; Write-Host ("RLS_OUTPUT=" + $out); Write-Host "===RLS_COMPLETE==="
