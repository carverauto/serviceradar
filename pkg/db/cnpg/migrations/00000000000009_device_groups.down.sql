-- Rollback device groups migration

-- Remove group_id from ocsf_devices
DROP INDEX IF EXISTS idx_ocsf_devices_group_id;
ALTER TABLE ocsf_devices DROP COLUMN IF EXISTS group_id;

-- Drop device_groups table and indexes
DROP INDEX IF EXISTS idx_device_groups_parent_id;
DROP INDEX IF EXISTS idx_device_groups_type;
DROP INDEX IF EXISTS idx_device_groups_tenant_id;
DROP TABLE IF EXISTS device_groups;
