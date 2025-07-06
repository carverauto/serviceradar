-- Rollback migration: remove added columns

-- Remove additional device metadata columns from unified_devices
ALTER STREAM unified_devices DROP COLUMN last_heartbeat;
ALTER STREAM unified_devices DROP COLUMN service_status;
ALTER STREAM unified_devices DROP COLUMN service_type;
ALTER STREAM unified_devices DROP COLUMN device_type;
ALTER STREAM unified_devices DROP COLUMN version_info;
ALTER STREAM unified_devices DROP COLUMN os_info;

-- Remove agent_id from service_status table
ALTER STREAM service_status DROP COLUMN agent_id;

-- Remove agent_id from unified_devices table  
ALTER STREAM unified_devices DROP COLUMN agent_id;