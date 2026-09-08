defmodule ServiceRadar.Repo.Migrations.DisableDefaultGeoipEnrichment do
  @moduledoc false
  use Ecto.Migration

  def up do
    alter table(:netflow_settings, prefix: "platform") do
      modify :geoip_enabled, :boolean, null: false, default: false
    end

    execute("""
    UPDATE platform.netflow_settings
    SET geoip_enabled = false
    WHERE geoip_enabled = true
      AND geolite_mmdb_last_success_at IS NULL
    """)
  end

  def down do
    alter table(:netflow_settings, prefix: "platform") do
      modify :geoip_enabled, :boolean, null: false, default: true
    end
  end
end
