Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Cli = Join-Path $RepoRoot "cli\proteus.ps1"
$RpcClient = Join-Path $RepoRoot "cli\lib\supabase_client.ps1"
$ConfigExample = Join-Path $RepoRoot "proteus.config.example.json"
$ReceiptDir = Join-Path $RepoRoot "proofs\smoke"

function Die([string]$m){ throw $m }

function Ensure-Dir([string]$Path){
  if($Path -and !(Test-Path -LiteralPath $Path -PathType Container)){
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Invoke-CliJson([string[]]$Args){
  $out = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Cli @Args 2>&1
  if($LASTEXITCODE -ne 0){
    Die ("CLI_COMMAND_FAILED: " + ($Args -join " ") + "`n" + ($out | Out-String))
  }

  $raw = ($out | Out-String).Trim()
  if([string]::IsNullOrWhiteSpace($raw)){
    Die ("CLI_EMPTY_OUTPUT: " + ($Args -join " "))
  }

  return ($raw | ConvertFrom-Json)
}

function Assert-Token([object]$Obj,[string]$Expected){
  if($null -eq $Obj){ Die ("TOKEN_OBJECT_NULL: " + $Expected) }
  if($Obj.token -ne $Expected){
    Die ("TOKEN_MISMATCH expected=" + $Expected + " actual=" + [string]$Obj.token)
  }
}

if(!(Test-Path -LiteralPath $Cli -PathType Leaf)){ Die "CLI_MISSING" }
if(!(Test-Path -LiteralPath $RpcClient -PathType Leaf)){ Die "RPC_CLIENT_MISSING" }
if(!(Test-Path -LiteralPath $ConfigExample -PathType Leaf)){ Die "CONFIG_EXAMPLE_MISSING" }

Ensure-Dir $ReceiptDir

$help = Invoke-CliJson @("-Json","-Command","help")
Assert-Token $help "PROTEUSOPS_CLI_HELP_OK"

$models = Invoke-CliJson @("-Json","-Command","models")
Assert-Token $models "PROTEUSOPS_CLI_MODELS_OK"

$setup = Invoke-CliJson @("-Json","-Command","setup")
Assert-Token $setup "PROTEUSOPS_CLI_SETUP_OK"

$verify = Invoke-CliJson @("-Json","-Command","verify")
Assert-Token $verify "PROTEUSOPS_CLI_VERIFY_NEEDS_ORG_OK"

$launch = Invoke-CliJson @("-Json","-Command","launch")
Assert-Token $launch "PROTEUSOPS_CLI_LAUNCH_ARGUMENT_GATE_OK"

$receipts = Invoke-CliJson @("-Json","-Command","receipts")
Assert-Token $receipts "PROTEUSOPS_CLI_RECEIPTS_OK"

$receiptPaths = @(
  $help.cli_receipt_path,
  $models.cli_receipt_path,
  $setup.cli_receipt_path,
  $verify.cli_receipt_path,
  $launch.cli_receipt_path,
  $receipts.cli_receipt_path
)

foreach($p in $receiptPaths){
  if([string]::IsNullOrWhiteSpace([string]$p)){ Die "CLI_RECEIPT_PATH_MISSING" }
  if(!(Test-Path -LiteralPath $p -PathType Leaf)){ Die ("CLI_RECEIPT_FILE_MISSING: " + $p) }
}

$body = [ordered]@{
  ok = $true
  token = "PROTEUSOPS_CLI_FULL_GREEN_SMOKE_OK"
  utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
  cli = $Cli
  rpc_client = $RpcClient
  config_example = $ConfigExample
  commands = [ordered]@{
    help = $help.token
    models = $models.token
    setup = $setup.token
    verify = $verify.token
    launch = $launch.token
    receipts = $receipts.token
  }
  cli_receipt_paths = $receiptPaths
}

$json = $body | ConvertTo-Json -Depth 40
$path = Join-Path $ReceiptDir ("proteus_cli_full_green_smoke_" + [DateTime]::UtcNow.ToString("yyyyMMdd_HHmmss_fffffffZ") + ".json")
[IO.File]::WriteAllText($path,($json + "`n"),[Text.UTF8Encoding]::new($false))

Write-Host "PROTEUSOPS_CLI_FULL_GREEN_SMOKE_OK" -ForegroundColor Green
Write-Host $path
