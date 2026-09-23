<#
ProteusOps — store a provider secret in the Workspace Hub safely (operator path, until the dashboard exists).

  * Registers (or finds) the provider account in a workspace, then stores the secret in Supabase Vault.
  * You are prompted for the Supabase service key and the secret; neither is echoed, written to disk,
    put in shell history, or sent anywhere except https://<project>.supabase.co over TLS.
  * Prints only the account id, the credential id and a short fingerprint (sha256:xxxxxxxx) so you can
    confirm which secret is stored without ever displaying it.

Examples
  # GitHub webhook signing secret for ScrappyHub (TEST ONLY workspace):
  powershell -ExecutionPolicy Bypass -File .\scripts\_SET_hub_secret_v1.ps1 -Workspace proteusops-stripe-test `
      -Provider github -AccountName "ScrappyHub GitHub" -ExternalRef ScrappyHub -Purpose webhook -Environment test `
      -RotateInDays 180 -Justification "GitHub webhook signing secret for ScrappyHub repos"

  # GitHub fine-grained read-only token (Metadata: read) for repo discovery:
  ... -Purpose api -RotateInDays 90 -Justification "Read-only GitHub token for repository inventory"

  # Only register the account and print the webhook URL (no secret):
  ... -Purpose none
#>
param(
  [Parameter(Mandatory)] [string] $Workspace,
  [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9][a-z0-9_-]{1,31}$')] [string] $Provider,
  [Parameter(Mandatory)] [string] $AccountName,
  [string] $ExternalRef = "",
  [ValidateSet('shared','test','live')] [string] $AccountEnvironment = "shared",
  [Parameter(Mandatory)] [ValidatePattern('^(none|[a-z][a-z0-9_.-]{1,63})$')] [string] $Purpose,
  [ValidateSet('test','live')] [string] $Environment = "test",
  [ValidateRange(1,400)] [int] $RotateInDays = 90,
  [string] $Justification = "",
  [string] $ProjectRef = "ytwjyemqlbbebysiopzd"
)
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$base = "https://$ProjectRef.supabase.co/rest/v1/rpc"

function Read-Secret([string]$prompt) {
  $s = Read-Host -Prompt $prompt -AsSecureString
  $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}
function Call-Rpc([string]$fn, [hashtable]$body, [string]$key) {
  $h = @{ apikey = $key; "Content-Type" = "application/json"; Prefer = "return=representation" }
  if ($key.StartsWith("eyJ")) { $h["Authorization"] = "Bearer $key" }   # legacy JWT service_role key
  try {
    return Invoke-RestMethod -Method Post -Uri "$base/$fn" -Headers $h -Body ($body | ConvertTo-Json -Compress)
  } catch {
    $msg = $_.ErrorDetails.Message; if (-not $msg) { $msg = $_.Exception.Message }
    throw "RPC $fn failed: $msg"
  }
}

Write-Host "Supabase dashboard -> Project Settings -> API Keys: copy the SECRET / service_role key (it is not echoed)."
$svc = Read-Secret "Service key"
if ($svc.Length -lt 20) { throw "That does not look like a service key." }
$operator = "$env:USERNAME@$env:COMPUTERNAME"
try {
  $acct = Call-Rpc "svc_hub_account_ensure_v1" @{ p_org_slug = $Workspace; p_provider_key = $Provider; p_display_name = $AccountName;
            p_external_ref = $ExternalRef; p_environment = $AccountEnvironment; p_operator = $operator } $svc
  Write-Host ("account_id : " + $acct.account_id + $(if ($acct.created) { "  (created)" } else { "  (existing)" }))
  if ($Provider -eq "github") {
    Write-Host ("webhook URL: https://$ProjectRef.functions.supabase.co/github-webhook?account=" + $acct.account_id)
  }
  if ($Purpose -eq "none") { return }
  if ($Justification.Trim().Length -lt 10) { throw "-Justification must be at least 10 characters (why this secret exists)." }
  $secret = Read-Secret "Secret value for '$Purpose' ($Environment)"
  if ($secret.Length -lt 8) { throw "Secret too short." }
  $secret2 = Read-Secret "Type it again to confirm"
  if ($secret -ne $secret2) { throw "The two entries do not match; nothing was stored." }
  $rot = (Get-Date).ToUniversalTime().AddDays($RotateInDays).ToString("o")
  $res = Call-Rpc "svc_hub_credential_put_v1" @{ p_account_id = $acct.account_id; p_purpose = $Purpose; p_environment = $Environment;
            p_secret_value = $secret; p_rotates_at = $rot; p_justification = $Justification; p_operator = $operator } $svc
  Write-Host ("credential : " + $res.credential_id + "  " + $res.action + "  fingerprint " + $res.fingerprint + "  rotates " + $rot.Substring(0,10))
  Write-Host "Status is pending_verification until the provider proves it (GitHub: the webhook 'ping' / a sync run)."
} finally {
  $svc = $null; $secret = $null; $secret2 = $null; [GC]::Collect()
}
