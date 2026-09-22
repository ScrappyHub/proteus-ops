$ErrorActionPreference = "Continue"
Set-Location "C:\dev\proteusops"
Write-Host ">>> Deploying the stripe-webhook edge function to hosted..."
supabase functions deploy stripe-webhook --project-ref ytwjyemqlbbebysiopzd
Write-Host (">>> deploy exit code: " + $LASTEXITCODE + " <<<")
Write-Host ">>> Function URL: https://ytwjyemqlbbebysiopzd.functions.supabase.co/stripe-webhook"
