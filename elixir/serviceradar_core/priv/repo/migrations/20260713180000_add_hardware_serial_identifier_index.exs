defmodule ServiceRadar.Repo.Migrations.AddHardwareSerialIdentifierIndex do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS device_identifiers_hardware_serial_lookup_idx
      ON platform.device_identifiers (identifier_value, partition, device_id)
      WHERE identifier_type = 'hardware_serial'
    """)
  end

  def down do
    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS platform.device_identifiers_hardware_serial_lookup_idx
    """)
  end
end
