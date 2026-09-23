// ProteusOps — GitHub discovery sync (H3). Lists the repositories each connected GitHub account can see and
// reconciles them into the hub resource inventory (new -> added, gone -> marked missing), then marks the API
// credential verified (or invalid on 401/403). Uses hub credentials with purpose "api" (a fine-grained,
// read-only GitHub token stored in Vault). Caller must be the service role (Supabase verifies the JWT).
// Deploy: supabase functions deploy github-sync      (JWT verification ON)
// Invoke: POST with Authorization: Bearer <service_role key>   body: {} or {"account_id":"<uuid>"}
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json" } });

function jwtRole(req: Request): string | null {
  const tok = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const part = tok.split(".")[1];
  if (!part) return null;
  try { return JSON.parse(atob(part.replace(/-/g, "+").replace(/_/g, "/")))?.role ?? null; } catch { return null; }
}

async function gh(token: string, url: string) {
  return await fetch(url, { headers: { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "ProteusOps-Hub" } });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  if (jwtRole(req) !== "service_role") return new Response("forbidden", { status: 403 }); // gateway already verified the signature
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false } });
  let only: string | null = null;
  try { only = (await req.json())?.account_id ?? null; } catch { /* empty body */ }

  const { data: targets, error } = await sb.rpc("svc_hub_sync_targets_v1", { p_provider_key: "github" });
  if (error) return json({ error: error.message }, 500);
  const results: unknown[] = [];
  for (const t of (targets ?? []) as any[]) {
    if (only && t.account_id !== only) continue;
    const { data: token, error: se } = await sb.rpc("svc_hub_credential_secret_v1",
      { p_credential_id: t.credential_id, p_purpose_of_use: "github repository discovery" });
    if (se || typeof token !== "string") { results.push({ account_id: t.account_id, error: "credential unavailable" }); continue; }

    const owner = String(t.external_ref ?? "").trim();
    const first = owner ? `https://api.github.com/orgs/${encodeURIComponent(owner)}/repos?per_page=100&type=all`
                        : `https://api.github.com/user/repos?per_page=100&affiliation=owner,organization_member`;
    let url: string | null = first; const items: unknown[] = []; let status = 200; let pages = 0;
    while (url && pages < 20) {
      let r = await gh(token, url);
      if (r.status === 404 && owner && pages === 0) {   // external_ref is a user, not an org
        url = `https://api.github.com/users/${encodeURIComponent(owner)}/repos?per_page=100&type=owner`; r = await gh(token, url);
      }
      status = r.status;
      if (!r.ok) break;
      for (const repo of await r.json()) {
        items.push({ kind: "repo", external_id: repo.full_name, display_name: repo.full_name,
          attributes: { private: repo.private, archived: repo.archived, default_branch: repo.default_branch,
                        visibility: repo.visibility, html_url: repo.html_url, pushed_at: repo.pushed_at } });
      }
      const next = /<([^>]+)>;\s*rel="next"/.exec(r.headers.get("link") ?? "");
      url = next ? next[1] : null; pages++;
    }
    if (status === 401 || status === 403) {
      await sb.rpc("svc_hub_credential_mark_verified_v1", { p_credential_id: t.credential_id, p_ok: false, p_detail: `github api ${status}` });
      results.push({ account_id: t.account_id, error: `github ${status}` }); continue;
    }
    if (status !== 200) { results.push({ account_id: t.account_id, error: `github ${status}` }); continue; }
    const { data: sync, error: ye } = await sb.rpc("svc_hub_resource_sync_v1", { p_account_id: t.account_id, p_items: items });
    if (ye) { results.push({ account_id: t.account_id, error: ye.message }); continue; }
    await sb.rpc("svc_hub_credential_mark_verified_v1", { p_credential_id: t.credential_id, p_ok: true, p_detail: `github api ok, ${items.length} repos` });
    results.push({ account_id: t.account_id, repos: items.length, sync });
  }
  return json({ ok: true, results });
});
