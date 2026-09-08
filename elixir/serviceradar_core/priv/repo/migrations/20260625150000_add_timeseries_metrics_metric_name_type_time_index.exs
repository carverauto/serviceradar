defmodule ServiceRadar.Repo.Migrations.AddTimeseriesMetricsMetricNameTypeTimeIndex do
  @moduledoc """
  Adds a covering index for the raw device-page metric-point pulls that filter on
  (metric_type, metric_name) with an optional agent_id/device_id predicate and order by
  `timestamp DESC` with a LIMIT.

  The pre-existing indexes only lead with `metric_name` alone
  (`idx_timeseries_metrics_name`) or with `device_id`
  (`idx_timeseries_metrics_device_if_metric_time`). The SysmonMetrics device-detail charts
  also issue an agent-scoped raw pull
  (`... WHERE metric_type = $ AND metric_name = $ AND agent_id = $ ORDER BY timestamp DESC LIMIT $`)
  which has no usable index and degrades to a per-chunk bitmap heap scan over every
  `metric_name` match plus a sort (~1.3s mean on demo, a top CNPG CPU consumer).

  `(metric_name, metric_type, "timestamp" DESC)` lets PostgreSQL satisfy the two equality
  predicates from the index, walk rows in timestamp-descending order to serve the
  ORDER BY ... LIMIT without an explicit sort, and heap-check the remaining agent_id/device_id
  predicate. TimescaleDB propagates the index definition to existing and future chunks.
  """

  use Ecto.Migration

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_timeseries_metrics_name_type_time
    ON platform.timeseries_metrics (metric_name, metric_type, "timestamp" DESC)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.idx_timeseries_metrics_name_type_time")
  end
end
