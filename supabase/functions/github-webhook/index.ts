// ProteusOps — GitHub webhook adapter (H3). One endpoint for every workspace:
//   POST https://<project>.functions.supabase.co/github-webhook?account=<hub account_id>
// The GitHub webhook secret is a hub credential (purpose "webhook", storage vault) on that account; it is read
// server-side through the audited svc_hub_credential_secret_v1 and never leaves the function.
// Deploy: supabase functions deploy github-webhook --no-verify-jwt   (GitHub cannot send a Supabase JWT;
//         authenticity is the HMAC X-Hub-Signature-256 check below)
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const enc = new TextEncoder();
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_BODY = 2_000_000;
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json" } });
const clip = (s: unknown, n = 140) => (typeof s === "string" ? s.split("\n")[0].slice(0, n) : "");

async function hmacHex(secret: string, msg: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, enc.encode(msg));
  return Array.from(new Uint8Array(mac)).map((b) => b.toString(16).padStart(2, "0")).join("");
}
function safeEq(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

type Ev = { change_type: string; severity?: string; summary: string; actor?: string; url?: string;
  resource_kind?: string; resource_external_id?: string; details?: Record<string, unknown>; occurred_at?: string };

function mapEvent(name: string, p: any): Ev | null {
  const repo = p?.repository?.full_name as string | undefined;
  const actor = p?.sender?.login as string | undefined;
  const base = { actor, resource_kind: repo ? "repo" : undefined, resource_external_id: repo };
  switch (name) {
    case "push": {
      if (p.deleted) return { ...base, change_type: "repo.branch_deleted", severity: "notice", summary: `${repo}: ${p.ref} deleted`, url: p.compare };
      const n = Array.isArray(p.commits) ? p.commits.length : 0;
      const branch = String(p.ref ?? "").replace("refs/heads/", "");
      const forced = p.forced ? " (force-push)" : "";
      return { ...base, change_type: p.forced ? "repo.force_push" : "repo.push", severity: p.forced ? "warning" : "info",
        summary: `${repo}: ${n} commit(s) to ${branch}${forced}`, url: p.compare,
        details: { branch, commits: n, head: clip(p.head_commit?.id, 40) }, occurred_at: p.head_commit?.timestamp };
    }
    case "pull_request": {
      const pr = p.pull_request ?? {};
      const act = pr.merged && p.action === "closed" ? "merged" : p.action;
      if (!["opened", "closed", "merged", "reopened", "ready_for_review"].includes(act)) return null;
      return { ...base, change_type: `repo.pr_${act}`, summary: `${repo}: PR #${pr.number} ${act} — ${clip(pr.title, 100)}`,
        url: pr.html_url, details: { number: pr.number, base: pr.base?.ref, head: pr.head?.ref } };
    }
    case "release":
      if (!["published", "deleted"].includes(p.action)) return null;
      return { ...base, change_type: `repo.release_${p.action}`, severity: "notice",
        summary: `${repo}: release ${clip(p.release?.tag_name, 60)} ${p.action}`, url: p.release?.html_url };
    case "deployment_status": {
      const st = p.deployment_status?.state;
      if (!["success", "failure", "error"].includes(st)) return null;
      return { ...base, change_type: `deploy.${st}`, severity: st === "success" ? "info" : "warning",
        summary: `${repo}: deploy to ${clip(p.deployment?.environment, 60)} ${st}`, url: p.deployment_status?.target_url || undefined,
        details: { environment: p.deployment?.environment, sha: clip(p.deployment?.sha, 40) } };
    }
    case "workflow_run": {
      if (p.action !== "completed") return null;
      const c = p.workflow_run?.conclusion;
      if (c === "success" || c === "skipped") return null;
      return { ...base, change_type: `ci.${c}`, severity: "warning",
        summary: `${repo}: workflow ${clip(p.workflow_run?.name, 60)} ${c} on ${clip(p.workflow_run?.head_branch, 60)}`, url: p.workflow_run?.html_url };
    }
    case "repository":
      if (!["created", "deleted", "archived", "unarchived", "renamed", "transferred", "privatized", "publicized"].includes(p.action)) return null;
      return { ...base, change_type: `repo.${p.action}`, severity: ["deleted", "publicized", "transferred"].includes(p.action) ? "critical" : "notice",
        summary: `${repo}: repository ${p.action}`, url: p.repository?.html_url };
    case "branch_protection_rule":
      return { ...base, change_type: `repo.branch_protection_${p.action}`, severity: p.action === "deleted" ? "critical" : "warning",
        summary: `${repo}: branch protection ${clip(p.rule?.name, 60)} ${p.action}` };
    case "secret_scanning_alert":
    case "code_scanning_alert":
    case "dependabot_alert": {
      const sev = name === "secret_scanning_alert" ? "critical" : (p.alert?.security_advisory?.severity === "critical" || p.alert?.rule?.security_severity_level === "critical") ? "critical" : "warning";
      return { ...base, change_type: `security.${name.replace("_alert", "")}_${p.action}`, severity: sev,
        summary: `${repo}: ${name.replaceAll("_", " ")} ${p.action}`, url: p.alert?.html_url };
    }
    case "member":
    case "organization":
    case "team":
      return { actor, change_type: `access.${name}_${p.action}`, severity: "warning",
        summary: `${name} ${p.action}: ${clip(p.member?.login ?? p.membership?.user?.login ?? p.team?.name, 60)}` };
    default:
      return null;
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });
  const accountId = new URL(req.url).searchParams.get("account") ?? "";
  if (!UUID.test(accountId)) return new Response("unauthorized", { status: 401 });
  const body = await req.text();
  if (body.length > MAX_BODY) return new Response("payload too large", { status: 413 });
  const sig = req.headers.get("X-Hub-Signature-256") ?? "";
  const eventName = req.headers.get("X-GitHub-Event") ?? "";
  const delivery = req.headers.get("X-GitHub-Delivery") ?? "";
  if (!sig.startsWith("sha256=") || !eventName || !delivery) return new Response("unauthorized", { status: 401 });

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false } });
  const { data: target, error: te } = await sb.rpc("svc_hub_webhook_target_v1", { p_account_id: accountId, p_provider_key: "github" });
  if (te) { console.error("target error", te.message); return new Response("error", { status: 500 }); }
  if (!target?.found || !target?.credential_id) return new Response("unauthorized", { status: 401 }); // same answer: no oracle
  const { data: secret, error: se } = await sb.rpc("svc_hub_credential_secret_v1",
    { p_credential_id: target.credential_id, p_purpose_of_use: "github webhook signature check" });
  if (se || typeof secret !== "string") return new Response("unauthorized", { status: 401 });
  const expected = "sha256=" + (await hmacHex(secret, body));
  if (!safeEq(expected, sig)) return new Response("unauthorized", { status: 401 });

  let payload: any;
  try { payload = JSON.parse(body); } catch { return new Response("bad json", { status: 400 }); }

  if (eventName === "ping") {
    await sb.rpc("svc_hub_credential_mark_verified_v1", { p_credential_id: target.credential_id, p_ok: true,
      p_detail: `github ping ok (hook ${payload?.hook_id ?? "?"})` });
    return json({ ok: true, ping: true });
  }
  const ev = mapEvent(eventName, payload);
  if (!ev) return json({ ok: true, ignored: eventName });
  const { data, error } = await sb.rpc("svc_hub_change_ingest_v1", {
    p_account_id: accountId,
    p_events: [{ ...ev, dedupe_key: `gh:${delivery}`, source: "webhook", occurred_at: ev.occurred_at ?? new Date().toISOString() }],
  });
  if (error) { console.error("ingest error", eventName, delivery, error.message); return new Response("ingest error", { status: 500 }); }
  return json({ ok: true, event: eventName, result: data });
});
