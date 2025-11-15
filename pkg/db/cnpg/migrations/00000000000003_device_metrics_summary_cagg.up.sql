-- Timescale continuous aggregate that replaces the Proton device_metrics_summary stream

DO $$
BEGIN
    CREATE MATERIALIZED VIEW IF NOT EXISTS device_metrics_summary
    WITH (timescaledb.continuous) AS
    WITH cpu AS (
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
    ),
    disk AS (
        SELECT
            time_bucket(INTERVAL '5 minutes', timestamp) AS window_time,
            device_id,
            poller_id,
            MAX(total_bytes)                             AS total_disk_bytes,
            MAX(used_bytes)                              AS used_disk_bytes
        FROM disk_metrics
        GROUP BY window_time, device_id, poller_id
    ),
    memory AS (
        SELECT
            time_bucket(INTERVAL '5 minutes', timestamp) AS window_time,
            device_id,
            poller_id,
            MAX(total_bytes)                             AS total_memory_bytes,
            MAX(used_bytes)                              AS used_memory_bytes
        FROM memory_metrics
        GROUP BY window_time, device_id, poller_id
    )
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
    FROM cpu
    LEFT JOIN disk
        ON disk.window_time = cpu.window_time
       AND disk.device_id = cpu.device_id
       AND disk.poller_id = cpu.poller_id
    LEFT JOIN memory
        ON memory.window_time = cpu.window_time
       AND memory.device_id = cpu.device_id
       AND memory.poller_id = cpu.poller_id
    WITH NO DATA;

    ALTER MATERIALIZED VIEW device_metrics_summary
        SET (timescaledb.materialized_only = FALSE);

    PERFORM add_continuous_aggregate_policy(
        'device_metrics_summary',
        start_offset      => INTERVAL '3 days',
        end_offset        => INTERVAL '10 minutes',
        schedule_interval => INTERVAL '5 minutes',
        if_not_exists     => TRUE
    );

    PERFORM add_retention_policy('device_metrics_summary', INTERVAL '3 days', if_not_exists => TRUE);
EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'device_metrics_summary continuous aggregate skipped: %', SQLERRM;
END$$;
