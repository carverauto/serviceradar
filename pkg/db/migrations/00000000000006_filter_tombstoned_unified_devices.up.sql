-- Filter tombstoned and deleted device records out of the unified device pipeline.
DROP VIEW IF EXISTS unified_device_pipeline_mv;

CREATE MATERIALIZED VIEW unified_device_pipeline_mv
INTO unified_devices
AS
SELECT
    device_id,
    arg_max_if(ip, timestamp, is_active AND has_identity) AS ip,
    arg_max_if(poller_id, timestamp, is_active AND has_identity) AS poller_id,
    arg_max_if(agent_id, timestamp, is_active AND has_identity) AS agent_id,
    arg_max_if(hostname, timestamp, is_active AND has_identity) AS hostname,
    arg_max_if(mac, timestamp, is_active AND has_identity) AS mac,
    group_uniq_array_if(discovery_source, is_active AND has_identity) AS discovery_sources,
    arg_max_if(available, timestamp, is_active AND has_identity) AS is_available,
    min_if(timestamp, is_active AND has_identity) AS first_seen,
    max_if(timestamp, is_active AND has_identity) AS last_seen,
    arg_max_if(metadata, timestamp, is_active AND has_identity) AS metadata,
    'network_device' AS device_type,
    CAST(NULL AS nullable(string)) AS service_type,
    CAST(NULL AS nullable(string)) AS service_status,
    CAST(NULL AS nullable(DateTime64(3))) AS last_heartbeat,
    CAST(NULL AS nullable(string)) AS os_info,
    CAST(NULL AS nullable(string)) AS version_info
FROM (
    SELECT
        device_id,
        ip,
        poller_id,
        agent_id,
        hostname,
        mac,
        discovery_source,
        available,
        timestamp,
        metadata,
        coalesce(metadata['_merged_into'], '') AS merged_into,
        lower(coalesce(metadata['_deleted'], 'false')) AS deleted_flag,
        coalesce(metadata['armis_device_id'], '') AS armis_device_id,
        coalesce(metadata['integration_id'], metadata['netbox_device_id'], '') AS external_id,
        coalesce(mac, '') AS mac_value,
        (coalesce(metadata['_merged_into'], '') = '' AND lower(coalesce(metadata['_deleted'], 'false')) != 'true') AS is_active,
        (
            coalesce(metadata['armis_device_id'], '') != ''
            OR coalesce(metadata['integration_id'], metadata['netbox_device_id'], '') != ''
            OR coalesce(mac, '') != ''
        ) AS has_identity
    FROM device_updates
) AS src
GROUP BY device_id
HAVING count_if(is_active AND has_identity) > 0;

ALTER STREAM unified_devices
    DELETE WHERE coalesce(metadata['_merged_into'], '') != ''
       OR lower(coalesce(metadata['_deleted'], 'false')) = 'true'
       OR (
            coalesce(metadata['armis_device_id'], '') = ''
            AND coalesce(metadata['integration_id'], metadata['netbox_device_id'], '') = ''
            AND coalesce(mac, '') = ''
       );

ALTER STREAM unified_devices_registry
    DELETE WHERE coalesce(metadata['_merged_into'], '') != ''
       OR lower(coalesce(metadata['_deleted'], 'false')) = 'true'
       OR (
            coalesce(metadata['armis_device_id'], '') = ''
            AND coalesce(metadata['integration_id'], metadata['netbox_device_id'], '') = ''
            AND ifNull(mac, '') = ''
       );
