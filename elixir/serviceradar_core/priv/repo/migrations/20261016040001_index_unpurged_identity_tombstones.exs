defmodule ServiceRadar.Repo.Migrations.IndexUnpurgedIdentityTombstones do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS ocsf_devices_unpurged_identity_tombstones_idx
    ON platform.ocsf_devices (uid)
    WHERE deleted_at IS NOT NULL AND identity_purged_at IS NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS platform.ocsf_devices_unpurged_identity_tombstones_idx")
  end
end
