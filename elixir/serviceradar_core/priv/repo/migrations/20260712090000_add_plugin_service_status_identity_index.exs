defmodule ServiceRadar.Repo.Migrations.AddPluginServiceStatusIdentityIndex do
  @moduledoc """
  Adds the partial identity/time index used by paginated plugin-state repair.

  The repair selects a bounded keyset page of logical plugin identities, then
  ranks history only for that page. TimescaleDB builds the index one chunk at a
  time so upgrades do not hold a hypertable-wide lock for the full build.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_service_status_plugin_identity_time
    ON platform.service_status (
      agent_id,
      (COALESCE(partition, 'default')),
      service_name,
      timestamp DESC
    )
    WITH (timescaledb.transaction_per_chunk)
    WHERE service_type = 'plugin' AND agent_id IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.idx_service_status_plugin_identity_time")
  end
end
