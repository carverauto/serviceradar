-- =================================================================
-- == ServiceRadar Consolidated Initial Schema
-- =================================================================
-- This single migration creates the entire database schema from scratch.
-- Includes race-condition and syntax corrections for unified device pipeline.

-- Cleanup old views and streams
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

-- =================================================================
-- == Foundational Streams
-- =================================================================

CREATE STREAM IF NOT EXISTS pollers (
    poller_id  string,
    first_seen DateTime64(3) DEFAULT now64(3),
    last_seen  DateTime64(3) DEFAULT now64(3),
    is_healthy bool
);

CREATE STREAM IF NOT EXISTS poller_history (
    poller_id string,
    timestamp  DateTime64(3) DEFAULT now64(3),
    is_healthy bool
);

CREATE STREAM IF NOT EXISTS service_status (
    poller_id    string,
    service_name string,
    service_type string,
    available    bool,
    details      string,
    timestamp    DateTime64(3) DEFAULT now64(3),
    agent_id     string,
    device_id    string,
    partition    string
);

CREATE STREAM IF NOT EXISTS users (
    id         string,
    email      string,
    name       string,
    provider   string,
    created_at DateTime64(3) DEFAULT now64(3),
    updated_at DateTime64(3) DEFAULT now64(3)
);

-- =================================================================
-- == Sysmon Streams
-- =================================================================

CREATE STREAM IF NOT EXISTS cpu_metrics (
    poller_id     string,
    agent_id      string,
    host_id       string,
    timestamp     DateTime64(3) DEFAULT now64(3),
    core_id       int32,
    usage_percent float64,
    device_id     string,
    partition     string
);

CREATE STREAM IF NOT EXISTS disk_metrics (
    poller_id   string,
    agent_id    string,
    host_id     string,
    timestamp   DateTime64(3) DEFAULT now64(3),
    mount_point string,
    used_bytes  uint64,
    total_bytes uint64,
    device_id   string,
    partition   string
);

CREATE STREAM IF NOT EXISTS memory_metrics (
    poller_id   string,
    agent_id    string,
    host_id     string,
    timestamp   DateTime64(3) DEFAULT now64(3),
    used_bytes  uint64,
    total_bytes uint64,
    device_id   string,
    partition   string
);

-- =================================================================
-- == Timeseries Metrics Stream
-- =================================================================

CREATE STREAM IF NOT EXISTS timeseries_metrics (
    poller_id        string,
    target_device_ip string,
    ifIndex          int32,
    metric_name      string,
    metric_type      string,
    value            string,
    metadata         string,
    timestamp        DateTime64(3) DEFAULT now64(3),
    device_id        string,
    partition        string
);

-- =================================================================
-- == Discovery and Topology Streams
-- =================================================================

CREATE STREAM IF NOT EXISTS discovered_interfaces (
    timestamp          DateTime64(3) DEFAULT now64(3),
    agent_id           string,
    poller_id          string,
    device_ip          string,
    device_id          string,
    ifIndex            int32,
    ifName             nullable(string),
    ifDescr            nullable(string),
    ifAlias            nullable(string),
    ifSpeed            uint64,
    ifPhysAddress      nullable(string),
    ip_addresses       array(string),
    ifAdminStatus      int32,
    ifOperStatus       int32,
    metadata           map(string, string)
);

CREATE STREAM IF NOT EXISTS topology_discovery_events (
    timestamp                   DateTime64(3) DEFAULT now64(3),
    agent_id                    string,
    poller_id                   string,
    local_device_ip             string,
    local_device_id             string,
    local_ifIndex               int32,
    local_ifName                nullable(string),
    protocol_type               string,
    neighbor_chassis_id         nullable(string),
    neighbor_port_id            nullable(string),
    neighbor_port_descr         nullable(string),
    neighbor_system_name        nullable(string),
    neighbor_management_address nullable(string),
    neighbor_bgp_router_id      nullable(string),
    neighbor_ip_address         nullable(string),
    neighbor_as                 nullable(uint32),
    bgp_session_state           nullable(string),
    metadata                    map(string, string)
);

-- =================================================================
-- == Events Stream
-- =================================================================

CREATE STREAM IF NOT EXISTS events (
    specversion     string,
    id              string,
    source          string,
    type            string,
    datacontenttype string,
    subject         string,
    remote_addr     string,
    host            string,
    level           int32,
    severity        string,
    short_message   string,
    event_timestamp DateTime64(3),
    version         string,
    raw_data        string
);

-- =================================================================
-- == Services Stream
-- =================================================================

CREATE STREAM IF NOT EXISTS services (
    poller_id    string,
    service_name string,
    service_type string,
    agent_id     string,
    timestamp    DateTime64(3) DEFAULT now64(3),
    device_id    string,
    partition    string
) PRIMARY KEY (poller_id, service_name)
  SETTINGS mode='versioned_kv', version_column='_tp_time';

-- =================================================================
-- == Unified Device Pipeline
-- =================================================================

CREATE STREAM IF NOT EXISTS sweep_results (
    agent_id         string,
    poller_id        string,
    partition        string,
    discovery_source string,
    ip               string,
    mac              nullable(string),
    hostname         nullable(string),
    timestamp        DateTime64(3),
    available        bool,
    metadata         map(string, string)
);

CREATE STREAM IF NOT EXISTS unified_devices (
    device_id         string,
    ip                string,
    poller_id         string,
    hostname          nullable(string),
    mac               nullable(string),
    discovery_sources array(string),
    is_available      bool,
    first_seen        DateTime64(3),
    last_seen         DateTime64(3),
    metadata          map(string, string),
    agent_id          string,
    device_type       string,
    service_type      nullable(string),
    service_status    nullable(string),
    last_heartbeat    nullable(DateTime64(3)),
    os_info           nullable(string),
    version_info      nullable(string)
) PRIMARY KEY (device_id)
  SETTINGS mode='versioned_kv', version_column='_tp_time';

CREATE STREAM IF NOT EXISTS unified_devices_changelog (
    device_id         string,
    ip                string,
    poller_id         string,
    hostname          nullable(string),
    mac               nullable(string),
    discovery_sources array(string),
    available         bool,
    timestamp         DateTime64(3),
    metadata          map(string, string),
    agent_id          string
);

CREATE MATERIALIZED VIEW IF NOT EXISTS unified_device_aggregator_mv
INTO unified_devices_changelog AS
SELECT
    concat(partition, ':', ip)      AS device_id,
    ip,
    arg_max(poller_id, timestamp)   AS poller_id,
    arg_max(hostname, timestamp)    AS hostname,
    arg_max(mac, timestamp)         AS mac,
    group_uniq_array(discovery_source) AS discovery_sources,
    arg_max(available, timestamp)   AS available,
    window_end                      AS timestamp,
    arg_max(metadata, timestamp)    AS metadata,
    arg_max(agent_id, timestamp)    AS agent_id
FROM tumble(sweep_results, timestamp, 2s)
GROUP BY ip, partition, window_end;

-- Simplified approach: just flatten and keep all sources (with potential duplicates)
-- This ensures we don't lose any discovery sources (like netbox) over time
-- Duplicates are acceptable as they don't affect functionality
CREATE MATERIALIZED VIEW IF NOT EXISTS unified_device_applier_mv
INTO unified_devices AS
SELECT
    device_id,
    ip,
    arg_max(poller_id, timestamp) AS poller_id,
    arg_max(hostname, timestamp) AS hostname,
    arg_max(mac, timestamp) AS mac,
    -- Flatten all arrays - this accumulates all discovery sources over time
    -- We accept duplicates since Timeplus doesn't support array_distinct in streaming
    array_flatten(group_array(discovery_sources)) AS discovery_sources,
    arg_max(available, timestamp) AS is_available,
    min(timestamp) AS first_seen,
    max(timestamp) AS last_seen,
    arg_max(metadata, timestamp) AS metadata,
    arg_max(agent_id, timestamp) AS agent_id,
    'network_device' AS device_type,
    CAST(NULL, 'nullable(string)') AS service_type,
    CAST(NULL, 'nullable(string)') AS service_status,
    CAST(NULL, 'nullable(DateTime64(3))') AS last_heartbeat,
    CAST(NULL, 'nullable(string)') AS os_info,
    CAST(NULL, 'nullable(string)') AS version_info
FROM unified_devices_changelog
GROUP BY device_id, ip;

-- =================================================================
-- == Unified Sysmon Materialized Views
-- =================================================================

CREATE STREAM IF NOT EXISTS cpu_aggregates (
    window_time     DateTime64(3),
    poller_id       string,
    agent_id        string,
    host_id         string,
    avg_cpu_usage   float64,
    device_id       string,
    partition       string
);

CREATE STREAM IF NOT EXISTS disk_aggregates (
    window_time       DateTime64(3),
    poller_id         string,
    agent_id          string,
    host_id           string,
    total_disk_bytes  uint64,
    used_disk_bytes   uint64,
    device_id         string,
    partition         string
);

CREATE STREAM IF NOT EXISTS memory_aggregates (
    window_time       DateTime64(3),
    poller_id         string,
    agent_id          string,
    host_id           string,
    total_memory_bytes uint64,
    used_memory_bytes  uint64,
    device_id          string,
    partition          string
);

CREATE MATERIALIZED VIEW IF NOT EXISTS cpu_aggregates_mv
INTO cpu_aggregates AS
SELECT
    window_start       AS window_time,
    poller_id,
    agent_id,
    host_id,
    avg(usage_percent) AS avg_cpu_usage,
    arg_max(device_id, timestamp) AS device_id,
    arg_max(partition, timestamp) AS partition
FROM tumble(cpu_metrics, timestamp, 10s)
GROUP BY window_start, poller_id, agent_id, host_id;

CREATE MATERIALIZED VIEW IF NOT EXISTS disk_aggregates_mv
INTO disk_aggregates AS
SELECT
    window_start       AS window_time,
    poller_id,
    agent_id,
    host_id,
    sum(total_bytes)   AS total_disk_bytes,
    sum(used_bytes)    AS used_disk_bytes,
    arg_max(device_id, timestamp) AS device_id,
    arg_max(partition, timestamp) AS partition
FROM tumble(disk_metrics, timestamp, 10s)
GROUP BY window_start, poller_id, agent_id, host_id;

CREATE MATERIALIZED VIEW IF NOT EXISTS memory_aggregates_mv
INTO memory_aggregates AS
SELECT
    window_start       AS window_time,
    poller_id,
    agent_id,
    host_id,
    arg_max(total_bytes, timestamp) AS total_memory_bytes,
    arg_max(used_bytes, timestamp)  AS used_memory_bytes,
    arg_max(device_id, timestamp)   AS device_id,
    arg_max(partition, timestamp)   AS partition
FROM tumble(memory_metrics, timestamp, 10s)
GROUP BY window_start, poller_id, agent_id, host_id;

CREATE STREAM IF NOT EXISTS unified_sysmon_metrics (
    timestamp            DateTime64(3),
    poller_id            string,
    agent_id             string,
    host_id              string,
    avg_cpu_usage        float64,
    total_disk_bytes     uint64,
    used_disk_bytes      uint64,
    total_memory_bytes   uint64,
    used_memory_bytes    uint64,
    device_id            string,
    partition            string
);

CREATE MATERIALIZED VIEW IF NOT EXISTS unified_sysmon_metrics_mv
INTO unified_sysmon_metrics AS
SELECT
    c.window_time           AS timestamp,
    c.poller_id             AS poller_id,
    c.agent_id              AS agent_id,
    c.host_id               AS host_id,
    c.avg_cpu_usage         AS avg_cpu_usage,
    d.total_disk_bytes      AS total_disk_bytes,
    d.used_disk_bytes       AS used_disk_bytes,
    m.total_memory_bytes    AS total_memory_bytes,
    m.used_memory_bytes     AS used_memory_bytes,
    c.device_id             AS device_id,
    c.partition             AS partition
FROM cpu_aggregates AS c
         LEFT JOIN disk_aggregates AS d
                   ON c.window_time = d.window_time
                       AND c.poller_id = d.poller_id
                       AND c.agent_id = d.agent_id
                       AND c.host_id = d.host_id
                       AND c.device_id = d.device_id
         LEFT JOIN memory_aggregates AS m
                   ON c.window_time = m.window_time
                       AND c.poller_id = m.poller_id
                       AND c.agent_id = m.agent_id
                       AND c.host_id = m.host_id
                       AND c.device_id = m.device_id;

-- =================================================================
-- == Unified Device Registry Stream (Application-Level Management)
-- =================================================================

CREATE STREAM IF NOT EXISTS unified_devices_registry (
    device_id         string,
    ip                string,
    hostname_field    string,  -- JSON-encoded DiscoveredField[string]
    mac_field         string,  -- JSON-encoded DiscoveredField[string]
    metadata_field    string,  -- JSON-encoded DiscoveredField[map[string]string]
    discovery_sources string,  -- JSON-encoded []DiscoverySourceInfo
    first_seen        DateTime64(3),
    last_seen         DateTime64(3),
    is_available      bool,
    device_type       string,
    service_type      nullable(string),
    service_status    nullable(string),
    last_heartbeat    nullable(DateTime64(3)),
    os_info           nullable(string),
    version_info      nullable(string)
) PRIMARY KEY (device_id)
  SETTINGS mode='versioned_kv', version_column='_tp_time';