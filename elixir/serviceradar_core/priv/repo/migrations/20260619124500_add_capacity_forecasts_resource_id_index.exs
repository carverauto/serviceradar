defmodule ServiceRadar.Repo.Migrations.AddCapacityForecastsResourceIdIndex do
  @moduledoc """
  Adds a narrow resource_id index for device-detail capacity lookups.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_capacity_forecasts_resource_id
    ON #{schema()}.capacity_forecasts (resource_id)
    """)
  end

  def down do
    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS #{schema()}.idx_capacity_forecasts_resource_id
    """)
  end

  defp schema, do: prefix() || "platform"
end
