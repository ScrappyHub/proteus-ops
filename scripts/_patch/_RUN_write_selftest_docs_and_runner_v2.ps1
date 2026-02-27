$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }

function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $dir = Split-Path -Parent $Path
  if($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)){
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $t = $Text -replace "`r`n","`n"
  $t = $t -replace "`r","`n"
  if(-not $t.EndsWith("`n")){ $t += "`n" }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path,$t,$enc)
}

function Parse-GatePs1([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Die ("MISSING_FILE: " + $Path) }
  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
  if($errors -and $errors.Count -gt 0){
    $e = $errors[0]
    Die ("PARSE_GATE_FAIL: " + $Path + " @ " + $e.Extent.StartLineNumber + ":" + $e.Extent.StartColumnNumber + " " + $e.Message)
  }
}

function Assert-Utf8NoBomLfFile([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Die ("MISSING_FILE: " + $Path) }
  $b = [System.IO.File]::ReadAllBytes($Path)

  # UTF-8 BOM check (EF BB BF)
  if($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF){
    Die ("BOM_PRESENT_NOT_ALLOWED: " + $Path)
  }

  # CR byte check (0x0D) — must be LF-only
  for($i=0; $i -lt $b.Length; $i++){
    if($b[$i] -eq 13){
      Die ("CR_BYTE_NOT_ALLOWED: " + $Path + " @index=" + $i)
    }
  }
}

$RepoRoot = (Resolve-Path -LiteralPath ".").Path
$DocPath  = Join-Path $RepoRoot "docs\SELFTEST_ProteusOps_v0_1.md"
$RunPath  = Join-Path $RepoRoot "scripts\selftest_all.ps1"

# -------------------------
# docs/SELFTEST_ProteusOps_v0_1.md (FULL REWRITE)
# NOTE: do NOT parse-gate markdown with PowerShell parser.
# -------------------------
$docLines = New-Object System.Collections.Generic.List[string]

[void]$docLines.Add('# SELFTEST — ProteusOps v0.1 (Storefront + Booking)')
[void]$docLines.Add('')
[void]$docLines.Add('## Purpose (Tier-0 proof)')
[void]$docLines.Add('')
[void]$docLines.Add('Prove (deterministically) that ProteusOps enforces:')
[void]$docLines.Add('')
[void]$docLines.Add('- Billing entitlements in the database (no UI tricks)')
[void]$docLines.Add('- Feature gating in the database (booking_enabled + paid_active)')
[void]$docLines.Add('- Booking integrity in the database (availability / overlap / time-off with stable failure tokens)')
[void]$docLines.Add('- “No direct writes” posture for booking tables (RPC-only surfaces)')
[void]$docLines.Add('')
[void]$docLines.Add('This selftest is a proof-run, not a product UX.')
[void]$docLines.Add('')
[void]$docLines.Add('---')
[void]$docLines.Add('')
[void]$docLines.Add('## Important Note (Supabase SQL Editor)')
[void]$docLines.Add('')
[void]$docLines.Add('Supabase SQL Editor runs without an authenticated user context:')
[void]$docLines.Add('')
[void]$docLines.Add('- auth.uid() is null')
[void]$docLines.Add('- auth.role() is typically not authenticated')
[void]$docLines.Add('- Any RPC that requires auth.uid() will raise AUTH_REQUIRED')
[void]$docLines.Add('')
[void]$docLines.Add('Therefore the official Tier-0 selftest path for authenticated behavior is Node scripts, not SQL Editor.')
[void]$docLines.Add('')
[void]$docLines.Add('---')
[void]$docLines.Add('')
[void]$docLines.Add('## Canonical Selftest Entry Points')
[void]$docLines.Add('')
[void]$docLines.Add('A) Authenticated selftest (positive booking gates)')
[void]$docLines.Add('- node selftest_booking.js')
[void]$docLines.Add('')
[void]$docLines.Add('B) Service-role selftest (plan flip → BOOKING_DISABLED → restore)')
[void]$docLines.Add('- node selftest_booking_disabled.js')
[void]$docLines.Add('')
[void]$docLines.Add('C) One-command FULL_GREEN runner')
[void]$docLines.Add('- powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File scripts\selftest_all.ps1')
[void]$docLines.Add('')
[void]$docLines.Add('---')
[void]$docLines.Add('')
[void]$docLines.Add('## Preconditions')
[void]$docLines.Add('')
[void]$docLines.Add('### Environment variables (Process env)')
[void]$docLines.Add('')
[void]$docLines.Add('Required for Node tests:')
[void]$docLines.Add('')
[void]$docLines.Add('- SUPABASE_URL')
[void]$docLines.Add('- SUPABASE_ANON_KEY')
[void]$docLines.Add('- SUPABASE_SERVICE_ROLE_KEY (only needed for selftest_booking_disabled.js)')
[void]$docLines.Add('- TEST_EMAIL')
[void]$docLines.Add('- TEST_PASSWORD')
[void]$docLines.Add('')
[void]$docLines.Add('### Database state')
[void]$docLines.Add('')
[void]$docLines.Add('- Migrations applied through the public surfaces you are testing.')
[void]$docLines.Add('- Required plan rows exist in pods.plan_tiers: proteusops_s_v1, proteusops_sb_v1')
[void]$docLines.Add('- Required plan capabilities exist in pods.plan_capabilities:')
[void]$docLines.Add('  - storefront_enabled=true for both plans')
[void]$docLines.Add('  - booking_enabled=false for S')
[void]$docLines.Add('  - booking_enabled=true for SB')
[void]$docLines.Add('- Org exists and has an active/trialing subscription row in pods.subscriptions')
[void]$docLines.Add('- Entitlements recompute works and materializes plan capabilities into pods.org_entitlements')
[void]$docLines.Add('')
[void]$docLines.Add('### Public RPC exposure (PostgREST)')
[void]$docLines.Add('')
[void]$docLines.Add('Authenticated wrappers in public:')
[void]$docLines.Add('- public.rpc_selftest_reset_booking_v1(uuid, uuid)')
[void]$docLines.Add('- public.rpc_upsert_availability_rule_v1(...)')
[void]$docLines.Add('- public.rpc_create_appointment_v1(...)')
[void]$docLines.Add('- public.rpc_add_time_off_block_v1(...)')
[void]$docLines.Add('')
[void]$docLines.Add('Service-role-only wrappers in public:')
[void]$docLines.Add('- public.rpc_selftest_set_subscription_plan_v1(uuid, text, text)')
[void]$docLines.Add('- public.rpc_recompute_entitlements(uuid)')
[void]$docLines.Add('')
[void]$docLines.Add('---')
[void]$docLines.Add('')
[void]$docLines.Add('## Expected tokens')
[void]$docLines.Add('')
[void]$docLines.Add('selftest_booking.js (positive path):')
[void]$docLines.Add('- SELFTEST_RESET_OK')
[void]$docLines.Add('- AVAILABILITY_OK')
[void]$docLines.Add('- APPOINTMENT_CREATE_OK')
[void]$docLines.Add('- OVERLAP_TEST_EXPECTED_FAIL token=APPOINTMENT_OVERLAP')
[void]$docLines.Add('- TIMEOFF_OK')
[void]$docLines.Add('- TIMEOFF_TEST_EXPECTED_FAIL token=STAFF_TIME_OFF_BLOCK')
[void]$docLines.Add('- SELFTEST_DONE')
[void]$docLines.Add('')
[void]$docLines.Add('selftest_booking_disabled.js (negative plan flip):')
[void]$docLines.Add('- PLAN_FLIP_OK plan_id=proteusops_s_v1 recompute=ok')
[void]$docLines.Add('- BOOKING_DISABLED_TEST_EXPECTED_FAIL token=BOOKING_DISABLED')
[void]$docLines.Add('- PLAN_RESTORE_OK plan_id=proteusops_sb_v1 recompute=ok')
[void]$docLines.Add('- SELFTEST_DONE')

Write-Utf8NoBomLf $DocPath ((@($docLines.ToArray()) -join "`n") + "`n")
Assert-Utf8NoBomLfFile $DocPath
Write-Host ("WROTE+DOC_UTF8_LF_OK: " + $DocPath) -ForegroundColor Green

# -------------------------
# scripts/selftest_all.ps1 (runner)
# -------------------------
$runLines = New-Object System.Collections.Generic.List[string]
[void]$runLines.Add('$ErrorActionPreference="Stop"')
[void]$runLines.Add('Set-StrictMode -Version Latest')
[void]$runLines.Add('')
[void]$runLines.Add('function Die([string]$m){ throw $m }')
[void]$runLines.Add('')
[void]$runLines.Add('$RepoRoot = (Resolve-Path -LiteralPath ".").Path')
[void]$runLines.Add('')
[void]$runLines.Add('# require env vars (Process env)')
[void]$runLines.Add('$need = @("SUPABASE_URL","SUPABASE_ANON_KEY","SUPABASE_SERVICE_ROLE_KEY","TEST_EMAIL","TEST_PASSWORD")')
[void]$runLines.Add('foreach($k in $need){')
[void]$runLines.Add('  $v = [Environment]::GetEnvironmentVariable($k,"Process")')
[void]$runLines.Add('  if([string]::IsNullOrWhiteSpace($v)){ Die ("MISSING_ENV_" + $k) }')
[void]$runLines.Add('}')
[void]$runLines.Add('')
[void]$runLines.Add('$node = (Get-Command node.exe -ErrorAction Stop).Source')
[void]$runLines.Add('')
[void]$runLines.Add('function RunNode([string]$rel){')
[void]$runLines.Add('  $p = Join-Path $RepoRoot $rel')
[void]$runLines.Add('  if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ Die ("MISSING_FILE: " + $p) }')
[void]$runLines.Add('  Write-Host ("RUN: node " + $rel) -ForegroundColor Cyan')
[void]$runLines.Add('  & $node $p | Out-Host')
[void]$runLines.Add('  if($LASTEXITCODE -ne 0){ Die ("NODE_FAIL: " + $rel + " exit=" + $LASTEXITCODE) }')
[void]$runLines.Add('}')
[void]$runLines.Add('')
[void]$runLines.Add('RunNode "selftest_booking.js"')
[void]$runLines.Add('RunNode "selftest_booking_disabled.js"')
[void]$runLines.Add('')
[void]$runLines.Add('Write-Host "FULL_GREEN_SELFTEST_OK" -ForegroundColor Green')

Write-Utf8NoBomLf $RunPath ((@($runLines.ToArray()) -join "`n") + "`n")
Parse-GatePs1 $RunPath
Write-Host ("WROTE+RUNNER_PARSE_OK: " + $RunPath) -ForegroundColor Green

Write-Host "PATCH_V2_OK" -ForegroundColor Green
