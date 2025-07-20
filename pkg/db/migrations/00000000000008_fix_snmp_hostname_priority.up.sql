DROP VIEW unified_device_pipeline_mv;

-- Materialized view that prioritizes mapper hostnames over SNMP checker hostnames
-- Mapper discovery has higher confidence than SNMP target monitoring
CREATE MATERIALIZED VIEW IF NOT EXISTS unified_device_pipeline_mv
INTO unified_devices
AS SELECT
    s.device_id AS device_id,
    s.ip,
    s.poller_id,
    -- Simple hostname priority: prevent SNMP target names from overwriting actual device names
    -- 1. Never allow 'tonka01' or 'farm01' to overwrite existing non-empty hostnames
    -- 2. Prefer hostnames with spaces/dashes (actual device names) over simple names
    -- 3. Use new hostname only if existing is empty or if new one looks better
    if(s.hostname IS NOT NULL AND s.hostname != '',
       if(s.hostname IN ('tonka01', 'farm01') AND u.hostname IS NOT NULL AND u.hostname != '' AND u.hostname != s.ip,
          u.hostname,  -- Never overwrite with SNMP target names
          if(u.hostname IS NULL OR u.hostname = '' OR u.hostname = s.ip,
             s.hostname,  -- Use new hostname if existing is empty/generic
             if((u.hostname LIKE '% %' OR u.hostname LIKE '%-%') AND s.hostname NOT LIKE '% %' AND s.hostname NOT LIKE '%-%',
                u.hostname,  -- Preserve device names with spaces/dashes over simple names
                s.hostname))), -- Otherwise use new hostname
       u.hostname) AS hostname,
    if(s.mac IS NOT NULL AND s.mac != '', s.mac, u.mac) AS mac,
    if(index_of(if_null(u.discovery_sources, []), s.discovery_source) > 0,
       u.discovery_sources,
       array_push_back(if_null(u.discovery_sources, []), s.discovery_source)) AS discovery_sources,

    -- START: ROBUST AVAILABILITY LOGIC
    -- Whitelist active sources. If the new event is from an active source, use its availability status.
    -- Otherwise (for passive sources like 'netbox'), keep the existing status (u.is_available).
    coalesce(if(s.discovery_source IN ('sweep', 'snmp', 'sysmon', 'mapper'), s.available, u.is_available), s.available) AS is_available,
    -- END: ROBUST AVAILABILITY LOGIC

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