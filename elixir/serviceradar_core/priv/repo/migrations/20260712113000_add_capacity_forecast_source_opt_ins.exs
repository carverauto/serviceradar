defmodule ServiceRadar.Repo.Migrations.AddCapacityForecastSourceOptIns do
  @moduledoc false
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE platform.capacity_forecast_configs
      ADD COLUMN default_source_opt_ins text[] NOT NULL DEFAULT '{}'::text[]
    """)
  end

  def down do
    alter table(:capacity_forecast_configs, prefix: "platform") do
      remove :default_source_opt_ins
    end
  end
end
