-- pods.core.v1 — RLS + grants + service-role-only surfaces
begin;

-- Enable RLS everywhere in pods schema tables
alter table pods.orgs enable row level security;
alter table pods.org_members enable row level security;
alter table pods.roles enable row level security;
alter table pods.role_permissions enable row level security;

alter table pods.billing_accounts enable row level security;
alter table pods.subscriptions enable row level security;
alter table pods.plan_tiers enable row level security;
alter table pods.plan_capabilities enable row level security;
alter table pods.entitlement_overrides enable row level security;
alter table pods.org_entitlements enable row level security;
alter table pods.usage_counters enable row level security;
alter table pods.audit_log enable row level security;

alter table pods.models enable row level security;
alter table pods.org_models enable row level security;
alter table pods.migration_ledger enable row level security;

-- -------------------------------------------------------------------
-- RLS POLICIES
-- Conservative v1:
-- - members can read their org + their membership
-- - billing tables: read only by org owner/admin (optional), writes only service role
-- - plan tables: readable by authenticated (so UI can show plan features); no writes except service role/migrations
-- - audit log: org owner/admin can read
-- -------------------------------------------------------------------

-- orgs: member can read org row
drop policy if exists orgs_select_member on pods.orgs;
create policy orgs_select_member
on pods.orgs
for select
to authenticated
using (
  exists (
    select 1 from pods.org_members m
    where m.org_id = pods.orgs.org_id
      and m.user_id = auth.uid()
  )
);

-- orgs: no direct insert/update/delete from clients (create org via RPC later if desired)
drop policy if exists orgs_no_write on pods.orgs;
create policy orgs_no_write
on pods.orgs
for all
to authenticated
using (false)
with check (false);

-- org_members: member can read their memberships (and owners/admins can read all members in org)
drop policy if exists org_members_select on pods.org_members;
create policy org_members_select
on pods.org_members
for select
to authenticated
using (
  pods.org_members.user_id = auth.uid()
  or exists (
    select 1
    from pods.org_members me
    where me.org_id = pods.org_members.org_id
      and me.user_id = auth.uid()
      and me.role_key in ('owner','admin')
  )
);

-- org_members: block direct writes (manage via RPC later)
drop policy if exists org_members_no_write on pods.org_members;
create policy org_members_no_write
on pods.org_members
for insert, update, delete
to authenticated
using (false)
with check (false);

-- roles + role_permissions: readable; no client writes
drop policy if exists roles_read on pods.roles;
create policy roles_read
on pods.roles
for select
to anon, authenticated
using (true);

drop policy if exists roles_no_write on pods.roles;
create policy roles_no_write
on pods.roles
for insert, update, delete
to anon, authenticated
using (false)
with check (false);

drop policy if exists role_perms_read on pods.role_permissions;
create policy role_perms_read
on pods.role_permissions
for select
to anon, authenticated
using (true);

drop policy if exists role_perms_no_write on pods.role_permissions;
create policy role_perms_no_write
on pods.role_permissions
for insert, update, delete
to anon, authenticated
using (false)
with check (false);

-- plan tables: readable; writes blocked (handled by migrations/service)
drop policy if exists plan_tiers_read on pods.plan_tiers;
create policy plan_tiers_read
on pods.plan_tiers
for select
to anon, authenticated
using (true);

drop policy if exists plan_tiers_no_write on pods.plan_tiers;
create policy plan_tiers_no_write
on pods.plan_tiers
for insert, update, delete
to anon, authenticated
using (false)
with check (false);

drop policy if exists plan_caps_read on pods.plan_capabilities;
create policy plan_caps_read
on pods.plan_capabilities
for select
to anon, authenticated
using (true);

drop policy if exists plan_caps_no_write on pods.plan_capabilities;
create policy plan_caps_no_write
on pods.plan_capabilities
for insert, update, delete
to anon, authenticated
using (false)
with check (false);

-- entitlements: members can read org_entitlements
drop policy if exists org_entitlements_read on pods.org_entitlements;
create policy org_entitlements_read
on pods.org_entitlements
for select
to authenticated
using (
  exists (
    select 1 from pods.org_members m
    where m.org_id = pods.org_entitlements.org_id
      and m.user_id = auth.uid()
  )
);

-- entitlements: no direct writes by clients
drop policy if exists org_entitlements_no_write on pods.org_entitlements;
create policy org_entitlements_no_write
on pods.org_entitlements
for insert, update, delete
to authenticated
using (false)
with check (false);

-- entitlement overrides: owners/admins can read; writes blocked (manage via admin RPC later)
drop policy if exists entitlement_overrides_read on pods.entitlement_overrides;
create policy entitlement_overrides_read
on pods.entitlement_overrides
for select
to authenticated
using (
  exists (
    select 1 from pods.org_members m
    where m.org_id = pods.entitlement_overrides.org_id
      and m.user_id = auth.uid()
      and m.role_key in ('owner','admin')
  )
);

drop policy if exists entitlement_overrides_no_write on pods.entitlement_overrides;
create policy entitlement_overrides_no_write
on pods.entitlement_overrides
for insert, update, delete
to authenticated
using (false)
with check (false);

-- billing_accounts + subscriptions: owners/admins can read; no client writes
drop policy if exists billing_accounts_read on pods.billing_accounts;
create policy billing_accounts_read
on pods.billing_accounts
for select
to authenticated
using (
  exists (
    select 1 from pods.org_members m
    where m.org_id = pods.billing_accounts.org_id
      and m.user_id = auth.uid()
      and m.role_key in ('owner','admin')
  )
);

drop policy if exists billing_accounts_no_write on pods.billing_accounts;
create policy billing_accounts_no_write
on pods.billing_accounts
for insert, update, delete
to authenticated
using (false)
with check (false);

drop policy if exists subscriptions_read on pods.subscriptions;
create policy subscriptions_read
on pods.subscriptions
for select
to authenticated
using (
  exists (
    select 1 from pods.org_members m
    where m.org_id = pods.subscriptions.org_id
      and m.user_id = auth.uid()
      and m.role_key in ('owner','admin')
  )
);

drop policy if exists subscriptions_no_write on pods.subscriptions;
create policy subscriptions_no_write
on pods.subscriptions
for insert, update, delete
to authenticated
using (false)
with check (false);

-- usage counters: owners/admins can read; no direct writes by clients
drop policy if exists usage_counters_read on pods.usage_counters;
create policy usage_counters_read
on pods.usage_counters
for select
to authenticated
using (
  exists (
    select 1 from pods.org_members m
    where m.org_id = pods.usage_counters.org_id
      and m.user_id = auth.uid()
      and m.role_key in ('owner','admin')
  )
);

drop policy if exists usage_counters_no_write on pods.usage_counters;
create policy usage_counters_no_write
on pods.usage_counters
for insert, update, delete
to authenticated
using (false)
with check (false);

-- audit log: owners/admins can read; no client writes
drop policy if exists audit_read on pods.audit_log;
create policy audit_read
on pods.audit_log
for select
to authenticated
using (
  pods.audit_log.org_id is null
  or exists (
    select 1 from pods.org_members m
    where m.org_id = pods.audit_log.org_id
      and m.user_id = auth.uid()
      and m.role_key in ('owner','admin')
  )
);

drop policy if exists audit_no_write on pods.audit_log;
create policy audit_no_write
on pods.audit_log
for insert, update, delete
to authenticated
using (false)
with check (false);

-- models + org_models + migration_ledger: readable by owners/admins; no client writes
drop policy if exists models_read on pods.models;
create policy models_read
on pods.models
for select
to anon, authenticated
using (true);

drop policy if exists models_no_write on pods.models;
create policy models_no_write
on pods.models
for insert, update, delete
to anon, authenticated
using (false)
with check (false);

drop policy if exists org_models_read on pods.org_models;
create policy org_models_read
on pods.org_models
for select
to authenticated
using (
  exists (
    select 1 from pods.org_members m
    where m.org_id = pods.org_models.org_id
      and m.user_id = auth.uid()
      and m.role_key in ('owner','admin')
  )
);

drop policy if exists org_models_no_write on pods.org_models;
create policy org_models_no_write
on pods.org_models
for insert, update, delete
to authenticated
using (false)
with check (false);

drop policy if exists migration_ledger_read on pods.migration_ledger;
create policy migration_ledger_read
on pods.migration_ledger
for select
to authenticated
using (
  exists (
    select 1 from pods.org_members m
    where m.org_id = pods.migration_ledger.org_id
      and m.user_id = auth.uid()
      and m.role_key in ('owner','admin')
  )
);

drop policy if exists migration_ledger_no_write on pods.migration_ledger;
create policy migration_ledger_no_write
on pods.migration_ledger
for insert, update, delete
to authenticated
using (false)
with check (false);

-- -------------------------------------------------------------------
-- FUNCTION EXECUTION GRANTS
-- rpc_recompute_entitlements must not be callable by anon/authenticated
-- (call it from server-side / service role / internal jobs).
-- We'll explicitly revoke and then you grant it to service_role in Supabase.
-- -------------------------------------------------------------------

revoke all on function pods.rpc_recompute_entitlements(uuid) from public;
revoke all on function pods.rpc_recompute_entitlements(uuid) from anon;
revoke all on function pods.rpc_recompute_entitlements(uuid) from authenticated;

-- We cannot GRANT to service_role directly in pure SQL migrations in some setups,
-- but in Supabase you can:
--   grant execute on function pods.rpc_recompute_entitlements(uuid) to service_role;

commit;