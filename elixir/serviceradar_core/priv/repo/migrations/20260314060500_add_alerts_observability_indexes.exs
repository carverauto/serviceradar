defmodule ServiceRadar.Repo.Migrations.AddAlertsObservabilityIndexes do
  use Ecto.Migration

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_alerts_triggered_at_desc
    ON platform.alerts (triggered_at DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_alerts_status_triggered_at_desc
    ON platform.alerts (status, triggered_at DESC)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.idx_alerts_status_triggered_at_desc")
    execute("DROP INDEX IF EXISTS platform.idx_alerts_triggered_at_desc")
  end
end
