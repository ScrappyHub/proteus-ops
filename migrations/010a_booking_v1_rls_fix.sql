begin;

-- Booking tables: RPC-only writes. So "no write" policies must be FOR ALL.

drop policy if exists booking_customers_no_write on pods.booking_customers;
create policy booking_customers_no_write
on pods.booking_customers
for all
to authenticated
using (false)
with check (false);

drop policy if exists booking_availability_no_write on pods.booking_availability_rules;
create policy booking_availability_no_write
on pods.booking_availability_rules
for all
to authenticated
using (false)
with check (false);

drop policy if exists booking_timeoff_no_write on pods.booking_time_off_blocks;
create policy booking_timeoff_no_write
on pods.booking_time_off_blocks
for all
to authenticated
using (false)
with check (false);

drop policy if exists booking_appointments_no_write on pods.booking_appointments;
create policy booking_appointments_no_write
on pods.booking_appointments
for all
to authenticated
using (false)
with check (false);

drop policy if exists booking_appt_status_no_write on pods.booking_appointment_status_log;
create policy booking_appt_status_no_write
on pods.booking_appointment_status_log
for all
to authenticated
using (false)
with check (false);

commit;