param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [int]$TimeoutSeconds = 300
)

$ErrorActionPreference="Stop"
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
  $t=$s.Replace("`r`n","`n").Replace("`r","`n")
  if(-not $t.EndsWith("`n")){ $t += "`n" }
  return $t
}

function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir=Split-Path -Parent $Path
  if($dir){ Ensure-Dir $dir }
  $enc=New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path,(Normalize-Lf $Text),$enc)
}

function Read-SecretTrimmed([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Die ("MISSING_SECRET_FILE: " + $Path) }
  $enc=New-Object System.Text.UTF8Encoding($false)
  $v=([System.IO.File]::ReadAllText($Path,$enc)).Trim()
  if([string]::IsNullOrWhiteSpace($v)){ Die ("SECRET_EMPTY: " + $Path) }
  return $v
}

function Sha256HexFile([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Die ("MISSING_FILE_FOR_SHA256: " + $Path) }
  $sha=[System.Security.Cryptography.SHA256]::Create()
  try{
    $bytes=[System.IO.File]::ReadAllBytes($Path)
    return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace "-","").ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Run-Child([string]$Exe,[string]$Cwd,[string]$ArgString,[string]$Out,[string]$Err,[int]$TimeoutSeconds){
  Ensure-Dir (Split-Path -Parent $Out)
  if(Test-Path -LiteralPath $Out -PathType Leaf){ Remove-Item -LiteralPath $Out -Force }
  if(Test-Path -LiteralPath $Err -PathType Leaf){ Remove-Item -LiteralPath $Err -Force }

  $p=Start-Process -FilePath $Exe -ArgumentList $ArgString -WorkingDirectory $Cwd -RedirectStandardOutput $Out -RedirectStandardError $Err -NoNewWindow -PassThru
  $ok=$p.WaitForExit($TimeoutSeconds * 1000)
  if(-not $ok){
    try{ Stop-Process -Id $p.Id -Force } catch {}
    Die ("TIMEOUT: child did not exit within " + $TimeoutSeconds + " seconds")
  }
  return [int]$p.ExitCode
}

function Tail-File([string]$Path){
  if(Test-Path -LiteralPath $Path -PathType Leaf){
    Get-Content -LiteralPath $Path -Tail 160 | ForEach-Object { Write-Output $_ }
  }
}

function Invoke-Psql([string]$RepoRoot,[string]$Sql,[string]$Out,[string]$Err,[int]$TimeoutSeconds){
  $psql=(Get-Command psql.exe -ErrorAction Stop).Source
  $db=[Environment]::GetEnvironmentVariable("DATABASE_URL","Process")
  if([string]::IsNullOrWhiteSpace($db)){ Die "DATABASE_URL_MISSING" }

  $sqlPath=Join-Path (Split-Path -Parent $Out) ((Split-Path -Leaf $Out) + ".sql")
  Write-Utf8NoBomLf $sqlPath $Sql

  $args='"' + $db + '" -v ON_ERROR_STOP=1 -f "' + $sqlPath + '"'
  return Run-Child $psql $RepoRoot $args $Out $Err $TimeoutSeconds
}

$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
$PSExe=(Get-Command powershell.exe -ErrorAction Stop).Source
$runId=(Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmssZ")

$RunDir=Join-Path $RepoRoot ("proofs\receipts\operator_bootstrap\" + $runId)
Ensure-Dir $RunDir

$BootstrapOut=Join-Path $RunDir "bootstrap_verify_stdout.txt"
$BootstrapErr=Join-Path $RunDir "bootstrap_verify_stderr.txt"
$Tier1Out=Join-Path $RunDir "tier1_stdout.txt"
$Tier1Err=Join-Path $RunDir "tier1_stderr.txt"
$Tier2Out=Join-Path $RunDir "tier2_provisioning_stdout.txt"
$Tier2Err=Join-Path $RunDir "tier2_provisioning_stderr.txt"
$OperatorReceipt=Join-Path $RunDir "OPERATOR_BOOTSTRAP_RECEIPT.md"
$Sums=Join-Path $RunDir "sha256sums.txt"
$Ndjson=Join-Path $RepoRoot "proofs\receipts\operator_bootstrap.ndjson"

Write-Output ("RUN_ID=" + $runId)
Write-Output ("OPERATOR_BOOTSTRAP_RUN_DIR=" + $RunDir)

$secretDir=Join-Path $RepoRoot "proofs\secrets"
$keys=@(
  "SUPABASE_SERVICE_ROLE_KEY",
  "SUPABASE_ANON_KEY",
  "SUPABASE_URL",
  "DATABASE_URL",
  "TEST_EMAIL",
  "TEST_PASSWORD",
  "ORG_ID"
)

foreach($k in $keys){
  $path=Join-Path $secretDir ($k + ".txt")
  $v=Read-SecretTrimmed $path
  [Environment]::SetEnvironmentVariable($k,$v,"Process")
}

$db=[Environment]::GetEnvironmentVariable("DATABASE_URL","Process")
$dbUri=[uri]$db
if($dbUri.Host -notmatch 'pooler\.supabase\.com$'){
  Die ("DATABASE_URL_NOT_POOLER_HOST: " + $dbUri.Host)
}
Write-Output ("DATABASE_URL_POOLER_OK: " + $dbUri.Host + ":" + $dbUri.Port)

$bootstrap=Join-Path $RepoRoot "scripts\_RUN_proteusops_bootstrap_verify_v1.ps1"
$tier1=Join-Path $RepoRoot "scripts\028_proteusops_tier1_full_runner_v1.ps1"

$bootstrapArgs='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $bootstrap + '" -RepoRoot "' + $RepoRoot + '"'
$bootstrapExit=Run-Child $PSExe $RepoRoot $bootstrapArgs $BootstrapOut $BootstrapErr $TimeoutSeconds
$bootstrapText=Get-Content -LiteralPath $BootstrapOut -Raw
if($bootstrapExit -ne 0 -or $bootstrapText -notmatch "PROTEUSOPS_BOOTSTRAP_VERIFY_OK"){
  Write-Output "---- BOOTSTRAP_STDOUT_TAIL ----"; Tail-File $BootstrapOut
  Write-Output "---- BOOTSTRAP_STDERR_TAIL ----"; Tail-File $BootstrapErr
  Die "BOOTSTRAP_VERIFY_FAIL"
}
Write-Output "BOOTSTRAP_VERIFY_OK"

$tier1Args='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $tier1 + '" -RepoRoot "' + $RepoRoot + '" -TimeoutSeconds ' + $TimeoutSeconds
$tier1Exit=Run-Child $PSExe $RepoRoot $tier1Args $Tier1Out $Tier1Err $TimeoutSeconds
$tier1Text=Get-Content -LiteralPath $Tier1Out -Raw
if($tier1Exit -ne 0 -or $tier1Text -notmatch "PROTEUSOPS_TIER1_FULL_GREEN_OK"){
  Write-Output "---- TIER1_STDOUT_TAIL ----"; Tail-File $Tier1Out
  Write-Output "---- TIER1_STDERR_TAIL ----"; Tail-File $Tier1Err
  Die "TIER1_FULL_GREEN_FAIL"
}
Write-Output "TIER1_FULL_GREEN_OK"

$tier2Sql="select pods_provisioning.rpc_selftest_provisioning_lane_v1() as result;"
$tier2Exit=Invoke-Psql $RepoRoot $tier2Sql $Tier2Out $Tier2Err $TimeoutSeconds
$tier2Text=Get-Content -LiteralPath $Tier2Out -Raw
if($tier2Exit -ne 0 -or $tier2Text -notmatch "PROTEUSOPS_TIER2_PROVISIONING_LANE_OK"){
  Write-Output "---- TIER2_STDOUT_TAIL ----"; Tail-File $Tier2Out
  Write-Output "---- TIER2_STDERR_TAIL ----"; Tail-File $Tier2Err
  Die "TIER2_PROVISIONING_LANE_FAIL"
}
Write-Output "TIER2_PROVISIONING_LANE_OK"

$adminUrl=[Environment]::GetEnvironmentVariable("SUPABASE_URL","Process")
$orgId=[Environment]::GetEnvironmentVariable("ORG_ID","Process")
$email=[Environment]::GetEnvironmentVariable("TEST_EMAIL","Process")

$receipt=@"
# ProteusOps Operator Bootstrap Receipt

## Status

READY

## Run

Run ID: $runId

## Proven

- Bootstrap verifier passed
- Tier-1 full green passed
- Tier-2 provisioning lane passed
- Supabase pooler database URL validated
- Repo-local secrets force-loaded
- Receipts emitted

## Operator Access

Supabase Project URL:

$adminUrl

Test Operator Email:

$email

Org ID:

$orgId

## Evidence Folder

$RunDir

## Files

- bootstrap_verify_stdout.txt
- bootstrap_verify_stderr.txt
- tier1_stdout.txt
- tier1_stderr.txt
- tier2_provisioning_stdout.txt
- tier2_provisioning_stderr.txt
- OPERATOR_BOOTSTRAP_RECEIPT.md
- sha256sums.txt

## Customer-Facing Meaning

The infrastructure is ready to provision business base models after a template pack is installed.

Next commercial template target:

BARBER_NAIL_V1

## Final Token

PROTEUSOPS_OPERATOR_BOOTSTRAP_OK
"@

Write-Utf8NoBomLf $OperatorReceipt $receipt

$files=@($BootstrapOut,$BootstrapErr,$Tier1Out,$Tier1Err,$Tier2Out,$Tier2Err,$OperatorReceipt)
$sumLines=New-Object System.Collections.Generic.List[string]
foreach($f in $files){
  if(Test-Path -LiteralPath $f -PathType Leaf){
    [void]$sumLines.Add((Sha256HexFile $f) + "  " + $f.Replace($RepoRoot + "\","").Replace("\","/"))
  }
}
Write-Utf8NoBomLf $Sums ((@($sumLines.ToArray() | Sort-Object) -join "`n") + "`n")
Write-Output ("SHA256SUMS_WROTE: " + $Sums)

$event=[ordered]@{
  event_type="proteusops/operator-bootstrap"
  run_id=$runId
  utc=(Get-Date).ToUniversalTime().ToString("o")
  status="ready"
  receipt_path=$OperatorReceipt.Replace($RepoRoot + "\","").Replace("\","/")
  sha256sums_sha256=(Sha256HexFile $Sums)
}
$j=($event | ConvertTo-Json -Compress -Depth 5)
[System.IO.File]::AppendAllText($Ndjson,(Normalize-Lf $j),(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("RECEIPT_APPENDED: " + $Ndjson)

Write-Output "PROTEUSOPS_OPERATOR_BOOTSTRAP_OK"
