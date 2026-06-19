defmodule ServiceRadar.Repo.Migrations.AddCapacityForecastsResourceIdIndex do
  @moduledoc """
  Adds a direct lookup path for device-scoped capacity forecast reads.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_capacity_forecasts_resource_id_exhaustion
    ON #{schema()}.capacity_forecasts (resource_id, projected_exhaustion_at)
    WHERE projected_exhaustion_at IS NOT NULL
    """)
  end

  def down do
    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS #{schema()}.idx_capacity_forecasts_resource_id_exhaustion
    """)
  end

  defp schema, do: prefix() || "platform"
end
