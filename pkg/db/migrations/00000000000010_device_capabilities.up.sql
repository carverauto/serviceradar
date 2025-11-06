-- =================================================================
-- Device Capability Streams
-- =================================================================
-- Provides an append-only audit stream for capability check outcomes
-- and a versioned_kv registry that exposes the latest state per
-- Device ⇄ Service ⇄ Capability tuple.
-- =================================================================

-- -----------------------------------------------------------------
-- Audit Stream: device_capabilities
-- -----------------------------------------------------------------
CREATE STREAM IF NOT EXISTS device_capabilities (
    event_id            string,
    device_id           string,
    service_id          string DEFAULT '',
    service_type        string DEFAULT '',
    capability          string,
    state               string DEFAULT 'unknown', -- ok, degraded, failed, unknown
    enabled             bool,
    last_checked        DateTime64(3) DEFAULT now64(),
    last_success        nullable(DateTime64(3)),
    last_failure        nullable(DateTime64(3)),
    failure_reason      string DEFAULT '',
    metadata            string DEFAULT '{}',
    recorded_by         string DEFAULT 'system'
) ENGINE = Stream(1, 1, rand())
PARTITION BY to_start_of_day(coalesce(last_checked, _tp_time))
ORDER BY (last_checked, device_id, capability, service_id)
TTL to_start_of_day(coalesce(last_checked, _tp_time)) + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;

-- -----------------------------------------------------------------
-- Registry Stream: device_capability_registry (versioned_kv)
-- -----------------------------------------------------------------
CREATE STREAM IF NOT EXISTS device_capability_registry (
    device_id           string,
    capability          string,
    service_id          string DEFAULT '',
    service_type        string DEFAULT '',
    state               string DEFAULT 'unknown',
    enabled             bool,
    last_checked        DateTime64(3),
    last_success        nullable(DateTime64(3)),
    last_failure        nullable(DateTime64(3)),
    failure_reason      string DEFAULT '',
    metadata            string DEFAULT '{}',
    recorded_by         string DEFAULT 'system'
) PRIMARY KEY (device_id, capability, service_id)
  SETTINGS mode='versioned_kv', version_column='_tp_time';

-- -----------------------------------------------------------------
-- Materialized View: synchronize registry stream with latest events
-- -----------------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS device_capability_registry_mv
INTO device_capability_registry
AS
SELECT
    device_id,
    capability,
    service_id,
    service_type,
    state,
    enabled,
    last_checked,
    last_success,
    last_failure,
    failure_reason,
    metadata,
    recorded_by,
    _tp_time
FROM device_capabilities;
