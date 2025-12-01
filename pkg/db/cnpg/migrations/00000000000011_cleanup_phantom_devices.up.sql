-- Migration: Cleanup phantom devices created by collectors
-- This migration removes device records that were incorrectly created for collector
-- ephemeral IPs (Docker bridge network IPs) instead of actual monitoring targets.
--
-- Phantom devices are identified by:
-- 1. IP address in Docker bridge network ranges (172.17.x.x, 172.18.x.x, etc.)
-- 2. Created by a checker (source = 'checker')
-- 3. Hostname suggests collector (contains 'agent', 'poller', or is empty/unknown)
-- 4. Device ID is NOT a serviceradar:* service device (those are intentional)

-- First, let's create a backup of potentially affected devices
CREATE TABLE IF NOT EXISTS _phantom_devices_backup AS
SELECT *
FROM unified_devices
WHERE
    -- Device ID is NOT a service device (we want to keep those)
    device_id NOT LIKE 'serviceradar:%'
    -- IP is in Docker bridge network ranges
    AND (
        ip ~ '^172\.17\.' OR
        ip ~ '^172\.18\.' OR
        ip ~ '^172\.19\.' OR
        ip ~ '^172\.20\.' OR
        ip ~ '^172\.21\.'
    )
    -- Source indicates it came from a checker
    AND (
        metadata->>'source' = 'checker'
        OR metadata->>'source' = 'self-reported'
    )
    -- Hostname suggests this is a collector, not a real target
    AND (
        hostname IS NULL
        OR hostname = ''
        OR LOWER(hostname) LIKE '%agent%'
        OR LOWER(hostname) LIKE '%poller%'
        OR LOWER(hostname) LIKE '%collector%'
        OR LOWER(hostname) = 'unknown'
        OR LOWER(hostname) = 'localhost'
    );

-- Log how many phantom devices were identified
DO $$
DECLARE
    phantom_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO phantom_count FROM _phantom_devices_backup;
    RAISE NOTICE 'Identified % phantom devices for cleanup', phantom_count;
END $$;

-- Delete the phantom devices
DELETE FROM unified_devices
WHERE device_id IN (SELECT device_id FROM _phantom_devices_backup);

-- Log completion
DO $$
DECLARE
    remaining_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO remaining_count FROM unified_devices;
    RAISE NOTICE 'Cleanup complete. % devices remaining in unified_devices', remaining_count;
END $$;
