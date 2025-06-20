-- migrations/20250622120000_add_discovery_sources_to_unified_devices.up.sql

-- Final script using a robust LEFT JOIN and standard functions
-- to avoid engine-specific limitations.

-- Step 1: Drop all related objects to ensure a clean slate.
DROP VIEW IF EXISTS unified_device_pipeline_mv;
DROP STREAM IF EXISTS unified_devices;
DROP STREAM IF EXISTS sweep_results;

-- Step 2: Recreate the sweep_results stream.
CREATE STREAM IF NOT EXISTS sweep_results (
    agent_id string,
    poller_id string,
    partition string,
    discovery_source string,
    ip string,
    mac nullable(string),
    hostname nullable(string),
    timestamp DateTime64(3),
    available boolean,
    metadata map(string, string)
);

-- Step 3: Recreate the unified_devices stream.
CREATE STREAM IF NOT EXISTS unified_devices (
    device_id string,
    ip string,
    poller_id string,
    hostname nullable(string),
    mac nullable(string),
    discovery_sources array(string),
    is_available boolean,
    first_seen DateTime64(3),
    last_seen DateTime64(3),
    metadata map(string, string),
    agent_id string
) PRIMARY KEY (device_id)
SETTINGS mode='versioned_kv', version_column='_tp_time';

-- Step 4: Recreate the materialized view with conditional logic.
CREATE MATERIALIZED VIEW unified_device_pipeline_mv
INTO unified_devices
AS
SELECT
    concat(s.partition, ':', s.ip) AS device_id,
    s.ip,
    s.poller_id,
    s.hostname,
    s.mac,
    -- If new source is already in the array, return the old array.
    -- Otherwise, append the new source to the old array.
    if(
            index_of(if_null(u.discovery_sources, []), s.discovery_source) > 0,
            u.discovery_sources,
            array_push_back(if_null(u.discovery_sources, []), s.discovery_source)
    ) AS discovery_sources,
    s.available AS is_available,
    coalesce(u.first_seen, s.timestamp) AS first_seen,
    s.timestamp AS last_seen,
    s.metadata,
    s.agent_id,
    s.timestamp AS _tp_time
FROM sweep_results AS s
         LEFT JOIN unified_devices AS u ON concat(s.partition, ':', s.ip) = u.device_id;