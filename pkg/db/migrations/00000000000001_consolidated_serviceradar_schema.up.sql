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
