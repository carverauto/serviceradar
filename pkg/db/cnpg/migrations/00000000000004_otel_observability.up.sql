-- Timescale hypertables for OTEL logs, metrics, and traces.

CREATE TABLE IF NOT EXISTS logs (
    timestamp           TIMESTAMPTZ   NOT NULL,
    trace_id            TEXT,
    span_id             TEXT,
    severity_text       TEXT,
    severity_number     INTEGER,
    body                TEXT,
    service_name        TEXT,
    service_version     TEXT,
    service_instance    TEXT,
    scope_name          TEXT,
    scope_version       TEXT,
    attributes          TEXT,
    resource_attributes TEXT,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    PRIMARY KEY (timestamp, trace_id, span_id)
);
SELECT create_hypertable('logs','timestamp', if_not_exists => TRUE);
SELECT add_retention_policy('logs', INTERVAL '3 days', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_logs_service_time ON logs (service_name, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_logs_trace_id ON logs (trace_id);

CREATE TABLE IF NOT EXISTS otel_metrics (
    timestamp           TIMESTAMPTZ       NOT NULL,
    trace_id            TEXT,
    span_id             TEXT,
    service_name        TEXT,
    span_name           TEXT,
    span_kind           TEXT,
    duration_ms         DOUBLE PRECISION,
    duration_seconds    DOUBLE PRECISION,
    metric_type         TEXT,
    http_method         TEXT,
    http_route          TEXT,
    http_status_code    TEXT,
    grpc_service        TEXT,
    grpc_method         TEXT,
    grpc_status_code    TEXT,
    is_slow             BOOLEAN,
    component           TEXT,
    level               TEXT,
    created_at          TIMESTAMPTZ       NOT NULL DEFAULT now(),
    PRIMARY KEY (timestamp, span_name, service_name, span_id)
);
SELECT create_hypertable('otel_metrics','timestamp', if_not_exists => TRUE);
SELECT add_retention_policy('otel_metrics', INTERVAL '3 days', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_otel_metrics_service_time ON otel_metrics (service_name, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_otel_metrics_component ON otel_metrics (component);

CREATE TABLE IF NOT EXISTS otel_traces (
    timestamp           TIMESTAMPTZ   NOT NULL,
    trace_id            TEXT,
    span_id             TEXT,
    parent_span_id      TEXT,
    name                TEXT,
    kind                INTEGER,
    start_time_unix_nano BIGINT,
    end_time_unix_nano  BIGINT,
    service_name        TEXT,
    service_version     TEXT,
    service_instance    TEXT,
    scope_name          TEXT,
    scope_version       TEXT,
    status_code         INTEGER,
    status_message      TEXT,
    attributes          TEXT,
    resource_attributes TEXT,
    events              TEXT,
    links               TEXT,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    PRIMARY KEY (timestamp, trace_id, span_id)
);
SELECT create_hypertable('otel_traces','timestamp', if_not_exists => TRUE);
SELECT add_retention_policy('otel_traces', INTERVAL '3 days', if_not_exists => TRUE);
CREATE INDEX IF NOT EXISTS idx_otel_traces_trace_id ON otel_traces (trace_id);
CREATE INDEX IF NOT EXISTS idx_otel_traces_service_time ON otel_traces (service_name, timestamp DESC);
