defmodule ServiceRadar.Repo.Migrations.AddHpnaDeviceSearchIndexes do
  @moduledoc false
  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS ocsf_devices_discovery_sources_gin_idx
      ON #{@prefix}.ocsf_devices USING gin (discovery_sources)
      WHERE deleted_at IS NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS ocsf_devices_hpna_instance_idx
      ON #{@prefix}.ocsf_devices ((metadata ->> 'hpna_instance_id'))
      WHERE deleted_at IS NULL AND 'hpna' = ANY(discovery_sources)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS ocsf_devices_hpna_instance_partition_idx
      ON #{@prefix}.ocsf_devices (
        (metadata ->> 'hpna_instance_id'),
        (metadata ->> 'hpna_partition')
      )
      WHERE deleted_at IS NULL AND 'hpna' = ANY(discovery_sources)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS ocsf_devices_hpna_instance_status_idx
      ON #{@prefix}.ocsf_devices (
        (metadata ->> 'hpna_instance_id'),
        (metadata ->> 'hpna_management_status')
      )
      WHERE deleted_at IS NULL AND 'hpna' = ANY(discovery_sources)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS ocsf_devices_hpna_device_id_idx
      ON #{@prefix}.ocsf_devices ((metadata ->> 'hpna_device_id'))
      WHERE deleted_at IS NULL AND 'hpna' = ANY(discovery_sources)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{@prefix}.ocsf_devices_hpna_device_id_idx")
    execute("DROP INDEX IF EXISTS #{@prefix}.ocsf_devices_hpna_instance_status_idx")
    execute("DROP INDEX IF EXISTS #{@prefix}.ocsf_devices_hpna_instance_partition_idx")
    execute("DROP INDEX IF EXISTS #{@prefix}.ocsf_devices_hpna_instance_idx")
    execute("DROP INDEX IF EXISTS #{@prefix}.ocsf_devices_discovery_sources_gin_idx")
  end
end
