defmodule ServiceRadar.Repo.Migrations.AddNetflowLocalCidrLocationAnchors do
  @moduledoc false
  use Ecto.Migration

  def change do
    alter table(:netflow_local_cidrs, prefix: "platform") do
      add :location_label, :text
      add :latitude, :float
      add :longitude, :float
    end

    create_if_not_exists index(:netflow_local_cidrs, [:enabled, :latitude, :longitude],
                           prefix: "platform",
                           name: "netflow_local_cidrs_location_enabled_idx"
                         )

    create constraint(:netflow_local_cidrs, :netflow_local_cidrs_latitude_range,
             prefix: "platform",
             check: "latitude IS NULL OR (latitude >= -90 AND latitude <= 90)"
           )

    create constraint(:netflow_local_cidrs, :netflow_local_cidrs_longitude_range,
             prefix: "platform",
             check: "longitude IS NULL OR (longitude >= -180 AND longitude <= 180)"
           )
  end
end
