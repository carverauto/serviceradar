defmodule ServiceRadar.Repo.Migrations.AddOcsfDevicesPartition do
  @moduledoc """
  Adds `ocsf_devices.partition` so the same IP can exist as two live devices.

  Isolation sweeps prove a host is unreachable from a disallowed subnet; a
  monitoring sweep from an allowed subnet needs its own availability bit. Both
  views share an address, so uniqueness is (partition, ip) rather than ip
  alone. Existing rows land in `default`, which keeps current identity lookups
  and isolation scans on the same copy they already update.
  """

  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE platform.ocsf_devices
      ADD COLUMN IF NOT EXISTS partition text NOT NULL DEFAULT 'default';
    """)

    execute("""
    DROP INDEX IF EXISTS platform.ocsf_devices_unique_active_ip_idx;
    """)

    execute("""
    CREATE UNIQUE INDEX ocsf_devices_unique_active_ip_idx
      ON platform.ocsf_devices (partition, ip)
      WHERE deleted_at IS NULL AND ip IS NOT NULL AND ip <> '';
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS ocsf_devices_partition_idx
      ON platform.ocsf_devices (partition)
      WHERE deleted_at IS NULL;
    """)
  end

  def down do
    execute("""
    DROP INDEX IF EXISTS platform.ocsf_devices_partition_idx;
    """)

    execute("""
    DROP INDEX IF EXISTS platform.ocsf_devices_unique_active_ip_idx;
    """)

    # Recreating the IP-only unique index fails if two live rows share an
    # address in different partitions. Collapse those copies first.
    execute("""
    CREATE UNIQUE INDEX ocsf_devices_unique_active_ip_idx
      ON platform.ocsf_devices (ip)
      WHERE deleted_at IS NULL AND ip IS NOT NULL AND ip <> '';
    """)

    execute("""
    ALTER TABLE platform.ocsf_devices DROP COLUMN IF EXISTS partition;
    """)
  end
end
