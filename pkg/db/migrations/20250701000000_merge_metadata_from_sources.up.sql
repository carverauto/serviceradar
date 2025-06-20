-- migrations/20250701000000_merge_metadata_from_sources.up.sql
-- Modify unified_device_pipeline_mv to merge new metadata with existing values

DROP VIEW IF EXISTS unified_device_pipeline_mv;

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
        if(isNull(u.metadata), s.metadata, mapUpdate(u.metadata, s.metadata)),
        u.metadata
    ) AS metadata,
    s.agent_id,
    s.timestamp AS _tp_time
FROM sweep_results AS s
         LEFT JOIN unified_devices AS u ON concat(s.partition, ':', s.ip) = u.device_id;
