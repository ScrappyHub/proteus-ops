begin;

-- ORGS: block all writes (clients)
drop policy if exists orgs_no_write on pods.orgs;
create policy orgs_no_write
on pods.orgs
for all
to authenticated
using (false)
with check (false);

-- ORG_MEMBERS: block all writes (clients)
drop policy if exists org_members_no_write on pods.org_members;
create policy org_members_no_write
on pods.org_members
for all
to authenticated
using (false)
with check (false);

-- ROLES: block all writes
drop policy if exists roles_no_write on pods.roles;
create policy roles_no_write
on pods.roles
for all
to anon, authenticated
using (false)
with check (false);

-- ROLE_PERMISSIONS: block all writes
drop policy if exists role_perms_no_write on pods.role_permissions;
create policy role_perms_no_write
on pods.role_permissions
for all
to anon, authenticated
using (false)
with check (false);

-- PLAN_TIERS: block all writes
drop policy if exists plan_tiers_no_write on pods.plan_tiers;
create policy plan_tiers_no_write
on pods.plan_tiers
for all
to anon, authenticated
using (false)
with check (false);

-- PLAN_CAPABILITIES: block all writes
drop policy if exists plan_caps_no_write on pods.plan_capabilities;
create policy plan_caps_no_write
on pods.plan_capabilities
for all
to anon, authenticated
using (false)
with check (false);

-- ORG_ENTITLEMENTS: block all writes
drop policy if exists org_entitlements_no_write on pods.org_entitlements;
create policy org_entitlements_no_write
on pods.org_entitlements
for all
to authenticated
using (false)
with check (false);

-- ENTITLEMENT_OVERRIDES: block all writes
drop policy if exists entitlement_overrides_no_write on pods.entitlement_overrides;
create policy entitlement_overrides_no_write
on pods.entitlement_overrides
for all
to authenticated
using (false)
with check (false);

-- BILLING_ACCOUNTS: block all writes
drop policy if exists billing_accounts_no_write on pods.billing_accounts;
create policy billing_accounts_no_write
on pods.billing_accounts
for all
to authenticated
using (false)
with check (false);

-- SUBSCRIPTIONS: block all writes
drop policy if exists subscriptions_no_write on pods.subscriptions;
create policy subscriptions_no_write
on pods.subscriptions
for all
to authenticated
using (false)
with check (false);

-- USAGE_COUNTERS: block all writes
drop policy if exists usage_counters_no_write on pods.usage_counters;
create policy usage_counters_no_write
on pods.usage_counters
for all
to authenticated
using (false)
with check (false);

-- AUDIT_LOG: block all writes
drop policy if exists audit_no_write on pods.audit_log;
create policy audit_no_write
on pods.audit_log
for all
to authenticated
using (false)
with check (false);

-- MODELS: block all writes
drop policy if exists models_no_write on pods.models;
create policy models_no_write
on pods.models
for all
to anon, authenticated
using (false)
with check (false);

-- ORG_MODELS: block all writes
drop policy if exists org_models_no_write on pods.org_models;
create policy org_models_no_write
on pods.org_models
for all
to authenticated
using (false)
with check (false);

-- MIGRATION_LEDGER: block all writes
drop policy if exists migration_ledger_no_write on pods.migration_ledger;
create policy migration_ledger_no_write
on pods.migration_ledger
for all
to authenticated
using (false)
with check (false);

commit;