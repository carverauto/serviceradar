-- Timescale continuous aggregate that replaces the Proton device_metrics_summary stream

CREATE MATERIALIZED VIEW IF NOT EXISTS device_metrics_summary
WITH (timescaledb.continuous) AS
SELECT
    time_bucket(INTERVAL '5 minutes', c.timestamp) AS window_time,
    c.device_id,
    c.poller_id,
    c.agent_id,
    COALESCE(c.partition, 'default')              AS partition,
    AVG(c.usage_percent)                          AS avg_cpu_usage,
    MAX(d.total_bytes)                            AS total_disk_bytes,
    MAX(d.used_bytes)                             AS used_disk_bytes,
    MAX(m.total_bytes)                            AS total_memory_bytes,
    MAX(m.used_bytes)                             AS used_memory_bytes,
    COUNT(*)                                      AS metric_count
FROM cpu_metrics c
LEFT JOIN disk_metrics d
    ON d.device_id = c.device_id
   AND d.poller_id = c.poller_id
   AND time_bucket(INTERVAL '5 minutes', d.timestamp) = time_bucket(INTERVAL '5 minutes', c.timestamp)
LEFT JOIN memory_metrics m
    ON m.device_id = c.device_id
   AND m.poller_id = c.poller_id
   AND time_bucket(INTERVAL '5 minutes', m.timestamp) = time_bucket(INTERVAL '5 minutes', c.timestamp)
GROUP BY window_time, c.device_id, c.poller_id, c.agent_id, COALESCE(c.partition, 'default')
WITH NO DATA;

ALTER MATERIALIZED VIEW device_metrics_summary
    SET (timescaledb.materialized_only = FALSE);

SELECT add_continuous_aggregate_policy(
    'device_metrics_summary',
    start_offset      => INTERVAL '3 days',
    end_offset        => INTERVAL '10 minutes',
    schedule_interval => INTERVAL '5 minutes',
    if_not_exists     => TRUE
);

SELECT add_retention_policy('device_metrics_summary', INTERVAL '3 days', if_not_exists => TRUE);
