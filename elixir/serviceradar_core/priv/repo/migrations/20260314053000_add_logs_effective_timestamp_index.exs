defmodule ServiceRadar.Repo.Migrations.AddLogsEffectiveTimestampIndex do
  use Ecto.Migration

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_logs_effective_timestamp
    ON platform.logs ((COALESCE(observed_timestamp, timestamp)) DESC)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.idx_logs_effective_timestamp")
  end
end
