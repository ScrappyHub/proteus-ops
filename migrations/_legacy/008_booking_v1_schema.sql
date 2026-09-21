begin;

-- -------------------------------
-- pods.booking v1.0.0
-- Depends: pods.core@1.0.0 + pods.storefront@1.0.0
-- -------------------------------

-- Customers (minimal; can be expanded later)
create table if not exists pods.booking_customers (
  customer_id   uuid primary key default gen_random_uuid(),
  org_id        uuid not null references pods.orgs(org_id) on delete cascade,
  user_id       uuid null, -- if authenticated customer; else null for guest
  display_name  text null,
  email         text null,
  phone         text null,
  created_at    timestamptz not null default now()
);

create index if not exists booking_customers_org_idx
  on pods.booking_customers(org_id);

create index if not exists booking_customers_user_idx
  on pods.booking_customers(user_id);

-- Staff availability rules (weekly)
-- day_of_week: 0=Sunday .. 6=Saturday
create table if not exists pods.booking_availability_rules (
  rule_id      uuid primary key default gen_random_uuid(),
  org_id       uuid not null references pods.orgs(org_id) on delete cascade,
  staff_user_id uuid not null, -- must be an org member (enforced in RPC)
  location_id  uuid null references pods.storefront_locations(location_id) on delete set null,
  day_of_week  int not null check (day_of_week between 0 and 6),
  start_time   time not null,
  end_time     time not null,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now()
);

create index if not exists booking_avail_org_staff_idx
  on pods.booking_availability_rules(org_id, staff_user_id);

-- Staff time off / blocks (absolute)
create table if not exists pods.booking_time_off_blocks (
  block_id      uuid primary key default gen_random_uuid(),
  org_id        uuid not null references pods.orgs(org_id) on delete cascade,
  staff_user_id uuid not null,
  start_at      timestamptz not null,
  end_at        timestamptz not null,
  reason        text null,
  created_at    timestamptz not null default now(),
  check (end_at > start_at)
);

create index if not exists booking_timeoff_org_staff_idx
  on pods.booking_time_off_blocks(org_id, staff_user_id);

-- Appointments
create table if not exists pods.booking_appointments (
  appointment_id uuid primary key default gen_random_uuid(),
  org_id         uuid not null references pods.orgs(org_id) on delete cascade,
  location_id    uuid null references pods.storefront_locations(location_id) on delete set null,
  service_id     uuid null references pods.storefront_services(service_id) on delete set null,
  staff_user_id  uuid not null,
  customer_id    uuid null references pods.booking_customers(customer_id) on delete set null,
  customer_user_id uuid null, -- if authenticated booking customer
  customer_name  text null,
  customer_email text null,
  customer_phone text null,
  start_at       timestamptz not null,
  end_at         timestamptz not null,
  status         text not null default 'requested', -- requested|confirmed|completed|cancelled
  notes          text null,
  created_by_user_id uuid null,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (end_at > start_at)
);

create index if not exists booking_appt_org_staff_idx
  on pods.booking_appointments(org_id, staff_user_id);

create index if not exists booking_appt_org_start_idx
  on pods.booking_appointments(org_id, start_at);

-- Status log (append-only)
create table if not exists pods.booking_appointment_status_log (
  log_id         uuid primary key default gen_random_uuid(),
  org_id         uuid not null references pods.orgs(org_id) on delete cascade,
  appointment_id uuid not null references pods.booking_appointments(appointment_id) on delete cascade,
  from_status    text null,
  to_status      text not null,
  actor_user_id  uuid null,
  actor_role_key text null,
  created_at     timestamptz not null default now(),
  details        jsonb not null default '{}'::jsonb
);

create index if not exists booking_appt_status_org_appt_idx
  on pods.booking_appointment_status_log(org_id, appointment_id);

-- Register model
insert into pods.models(model_id, version, depends_on, is_active)
values (
  'pods.booking', '1.0.0',
  jsonb_build_array('pods.core@1.0.0','pods.storefront@1.0.0'),
  true
)
on conflict (model_id, version) do nothing;

commit;