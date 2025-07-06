-- Add missing agent_id columns to tables
-- Migration to fix column mismatches identified in logs

-- Add agent_id to unified_devices table
ALTER STREAM unified_devices ADD COLUMN agent_id string;

-- Add agent_id to service_status table  
ALTER STREAM service_status ADD COLUMN agent_id string;

-- Add additional device metadata columns to unified_devices
ALTER STREAM unified_devices ADD COLUMN os_info nullable(string);
ALTER STREAM unified_devices ADD COLUMN version_info nullable(string);
ALTER STREAM unified_devices ADD COLUMN device_type nullable(string);
ALTER STREAM unified_devices ADD COLUMN service_type nullable(string);
ALTER STREAM unified_devices ADD COLUMN service_status nullable(string);
ALTER STREAM unified_devices ADD COLUMN last_heartbeat nullable(DateTime64(3));