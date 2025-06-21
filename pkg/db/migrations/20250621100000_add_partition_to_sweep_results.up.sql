-- Add partition column to sweep_results while preserving existing data
-- Drop dependent materialized view if it exists
DROP VIEW IF EXISTS unified_device_pipeline_mv;

-- Ensure the old stream exists (created automatically on some clusters)
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

-- Create new stream with the partition column
CREATE STREAM IF NOT EXISTS sweep_results_new (
    agent_id string,
    poller_id string,
    partition string,
    discovery_source string,
    ip string,
    mac nullable(string),
    hostname nullable(string),
    timestamp DateTime64(3),
    available boolean,
    metadata map(string, string)
);

-- Migrate existing data using an empty partition
INSERT INTO sweep_results_new (
    agent_id, poller_id, partition, discovery_source, ip, mac,
    hostname, timestamp, available, metadata
)
SELECT
    agent_id,
    poller_id,
    '' AS partition,
    discovery_source,
    ip,
    mac,
    hostname,
    timestamp,
    available,
    metadata
FROM table(sweep_results);

-- Replace old stream with the new one
DROP STREAM IF EXISTS sweep_results;
RENAME STREAM sweep_results_new TO sweep_results;

-- Recreate the materialized view
CREATE MATERIALIZED VIEW IF NOT EXISTS unified_device_pipeline_mv
INTO unified_devices
AS SELECT
    concat(partition, ':', ip) AS device_id,
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
