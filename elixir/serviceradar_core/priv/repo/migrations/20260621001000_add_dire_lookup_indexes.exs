defmodule ServiceRadar.Repo.Migrations.AddDireLookupIndexes do
  @moduledoc false

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS device_alias_states_value_state_idx
    ON platform.device_alias_states (
      alias_type,
      alias_value,
      state,
      partition,
      sighting_count DESC,
      first_seen_at ASC
    )
    INCLUDE (device_id, last_seen_at)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS device_identifiers_device_type_idx
    ON platform.device_identifiers (device_id, identifier_type)
    INCLUDE (identifier_value, partition, confidence, last_seen)
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS platform.device_identifiers_device_type_idx")

    execute("DROP INDEX CONCURRENTLY IF EXISTS platform.device_alias_states_value_state_idx")
  end
end
