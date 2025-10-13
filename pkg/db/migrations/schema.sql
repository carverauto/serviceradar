-- =================================================================
-- == ServiceRadar Complete Database Schema - Rebuild w/ TTL plan
-- =================================================================
-- TTL policy:
--   • 3d: logs, traces, otel metrics, raw runtime metrics, flows, events
--   • 7d: topology discovery, poller_history, poller_statuses
--   • 30d: everything else EXCEPT users (no TTL)
-- Notes:
--   • Timeplus/ClickHouse enforces TTL during background merges (not instant).
--   • _tp_time is the ingestion/version time; we prefer domain timestamps
--     when present, and fall back to _tp_time.

-- =================================================================
-- == Core Data Streams
-- =================================================================

-- Latest sweep host states (versioned_kv) – 3d TTL
CREATE STREAM IF NOT EXISTS sweep_host_states (
    host_ip           string,
    poller_id         string,
    agent_id          string,
    partition         string,
    network_cidr      nullable(string),
    hostname          nullable(string),
    mac               nullable(string),
    icmp_available    bool,
    icmp_response_time_ns nullable(int64),
    icmp_packet_loss  nullable(float64),
    tcp_ports_scanned string,
    tcp_ports_open    string,
    port_scan_results string,
    last_sweep_time   DateTime64(3),
    first_seen        DateTime64(3),
    metadata          string
) PRIMARY KEY (host_ip, poller_id, partition)
  TTL to_start_of_day(coalesce(last_sweep_time, _tp_time)) + INTERVAL 3 DAY
  SETTINGS mode='versioned_kv', version_column='_tp_time';

-- Raw device updates (firehose) – 3d TTL
CREATE STREAM IF NOT EXISTS device_updates (
    agent_id string,
    poller_id string,
    partition string,
    device_id string,
    discovery_source string,
    ip string,
    mac nullable(string),
    hostname nullable(string),
    timestamp DateTime64(3),
    available boolean,
    metadata map(string, string)
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (timestamp, device_id, poller_id)
TTL to_start_of_day(coalesce(timestamp, _tp_time)) + INTERVAL 3 DAY
SETTINGS index_granularity = 8192;

-- Current device inventory (versioned_kv) – 30d TTL
CREATE STREAM IF NOT EXISTS unified_devices (
    device_id string,
    ip string,
    poller_id string,
    agent_id string,
    hostname nullable(string),
    mac nullable(string),
    discovery_sources array(string),
    is_available boolean,
    first_seen DateTime64(3),
    last_seen DateTime64(3),
    metadata map(string, string),
    device_type string DEFAULT 'network_device',
    service_type nullable(string),
    service_status nullable(string),
    last_heartbeat nullable(DateTime64(3)),
    os_info nullable(string),
    version_info nullable(string)
) PRIMARY KEY (device_id)
  TTL to_start_of_day(coalesce(last_seen, _tp_time)) + INTERVAL 3 DAY
  SETTINGS mode='versioned_kv', version_column='_tp_time';

-- Registry expected by device-mgr (versioned_kv) – 30d TTL
CREATE STREAM IF NOT EXISTS unified_devices_registry (
    device_id string,
    ip string,
    poller_id string,
    agent_id string,
    hostname nullable(string),
    mac nullable(string),
    discovery_sources array(string),
    is_available boolean,
    first_seen DateTime64(3),
    last_seen DateTime64(3),
    metadata map(string, string),
    device_type string DEFAULT 'network_device',
    service_type nullable(string),
    service_status nullable(string),
    last_heartbeat nullable(DateTime64(3)),
    os_info nullable(string),
    version_info nullable(string)
) PRIMARY KEY (device_id)
  TTL to_start_of_day(coalesce(last_seen, _tp_time)) + INTERVAL 3 DAY
  SETTINGS mode='versioned_kv', version_column='_tp_time';

-- Aggregation pipeline MV
CREATE MATERIALIZED VIEW IF NOT EXISTS unified_device_pipeline_mv
INTO unified_devices
AS
SELECT
    device_id,
    arg_max(ip, timestamp) AS ip,
    arg_max(poller_id, timestamp) AS poller_id,
    arg_max(agent_id, timestamp) AS agent_id,
    arg_max(hostname, timestamp) AS hostname,
    arg_max(mac, timestamp) AS mac,
    group_uniq_array(discovery_source) AS discovery_sources,
    arg_max(available, timestamp) AS is_available,
    min(timestamp) AS first_seen,
    max(timestamp) AS last_seen,
    arg_max(metadata, timestamp) AS metadata,
    'network_device' AS device_type,
    CAST(NULL AS nullable(string)) AS service_type,
    CAST(NULL AS nullable(string)) AS service_status,
    CAST(NULL AS nullable(DateTime64(3))) AS last_heartbeat,
    CAST(NULL AS nullable(string)) AS os_info,
    CAST(NULL AS nullable(string)) AS version_info
FROM device_updates
GROUP BY device_id;

-- =================================================================
-- == Network Discovery Streams
-- =================================================================

-- Discovered interfaces (versioned_kv) – 3d TTL
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
  TTL to_start_of_day(coalesce(timestamp, _tp_time)) + INTERVAL 3 DAY
  SETTINGS mode='versioned_kv', version_column='_tp_time';

-- Topology discovery (LLDP/CDP/BGP/etc.) – 3d TTL
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
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (timestamp, local_device_id, local_if_index)
TTL to_start_of_day(coalesce(timestamp, _tp_time)) + INTERVAL 3 DAY
SETTINGS index_granularity = 8192;

-- =================================================================
-- == Metrics and Monitoring Streams (3d TTL)
-- =================================================================

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
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (timestamp, device_id, metric_name)
TTL to_start_of_day(coalesce(timestamp, _tp_time)) + INTERVAL 3 DAY
SETTINGS index_granularity = 8192;

CREATE STREAM IF NOT EXISTS cpu_metrics (
    timestamp         DateTime64(3),
    poller_id         string,
    agent_id          string,
    host_id           string,
    core_id           int32,
    usage_percent     float64,
    frequency_hz      float64,
    device_id         string,
    partition         string
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (timestamp, device_id, host_id, core_id)
TTL to_start_of_day(coalesce(timestamp, _tp_time)) + INTERVAL 3 DAY
SETTINGS index_granularity = 8192;

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
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (timestamp, device_id, host_id, mount_point)
TTL to_start_of_day(coalesce(timestamp, _tp_time)) + INTERVAL 3 DAY
SETTINGS index_granularity = 8192;

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
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (timestamp, device_id, host_id)
TTL to_start_of_day(coalesce(timestamp, _tp_time)) + INTERVAL 3 DAY
SETTINGS index_granularity = 8192;

CREATE STREAM IF NOT EXISTS process_metrics (
    timestamp         DateTime64(3),
    poller_id         string,
    agent_id          string,
    host_id           string,
    pid               uint32,
    name              string,
    cpu_usage         float32,
    memory_usage      uint64,
    status            string,
    start_time        string,
    device_id         string,
    partition         string
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (timestamp, device_id, host_id, pid)
TTL to_start_of_day(coalesce(timestamp, _tp_time)) + INTERVAL 3 DAY
SETTINGS index_granularity = 8192;

-- =================================================================
-- == Service Management Streams
-- =================================================================

-- 3d TTL on status events
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
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (timestamp, service_name, poller_id)
TTL to_start_of_day(coalesce(timestamp, _tp_time)) + INTERVAL 3 DAY
SETTINGS index_granularity = 8192;

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
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (timestamp, service_name, poller_id)
TTL to_start_of_day(coalesce(timestamp, _tp_time)) + INTERVAL 3 DAY
SETTINGS index_granularity = 8192;

-- Service definitions (configuration) – 3d TTL
CREATE STREAM IF NOT EXISTS services (
    timestamp         DateTime64(3),
    poller_id         string,
    agent_id          string,
    service_name      string,
    service_type      string,
    config            string,          -- Store JSON as text; still queryable via json_extract_*
    partition         string
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (timestamp, service_name, poller_id)
TTL to_start_of_day(coalesce(timestamp, _tp_time)) + INTERVAL 3 DAY
SETTINGS index_granularity = 8192;

-- Poller registry (versioned_kv) – 30d TTL
CREATE STREAM IF NOT EXISTS pollers (
    poller_id         string,
    first_seen        DateTime64(3),
    last_seen         DateTime64(3),
    is_healthy        bool
) PRIMARY KEY (poller_id)
  TTL to_start_of_day(coalesce(last_seen, _tp_time)) + INTERVAL 3 DAY
  SETTINGS mode='versioned_kv', version_column='_tp_time';

-- Poller history – 7d TTL
CREATE STREAM IF NOT EXISTS poller_history (
    timestamp         DateTime64(3),
    poller_id         string,
    is_healthy        bool
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (timestamp, poller_id)
TTL to_start_of_day(coalesce(timestamp, _tp_time)) + INTERVAL 7 DAY
SETTINGS index_granularity = 8192;

-- Poller status events – 7d TTL
CREATE STREAM IF NOT EXISTS poller_statuses (
    timestamp         DateTime64(3),
    poller_id         string,
    agent_id          string,
    is_healthy        bool,
    first_seen        DateTime64(3),
    last_seen         DateTime64(3),
    uptime_seconds    uint64,
    partition         string
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (timestamp, poller_id)
TTL to_start_of_day(coalesce(timestamp, _tp_time)) + INTERVAL 7 DAY
SETTINGS index_granularity = 8192;

-- =================================================================
-- == Events and Alerting Streams
-- =================================================================

-- CloudEvents – 3d TTL (short)
CREATE STREAM IF NOT EXISTS events (
    specversion       string,
    id                string,
    source            string,
    type              string,
    datacontenttype   string,
    subject           string,
    remote_addr       string,
    host              string,
    level             int32,
    severity          string,
    short_message     string,
    event_timestamp   DateTime64(3),
    version           string,
    raw_data          string
) PRIMARY KEY (id)
  TTL to_start_of_day(coalesce(event_timestamp, _tp_time)) + INTERVAL 3 DAY
  SETTINGS mode='versioned_kv', version_column='_tp_time';

-- =================================================================
-- == Network Flow and Security Streams (3d TTL)
-- =================================================================

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
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (timestamp, src_ip, dst_ip, src_port, dst_port)
TTL to_start_of_day(coalesce(timestamp, _tp_time)) + INTERVAL 3 DAY
SETTINGS index_granularity = 8192;

CREATE STREAM IF NOT EXISTS rperf_metrics (
    timestamp         DateTime64(3),
    poller_id         string,
    service_name      string,
    message           string
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (timestamp, poller_id, service_name)
TTL to_start_of_day(coalesce(timestamp, _tp_time)) + INTERVAL 3 DAY
SETTINGS index_granularity = 8192;

-- =================================================================
-- == User Management
-- =================================================================

-- Users (versioned_kv) – NO TTL per request
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
-- == Performance Optimization Streams / MVs
-- =================================================================

-- Aggregated device metrics – 3d TTL (derived)
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
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(window_time), 3600)
ORDER BY (window_time, device_id, poller_id)
TTL to_start_of_day(coalesce(window_time, _tp_time)) + INTERVAL 3 DAY
SETTINGS index_granularity = 8192;

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

-- =================================================================
-- == Observability (Logs, Metrics, Traces) – all 3d TTL
-- =================================================================

CREATE STREAM IF NOT EXISTS logs (
    timestamp          DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    trace_id           string CODEC(ZSTD(1)),
    span_id            string CODEC(ZSTD(1)),
    severity_text      string CODEC(ZSTD(1)),
    severity_number    int32 CODEC(ZSTD(1)),
    body               string CODEC(ZSTD(1)),
    service_name       string CODEC(ZSTD(1)),
    service_version    string CODEC(ZSTD(1)),
    service_instance   string CODEC(ZSTD(1)),
    scope_name         string CODEC(ZSTD(1)),
    scope_version      string CODEC(ZSTD(1)),
    attributes         string CODEC(ZSTD(1)),
    resource_attributes string CODEC(ZSTD(1))
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (timestamp, service_name, trace_id)
TTL to_start_of_day(_tp_time) + INTERVAL 3 DAY
SETTINGS index_granularity = 8192;

CREATE STREAM IF NOT EXISTS otel_metrics (
    timestamp       DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    trace_id        string CODEC(ZSTD(1)),
    span_id         string CODEC(ZSTD(1)),
    service_name    string CODEC(ZSTD(1)),
    span_name       string CODEC(ZSTD(1)),
    span_kind       string CODEC(ZSTD(1)),
    duration_ms     float64 CODEC(ZSTD(1)),
    duration_seconds float64 CODEC(ZSTD(1)),
    metric_type     string CODEC(ZSTD(1)),
    http_method     string CODEC(ZSTD(1)),
    http_route      string CODEC(ZSTD(1)),
    http_status_code string CODEC(ZSTD(1)),
    grpc_service    string CODEC(ZSTD(1)),
    grpc_method     string CODEC(ZSTD(1)),
    grpc_status_code string CODEC(ZSTD(1)),
    is_slow         bool CODEC(ZSTD(1)),
    component       string CODEC(ZSTD(1)),
    level           string CODEC(ZSTD(1))
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (timestamp, service_name, span_id)
TTL to_start_of_day(_tp_time) + INTERVAL 3 DAY
SETTINGS index_granularity = 8192;

CREATE STREAM IF NOT EXISTS otel_traces (
    timestamp         DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    trace_id          string CODEC(ZSTD(1)),
    span_id           string CODEC(ZSTD(1)),
    parent_span_id    string CODEC(ZSTD(1)),
    name              string CODEC(ZSTD(1)),
    kind              int32 CODEC(ZSTD(1)),
    start_time_unix_nano uint64 CODEC(Delta(8), ZSTD(1)),
    end_time_unix_nano   uint64 CODEC(Delta(8), ZSTD(1)),
    service_name      string CODEC(ZSTD(1)),
    service_version   string CODEC(ZSTD(1)),
    service_instance  string CODEC(ZSTD(1)),
    scope_name        string CODEC(ZSTD(1)),
    scope_version     string CODEC(ZSTD(1)),
    status_code       int32 CODEC(ZSTD(1)),
    status_message    string CODEC(ZSTD(1)),
    attributes        string CODEC(ZSTD(1)),
    resource_attributes string CODEC(ZSTD(1)),
    events            string CODEC(ZSTD(1)),
    links             string CODEC(ZSTD(1))
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (service_name, timestamp, trace_id, span_id)
TTL to_start_of_day(_tp_time) + INTERVAL 3 DAY
SETTINGS index_granularity = 8192;

-- Trace summaries + helper (3d TTL)
CREATE STREAM IF NOT EXISTS otel_trace_summaries (
    timestamp         DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    trace_id          string CODEC(ZSTD(1)),
    root_span_id      string CODEC(ZSTD(1)),
    root_span_name    string CODEC(ZSTD(1)),
    root_service_name string CODEC(ZSTD(1)),
    root_span_kind    int32 CODEC(ZSTD(1)),
    start_time_unix_nano uint64 CODEC(Delta(8), ZSTD(1)),
    end_time_unix_nano   uint64 CODEC(Delta(8), ZSTD(1)),
    duration_ms          float64 CODEC(ZSTD(1)),
    status_code       int32 CODEC(ZSTD(1)),
    service_set       array(string) CODEC(ZSTD(1)),
    span_count        uint32 CODEC(ZSTD(1)),
    error_count       uint32 CODEC(ZSTD(1))
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (timestamp, trace_id)
TTL to_start_of_day(_tp_time) + INTERVAL 3 DAY
SETTINGS index_granularity = 8192;

CREATE STREAM IF NOT EXISTS otel_spans_enriched (
  timestamp             DateTime64(9),
  trace_id              string,
  span_id               string,
  parent_span_id        string,
  name                  string,
  kind                  int32,
  start_time_unix_nano  uint64,
  end_time_unix_nano    uint64,
  service_name          string,
  status_code           int32,
  duration_ms           float64,
  is_root               bool
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (trace_id, span_id)
TTL to_start_of_day(_tp_time) + INTERVAL 3 DAY
SETTINGS index_granularity = 8192;

CREATE MATERIALIZED VIEW IF NOT EXISTS otel_spans_enriched_mv
INTO otel_spans_enriched AS
SELECT
    timestamp,
    trace_id,
    span_id,
    parent_span_id,
    name,
    kind,
    start_time_unix_nano,
    end_time_unix_nano,
    service_name,
    status_code,
    (end_time_unix_nano - start_time_unix_nano) / 1e6 AS duration_ms,
    (parent_span_id = '' OR parent_span_id = '0000000000000000' OR length(parent_span_id) = 0) AS is_root
FROM otel_traces;

CREATE MATERIALIZED VIEW IF NOT EXISTS otel_trace_summaries_mv
INTO otel_trace_summaries AS
SELECT
    min(timestamp) AS timestamp,
    trace_id,
    any_if(span_id, is_root) AS root_span_id,
    any_if(name, is_root) AS root_span_name,
    any_if(service_name, is_root) AS root_service_name,
    any_if(kind, is_root) AS root_span_kind,
    min(start_time_unix_nano) AS start_time_unix_nano,
    max(end_time_unix_nano) AS end_time_unix_nano,
    any_if(duration_ms, is_root) AS duration_ms,
    max(status_code) AS status_code,
    group_uniq_array(service_name) AS service_set,
    count() AS span_count,
    0 AS error_count
FROM otel_spans_enriched
GROUP BY trace_id;

-- =================================================================
-- == UI Compatibility Views
-- =================================================================

CREATE VIEW IF NOT EXISTS otel_trace_summaries_dedup AS
SELECT
    trace_id,
    timestamp,
    timestamp as _tp_time,
    root_span_id,
    root_span_name,
    root_service_name,
    root_span_kind,
    start_time_unix_nano,
    end_time_unix_nano,
    duration_ms,
    span_count,
    error_count,
    status_code,
    service_set
FROM otel_trace_summaries;

CREATE VIEW otel_trace_summaries_final       AS SELECT * FROM otel_trace_summaries_dedup;
CREATE VIEW otel_trace_summaries_final_v2    AS SELECT * FROM otel_trace_summaries_dedup;
CREATE VIEW otel_trace_summaries_deduplicated AS SELECT * FROM otel_trace_summaries_dedup;

-- =================================================================
-- == PERFORMANCE INDEXES
-- =================================================================

-- Trace indexes
ALTER STREAM otel_traces ADD INDEX IF NOT EXISTS idx_timestamp timestamp TYPE minmax GRANULARITY 1;
ALTER STREAM otel_traces ADD INDEX IF NOT EXISTS idx_trace_id trace_id TYPE bloom_filter GRANULARITY 1;
ALTER STREAM otel_traces ADD INDEX IF NOT EXISTS idx_service service_name TYPE bloom_filter GRANULARITY 1;
ALTER STREAM otel_traces ADD INDEX IF NOT EXISTS idx_span_id span_id TYPE bloom_filter GRANULARITY 1;

-- Trace summary indexes
ALTER STREAM otel_trace_summaries ADD INDEX IF NOT EXISTS idx_timestamp timestamp TYPE minmax GRANULARITY 1;
ALTER STREAM otel_trace_summaries ADD INDEX IF NOT EXISTS idx_trace_id trace_id TYPE bloom_filter GRANULARITY 1;
ALTER STREAM otel_trace_summaries ADD INDEX IF NOT EXISTS idx_service root_service_name TYPE bloom_filter GRANULARITY 1;
ALTER STREAM otel_trace_summaries ADD INDEX IF NOT EXISTS idx_duration duration_ms TYPE minmax GRANULARITY 1;

-- Log indexes
ALTER STREAM logs ADD INDEX IF NOT EXISTS idx_timestamp timestamp TYPE minmax GRANULARITY 1;
ALTER STREAM logs ADD INDEX IF NOT EXISTS idx_service service_name TYPE bloom_filter GRANULARITY 1;
ALTER STREAM logs ADD INDEX IF NOT EXISTS idx_trace_id trace_id TYPE bloom_filter GRANULARITY 1;
ALTER STREAM logs ADD INDEX IF NOT EXISTS idx_severity severity_text TYPE bloom_filter GRANULARITY 1;

-- Metrics indexes
ALTER STREAM process_metrics ADD INDEX IF NOT EXISTS idx_timestamp timestamp TYPE minmax GRANULARITY 1;
ALTER STREAM process_metrics ADD INDEX IF NOT EXISTS idx_device device_id TYPE bloom_filter GRANULARITY 1;
ALTER STREAM process_metrics ADD INDEX IF NOT EXISTS idx_poller poller_id TYPE bloom_filter GRANULARITY 1;
ALTER STREAM process_metrics ADD INDEX IF NOT EXISTS idx_host host_id TYPE bloom_filter GRANULARITY 1;

ALTER STREAM otel_metrics ADD INDEX IF NOT EXISTS idx_timestamp timestamp TYPE minmax GRANULARITY 1;
ALTER STREAM otel_metrics ADD INDEX IF NOT EXISTS idx_service service_name TYPE bloom_filter GRANULARITY 1;
ALTER STREAM otel_metrics ADD INDEX IF NOT EXISTS idx_trace_id trace_id TYPE bloom_filter GRANULARITY 1;

-- Services indexes
ALTER STREAM services ADD INDEX IF NOT EXISTS idx_timestamp timestamp TYPE minmax GRANULARITY 1;
ALTER STREAM services ADD INDEX IF NOT EXISTS idx_poller poller_id TYPE bloom_filter GRANULARITY 1;
ALTER STREAM services ADD INDEX IF NOT EXISTS idx_service_name service_name TYPE bloom_filter GRANULARITY 1;
-- OCSF Core Event Streams Migration
-- This migration creates the foundational OCSF-aligned streams for ServiceRadar
-- Based on OCSF schema with Timeplus Proton streaming constraints

-- Device Inventory Events (discovery.device_inventory_info)
-- OCSF Class: 5001 (Device Inventory Info)
DROP STREAM IF EXISTS ocsf_device_inventory;
CREATE STREAM ocsf_device_inventory (
    -- OCSF Core Fields
    time DateTime64(3) DEFAULT now64(),
    activity_id int32 DEFAULT 1,           -- OCSF: activity (Create = 1, Update = 2, Delete = 3)
    category_uid int32 DEFAULT 5,          -- OCSF: Discovery = 5
    class_uid int32 DEFAULT 5001,          -- OCSF: Device Inventory Info = 5001
    severity_id int32 DEFAULT 1,           -- OCSF: Informational = 1

    -- Device Object (OCSF device)
    device_uid string,                     -- OCSF: device.uid (primary identifier)
    device_name string DEFAULT '',         -- OCSF: device.name (hostname)
    device_ip array(string) DEFAULT [],    -- OCSF: device.ip (all discovered IPs)
    device_mac array(string) DEFAULT [],   -- OCSF: device.mac (all discovered MACs)
    device_type_id int32 DEFAULT 0,        -- OCSF: device.type_id (Unknown=0, Computer=1, Mobile=7, etc)
    device_os_name string DEFAULT '',      -- OCSF: device.os.name
    device_os_version string DEFAULT '',   -- OCSF: device.os.version
    device_location string DEFAULT '',     -- OCSF: device.location (site/geo info)
    device_domain string DEFAULT '',       -- OCSF: device.domain

    -- Discovery Context
    agent_id string DEFAULT '',
    poller_id string DEFAULT '',
    discovery_source string DEFAULT '',    -- 'sweep', 'netbox', 'armis', 'dhcp', etc.
    confidence_level int32 DEFAULT 3,     -- High=1, Medium=2, Low=3, Unknown=4

    -- Enrichment Data
    raw_data string DEFAULT '',           -- Original JSON from data source
    enrichments map(string, string),
    metadata map(string, string),

    -- Observable Flattening (for fast cross-entity searches)
    observables_ip array(string) DEFAULT [],
    observables_mac array(string) DEFAULT [],
    observables_hostname array(string) DEFAULT [],
    observables_domain array(string) DEFAULT [],
    observables_resource_uid array(string)) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(time), 3600)  -- Hourly partitions
ORDER BY (time, device_uid)
TTL to_start_of_day(time) + INTERVAL 30 DAY
SETTINGS index_granularity = 8192;

-- Network Activity Events (network.network_activity)
-- OCSF Class: 4001 (Network Activity)
DROP STREAM IF EXISTS ocsf_network_activity;
CREATE STREAM ocsf_network_activity (
    -- OCSF Core Fields
    time DateTime64(3) DEFAULT now64(),
    start_time DateTime64(3) DEFAULT now64(),
    end_time DateTime64(3) DEFAULT now64(),
    activity_id int32 DEFAULT 1,           -- Traffic = 1, Flow = 5, Connection = 6
    category_uid int32 DEFAULT 4,          -- Network Activity = 4
    class_uid int32 DEFAULT 4001,          -- Network Activity = 4001
    severity_id int32 DEFAULT 1,           -- Informational = 1

    -- Connection Object (OCSF connection)
    connection_uid string DEFAULT '',      -- Unique flow identifier
    protocol_num int32 DEFAULT 0,          -- IP protocol number (6=TCP, 17=UDP, 1=ICMP)
    protocol_ver int32 DEFAULT 4,          -- IP version (4 or 6)

    -- Source Endpoint (OCSF src_endpoint)
    src_endpoint_ip string DEFAULT '',
    src_endpoint_port int32 DEFAULT 0,
    src_endpoint_mac string DEFAULT '',
    src_endpoint_hostname string DEFAULT '',
    src_endpoint_domain string DEFAULT '',

    -- Destination Endpoint (OCSF dst_endpoint)
    dst_endpoint_ip string DEFAULT '',
    dst_endpoint_port int32 DEFAULT 0,
    dst_endpoint_mac string DEFAULT '',
    dst_endpoint_hostname string DEFAULT '',
    dst_endpoint_domain string DEFAULT '',

    -- Traffic Object (OCSF traffic)
    traffic_bytes_in int64 DEFAULT 0,
    traffic_bytes_out int64 DEFAULT 0,
    traffic_packets_in int64 DEFAULT 0,
    traffic_packets_out int64 DEFAULT 0,

    -- ServiceRadar Specific Fields
    agent_id string DEFAULT '',
    poller_id string DEFAULT '',
    sampler_address string DEFAULT '',     -- NetFlow exporter IP
    input_snmp int32 DEFAULT 0,            -- Input interface index
    output_snmp int32 DEFAULT 0,           -- Output interface index
    flow_direction_id int32 DEFAULT 0,     -- Inbound=1, Outbound=2, Unknown=0

    -- Enrichment Data
    raw_data string DEFAULT '',
    metadata map(string, string),

    -- Observable Flattening
    observables_ip array(string) DEFAULT [],
    observables_port array(string) DEFAULT [],      -- Format: "ip:port"
    observables_hostname array(string) DEFAULT [],
    observables_mac array(string)) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(time), 3600)
ORDER BY (time, src_endpoint_ip, dst_endpoint_ip)
TTL to_start_of_day(time) + INTERVAL 3 DAY        -- Shorter retention for high-volume data
SETTINGS index_granularity = 8192;

-- User Inventory Events (discovery.user_inventory_info)
-- OCSF Class: 5002 (User Inventory Info)
DROP STREAM IF EXISTS ocsf_user_inventory;
CREATE STREAM ocsf_user_inventory (
    -- OCSF Core Fields
    time DateTime64(3) DEFAULT now64(),
    activity_id int32 DEFAULT 1,
    category_uid int32 DEFAULT 5,          -- Discovery = 5
    class_uid int32 DEFAULT 5002,          -- User Inventory Info = 5002
    severity_id int32 DEFAULT 1,

    -- User Object (OCSF user)
    user_uid string,                       -- Primary identifier
    user_name string DEFAULT '',           -- Username/login
    user_email string DEFAULT '',
    user_full_name string DEFAULT '',
    user_domain string DEFAULT '',         -- Domain/realm
    user_type_id int32 DEFAULT 0,          -- Unknown=0, User=1, Admin=2, System=3
    user_credential_uid string DEFAULT '', -- Associated credential ID

    -- Account Object (OCSF account)
    account_name string DEFAULT '',        -- Account name if different from username
    account_type_id int32 DEFAULT 0,       -- Unknown=0, LDAP=1, Windows=2, etc
    account_uid string DEFAULT '',

    -- Discovery Context
    agent_id string DEFAULT '',
    poller_id string DEFAULT '',
    discovery_source string DEFAULT '',    -- 'ad', 'ldap', 'local', etc.
    confidence_level int32 DEFAULT 3,

    -- Enrichment Data
    raw_data string DEFAULT '',
    metadata map(string, string),

    -- Observable Flattening
    observables_username array(string) DEFAULT [],
    observables_email array(string) DEFAULT [],
    observables_hostname array(string) DEFAULT [],
    observables_domain array(string) DEFAULT [],
    observables_resource_uid array(string)) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(time), 3600)
ORDER BY (time, user_uid)
TTL to_start_of_day(time) + INTERVAL 90 DAY        -- Longer retention for compliance
SETTINGS index_granularity = 8192;

-- System Activity Events (system.system_activity)
-- OCSF Class: 1001 (System Activity)
DROP STREAM IF EXISTS ocsf_system_activity;
CREATE STREAM ocsf_system_activity (
    -- OCSF Core Fields
    time DateTime64(3) DEFAULT now64(),
    activity_id int32 DEFAULT 0,           -- Varies by activity type
    activity_name string DEFAULT '',       -- Human-readable activity name
    category_uid int32 DEFAULT 1,          -- System Activity = 1
    class_uid int32 DEFAULT 1001,          -- System Activity = 1001
    severity_id int32 DEFAULT 1,

    -- Activity Details
    message string DEFAULT '',             -- Log message/description
    status string DEFAULT '',              -- Success, Failure, etc.
    status_code string DEFAULT '',         -- Numeric/string status code

    -- Actor Object (OCSF actor)
    actor_process_name string DEFAULT '',
    actor_process_pid int32 DEFAULT 0,
    actor_user_name string DEFAULT '',
    actor_user_uid string DEFAULT '',

    -- Endpoint Object (OCSF endpoint - where activity occurred)
    endpoint_hostname string DEFAULT '',
    endpoint_ip string DEFAULT '',
    endpoint_mac string DEFAULT '',
    endpoint_domain string DEFAULT '',
    endpoint_os_name string DEFAULT '',

    -- ServiceRadar Specific
    agent_id string DEFAULT '',
    poller_id string DEFAULT '',
    log_level string DEFAULT '',           -- DEBUG, INFO, WARN, ERROR
    service_name string DEFAULT '',        -- Service that generated the event
    component string DEFAULT '',           -- Software component

    -- Enrichment Data
    raw_data string DEFAULT '',
    metadata map(string, string),

    -- Observable Flattening
    observables_ip array(string) DEFAULT [],
    observables_hostname array(string) DEFAULT [],
    observables_username array(string) DEFAULT [],
    observables_process array(string)) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(time), 3600)
ORDER BY (time, endpoint_hostname, service_name)
TTL to_start_of_day(time) + INTERVAL 7 DAY
SETTINGS index_granularity = 8192;
-- OCSF Entity State Streams Migration
-- These versioned_kv streams maintain current entity state for fast lookups
-- Compatible with Timeplus Proton's versioned key-value stream mode

-- Current Device State (versioned_kv)
-- Maintains the latest known state for each device across all discovery sources
DROP STREAM IF EXISTS ocsf_devices_current;
CREATE STREAM ocsf_devices_current (
    -- Primary Key and Timestamps
    device_uid string,                     -- Primary key - unique device identifier
    last_seen DateTime64(3) DEFAULT now64(),
    first_seen DateTime64(3) DEFAULT now64(),

    -- OCSF Device Object Fields
    device_name string DEFAULT '',         -- Current hostname
    device_ip array(string),    -- All known IP addresses
    device_mac array(string),   -- All known MAC addresses
    device_type_id int32 DEFAULT 0,        -- OCSF device type
    device_os_name string DEFAULT '',
    device_os_version string DEFAULT '',
    device_location string DEFAULT '',
    device_domain string DEFAULT '',

    -- Aggregated Discovery Data
    discovery_sources array(string),  -- All sources that found this device
    confidence_score float32 DEFAULT 0.0,        -- Confidence in data accuracy (0.0-1.0)
    discovery_count int32 DEFAULT 0,             -- Number of times discovered

    -- ServiceRadar Operational Fields
    agent_id string DEFAULT '',            -- Last reporting agent
    poller_id string DEFAULT '',           -- Last reporting poller
    is_available bool DEFAULT true,        -- Device availability status
    last_response_time DateTime64(3) DEFAULT now64(),

    -- State Management
    status string DEFAULT 'active',        -- active, inactive, deleted
    tags array(string),         -- User-defined tags
    categories array(string),   -- Device categories

    -- Raw Data and Enrichments
    raw_data string DEFAULT '',           -- Latest raw discovery data
    enrichments map(string, string),
    metadata map(string, string),

-- Pre-computed Observable Arrays (for fast observable-based searches)
    observables_ip array(string),
    observables_mac array(string),
    observables_hostname array(string),
    observables_domain array(string),
    observables_resource_uid array(string)
) PRIMARY KEY (device_uid)
TTL to_start_of_day(last_seen) + INTERVAL 90 DAY
SETTINGS mode='versioned_kv';

-- Current User State (versioned_kv)
-- Maintains the latest known state for each user account
DROP STREAM IF EXISTS ocsf_users_current;
CREATE STREAM ocsf_users_current (
    -- Primary Key and Timestamps
    user_uid string,                       -- Primary key - unique user identifier
    last_seen DateTime64(3) DEFAULT now64(),
    first_seen DateTime64(3) DEFAULT now64(),

    -- OCSF User Object Fields
    user_name string DEFAULT '',           -- Username/login
    user_email string DEFAULT '',
    user_full_name string DEFAULT '',
    user_domain string DEFAULT '',
    user_type_id int32 DEFAULT 0,
    user_credential_uid string DEFAULT '',

    -- Account Information
    account_name string DEFAULT '',
    account_type_id int32 DEFAULT 0,
    account_uid string DEFAULT '',

    -- Aggregated Discovery Data
    discovery_sources array(string),
    confidence_score float32 DEFAULT 0.0,
    discovery_count int32 DEFAULT 0,

    -- ServiceRadar Operational Fields
    agent_id string DEFAULT '',
    poller_id string DEFAULT '',
    is_active bool DEFAULT true,           -- Account active status
    last_login DateTime64(3) DEFAULT now64(),

    -- State Management
    status string DEFAULT 'active',
    groups array(string),       -- User groups/roles
    permissions array(string),  -- Assigned permissions

    -- Raw Data and Enrichments
    raw_data string DEFAULT '',
    metadata map(string, string),

    -- Pre-computed Observable Arrays
    observables_username array(string),
    observables_email array(string),
    observables_hostname array(string),
    observables_domain array(string),
    observables_resource_uid array(string)
) PRIMARY KEY (user_uid)
TTL to_start_of_day(last_seen) + INTERVAL 90 DAY
SETTINGS mode='versioned_kv';

-- Current Vulnerability State (versioned_kv)
-- Tracks current vulnerability findings across all affected resources
DROP STREAM IF EXISTS ocsf_vulnerabilities_current;
CREATE STREAM ocsf_vulnerabilities_current (
    -- Primary Key and Timestamps
    vulnerability_cve_uid string,          -- Primary key - CVE ID or internal vuln ID
    last_seen DateTime64(3) DEFAULT now64(),
    first_seen DateTime64(3) DEFAULT now64(),

    -- OCSF Vulnerability Object Fields
    title string DEFAULT '',
    desc string DEFAULT '',               -- Vulnerability description
    severity_id int32 DEFAULT 0,         -- Critical=1, High=2, Medium=3, Low=4
    score float32 DEFAULT 0.0,           -- CVSS score

    -- Affected Resources
    affected_devices array(string),     -- Device UIDs affected
    affected_users array(string),       -- User UIDs affected
    affected_services array(string),    -- Service names affected

    -- Vulnerability Details
    cwe_uid string DEFAULT '',            -- Common Weakness Enumeration
    references array(string), -- URLs to vulnerability details
    remediation string DEFAULT '',        -- Fix/mitigation steps

    -- Discovery Context
    discovery_sources array(string),
    confidence_score float32 DEFAULT 0.0,
    scanner_names array(string),

    -- ServiceRadar Operational Fields
    agent_id string DEFAULT '',
    poller_id string DEFAULT '',

    -- State Management
    status string DEFAULT 'open',         -- open, fixed, mitigated, false_positive
    priority string DEFAULT 'medium',     -- critical, high, medium, low
    assigned_to string DEFAULT '',        -- User responsible for remediation

    -- Raw Data and Enrichments
    raw_data string DEFAULT '',
    metadata map(string, string),

    -- Pre-computed Observable Arrays
    observables_cve array(string),
    observables_cwe array(string),
    observables_resource_uid array(string)
) PRIMARY KEY (vulnerability_cve_uid)
TTL to_start_of_day(last_seen) + INTERVAL 365 DAY  -- Keep vulnerabilities for 1 year
SETTINGS mode='versioned_kv';

-- Current Service State (versioned_kv)
-- Tracks discovered services and applications
DROP STREAM IF EXISTS ocsf_services_current;
CREATE STREAM ocsf_services_current (
    -- Primary Key and Timestamps
    service_uid string,                    -- Primary key - service identifier
    last_seen DateTime64(3) DEFAULT now64(),
    first_seen DateTime64(3) DEFAULT now64(),

    -- Service Information
    service_name string DEFAULT '',        -- Service/application name
    service_version string DEFAULT '',     -- Version information
    service_port int32 DEFAULT 0,         -- Primary port
    service_protocol string DEFAULT '',   -- tcp, udp, etc.
    service_description string DEFAULT '',

    -- Location Information
    device_uid string DEFAULT '',         -- Device hosting the service
    device_hostname string DEFAULT '',
    device_ip string DEFAULT '',

    -- Service State
    is_running bool DEFAULT true,         -- Service status
    response_time_ms float32 DEFAULT 0.0, -- Average response time

    -- Discovery Context
    discovery_sources array(string),
    confidence_score float32 DEFAULT 0.0,

    -- ServiceRadar Operational Fields
    agent_id string DEFAULT '',
    poller_id string DEFAULT '',

    -- State Management
    status string DEFAULT 'active',
    tags array(string),
    categories array(string),

    -- Raw Data and Enrichments
    raw_data string DEFAULT '',
    metadata map(string, string),

    -- Pre-computed Observable Arrays
    observables_service array(string),    -- service:port combinations
    observables_ip array(string),
    observables_hostname array(string),
    observables_resource_uid array(string)
) PRIMARY KEY (service_uid)
TTL to_start_of_day(last_seen) + INTERVAL 90 DAY
SETTINGS mode='versioned_kv';

-- OCSF Observable Index Stream Migration
-- Fast lookup table for cross-entity searches using observable values
-- Enables OCSF-aligned queries: observable:ip_address value:192.168.1.1

-- Observable Index Stream
-- Maps observable values (IPs, MACs, CVEs, etc.) to entities that contain them
DROP STREAM IF EXISTS ocsf_observable_index;
CREATE STREAM ocsf_observable_index (
    -- Observable Identification
    observable_type string,               -- 'ip_address', 'mac_address', 'hostname', 'cve', etc.
    observable_value string,              -- The actual observable value
    observable_value_normalized string,   -- Normalized form (lowercase, no special chars)

    -- Entity Reference
    entity_class string,                  -- 'device', 'user', 'vulnerability', 'service', 'network_activity'
    entity_uid string,                    -- Reference to the entity containing this observable
    entity_last_seen DateTime64(3) DEFAULT now64(),

    -- Observable Context
    entity_path string DEFAULT '',        -- Path within entity (e.g., 'device.ip[0]', 'src_endpoint.ip')
    confidence_score float32 DEFAULT 1.0, -- How confident we are in this mapping (0.0-1.0)
    discovery_source string DEFAULT '',   -- Where this observable mapping came from

    -- Metadata
    time DateTime64(3) DEFAULT now64(),   -- When this mapping was created/updated
    agent_id string DEFAULT '',
    poller_id string DEFAULT '',

    -- Observable Enrichments
    geo_country string DEFAULT '',        -- For IP addresses
    geo_region string DEFAULT '',
    geo_city string DEFAULT '',
    asn_number int32 DEFAULT 0,           -- Autonomous System Number
    asn_org string DEFAULT '',            -- ASN Organization

    -- Threat Intelligence
    threat_score float32 DEFAULT 0.0,     -- Threat intelligence score (0.0-1.0)
    threat_categories array(string), -- malware, phishing, botnet, etc.
    threat_sources array(string),    -- Sources that flagged this observable

    -- Categorization
    observable_category string DEFAULT '', -- internal, external, public, private, etc.
    tags array(string),        -- User-defined tags

    -- Raw Data
    metadata map(string, string)
) ENGINE = Stream(1, 1, rand())
PARTITION BY (observable_type, farm_hash64(observable_value))  -- Distribute by type and value
ORDER BY (observable_type, observable_value, entity_last_seen)
TTL to_start_of_day(entity_last_seen) + INTERVAL 30 DAY
SETTINGS index_granularity = 8192;

-- Observable Statistics Stream
-- Track frequency and relationships of observables over time
DROP STREAM IF EXISTS ocsf_observable_statistics;
CREATE STREAM ocsf_observable_statistics (
    -- Observable Identity
    observable_type string,
    observable_value string,

    -- Time Window
    time_window_start DateTime64(3),
    time_window_end DateTime64(3),

    -- Statistics
    entity_count int32 DEFAULT 0,         -- Number of entities containing this observable
    entity_classes array(string), -- Types of entities (device, user, etc.)
    discovery_sources array(string), -- Sources that reported this observable

    -- Activity Metrics
    first_seen DateTime64(3) DEFAULT now64(),
    last_seen DateTime64(3) DEFAULT now64(),
    occurrence_count int32 DEFAULT 0,      -- How many times we've seen this observable

    -- Confidence and Quality
    avg_confidence_score float32 DEFAULT 0.0,
    max_confidence_score float32 DEFAULT 0.0,
    data_quality_score float32 DEFAULT 1.0,  -- Based on consistency across sources

    -- Threat Intelligence Summary
    max_threat_score float32 DEFAULT 0.0,
    threat_categories array(string),
    is_flagged bool DEFAULT false,

    -- Geographic Summary (for IPs)
    countries array(string),
    regions array(string),
    asn_orgs array(string),

    -- Metadata
    metadata map(string, string)
) ENGINE = Stream(1, 1, rand())
PARTITION BY (observable_type, int_div(to_unix_timestamp(time_window_start), 3600))
ORDER BY (observable_type, observable_value, time_window_start)
TTL to_start_of_day(time_window_start) + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;

-- Entity Relationship Stream
-- Track relationships between entities discovered through shared observables
DROP STREAM IF EXISTS ocsf_entity_relationships;
CREATE STREAM ocsf_entity_relationships (
    -- Relationship Identity
    relationship_uid string,              -- Unique identifier for this relationship
    relationship_type string,             -- 'shares_ip', 'shares_network', 'communicates_with', etc.

    -- Source Entity
    source_entity_class string,           -- device, user, service, etc.
    source_entity_uid string,
    source_entity_name string DEFAULT '',

    -- Target Entity
    target_entity_class string,
    target_entity_uid string,
    target_entity_name string DEFAULT '',

    -- Relationship Details
    shared_observables array(string),  -- Observable values that link these entities
    observable_types array(string),    -- Types of shared observables
    confidence_score float32 DEFAULT 0.0,         -- Confidence in this relationship

    -- Temporal Information
    time DateTime64(3) DEFAULT now64(),
    first_observed DateTime64(3) DEFAULT now64(),
    last_observed DateTime64(3) DEFAULT now64(),
    observation_count int32 DEFAULT 1,

    -- Context
    discovery_source string DEFAULT '',
    agent_id string DEFAULT '',
    poller_id string DEFAULT '',

    -- Relationship Strength
    interaction_frequency string DEFAULT 'low',  -- low, medium, high
    relationship_strength float32 DEFAULT 0.0,   -- 0.0-1.0 based on frequency and confidence

    -- Metadata
    metadata map(string, string),
    tags array(string)
) ENGINE = Stream(1, 1, rand())
PARTITION BY farm_hash64(concat(source_entity_uid, target_entity_uid))
ORDER BY (relationship_type, source_entity_uid, target_entity_uid, time)
TTL to_start_of_day(time) + INTERVAL 30 DAY
SETTINGS index_granularity = 8192;

-- Search Query Performance Stream
-- Track query patterns and performance for observable-based searches
DROP STREAM IF EXISTS ocsf_search_performance;
CREATE STREAM ocsf_search_performance (
    -- Query Identity
    query_id string DEFAULT '',
    query_hash string,                    -- Hash of normalized query
    query_text string,                   -- Original query

    -- Query Classification
    query_type string DEFAULT '',        -- 'observable_search', 'entity_search', 'federated', etc.
    entity_classes array(string), -- Entities being searched
    observable_types array(string), -- Observable types in query

    -- Performance Metrics
    time DateTime64(3) DEFAULT now64(),
    execution_time_ms int32 DEFAULT 0,
    result_count int32 DEFAULT 0,
    cache_hit bool DEFAULT false,

    -- Query Optimization
    optimization_applied array(string), -- Optimizations used
    index_usage array(string),          -- Indexes utilized
    estimated_cost float32 DEFAULT 0.0,

    -- User Context
    user_id string DEFAULT '',
    session_id string DEFAULT '',
    client_ip string DEFAULT '',

    -- Metadata
    metadata map(string, string)
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(time), 3600)
ORDER BY (time, query_hash)
TTL to_start_of_day(time) + INTERVAL 7 DAY
SETTINGS index_granularity = 8192;

-- OCSF Materialized Views Migration
-- These views automatically aggregate event data into entity state and observable indexes
-- Enables real-time updates from event streams to current state streams

-- Device State Aggregation
-- Populates ocsf_devices_current from device inventory events
DROP VIEW IF EXISTS ocsf_devices_aggregator_mv;
CREATE MATERIALIZED VIEW ocsf_devices_aggregator_mv AS
SELECT
    device_uid,
    time AS last_seen,
    time AS first_seen,

    -- Device Object Fields (take latest non-empty values)
    if(device_name != '', device_name, '') AS device_name,
    device_ip,
    device_mac,
    device_type_id,
    if(device_os_name != '', device_os_name, '') AS device_os_name,
    if(device_os_version != '', device_os_version, '') AS device_os_version,
    if(device_location != '', device_location, '') AS device_location,
    if(device_domain != '', device_domain, '') AS device_domain,

    -- Aggregated Discovery Data
    [discovery_source] AS discovery_sources,
    confidence_level / 4.0 AS confidence_score,  -- Convert 1-4 scale to 0.0-1.0
    1 AS discovery_count,

    -- ServiceRadar Fields
    agent_id,
    poller_id,
    activity_id IN (1, 2) AS is_available,  -- Create=1 or Update=2 means available
    time AS last_response_time,

    -- State Management
    CASE
        WHEN activity_id = 3 THEN 'deleted'
        WHEN activity_id = 1 THEN 'active'
        ELSE 'active'
    END AS status,
    CAST([] AS array(string)) AS tags,
    CAST([] AS array(string)) AS categories,

    -- Raw Data
    raw_data,
    enrichments,
    metadata,

    -- Observable Arrays
    observables_ip,
    observables_mac,
    observables_hostname,
    observables_domain,
    observables_resource_uid

FROM ocsf_device_inventory;

-- User State Aggregation
-- Populates ocsf_users_current from user inventory events
DROP VIEW IF EXISTS ocsf_users_aggregator_mv;
CREATE MATERIALIZED VIEW ocsf_users_aggregator_mv AS
SELECT
    user_uid,
    time AS last_seen,
    time AS first_seen,

    -- User Object Fields
    if(user_name != '', user_name, '') AS user_name,
    if(user_email != '', user_email, '') AS user_email,
    if(user_full_name != '', user_full_name, '') AS user_full_name,
    if(user_domain != '', user_domain, '') AS user_domain,
    user_type_id,
    if(user_credential_uid != '', user_credential_uid, '') AS user_credential_uid,

    -- Account Information
    if(account_name != '', account_name, '') AS account_name,
    account_type_id,
    if(account_uid != '', account_uid, '') AS account_uid,

    -- Aggregated Discovery Data
    [discovery_source] AS discovery_sources,
    confidence_level / 4.0 AS confidence_score,
    1 AS discovery_count,

    -- ServiceRadar Fields
    agent_id,
    poller_id,
    activity_id IN (1, 2) AS is_active,
    time AS last_login,

    -- State Management
    CASE
        WHEN activity_id = 3 THEN 'deleted'
        WHEN activity_id = 1 THEN 'active'
        ELSE 'active'
    END AS status,
    CAST([] AS array(string)) AS groups,
    CAST([] AS array(string)) AS permissions,

    -- Raw Data
    raw_data,
    metadata,

    -- Observable Arrays
    observables_username,
    observables_email,
    observables_hostname,
    observables_domain,
    observables_resource_uid

FROM ocsf_user_inventory;

-- Observable Index Population - Device IPs
-- Index IP addresses from device inventory
DROP VIEW IF EXISTS ocsf_observable_device_ips_mv;
CREATE MATERIALIZED VIEW ocsf_observable_device_ips_mv AS
SELECT
    'ip_address' AS observable_type,
    ip AS observable_value,
    lower(ip) AS observable_value_normalized,
    'device' AS entity_class,
    device_uid AS entity_uid,
    time AS entity_last_seen,
    'device.ip' AS entity_path,
    confidence_level / 4.0 AS confidence_score,
    discovery_source,
    time,
    agent_id,
    poller_id,

    -- Enrichments (would be populated by separate threat intel process)
    '' AS geo_country,
    '' AS geo_region,
    '' AS geo_city,
    0 AS asn_number,
    '' AS asn_org,
    0.0 AS threat_score,
    CAST([] AS array(string)) AS threat_categories,
    CAST([] AS array(string)) AS threat_sources,

    -- Categorization
    CASE
        WHEN starts_with(ip, '10.') OR starts_with(ip, '192.168.') OR starts_with(ip, '172.') THEN 'private'
        WHEN starts_with(ip, '127.') THEN 'loopback'
        ELSE 'public'
    END AS observable_category,
    CAST([] AS array(string)) AS tags,

    metadata

FROM ocsf_device_inventory
ARRAY JOIN device_ip AS ip
WHERE ip != '';

-- Observable Index Population - Device MACs
-- Index MAC addresses from device inventory
DROP VIEW IF EXISTS ocsf_observable_device_macs_mv;
CREATE MATERIALIZED VIEW ocsf_observable_device_macs_mv AS
SELECT
    'mac_address' AS observable_type,
    mac AS observable_value,
    lower(replace_all(mac, ':', '')) AS observable_value_normalized,
    'device' AS entity_class,
    device_uid AS entity_uid,
    time AS entity_last_seen,
    'device.mac' AS entity_path,
    confidence_level / 4.0 AS confidence_score,
    discovery_source,
    time,
    agent_id,
    poller_id,

    -- Enrichments
    '' AS geo_country,
    '' AS geo_region,
    '' AS geo_city,
    0 AS asn_number,
    '' AS asn_org,
    0.0 AS threat_score,
    CAST([] AS array(string)) AS threat_categories,
    CAST([] AS array(string)) AS threat_sources,
    'hardware' AS observable_category,
    CAST([] AS array(string)) AS tags,
    metadata

FROM ocsf_device_inventory
ARRAY JOIN device_mac AS mac
WHERE mac != '';

-- Observable Index Population - Device Hostnames
-- Index hostnames from device inventory
DROP VIEW IF EXISTS ocsf_observable_device_hostnames_mv;
CREATE MATERIALIZED VIEW ocsf_observable_device_hostnames_mv AS
SELECT
    'hostname' AS observable_type,
    device_name AS observable_value,
    lower(device_name) AS observable_value_normalized,
    'device' AS entity_class,
    device_uid AS entity_uid,
    time AS entity_last_seen,
    'device.name' AS entity_path,
    confidence_level / 4.0 AS confidence_score,
    discovery_source,
    time,
    agent_id,
    poller_id,

    -- Enrichments
    '' AS geo_country,
    '' AS geo_region,
    '' AS geo_city,
    0 AS asn_number,
    '' AS asn_org,
    0.0 AS threat_score,
    CAST([] AS array(string)) AS threat_categories,
    CAST([] AS array(string)) AS threat_sources,
    'internal' AS observable_category,
    CAST([] AS array(string)) AS tags,
    metadata

FROM ocsf_device_inventory
WHERE device_name != '';

-- Observable Index Population - Network Activity Source IPs
-- Index source IPs from network activity events
DROP VIEW IF EXISTS ocsf_observable_netflow_src_ips_mv;
CREATE MATERIALIZED VIEW ocsf_observable_netflow_src_ips_mv AS
SELECT
    'ip_address' AS observable_type,
    src_endpoint_ip AS observable_value,
    lower(src_endpoint_ip) AS observable_value_normalized,
    'network_activity' AS entity_class,
    connection_uid AS entity_uid,
    time AS entity_last_seen,
    'src_endpoint.ip' AS entity_path,
    0.7 AS confidence_score,  -- Lower confidence for transient network data
    'netflow' AS discovery_source,
    time,
    agent_id,
    poller_id,

    -- Enrichments
    '' AS geo_country,
    '' AS geo_region,
    '' AS geo_city,
    0 AS asn_number,
    '' AS asn_org,
    0.0 AS threat_score,
    CAST([] AS array(string)) AS threat_categories,
    CAST([] AS array(string)) AS threat_sources,
    CASE
        WHEN starts_with(src_endpoint_ip, '10.') OR starts_with(src_endpoint_ip, '192.168.') OR starts_with(src_endpoint_ip, '172.') THEN 'private'
        WHEN starts_with(src_endpoint_ip, '127.') THEN 'loopback'
        ELSE 'public'
    END AS observable_category,
    CAST([] AS array(string)) AS tags,
    metadata

FROM ocsf_network_activity
WHERE src_endpoint_ip != '';

-- Observable Index Population - Network Activity Destination IPs
-- Index destination IPs from network activity events
DROP VIEW IF EXISTS ocsf_observable_netflow_dst_ips_mv;
CREATE MATERIALIZED VIEW ocsf_observable_netflow_dst_ips_mv AS
SELECT
    'ip_address' AS observable_type,
    dst_endpoint_ip AS observable_value,
    lower(dst_endpoint_ip) AS observable_value_normalized,
    'network_activity' AS entity_class,
    connection_uid AS entity_uid,
    time AS entity_last_seen,
    'dst_endpoint.ip' AS entity_path,
    0.7 AS confidence_score,
    'netflow' AS discovery_source,
    time,
    agent_id,
    poller_id,

    -- Enrichments
    '' AS geo_country,
    '' AS geo_region,
    '' AS geo_city,
    0 AS asn_number,
    '' AS asn_org,
    0.0 AS threat_score,
    CAST([] AS array(string)) AS threat_categories,
    CAST([] AS array(string)) AS threat_sources,
    CASE
        WHEN starts_with(dst_endpoint_ip, '10.') OR starts_with(dst_endpoint_ip, '192.168.') OR starts_with(dst_endpoint_ip, '172.') THEN 'private'
        WHEN starts_with(dst_endpoint_ip, '127.') THEN 'loopback'
        ELSE 'public'
    END AS observable_category,
    CAST([] AS array(string)) AS tags,
    metadata

FROM ocsf_network_activity
WHERE dst_endpoint_ip != '';

-- Observable Statistics Aggregation
-- Compute hourly statistics for observables
DROP VIEW IF EXISTS ocsf_observable_stats_mv;
CREATE MATERIALIZED VIEW ocsf_observable_stats_mv AS
SELECT
    observable_type,
    observable_value,

    -- Time Window (hourly buckets)
    to_start_of_hour(time) AS time_window_start,
    to_start_of_hour(time) + INTERVAL 1 HOUR AS time_window_end,

    -- Statistics
    unique(entity_uid) AS entity_count,
    group_uniq_array(entity_class) AS entity_classes,
    group_uniq_array(discovery_source) AS discovery_sources,

    -- Activity Metrics
    min(time) AS first_seen,
    max(time) AS last_seen,
    count() AS occurrence_count,

    -- Confidence and Quality
    avg(confidence_score) AS avg_confidence_score,
    max(confidence_score) AS max_confidence_score,
    1.0 AS data_quality_score,  -- Will be computed by separate process

    -- Threat Intelligence (placeholder - populated by threat intel process)
    max(threat_score) AS max_threat_score,
    group_uniq_array(threat_categories) AS threat_categories,
    max(threat_score) > 0.5 AS is_flagged,

    -- Geographic Summary
    group_uniq_array(geo_country) AS countries,
    group_uniq_array(geo_region) AS regions,
    group_uniq_array(asn_org) AS asn_orgs,

    map_cast(CAST([] AS array(string)), CAST([] AS array(string))) AS metadata

FROM ocsf_observable_index
GROUP BY
    observable_type,
    observable_value,
    to_start_of_hour(time);

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
            AND coalesce(mac, '') = ''
       );

-- Allow non-sweep IP-identified devices to remain in unified device views.
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
            OR (discovery_source != 'sweep' AND coalesce(ip, '') != '')
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
            AND (
                has(discovery_sources, 'sweep')
                OR ip = ''
            )
       );

ALTER STREAM unified_devices_registry
    DELETE WHERE coalesce(metadata['_merged_into'], '') != ''
       OR lower(coalesce(metadata['_deleted'], 'false')) = 'true'
       OR (
            coalesce(metadata['armis_device_id'], '') = ''
            AND coalesce(metadata['integration_id'], metadata['netbox_device_id'], '') = ''
            AND coalesce(mac, '') = ''
            AND (
                has(discovery_sources, 'sweep')
                OR ip = ''
            )
       );
