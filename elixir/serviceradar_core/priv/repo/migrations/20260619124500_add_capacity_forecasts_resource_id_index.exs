defmodule ServiceRadar.Repo.Migrations.AddCapacityForecastsResourceIdIndex do
  @moduledoc """
  Adds a narrow resource_id index for device-detail capacity lookups.
  """
  use Ecto.Migration

  # Timescale hypertables do not support CREATE INDEX CONCURRENTLY. Keep this
  # migration outside the transaction/lock path, but build the index normally.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_capacity_forecasts_resource_id
    ON #{schema()}.capacity_forecasts (resource_id)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{schema()}.idx_capacity_forecasts_resource_id")
  end

  defp schema, do: prefix() || "platform"
end
