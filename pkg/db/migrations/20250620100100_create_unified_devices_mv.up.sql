-- Migration: Simple fix for unified devices
-- Date: 20250620200000
-- Description: Uses a single materialized view to prevent overwriting issues

-- Step 1: Clean up existing views
DROP VIEW IF EXISTS all_sources_to_unified_mv;
DROP VIEW IF EXISTS sweep_to_unified_mv;
DROP VIEW IF EXISTS devices_to_unified_mv;

-- Step 2: Ensure the source 'devices' stream exists
CREATE STREAM IF NOT EXISTS devices (
    device_id string,
    ip string,
    poller_id string,
    hostname nullable(string),
    mac nullable(string),
    discovery_source string,
    is_available boolean,
    first_seen DateTime64(3),
    last_seen DateTime64(3),
    agent_id string,
    metadata map(string, string)
);

-- Step 3: Ensure the source 'sweep_results' stream exists
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

-- Step 4: Ensure 'unified_devices' stream exists
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

-- Step 5: Create a materialized view from the 'devices' stream (Correctly uses a streaming query)
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
    last_seen AS _tp_time
FROM devices;

-- Step 6: Manually insert all sweep_results data using BOUNDED queries
INSERT INTO unified_devices (device_id, ip, poller_id, hostname, mac, discovery_source, is_available, first_seen, last_seen, metadata, agent_id, _tp_time)
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
    date_sub(now64(3), INTERVAL 1 SECOND) AS _tp_time
FROM table(sweep_results) -- Correctly using table() for a bounded query
WHERE (ip, agent_id, poller_id) NOT IN (
    SELECT ip, agent_id, poller_id FROM table(devices) -- Correctly using table() for a bounded query
);