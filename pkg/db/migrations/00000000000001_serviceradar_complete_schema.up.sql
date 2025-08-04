-- =================================================================
-- == ServiceRadar Complete Database Schema - Clean Slate
-- =================================================================
-- This migration creates the complete ServiceRadar database schema
-- from scratch, replacing all previous migrations with a clean,
-- efficient implementation that eliminates trace multiplication issues.
--
-- This is the ONLY migration you need for a fresh ServiceRadar installation.

-- =================================================================
-- CORE OPERATIONAL TABLES
-- =================================================================

-- Poller status tracking
CREATE STREAM IF NOT EXISTS pollers (
    poller_id           string CODEC(ZSTD(1)),
    hostname            string CODEC(ZSTD(1)),
    ip_address          string CODEC(ZSTD(1)),
    version             string CODEC(ZSTD(1)),
    status              string CODEC(ZSTD(1)),
    last_heartbeat      DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    uptime_seconds      uint64 CODEC(ZSTD(1)),
    cpu_usage           float32 CODEC(ZSTD(1)),
    memory_usage        float32 CODEC(ZSTD(1)),
    active_jobs         uint32 CODEC(ZSTD(1)),
    completed_jobs      uint64 CODEC(ZSTD(1)),
    failed_jobs         uint64 CODEC(ZSTD(1)),
    config_version      string CODEC(ZSTD(1)),
    created_at          DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    updated_at          DateTime64(9) CODEC(Delta(8), ZSTD(1))
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(updated_at), 86400)
ORDER BY (poller_id, updated_at)
SETTINGS index_granularity = 8192;

-- Unified devices table for all device tracking
CREATE STREAM IF NOT EXISTS devices (
    device_id           string CODEC(ZSTD(1)),
    hostname            string CODEC(ZSTD(1)),
    ip_address          string CODEC(ZSTD(1)),
    mac_address         string CODEC(ZSTD(1)),
    device_type         string CODEC(ZSTD(1)),
    vendor              string CODEC(ZSTD(1)),
    model               string CODEC(ZSTD(1)),
    os_name             string CODEC(ZSTD(1)),
    os_version          string CODEC(ZSTD(1)),
    first_seen          DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    last_seen           DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    status              string CODEC(ZSTD(1)),
    poller_id           string CODEC(ZSTD(1)),
    site_id             string CODEC(ZSTD(1)),
    subnet              string CODEC(ZSTD(1)),
    vlan                uint16 CODEC(ZSTD(1)),
    snmp_community      string CODEC(ZSTD(1)),
    snmp_version        string CODEC(ZSTD(1)),
    credentials_id      string CODEC(ZSTD(1)),
    tags                array(string) CODEC(ZSTD(1)),
    metadata            string CODEC(ZSTD(1)),
    created_at          DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    updated_at          DateTime64(9) CODEC(Delta(8), ZSTD(1))
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(updated_at), 86400)
ORDER BY (device_id, updated_at)
SETTINGS index_granularity = 8192;

-- Device discovery results
CREATE STREAM IF NOT EXISTS device_discoveries (
    discovery_id        string CODEC(ZSTD(1)),
    device_id           string CODEC(ZSTD(1)),
    poller_id           string CODEC(ZSTD(1)),
    discovery_method    string CODEC(ZSTD(1)),
    ip_address          string CODEC(ZSTD(1)),
    hostname            string CODEC(ZSTD(1)),
    mac_address         string CODEC(ZSTD(1)),
    device_type         string CODEC(ZSTD(1)),
    vendor              string CODEC(ZSTD(1)),
    model               string CODEC(ZSTD(1)),
    os_info             string CODEC(ZSTD(1)),
    services            array(string) CODEC(ZSTD(1)),
    ports_open          array(uint16) CODEC(ZSTD(1)),
    confidence_score    float32 CODEC(ZSTD(1)),
    discovered_at       DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    metadata            string CODEC(ZSTD(1))
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(discovered_at), 86400)
ORDER BY (poller_id, discovered_at)
SETTINGS index_granularity = 8192;

-- Network interfaces
CREATE STREAM IF NOT EXISTS interfaces (
    interface_id        string CODEC(ZSTD(1)),
    device_id           string CODEC(ZSTD(1)),
    interface_name      string CODEC(ZSTD(1)),
    interface_index     uint32 CODEC(ZSTD(1)),
    interface_type      string CODEC(ZSTD(1)),
    mac_address         string CODEC(ZSTD(1)),
    ip_address          string CODEC(ZSTD(1)),
    subnet_mask         string CODEC(ZSTD(1)),
    admin_status        string CODEC(ZSTD(1)),
    oper_status         string CODEC(ZSTD(1)),
    speed               uint64 CODEC(ZSTD(1)),
    mtu                 uint32 CODEC(ZSTD(1)),
    description         string CODEC(ZSTD(1)),
    vlan                uint16 CODEC(ZSTD(1)),
    updated_at          DateTime64(9) CODEC(Delta(8), ZSTD(1))
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(updated_at), 86400)
ORDER BY (device_id, interface_id, updated_at)
SETTINGS index_granularity = 8192;

-- SNMP status tracking
CREATE STREAM IF NOT EXISTS snmp_status (
    device_id           string CODEC(ZSTD(1)),
    poller_id           string CODEC(ZSTD(1)),
    status              string CODEC(ZSTD(1)),
    response_time_ms    float32 CODEC(ZSTD(1)),
    error_message       string CODEC(ZSTD(1)),
    community_string    string CODEC(ZSTD(1)),
    snmp_version        string CODEC(ZSTD(1)),
    last_success        DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    last_attempt        DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    consecutive_failures uint32 CODEC(ZSTD(1)),
    timestamp           DateTime64(9) CODEC(Delta(8), ZSTD(1))
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 86400)
ORDER BY (device_id, timestamp)
SETTINGS index_granularity = 8192;

-- Authentication credentials
CREATE STREAM IF NOT EXISTS auth_credentials (
    credential_id       string CODEC(ZSTD(1)),
    credential_type     string CODEC(ZSTD(1)),
    username            string CODEC(ZSTD(1)),
    password_hash       string CODEC(ZSTD(1)),
    ssh_key             string CODEC(ZSTD(1)),
    snmp_community      string CODEC(ZSTD(1)),
    snmp_version        string CODEC(ZSTD(1)),
    snmp_auth_protocol  string CODEC(ZSTD(1)),
    snmp_priv_protocol  string CODEC(ZSTD(1)),
    description         string CODEC(ZSTD(1)),
    created_at          DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    updated_at          DateTime64(9) CODEC(Delta(8), ZSTD(1))
) ENGINE = Stream(1, 1, rand())
ORDER BY (credential_id, updated_at)
SETTINGS index_granularity = 8192;

-- Network discovery sweeps
CREATE STREAM IF NOT EXISTS network_sweeps (
    sweep_id            string CODEC(ZSTD(1)),
    poller_id           string CODEC(ZSTD(1)),
    subnet              string CODEC(ZSTD(1)),
    sweep_type          string CODEC(ZSTD(1)),
    started_at          DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    completed_at        DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    hosts_discovered    uint32 CODEC(ZSTD(1)),
    hosts_responsive    uint32 CODEC(ZSTD(1)),
    status              string CODEC(ZSTD(1)),
    error_message       string CODEC(ZSTD(1))
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(started_at), 86400)
ORDER BY (poller_id, started_at)
SETTINGS index_granularity = 8192;

-- Services discovered on devices
CREATE STREAM IF NOT EXISTS services (
    service_id          string CODEC(ZSTD(1)),
    device_id           string CODEC(ZSTD(1)),
    service_name        string CODEC(ZSTD(1)),
    port                uint16 CODEC(ZSTD(1)),
    protocol            string CODEC(ZSTD(1)),
    service_type        string CODEC(ZSTD(1)),
    version             string CODEC(ZSTD(1)),
    banner              string CODEC(ZSTD(1)),
    status              string CODEC(ZSTD(1)),
    last_seen           DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    first_discovered    DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    confidence_score    float32 CODEC(ZSTD(1))
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(last_seen), 86400)
ORDER BY (device_id, service_id, last_seen)
SETTINGS index_granularity = 8192;

-- =================================================================
-- OBSERVABILITY TABLES (LOGS, METRICS, TRACES)
-- =================================================================

-- Application and system logs
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
    resource_attributes string CODEC(ZSTD(1)),
    raw_data           string CODEC(ZSTD(1))
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (timestamp, service_name, trace_id)
SETTINGS index_granularity = 8192;

-- Process and system metrics (using original schema)
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
);

-- OpenTelemetry metrics
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
    level           string CODEC(ZSTD(1)),
    raw_data        string CODEC(ZSTD(1))
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (timestamp, service_name, span_id)
SETTINGS index_granularity = 8192;

-- OpenTelemetry traces (raw span data)
CREATE STREAM IF NOT EXISTS otel_traces (
    timestamp          DateTime64(9) CODEC(Delta(8), ZSTD(1)),
    trace_id           string CODEC(ZSTD(1)),
    span_id            string CODEC(ZSTD(1)),
    parent_span_id     string CODEC(ZSTD(1)),
    name               string CODEC(ZSTD(1)),
    kind               int32 CODEC(ZSTD(1)),
    start_time_unix_nano uint64 CODEC(Delta(8), ZSTD(1)),
    end_time_unix_nano   uint64 CODEC(Delta(8), ZSTD(1)),
    service_name       string CODEC(ZSTD(1)),
    service_version    string CODEC(ZSTD(1)),
    service_instance_id string CODEC(ZSTD(1)),
    status_code        int32 CODEC(ZSTD(1)),
    status_message     string CODEC(ZSTD(1)),
    attributes         map(string, string) CODEC(ZSTD(1)),
    events             array(string) CODEC(ZSTD(1)),
    links              array(string) CODEC(ZSTD(1)),
    resource_attributes map(string, string) CODEC(ZSTD(1))
) ENGINE = Stream(1, 1, rand())
PARTITION BY int_div(to_unix_timestamp(timestamp), 3600)
ORDER BY (trace_id, span_id, timestamp)
SETTINGS index_granularity = 8192;

-- =================================================================
-- TRACE SUMMARIES - CLEAN, EFFICIENT IMPLEMENTATION
-- =================================================================

-- Trace summaries stream - aggregated trace information
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
SETTINGS index_granularity = 8192;

-- Step 1: Create an intermediate enriched spans stream (like the working version)
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
SETTINGS index_granularity = 8192;

-- Step 1 MV: Enrich spans with duration calculation
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

-- Step 2: Create the final trace summaries materialized view (using simple aggregations)
CREATE MATERIALIZED VIEW IF NOT EXISTS otel_trace_summaries_mv
INTO otel_trace_summaries AS
SELECT
  min(timestamp) AS timestamp,
  trace_id,
  
  -- Root span detection using the enriched data
  any_if(span_id, is_root) AS root_span_id,
  any_if(name, is_root) AS root_span_name,
  any_if(service_name, is_root) AS root_service_name,
  any_if(kind, is_root) AS root_span_kind,
  
  -- Store raw timing values (let views calculate duration)
  min(start_time_unix_nano) AS start_time_unix_nano,
  max(end_time_unix_nano) AS end_time_unix_nano,
  any_if(duration_ms, is_root) AS duration_ms,  -- Use span-level duration from root span
  
  -- Status
  max(status_code) AS status_code,
  
  -- Aggregations  
  group_uniq_array(service_name) AS service_set,
  count() AS span_count,
  0 AS error_count  -- Placeholder for now

FROM otel_spans_enriched
GROUP BY trace_id;

-- Optional: Span attributes for filtering (populated by event writer)
CREATE STREAM IF NOT EXISTS otel_span_attrs (
  trace_id string,
  span_id  string,
  http_method nullable(string),
  http_route  nullable(string),
  http_status_code nullable(string),
  rpc_service nullable(string),
  rpc_method  nullable(string),
  rpc_grpc_status_code nullable(string)
) ENGINE = Stream(1, 1, rand())
ORDER BY (trace_id, span_id);

-- =================================================================
-- UI COMPATIBILITY VIEWS
-- =================================================================

-- Deduplication view - simple pass-through
-- Note: duration_ms and error_count will be 0 from MV, can be calculated in application
CREATE VIEW IF NOT EXISTS otel_trace_summaries_dedup AS
SELECT 
  trace_id,
  any(timestamp) as timestamp,
  any(root_span_id) as root_span_id,
  any(root_span_name) as root_span_name,
  any(root_service_name) as root_service_name,
  any(root_span_kind) as root_span_kind,
  any(start_time_unix_nano) as start_time_unix_nano,
  any(end_time_unix_nano) as end_time_unix_nano,
  any(duration_ms) as duration_ms,  -- Will be 0 from MV
  any(span_count) as span_count,
  any(error_count) as error_count,  -- Will be 0 from MV
  any(status_code) as status_code,
  any(service_set) as service_set
FROM otel_trace_summaries
GROUP BY trace_id;

-- UI compatibility aliases
CREATE VIEW otel_trace_summaries_final AS 
SELECT * FROM otel_trace_summaries_dedup;

CREATE VIEW otel_trace_summaries_final_v2 AS 
SELECT * FROM otel_trace_summaries_dedup;

CREATE VIEW otel_trace_summaries_deduplicated AS 
SELECT * FROM otel_trace_summaries_dedup;

-- =================================================================
-- PERFORMANCE INDEXES
-- =================================================================

-- Poller indexes
ALTER STREAM pollers ADD INDEX IF NOT EXISTS idx_poller_id poller_id TYPE bloom_filter GRANULARITY 1;
ALTER STREAM pollers ADD INDEX IF NOT EXISTS idx_status status TYPE bloom_filter GRANULARITY 1;
ALTER STREAM pollers ADD INDEX IF NOT EXISTS idx_updated updated_at TYPE minmax GRANULARITY 1;

-- Core device indexes
ALTER STREAM devices ADD INDEX IF NOT EXISTS idx_device_id device_id TYPE bloom_filter GRANULARITY 1;
ALTER STREAM devices ADD INDEX IF NOT EXISTS idx_ip ip_address TYPE bloom_filter GRANULARITY 1;
ALTER STREAM devices ADD INDEX IF NOT EXISTS idx_hostname hostname TYPE bloom_filter GRANULARITY 1;
ALTER STREAM devices ADD INDEX IF NOT EXISTS idx_poller poller_id TYPE bloom_filter GRANULARITY 1;
ALTER STREAM devices ADD INDEX IF NOT EXISTS idx_updated updated_at TYPE minmax GRANULARITY 1;

-- Discovery indexes
ALTER STREAM device_discoveries ADD INDEX IF NOT EXISTS idx_device_id device_id TYPE bloom_filter GRANULARITY 1;
ALTER STREAM device_discoveries ADD INDEX IF NOT EXISTS idx_poller poller_id TYPE bloom_filter GRANULARITY 1;
ALTER STREAM device_discoveries ADD INDEX IF NOT EXISTS idx_discovered discovered_at TYPE minmax GRANULARITY 1;

-- Interface indexes
ALTER STREAM interfaces ADD INDEX IF NOT EXISTS idx_device_id device_id TYPE bloom_filter GRANULARITY 1;
ALTER STREAM interfaces ADD INDEX IF NOT EXISTS idx_interface interface_name TYPE bloom_filter GRANULARITY 1;

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