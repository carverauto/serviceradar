defmodule ServiceRadar.Repo.Migrations.IndexSecurityEventBrowsing do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS security_events_browse_index
      ON platform.security_events (occurred_at DESC, id DESC)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS platform.security_events_browse_index")
  end
end
