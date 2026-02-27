begin;

-- Ensure RLS is enabled
alter table pods.booking_customers enable row level security;
alter table pods.booking_availability_rules enable row level security;
alter table pods.booking_time_off_blocks enable row level security;
alter table pods.booking_appointments enable row level security;
alter table pods.booking_appointment_status_log enable row level security;

-- READ policies

drop policy if exists booking_customers_read on pods.booking_customers;
create policy booking_customers_read
on pods.booking_customers
for select to authenticated
using (
  exists (
    select 1 from pods.org_members m
    where m.org_id = pods.booking_customers.org_id
      and m.user_id = auth.uid()
      and m.role_key in ('owner','admin','staff')
  )
);

drop policy if exists booking_availability_read on pods.booking_availability_rules;
create policy booking_availability_read
on pods.booking_availability_rules
for select to authenticated
using (
  exists (
    select 1 from pods.org_members m
    where m.org_id = pods.booking_availability_rules.org_id
      and m.user_id = auth.uid()
      and m.role_key in ('owner','admin','staff')
  )
);

drop policy if exists booking_timeoff_read on pods.booking_time_off_blocks;
create policy booking_timeoff_read
on pods.booking_time_off_blocks
for select to authenticated
using (
  exists (
    select 1 from pods.org_members m
    where m.org_id = pods.booking_time_off_blocks.org_id
      and m.user_id = auth.uid()
      and m.role_key in ('owner','admin','staff')
  )
);

drop policy if exists booking_appointments_read on pods.booking_appointments;
create policy booking_appointments_read
on pods.booking_appointments
for select to authenticated
using (
  exists (
    select 1 from pods.org_members m
    where m.org_id = pods.booking_appointments.org_id
      and m.user_id = auth.uid()
      and m.role_key in ('owner','admin')
  )
  or (
    pods.booking_appointments.staff_user_id = auth.uid()
    and exists (
      select 1 from pods.org_members m2
      where m2.org_id = pods.booking_appointments.org_id
        and m2.user_id = auth.uid()
        and m2.role_key = 'staff'
    )
  )
);

drop policy if exists booking_appt_status_read on pods.booking_appointment_status_log;
create policy booking_appt_status_read
on pods.booking_appointment_status_log
for select to authenticated
using (
  exists (
    select 1 from pods.org_members m
    where m.org_id = pods.booking_appointment_status_log.org_id
      and m.user_id = auth.uid()
      and m.role_key in ('owner','admin','staff')
  )
);

-- NO DIRECT WRITES (RPC-only)

drop policy if exists booking_customers_no_write on pods.booking_customers;
create policy booking_customers_no_write
on pods.booking_customers
for all to authenticated
using (false) with check (false);

drop policy if exists booking_availability_no_write on pods.booking_availability_rules;
create policy booking_availability_no_write
on pods.booking_availability_rules
for all to authenticated
using (false) with check (false);

drop policy if exists booking_timeoff_no_write on pods.booking_time_off_blocks;
create policy booking_timeoff_no_write
on pods.booking_time_off_blocks
for all to authenticated
using (false) with check (false);

drop policy if exists booking_appointments_no_write on pods.booking_appointments;
create policy booking_appointments_no_write
on pods.booking_appointments
for all to authenticated
using (false) with check (false);

drop policy if exists booking_appt_status_no_write on pods.booking_appointment_status_log;
create policy booking_appt_status_no_write
on pods.booking_appointment_status_log
for all to authenticated
using (false) with check (false);

commit;