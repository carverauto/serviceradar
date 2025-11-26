-- Merge duplicate devices in unified_devices
-- This script identifies devices that share the same IP but have different UUIDs.
-- It picks the "best" device (most metadata/strong IDs) as canonical and merges others into it.
BEGIN;
-- 1. Identify duplicates
CREATE TEMP TABLE duplicates AS WITH ranked AS (
    SELECT ip,
        device_id,
        metadata,
        mac,
        last_seen,
        ROW_NUMBER() OVER (
            PARTITION BY ip
            ORDER BY -- Prefer devices with Armis ID
                CASE
                    WHEN metadata->>'armis_device_id' IS NOT NULL THEN 1
                    ELSE 0
                END DESC,
                -- Prefer devices with MAC
                CASE
                    WHEN mac IS NOT NULL THEN 1
                    ELSE 0
                END DESC,
                -- Prefer devices with NetBox ID
                CASE
                    WHEN metadata->>'netbox_device_id' IS NOT NULL THEN 1
                    ELSE 0
                END DESC,
                -- Prefer newer devices
                last_seen DESC
        ) as rank
    FROM unified_devices
    WHERE device_id LIKE 'sr:%'
        AND (
            metadata->>'_merged_into' IS NULL
            OR metadata->>'_merged_into' = ''
        )
        AND COALESCE(lower(metadata->>'_deleted'), 'false') <> 'true'
)
SELECT *
FROM ranked
WHERE rank > 1;
-- 2. Identify canonical devices for those duplicates
CREATE TEMP TABLE canonical_map AS WITH ranked AS (
    SELECT ip,
        device_id as canonical_id,
        ROW_NUMBER() OVER (
            PARTITION BY ip
            ORDER BY CASE
                    WHEN metadata->>'armis_device_id' IS NOT NULL THEN 1
                    ELSE 0
                END DESC,
                CASE
                    WHEN mac IS NOT NULL THEN 1
                    ELSE 0
                END DESC,
                CASE
                    WHEN metadata->>'netbox_device_id' IS NOT NULL THEN 1
                    ELSE 0
                END DESC,
                last_seen DESC
        ) as rank
    FROM unified_devices
    WHERE device_id LIKE 'sr:%'
        AND (
            metadata->>'_merged_into' IS NULL
            OR metadata->>'_merged_into' = ''
        )
        AND COALESCE(lower(metadata->>'_deleted'), 'false') <> 'true'
)
SELECT ip,
    canonical_id
FROM ranked
WHERE rank = 1;
-- 3. Update duplicates to point to canonical
UPDATE unified_devices u
SET metadata = u.metadata || jsonb_build_object('_merged_into', c.canonical_id)
FROM duplicates d
    JOIN canonical_map c ON d.ip = c.ip
WHERE u.device_id = d.device_id;
-- 4. Cleanup temp tables
DROP TABLE IF EXISTS duplicates;
DROP TABLE IF EXISTS canonical_map;
COMMIT;