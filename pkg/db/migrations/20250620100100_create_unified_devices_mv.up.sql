-- Migration: Simple fix for unified devices
-- Date: 20250620200000
-- Description: Uses a single materialized view to prevent overwriting issues

-- Step 1: Clean up existing views
DROP VIEW IF EXISTS all_sources_to_unified_mv;
DROP VIEW IF EXISTS sweep_to_unified_mv;
DROP VIEW IF EXISTS devices_to_unified_mv;

-- Step 2: Ensure unified_devices stream exists
CREATE STREAM IF NOT EXISTS unified_devices (
    device_id string,
    ip string,
    poller_id string,
    hostname nullable(string),
    mac nullable(string),
    discovery_source string,
    is_available boolean,
    first_seen DateTime64(3),
    last_seen DateTime64(3),
    metadata map(string, string),
    agent_id string
)
PRIMARY KEY (device_id)
SETTINGS mode='versioned_kv', version_column='_tp_time';

-- Step 3: Only create ONE materialized view for devices stream
-- This prevents the overwriting issue
CREATE MATERIALIZED VIEW IF NOT EXISTS devices_to_unified_mv INTO unified_devices AS
SELECT
    device_id,
    ip,
    poller_id,
    hostname,
    mac,
    discovery_source,
    is_available,
    first_seen,
    last_seen,
    agent_id,
    metadata,
    last_seen AS _tp_time
FROM devices;

-- Step 4: Manually insert all sweep_results data as a one-time operation
-- This ensures sweep data is in unified_devices but won't be overwritten
INSERT INTO unified_devices
SELECT
    concat(ip, ':', agent_id, ':', poller_id) AS device_id,
    ip,
    poller_id,
    hostname,
    mac,
    discovery_source,
    available AS is_available,
    timestamp AS first_seen,
    timestamp AS last_seen,
    agent_id,
    metadata,
    -- Use a timestamp slightly before current time to ensure devices stream wins
    date_sub(now64(3), INTERVAL 1 SECOND) AS _tp_time
FROM sweep_results
WHERE (ip, agent_id, poller_id) NOT IN (
    SELECT ip, agent_id, poller_id FROM devices
);

-- Step 5: Create a scheduled job or trigger to periodically sync sweep_results
-- This would need to be done outside the migration, in your application code
-- Example pseudo-code:
-- Every 5 minutes: INSERT INTO unified_devices SELECT ... FROM sweep_results WHERE [new records only]