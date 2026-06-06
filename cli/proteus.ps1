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
function Ensure-ProteusDir([string]$Path){
  if([string]::IsNullOrWhiteSpace($Path)){ throw "PROTEUS_DIR_EMPTY" }
  if(!(Test-Path -LiteralPath $Path -PathType Container)){
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
  }
}

function Export-ProteusCliReceipt([object]$Receipt,[string]$CommandName){
  $repoRoot = Split-Path -Parent $ScriptRoot
  $receiptDir = Join-Path $repoRoot "proofs\receipts\cli"
  Ensure-ProteusDir $receiptDir

  $utc = [DateTime]::UtcNow.ToString("yyyyMMdd_HHmmss_fffffffZ")
  $safeCommand = ($CommandName -replace '[^A-Za-z0-9_\-]','_')
  $path = Join-Path $receiptDir ($utc + "_" + $safeCommand + ".json")

  $json = $Receipt | ConvertTo-Json -Depth 60
  $json = $json -replace "`r`n","`n"
  $json = $json -replace "`r","`n"
  if(!$json.EndsWith("`n")){ $json += "`n" }

  [IO.File]::WriteAllText($path,$json,[Text.UTF8Encoding]::new($false))

  return $path
}

function Write-ProteusCliResult([object]$Receipt,[string]$CommandName,[switch]$AsJson){
  $receiptPath = Export-ProteusCliReceipt -Receipt $Receipt -CommandName $CommandName

  if($Receipt -is [System.Collections.IDictionary]){
    $Receipt["cli_receipt_path"] = $receiptPath
  }

  if($AsJson){
    Write-ProteusJson $Receipt
  }
  else {
    Write-Host ("CLI_RECEIPT: " + $receiptPath) -ForegroundColor DarkGray
  }
}

switch($Command){
  "help" {
    $receipt = New-ProteusReceipt "PROTEUSOPS_CLI_HELP_OK" @{
      commands = @("setup","models","verify","launch","rollback","receipts","rpc")
    }
    if($Json){ Write-ProteusCliResult -Receipt $receipt -CommandName $Command -AsJson; return }
    Show-Human "ProteusOps CLI" "Commands: setup, models, verify, launch, rollback, receipts, rpc"
    return
  }

  "models" {
    $receipt = New-ProteusReceipt "PROTEUSOPS_CLI_MODELS_OK" @{
      models = @("BARBER_NAIL_V1","CONTRACTOR_V1","REAL_ESTATE_V1","DEVELOPER_PORTAL_V1")
    }
    if($Json){ Write-ProteusCliResult -Receipt $receipt -CommandName $Command -AsJson; return }
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
    if($Json){ Write-ProteusCliResult -Receipt $receipt -CommandName $Command -AsJson; return }
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
      if($Json){ Write-ProteusCliResult -Receipt $receipt -CommandName $Command -AsJson; return }
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

    if($Json){ Write-ProteusCliResult -Receipt $receipt -CommandName $Command -AsJson; return }

    Show-Human "Verify" "Live Supabase RPC verification completed."
    Write-ProteusJson $receipt
    return
  }

  "launch" {
    $missing = @()

    if([string]::IsNullOrWhiteSpace($OrgId)){
      $missing += "OrgId"
    }

    if([string]::IsNullOrWhiteSpace($WizardSessionId)){
      $missing += "WizardSessionId"
    }

    if([string]::IsNullOrWhiteSpace($PlanRunId)){
      $missing += "PlanRunId"
    }

    if([string]::IsNullOrWhiteSpace($DeploymentReceiptId)){
      $missing += "DeploymentReceiptId"
    }

    if([string]::IsNullOrWhiteSpace($ProviderReadinessRollupId)){
      $missing += "ProviderReadinessRollupId"
    }

    if($missing.Count -gt 0){
      $receipt = [ordered]@{
        ok = $false
        token = "PROTEUSOPS_CLI_LAUNCH_ARGUMENT_GATE_OK"
        status = "missing_required_arguments"
        missing = $missing
        usage = "proteus launch -OrgId <uuid> -WizardSessionId <uuid> -PlanRunId <uuid> -DeploymentReceiptId <uuid> -ProviderReadinessRollupId <uuid>"
      }

      if($Json){
        Write-ProteusCliResult -Receipt $receipt -CommandName $Command -AsJson
        return
      }

      Show-Human "Launch" "Missing required arguments."
      foreach($m in $missing){
        Write-Host ("- " + $m)
      }
      Write-Host ""
      Write-Host $receipt.usage
      return
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

    $worker = [ordered]@{
      ok = $false
      token = "PROTEUSOPS_CLI_LAUNCH_WORKER_SKIPPED"
      reason = "launch_control_rpc_failed"
    }

    if($launchControl.ok -and $null -ne $launchControl.response){
      $launchControlReceiptId = ""
      if($launchControl.response.PSObject.Properties.Name -contains "launch_control_receipt_id"){
        $launchControlReceiptId = [string]$launchControl.response.launch_control_receipt_id
      }

      if(-not [string]::IsNullOrWhiteSpace($launchControlReceiptId)){
        $worker = Invoke-ProteusRpc -ConfigPath $Config -RpcName "rpc_queue_launch_execution_worker_v1" -Body @{
          p_launch_control_receipt_id = $launchControlReceiptId
        }
      }
      else {
        $worker = [ordered]@{
          ok = $false
          token = "PROTEUSOPS_CLI_LAUNCH_WORKER_SKIPPED"
          reason = "launch_control_receipt_id_missing"
        }
      }
    }

    $receipt = [ordered]@{
      ok = ($handoff.ok -and $launchControl.ok -and $worker.ok)
      token = "PROTEUSOPS_CLI_LAUNCH_WORKER_SEQUENCE_OK"
      model = $Model
      org_id = $OrgId
      handoff = $handoff.response
      launch_control = $launchControl.response
      worker = $worker.response
      worker_rpc = $worker
    }

    if($Json){ Write-ProteusCliResult -Receipt $receipt -CommandName $Command -AsJson; return }

    Show-Human "Launch" "Launch handoff, control-plane receipt, and worker queue RPCs completed."
    Write-ProteusJson $receipt
    return
  }

  "rollback" {
    $receipt = New-ProteusReceipt "PROTEUSOPS_CLI_ROLLBACK_PENDING_OK" @{
      status = "pending_rollback_wiring"
    }
    if($Json){ Write-ProteusCliResult -Receipt $receipt -CommandName $Command -AsJson; return }
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
    if($Json){ Write-ProteusCliResult -Receipt $receipt -CommandName $Command -AsJson; return }
    Show-Human "Receipts" "Known platform receipt tokens."
    foreach($t in $receipt.data.tokens){ Write-Host ("- " + $t) }
    return
  }
}
