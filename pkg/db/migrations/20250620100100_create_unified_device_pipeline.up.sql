-- Unified discovery pipeline
-- Drops old devices stream and creates single materialized view

DROP STREAM IF EXISTS devices;

CREATE STREAM IF NOT EXISTS sweep_results (
    agent_id string,
    poller_id string,
    discovery_source string,
    ip string,
    mac nullable(string),
    hostname nullable(string),
    timestamp DateTime64(3),
    available boolean,
    metadata map(string, string)
);

CREATE STREAM IF NOT EXISTS unified_devices (
    device_id string,
    ip string,
    poller_id string,
    hostname nullable(string),
    mac nullable(string),
    discovery_source string,
    is_available boolean,
    first_seen DateTime64(3),
    last_seen DateTime64(3),
    metadata map(string, string),
    agent_id string
)
PRIMARY KEY (device_id)
SETTINGS mode='versioned_kv', version_column='_tp_time';

CREATE MATERIALIZED VIEW IF NOT EXISTS unified_device_pipeline_mv
INTO unified_devices
AS SELECT
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
    timestamp AS _tp_time
FROM sweep_results;

