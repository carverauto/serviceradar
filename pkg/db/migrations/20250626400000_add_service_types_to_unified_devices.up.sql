-- Add service type support to unified_devices instead of creating separate streams
-- Note: This migration recreates the unified_devices stream to add service device columns

-- Drop existing materialized view first
DROP VIEW IF EXISTS unified_device_pipeline_mv;

-- Drop existing stream
DROP STREAM IF EXISTS unified_devices;

-- Recreate unified_devices with service device columns
CREATE STREAM unified_devices (
    device_id string,
    ip string,
    poller_id string,
    hostname nullable(string),
    mac nullable(string),
    discovery_sources array(string),
    is_available boolean,
    first_seen DateTime64(3),
    last_seen DateTime64(3),
    metadata map(string, string),
    agent_id string,
    device_type string DEFAULT 'network_device',
    service_type string DEFAULT '',
    service_status string DEFAULT 'unknown',
    last_heartbeat DATETIME DEFAULT NOW(),
    os_info string DEFAULT '',
    version_info string DEFAULT ''
) PRIMARY KEY (device_id)
SETTINGS mode='versioned_kv', version_column='_tp_time';

-- Recreate the materialized view
CREATE MATERIALIZED VIEW unified_device_pipeline_mv
INTO unified_devices
AS
SELECT
    concat(s.partition, ':', s.ip) AS device_id,
    s.ip,
    s.poller_id,
    s.hostname,
    s.mac,
    CASE WHEN s.discovery_source = '' THEN [] ELSE [s.discovery_source] END as discovery_sources,
    s.is_available,
    s.first_seen,
    s.last_seen,
    s.metadata,
    s.agent_id,
    'network_device' AS device_type,
    '' AS service_type,
    'unknown' AS service_status,
    NOW() AS last_heartbeat,
    '' AS os_info,
    '' AS version_info
FROM device_pipeline s;