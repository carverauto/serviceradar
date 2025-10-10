-- Restore the previous unified device pipeline definition.
DROP VIEW IF EXISTS unified_device_pipeline_mv;

CREATE MATERIALIZED VIEW unified_device_pipeline_mv
INTO unified_devices
AS
SELECT
    device_id,
    arg_max(ip, timestamp) AS ip,
    arg_max(poller_id, timestamp) AS poller_id,
    arg_max(agent_id, timestamp) AS agent_id,
    arg_max(hostname, timestamp) AS hostname,
    arg_max(mac, timestamp) AS mac,
    group_uniq_array(discovery_source) AS discovery_sources,
    arg_max(available, timestamp) AS is_available,
    min(timestamp) AS first_seen,
    max(timestamp) AS last_seen,
    arg_max(metadata, timestamp) AS metadata,
    'network_device' AS device_type,
    CAST(NULL AS nullable(string)) AS service_type,
    CAST(NULL AS nullable(string)) AS service_status,
    CAST(NULL AS nullable(DateTime64(3))) AS last_heartbeat,
    CAST(NULL AS nullable(string)) AS os_info,
    CAST(NULL AS nullable(string)) AS version_info
FROM device_updates
GROUP BY device_id;
