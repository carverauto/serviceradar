defmodule ServiceRadar.Repo.Migrations.IndexSourceIdentifierRetirement do
  @moduledoc """
  Indexes for source identifier retirement (change `add-source-id-succession`, design D1, D2
  and D5).

  * `ocsf_devices (source_retired_at)`, partial on live marked records: serves the grace pass,
    which reads records marked `source_retired` longer ago than the grace period, and the
    count of hidden records.
  * `device_identifier_archive (identifier_type, identifier_value, partition)`: the ingest
    guard and the duplicate pass now ask whether any record held a value of a source type in
    a scope, so the archive is read by value the way `device_identifiers` is.
  * `device_identifier_archive (device_id, identifier_type)`: the guard and the seed-adoption
    check read a record's archived source ids by device.

  Built `CONCURRENTLY` so that neither the device table nor the archive is locked against
  writes; that cannot run inside a transaction, hence the DDL transaction and migration lock
  are disabled.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS ocsf_devices_source_retired_at_idx
    ON platform.ocsf_devices (source_retired_at)
    WHERE source_retired_at IS NOT NULL AND deleted_at IS NULL
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS device_identifier_archive_type_value_partition_idx
    ON platform.device_identifier_archive (identifier_type, identifier_value, partition)
    """)

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS device_identifier_archive_device_type_idx
    ON platform.device_identifier_archive (device_id, identifier_type)
    """)
  end

  def down do
    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS platform.device_identifier_archive_device_type_idx"
    )

    execute(
      "DROP INDEX CONCURRENTLY IF EXISTS platform.device_identifier_archive_type_value_partition_idx"
    )

    execute("DROP INDEX CONCURRENTLY IF EXISTS platform.ocsf_devices_source_retired_at_idx")
  end
end
