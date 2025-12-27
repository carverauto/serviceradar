defmodule ServiceRadar.Repo.Migrations.RecreateMetricTablesFromGo do
  @moduledoc """
  Recreates metric tables matching the Go schema exactly.
  These are TimescaleDB hypertables that Ash was creating with different schemas.

  This migration drops any Ash-created tables with conflicting schemas
  and recreates them with the proper Go schema.
  """

  use Ecto.Migration

  def up do
    # Drop any Ash-created metric tables with wrong schema
    execute "DROP TABLE IF EXISTS timeseries_metrics CASCADE"
    execute "DROP TABLE IF EXISTS cpu_metrics CASCADE"
    execute "DROP TABLE IF EXISTS memory_metrics CASCADE"
    execute "DROP TABLE IF EXISTS disk_metrics CASCADE"
    execute "DROP TABLE IF EXISTS process_metrics CASCADE"

    # Create timeseries_metrics table matching Go schema exactly
    execute """
    CREATE TABLE IF NOT EXISTS timeseries_metrics (
        timestamp           TIMESTAMPTZ       NOT NULL,
        poller_id           TEXT              NOT NULL,
        agent_id            TEXT,
        metric_name         TEXT              NOT NULL,
        metric_type         TEXT              NOT NULL,
        device_id           TEXT,
        value               DOUBLE PRECISION  NOT NULL,
        unit                TEXT,
        tags                JSONB,
        partition           TEXT,
        scale               DOUBLE PRECISION,
        is_delta            BOOLEAN           DEFAULT FALSE,
        target_device_ip    TEXT,
        if_index            INTEGER,
        metadata            JSONB,
        created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
    )
    """

    execute "SELECT create_hypertable('timeseries_metrics','timestamp', if_not_exists => TRUE)"
    execute "CREATE INDEX IF NOT EXISTS idx_timeseries_metrics_device_time ON timeseries_metrics (device_id, timestamp DESC)"

    # Create cpu_metrics table matching Go schema exactly
    execute """
    CREATE TABLE IF NOT EXISTS cpu_metrics (
        timestamp           TIMESTAMPTZ       NOT NULL,
        poller_id           TEXT              NOT NULL,
        agent_id            TEXT,
        host_id             TEXT,
        core_id             INTEGER,
        usage_percent       DOUBLE PRECISION,
        frequency_hz        DOUBLE PRECISION,
        label               TEXT,
        cluster             TEXT,
        device_id           TEXT,
        partition           TEXT,
        created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
    )
    """

    execute "SELECT create_hypertable('cpu_metrics','timestamp', if_not_exists => TRUE)"
    execute "CREATE INDEX IF NOT EXISTS idx_cpu_metrics_device_time ON cpu_metrics (device_id, timestamp DESC)"

    # Create memory_metrics table matching Go schema exactly
    execute """
    CREATE TABLE IF NOT EXISTS memory_metrics (
        timestamp           TIMESTAMPTZ       NOT NULL,
        poller_id           TEXT,
        agent_id            TEXT,
        host_id             TEXT,
        total_bytes         BIGINT,
        used_bytes          BIGINT,
        available_bytes     BIGINT,
        usage_percent       DOUBLE PRECISION,
        device_id           TEXT,
        partition           TEXT,
        created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
    )
    """

    execute "SELECT create_hypertable('memory_metrics','timestamp', if_not_exists => TRUE)"

    # Create disk_metrics table matching Go schema exactly
    execute """
    CREATE TABLE IF NOT EXISTS disk_metrics (
        timestamp           TIMESTAMPTZ       NOT NULL,
        poller_id           TEXT,
        agent_id            TEXT,
        host_id             TEXT,
        mount_point         TEXT,
        device_name         TEXT,
        total_bytes         BIGINT,
        used_bytes          BIGINT,
        available_bytes     BIGINT,
        usage_percent       DOUBLE PRECISION,
        device_id           TEXT,
        partition           TEXT,
        created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
    )
    """

    execute "SELECT create_hypertable('disk_metrics','timestamp', if_not_exists => TRUE)"

    # Create process_metrics table matching Go schema exactly
    execute """
    CREATE TABLE IF NOT EXISTS process_metrics (
        timestamp           TIMESTAMPTZ       NOT NULL,
        poller_id           TEXT,
        agent_id            TEXT,
        host_id             TEXT,
        pid                 INTEGER,
        name                TEXT,
        cpu_usage           REAL,
        memory_usage        BIGINT,
        status              TEXT,
        start_time          TEXT,
        device_id           TEXT,
        partition           TEXT,
        created_at          TIMESTAMPTZ       NOT NULL DEFAULT now()
    )
    """

    execute "SELECT create_hypertable('process_metrics','timestamp', if_not_exists => TRUE)"
  end

  def down do
    execute "DROP TABLE IF EXISTS process_metrics CASCADE"
    execute "DROP TABLE IF EXISTS disk_metrics CASCADE"
    execute "DROP TABLE IF EXISTS memory_metrics CASCADE"
    execute "DROP TABLE IF EXISTS cpu_metrics CASCADE"
    execute "DROP TABLE IF EXISTS timeseries_metrics CASCADE"
  end
end
