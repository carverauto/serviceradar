-- =================================================================
-- == ServiceRadar Consolidated Initial Schema
-- =================================================================
-- This single migration creates the entire database schema from scratch.
-- Includes the fix for unified_device_pipeline_mv race condition.

-- Foundational Streams (from 20250610...)
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

-- Sysmon Streams (final correct schema)
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

-- Timeseries Metrics Stream (from 20250612...)
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

-- Discovery and Topology Streams (from 20250610...)
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

-- Events Stream (from 20250622...)
CREATE STREAM IF NOT EXISTS events (
    specversion string, id string, source string, type string,
    datacontenttype string, subject string, remote_addr string,
    host string, level int32, severity string, short_message string,
    event_timestamp datetime64(3), version string, raw_data string
);

-- Services Stream (from 20250702...)
CREATE STREAM IF NOT EXISTS services (
    poller_id string, service_name string, service_type string,
    agent_id string, timestamp DateTime64(3) DEFAULT now64(3),
    device_id string, partition string
) PRIMARY KEY (poller_id, service_name)
SETTINGS mode='versioned_kv', version_column='_tp_time';

-- Unified Device Pipeline (with corrected race condition fix)
CREATE STREAM IF NOT EXISTS sweep_results (
    agent_id string, poller_id string, partition string,
    discovery_source string, ip string, mac nullable(string),
    hostname nullable(string), timestamp DateTime64(3),
    available boolean, metadata map(string, string)
);

CREATE STREAM IF NOT EXISTS unified_devices (
    device_id string, ip string, poller_id string, hostname nullable(string),
    mac nullable(string), discovery_sources array(string), is_available boolean,
    first_seen DateTime64(3), last_seen DateTime64(3), metadata map(string, string),
    agent_id string, device_type string DEFAULT 'network_device',
    service_type nullable(string), service_status nullable(string),
    last_heartbeat nullable(DateTime64(3)), os_info nullable(string), version_info nullable(string)
) PRIMARY KEY (device_id)
SETTINGS mode='versioned_kv', version_column='_tp_time';

-- Fixed materialized view with "preserve existing" merge strategy
CREATE MATERIALIZED VIEW IF NOT EXISTS unified_device_pipeline_mv
INTO unified_devices
AS SELECT
    concat(s.partition, ':', s.ip) AS device_id,
    s.ip,
    -- Change: Prefer existing poller_id if it's populated
    if(u.poller_id IS NOT NULL AND u.poller_id != '', u.poller_id, s.poller_id) AS poller_id,
    -- Change: Prefer existing hostname if it's populated
    if(u.hostname IS NOT NULL AND u.hostname != '', u.hostname, s.hostname) AS hostname,
    -- Change: Prefer existing mac if it's populated
    if(u.mac IS NOT NULL AND u.mac != '', u.mac, s.mac) AS mac,
    -- This logic for discovery_sources is correct and remains unchanged
    if( index_of(if_null(u.discovery_sources, []), s.discovery_source) = 0, array_push_back(if_null(u.discovery_sources, []), s.discovery_source), u.discovery_sources ) AS discovery_sources,
    s.available AS is_available,
    coalesce(u.first_seen, s.timestamp) AS first_seen,
    s.timestamp AS last_seen,
    -- This metadata merge logic is correct and remains unchanged
    if( length(s.metadata) > 0, if(u.metadata IS NULL, s.metadata, map_update(u.metadata, s.metadata)), u.metadata ) AS metadata,
    -- Change: Prefer existing agent_id if it's populated
    if(u.agent_id IS NOT NULL AND u.agent_id != '', u.agent_id, s.agent_id) AS agent_id,
    -- This device_type logic is correct for preserving the existing type
    if(u.device_id IS NULL, 'network_device', u.device_type) AS device_type,
    -- These fields are correctly preserved from the existing record
    u.service_type, u.service_status, u.last_heartbeat, u.os_info, u.version_info
FROM sweep_results AS s
LEFT JOIN unified_devices AS u ON concat(s.partition, ':', s.ip) = u.device_id;


-- =================================================================
-- == Unified Sysmon Materialized Views (final working version)
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
SELECT window_start as window_time, poller_id, agent_id, host_id, avg(usage_percent) as avg_cpu_usage, any(device_id) as device_id, any(partition) as partition
FROM tumble(cpu_metrics, timestamp, 10s)
GROUP BY window_start, poller_id, agent_id, host_id;

CREATE MATERIALIZED VIEW IF NOT EXISTS disk_aggregates_mv INTO disk_aggregates AS
SELECT window_start as window_time, poller_id, agent_id, host_id, sum(total_bytes) as total_disk_bytes, sum(used_bytes) as used_disk_bytes, any(device_id) as device_id, any(partition) as partition
FROM tumble(disk_metrics, timestamp, 10s)
GROUP BY window_start, poller_id, agent_id, host_id;

CREATE MATERIALIZED VIEW IF NOT EXISTS memory_aggregates_mv INTO memory_aggregates AS
SELECT window_start as window_time, poller_id, agent_id, host_id, any(total_bytes) as total_memory_bytes, any(used_bytes) as used_memory_bytes, any(device_id) as device_id, any(partition) as partition
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