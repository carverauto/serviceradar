defmodule ServiceRadar.Repo.Migrations.AddLogsSource do
  @moduledoc """
  Adds a source column to logs for fast filtering (syslog, otel, snmp, etc).
  """
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE IF EXISTS #{prefix() || "platform"}.logs
      ADD COLUMN IF NOT EXISTS source TEXT
    """)

    execute("CREATE INDEX IF NOT EXISTS idx_logs_source ON #{prefix() || "platform"}.logs (source)")
  end

  def down do
    execute("DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_logs_source")

    execute("""
    ALTER TABLE IF EXISTS #{prefix() || "platform"}.logs
      DROP COLUMN IF EXISTS source
    """)
  end
end
