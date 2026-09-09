defmodule ServiceRadar.Repo.Migrations.AddTimeseriesMetricsProbeIndex do
  @moduledoc """
  Adds the composite lookup used by SRQL sysmon presence probes and sections.

  The device detail page probes `timeseries_metrics` with
  `metric_type = ? AND metric_name = ? AND device_id = ANY(?) AND timestamp in
  last_24h ORDER BY timestamp DESC LIMIT 1`. The existing single-column
  indexes (`timestamp`, `metric_name`, `device_id`) force the planner to scan
  a large slice of the window and filter, so negative probes — the common
  case, proving a device has no data — walked the whole 24h of every metric
  and died to `statement_timeout` (Postgrex `:query_canceled`). The composite
  serves the equality prefix plus the ordered range in one index scan, making
  both present and absent probes bounded.

  `platform.timeseries_metrics` is a large TimescaleDB hypertable. Build one
  chunk per transaction so deployment does not hold a hypertable-wide lock
  for the full index build. TimescaleDB requires this option to run outside
  Ecto's DDL transaction and migration lock.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_timeseries_metrics_probe
    ON platform.timeseries_metrics (metric_type, metric_name, device_id, timestamp DESC)
    WITH (timescaledb.transaction_per_chunk)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.idx_timeseries_metrics_probe")
  end
end
