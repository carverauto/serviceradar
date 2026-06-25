defmodule ServiceRadar.Repo.Migrations.AddTimeseriesMetricsAgentDeviceMetricTimeIndexes do
  @moduledoc """
  Composite indexes for the RAW full-row metric-point pulls behind the device/interface
  charts (web-ng DeviceLive sysmon_metrics / interface_data). These are NOT aggregations
  — the CAGG-routing fix (rust/srql downsample/sql.rs) correctly does not apply to raw
  point queries — they just needed an index that anchors all three equality predicates
  (agent_id|device_id + metric_type + metric_name) and walks "timestamp" DESC so the
  ORDER BY timestamp DESC LIMIT fills with zero skipped rows (eliminating the post-index
  Filter skip-walk that was ~1.2s / 0.73s mean on demo).

  NOTE: timeseries_metrics is a TimescaleDB hypertable, so CONCURRENTLY is rejected
  (same as the prior ocsf_events/timeseries index work) — this builds non-concurrently;
  Timescale propagates the definition to existing and future chunks.

  Renumbered from 20260625160000 to 20260625161000 to avoid colliding with
  AddDireReconciliationIndexes.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_timeseries_metrics_agent_metric_time
    ON platform.timeseries_metrics (agent_id, metric_type, metric_name, "timestamp" DESC)
    WHERE agent_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_timeseries_metrics_device_metric_time
    ON platform.timeseries_metrics (device_id, metric_type, metric_name, "timestamp" DESC)
    WHERE device_id IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.idx_timeseries_metrics_agent_metric_time")
    execute("DROP INDEX IF EXISTS platform.idx_timeseries_metrics_device_metric_time")
  end
end
