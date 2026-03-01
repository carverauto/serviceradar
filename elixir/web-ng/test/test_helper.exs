ExUnit.start()

# Test suite should exercise app behavior, not startup migration gating.
if System.get_env("SERVICERADAR_MIGRATIONS_GATE") in [nil, ""] do
  System.put_env("SERVICERADAR_MIGRATIONS_GATE", "false")
end

{:ok, _} = Application.ensure_all_started(:serviceradar_web_ng)

# Use ServiceRadar.Repo from serviceradar_core directly for SQL adapter operations
repo = ServiceRadar.Repo

if System.get_env("CI") not in ["1", "true", "TRUE"] do
  case Ecto.Adapters.SQL.query(repo, "SELECT 1", []) do
    {:ok, _} ->
      :ok

    {:error, reason} ->
      IO.warn("Skipping web-ng tests; database unavailable: #{inspect(reason)}")
      System.halt(0)
  end
end

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
      {"gateway_id", "text"},
      {"agent_id", "text"},
      {"management_device_id", "text"},
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
    CREATE TABLE IF NOT EXISTS gateways (
      gateway_id text PRIMARY KEY
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
      {"updated_at", "timestamptz"},
      {"partition_id", "uuid"}
    ],
    fn {col, type} ->
      Ecto.Adapters.SQL.query!(
        repo,
        "ALTER TABLE gateways ADD COLUMN IF NOT EXISTS #{col} #{type}",
        []
      )
    end
  )

# Create logs table for SRQL UUID parameter testing
_ =
  Ecto.Adapters.SQL.query!(
    repo,
    """
    CREATE TABLE IF NOT EXISTS logs (
      timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      observed_timestamp TIMESTAMPTZ,
      id UUID NOT NULL DEFAULT gen_random_uuid(),
      trace_id TEXT,
      span_id TEXT,
      trace_flags INT,
      severity_text TEXT,
      severity_number INT,
      body TEXT,
      event_name TEXT,
      service_name TEXT,
      service_version TEXT,
      service_instance TEXT,
      scope_name TEXT,
      scope_version TEXT,
      scope_attributes TEXT,
      attributes TEXT,
      resource_attributes TEXT,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (timestamp, id)
    )
    """,
    []
  )

# Ensure RBAC system role profiles exist for tests that depend on them.
# In test env we keep seeders disabled to avoid async sandbox ownership issues,
# so we seed once here during boot.
try do
  ServiceRadar.Identity.RoleProfileSeeder.seed()
rescue
  e ->
    IO.warn("Failed to seed role profiles: #{Exception.message(e)}")
end

Ecto.Adapters.SQL.Sandbox.mode(ServiceRadar.Repo, :manual)
