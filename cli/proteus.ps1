param(
  [Parameter(Position=0)]
  [ValidateSet("setup","models","verify","launch","rollback","receipts","rpc","help")]
  [string]$Command = "help",

  [string]$Model = "DEVELOPER_PORTAL_V1",
  [string]$OrgId = "",
  [string]$Config = ".\proteus.config.json",
  [string]$RpcName = "",
  [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ClientPath = Join-Path $ScriptRoot "lib\supabase_client.ps1"
if(Test-Path -LiteralPath $ClientPath -PathType Leaf){
  . $ClientPath
}

function Write-ProteusJson([object]$Obj){ $Obj | ConvertTo-Json -Depth 40 }

function New-ProteusReceipt([string]$Token,[hashtable]$Data){
  [ordered]@{
    ok = $true
    token = $Token
    utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
    data = $Data
  }
}

function Show-Human([string]$Title,[string]$Message){
  Write-Host ""
  Write-Host $Title -ForegroundColor Cyan
  Write-Host $Message
  Write-Host ""
}

switch($Command){
  "help" {
    $receipt = New-ProteusReceipt "PROTEUSOPS_CLI_HELP_OK" @{
      commands = @("setup","models","verify","launch","rollback","receipts","rpc")
    }
    if($Json){ Write-ProteusJson $receipt; return }
    Show-Human "ProteusOps CLI" "Commands: setup, models, verify, launch, rollback, receipts, rpc"
    return
  }

  "models" {
    $receipt = New-ProteusReceipt "PROTEUSOPS_CLI_MODELS_OK" @{
      models = @("BARBER_NAIL_V1","CONTRACTOR_V1","REAL_ESTATE_V1","DEVELOPER_PORTAL_V1")
    }
    if($Json){ Write-ProteusJson $receipt; return }
    Show-Human "Available Models" "Pick one supported operational model."
    foreach($m in $receipt.data.models){ Write-Host ("- " + $m) }
    return
  }

  "setup" {
    $receipt = New-ProteusReceipt "PROTEUSOPS_CLI_SETUP_OK" @{
      model = $Model
      config = $Config
      next = @("copy proteus.config.example.json to proteus.config.json","fill Supabase URL/key","run proteus verify")
    }
    if($Json){ Write-ProteusJson $receipt; return }
    Show-Human "Setup" ("Model selected: " + $Model)
    foreach($n in $receipt.data.next){ Write-Host ("- " + $n) }
    return
  }

  "rpc" {
    if([string]::IsNullOrWhiteSpace($RpcName)){ throw "PROTEUS_RPC_NAME_REQUIRED" }
    $res = Invoke-ProteusRpc -ConfigPath $Config -RpcName $RpcName -Body @{}
    Write-ProteusJson $res
    return
  }

  "verify" {
    if([string]::IsNullOrWhiteSpace($OrgId)){
      $receipt = New-ProteusReceipt "PROTEUSOPS_CLI_VERIFY_NEEDS_ORG_OK" @{
        status = "needs_org_id"
        usage = "proteus verify -OrgId <uuid>"
      }
      if($Json){ Write-ProteusJson $receipt; return }
      Show-Human "Verify" "Provide -OrgId <uuid> to run live Supabase RPC verification."
      return
    }

    $rollup = Invoke-ProteusRpc -ConfigPath $Config -RpcName "rpc_provider_readiness_rollup_v1" -Body @{
      p_org_id = $OrgId
      p_model_key = $Model
      p_model_version = "v1"
    }

    if(-not $rollup.ok){
      Write-ProteusJson $rollup
      return
    }

    $gate = Invoke-ProteusRpc -ConfigPath $Config -RpcName "rpc_run_security_gate_matrix_v1" -Body @{
      p_org_id = $OrgId
      p_model_key = $Model
    }

    $receipt = [ordered]@{
      ok = ($rollup.ok -and $gate.ok)
      token = "PROTEUSOPS_CLI_VERIFY_RPC_OK"
      model = $Model
      org_id = $OrgId
      provider_readiness = $rollup.response
      security_gates = $gate.response
    }

    if($Json){ Write-ProteusJson $receipt; return }

    Show-Human "Verify" "Live Supabase RPC verification completed."
    Write-ProteusJson $receipt
    return
  }

  "launch" {
    $receipt = New-ProteusReceipt "PROTEUSOPS_CLI_LAUNCH_PENDING_OK" @{
      status = "pending_launch_wiring"
      next = "wire launch-control + worker RPC sequence"
    }
    if($Json){ Write-ProteusJson $receipt; return }
    Show-Human "Launch" "Launch RPC sequence comes next."
    return
  }

  "rollback" {
    $receipt = New-ProteusReceipt "PROTEUSOPS_CLI_ROLLBACK_PENDING_OK" @{
      status = "pending_rollback_wiring"
    }
    if($Json){ Write-ProteusJson $receipt; return }
    Show-Human "Rollback" "Rollback RPC sequence comes next."
    return
  }

  "receipts" {
    $receipt = New-ProteusReceipt "PROTEUSOPS_CLI_RECEIPTS_OK" @{
      tokens = @(
        "PROTEUSOPS_FULL_GREEN_ENGINE_REGISTRY_OK",
        "PROTEUSOPS_CUSTOMER_DEPLOYMENT_HANDOFF_OK",
        "PROTEUSOPS_SECURITY_GATE_MATRIX_OK",
        "PROTEUSOPS_STRESS_HARNESS_OK"
      )
    }
    if($Json){ Write-ProteusJson $receipt; return }
    Show-Human "Receipts" "Known platform receipt tokens."
    foreach($t in $receipt.data.tokens){ Write-Host ("- " + $t) }
    return
  }
}
