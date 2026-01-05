defmodule ServiceRadar.Edge.AgentConfigGenerator do
  @moduledoc """
  Generates agent configuration from tenant data stored in CNPG.

  This module is responsible for:
  1. Loading service checks assigned to a specific agent
  2. Converting them to proto-compatible format (AgentCheckConfig)
  3. Computing a version hash for cache validation
  4. Supporting `not_modified` responses when config hasn't changed

  ## Config Versioning

  The config version is a SHA256 hash of the serialized configuration.
  This allows agents to cache their config and only fetch updates when
  the hash changes.

  ## Usage

      # Generate full config for an agent
      {:ok, config} = AgentConfigGenerator.generate_config(agent_id, tenant_id)

      # Check if config has changed (returns :not_modified or {:ok, config})
      result = AgentConfigGenerator.get_config_if_changed(agent_id, tenant_id, current_version)
  """

  require Logger
  require Ash.Query

  alias ServiceRadar.Monitoring.ServiceCheck

  # Default intervals
  @default_heartbeat_interval_sec 30
  @default_config_poll_interval_sec 300

  @type check_config :: %{
          check_id: String.t(),
          check_type: String.t(),
          name: String.t(),
          enabled: boolean(),
          interval_sec: integer(),
          timeout_sec: integer(),
          target: String.t(),
          port: integer() | nil,
          path: String.t() | nil,
          method: String.t() | nil,
          settings: map()
        }

  @type agent_config :: %{
          config_version: String.t(),
          config_timestamp: integer(),
          heartbeat_interval_sec: integer(),
          config_poll_interval_sec: integer(),
          checks: [check_config()]
        }

  @doc """
  Generates the full configuration for an agent.

  Loads all enabled service checks assigned to this agent from the database
  and returns them in a format suitable for the AgentConfigResponse proto.

  ## Parameters

    - `agent_id` - The agent's unique identifier (uid)
    - `tenant_id` - The tenant's UUID (for multi-tenant isolation)

  ## Returns

    - `{:ok, config}` - The generated config with version hash
    - `{:error, reason}` - If config generation fails
  """
  @spec generate_config(String.t(), String.t()) :: {:ok, agent_config()} | {:error, term()}
  def generate_config(agent_id, tenant_id) do
    case load_agent_checks(agent_id, tenant_id) do
      {:ok, checks} ->
        config = build_config(checks)
        {:ok, config}

      {:error, reason} ->
        Logger.error("Failed to load checks for agent #{agent_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Gets the agent config if it has changed from the provided version.

  This is the main entry point for config requests. It:
  1. Generates the current config
  2. Computes the version hash
  3. Returns `:not_modified` if the hash matches `current_version`
  4. Returns `{:ok, config}` if the config has changed

  ## Parameters

    - `agent_id` - The agent's unique identifier
    - `tenant_id` - The tenant's UUID
    - `current_version` - The agent's current config version hash (or empty string)

  ## Returns

    - `:not_modified` - If config hasn't changed
    - `{:ok, config}` - If config has changed (includes new version hash)
    - `{:error, reason}` - If config generation fails
  """
  @spec get_config_if_changed(String.t(), String.t(), String.t()) ::
          :not_modified | {:ok, agent_config()} | {:error, term()}
  def get_config_if_changed(agent_id, tenant_id, current_version) do
    case generate_config(agent_id, tenant_id) do
      {:ok, config} ->
        if config.config_version == current_version do
          Logger.debug("Config not modified for agent #{agent_id}, version: #{current_version}")
          :not_modified
        else
          Logger.info(
            "Config changed for agent #{agent_id}: #{current_version} -> #{config.config_version}"
          )

          {:ok, config}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Converts our internal config format to proto-compatible structs.

  This creates `Monitoring.AgentCheckConfig` structs that can be
  directly used in `Monitoring.AgentConfigResponse`.
  """
  @spec to_proto_checks([check_config()]) :: [Monitoring.AgentCheckConfig.t()]
  def to_proto_checks(checks) do
    Enum.map(checks, fn check ->
      %Monitoring.AgentCheckConfig{
        check_id: check.check_id,
        check_type: check.check_type,
        name: check.name,
        enabled: check.enabled,
        interval_sec: check.interval_sec,
        timeout_sec: check.timeout_sec,
        target: check.target || "",
        port: check.port || 0,
        path: check.path || "",
        method: check.method || "",
        settings: check.settings || %{}
      }
    end)
  end

  # Load service checks assigned to this agent from the database
  defp load_agent_checks(agent_id, tenant_id) do
    try do
      actor = %{
        id: "system",
        email: "gateway@serviceradar",
        role: :admin,
        tenant_id: tenant_id
      }

      # Query for enabled checks assigned to this agent
      checks =
        ServiceCheck
        |> Ash.Query.for_read(:by_agent, %{agent_uid: agent_id},
          actor: actor,
          tenant: tenant_id
        )
        |> Ash.Query.filter(enabled == true)
        |> Ash.read!()

      Logger.debug("Loaded #{length(checks)} checks for agent #{agent_id}")
      {:ok, checks}
    rescue
      e ->
        Logger.error("Error loading checks: #{inspect(e)}")
        {:error, {:database_error, e}}
    end
  end

  # Build the full config structure from database checks
  defp build_config(checks) do
    check_configs = Enum.map(checks, &convert_check_to_config/1)

    # Compute version hash from the check configs
    config_version = compute_version_hash(check_configs)

    %{
      config_version: config_version,
      config_timestamp: System.os_time(:second),
      heartbeat_interval_sec: @default_heartbeat_interval_sec,
      config_poll_interval_sec: @default_config_poll_interval_sec,
      checks: check_configs
    }
  end

  # Convert a ServiceCheck record to our check config format
  defp convert_check_to_config(%ServiceCheck{} = check) do
    # Map Ash atom check_type to string
    check_type = atom_to_check_type(check.check_type)

    # Extract settings from the config map
    raw_settings = Map.merge(check.config || %{}, check.metadata || %{})
    settings = stringify_keys(raw_settings)

    %{
      check_id: to_string(check.id),
      check_type: check_type,
      name: check.name,
      enabled: check.enabled,
      interval_sec: check.interval_seconds || 60,
      timeout_sec: check.timeout_seconds || 10,
      target: check.target,
      port: check.port,
      path: Map.get(settings, "path"),
      method: Map.get(settings, "method"),
      settings: settings
    }
  end

  # Convert Ash atom types to proto string types
  defp atom_to_check_type(:ping), do: "icmp"
  defp atom_to_check_type(:http), do: "http"
  defp atom_to_check_type(:tcp), do: "tcp"
  defp atom_to_check_type(:snmp), do: "snmp"
  defp atom_to_check_type(:grpc), do: "grpc"
  defp atom_to_check_type(:dns), do: "dns"
  defp atom_to_check_type(:custom), do: "custom"
  defp atom_to_check_type(other) when is_atom(other), do: Atom.to_string(other)
  defp atom_to_check_type(other) when is_binary(other), do: other

  # Ensure all map keys are strings for proto compatibility
  # Preserves original value types (numbers, booleans) instead of converting to strings
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: to_string(k)
      {key, stringify_value(v)}
    end)
  end

  defp stringify_keys(other), do: other

  defp stringify_value(v) when is_map(v), do: stringify_keys(v)
  defp stringify_value(v) when is_list(v), do: Enum.map(v, &stringify_value/1)
  defp stringify_value(v), do: v

  # Compute SHA256 hash of the config for versioning
  defp compute_version_hash(check_configs) do
    # Sort checks by ID for deterministic ordering
    sorted_checks = Enum.sort_by(check_configs, & &1.check_id)

    # Serialize deterministically for hashing (works for any Erlang term).
    bin = :erlang.term_to_binary(sorted_checks)

    # Compute SHA256 hash
    hash = :crypto.hash(:sha256, bin)

    # Return as hex string with "v" prefix
    "v" <> Base.encode16(hash, case: :lower)
  end
end
