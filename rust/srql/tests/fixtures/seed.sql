-- Canonical SRQL device fixture rows.
TRUNCATE unified_devices RESTART IDENTITY;

WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO unified_devices (
    device_id,
    ip,
    poller_id,
    agent_id,
    hostname,
    mac,
    discovery_sources,
    is_available,
    first_seen,
    last_seen,
    metadata,
    device_type,
    service_type,
    service_status,
    last_heartbeat,
    os_info,
    version_info
)
SELECT
    'device-alpha',
    '10.10.10.5',
    'poller-1',
    'agent-1',
    'alpha-edge',
    'aa:bb:cc:dd:ee:01',
    ARRAY['sweep','armis'],
    TRUE,
    base.now_ts - INTERVAL '14 days',
    base.now_ts - INTERVAL '1 hour',
    '{"site":"dfw-edge","packet_loss_bucket":"low"}'::jsonb,
    'network_device',
    'router',
    'healthy',
    base.now_ts - INTERVAL '65 minutes',
    'IOS-XE',
    '17.9.3'
FROM base
UNION ALL
SELECT
    'device-beta',
    '10.10.20.6',
    'poller-1',
    'agent-2',
    'beta-core',
    'aa:bb:cc:dd:ee:02',
    ARRAY['armis'],
    FALSE,
    base.now_ts - INTERVAL '10 days',
    base.now_ts - INTERVAL '3 hours',
    '{"site":"dfw-edge","packet_loss_bucket":"medium"}'::jsonb,
    'network_device',
    'switch',
    'warning',
    base.now_ts - INTERVAL '1 day',
    'NX-OS',
    '10.2(4)'
FROM base
UNION ALL
SELECT
    'device-gamma',
    '10.10.30.7',
    'poller-2',
    'agent-3',
    'gamma-edge',
    'aa:bb:cc:dd:ee:03',
    ARRAY['sweep'],
    TRUE,
    base.now_ts - INTERVAL '6 days',
    base.now_ts - INTERVAL '2 hours',
    '{"site":"phx-edge","packet_loss_bucket":"high"}'::jsonb,
    'network_device',
    'firewall',
    'critical',
    base.now_ts - INTERVAL '90 minutes',
    'PAN-OS',
    '11.1.0'
FROM base;

WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO pollers (
    poller_id, component_id, registration_source, status, spiffe_identity,
    first_registered, first_seen, last_seen, metadata, created_by,
    is_healthy, agent_count, checker_count, updated_at
)
SELECT
    'poller-1', 'comp-1', 'manual', 'active', 'spiffe://example.org/poller/1',
    base.now_ts - INTERVAL '30 days', base.now_ts - INTERVAL '30 days', base.now_ts - INTERVAL '1 minute',
    '{"region":"us-west"}'::jsonb, 'admin', true, 10, 50, base.now_ts
FROM base
UNION ALL
SELECT
    'poller-2', 'comp-2', 'auto', 'active', 'spiffe://example.org/poller/2',
    base.now_ts - INTERVAL '15 days', base.now_ts - INTERVAL '15 days', base.now_ts - INTERVAL '2 minutes',
    '{"region":"us-east"}'::jsonb, 'system', true, 5, 25, base.now_ts
FROM base;

WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO service_status (
    timestamp, poller_id, agent_id, service_name, service_type,
    available, message, details, partition, created_at
)
SELECT
    base.now_ts - INTERVAL '5 minutes', 'poller-1', 'agent-1', 'ssh', 'ssh',
    true, 'SSH service running', 'listening on port 22', 'default', base.now_ts
FROM base
UNION ALL
SELECT
    base.now_ts - INTERVAL '10 minutes', 'poller-1', 'agent-1', 'http', 'http',
    false, 'HTTP service down', 'connection refused', 'default', base.now_ts
FROM base;

WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO cpu_metrics (
    timestamp, poller_id, agent_id, host_id, core_id,
    usage_percent, frequency_hz, label, cluster, device_id, partition, created_at
)
SELECT
    base.now_ts - INTERVAL '1 minute', 'poller-1', 'agent-1', 'host-1', 0,
    45.5, 2400000000, 'cpu0', 'cluster-a', 'device-alpha', 'default', base.now_ts
FROM base
UNION ALL
SELECT
    base.now_ts - INTERVAL '2 minutes', 'poller-1', 'agent-1', 'host-1', 1,
    88.2, 2400000000, 'cpu1', 'cluster-a', 'device-alpha', 'default', base.now_ts
FROM base;

WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO logs (
    timestamp, trace_id, span_id, severity_text, severity_number,
    body, service_name, service_version, service_instance, scope_name,
    scope_version, attributes, resource_attributes, created_at
)
SELECT
    base.now_ts - INTERVAL '1 minute', 'trace-1', 'span-1', 'INFO', 9,
    'Application started', 'my-service', '1.0.0', 'inst-1', 'my-scope',
    '1.0', '{"key":"value"}'::text, '{"res":"val"}'::text, base.now_ts
FROM base
UNION ALL
SELECT
    base.now_ts - INTERVAL '5 minutes', 'trace-2', 'span-2', 'ERROR', 17,
    'Connection failed', 'my-service', '1.0.0', 'inst-1', 'my-scope',
    '1.0', '{"error":"timeout"}'::text, '{"res":"val"}'::text, base.now_ts
FROM base;

WITH base AS (
    SELECT NOW() AS now_ts
)
INSERT INTO otel_traces (
    timestamp, trace_id, span_id, parent_span_id, name, kind,
    start_time_unix_nano, end_time_unix_nano, service_name, service_version,
    service_instance, scope_name, scope_version, status_code, status_message,
    attributes, resource_attributes, events, links, created_at
)
SELECT
    base.now_ts - INTERVAL '1 minute', 'trace-1', 'span-1', NULL, 'handle_request', 1,
    1600000000000000000, 1600000000100000000, 'api-service', 'v1',
    'pod-1', 'http-server', '1.0', 1, 'OK',
    '{"http.method":"GET"}'::text, '{"k8s.pod":"pod-1"}'::text, '[]', '[]', base.now_ts
FROM base;
