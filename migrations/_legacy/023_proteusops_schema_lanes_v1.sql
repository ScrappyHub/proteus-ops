begin;

create schema if not exists pods_core;
create schema if not exists pods_ops;
create schema if not exists pods_public;

comment on schema pods_core is
'ProteusOps canonical governance/core lane: owner objects, memberships, subscriptions, plans, capabilities, entitlements, scope law, and maintenance/governance RPC surfaces. Non-breaking transition schema; current working storage may remain under pods during transition.';

comment on schema pods_ops is
'ProteusOps canonical operations lane: services, staff, locations, appointments, availability, time off, activity/media later, and other operational business records. Non-breaking transition schema; current working storage may remain under pods during transition.';

comment on schema pods_public is
'ProteusOps canonical public surface lane: public-facing views, projections, and request RPC surfaces. This lane is exposure/projection, not authority. Non-breaking transition schema; current working storage may remain under pods during transition.';

create or replace view pods_core.v_orgs as
select *
from pods.orgs;

comment on view pods_core.v_orgs is
'Compatibility view during schema transition. Authoritative conceptual lane: pods_core. Physical storage currently remains under pods.orgs unless/until explicitly migrated.';

create or replace view pods_core.v_org_members as
select *
from pods.org_members;

comment on view pods_core.v_org_members is
'Compatibility view during schema transition. Authoritative conceptual lane: pods_core.';

create or replace view pods_core.v_subscriptions as
select *
from pods.subscriptions;

comment on view pods_core.v_subscriptions is
'Compatibility view during schema transition. Authoritative conceptual lane: pods_core.';

create or replace view pods_core.v_plan_tiers as
select *
from pods.plan_tiers;

comment on view pods_core.v_plan_tiers is
'Compatibility view during schema transition. Authoritative conceptual lane: pods_core.';

create or replace view pods_core.v_plan_capabilities as
select *
from pods.plan_capabilities;

comment on view pods_core.v_plan_capabilities is
'Compatibility view during schema transition. Authoritative conceptual lane: pods_core.';

create or replace view pods_core.v_org_entitlements as
select *
from pods.org_entitlements;

comment on view pods_core.v_org_entitlements is
'Compatibility view during schema transition. Authoritative conceptual lane: pods_core.';

create or replace view pods_ops.v_booking_appointments as
select *
from pods.booking_appointments;

comment on view pods_ops.v_booking_appointments is
'Compatibility view during schema transition. Authoritative conceptual lane: pods_ops.';

create or replace view pods_ops.v_booking_availability_rules as
select *
from pods.booking_availability_rules;

comment on view pods_ops.v_booking_availability_rules is
'Compatibility view during schema transition. Authoritative conceptual lane: pods_ops.';

create or replace view pods_ops.v_booking_time_off_blocks as
select *
from pods.booking_time_off_blocks;

comment on view pods_ops.v_booking_time_off_blocks is
'Compatibility view during schema transition. Authoritative conceptual lane: pods_ops.';

comment on function public.rpc_recompute_entitlements(uuid) is
'Canonical lane classification: pods_core. Public wrapper retained for compatibility/PostgREST exposure during transition.';

comment on function public.rpc_selftest_set_subscription_plan_v1(uuid, text, text) is
'Canonical lane classification: pods_core. Public wrapper retained for compatibility/PostgREST exposure during transition.';

comment on function public.rpc_selftest_add_org_member_v1(uuid, uuid, text) is
'Canonical lane classification: pods_core. Public wrapper retained for compatibility/PostgREST exposure during transition.';

comment on function public.rpc_selftest_reset_booking_v1(uuid, uuid) is
'Canonical lane classification: pods_ops. Public wrapper retained for compatibility/PostgREST exposure during transition.';

comment on function public.rpc_upsert_availability_rule_v1(uuid, uuid, uuid, uuid, integer, time without time zone, time without time zone, boolean) is
'Canonical lane classification: pods_ops. Public wrapper retained for compatibility/PostgREST exposure during transition.';

comment on function public.rpc_create_appointment_v1(uuid, uuid, timestamp with time zone, timestamp with time zone, uuid, uuid, text, text, text, text) is
'Canonical lane classification: pods_ops. Public wrapper retained for compatibility/PostgREST exposure during transition.';

comment on function public.rpc_add_time_off_block_v1(uuid, uuid, timestamp with time zone, timestamp with time zone, text) is
'Canonical lane classification: pods_ops. Public wrapper retained for compatibility/PostgREST exposure during transition.';

comment on function public.rpc_request_booking_v1(uuid, uuid, timestamp with time zone, timestamp with time zone, text, text, text, text) is
'Canonical lane classification: pods_public. Public wrapper retained as part of the public request surface during transition.'
;

commit;