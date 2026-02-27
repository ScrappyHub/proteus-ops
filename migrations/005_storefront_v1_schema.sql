begin;

-- -------------------------------
-- ProteusOps: Storefront Model v1
-- Depends: pods.core.v1
-- -------------------------------

create table if not exists pods.storefront_profiles (
  org_id        uuid primary key references pods.orgs(org_id) on delete cascade,
  display_name  text not null,
  tagline       text null,
  description   text null,
  website_url   text null,
  phone         text null,
  email         text null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table if not exists pods.storefront_locations (
  location_id   uuid primary key default gen_random_uuid(),
  org_id        uuid not null references pods.orgs(org_id) on delete cascade,
  name          text not null,
  address_line1 text null,
  address_line2 text null,
  city          text null,
  region        text null,
  postal_code   text null,
  country       text null,
  latitude      numeric null,
  longitude     numeric null,
  hours_json    jsonb not null default '{}'::jsonb, -- simple structured hours
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);

create index if not exists storefront_locations_org_idx
  on pods.storefront_locations(org_id);

create table if not exists pods.storefront_team_members (
  team_member_id uuid primary key default gen_random_uuid(),
  org_id         uuid not null references pods.orgs(org_id) on delete cascade,
  display_name   text not null,
  role_title     text null,
  bio            text null,
  photo_url      text null,
  sort_order     int not null default 0,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now()
);

create index if not exists storefront_team_org_idx
  on pods.storefront_team_members(org_id);

create table if not exists pods.storefront_service_categories (
  category_id   uuid primary key default gen_random_uuid(),
  org_id        uuid not null references pods.orgs(org_id) on delete cascade,
  name          text not null,
  sort_order    int not null default 0,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  unique (org_id, name)
);

create index if not exists storefront_service_cat_org_idx
  on pods.storefront_service_categories(org_id);

create table if not exists pods.storefront_services (
  service_id     uuid primary key default gen_random_uuid(),
  org_id         uuid not null references pods.orgs(org_id) on delete cascade,
  category_id    uuid null references pods.storefront_service_categories(category_id) on delete set null,
  name           text not null,
  description    text null,
  price_cents    int null,
  duration_mins  int null, -- allowed in storefront even if booking not installed yet
  is_active      boolean not null default true,
  sort_order     int not null default 0,
  created_at     timestamptz not null default now(),
  unique (org_id, name)
);

create index if not exists storefront_services_org_idx
  on pods.storefront_services(org_id);

-- Contact / inquiry capture (no “UI tricks”: this is just data)
create table if not exists pods.storefront_contact_requests (
  contact_request_id uuid primary key default gen_random_uuid(),
  org_id             uuid not null references pods.orgs(org_id) on delete cascade,
  name               text null,
  email              text null,
  phone              text null,
  message            text not null,
  status             text not null default 'new', -- new|read|archived
  created_at         timestamptz not null default now()
);

create index if not exists storefront_contact_org_idx
  on pods.storefront_contact_requests(org_id);

-- Register model (global registry)
insert into pods.models(model_id, version, depends_on, is_active)
values ('pods.storefront','1.0.0', jsonb_build_array('pods.core@1.0.0'), true)
on conflict (model_id, version) do nothing;

commit;