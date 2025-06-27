-- migrations/20250703000000_enhance_device_merging_logic.up.sql
-- This migration enhances the unified device pipeline to correctly merge data from multiple discovery sources.
-- It ensures that rich metadata from sources like Netbox is not overwritten by subsequent, less-detailed discoveries.

-- Drop the existing view to redefine it with enhanced merging logic.
DROP VIEW IF EXISTS unified_device_pipeline_mv;

-- Recreate the materialized view with comprehensive merging logic.
CREATE MATERIALIZED VIEW unified_device_pipeline_mv
INTO unified_devices
AS SELECT
    concat(s.partition, ':', s.ip) AS device_id,
    s.ip,
    s.poller_id,

    -- Merge hostname: take new value if not empty, otherwise keep the old one.
    if(s.hostname IS NOT NULL AND s.hostname != '', s.hostname, u.hostname) AS hostname,

    -- Merge MAC address: take new value if not empty, otherwise keep the old one.
    if(s.mac IS NOT NULL AND s.mac != '', s.mac, u.mac) AS mac,

    -- Merge discovery sources: append new source if it's not already in the list.
    if(
        index_of(if_null(u.discovery_sources, []), s.discovery_source) > 0,
        u.discovery_sources,
        array_push_back(if_null(u.discovery_sources, []), s.discovery_source)
    ) AS discovery_sources,

    -- Always update availability and timestamps from the latest event.
    s.available AS is_available,
    coalesce(u.first_seen, s.timestamp) AS first_seen,
    s.timestamp AS last_seen,

    -- Merge metadata: update the existing map with new key-value pairs.
    if(
        length(s.metadata) > 0,
        if(u.metadata IS NULL, s.metadata, map_update(u.metadata, s.metadata)),
        u.metadata
    ) AS metadata,
    s.agent_id,

    -- Preserve existing service-related fields, as sweep_results events are for network devices.
    if(u.device_id IS NULL, 'network_device', u.device_type) AS device_type,
    u.service_type,
    u.service_status,
    u.last_heartbeat,
    u.os_info,
    u.version_info
FROM sweep_results AS s
LEFT JOIN unified_devices AS u ON concat(s.partition, ':', s.ip) = u.device_id;