defmodule ServiceRadar.Repo.Migrations.AddLogsIdLookupIndex do
  use Ecto.Migration

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_logs_id
    ON platform.logs (id)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.idx_logs_id")
  end
end
