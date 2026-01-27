defmodule ServiceRadar.Repo.Migrations.AddInterfaceQueryIndexes do
  use Ecto.Migration

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_discovered_interfaces_device_uid_time
    ON platform.discovered_interfaces (device_id, interface_uid, timestamp DESC, created_at DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_timeseries_metrics_device_if_metric_time
    ON platform.timeseries_metrics (device_id, if_index, metric_name, metric_type, timestamp DESC)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.idx_discovered_interfaces_device_uid_time")
    execute("DROP INDEX IF EXISTS platform.idx_timeseries_metrics_device_if_metric_time")
  end
end
