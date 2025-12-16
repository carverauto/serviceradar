ExUnit.start()

{:ok, _} = Application.ensure_all_started(:serviceradar_web_ng)

repo = ServiceRadarWebNG.Repo

_ =
  Ecto.Adapters.SQL.query!(
    repo,
    """
    CREATE TABLE IF NOT EXISTS unified_devices (
      device_id text PRIMARY KEY
    )
    """,
    []
  )

_ =
  Enum.each(
    [
      {"ip", "text"},
      {"poller_id", "text"},
      {"agent_id", "text"},
      {"hostname", "text"},
      {"mac", "text"},
      {"discovery_sources", "text[]"},
      {"is_available", "boolean"},
      {"first_seen", "timestamptz"},
      {"last_seen", "timestamptz"},
      {"metadata", "jsonb"},
      {"device_type", "text"},
      {"service_type", "text"},
      {"service_status", "text"},
      {"last_heartbeat", "timestamptz"},
      {"os_info", "text"},
      {"version_info", "text"},
      {"updated_at", "timestamptz"}
    ],
    fn {col, type} ->
      Ecto.Adapters.SQL.query!(
        repo,
        "ALTER TABLE unified_devices ADD COLUMN IF NOT EXISTS #{col} #{type}",
        []
      )
    end
  )

_ =
  Ecto.Adapters.SQL.query!(
    repo,
    """
    CREATE TABLE IF NOT EXISTS pollers (
      poller_id text PRIMARY KEY
    )
    """,
    []
  )

_ =
  Enum.each(
    [
      {"component_id", "text"},
      {"registration_source", "text"},
      {"status", "text"},
      {"spiffe_identity", "text"},
      {"first_registered", "timestamptz"},
      {"first_seen", "timestamptz"},
      {"last_seen", "timestamptz"},
      {"metadata", "jsonb"},
      {"created_by", "text"},
      {"is_healthy", "boolean"},
      {"agent_count", "integer"},
      {"checker_count", "integer"},
      {"updated_at", "timestamptz"}
    ],
    fn {col, type} ->
      Ecto.Adapters.SQL.query!(
        repo,
        "ALTER TABLE pollers ADD COLUMN IF NOT EXISTS #{col} #{type}",
        []
      )
    end
  )

Ecto.Adapters.SQL.Sandbox.mode(ServiceRadarWebNG.Repo, :manual)
