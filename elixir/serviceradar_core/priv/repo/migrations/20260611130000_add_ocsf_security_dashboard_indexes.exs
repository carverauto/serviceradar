defmodule ServiceRadar.Repo.Migrations.AddOcsfSecurityDashboardIndexes do
  @moduledoc false
  use Ecto.Migration

  @schema "platform"
  @table "ocsf_events"

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_events_category_time
    ON #{schema()}.#{@table} (category_uid, time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_events_class_category_time
    ON #{schema()}.#{@table} (class_uid, category_uid, time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_events_log_provider_time
    ON #{schema()}.#{@table} (log_provider, time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_events_service_radar_source_time
    ON #{schema()}.#{@table} ((metadata #>> '{service_radar,source_type}'), time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_events_finding_uid_time
    ON #{schema()}.#{@table} ((metadata #>> '{finding_info,uid}'), time DESC)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{schema()}.idx_ocsf_events_finding_uid_time")
    execute("DROP INDEX IF EXISTS #{schema()}.idx_ocsf_events_service_radar_source_time")
    execute("DROP INDEX IF EXISTS #{schema()}.idx_ocsf_events_log_provider_time")
    execute("DROP INDEX IF EXISTS #{schema()}.idx_ocsf_events_class_category_time")
    execute("DROP INDEX IF EXISTS #{schema()}.idx_ocsf_events_category_time")
  end

  defp schema do
    prefix() || @schema
  end
end
