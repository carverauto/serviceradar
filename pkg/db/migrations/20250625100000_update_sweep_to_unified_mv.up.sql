DROP VIEW IF EXISTS sweep_to_unified_mv;

CREATE MATERIALIZED VIEW IF NOT EXISTS sweep_to_unified_mv
INTO unified_devices AS
SELECT
    concat(s.ip, ':', s.agent_id, ':', s.poller_id) AS device_id,
    s.ip,
    s.poller_id,
    coalesce(d.hostname, s.hostname) AS hostname,
    coalesce(d.mac, s.mac) AS mac,
    s.discovery_source,
    s.available AS is_available,
    coalesce(d.first_seen, s.timestamp) AS first_seen,
    s.timestamp AS last_seen,
    if(d.metadata != map(), mapMerge(d.metadata, s.metadata), s.metadata) AS metadata,
    s.agent_id,
    now64(3) AS _tp_time
FROM sweep_results s
LEFT JOIN devices d
    ON d.device_id = concat(s.ip, ':', s.agent_id, ':', s.poller_id);
