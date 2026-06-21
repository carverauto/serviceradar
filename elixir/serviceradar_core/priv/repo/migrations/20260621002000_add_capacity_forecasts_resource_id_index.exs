defmodule ServiceRadar.Repo.Migrations.AddCapacityForecastsResourceIdIndex do
  @moduledoc false

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_capacity_forecasts_resource_id_time
    ON platform.capacity_forecasts (resource_id, forecasted_at DESC)
    INCLUDE (resource_label, metric_name, status, projected_exhaustion_at)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS platform.idx_capacity_forecasts_resource_id_time")
  end
end
