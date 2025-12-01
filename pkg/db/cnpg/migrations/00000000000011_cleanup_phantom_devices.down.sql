-- Rollback: Restore phantom devices from backup
-- This migration restores devices that were deleted by the cleanup migration.

-- Restore devices from backup
INSERT INTO unified_devices
SELECT * FROM _phantom_devices_backup
ON CONFLICT (device_id) DO NOTHING;

-- Log restoration
DO $$
DECLARE
    restored_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO restored_count FROM _phantom_devices_backup;
    RAISE NOTICE 'Restored % phantom devices from backup', restored_count;
END $$;

-- Drop the backup table after restoration
DROP TABLE IF EXISTS _phantom_devices_backup;
