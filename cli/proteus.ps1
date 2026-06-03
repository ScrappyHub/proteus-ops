param(
  [Parameter(Position=0)]
  [ValidateSet("setup","models","verify","launch","rollback","receipts","help")]
  [string]$Command = "help",

  [string]$Model = "DEVELOPER_PORTAL_V1",
  [string]$OrgId = "",
  [string]$Config = ".\proteus.config.json",
  [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-ProteusJson([object]$Obj){
  $Obj | ConvertTo-Json -Depth 20
}

function New-ProteusReceipt([string]$Token,[hashtable]$Data){
  $obj = [ordered]@{
    ok = $true
    token = $Token
    utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
    data = $Data
  }

  return $obj
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
      commands = @("setup","models","verify","launch","rollback","receipts")
      purpose = "ProteusOps operator CLI scaffold"
    }

    if($Json){ Write-ProteusJson $receipt; return }

    Show-Human "ProteusOps CLI" "Commands: setup, models, verify, launch, rollback, receipts"
    return
  }

  "setup" {
    $receipt = New-ProteusReceipt "PROTEUSOPS_CLI_SETUP_OK" @{
      model = $Model
      config = $Config
      next = @(
        "Create or review proteus.config.json",
        "Run proteus models",
        "Run proteus verify",
        "Connect providers",
        "Run proteus launch"
      )
    }

    if($Json){ Write-ProteusJson $receipt; return }

    Show-Human "Setup" ("Model selected: " + $Model)
    Write-Host "Next:"
    foreach($n in $receipt.data.next){ Write-Host ("- " + $n) }
    return
  }

  "models" {
    $receipt = New-ProteusReceipt "PROTEUSOPS_CLI_MODELS_OK" @{
      models = @(
        "BARBER_NAIL_V1",
        "CONTRACTOR_V1",
        "REAL_ESTATE_V1",
        "DEVELOPER_PORTAL_V1"
      )
    }

    if($Json){ Write-ProteusJson $receipt; return }

    Show-Human "Available Models" "Pick one of the supported operational models."
    foreach($m in $receipt.data.models){ Write-Host ("- " + $m) }
    return
  }

  "verify" {
    $receipt = New-ProteusReceipt "PROTEUSOPS_CLI_VERIFY_SCAFFOLD_OK" @{
      model = $Model
      org_id = $OrgId
      checks = @(
        "supabase_adapter_runtime",
        "stripe_adapter_runtime",
        "email_adapter_runtime",
        "storage_adapter_runtime",
        "github_adapter_runtime",
        "provider_readiness_rollup",
        "security_gate_matrix"
      )
      status = "scaffold_only"
    }

    if($Json){ Write-ProteusJson $receipt; return }

    Show-Human "Verify" "CLI scaffold is ready. RPC wiring comes next."
    foreach($c in $receipt.data.checks){ Write-Host ("- " + $c) }
    return
  }

  "launch" {
    $receipt = New-ProteusReceipt "PROTEUSOPS_CLI_LAUNCH_SCAFFOLD_OK" @{
      model = $Model
      org_id = $OrgId
      status = "not_executed"
      reason = "RPC execution wiring pending"
    }

    if($Json){ Write-ProteusJson $receipt; return }

    Show-Human "Launch" "Launch command scaffold exists. Execution wiring comes next."
    return
  }

  "rollback" {
    $receipt = New-ProteusReceipt "PROTEUSOPS_CLI_ROLLBACK_SCAFFOLD_OK" @{
      model = $Model
      org_id = $OrgId
      status = "not_executed"
      reason = "Rollback RPC wiring pending"
    }

    if($Json){ Write-ProteusJson $receipt; return }

    Show-Human "Rollback" "Rollback command scaffold exists. Runtime wiring comes next."
    return
  }

  "receipts" {
    $receipt = New-ProteusReceipt "PROTEUSOPS_CLI_RECEIPTS_SCAFFOLD_OK" @{
      model = $Model
      org_id = $OrgId
      receipt_tokens = @(
        "PROTEUSOPS_FULL_GREEN_ENGINE_REGISTRY_OK",
        "PROTEUSOPS_CUSTOMER_DEPLOYMENT_HANDOFF_OK",
        "PROTEUSOPS_SECURITY_GATE_MATRIX_OK",
        "PROTEUSOPS_STRESS_HARNESS_OK"
      )
    }

    if($Json){ Write-ProteusJson $receipt; return }

    Show-Human "Receipts" "Receipt export scaffold exists."
    foreach($r in $receipt.data.receipt_tokens){ Write-Host ("- " + $r) }
    return
  }
}
