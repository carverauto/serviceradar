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
    discovery_source string,
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
    concat(partition, ':', ip) AS device_id,
    ip,
    poller_id,
    hostname,
    mac,
    discovery_source,
    available AS is_available,
    timestamp AS first_seen,
    timestamp AS last_seen,
    metadata,
    agent_id,
    timestamp AS _tp_time,
    -- Default values for network devices
    'network_device' AS device_type,
    NULL AS service_type,
    NULL AS service_status,
    NULL AS last_heartbeat,
    NULL AS os_info,
    NULL AS version_info
FROM sweep_results;