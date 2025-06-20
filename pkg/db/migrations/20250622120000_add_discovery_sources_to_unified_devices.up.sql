-- Add discovery_sources array to unified_devices and update the materialized view

-- Ensure the unified_devices stream exists in case the previous migration
-- failed to create it (e.g. on older clusters)
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
) PRIMARY KEY (device_id)
SETTINGS mode='versioned_kv', version_column='_tp_time';

-- Drop existing materialized view
DROP VIEW IF EXISTS unified_device_pipeline_mv;

-- Add new array column with an empty array default
ALTER STREAM unified_devices
    ADD COLUMN discovery_sources array(string) DEFAULT [] AFTER mac;

-- Populate array column from existing discovery_source values
ALTER STREAM unified_devices
    UPDATE discovery_sources = [discovery_source]
    WHERE discovery_source IS NOT NULL;

-- Remove old discovery_source column
ALTER STREAM unified_devices DROP COLUMN discovery_source;

-- Recreate materialized view with array merge logic
CREATE MATERIALIZED VIEW unified_device_pipeline_mv
INTO unified_devices
AS SELECT
    concat(partition, ':', ip) AS device_id,
    ip,
    poller_id,
    hostname,
    mac,
    arrayDistinct(arrayConcat(
        ifnull((SELECT discovery_sources FROM unified_devices WHERE device_id = concat(partition, ':', ip) ORDER BY _tp_time DESC LIMIT 1), []),
        [discovery_source]
    )) AS discovery_sources,
    available AS is_available,
    coalesce((SELECT first_seen FROM unified_devices WHERE device_id = concat(partition, ':', ip) ORDER BY _tp_time DESC LIMIT 1), timestamp) AS first_seen,
    timestamp AS last_seen,
    metadata,
    agent_id,
    timestamp AS _tp_time
FROM sweep_results;
