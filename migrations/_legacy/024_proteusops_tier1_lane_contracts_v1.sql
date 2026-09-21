begin;

create schema if not exists pods_core;
create schema if not exists pods_ops;
create schema if not exists pods_public;
create schema if not exists pods_billing;

comment on schema pods_core is
'Tier-1 CORE lane: org identity, memberships, auth-bound actor context, entitlements roots.';

comment on schema pods_ops is
'Tier-1 OPS lane: operational execution entities such as availability, appointments, and time-off.';

comment on schema pods_public is
'Tier-1 PUBLIC lane: externally consumable read/public booking request surfaces only.';

comment on schema pods_billing is
'Tier-1 BILLING lane: subscription state, plan materialization, billing-driven capability effects.';

create table if not exists pods_core.lane_contracts_v1 (
  lane_key text primary key,
  owner_schema text not null,
  purpose text not null,
  write_policy text not null,
  public_surface boolean not null default false,
  created_at timestamptz not null default now()
);

insert into pods_core.lane_contracts_v1
  (lane_key, owner_schema, purpose, write_policy, public_surface)
values
  ('core','pods_core','org/membership/entitlement roots','service + authorized internal rpc only',false),
  ('ops','pods_ops','availability/appointments/timeoff operational data','authorized internal rpc only',false),
  ('public','pods_public','public wrappers and externally consumable read/request surfaces','wrapper/rpc only',true),
  ('billing','pods_billing','plan state and capability effects','service + billing sync only',false)
on conflict (lane_key) do update
set owner_schema = excluded.owner_schema,
    purpose = excluded.purpose,
    write_policy = excluded.write_policy,
    public_surface = excluded.public_surface;

commit;