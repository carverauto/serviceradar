-- Fix the discovery sources array logic in the unified device pipeline materialized view
-- The previous logic had index_of(...) > 0 which was incorrect since index_of returns 0 for not found
-- and 1-based indices for found elements

DROP VIEW IF EXISTS unified_device_pipeline_mv;

CREATE MATERIALIZED VIEW IF NOT EXISTS unified_device_pipeline_mv
INTO unified_devices
AS SELECT
    concat(s.partition, ':', s.ip) AS device_id, s.ip, s.poller_id,
    if(s.hostname IS NOT NULL AND s.hostname != '', s.hostname, u.hostname) AS hostname,
    if(s.mac IS NOT NULL AND s.mac != '', s.mac, u.mac) AS mac,
    if( index_of(if_null(u.discovery_sources, []), s.discovery_source) = 0, array_push_back(if_null(u.discovery_sources, []), s.discovery_source), u.discovery_sources ) AS discovery_sources,
    s.available AS is_available, coalesce(u.first_seen, s.timestamp) AS first_seen, s.timestamp AS last_seen,
    if( length(s.metadata) > 0, if(u.metadata IS NULL, s.metadata, map_update(u.metadata, s.metadata)), u.metadata ) AS metadata,
    s.agent_id, if(u.device_id IS NULL, 'network_device', u.device_type) AS device_type,
    u.service_type, u.service_status, u.last_heartbeat, u.os_info, u.version_info
FROM sweep_results AS s
LEFT JOIN unified_devices AS u ON concat(s.partition, ':', s.ip) = u.device_id;