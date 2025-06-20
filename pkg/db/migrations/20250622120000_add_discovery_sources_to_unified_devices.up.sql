-- Add discovery_sources array to unified_devices and update the materialized view

-- Drop existing materialized view
DROP VIEW IF EXISTS unified_device_pipeline_mv;

-- Add new array column with an empty array default
ALTER STREAM unified_devices
    ADD COLUMN discovery_sources Array(String) DEFAULT [] AFTER mac;

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
