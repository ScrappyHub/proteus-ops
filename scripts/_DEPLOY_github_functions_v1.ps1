# Deploy the GitHub hub adapters to hosted.
$ErrorActionPreference = "Continue"
Set-Location "C:\dev\proteusops"
Write-Host ">>> github-webhook (no JWT: GitHub authenticates with the per-account HMAC secret)"
supabase functions deploy github-webhook --no-verify-jwt
Write-Host (">>> exit " + $LASTEXITCODE)
Write-Host ">>> github-sync (JWT required; service role only)"
supabase functions deploy github-sync
Write-Host (">>> exit " + $LASTEXITCODE)
Write-Host ">>> Webhook URL: https://ytwjyemqlbbebysiopzd.functions.supabase.co/github-webhook?account=<hub account_id>"
