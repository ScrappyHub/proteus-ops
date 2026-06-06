Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-ProteusSupabaseExecutionReadiness {
  param(
    [string]$RepoRoot,
    [string]$ConfigPath = ".\proteus.config.json"
  )

  if([string]::IsNullOrWhiteSpace($RepoRoot)){
    throw "SUPABASE_EXEC_REPO_ROOT_REQUIRED"
  }

  $resolvedConfig = $ConfigPath
  if(-not [IO.Path]::IsPathRooted($resolvedConfig)){
    $resolvedConfig = Join-Path $RepoRoot $ConfigPath
  }

  $migrationDir = Join-Path $RepoRoot "migrations"
  $supabaseClient = Join-Path $RepoRoot "cli\lib\supabase_client.ps1"

  $configExists = Test-Path -LiteralPath $resolvedConfig -PathType Leaf
  $migrationDirExists = Test-Path -LiteralPath $migrationDir -PathType Container
  $rpcClientExists = Test-Path -LiteralPath $supabaseClient -PathType Leaf
  $supabaseCliAvailable = [bool](Get-Command supabase -ErrorAction SilentlyContinue)

  $supabaseUrlPresent = $false
  $keyPresent = $false
  $defaultModel = ""

  if($configExists){
    $cfg = Get-Content -Raw -LiteralPath $resolvedConfig | ConvertFrom-Json

    if($cfg.PSObject.Properties.Name -contains "supabase_url"){
      $supabaseUrlPresent = -not [string]::IsNullOrWhiteSpace([string]$cfg.supabase_url)
    }

    if($cfg.PSObject.Properties.Name -contains "service_role_key"){
      $keyPresent = $keyPresent -or (-not [string]::IsNullOrWhiteSpace([string]$cfg.service_role_key))
    }

    if($cfg.PSObject.Properties.Name -contains "anon_key"){
      $keyPresent = $keyPresent -or (-not [string]::IsNullOrWhiteSpace([string]$cfg.anon_key))
    }

    if($cfg.PSObject.Properties.Name -contains "default_model"){
      $defaultModel = [string]$cfg.default_model
    }
  }

  $migrationCount = 0
  if($migrationDirExists){
    $migrationCount = @(
      Get-ChildItem -LiteralPath $migrationDir -Filter "*.sql" -File -ErrorAction SilentlyContinue
    ).Count
  }

  $ready = (
    $configExists `
    -and $supabaseUrlPresent `
    -and $keyPresent `
    -and $migrationDirExists `
    -and ($migrationCount -gt 0) `
    -and $rpcClientExists
  )

  $blocked = @()
  if(-not $configExists){ $blocked += "config_missing" }
  if($configExists -and -not $supabaseUrlPresent){ $blocked += "supabase_url_missing" }
  if($configExists -and -not $keyPresent){ $blocked += "supabase_key_missing" }
  if(-not $migrationDirExists){ $blocked += "migrations_dir_missing" }
  if($migrationDirExists -and $migrationCount -le 0){ $blocked += "migrations_missing" }
  if(-not $rpcClientExists){ $blocked += "rpc_client_missing" }
  if(-not $supabaseCliAvailable){ $blocked += "supabase_cli_not_installed_optional" }

  return [ordered]@{
    ok = $ready
    token = "PROTEUSOPS_SUPABASE_PROJECT_EXECUTION_ADAPTER_OK"
    utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
    adapter = "supabase_project_execution"
    readiness_status = $(if($ready){ "ready" } else { "blocked" })
    repo_root = $RepoRoot
    config_path = $resolvedConfig
    config_exists = $configExists
    supabase_url_present = $supabaseUrlPresent
    supabase_key_present = $keyPresent
    default_model = $defaultModel
    migration_dir = $migrationDir
    migration_count = $migrationCount
    rpc_client_exists = $rpcClientExists
    supabase_cli_available = $supabaseCliAvailable
    blocked_reasons = $blocked
    destructive_actions = $false
  }
}
