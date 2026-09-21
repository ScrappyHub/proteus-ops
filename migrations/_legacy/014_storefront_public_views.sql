begin;

-- Public storefront view (only active orgs)
create or replace view pods.public_storefront_profile_v1 as
select
  o.slug,
  o.name as org_name,
  p.display_name,
  p.tagline,
  p.description,
  p.website_url,
  p.phone,
  p.email
from pods.orgs o
join pods.storefront_profiles p on p.org_id = o.org_id
where o.is_active = true;

-- Public locations (active only)
create or replace view pods.public_storefront_locations_v1 as
select
  o.slug,
  l.location_id,
  l.name,
  l.address_line1,
  l.address_line2,
  l.city,
  l.region,
  l.postal_code,
  l.country,
  l.latitude,
  l.longitude,
  l.hours_json
from pods.orgs o
join pods.storefront_locations l on l.org_id = o.org_id
where o.is_active = true and l.is_active = true;

-- Public team (active only)
create or replace view pods.public_storefront_team_v1 as
select
  o.slug,
  t.team_member_id,
  t.display_name,
  t.role_title,
  t.bio,
  t.photo_url,
  t.sort_order
from pods.orgs o
join pods.storefront_team_members t on t.org_id = o.org_id
where o.is_active = true and t.is_active = true;

-- Public services (active only)
create or replace view pods.public_storefront_services_v1 as
select
  o.slug,
  s.service_id,
  s.name,
  s.description,
  s.price_cents,
  s.duration_mins,
  s.sort_order,
  c.name as category_name
from pods.orgs o
join pods.storefront_services s on s.org_id = o.org_id
left join pods.storefront_service_categories c on c.category_id = s.category_id
where o.is_active = true and s.is_active = true;

-- Grant public read
grant select on pods.public_storefront_profile_v1 to anon, authenticated;
grant select on pods.public_storefront_locations_v1 to anon, authenticated;
grant select on pods.public_storefront_team_v1 to anon, authenticated;
grant select on pods.public_storefront_services_v1 to anon, authenticated;

commit;