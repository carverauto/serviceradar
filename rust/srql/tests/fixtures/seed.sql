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
