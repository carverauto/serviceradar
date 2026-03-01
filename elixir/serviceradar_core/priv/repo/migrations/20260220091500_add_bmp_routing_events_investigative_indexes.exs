defmodule ServiceRadar.Repo.Migrations.AddBmpRoutingEventsInvestigativeIndexes do
  @moduledoc """
  Adds query-focused indexes for BMP routing investigations.

  These indexes target common SRQL/operational filters used by the new
  `in:bmp_events` workflows (router_ip, peer_ip, prefix, severity, metadata).
  """
  use Ecto.Migration

  @table "bmp_routing_events"

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_bmp_routing_events_router_ip_time
      ON #{prefix() || "platform"}.#{@table} (router_ip, time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_bmp_routing_events_peer_ip_time
      ON #{prefix() || "platform"}.#{@table} (peer_ip, time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_bmp_routing_events_prefix_time
      ON #{prefix() || "platform"}.#{@table} (prefix, time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_bmp_routing_events_severity_time
      ON #{prefix() || "platform"}.#{@table} (severity_id, time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_bmp_routing_events_metadata_gin
      ON #{prefix() || "platform"}.#{@table} USING GIN (metadata)
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_bmp_routing_events_metadata_gin")
    execute("DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_bmp_routing_events_severity_time")
    execute("DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_bmp_routing_events_prefix_time")
    execute("DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_bmp_routing_events_peer_ip_time")
    execute("DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_bmp_routing_events_router_ip_time")
  end
end
