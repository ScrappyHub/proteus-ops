begin;

alter table pods.storefront_profiles enable row level security;
alter table pods.storefront_locations enable row level security;
alter table pods.storefront_team_members enable row level security;
alter table pods.storefront_service_categories enable row level security;
alter table pods.storefront_services enable row level security;
alter table pods.storefront_contact_requests enable row level security;

-- Helper: org membership test inline (kept simple)
-- Public read is NOT enabled here yet; we’ll add a controlled “public view” later.

-- SELECT: any org member can read
create policy storefront_profiles_read
on pods.storefront_profiles
for select to authenticated
using (exists (select 1 from pods.org_members m where m.org_id = org_id and m.user_id = auth.uid()));

create policy storefront_locations_read
on pods.storefront_locations
for select to authenticated
using (exists (select 1 from pods.org_members m where m.org_id = org_id and m.user_id = auth.uid()));

create policy storefront_team_read
on pods.storefront_team_members
for select to authenticated
using (exists (select 1 from pods.org_members m where m.org_id = org_id and m.user_id = auth.uid()));

create policy storefront_service_categories_read
on pods.storefront_service_categories
for select to authenticated
using (exists (select 1 from pods.org_members m where m.org_id = org_id and m.user_id = auth.uid()));

create policy storefront_services_read
on pods.storefront_services
for select to authenticated
using (exists (select 1 from pods.org_members m where m.org_id = org_id and m.user_id = auth.uid()));

create policy storefront_contact_read
on pods.storefront_contact_requests
for select to authenticated
using (
  exists (
    select 1 from pods.org_members m
    where m.org_id = org_id and m.user_id = auth.uid()
      and m.role_key in ('owner','admin')
  )
);

-- WRITES: restrict to owner/admin and require entitlement storefront_enabled
create policy storefront_profiles_write
on pods.storefront_profiles
for insert, update, delete to authenticated
using (
  exists (
    select 1 from pods.org_members m
    where m.org_id = org_id and m.user_id = auth.uid() and m.role_key in ('owner','admin')
  )
  and pods.has_cap_bool(org_id,'storefront_enabled') = true
)
with check (
  exists (
    select 1 from pods.org_members m
    where m.org_id = org_id and m.user_id = auth.uid() and m.role_key in ('owner','admin')
  )
  and pods.has_cap_bool(org_id,'storefront_enabled') = true
);

create policy storefront_locations_write
on pods.storefront_locations
for insert, update, delete to authenticated
using (
  exists (select 1 from pods.org_members m where m.org_id = org_id and m.user_id = auth.uid() and m.role_key in ('owner','admin'))
  and pods.has_cap_bool(org_id,'storefront_enabled') = true
)
with check (
  exists (select 1 from pods.org_members m where m.org_id = org_id and m.user_id = auth.uid() and m.role_key in ('owner','admin'))
  and pods.has_cap_bool(org_id,'storefront_enabled') = true
);

create policy storefront_team_write
on pods.storefront_team_members
for insert, update, delete to authenticated
using (
  exists (select 1 from pods.org_members m where m.org_id = org_id and m.user_id = auth.uid() and m.role_key in ('owner','admin'))
  and pods.has_cap_bool(org_id,'storefront_enabled') = true
)
with check (
  exists (select 1 from pods.org_members m where m.org_id = org_id and m.user_id = auth.uid() and m.role_key in ('owner','admin'))
  and pods.has_cap_bool(org_id,'storefront_enabled') = true
);

create policy storefront_service_categories_write
on pods.storefront_service_categories
for insert, update, delete to authenticated
using (
  exists (select 1 from pods.org_members m where m.org_id = org_id and m.user_id = auth.uid() and m.role_key in ('owner','admin'))
  and pods.has_cap_bool(org_id,'storefront_enabled') = true
)
with check (
  exists (select 1 from pods.org_members m where m.org_id = org_id and m.user_id = auth.uid() and m.role_key in ('owner','admin'))
  and pods.has_cap_bool(org_id,'storefront_enabled') = true
);

create policy storefront_services_write
on pods.storefront_services
for insert, update, delete to authenticated
using (
  exists (select 1 from pods.org_members m where m.org_id = org_id and m.user_id = auth.uid() and m.role_key in ('owner','admin'))
  and pods.has_cap_bool(org_id,'storefront_enabled') = true
)
with check (
  exists (select 1 from pods.org_members m where m.org_id = org_id and m.user_id = auth.uid() and m.role_key in ('owner','admin'))
  and pods.has_cap_bool(org_id,'storefront_enabled') = true
);

-- Contact requests: public insert will be added later via a dedicated RPC (safer than anon table insert).
create policy storefront_contact_no_write
on pods.storefront_contact_requests
for insert, update, delete to authenticated
using (false)
with check (false);

commit;