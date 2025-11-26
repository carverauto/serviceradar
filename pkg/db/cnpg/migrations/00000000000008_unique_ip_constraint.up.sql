-- Add unique constraint on IP for active sr: devices
-- This prevents duplicate devices from being created for the same IP
-- Run AFTER the merge_duplicates migration (007) to ensure no duplicates exist

-- The constraint is a partial unique index that:
-- 1. Only applies to devices with sr: UUIDs
-- 2. Excludes merged devices (those with _merged_into pointing elsewhere)
-- 3. Excludes deleted devices

BEGIN;

-- Create the partial unique index
-- This ensures that for any given IP, there can only be one active sr: device
-- Note: If duplicates exist, this CREATE will fail with a clear error message
CREATE UNIQUE INDEX IF NOT EXISTS idx_unified_devices_ip_unique_active
ON unified_devices (ip)
WHERE device_id LIKE 'sr:%'
  AND (metadata->>'_merged_into' IS NULL OR metadata->>'_merged_into' = '' OR metadata->>'_merged_into' = device_id)
  AND COALESCE(lower(metadata->>'_deleted'),'false') <> 'true'
  AND COALESCE(lower(metadata->>'deleted'),'false') <> 'true';

COMMIT;
