param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [int]$TimeoutSeconds = 300
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
  $tokens=$null
  $errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
  if($errors -and $errors.Count -gt 0){
    $e=$errors[0]
    Die ("PARSE_GATE_FAIL: " + $Path + " @ " + $e.Extent.StartLineNumber + ":" + $e.Extent.StartColumnNumber + " " + $e.Message)
  }
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

function Read-SecretTrimmed([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Die ("MISSING_SECRET_FILE: " + $Path) }
  $enc = New-Object System.Text.UTF8Encoding($false)
  $v = ([System.IO.File]::ReadAllText($Path,$enc)).Trim()
  if([string]::IsNullOrWhiteSpace($v)){ Die ("SECRET_EMPTY: " + $Path) }
  return $v
}

function Force-Load-Secrets([string]$RepoRoot){
  $secretDir = Join-Path $RepoRoot "proofs\secrets"

  $db = Read-SecretTrimmed (Join-Path $secretDir "DATABASE_URL.txt")
  if(([uri]$db).Host -eq "db.ytwjyemqlbbebysiopzd.supabase.co"){
    Die "DATABASE_URL_DIRECT_HOST_STILL_PRESENT_USE_POOLER"
  }

  [Environment]::SetEnvironmentVariable("SUPABASE_SERVICE_ROLE_KEY",(Read-SecretTrimmed (Join-Path $secretDir "SUPABASE_SERVICE_ROLE_KEY.txt")),"Process")
  [Environment]::SetEnvironmentVariable("SUPABASE_ANON_KEY",(Read-SecretTrimmed (Join-Path $secretDir "SUPABASE_ANON_KEY.txt")),"Process")
  [Environment]::SetEnvironmentVariable("SUPABASE_URL",(Read-SecretTrimmed (Join-Path $secretDir "SUPABASE_URL.txt")),"Process")
  [Environment]::SetEnvironmentVariable("DATABASE_URL",$db,"Process")
  [Environment]::SetEnvironmentVariable("TEST_EMAIL",(Read-SecretTrimmed (Join-Path $secretDir "TEST_EMAIL.txt")),"Process")
  [Environment]::SetEnvironmentVariable("TEST_PASSWORD",(Read-SecretTrimmed (Join-Path $secretDir "TEST_PASSWORD.txt")),"Process")
  [Environment]::SetEnvironmentVariable("ORG_ID",(Read-SecretTrimmed (Join-Path $secretDir "ORG_ID.txt")),"Process")

  Write-Output ("ENV_DATABASE_URL_HOST=" + ([uri]$db).Host)
  Write-Output ("ENV_DATABASE_URL_PORT=" + ([uri]$db).Port)
}

function Run-Child([string]$Exe,[string]$Cwd,[string]$ArgString,[string]$Out,[string]$Err,[int]$TimeoutSeconds){
  Ensure-Dir (Split-Path -Parent $Out)
  if(Test-Path -LiteralPath $Out -PathType Leaf){ Remove-Item -LiteralPath $Out -Force }
  if(Test-Path -LiteralPath $Err -PathType Leaf){ Remove-Item -LiteralPath $Err -Force }

  $p = Start-Process -FilePath $Exe -ArgumentList $ArgString -WorkingDirectory $Cwd -RedirectStandardOutput $Out -RedirectStandardError $Err -NoNewWindow -PassThru
  $ok = $p.WaitForExit($TimeoutSeconds * 1000)
  if(-not $ok){
    try{ Stop-Process -Id $p.Id -Force } catch {}
    Die ("TIMEOUT: child did not exit within " + $TimeoutSeconds + " seconds")
  }
  return [int]$p.ExitCode
}

function Tail-File([string]$Path){
  if(Test-Path -LiteralPath $Path -PathType Leaf){
    Get-Content -LiteralPath $Path -Tail 200 | ForEach-Object { Write-Output $_ }
  }
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source
$PsqlExe = (Get-Command psql.exe -ErrorAction Stop).Source

$runId = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmssZ")
$RunDir = Join-Path $RepoRoot ("proofs\receipts\proteusops_tier1\" + $runId)
Ensure-Dir $RunDir

$Tier0Out = Join-Path $RunDir "tier0_stdout.txt"
$Tier0Err = Join-Path $RunDir "tier0_stderr.txt"
$LaneOut = Join-Path $RunDir "lane_stdout.txt"
$LaneErr = Join-Path $RunDir "lane_stderr.txt"
$PublicOut = Join-Path $RunDir "public_stdout.txt"
$PublicErr = Join-Path $RunDir "public_stderr.txt"
$Sums = Join-Path $RunDir "sha256sums.txt"
$Ndjson = Join-Path $RepoRoot "proofs\receipts\proteusops_tier1.ndjson"

Write-Output ("RUN_ID=" + $runId)

foreach($f in @(
  (Join-Path $RepoRoot "scripts\_RUN_proteusops_restore_sane_v1.ps1"),
  (Join-Path $RepoRoot "scripts\_RUN_proteusops_tier0_full_green_v7.ps1"),
  (Join-Path $RepoRoot "scripts\028_proteusops_tier1_full_runner_v1.ps1"),
  (Join-Path $RepoRoot "scripts\selftest_all.ps1")
)){
  Parse-GateFile $f
  Write-Output ("PARSE_OK: " + $f)
}

Force-Load-Secrets $RepoRoot

$tier0Runner = Join-Path $RepoRoot "scripts\_RUN_proteusops_tier0_full_green_v7.ps1"
$tier0Args = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $tier0Runner + '" -RepoRoot "' + $RepoRoot + '" -TimeoutSeconds ' + $TimeoutSeconds
$tier0Exit = Run-Child $PSExe $RepoRoot $tier0Args $Tier0Out $Tier0Err $TimeoutSeconds
$tier0Text = Get-Content -LiteralPath $Tier0Out -Raw
if($tier0Exit -ne 0 -or $tier0Text -notmatch "PROTEUSOPS_TIER0_FULL_GREEN_OK"){
  Write-Output "---- TIER0_STDOUT_TAIL ----"; Tail-File $Tier0Out
  Write-Output "---- TIER0_STDERR_TAIL ----"; Tail-File $Tier0Err
  Die "TIER0_FAIL"
}
Write-Output "TIER0_OK"

function Run-PsqlQuery([string]$Sql,[string]$Out,[string]$Err,[string]$Needle){
  $db = [Environment]::GetEnvironmentVariable("DATABASE_URL","Process")
  if([string]::IsNullOrWhiteSpace($db)){ Die "DATABASE_URL_MISSING" }

  $sqlPath = Join-Path (Split-Path -Parent $Out) ((Split-Path -Leaf $Out) + ".sql")
  Write-Utf8NoBomLf $sqlPath $Sql

  $args = '"' + $db + '" -v ON_ERROR_STOP=1 -f "' + $sqlPath + '"'
  $exit = Run-Child $script:PsqlExe $script:RepoRoot $args $Out $Err $script:TimeoutSeconds
  $text = ""
  if(Test-Path -LiteralPath $Out -PathType Leaf){ $text = Get-Content -LiteralPath $Out -Raw }
  if($exit -ne 0 -or $text -notmatch $Needle){
    Write-Output ("PSQL_STDOUT_PATH=" + $Out)
    Write-Output ("PSQL_STDERR_PATH=" + $Err)
    Write-Output "---- PSQL_STDOUT_TAIL ----"; Tail-File $Out
    Write-Output "---- PSQL_STDERR_TAIL ----"; Tail-File $Err
    Die ("PSQL_TOKEN_MISSING: " + $Needle)
  }
}

Run-PsqlQuery "select * from pods_core.rpc_selftest_lane_boundaries_all_v1();" $LaneOut $LaneErr "LANE_BOUNDARY_DENY"
Write-Output "LANE_OK"

Run-PsqlQuery "select * from pods_public.rpc_selftest_public_surfaces_all_v1();" $PublicOut $PublicErr "PUBLIC_SURFACE_DENY"
Write-Output "PUBLIC_OK"

$files = @(
  (Join-Path $RepoRoot "scripts\028_proteusops_tier1_full_runner_v1.ps1"),
  $Tier0Out,$Tier0Err,$LaneOut,$LaneErr,$PublicOut,$PublicErr
)

$sumLines = New-Object System.Collections.Generic.List[string]
foreach($f in $files){
  if(Test-Path -LiteralPath $f -PathType Leaf){
    [void]$sumLines.Add((Sha256HexFile $f) + "  " + $f.Replace($RepoRoot + "\","").Replace("\","/"))
  }
}
Write-Utf8NoBomLf $Sums ((@($sumLines.ToArray() | Sort-Object) -join "`n") + "`n")
Write-Output ("SHA256SUMS_WROTE: " + $Sums)

$receipt = [ordered]@{
  event_type = "proteusops/tier1-full-green"
  run_id = $runId
  utc = (Get-Date).ToUniversalTime().ToString("o")
  sha256sums_sha256 = (Sha256HexFile $Sums)
}
$j = ($receipt | ConvertTo-Json -Compress -Depth 5)
[System.IO.File]::AppendAllText($Ndjson,(Normalize-Lf $j),(New-Object System.Text.UTF8Encoding($false)))
Write-Output ("RECEIPT_APPENDED: " + $Ndjson)

Write-Output "PROTEUSOPS_TIER1_FULL_GREEN_OK"
