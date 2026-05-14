param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }

function Parse-GateFile([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Die ("MISSING_FILE: " + $Path) }
  $tokens=$null
  $errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
  if($errors -and $errors.Count -gt 0){
    $e=$errors[0]
    Die ("PARSE_GATE_FAIL: " + $Path + " @ " + $e.Extent.StartLineNumber + ":" + $e.Extent.StartColumnNumber + " " + $e.Message)
  }
}

function Read-SecretTrimmed([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Die ("MISSING_SECRET_FILE: " + $Path) }
  $enc = New-Object System.Text.UTF8Encoding($false)
  $v = ([System.IO.File]::ReadAllText($Path,$enc)).Trim()
  if([string]::IsNullOrWhiteSpace($v)){ Die ("SECRET_EMPTY: " + $Path) }
  return $v
}

function Assert-JwtShape([string]$Name,[string]$Value){
  if([string]::IsNullOrWhiteSpace($Value)){ Die ($Name + "_EMPTY") }
  if($Value -notmatch '^[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+$'){
    Die ($Name + "_NOT_JWT")
  }
}

function Decode-JwtPayload([string]$Jwt){
  Assert-JwtShape "JWT" $Jwt
  $p = $Jwt.Split('.')[1].Replace('-','+').Replace('_','/')
  while(($p.Length % 4) -ne 0){ $p += '=' }
  $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p))
  return ($json | ConvertFrom-Json)
}

function Assert-Tool([string]$Name){
  $cmd = Get-Command $Name -ErrorAction SilentlyContinue
  if(-not $cmd){ Die ("MISSING_TOOL: " + $Name) }
  Write-Output ("TOOL_OK: " + $Name)
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
Write-Output ("BOOTSTRAP_REPOROOT=" + $RepoRoot)

# Required tools
Assert-Tool "git.exe"
Assert-Tool "node.exe"
Assert-Tool "powershell.exe"
Assert-Tool "psql.exe"

# Git remote
$origin = ""
try{
  $origin = (& git -C $RepoRoot remote get-url origin 2>$null).Trim()
} catch {
  $origin = ""
}
if([string]::IsNullOrWhiteSpace($origin)){ Die "GIT_ORIGIN_MISSING" }
Write-Output ("GIT_ORIGIN_OK: " + $origin)

# Required files
$requiredFiles = @(
  "README.md",
  "docs\TIER1_WITNESS_ProteusOps_v1.md",
  "docs\TIER1_PUBLIC_SURFACE_HARDENING_ProteusOps_v1.md",
  "docs\TIER1_BOUNDARY_SELFTESTS_ProteusOps_v1.md",
  "migrations\024_proteusops_tier1_lane_contracts_v1.sql",
  "migrations\025_proteusops_tier1_negative_boundaries_v1.sql",
  "migrations\026_proteusops_tier1_boundary_selftests_v1.sql",
  "migrations\027_proteusops_tier1_public_surface_hardening_v1.sql",
  "scripts\_RUN_proteusops_restore_sane_v1.ps1",
  "scripts\_RUN_proteusops_tier0_full_green_v7.ps1",
  "scripts\028_proteusops_tier1_full_runner_v1.ps1",
  "scripts\selftest_all.ps1",
  "selftest_booking.js",
  "selftest_booking_disabled.js",
  "package.json",
  "package-lock.json"
)

foreach($rel in $requiredFiles){
  $p = Join-Path $RepoRoot $rel
  if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ Die ("REQUIRED_FILE_MISSING: " + $rel) }
  Write-Output ("FILE_OK: " + $rel)
}

# Parse-gate PowerShell runners
foreach($rel in @(
  "scripts\_RUN_proteusops_restore_sane_v1.ps1",
  "scripts\_RUN_proteusops_tier0_full_green_v7.ps1",
  "scripts\028_proteusops_tier1_full_runner_v1.ps1",
  "scripts\selftest_all.ps1"
)){
  $p = Join-Path $RepoRoot $rel
  Parse-GateFile $p
  Write-Output ("PARSE_OK: " + $rel)
}

# Secrets
$secretDir = Join-Path $RepoRoot "proofs\secrets"

$secretFiles = @{
  "SUPABASE_URL" = "SUPABASE_URL.txt"
  "SUPABASE_ANON_KEY" = "SUPABASE_ANON_KEY.txt"
  "SUPABASE_SERVICE_ROLE_KEY" = "SUPABASE_SERVICE_ROLE_KEY.txt"
  "DATABASE_URL" = "DATABASE_URL.txt"
  "TEST_EMAIL" = "TEST_EMAIL.txt"
  "TEST_PASSWORD" = "TEST_PASSWORD.txt"
  "ORG_ID" = "ORG_ID.txt"
}

$values = @{}
foreach($k in $secretFiles.Keys){
  $path = Join-Path $secretDir $secretFiles[$k]
  $v = Read-SecretTrimmed $path
  $values[$k] = $v
  Write-Output ("SECRET_OK: " + $k + " len=" + $v.Length)
}

# Shape checks
if($values["SUPABASE_URL"] -notmatch '^https://[a-z0-9]+\.supabase\.co$'){
  Die "SUPABASE_URL_INVALID_SHAPE"
}
Write-Output "SUPABASE_URL_SHAPE_OK"

Assert-JwtShape "SUPABASE_ANON_KEY" $values["SUPABASE_ANON_KEY"]
Assert-JwtShape "SUPABASE_SERVICE_ROLE_KEY" $values["SUPABASE_SERVICE_ROLE_KEY"]

$anonPayload = Decode-JwtPayload $values["SUPABASE_ANON_KEY"]
$svcPayload  = Decode-JwtPayload $values["SUPABASE_SERVICE_ROLE_KEY"]

if($anonPayload.role -ne "anon"){ Die ("SUPABASE_ANON_ROLE_BAD: " + $anonPayload.role) }
if($svcPayload.role -ne "service_role"){ Die ("SUPABASE_SERVICE_ROLE_BAD: " + $svcPayload.role) }

Write-Output "SUPABASE_KEY_ROLES_OK"

$dbUri = [uri]$values["DATABASE_URL"]
if($dbUri.Host -eq "db.ytwjyemqlbbebysiopzd.supabase.co"){
  Die "DATABASE_URL_DIRECT_HOST_NOT_ALLOWED_USE_POOLER"
}
if($dbUri.Host -notmatch 'pooler\.supabase\.com$'){
  Die ("DATABASE_URL_NOT_POOLER_HOST: " + $dbUri.Host)
}
Write-Output ("DATABASE_URL_POOLER_OK: " + $dbUri.Host + ":" + $dbUri.Port)

if($values["TEST_EMAIL"] -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$'){
  Die "TEST_EMAIL_INVALID_SHAPE"
}
Write-Output "TEST_EMAIL_SHAPE_OK"

if($values["ORG_ID"] -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'){
  Die "ORG_ID_NOT_UUID"
}
Write-Output "ORG_ID_SHAPE_OK"

# Force env for downstream runners
foreach($k in $values.Keys){
  [Environment]::SetEnvironmentVariable($k,$values[$k],"Process")
}
Write-Output "ENV_FORCE_LOAD_OK"

Write-Output "PROTEUSOPS_BOOTSTRAP_VERIFY_OK"
