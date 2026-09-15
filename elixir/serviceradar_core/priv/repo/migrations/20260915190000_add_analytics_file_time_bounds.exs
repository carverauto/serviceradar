defmodule ServiceRadar.Repo.Migrations.AddAnalyticsFileTimeBounds do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:analytics_file_manifest, prefix: "platform") do
      # Old objects remain query-visible until their bounds are populated.
      add :min_timestamp, :timestamptz
      add :max_timestamp, :timestamptz
    end
  end
end
