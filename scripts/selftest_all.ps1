$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }

function NeedEnv([string]$k){
  $v=[Environment]::GetEnvironmentVariable($k,"Process")
  if([string]::IsNullOrWhiteSpace($v)){ Die ("MISSING_ENV_" + $k) }
  return $v.Trim()
}

$RepoRoot = (Resolve-Path -LiteralPath ".").Path
$node = (Get-Command node.exe -ErrorAction Stop).Source
$url = (NeedEnv "SUPABASE_URL").TrimEnd("/")
$anon = NeedEnv "SUPABASE_ANON_KEY"
$svc  = NeedEnv "SUPABASE_SERVICE_ROLE_KEY"
[void](NeedEnv "TEST_EMAIL")
[void](NeedEnv "TEST_PASSWORD")
[void](NeedEnv "ORG_ID")

if($anon -notmatch '^[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+$'){ Die "SUPABASE_ANON_KEY_NOT_JWT" }
if($svc  -notmatch '^[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+$'){ Die "SUPABASE_SERVICE_ROLE_KEY_NOT_JWT" }

function PreflightKey([string]$name,[string]$key){
  try{
    $h = @{ apikey=$key; Authorization=("Bearer " + $key) }
    $r = Invoke-WebRequest -UseBasicParsing -Method Get -Uri ($url + "/rest/v1/") -Headers $h -TimeoutSec 15
    if($r.StatusCode -eq 401){ Die ($name + "_INVALID_FOR_URL") }
  }catch{
    $m = $_.Exception.Message
    if($m -match '401'){ Die ($name + "_INVALID_FOR_URL") }
  }
}

PreflightKey "SUPABASE_ANON_KEY" $anon
PreflightKey "SUPABASE_SERVICE_ROLE_KEY" $svc

function RunNode([string]$rel){
  $p = Join-Path $RepoRoot $rel
  if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ Die ("MISSING_FILE: " + $p) }
  Write-Host ("RUN: node " + $rel) -ForegroundColor Cyan
  & $node $p | Out-Host
  if($LASTEXITCODE -ne 0){ Die ("NODE_FAIL: " + $rel + " exit=" + $LASTEXITCODE) }
}

RunNode "selftest_booking.js"
RunNode "selftest_booking_disabled.js"
Write-Host "FULL_GREEN_SELFTEST_OK" -ForegroundColor Green
