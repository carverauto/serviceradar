-- It now guards against environments where the backup table was removed or never created.
-- Create an empty backup table if it's missing so the INSERT/ DROP statements remain safe.
CREATE TABLE IF NOT EXISTS _phantom_devices_backup AS
SELECT *
FROM unified_devices
WHERE false;

INSERT INTO unified_devices
SELECT * FROM _phantom_devices_backup
ON CONFLICT (device_id) DO NOTHING;

DROP TABLE IF EXISTS _phantom_devices_backup;
