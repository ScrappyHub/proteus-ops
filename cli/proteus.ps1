param(
  [Parameter(Position=0)]
  [ValidateSet("setup","models","verify","launch","rollback","receipts","rpc","help")]
  [string]$Command = "help",

  [string]$Model = "DEVELOPER_PORTAL_V1",
  [string]$OrgId = "",
  [string]$Config = ".\proteus.config.json",
  [string]$RpcName = "",
  [string]$WizardSessionId = "",
  [string]$PlanRunId = "",
  [string]$DeploymentReceiptId = "",
  [string]$ProviderReadinessRollupId = "",
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
    if([string]::IsNullOrWhiteSpace($OrgId)){
      throw "PROTEUS_LAUNCH_ORG_REQUIRED"
    }

    if([string]::IsNullOrWhiteSpace($WizardSessionId)){
      throw "PROTEUS_LAUNCH_WIZARD_SESSION_REQUIRED"
    }

    if([string]::IsNullOrWhiteSpace($PlanRunId)){
      throw "PROTEUS_LAUNCH_PLAN_RUN_REQUIRED"
    }

    if([string]::IsNullOrWhiteSpace($DeploymentReceiptId)){
      throw "PROTEUS_LAUNCH_DEPLOYMENT_RECEIPT_REQUIRED"
    }

    if([string]::IsNullOrWhiteSpace($ProviderReadinessRollupId)){
      throw "PROTEUS_LAUNCH_PROVIDER_READINESS_REQUIRED"
    }

    $handoff = Invoke-ProteusRpc -ConfigPath $Config -RpcName "rpc_emit_customer_deployment_handoff_v1" -Body @{
      p_org_id = $OrgId
      p_model_key = $Model
      p_model_version = "v1"
    }

    $launchControl = Invoke-ProteusRpc -ConfigPath $Config -RpcName "rpc_emit_launch_control_plane_receipt_v1" -Body @{
      p_org_id = $OrgId
      p_wizard_session_id = $WizardSessionId
      p_plan_run_id = $PlanRunId
      p_deployment_receipt_id = $DeploymentReceiptId
      p_provider_readiness_rollup_id = $ProviderReadinessRollupId
    }

    $receipt = [ordered]@{
      ok = ($handoff.ok -and $launchControl.ok)
      token = "PROTEUSOPS_CLI_LAUNCH_SEQUENCE_OK"
      model = $Model
      org_id = $OrgId
      handoff = $handoff.response
      launch_control = $launchControl.response
    }

    if($Json){ Write-ProteusJson $receipt; return }

    Show-Human "Launch" "Launch handoff and control-plane receipt RPCs completed."
    Write-ProteusJson $receipt
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
