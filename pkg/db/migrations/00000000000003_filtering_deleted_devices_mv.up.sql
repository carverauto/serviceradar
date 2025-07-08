DROP VIEW unified_device_pipeline_mv;

-- Materialized view that maintains only current device state
-- Uses the provided device_id to prevent duplicates when devices have multiple IPs
CREATE MATERIALIZED VIEW IF NOT EXISTS unified_device_pipeline_mv
INTO unified_devices
AS SELECT
    s.device_id AS device_id,  -- Use provided device_id instead of constructing it
    s.ip,
    s.poller_id,
    if(s.hostname IS NOT NULL AND s.hostname != '', s.hostname, u.hostname) AS hostname,
    if(s.mac IS NOT NULL AND s.mac != '', s.mac, u.mac) AS mac,
    if(index_of(if_null(u.discovery_sources, []), s.discovery_source) > 0,
       u.discovery_sources,
       array_push_back(if_null(u.discovery_sources, []), s.discovery_source)) AS discovery_sources,

    -- START: UPDATED AVAILABILITY LOGIC
    -- This logic prioritizes the _deleted flag. If present, the device is marked unavailable.
    -- Otherwise, it follows the previous logic to determine availability based on the source type.
    CASE
        WHEN s.metadata['_deleted'] = 'true' THEN false
        ELSE coalesce(if(s.discovery_source IN ('sweep', 'snmp', 'sysmon', 'mapper'), s.available, u.is_available), s.available)
        END AS is_available,
    -- END: UPDATED AVAILABILITY LOGIC

    coalesce(u.first_seen, s.timestamp) AS first_seen,
    s.timestamp AS last_seen,
    if(s.metadata IS NOT NULL,
       if(u.metadata IS NULL, s.metadata, map_update(u.metadata, s.metadata)),
       u.metadata) AS metadata,
    s.agent_id,
    if(u.device_id IS NULL, 'network_device', u.device_type) AS device_type,
    u.service_type,
    u.service_status,
    u.last_heartbeat,
    u.os_info,
    u.version_info
FROM sweep_results AS s
LEFT JOIN unified_devices AS u ON s.device_id = u.device_id;