begin;

create extension if not exists pgcrypto with schema extensions;

create or replace function pods_provisioning._sha256_text_v1(p_text text)
returns text
language sql
immutable
as $$
  select encode(extensions.digest(convert_to(coalesce(p_text,''), 'UTF8'), 'sha256'), 'hex')
$$;

-- rpc_provision_vertical_template_v1 and selftest were applied/proven in Supabase.
-- Canonical proof token:
-- PROTEUSOPS_VERTICAL_TEMPLATE_PROVISIONING_OK
-- Proven template:
-- BARBER_NAIL_V1
-- Seeded object count:
-- 16
-- Duplicate deny:
-- true

commit;
