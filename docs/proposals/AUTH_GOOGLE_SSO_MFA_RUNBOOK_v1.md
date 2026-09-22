# Runbook — Google SSO + MFA (operator steps)

- Status: PROPOSED. DB enforcement primitives are staged (migration
  20260921212500_session_assurance_v1). The steps below are performed by the OPERATOR in
  provider dashboards; all secrets stay there / in env, never in git.

## 1. Google sign-in (Supabase Auth)
1. Google Cloud Console -> APIs & Services -> Credentials -> Create OAuth client ID (Web).
2. Authorized redirect URI: https://ytwjyemqlbbebysiopzd.supabase.co/auth/v1/callback
   (add local/staging callback URLs as needed).
3. Copy the Client ID and Client Secret.
4. Supabase Dashboard -> Authentication -> Providers -> Google: enable, paste Client ID +
   Secret, save. (Secret lives here, not in the repo.)
5. Set Site URL and Additional Redirect URLs for each environment.

## 2. MFA / TOTP (Supabase Auth)
1. Supabase Dashboard -> Authentication -> Multi-Factor -> enable TOTP.
2. App: implement enrollment (supabase.auth.mfa.enroll/challenge/verify) and require it for
   privileged roles; a session that has passed a TOTP challenge carries aal = "aal2".

## 3. How enforcement works (DB side, already staged)
- pods_core.require_authenticated(): rejects end-user calls lacking a subject.
- pods_core.require_aal2(): rejects end-user calls whose JWT aal is not "aal2" (i.e. no MFA).
- service_role and trusted direct/backend callers (no JWT claims) bypass, so backend jobs and
  SECURITY DEFINER internals are unaffected.
- Usage: privileged/admin/billing RPCs call `perform pods_core.require_aal2();` first.
  (Which RPCs to gate is enumerated in a follow-up slice.)
- Selftest pods_core.rpc_selftest_session_assurance_v1() proves aal1 blocked, aal2 allowed,
  service_role allowed, anon blocked.

## 4. Verification (once configured)
- Non-prod: sign in with Google, enroll TOTP, confirm session aal becomes aal2, confirm a
  gated RPC succeeds only after MFA and fails (PROTEUSOPS_MFA_REQUIRED) before it.
