begin;

-- Any policies in 006 that used: "for insert, update, delete"
-- must be replaced with a valid single cmd. We use FOR ALL.

-- Profiles write
drop policy if exists storefront_profiles_write on pods.storefront_profiles;
create policy storefront_profiles_write
on pods.storefront_profiles
for all
to authenticated
using (
  exists (
    select 1 from pods.org_members m
    where m.org_id = pods.storefront_profiles.org_id
      and m.user_id = auth.uid()
      and m.role_key in ('owner','admin')
  )
  and pods.has_cap_bool(pods.storefront_profiles.org_id,'storefront_enabled') = true
)
with check (
  exists (
    select 1 from pods.org_members m
    where m.org_id = pods.storefront_profiles.org_id
      and m.user_id = auth.uid()
      and m.role_key in ('owner','admin')
  )
  and pods.has_cap_bool(pods.storefront_profiles.org_id,'storefront_enabled') = true
);

-- Locations write
drop policy if exists storefront_locations_write on pods.storefront_locations;
create policy storefront_locations_write
on pods.storefront_locations
for all
to authenticated
using (
  exists (
    select 1 from pods.org_members m
    where m.org_id = pods.storefront_locations.org_id
      and m.user_id = auth.uid()
      and m.role_key in ('owner','admin')
  )
  and pods.has_cap_bool(pods.storefront_locations.org_id,'storefront_enabled') = true
)
with check (
  exists (
    select 1 from pods.org_members m
    where m.org_id = pods.storefront_locations.org_id
      and m.user_id = auth.uid()
      and m.role_key in ('owner','admin')
  )
  and pods.has_cap_bool(pods.storefront_locations.org_id,'storefront_enabled') = true
);

-- Team write
drop policy if exists storefront_team_write on pods.storefront_team_members;
create policy storefront_team_write
on pods.storefront_team_members
for all
to authenticated
using (
  exists (
    select 1 from pods.org_members m
    where m.org_id = pods.storefront_team_members.org_id
      and m.user_id = auth.uid()
      and m.role_key in ('owner','admin')
  )
  and pods.has_cap_bool(pods.storefront_team_members.org_id,'storefront_enabled') = true
)
with check (
  exists (
    select 1 from pods.org_members m
    where m.org_id = pods.storefront_team_members.org_id
      and m.user_id = auth.uid()
      and m.role_key in ('owner','admin')
  )
  and pods.has_cap_bool(pods.storefront_team_members.org_id,'storefront_enabled') = true
);

-- Service categories write
drop policy if exists storefront_service_categories_write on pods.storefront_service_categories;
create policy storefront_service_categories_write
on pods.storefront_service_categories
for all
to authenticated
using (
  exists (
    select 1 from pods.org_members m
    where m.org_id = pods.storefront_service_categories.org_id
      and m.user_id = auth.uid()
      and m.role_key in ('owner','admin')
  )
  and pods.has_cap_bool(pods.storefront_service_categories.org_id,'storefront_enabled') = true
)
with check (
  exists (
    select 1 from pods.org_members m
    where m.org_id = pods.storefront_service_categories.org_id
      and m.user_id = auth.uid()
      and m.role_key in ('owner','admin')
  )
  and pods.has_cap_bool(pods.storefront_service_categories.org_id,'storefront_enabled') = true
);

-- Services write
drop policy if exists storefront_services_write on pods.storefront_services;
create policy storefront_services_write
on pods.storefront_services
for all
to authenticated
using (
  exists (
    select 1 from pods.org_members m
    where m.org_id = pods.storefront_services.org_id
      and m.user_id = auth.uid()
      and m.role_key in ('owner','admin')
  )
  and pods.has_cap_bool(pods.storefront_services.org_id,'storefront_enabled') = true
)
with check (
  exists (
    select 1 from pods.org_members m
    where m.org_id = pods.storefront_services.org_id
      and m.user_id = auth.uid()
      and m.role_key in ('owner','admin')
  )
  and pods.has_cap_bool(pods.storefront_services.org_id,'storefront_enabled') = true
);

-- Contact requests: keep as "no write" (already correct if it used FOR ALL)
drop policy if exists storefront_contact_no_write on pods.storefront_contact_requests;
create policy storefront_contact_no_write
on pods.storefront_contact_requests
for all
to authenticated
using (false)
with check (false);

commit;