-- migrations/20250703000000_enhance_device_merging_logic.down.sql
-- Revert to the previous version of the unified device pipeline

DROP VIEW IF EXISTS unified_device_pipeline_mv;

-- Recreate the previous version of the materialized view
CREATE MATERIALIZED VIEW unified_device_pipeline_mv
INTO unified_devices
AS
SELECT
    concat(s.partition, ':', s.ip) AS device_id,
    s.ip,
    s.poller_id,
    s.hostname,
    s.mac,
    if(
        index_of(if_null(u.discovery_sources, []), s.discovery_source) > 0,
        u.discovery_sources,
        array_push_back(if_null(u.discovery_sources, []), s.discovery_source)
    ) AS discovery_sources,
    s.available AS is_available,
    coalesce(u.first_seen, s.timestamp) AS first_seen,
    s.timestamp AS last_seen,
    if(
        length(s.metadata) > 0,
        if(is_null(u.metadata), s.metadata, map_update(u.metadata, s.metadata)),
        u.metadata
    ) AS metadata,
    s.agent_id,
    s.timestamp AS _tp_time
FROM sweep_results AS s
         LEFT JOIN unified_devices AS u ON concat(s.partition, ':', s.ip) = u.device_id;