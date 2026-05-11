param(
  [Parameter(Mandatory=$true)]
  [string]$RepoRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }

function Ensure-Dir([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ Die "ENSURE_DIR_EMPTY" }
  if(-not (Test-Path -LiteralPath $p -PathType Container)){
    New-Item -ItemType Directory -Force -Path $p | Out-Null
  }
}

function Normalize-Lf([string]$s){
  if($null -eq $s){ return "`n" }
  $t = $s.Replace("`r`n","`n").Replace("`r","`n")
  if(-not $t.EndsWith("`n")){ $t += "`n" }
  return $t
}

function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir){ Ensure-Dir $dir }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path,(Normalize-Lf $Text),$enc)
}

function Parse-GateFile([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Die ("MISSING_FILE: " + $Path) }
  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
  if($errors -and $errors.Count -gt 0){
    $e = $errors[0]
    Die ("PARSE_GATE_FAIL: " + $Path + " @ " + $e.Extent.StartLineNumber + ":" + $e.Extent.StartColumnNumber + " " + $e.Message)
  }
}

function Load-SecretEnv([string]$EnvName,[string]$SecretPath,[string]$MarkerName){
  $cur = [Environment]::GetEnvironmentVariable($EnvName,"Process")
  if(-not [string]::IsNullOrWhiteSpace($cur)){
    $v0 = $cur.Trim()
    Write-Host ($MarkerName + "=already_present len=" + $v0.Length)
    return $v0
  }

  if(-not (Test-Path -LiteralPath $SecretPath -PathType Leaf)){
    Die ("MISSING_SECRET_FILE: " + $SecretPath)
  }

  $enc = New-Object System.Text.UTF8Encoding($false)
  $raw = [System.IO.File]::ReadAllText($SecretPath,$enc)
  if($null -eq $raw){ Die ("SECRET_READ_NULL: " + $SecretPath) }

  $v = $raw.Trim()
  if([string]::IsNullOrWhiteSpace($v)){ Die ("SECRET_EMPTY: " + $SecretPath) }

  [Environment]::SetEnvironmentVariable($EnvName,$v,"Process")
  Write-Host ($MarkerName + "=loaded len=" + $v.Length)
  return $v
}

function Assert-JwtShape([string]$Name,[string]$Value){
  if([string]::IsNullOrWhiteSpace($Value)){ Die ($Name + "_EMPTY") }
  if($Value -notmatch '^[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+$'){
    Die ($Name + "_NOT_JWT")
  }
}

function Assert-UrlShape([string]$Name,[string]$Value){
  if([string]::IsNullOrWhiteSpace($Value)){ Die ($Name + "_EMPTY") }
  if($Value -notmatch '^https://'){
    Die ($Name + "_NOT_HTTPS_URL")
  }
}

function Invoke-HttpStatus([string]$Uri,[hashtable]$Headers){
  try{
    $resp = Invoke-WebRequest -UseBasicParsing -Method Get -Uri $Uri -Headers $Headers -TimeoutSec 20
    return [int]$resp.StatusCode
  } catch {
    if($_.Exception.Response -and $_.Exception.Response.StatusCode){
      return [int]$_.Exception.Response.StatusCode
    }
    throw
  }
}

function Run-NodeScript([string]$RepoRoot,[string]$ScriptPath,[int]$TimeoutSeconds){
  if([string]::IsNullOrWhiteSpace($RepoRoot)){ Die "REPOROOT_EMPTY" }
  if([string]::IsNullOrWhiteSpace($ScriptPath)){ Die "SCRIPT_PATH_EMPTY" }

  $node = (Get-Command node.exe -ErrorAction Stop).Source
  if(-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)){ Die ("MISSING_NODE_SCRIPT: " + $ScriptPath) }

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
  $p.StartInfo.FileName = $node
  $p.StartInfo.Arguments = ('"' + $ScriptPath + '"')
  $p.StartInfo.WorkingDirectory = $RepoRoot
  $p.StartInfo.UseShellExecute = $false
  $p.StartInfo.RedirectStandardOutput = $true
  $p.StartInfo.RedirectStandardError  = $true
  $p.StartInfo.CreateNoWindow = $true

  $null = $p.Start()
  $ok = $p.WaitForExit($TimeoutSeconds * 1000)
  if(-not $ok){
    try{ $p.Kill() } catch {}
    Die ("NODE_TIMEOUT: " + $ScriptPath + " seconds=" + $TimeoutSeconds)
  }

  $so = $p.StandardOutput.ReadToEnd()
  $se = $p.StandardError.ReadToEnd()

  if($p.ExitCode -ne 0){
    Die ("NODE_FAIL: " + $ScriptPath + " exit=" + $p.ExitCode + "`nSTDOUT:`n" + $so + "`nSTDERR:`n" + $se)
  }

  if(-not [string]::IsNullOrWhiteSpace($so)){ Write-Output $so.TrimEnd() }
  if(-not [string]::IsNullOrWhiteSpace($se)){ Write-Output $se.TrimEnd() }
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
Write-Output ("RESTORE_REPOROOT=" + $RepoRoot)

# --- filesystem sanity ---
$psFiles = @(
  (Join-Path $RepoRoot "scripts\selftest_all.ps1"),
  (Join-Path $RepoRoot "scripts\_RUN_proteusops_tier0_full_green_v7.ps1")
)
foreach($f in $psFiles){
  if(-not (Test-Path -LiteralPath $f -PathType Leaf)){ Die ("MISSING_FILE: " + $f) }
  Parse-GateFile $f
  Write-Output ("PARSE_OK: " + $f)
}

$otherFiles = @(
  (Join-Path $RepoRoot "selftest_booking.js"),
  (Join-Path $RepoRoot "selftest_booking_disabled.js"),
  (Join-Path $RepoRoot "migrations\022_selftest_add_org_member_v1.sql"),
  (Join-Path $RepoRoot "migrations\023_proteusops_schema_lanes_v1.sql"),
  (Join-Path $RepoRoot "package.json"),
  (Join-Path $RepoRoot "package-lock.json")
)
foreach($f in $otherFiles){
  if(-not (Test-Path -LiteralPath $f -PathType Leaf)){ Die ("MISSING_FILE: " + $f) }
  Write-Output ("FILE_OK: " + $f)
}

# --- secrets sanity ---
$secretDir = Join-Path $RepoRoot "proofs\secrets"
Ensure-Dir $secretDir

$serviceKey = Load-SecretEnv "SUPABASE_SERVICE_ROLE_KEY" (Join-Path $secretDir "SUPABASE_SERVICE_ROLE_KEY.txt") "ENV_SUPABASE_SERVICE_ROLE_KEY"
$anonKey    = Load-SecretEnv "SUPABASE_ANON_KEY"         (Join-Path $secretDir "SUPABASE_ANON_KEY.txt")         "ENV_SUPABASE_ANON_KEY"
$supabaseUrl= Load-SecretEnv "SUPABASE_URL"              (Join-Path $secretDir "SUPABASE_URL.txt")              "ENV_SUPABASE_URL"

Assert-JwtShape "SUPABASE_SERVICE_ROLE_KEY" $serviceKey
Assert-JwtShape "SUPABASE_ANON_KEY" $anonKey
Assert-UrlShape "SUPABASE_URL" $supabaseUrl

$testEmailPath    = Join-Path $secretDir "TEST_EMAIL.txt"
$testPasswordPath = Join-Path $secretDir "TEST_PASSWORD.txt"
$orgIdPath        = Join-Path $secretDir "ORG_ID.txt"

if(Test-Path -LiteralPath $testEmailPath -PathType Leaf){
  [void](Load-SecretEnv "TEST_EMAIL" $testEmailPath "ENV_TEST_EMAIL")
}
if(Test-Path -LiteralPath $testPasswordPath -PathType Leaf){
  [void](Load-SecretEnv "TEST_PASSWORD" $testPasswordPath "ENV_TEST_PASSWORD")
}
if(Test-Path -LiteralPath $orgIdPath -PathType Leaf){
  [void](Load-SecretEnv "ORG_ID" $orgIdPath "ENV_ORG_ID")
}

# --- remote API sanity ---
$restUrl = $supabaseUrl.TrimEnd("/") + "/rest/v1/"
$authUrl = $supabaseUrl.TrimEnd("/") + "/auth/v1/health"

$anonHeaders = @{
  apikey = $anonKey
  Authorization = ("Bearer " + $anonKey)
}
$svcHeaders = @{
  apikey = $serviceKey
  Authorization = ("Bearer " + $serviceKey)
}

$restAnonStatus = Invoke-HttpStatus -Uri $restUrl -Headers $anonHeaders
Write-Output ("REST_V1_ANON_STATUS=" + $restAnonStatus)
if($restAnonStatus -eq 401){ Write-Output "REST_V1_ANON_STATUS_401_ALLOWED_DEFER_TO_AUTH_SELFTEST" }

$restSvcStatus = Invoke-HttpStatus -Uri $restUrl -Headers $svcHeaders
Write-Output ("REST_V1_SERVICE_STATUS=" + $restSvcStatus)
if($restSvcStatus -eq 401){ Die "SUPABASE_SERVICE_ROLE_KEY_INVALID_FOR_URL" }

$authAnonStatus = Invoke-HttpStatus -Uri $authUrl -Headers $anonHeaders
Write-Output ("AUTH_V1_ANON_STATUS=" + $authAnonStatus)
if($authAnonStatus -eq 401){ Die "SUPABASE_AUTH_ANON_INVALID_FOR_URL" }

# --- selftest env sanity ---
$requiredEnv = @("SUPABASE_URL","SUPABASE_ANON_KEY","SUPABASE_SERVICE_ROLE_KEY","TEST_EMAIL","TEST_PASSWORD","ORG_ID")
foreach($k in $requiredEnv){
  $v = [Environment]::GetEnvironmentVariable($k,"Process")
  if([string]::IsNullOrWhiteSpace($v)){ Die ("MISSING_ENV_" + $k) }
  Write-Output ("ENV_OK_" + $k + "=1")
}

# --- operational sanity ---
$p1 = Join-Path $RepoRoot "selftest_booking.js"
Write-Output "RUN_NODE_SANITY_BOOKING"
Run-NodeScript -RepoRoot $RepoRoot -ScriptPath $p1 -TimeoutSeconds 120

Write-Output "PROTEUSOPS_RESTORE_SANE_OK"
