defmodule ServiceRadar.Repo.Migrations.EnsureLogsPlainTimestampIndexes do
  @moduledoc """
  Forward repair for the shared 20260927130000 ledger entry.

  `add_logs_plain_timestamp_indexes.exs` and the original `topology_world.exs`
  both shipped as migration version 20260927130000. The topology migration has
  since been re-versioned, but installs that already applied the topology
  migration under the old shared version recorded that ledger row without ever
  creating the logs timestamp indexes. This idempotent migration recreates those
  four indexes so the shared ledger entry cannot silently skip them.

  The definitions mirror `add_logs_plain_timestamp_indexes.exs`: one chunk per
  transaction on the TimescaleDB hypertable, outside Ecto's DDL transaction and
  migration lock. `down` is intentionally a no-op because the indexes may be
  owned by the original migration, and rolling back this repair must not drop
  indexes that migration legitimately created.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @table "platform.logs"

  def up do
    create_index_if_logs_table_exists("""
    CREATE INDEX IF NOT EXISTS idx_logs_severity_lower_timestamp
    ON platform.logs (lower(severity_text), "timestamp" DESC)
    WITH (timescaledb.transaction_per_chunk)
    """)

    create_index_if_logs_table_exists("""
    CREATE INDEX IF NOT EXISTS idx_logs_severity_number_timestamp
    ON platform.logs (severity_number, "timestamp" DESC)
    WITH (timescaledb.transaction_per_chunk)
    """)

    create_index_if_logs_table_exists("""
    CREATE INDEX IF NOT EXISTS idx_logs_source_timestamp
    ON platform.logs (source, "timestamp" DESC)
    WITH (timescaledb.transaction_per_chunk)
    """)

    create_index_if_logs_table_exists("""
    CREATE INDEX IF NOT EXISTS idx_logs_source_ip_timestamp
    ON platform.logs (source_ip, "timestamp" DESC)
    WITH (timescaledb.transaction_per_chunk)
    """)
  end

  def down do
    :ok
  end

  defp create_index_if_logs_table_exists(statement) do
    case repo().query!("SELECT to_regclass($1)", [@table]) do
      %{rows: [[nil]]} -> :ok
      %{rows: [[_]]} -> execute(statement)
    end
  end
end
