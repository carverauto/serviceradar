DROP VIEW IF EXISTS devices_view;
DROP VIEW IF EXISTS device_updates_stream;
DROP MATERIALIZED VIEW IF EXISTS unified_devices_mv;

CREATE VIEW IF NOT EXISTS device_updates_stream AS
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
    last_seen AS update_time
FROM devices
UNION ALL
SELECT
    concat(ip, ':', poller_id) AS device_id,
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
    timestamp AS update_time
FROM sweep_results;

CREATE MATERIALIZED VIEW IF NOT EXISTS unified_devices_mv INTO unified_devices AS
SELECT
    device_id,
    arg_max(ip, update_time) AS ip,
    arg_max(poller_id, update_time) AS poller_id,
    arg_max(hostname, update_time) AS hostname,
    arg_max(mac, update_time) AS mac,
    arg_max(discovery_source, update_time) AS discovery_source,
    arg_max(is_available, update_time) AS is_available,
    min(first_seen) AS first_seen,
    max(last_seen) AS last_seen,
    arg_max(metadata, update_time) AS metadata,
    arg_max(agent_id, update_time) AS agent_id
FROM device_updates_stream
GROUP BY device_id;
