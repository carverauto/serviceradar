ExUnit.start(exclude: [:pending_multitenancy_investigation])

{:ok, _} = Application.ensure_all_started(:serviceradar_web_ng)

# Use ServiceRadar.Repo from serviceradar_core directly for SQL adapter operations
repo = ServiceRadar.Repo

# Create OCSF-aligned device inventory table (OCSF v1.7.0 Device object)
_ =
  Ecto.Adapters.SQL.query!(
    repo,
    """
    CREATE TABLE IF NOT EXISTS ocsf_devices (
      uid text PRIMARY KEY
    )
    """,
    []
  )

_ =
  Enum.each(
    [
      # OCSF Core Identity
      {"type_id", "integer DEFAULT 0"},
      {"type", "text"},
      {"name", "text"},
      {"hostname", "text"},
      {"ip", "text"},
      {"mac", "text"},
      # OCSF Extended Identity
      {"uid_alt", "text"},
      {"vendor_name", "text"},
      {"model", "text"},
      {"domain", "text"},
      {"zone", "text"},
      {"subnet_uid", "text"},
      {"vlan_uid", "text"},
      {"region", "text"},
      # OCSF Temporal
      {"first_seen_time", "timestamptz"},
      {"last_seen_time", "timestamptz"},
      {"created_time", "timestamptz DEFAULT NOW()"},
      {"modified_time", "timestamptz DEFAULT NOW()"},
      # OCSF Risk and Compliance
      {"risk_level_id", "integer"},
      {"risk_level", "text"},
      {"risk_score", "integer"},
      {"is_managed", "boolean"},
      {"is_compliant", "boolean"},
      {"is_trusted", "boolean"},
      # OCSF Nested Objects (JSONB)
      {"os", "jsonb"},
      {"hw_info", "jsonb"},
      {"network_interfaces", "jsonb"},
      {"owner", "jsonb"},
      {"org", "jsonb"},
      {"groups", "jsonb"},
      {"agent_list", "jsonb"},
      # ServiceRadar-specific fields
      {"poller_id", "text"},
      {"agent_id", "text"},
      {"discovery_sources", "text[]"},
      {"is_available", "boolean"},
      {"metadata", "jsonb"}
    ],
    fn {col, type} ->
      Ecto.Adapters.SQL.query!(
        repo,
        "ALTER TABLE ocsf_devices ADD COLUMN IF NOT EXISTS #{col} #{type}",
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

Ecto.Adapters.SQL.Sandbox.mode(ServiceRadar.Repo, :manual)
