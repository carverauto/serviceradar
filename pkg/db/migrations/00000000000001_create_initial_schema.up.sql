-- =================================================================
-- == ServiceRadar Unified Device Registry Schema
-- =================================================================
-- This schema eliminates race conditions by using application-level 
-- device management instead of materialized views.

-- =================================================================
-- == Core Data Streams
-- =================================================================

-- Raw sweep results from network discovery
CREATE STREAM IF NOT EXISTS sweep_results (
    agent_id          string,
    poller_id         string,
    partition         string,
    discovery_source  string,
    ip                string,
    mac               nullable(string),
    hostname          nullable(string),
    timestamp         DateTime64(3),
    available         bool,
    metadata          string
);

-- Unified device registry - application-managed device inventory
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

-- Legacy unified devices stream (for backward compatibility)
CREATE STREAM IF NOT EXISTS unified_devices (
    agent_id          string,
    poller_id         string,
    partition         string,
    device_id         string,
    ip                string,
    hostname          nullable(string),
    mac               nullable(string),
    first_seen        DateTime64(3),
    last_seen         DateTime64(3),
    is_available      bool,
    device_type       string,
    service_type      nullable(string),
    service_status    nullable(string),
    last_heartbeat    nullable(DateTime64(3)),
    os_info           nullable(string),
    version_info      nullable(string),
    metadata          string,
    discovery_sources array(string)
) PRIMARY KEY (device_id)
  SETTINGS mode='versioned_kv', version_column='_tp_time';

-- =================================================================
-- == Network Discovery Streams
-- =================================================================

-- SNMP discovery results (versioned key-value to prevent duplicates)
CREATE STREAM IF NOT EXISTS discovered_interfaces (
    timestamp         DateTime64(3),
    agent_id          string,
    poller_id         string,
    device_ip         string,
    device_id         string,
    if_index          int32,
    if_name           string,
    if_descr          string,
    if_alias          string,
    if_speed          uint64,
    if_phys_address   string,
    ip_addresses      array(string),
    if_admin_status   int32,
    if_oper_status    int32,
    metadata          string
) PRIMARY KEY (device_id, if_index)
  SETTINGS mode='versioned_kv', version_column='_tp_time';

-- Network topology discovery
CREATE STREAM IF NOT EXISTS topology_discovery_events (
    timestamp                  DateTime64(3),
    agent_id                   string,
    poller_id                  string,
    local_device_ip            string,
    local_device_id            string,
    local_if_index             int32,
    local_if_name              string,
    protocol_type              string,
    neighbor_chassis_id        string,
    neighbor_port_id           string,
    neighbor_port_descr        string,
    neighbor_system_name       string,
    neighbor_management_addr   string,
    neighbor_bgp_router_id     string,
    neighbor_ip_address        string,
    neighbor_as                uint32,
    bgp_session_state          string,
    metadata                   string
);

-- =================================================================
-- == Metrics and Monitoring Streams
-- =================================================================

-- Time-series metrics (SNMP, ICMP, etc.)
CREATE STREAM IF NOT EXISTS timeseries_metrics (
    timestamp         DateTime64(3),
    poller_id         string,
    agent_id          string,
    metric_name       string,
    metric_type       string,
    device_id         string,
    value             float64,
    unit              string,
    tags              map(string, string),
    partition         string,
    scale             float64,
    is_delta          bool,
    target_device_ip  nullable(string),
    ifIndex           nullable(int32),
    metadata          string
);

-- System monitoring metrics
CREATE STREAM IF NOT EXISTS cpu_metrics (
    timestamp         DateTime64(3),
    poller_id         string,
    agent_id          string,
    host_id           string,
    core_id           int32,
    usage_percent     float64,
    device_id         string,
    partition         string
);

CREATE STREAM IF NOT EXISTS disk_metrics (
    timestamp         DateTime64(3),
    poller_id         string,
    agent_id          string,
    host_id           string,
    mount_point       string,
    device_name       string,
    total_bytes       uint64,
    used_bytes        uint64,
    available_bytes   uint64,
    usage_percent     float64,
    device_id         string,
    partition         string
);

CREATE STREAM IF NOT EXISTS memory_metrics (
    timestamp         DateTime64(3),
    poller_id         string,
    agent_id          string,
    host_id           string,
    total_bytes       uint64,
    used_bytes        uint64,
    available_bytes   uint64,
    usage_percent     float64,
    device_id         string,
    partition         string
);

-- =================================================================
-- == Service Management Streams
-- =================================================================

-- Service status tracking
CREATE STREAM IF NOT EXISTS service_statuses (
    timestamp         DateTime64(3),
    poller_id         string,
    agent_id          string,
    service_name      string,
    service_type      string,
    is_healthy        bool,
    message           string,
    details           string,
    partition         string
);

-- Service status (legacy name for backward compatibility)
CREATE STREAM IF NOT EXISTS service_status (
    timestamp         DateTime64(3),
    poller_id         string,
    agent_id          string,
    service_name      string,
    service_type      string,
    available         bool,
    message           string,
    details           string,
    partition         string
);

-- Service definitions
CREATE STREAM IF NOT EXISTS services (
    timestamp         DateTime64(3),
    poller_id         string,
    agent_id          string,
    service_name      string,
    service_type      string,
    config            map(string, string),
    partition         string
);

-- Poller registry - current state
CREATE STREAM IF NOT EXISTS pollers (
    poller_id         string,
    first_seen        DateTime64(3),
    last_seen         DateTime64(3),
    is_healthy        bool
) PRIMARY KEY (poller_id)
  SETTINGS mode='versioned_kv', version_column='_tp_time';

-- Poller health tracking history
CREATE STREAM IF NOT EXISTS poller_history (
    timestamp         DateTime64(3),
    poller_id         string,
    is_healthy        bool
);

-- Poller health tracking events
CREATE STREAM IF NOT EXISTS poller_statuses (
    timestamp         DateTime64(3),
    poller_id         string,
    agent_id          string,
    is_healthy        bool,
    first_seen        DateTime64(3),
    last_seen         DateTime64(3),
    uptime_seconds    uint64,
    partition         string
);

-- =================================================================
-- == Events and Alerting Streams
-- =================================================================

-- System and network events
CREATE STREAM IF NOT EXISTS events (
    id                string,
    event_timestamp   DateTime64(3),
    severity          string,
    event_type        string,
    source            string,
    device_id         nullable(string),
    poller_id         nullable(string),
    agent_id          nullable(string),
    title             string,
    description       string,
    metadata          string,
    acknowledged      bool,
    acknowledged_by   nullable(string),
    acknowledged_at   nullable(DateTime64(3))
) PRIMARY KEY (id)
  SETTINGS mode='versioned_kv', version_column='_tp_time';

-- =================================================================
-- == Network Flow and Security Streams
-- =================================================================

-- NetFlow data
CREATE STREAM IF NOT EXISTS netflow_metrics (
    timestamp         DateTime64(3),
    agent_id          string,
    poller_id         string,
    src_ip            string,
    dst_ip            string,
    src_port          uint16,
    dst_port          uint16,
    protocol          uint8,
    bytes             uint64,
    packets           uint64,
    duration_ms       uint64,
    tcp_flags         uint8,
    tos               uint8,
    partition         string
);

-- Performance testing results
CREATE STREAM IF NOT EXISTS rperf_metrics (
    timestamp         DateTime64(3),
    poller_id         string,
    service_name      string,
    message           string
);

-- =================================================================
-- == User Management
-- =================================================================

-- User accounts and authentication
CREATE STREAM IF NOT EXISTS users (
    id                string,
    username          string,
    email             string,
    password_hash     string,
    created_at        DateTime64(3),
    updated_at        DateTime64(3),
    is_active         bool,
    roles             array(string)
) PRIMARY KEY (id)
  SETTINGS mode='versioned_kv', version_column='_tp_time';

-- =================================================================
-- == Performance Optimization Views
-- =================================================================

-- Device aggregates for fast queries (replaces legacy materialized views)
CREATE STREAM IF NOT EXISTS device_metrics_summary (
    window_time       DateTime64(3),
    device_id         string,
    poller_id         string,
    agent_id          string,
    partition         string,
    avg_cpu_usage     float64,
    total_disk_bytes  uint64,
    used_disk_bytes   uint64,
    total_memory_bytes uint64,
    used_memory_bytes  uint64,
    metric_count      uint64
);

-- Create materialized view for device metrics aggregation
CREATE MATERIALIZED VIEW IF NOT EXISTS device_metrics_aggregator_mv
INTO device_metrics_summary AS
SELECT
    c.window_start                  AS window_time,
    c.device_id                     AS device_id,
    c.poller_id                     AS poller_id,
    c.agent_id                      AS agent_id,
    c.partition                     AS partition,
    avg(c.usage_percent)            AS avg_cpu_usage,
    any(d.total_bytes)              AS total_disk_bytes,
    any(d.used_bytes)               AS used_disk_bytes,
    any(m.total_bytes)              AS total_memory_bytes,
    any(m.used_bytes)               AS used_memory_bytes,
    count(*)                        AS metric_count
FROM hop(cpu_metrics, timestamp, 10s, 60s) AS c
LEFT JOIN hop(disk_metrics, timestamp, 10s, 60s) AS d
    ON c.window_start = d.window_start 
    AND c.device_id = d.device_id
    AND c.poller_id = d.poller_id
LEFT JOIN hop(memory_metrics, timestamp, 10s, 60s) AS m
    ON c.window_start = m.window_start
    AND c.device_id = m.device_id  
    AND c.poller_id = m.poller_id
GROUP BY c.window_start, c.device_id, c.poller_id, c.agent_id, c.partition;