DROP VIEW IF EXISTS device_updates_stream;

CREATE MATERIALIZED VIEW IF NOT EXISTS sweep_to_unified_mv INTO unified_devices AS
SELECT
    concat(ip, ':', agent_id, ':', poller_id) AS device_id,
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
    now64(3) AS _tp_time -- Provide the version column for the KV stream
FROM sweep_results;

CREATE MATERIALIZED VIEW IF NOT EXISTS devices_to_unified_mv INTO unified_devices AS
SELECT
    device_id,
    ip,
    poller_id,
    hostname,
    mac,
    discovery_source,
    is_available,
    first_seen,
    last_seen,
    metadata,
    agent_id,
    _tp_time -- Pass through the version from the source 'devices' stream
FROM devices;