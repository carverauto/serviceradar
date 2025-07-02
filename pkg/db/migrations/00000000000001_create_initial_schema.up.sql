-- =================================================================
-- == ServiceRadar Consolidated Initial Schema
-- =================================================================
-- This single migration creates the entire database schema from scratch.
-- Includes the fix for unified_device_pipeline_mv race condition and all syntax corrections.

-- Cleanup old/new views and streams to ensure a clean slate on migration
DROP VIEW IF EXISTS unified_device_pipeline_mv;
DROP VIEW IF EXISTS unified_device_applier_mv;
DROP VIEW IF EXISTS unified_device_aggregator_mv;
DROP STREAM IF EXISTS unified_devices_changelog;
DROP VIEW IF EXISTS cpu_aggregates_mv;
DROP VIEW IF EXISTS disk_aggregates_mv;
DROP VIEW IF EXISTS memory_aggregates_mv;
DROP VIEW IF EXISTS unified_sysmon_metrics_mv;
DROP STREAM IF EXISTS cpu_aggregates;
DROP STREAM IF EXISTS disk_aggregates;
DROP STREAM IF EXISTS memory_aggregates;
DROP STREAM IF EXISTS unified_sysmon_metrics;


-- Foundational Streams
CREATE STREAM IF NOT EXISTS pollers (
    poller_id string,
    first_seen DateTime64(3) DEFAULT now64(3),
    last_seen DateTime64(3) DEFAULT now64(3),
    is_healthy bool
);

CREATE STREAM IF NOT EXISTS poller_history (
    poller_id string,
    timestamp DateTime64(3) DEFAULT now64(3),
    is_healthy bool
);

CREATE STREAM IF NOT EXISTS service_status (
    poller_id string,
    service_name string,
    service_type string,
    available bool,
    details string,
    timestamp DateTime64(3) DEFAULT now64(3),
    agent_id string,
    device_id string,
    partition string
);

CREATE STREAM IF NOT EXISTS users (
    id string,
    email string,
    name string,
    provider string,
    created_at DateTime64(3) DEFAULT now64(3),
    updated_at DateTime64(3) DEFAULT now64(3)
);

-- Sysmon Streams
CREATE STREAM IF NOT EXISTS cpu_metrics (
    poller_id string,
    agent_id string,
    host_id string,
    timestamp DateTime64(3) DEFAULT now64(3),
    core_id int32,
    usage_percent float64,
    device_id string,
    partition string
);

CREATE STREAM IF NOT EXISTS disk_metrics (
    poller_id string,
    agent_id string,
    host_id string,
    timestamp DateTime64(3) DEFAULT now64(3),
    mount_point string,
    used_bytes uint64,
    total_bytes uint64,
    device_id string,
    partition string
);

CREATE STREAM IF NOT EXISTS memory_metrics (
    poller_id string,
    agent_id string,
    host_id string,
    timestamp DateTime64(3) DEFAULT now64(3),
    used_bytes uint64,
    total_bytes uint64,
    device_id string,
    partition string
);

-- Timeseries Metrics Stream
CREATE STREAM IF NOT EXISTS timeseries_metrics (
    poller_id string,
    target_device_ip string,
    ifIndex int32,
    metric_name string,
    metric_type string,
    value string,
    metadata string,
    timestamp DateTime64(3) DEFAULT now64(3),
    device_id string,
    partition string
);

-- Discovery and Topology Streams
CREATE STREAM IF NOT EXISTS discovered_interfaces (
    timestamp DateTime64(3) DEFAULT now64(3),
    agent_id string,
    poller_id string,
    device_ip string,
    device_id string,
    ifIndex int32,
    ifName nullable(string),
    ifDescr nullable(string),
    ifAlias nullable(string),
    ifSpeed uint64,
    ifPhysAddress nullable(string),
    ip_addresses array(string),
    ifAdminStatus int32,
    ifOperStatus int32,
    metadata map(string, string)
);

CREATE STREAM IF NOT EXISTS topology_discovery_events (
    timestamp DateTime64(3) DEFAULT now64(3),
    agent_id string,
    poller_id string,
    local_device_ip string,
    local_device_id string,
    local_ifIndex int32,
    local_ifName nullable(string),
    protocol_type string,
    neighbor_chassis_id nullable(string),
    neighbor_port_id nullable(string),
    neighbor_port_descr nullable(string),
    neighbor_system_name nullable(string),
    neighbor_management_address nullable(string),
    neighbor_bgp_router_id nullable(string),
    neighbor_ip_address nullable(string),
    neighbor_as nullable(uint32),
    bgp_session_state nullable(string),
    metadata map(string, string)
);

-- Events Stream
CREATE STREAM IF NOT EXISTS events (
    specversion string, id string, source string, type string,
    datacontenttype string, subject string, remote_addr string,
    host string, level int32, severity string, short_message string,
    event_timestamp datetime64(3), version string, raw_data string
);

-- Services Stream
CREATE STREAM IF NOT EXISTS services (
    poller_id string, service_name string, service_type string,
    agent_id string, timestamp DateTime64(3) DEFAULT now64(3),
    device_id string, partition string
) PRIMARY KEY (poller_id, service_name)
SETTINGS mode='versioned_kv', version_column='_tp_time';

-- =================================================================
-- == Unified Device Pipeline (RACE CONDITION AND SYNTAX FIX)
-- =================================================================

-- Source stream for all raw device discovery events
CREATE STREAM IF NOT EXISTS sweep_results (
    agent_id string, poller_id string, partition string,
    discovery_source string, ip string, mac nullable(string),
    hostname nullable(string), timestamp DateTime64(3),
    available boolean, metadata map(string, string)
);

-- Final Versioned-KV stream that holds the unified state of all devices
CREATE STREAM IF NOT EXISTS unified_devices (
    device_id string, ip string, poller_id string, hostname nullable(string),
    mac nullable(string), discovery_sources array(string), is_available boolean,
    first_seen DateTime64(3), last_seen DateTime64(3), metadata map(string, string),
    agent_id string, device_type string,
    service_type nullable(string), service_status nullable(string),
    last_heartbeat nullable(DateTime64(3)), os_info nullable(string), version_info nullable(string)
) PRIMARY KEY (device_id)
SETTINGS mode='versioned_kv', version_column='_tp_time';

-- Intermediate stream to hold aggregated results from `sweep_results`.
CREATE STREAM IF NOT EXISTS unified_devices_changelog (
    device_id string,
    ip string,
    poller_id string,
    hostname nullable(string),
    mac nullable(string),
    discovery_sources array(string),
    available boolean,
    timestamp DateTime64(3),
    metadata map(string, string),
    agent_id string
);

-- STAGE 1 MV: Aggregate `sweep_results` into `unified_devices_changelog`.
CREATE MATERIALIZED VIEW IF NOT EXISTS unified_device_aggregator_mv
INTO unified_devices_changelog
AS SELECT
                                                                                                                                           concat(partition, ':', ip) as device_id,
                                                                                                                                           ip,
                                                                                                                                           arg_max(poller_id, timestamp) as poller_id,
                                                                                                                                           arg_max(hostname, timestamp) as hostname,
                                                                                                                                           arg_max(mac, timestamp) as mac,
                                                                                                                                           group_uniq_array(discovery_source) as discovery_sources,
                                                                                                                                           arg_max(available, timestamp) as available,
                                                                                                                                           window_end as timestamp,
                                                                                                                                           arg_max(metadata, timestamp) as metadata,
                                                                                                                                           arg_max(agent_id, timestamp) as agent_id
   FROM tumble(sweep_results, timestamp, 2s)
   GROUP BY ip, partition, window_end;

-- STAGE 2 MV: Apply the aggregated changes to the final `unified_devices` kv-stream.
-- This version uses correct, validated functions to prevent all previous errors.
CREATE MATERIALIZED VIEW IF NOT EXISTS unified_device_applier_mv
INTO unified_devices
AS
SELECT
    s.device_id,
    s.ip,
    arg_max(s.poller_id, s.timestamp) AS poller_id,
    arg_max(s.hostname, s.timestamp) AS hostname,
    arg_max(s.mac, s.timestamp) AS mac,
    group_uniq_array(source) AS discovery_sources,
    arg_max(s.available, s.timestamp) AS is_available,
    min(s.timestamp) AS first_seen,
    max(s.timestamp) AS last_seen,
    arg_max(s.metadata, s.timestamp) AS metadata, -- Use arg_max for "last write wins" on metadata
    arg_max(s.agent_id, s.timestamp) AS agent_id,
    coalesce(arg_max(s.metadata['device_type'], s.timestamp), 'network_device') AS device_type,
    CAST(null, 'nullable(string)') as service_type,
    CAST(null, 'nullable(string)') as service_status,
    CAST(null, 'nullable(datetime64(3))') as last_heartbeat,
    CAST(null, 'nullable(string)') as os_info,
    CAST(null, 'nullable(string)') as version_info
FROM unified_devices_changelog AS s
    ARRAY JOIN s.discovery_sources as source
GROUP BY s.device_id, s.ip;


-- =================================================================
-- == Unified Sysmon Materialized Views (IMPROVED LOGIC)
-- =================================================================
-- Step 1: Create intermediate aggregation streams
CREATE STREAM IF NOT EXISTS cpu_aggregates (
    window_time DateTime64(3), poller_id string, agent_id string, host_id string, avg_cpu_usage float64, device_id string, partition string
);
CREATE STREAM IF NOT EXISTS disk_aggregates (
    window_time DateTime64(3), poller_id string, agent_id string, host_id string, total_disk_bytes uint64, used_disk_bytes uint64, device_id string, partition string
);
CREATE STREAM IF NOT EXISTS memory_aggregates (
    window_time DateTime64(3), poller_id string, agent_id string, host_id string, total_memory_bytes uint64, used_memory_bytes uint64, device_id string, partition string
);

-- Step 2: Create materialized views for aggregation
CREATE MATERIALIZED VIEW IF NOT EXISTS cpu_aggregates_mv INTO cpu_aggregates AS
SELECT window_start as window_time, poller_id, agent_id, host_id, avg(usage_percent) as avg_cpu_usage, arg_max(device_id, timestamp) as device_id, arg_max(partition, timestamp) as partition
FROM tumble(cpu_metrics, timestamp, 10s)
GROUP BY window_start, poller_id, agent_id, host_id;

CREATE MATERIALIZED VIEW IF NOT EXISTS disk_aggregates_mv INTO disk_aggregates AS
SELECT window_start as window_time, poller_id, agent_id, host_id, sum(total_bytes) as total_disk_bytes, sum(used_bytes) as used_disk_bytes, arg_max(device_id, timestamp) as device_id, arg_max(partition, timestamp) as partition
FROM tumble(disk_metrics, timestamp, 10s)
GROUP BY window_start, poller_id, agent_id, host_id;

CREATE MATERIALIZED VIEW IF NOT EXISTS memory_aggregates_mv INTO memory_aggregates AS
SELECT window_start as window_time, poller_id, agent_id, host_id, arg_max(total_bytes, timestamp) as total_memory_bytes, arg_max(used_bytes, timestamp) as used_memory_bytes, arg_max(device_id, timestamp) as device_id, arg_max(partition, timestamp) as partition
FROM tumble(memory_metrics, timestamp, 10s)
GROUP BY window_start, poller_id, agent_id, host_id;

-- Step 3: Create the final unified stream
CREATE STREAM IF NOT EXISTS unified_sysmon_metrics (
    timestamp DateTime64(3), poller_id string, agent_id string, host_id string,
    avg_cpu_usage float64, total_disk_bytes uint64, used_disk_bytes uint64,
    total_memory_bytes uint64, used_memory_bytes uint64, device_id string, partition string
);

-- Step 4: Create the final materialized view that joins all aggregated data
CREATE MATERIALIZED VIEW IF NOT EXISTS unified_sysmon_metrics_mv INTO unified_sysmon_metrics AS
SELECT
    c.window_time as timestamp, c.poller_id as poller_id, c.agent_id as agent_id, c.host_id as host_id,
    c.avg_cpu_usage as avg_cpu_usage, d.total_disk_bytes as total_disk_bytes, d.used_disk_bytes as used_disk_bytes,
    m.total_memory_bytes as total_memory_bytes, m.used_memory_bytes as used_memory_bytes, c.device_id as device_id, c.partition as partition
FROM cpu_aggregates AS c
         LEFT JOIN disk_aggregates AS d ON c.window_time = d.window_time AND c.poller_id = d.poller_id AND c.agent_id = d.agent_id AND c.host_id = d.host_id AND c.device_id = d.device_id
         LEFT JOIN memory_aggregates AS m ON c.window_time = m.window_time AND c.poller_id = m.poller_id AND c.agent_id = m.agent_id AND c.host_id = m.host_id AND c.device_id = m.device_id;