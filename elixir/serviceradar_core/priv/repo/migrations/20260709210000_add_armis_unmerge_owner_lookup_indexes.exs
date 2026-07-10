defmodule ServiceRadar.Repo.Migrations.AddArmisUnmergeOwnerLookupIndexes do
  @moduledoc """
  Indexed normalized-MAC ownership lookups used by the fail-closed Armis
  disposition while its short DML barrier is held.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS device_identifiers_mac_tokens_gin_idx
    ON platform.device_identifiers
    USING GIN ((
      regexp_split_to_array(
        upper(translate(identifier_value, ':-.', '')),
        '[,;[:space:]]+'
      )
    ))
    WHERE identifier_type = 'mac'
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS ocsf_devices_display_mac_tokens_gin_idx
    ON platform.ocsf_devices
    USING GIN ((
      regexp_split_to_array(
        upper(translate(mac, ':-.', '')),
        '[,;[:space:]]+'
      )
    ))
    WHERE mac IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS platform.ocsf_devices_display_mac_tokens_gin_idx")

    execute("DROP INDEX CONCURRENTLY IF EXISTS platform.device_identifiers_mac_tokens_gin_idx")
  end
end
