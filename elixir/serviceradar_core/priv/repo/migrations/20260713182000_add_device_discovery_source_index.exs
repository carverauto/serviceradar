defmodule ServiceRadar.Repo.Migrations.AddDeviceDiscoverySourceIndex do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS ocsf_devices_discovery_sources_gin_idx
      ON #{@prefix}.ocsf_devices USING gin (discovery_sources)
      WHERE deleted_at IS NULL
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{@prefix}.ocsf_devices_discovery_sources_gin_idx")
  end
end
