-- =================================================================
-- == ServiceRadar Consolidated Initial Schema
-- =================================================================
-- This single migration creates the entire database schema from scratch.
-- It consolidates all migrations from 20250610 through 20250701.

-- =================================================================
-- == Foundational Streams (from 20250610...)
-- =================================================================

-- Poller management streams
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

-- Service status tracking
CREATE STREAM IF NOT EXISTS service_status (
    poller_id string,
    service_name string,
    service_type string,
    available bool,
    details string,
    timestamp DateTime64(3) DEFAULT now64(3)
);

-- User authentication
CREATE STREAM IF NOT EXISTS users (
    id string,
    email string,
    name string,
    provider string,
    created_at DateTime64(3) DEFAULT now64(3),
    updated_at DateTime64(3) DEFAULT now64(3)
);

-- =================================================================
-- == System Monitoring Streams (Sysmon)
-- =================================================================

CREATE STREAM IF NOT EXISTS cpu_metrics (
    poller_id string,
    agent_id string,
    host_id string,
    timestamp DateTime64(3) DEFAULT now64(3),
    core_id int32,
    usage_percent float64
);

CREATE STREAM IF NOT EXISTS disk_metrics (
    poller_id string,
    agent_id string,
    host_id string,
    timestamp DateTime64(3) DEFAULT now64(3),
    mount_point string,
    used_bytes uint64,
    total_bytes uint64
);

CREATE STREAM IF NOT EXISTS memory_metrics (
    poller_id string,
    agent_id string,
    host_id string,
    timestamp DateTime64(3) DEFAULT now64(3),
    used_bytes uint64,
    total_bytes uint64
);

-- =================================================================
-- == Timeseries Metrics Stream (from 20250612...)
-- =================================================================

CREATE STREAM IF NOT EXISTS timeseries_metrics (
    poller_id string,
    target_device_ip string,      -- Added in 20250612
    ifIndex int32,                -- Added in 20250612
    metric_name string,
    metric_type string,
    value string,
    metadata string,
    timestamp DateTime64(3) DEFAULT now64(3)
);

-- =================================================================
-- == Discovery and Topology Streams
-- =================================================================

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

-- =================================================================
-- == Events Stream (from 20250622...)
-- =================================================================

CREATE STREAM IF NOT EXISTS events (
    -- CloudEvents standard attributes
    specversion string,
    id string,
    source string,
    type string,
    datacontenttype string,
    subject string,
    
    -- Syslog-specific data (flattened from data payload)
    remote_addr string,
    host string,
    level int32,
    severity string,
    short_message string,
    event_timestamp datetime64(3),
    version string,
    
    -- Raw data for auditing
    raw_data string
);

-- =================================================================
-- == Unified Device Pipeline (from 20250620-20250701)
-- =================================================================

-- Sweep results from discovery scans
CREATE STREAM IF NOT EXISTS sweep_results (
    agent_id string,
    poller_id string,
    partition string,             -- Added in 20250621
    discovery_source string,
    ip string,
    mac nullable(string),
    hostname nullable(string),
    timestamp DateTime64(3),
    available boolean,
    metadata map(string, string)
);

-- Unified device inventory (versioned KV store)
CREATE STREAM IF NOT EXISTS unified_devices (
    device_id string,             -- Format: partition:ip
    ip string,
    poller_id string,
    hostname nullable(string),
    mac nullable(string),
    discovery_sources array(string),  -- Changed from string to array in 20250622
    is_available boolean,
    first_seen DateTime64(3),
    last_seen DateTime64(3),
    metadata map(string, string)
) PRIMARY KEY (device_id)
SETTINGS mode='versioned_kv', version_column='_tp_time';

-- Materialized view to process sweep results into unified devices
CREATE MATERIALIZED VIEW IF NOT EXISTS unified_device_pipeline_mv
INTO unified_devices
AS SELECT
    concat(s.partition, ':', s.ip) AS device_id,
    s.ip,
    s.poller_id,
    if(s.hostname IS NOT NULL AND s.hostname != '', s.hostname, u.hostname) AS hostname,
    if(s.mac IS NOT NULL AND s.mac != '', s.mac, u.mac) AS mac,
    -- Accumulate discovery sources without duplicates (from 20250622)
    if(
        index_of(if_null(u.discovery_sources, []), s.discovery_source) > 0,
        u.discovery_sources,
        array_push_back(if_null(u.discovery_sources, []), s.discovery_source)
    ) AS discovery_sources,
    s.available AS is_available,
    coalesce(u.first_seen, s.timestamp) AS first_seen,
    s.timestamp AS last_seen,
    -- Merge metadata from different sources (from 20250701)
    if(
        length(s.metadata) > 0,
        if(u.metadata IS NULL, s.metadata, map_update(u.metadata, s.metadata)),
        u.metadata
    ) AS metadata
FROM sweep_results AS s
LEFT JOIN unified_devices AS u ON concat(s.partition, ':', s.ip) = u.device_id;