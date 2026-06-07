param(
  [Parameter(Position=0)]
  [ValidateSet("setup","models","verify","launch","rollback","receipts","rpc","check-supabase","connect","help")]
  [string]$Command = "help",

  [string]$Model = "DEVELOPER_PORTAL_V1",
  [string]$OrgId = "",
  [string]$Config = ".\proteus.config.json",
  [string]$RpcName = "",
  [ValidateSet("supabase","stripe","github","figma","email","storage")]
  [string]$Provider = "supabase",
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

$SupabaseExecutionAdapterPath = Join-Path $ScriptRoot "lib\supabase_execution_adapter.ps1"
if(Test-Path -LiteralPath $SupabaseExecutionAdapterPath -PathType Leaf){
  . $SupabaseExecutionAdapterPath
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
    Show-Human "ProteusOps CLI" "Commands: setup, models, verify, launch, rollback, receipts, rpc, check-supabase, connect"
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

  "connect" {
    $repoRoot = Split-Path -Parent $ScriptRoot

    if($Provider -ne "supabase"){
      $receipt = [ordered]@{
        ok = $false
        token = "PROTEUSOPS_CLI_CONNECT_PROVIDER_SCAFFOLD_OK"
        provider = $Provider
        status = "provider_not_implemented_yet"
        implemented = @("supabase")
        next = "Add provider adapter for " + $Provider
      }

      if($Json){
        Write-ProteusCliResult -Receipt $receipt -CommandName ("connect-" + $Provider) -AsJson
        return
      }

      Show-Human "Connect" ("Provider scaffold exists, but " + $Provider + " is not implemented yet.")
      return
    }

    $localConfig = Join-Path $repoRoot "proteus.config.json"

    if(!(Test-Path -LiteralPath $localConfig -PathType Leaf)){
      $cfg = [ordered]@{
        supabase_url = "https://YOUR_PROJECT.supabase.co"
        service_role_key = ""
        anon_key = ""
        default_model = $Model
      }

      $json = $cfg | ConvertTo-Json -Depth 10
      [IO.File]::WriteAllText($localConfig,($json + "`n"),[Text.UTF8Encoding]::new($false))
    }

    if(-not (Get-Command Test-ProteusSupabaseExecutionReadiness -ErrorAction SilentlyContinue)){
      throw "PROTEUS_SUPABASE_EXECUTION_ADAPTER_NOT_LOADED"
    }

    $check = Test-ProteusSupabaseExecutionReadiness -RepoRoot $repoRoot -ConfigPath $localConfig

    $receipt = [ordered]@{
      ok = [bool]$check.ok
      token = "PROTEUSOPS_CLI_CONNECT_PROVIDER_SCAFFOLD_OK"
      provider = "supabase"
      config_path = $localConfig
      readiness_status = $check.readiness_status
      blocked_reasons = $check.blocked_reasons
      destructive_actions = $false
      secret_printed = $false
      next = $(if($check.ok){ "Supabase ready." } else { "Fill missing local config values, then rerun connect." })
      check = $check
    }

    if($Json){
      Write-ProteusCliResult -Receipt $receipt -CommandName "connect-supabase" -AsJson
      return
    }

    $receiptPath = Export-ProteusCliReceipt -Receipt $receipt -CommandName "connect-supabase"
    Show-Human "Connect Supabase" ("Status: " + $check.readiness_status)
    Write-Host ("Config: " + $localConfig)
    Write-Host ("CLI_RECEIPT: " + $receiptPath) -ForegroundColor DarkGray

    if($check.blocked_reasons.Count -gt 0){
      Write-Host "Blocked reasons:"
      foreach($r in $check.blocked_reasons){
        Write-Host ("- " + $r)
      }
    }

    return
  }
  "check-supabase" {
    $repoRoot = Split-Path -Parent $ScriptRoot

    if(-not (Get-Command Test-ProteusSupabaseExecutionReadiness -ErrorAction SilentlyContinue)){
      throw "PROTEUS_SUPABASE_EXECUTION_ADAPTER_NOT_LOADED"
    }

    $check = Test-ProteusSupabaseExecutionReadiness -RepoRoot $repoRoot -ConfigPath $Config

    $receipt = [ordered]@{
      ok = [bool]$check.ok
      token = "PROTEUSOPS_CLI_SUPABASE_EXECUTION_CHECK_OK"
      utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
      check = $check
    }

    if($Json){
      Write-ProteusCliResult -Receipt $receipt -CommandName $Command -AsJson
      return
    }

    $receiptPath = Export-ProteusCliReceipt -Receipt $receipt -CommandName $Command
    Show-Human "Supabase Check" ("Status: " + $check.readiness_status)
    Write-Host ("CLI_RECEIPT: " + $receiptPath) -ForegroundColor DarkGray

    if($check.blocked_reasons.Count -gt 0){
      Write-Host "Blocked reasons:"
      foreach($r in $check.blocked_reasons){
        Write-Host ("- " + $r)
      }
    }

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
