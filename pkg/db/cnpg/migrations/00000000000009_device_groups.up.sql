-- DEPRECATED: This migration is now a no-op.
-- Device groups are now created in tenant schemas via Ash migrations.
-- See: elixir/serviceradar_core/priv/repo/tenant_migrations/

-- Original functionality (now in tenant migrations):
-- - Create device_groups table
-- - Add group_id column to ocsf_devices
