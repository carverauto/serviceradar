defmodule ServiceRadar.Repo.Migrations.AddUiSlowQueryIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ocsf_devices_active_last_seen_uid
    ON platform.ocsf_devices (last_seen_time DESC, uid ASC)
    WHERE deleted_at IS NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_discovered_interfaces_device_if_index_time
    ON platform.discovered_interfaces (device_id, if_index, timestamp DESC)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.idx_discovered_interfaces_device_if_index_time")
    execute("DROP INDEX IF EXISTS platform.idx_ocsf_devices_active_last_seen_uid")
  end
end
