-- Add service types to unified_devices to support agents and pollers
-- This migration enhances the unified_devices stream to accommodate both network devices and service components

-- Drop existing materialized view
DROP VIEW IF EXISTS unified_device_pipeline_mv;

-- Drop existing stream
DROP STREAM IF EXISTS unified_devices;

-- Recreate unified_devices stream with new columns for service devices
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
    agent_id string,
    -- New columns for service devices
    device_type string DEFAULT 'network_device',  -- 'network_device' or 'service_device'
    service_type nullable(string),                 -- 'poller', 'agent', 'core', 'agent_poller'
    service_status nullable(string),               -- 'online', 'offline', 'degraded'
    last_heartbeat nullable(DateTime64(3)),        -- Last check-in time for service components
    os_info nullable(string),                      -- OS information of host
    version_info nullable(string)                  -- Software version of agent/poller
)
PRIMARY KEY (device_id)
SETTINGS mode='versioned_kv', version_column='_tp_time';

-- Recreate materialized view with default values for network devices
CREATE MATERIALIZED VIEW IF NOT EXISTS unified_device_pipeline_mv
INTO unified_devices
AS SELECT
    concat(s.partition, ':', s.ip) AS device_id,
    s.ip,
    s.poller_id,
    s.hostname,
    s.mac,
    -- Handle discovery sources array properly
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
    s.timestamp AS _tp_time,
    -- Default values for network devices
    'network_device' AS device_type,
    NULL AS service_type,
    NULL AS service_status,
    NULL AS last_heartbeat,
    NULL AS os_info,
    NULL AS version_info
FROM sweep_results AS s
LEFT JOIN unified_devices AS u ON concat(s.partition, ':', s.ip) = u.device_id;