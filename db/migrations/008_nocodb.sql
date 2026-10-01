-- P1 admin grids (NocoDB on the app database): clinic setup, clients and appointments only.
-- Conversations, messages, channel tokens and traces stay out of reach. Direct edits are safe: the
-- exclusion constraints block double booking, and the appointments trigger re-arms calendar sync
-- and reminders for cron.reconcile / cron.reminders. Clinics are created by admin.onboard, so the
-- grid may edit a clinic but not add or delete one.
grant usage on schema public to nocodb;
grant select, update on tenants to nocodb;
grant select, insert, update, delete on branches, doctors, services, doctor_services, doctor_schedules,
  doctor_shifts, clients, appointments to nocodb;
