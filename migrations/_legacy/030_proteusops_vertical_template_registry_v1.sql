create schema if not exists pods_provisioning;

create table if not exists pods_provisioning.vertical_templates (
  template_key text primary key,
  display_name text not null,
  category text not null,
  description text not null,

  enabled boolean not null default true,

  default_timezone text not null default 'America/New_York',

  booking_enabled boolean not null default true,
  memberships_enabled boolean not null default false,
  staff_roles_enabled boolean not null default true,
  notifications_enabled boolean not null default true,

  config jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now()
);

create table if not exists pods_provisioning.vertical_template_services (
  id uuid primary key default gen_random_uuid(),

  template_key text not null references pods_provisioning.vertical_templates(template_key) on delete cascade,

  service_code text not null,
  display_name text not null,

  duration_minutes integer not null,
  price_cents integer not null,

  booking_enabled boolean not null default true,

  created_at timestamptz not null default now()
);

create table if not exists pods_provisioning.vertical_template_roles (
  id uuid primary key default gen_random_uuid(),

  template_key text not null references pods_provisioning.vertical_templates(template_key) on delete cascade,

  role_key text not null,
  display_name text not null,

  created_at timestamptz not null default now()
);

create table if not exists pods_provisioning.vertical_template_hours (
  id uuid primary key default gen_random_uuid(),

  template_key text not null references pods_provisioning.vertical_templates(template_key) on delete cascade,

  dow integer not null check (dow between 0 and 6),

  open_time time not null,
  close_time time not null,

  created_at timestamptz not null default now()
);

insert into pods_provisioning.vertical_templates(
  template_key,
  display_name,
  category,
  description,
  memberships_enabled,
  config
)
values
(
  'BARBER_NAIL_V1',
  'Barber + Nail Studio',
  'beauty',
  'Combined barber shop and nail salon starter operating model',
  true,
  jsonb_build_object(
    'public_booking', true,
    'staff_scheduling', true,
    'memberships', true,
    'tips', true,
    'inventory_tracking', false
  )
)
on conflict (template_key) do nothing;

insert into pods_provisioning.vertical_template_services(
  template_key,
  service_code,
  display_name,
  duration_minutes,
  price_cents
)
values
('BARBER_NAIL_V1','BARBER_CUT','Barber Cut',45,3500),
('BARBER_NAIL_V1','BEARD_TRIM','Beard Trim',20,1500),
('BARBER_NAIL_V1','MANICURE','Manicure',45,3000),
('BARBER_NAIL_V1','PEDICURE','Pedicure',60,4500)
on conflict do nothing;

insert into pods_provisioning.vertical_template_roles(
  template_key,
  role_key,
  display_name
)
values
('BARBER_NAIL_V1','OWNER','Owner'),
('BARBER_NAIL_V1','MANAGER','Manager'),
('BARBER_NAIL_V1','BARBER','Barber'),
('BARBER_NAIL_V1','NAIL_TECH','Nail Technician'),
('BARBER_NAIL_V1','FRONT_DESK','Front Desk')
on conflict do nothing;

insert into pods_provisioning.vertical_template_hours(
  template_key,
  dow,
  open_time,
  close_time
)
values
('BARBER_NAIL_V1',1,'09:00','19:00'),
('BARBER_NAIL_V1',2,'09:00','19:00'),
('BARBER_NAIL_V1',3,'09:00','19:00'),
('BARBER_NAIL_V1',4,'09:00','19:00'),
('BARBER_NAIL_V1',5,'09:00','19:00'),
('BARBER_NAIL_V1',6,'09:00','17:00')
on conflict do nothing;

create or replace function pods_provisioning.rpc_selftest_vertical_templates_v1()
returns jsonb
language plpgsql
security definer
as $$
declare
  template_count integer;
  service_count integer;
  role_count integer;
begin
  select count(*)
  into template_count
  from pods_provisioning.vertical_templates;

  select count(*)
  into service_count
  from pods_provisioning.vertical_template_services;

  select count(*)
  into role_count
  from pods_provisioning.vertical_template_roles;

  if template_count < 1 then
    raise exception 'TEMPLATE_COUNT_INVALID';
  end if;

  if service_count < 1 then
    raise exception 'SERVICE_COUNT_INVALID';
  end if;

  if role_count < 1 then
    raise exception 'ROLE_COUNT_INVALID';
  end if;

  return jsonb_build_object(
    'ok', true,
    'token', 'PROTEUSOPS_VERTICAL_TEMPLATE_REGISTRY_OK',
    'template_count', template_count,
    'service_count', service_count,
    'role_count', role_count
  );
end;
$$;

select pods_provisioning.rpc_selftest_vertical_templates_v1();