Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Read-ProteusConfig {
  param([string]$ConfigPath)

  if([string]::IsNullOrWhiteSpace($ConfigPath)){
    throw "PROTEUS_CONFIG_PATH_EMPTY"
  }

  if(!(Test-Path -LiteralPath $ConfigPath -PathType Leaf)){
    throw ("PROTEUS_CONFIG_MISSING: " + $ConfigPath)
  }

  $raw = Get-Content -Raw -LiteralPath $ConfigPath
  if([string]::IsNullOrWhiteSpace($raw)){
    throw "PROTEUS_CONFIG_EMPTY"
  }

  return ($raw | ConvertFrom-Json)
}

function Invoke-ProteusRpc {
  param(
    [string]$ConfigPath,
    [string]$RpcName,
    [hashtable]$Body
  )

  if([string]::IsNullOrWhiteSpace($RpcName)){
    throw "PROTEUS_RPC_NAME_EMPTY"
  }

  $cfg = Read-ProteusConfig -ConfigPath $ConfigPath

  if([string]::IsNullOrWhiteSpace([string]$cfg.supabase_url)){
    throw "PROTEUS_SUPABASE_URL_MISSING"
  }

  $key = ""
  if($cfg.PSObject.Properties.Name -contains "service_role_key"){
    $key = [string]$cfg.service_role_key
  }

  if([string]::IsNullOrWhiteSpace($key) -and ($cfg.PSObject.Properties.Name -contains "anon_key")){
    $key = [string]$cfg.anon_key
  }

  if([string]::IsNullOrWhiteSpace($key)){
    throw "PROTEUS_SUPABASE_KEY_MISSING"
  }

  $base = ([string]$cfg.supabase_url).TrimEnd("/")
  $uri = $base + "/rest/v1/rpc/" + $RpcName

  $json = ($Body | ConvertTo-Json -Depth 30)

  $headers = @{
    "apikey" = $key
    "Authorization" = "Bearer $key"
    "Content-Type" = "application/json"
  }

  try {
    $res = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $json
    return [ordered]@{
      ok = $true
      token = "PROTEUSOPS_CLI_RPC_OK"
      rpc = $RpcName
      response = $res
    }
  }
  catch {
    return [ordered]@{
      ok = $false
      token = "PROTEUSOPS_CLI_RPC_FAIL"
      rpc = $RpcName
      error = $_.Exception.Message
    }
  }
}
