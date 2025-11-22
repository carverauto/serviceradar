-- CPU rollup (single hypertable to satisfy Timescale CAGG constraints)
CREATE MATERIALIZED VIEW IF NOT EXISTS device_metrics_summary_cpu
WITH (timescaledb.continuous) AS
SELECT
    time_bucket(INTERVAL '5 minutes', timestamp) AS window_time,
    device_id,
    poller_id,
    agent_id,
    COALESCE(partition, 'default')               AS partition,
    AVG(usage_percent)                           AS avg_cpu_usage,
    COUNT(*)                                     AS metric_count
FROM cpu_metrics
GROUP BY window_time, device_id, poller_id, agent_id, COALESCE(partition, 'default')
WITH NO DATA;

ALTER MATERIALIZED VIEW device_metrics_summary_cpu
    SET (timescaledb.materialized_only = FALSE);

SELECT add_continuous_aggregate_policy(
    'device_metrics_summary_cpu',
    start_offset      => INTERVAL '3 days',
    end_offset        => INTERVAL '10 minutes',
    schedule_interval => INTERVAL '5 minutes',
    if_not_exists     => TRUE
);

SELECT add_retention_policy('device_metrics_summary_cpu', INTERVAL '3 days', if_not_exists => TRUE);

-- Disk rollup
CREATE MATERIALIZED VIEW IF NOT EXISTS device_metrics_summary_disk
WITH (timescaledb.continuous) AS
SELECT
    time_bucket(INTERVAL '5 minutes', timestamp) AS window_time,
    device_id,
    poller_id,
    agent_id,
    COALESCE(partition, 'default')               AS partition,
    MAX(total_bytes)                             AS total_disk_bytes,
    MAX(used_bytes)                              AS used_disk_bytes
FROM disk_metrics
GROUP BY window_time, device_id, poller_id, agent_id, COALESCE(partition, 'default')
WITH NO DATA;

ALTER MATERIALIZED VIEW device_metrics_summary_disk
    SET (timescaledb.materialized_only = FALSE);

SELECT add_continuous_aggregate_policy(
    'device_metrics_summary_disk',
    start_offset      => INTERVAL '3 days',
    end_offset        => INTERVAL '10 minutes',
    schedule_interval => INTERVAL '5 minutes',
    if_not_exists     => TRUE
);

SELECT add_retention_policy('device_metrics_summary_disk', INTERVAL '3 days', if_not_exists => TRUE);

-- Memory rollup
CREATE MATERIALIZED VIEW IF NOT EXISTS device_metrics_summary_memory
WITH (timescaledb.continuous) AS
SELECT
    time_bucket(INTERVAL '5 minutes', timestamp) AS window_time,
    device_id,
    poller_id,
    agent_id,
    COALESCE(partition, 'default')               AS partition,
    MAX(total_bytes)                             AS total_memory_bytes,
    MAX(used_bytes)                              AS used_memory_bytes
FROM memory_metrics
GROUP BY window_time, device_id, poller_id, agent_id, COALESCE(partition, 'default')
WITH NO DATA;

ALTER MATERIALIZED VIEW device_metrics_summary_memory
    SET (timescaledb.materialized_only = FALSE);

SELECT add_continuous_aggregate_policy(
    'device_metrics_summary_memory',
    start_offset      => INTERVAL '3 days',
    end_offset        => INTERVAL '10 minutes',
    schedule_interval => INTERVAL '5 minutes',
    if_not_exists     => TRUE
);

SELECT add_retention_policy('device_metrics_summary_memory', INTERVAL '3 days', if_not_exists => TRUE);

-- Composite view joining the single-hypertable CAGGs
CREATE OR REPLACE VIEW device_metrics_summary AS
SELECT
    cpu.window_time,
    cpu.device_id,
    cpu.poller_id,
    cpu.agent_id,
    cpu.partition,
    cpu.avg_cpu_usage,
    disk.total_disk_bytes,
    disk.used_disk_bytes,
    memory.total_memory_bytes,
    memory.used_memory_bytes,
    cpu.metric_count
FROM device_metrics_summary_cpu cpu
LEFT JOIN device_metrics_summary_disk disk
    ON disk.window_time = cpu.window_time
   AND disk.device_id = cpu.device_id
   AND disk.poller_id = cpu.poller_id
   AND disk.agent_id = cpu.agent_id
   AND disk.partition = cpu.partition
LEFT JOIN device_metrics_summary_memory memory
    ON memory.window_time = cpu.window_time
   AND memory.device_id = cpu.device_id
   AND memory.poller_id = cpu.poller_id
   AND memory.agent_id = cpu.agent_id
   AND memory.partition = cpu.partition;
