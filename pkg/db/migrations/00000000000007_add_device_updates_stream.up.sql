-- Create device_updates stream for modern DeviceUpdate events
CREATE STREAM IF NOT EXISTS device_updates (
    device_id string,
    ip string,
    source string,
    agent_id string,
    poller_id string,
    partition string,
    timestamp datetime,
    hostname nullable(string),
    mac nullable(string),
    metadata map(string, string),
    is_available bool,
    confidence int
) PRIMARY KEY device_id
SETTINGS mode='versioned_kv';

-- Drop the existing materialized view to recreate it with device_updates
DROP VIEW IF EXISTS unified_device_pipeline_mv;

-- Create new materialized view that consumes from device_updates stream
CREATE MATERIALIZED VIEW IF NOT EXISTS unified_device_pipeline_mv
INTO unified_devices
AS SELECT
    d.device_id AS device_id,
    d.ip,
    d.poller_id,
    if(d.hostname IS NOT NULL AND d.hostname != '', d.hostname, u.hostname) AS hostname,
    if(d.mac IS NOT NULL AND d.mac != '', d.mac, u.mac) AS mac,
    if(index_of(if_null(u.discovery_sources, []), d.source) > 0,
       u.discovery_sources,
       array_push_back(if_null(u.discovery_sources, []), d.source)) AS discovery_sources,

    -- START: ROBUST AVAILABILITY LOGIC
    -- Whitelist active sources. If the new event is from an active source, use its availability status.
    -- Otherwise (for passive sources like 'netbox'), keep the existing status (u.is_available).
    coalesce(if(d.source IN ('sweep', 'snmp', 'sysmon', 'mapper'), d.is_available, u.is_available), d.is_available) AS is_available,
    -- END: ROBUST AVAILABILITY LOGIC

    coalesce(u.first_seen, d.timestamp) AS first_seen,
    d.timestamp AS last_seen,
    if(d.metadata IS NOT NULL,
       if(u.metadata IS NULL, d.metadata, map_update(u.metadata, d.metadata)),
       u.metadata) AS metadata,
    d.agent_id,
    if(u.device_id IS NULL, 'network_device', u.device_type) AS device_type,
    u.service_type,
    u.service_status,
    u.last_heartbeat,
    u.os_info,
    u.version_info
FROM device_updates AS d
LEFT JOIN unified_devices AS u ON d.device_id = u.device_id;