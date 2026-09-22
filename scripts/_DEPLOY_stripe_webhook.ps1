$ErrorActionPreference = "Continue"
Set-Location "C:\dev\proteusops"
Write-Host ">>> Deploying the stripe-webhook edge function to hosted..."
# --no-verify-jwt: Stripe calls without a Supabase JWT; auth is the Stripe signature check inside the function.
supabase functions deploy stripe-webhook --project-ref ytwjyemqlbbebysiopzd --no-verify-jwt
Write-Host (">>> deploy exit code: " + $LASTEXITCODE + " <<<")
Write-Host ">>> Function URL: https://ytwjyemqlbbebysiopzd.functions.supabase.co/stripe-webhook"
