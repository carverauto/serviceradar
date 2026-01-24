defmodule ServiceRadar.Edge.AgentConfigGenerator do
  @moduledoc """
  Generates agent configuration from database.

  This module is responsible for:
  1. Loading service checks assigned to a specific agent
  2. Converting them to proto-compatible format (AgentCheckConfig)
  3. Computing a version hash for cache validation
  4. Supporting `not_modified` responses when config hasn't changed

  ## Schema Isolation

  The database connection's search_path (set by CNPG credentials) determines
  the schema for this deployment.

  ## Config Versioning

  The config version is a SHA256 hash of the serialized configuration.
  This allows agents to cache their config and only fetch updates when
  the hash changes.

  ## Usage

      # Generate full config for an agent
      {:ok, config} = AgentConfigGenerator.generate_config(agent_id)

      # Check if config has changed (returns :not_modified or {:ok, config})
      result = AgentConfigGenerator.get_config_if_changed(agent_id, current_version)
  """

  require Logger
  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.DuskCompiler
  alias ServiceRadar.AgentConfig.Compilers.SNMPCompiler
  alias ServiceRadar.AgentConfig.Compilers.SysmonCompiler
  alias ServiceRadar.AgentConfig.ConfigServer
  alias ServiceRadar.AgentRegistry
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Integrations.SyncConfigGenerator
  alias ServiceRadar.Monitoring.ServiceCheck
  alias ServiceRadar.Plugins.{PluginAssignment, PluginPackage}

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
          checks: [check_config()],
          plugins: [plugin_assignment_config()],
          plugin_engine_limits: plugin_engine_limits_config()
        }

  @type plugin_engine_limits_config :: %{
          max_memory_mb: integer() | nil,
          max_cpu_ms: integer() | nil,
          max_concurrent: integer() | nil,
          max_open_connections: integer() | nil
        }

  @type plugin_assignment_config :: %{
          assignment_id: String.t(),
          plugin_id: String.t(),
          package_id: String.t(),
          version: String.t(),
          name: String.t(),
          entrypoint: String.t(),
          runtime: String.t() | nil,
          outputs: String.t(),
          capabilities: [String.t()],
          params: map(),
          permissions: map(),
          resources: map(),
          enabled: boolean(),
          interval_sec: integer(),
          timeout_sec: integer(),
          wasm_object_key: String.t() | nil,
          content_hash: String.t() | nil,
          source_type: String.t() | nil,
          source_repo_url: String.t() | nil,
          source_commit: String.t() | nil,
          download_url: String.t() | nil
        }

  @doc """
  Generates the full configuration for an agent.

  Loads all enabled service checks assigned to this agent from the database
  and returns them in a format suitable for the AgentConfigResponse proto.

  The schema is determined by the DB connection's search_path.

  ## Parameters

    - `agent_id` - The agent's unique identifier (uid)

  ## Returns

    - `{:ok, config}` - The generated config with version hash
    - `{:error, reason}` - If config generation fails
  """
  @spec generate_config(String.t()) :: {:ok, agent_config()} | {:error, term()}
  def generate_config(agent_id) do
    case load_agent_checks(agent_id) do
      {:ok, checks} ->
        sync_payload = load_sync_payload(agent_id)
        sweep_config = load_sweep_config(agent_id)
        mapper_config = load_mapper_config(agent_id)
        sysmon_config = load_sysmon_config(agent_id)
        snmp_config = load_snmp_config(agent_id)
        dusk_config = load_dusk_config(agent_id)
        plugin_assignments = load_plugin_assignments(agent_id)
        plugin_engine_limits = load_plugin_engine_limits(agent_id)
        plugin_config = %{
          assignments: plugin_assignments,
          engine_limits: plugin_engine_limits
        }

        config =
          build_config(
            checks,
            sync_payload,
            sweep_config,
            mapper_config,
            sysmon_config,
            snmp_config,
            dusk_config,
            plugin_config
          )

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

  The schema is determined by the DB connection's search_path.

  ## Parameters

    - `agent_id` - The agent's unique identifier
    - `current_version` - The agent's current config version hash (or empty string)

  ## Returns

    - `:not_modified` - If config hasn't changed
    - `{:ok, config}` - If config has changed (includes new version hash)
    - `{:error, reason}` - If config generation fails
  """
  @spec get_config_if_changed(String.t(), String.t()) ::
          :not_modified | {:ok, agent_config()} | {:error, term()}
  def get_config_if_changed(agent_id, current_version) do
    case generate_config(agent_id) do
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
  defp load_agent_checks(agent_id) do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:agent_config_generator)

    # Query for enabled checks assigned to this agent
    checks =
      ServiceCheck
      |> Ash.Query.for_read(:by_agent, %{agent_uid: agent_id}, actor: actor)
      |> Ash.Query.filter(enabled == true)
      |> Ash.read!()

    Logger.debug("Loaded #{length(checks)} checks for agent #{agent_id}")
    {:ok, checks}
  rescue
    e ->
      Logger.error("Error loading checks: #{inspect(e)}")
      {:error, {:database_error, e}}
  end

  defp load_plugin_assignments(agent_id) do
    actor = SystemActor.system(:agent_config_generator)

    assignments =
      PluginAssignment
      |> Ash.Query.for_read(:by_agent, %{agent_uid: agent_id}, actor: actor)
      |> Ash.Query.load(:plugin_package)
      |> Ash.read!()

    assignments
    |> Enum.filter(&has_approved_package?/1)
    |> Enum.map(&build_plugin_assignment_config/1)
  rescue
    e ->
      Logger.warning("Error loading plugin assignments: #{inspect(e)}")
      []
  end

  defp has_approved_package?(%PluginAssignment{
         plugin_package: %PluginPackage{status: :approved}
       }),
       do: true

  defp has_approved_package?(_), do: false

  defp load_plugin_engine_limits(agent_id) do
    actor = SystemActor.system(:plugin_engine_limits)

    case Agent.get_by_uid(agent_id, actor: actor) do
      {:ok, agent} ->
        %{
          max_memory_mb: agent.plugin_engine_max_memory_mb,
          max_cpu_ms: agent.plugin_engine_max_cpu_ms,
          max_concurrent: agent.plugin_engine_max_concurrent,
          max_open_connections: agent.plugin_engine_max_open_connections
        }

      {:error, _} ->
        %{
          max_memory_mb: nil,
          max_cpu_ms: nil,
          max_concurrent: nil,
          max_open_connections: nil
        }
    end
  end

  defp build_plugin_assignment_config(%PluginAssignment{} = assignment) do
    package = assignment.plugin_package
    manifest = normalize_map(package.manifest)

    %{
      assignment_id: to_string(assignment.id),
      plugin_id: package.plugin_id,
      package_id: package.id,
      version: package.version,
      name: package.name,
      entrypoint: package.entrypoint,
      runtime: package.runtime,
      outputs: package.outputs,
      capabilities: effective_capabilities(package, manifest),
      params: normalize_map(assignment.params),
      permissions: effective_permissions(assignment, package, manifest),
      resources: effective_resources(assignment, package, manifest),
      enabled: assignment.enabled,
      interval_sec: assignment.interval_seconds || 60,
      timeout_sec: assignment.timeout_seconds || 10,
      wasm_object_key: package.wasm_object_key,
      content_hash: package.content_hash,
      source_type: normalize_source_type(package.source_type),
      download_url: nil
    }
  end

  defp effective_capabilities(%PluginPackage{} = package, manifest) do
    approved = package.approved_capabilities || []

    if approved != [] do
      approved
    else
      Map.get(manifest, "capabilities") || Map.get(manifest, :capabilities) || []
    end
  end

  defp effective_permissions(
         %PluginAssignment{} = assignment,
         %PluginPackage{} = package,
         manifest
       ) do
    cond do
      map_present?(assignment.permissions_override) ->
        assignment.permissions_override

      map_present?(package.approved_permissions) ->
        package.approved_permissions

      true ->
        Map.get(manifest, "permissions") || Map.get(manifest, :permissions) || %{}
    end
    |> normalize_map()
  end

  defp effective_resources(%PluginAssignment{} = assignment, %PluginPackage{} = package, manifest) do
    cond do
      map_present?(assignment.resources_override) ->
        assignment.resources_override

      map_present?(package.approved_resources) ->
        package.approved_resources

      true ->
        Map.get(manifest, "resources") || Map.get(manifest, :resources) || %{}
    end
    |> normalize_map()
  end

  defp map_present?(map) when is_map(map), do: map_size(map) > 0
  defp map_present?(_), do: false

  defp normalize_map(nil), do: %{}
  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_), do: %{}

  defp normalize_source_type(nil), do: nil
  defp normalize_source_type(source) when is_atom(source), do: Atom.to_string(source)
  defp normalize_source_type(source) when is_binary(source), do: source
  defp normalize_source_type(_), do: nil

  defp encode_json(map) when is_map(map) do
    if map_present?(map) do
      Jason.encode!(map)
    else
      ""
    end
  end

  defp encode_json(_), do: ""

  # Build the full config structure from database checks
  defp build_config(
         checks,
         sync_payload,
         sweep_config,
         mapper_config,
         sysmon_config,
         snmp_config,
         dusk_config,
         plugin_config
       ) do
    check_configs = Enum.map(checks, &convert_check_to_config/1)
    plugin_assignments = Map.get(plugin_config, :assignments, [])
    plugin_engine_limits = Map.get(plugin_config, :engine_limits, %{})

    # Merge sweep config into the payload
    full_payload =
      sync_payload
      |> Map.put("sweep", sweep_config)
      |> Map.put("mapper", mapper_config)

    # Compute version hash from checks, sync payload, sweep config, sysmon config, and dusk config
    config_version =
      compute_version_hash(
        check_configs,
        full_payload,
        sysmon_config,
        snmp_config,
        dusk_config,
        plugin_assignments,
        plugin_engine_limits
      )

    config_json = Jason.encode!(full_payload)

    %{
      config_version: config_version,
      config_timestamp: System.os_time(:second),
      heartbeat_interval_sec: @default_heartbeat_interval_sec,
      config_poll_interval_sec: @default_config_poll_interval_sec,
      checks: check_configs,
      plugins: plugin_assignments,
      plugin_engine_limits: plugin_engine_limits,
      config_json: config_json,
      sysmon_config: build_sysmon_proto_config(sysmon_config),
      snmp_config: build_snmp_proto_config(snmp_config),
      dusk_config: build_dusk_proto_config(dusk_config)
    }
  end

  # Convert a ServiceCheck record to our check config format
  defp convert_check_to_config(%ServiceCheck{} = check) do
    # Map Ash atom check_type to string
    check_type = atom_to_check_type(check.check_type)

    # Extract settings from the config map
    raw_settings = Map.merge(check.config || %{}, check.metadata || %{})

    settings =
      raw_settings
      |> stringify_keys()
      |> maybe_put_device_uid(check.device_uid)

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

  defp maybe_put_device_uid(settings, device_uid)
       when is_map(settings) and is_binary(device_uid) and device_uid != "" do
    Map.put(settings, "device_uid", device_uid)
  end

  defp maybe_put_device_uid(settings, _device_uid), do: settings

  # Compute SHA256 hash of the config for versioning
  defp compute_version_hash(
         check_configs,
         sync_payload,
         sysmon_config,
         snmp_config,
         dusk_config,
         plugin_assignments,
         plugin_engine_limits
       ) do
    # Sort checks by ID for deterministic ordering
    sorted_checks = Enum.sort_by(check_configs, & &1.check_id)
    sorted_plugins = Enum.sort_by(plugin_assignments, & &1.assignment_id)

    # Serialize deterministically for hashing (works for any Erlang term).
    bin =
      :erlang.term_to_binary(%{
        checks: sorted_checks,
        sync: sync_payload,
        sysmon: sysmon_config,
        snmp: snmp_config,
        dusk: dusk_config,
        plugins: sorted_plugins,
        plugin_engine_limits: plugin_engine_limits
      })

    # Compute SHA256 hash
    hash = :crypto.hash(:sha256, bin)

    # Return as hex string with "v" prefix
    "v" <> Base.encode16(hash, case: :lower)
  end

  @doc """
  Converts plugin assignments to proto-compatible structs.
  """
  @spec to_proto_plugin_config([plugin_assignment_config()], plugin_engine_limits_config()) ::
          Monitoring.PluginConfig.t()
  def to_proto_plugin_config(plugin_assignments, engine_limits \\ %{}) do
    %Monitoring.PluginConfig{
      assignments: Enum.map(plugin_assignments, &to_proto_plugin_assignment/1),
      engine_limits: to_proto_plugin_engine_limits(engine_limits)
    }
  end

  defp to_proto_plugin_engine_limits(engine_limits) do
    %Monitoring.PluginEngineLimits{
      max_memory_mb: normalize_limit(engine_limits[:max_memory_mb]),
      max_cpu_ms: normalize_limit(engine_limits[:max_cpu_ms]),
      max_concurrent: normalize_limit(engine_limits[:max_concurrent]),
      max_open_connections: normalize_limit(engine_limits[:max_open_connections])
    }
  end

  defp normalize_limit(nil), do: 0
  defp normalize_limit(value) when is_integer(value) and value > 0, do: value
  defp normalize_limit(_), do: 0

  defp to_proto_plugin_assignment(assignment) do
    %Monitoring.PluginAssignmentConfig{
      assignment_id: assignment.assignment_id,
      plugin_id: assignment.plugin_id,
      package_id: assignment.package_id,
      version: assignment.version,
      name: assignment.name,
      entrypoint: assignment.entrypoint,
      runtime: assignment.runtime || "",
      outputs: assignment.outputs,
      capabilities: assignment.capabilities || [],
      params_json: encode_json(assignment.params),
      permissions_json: encode_json(assignment.permissions),
      resources_json: encode_json(assignment.resources),
      enabled: assignment.enabled,
      interval_sec: assignment.interval_sec,
      timeout_sec: assignment.timeout_sec,
      wasm_object_key: assignment.wasm_object_key || "",
      content_hash: assignment.content_hash || "",
      source_type: assignment.source_type || "",
      source_repo_url: Map.get(assignment, :source_repo_url, ""),
      source_commit: Map.get(assignment, :source_commit, ""),
      download_url: assignment.download_url || ""
    }
  end

  defp load_sync_payload(agent_id) do
    case SyncConfigGenerator.build_payload(agent_id) do
      {:ok, payload} ->
        payload

      {:error, reason} ->
        Logger.warning(
          "Failed to load integration config for agent #{agent_id}: #{inspect(reason)}"
        )

        %{"agent_id" => agent_id, "sources" => %{}}
    end
  end

  # Load sweep configuration from the AgentConfig system
  # This uses the ConfigServer which compiles sweep configs from SweepGroup/SweepProfile resources
  defp load_sweep_config(agent_id) do
    # Resolve partition from agent registry, fall back to "default"
    partition = get_agent_partition(agent_id)

    Logger.debug(
      "AgentConfigGenerator: loading sweep config for agent_id=#{inspect(agent_id)}, partition=#{inspect(partition)}"
    )

    case ConfigServer.get_config(:sweep, partition, agent_id) do
      {:ok, entry} ->
        # Return the compiled config from the cache entry
        Logger.debug(
          "AgentConfigGenerator: got sweep config with #{length(entry.config["groups"] || [])} groups, hash=#{entry.hash}"
        )

        entry.config

      {:error, :no_config_found} ->
        # No sweep config defined for this agent - return empty config
        Logger.debug(
          "AgentConfigGenerator: no sweep config found for agent #{agent_id} in partition #{partition}"
        )

        %{}

      {:error, reason} ->
        Logger.warning(
          "AgentConfigGenerator: failed to load sweep config for agent #{agent_id}: #{inspect(reason)}"
        )

        %{}
    end
  end

  # Load mapper discovery configuration from the AgentConfig system
  defp load_mapper_config(agent_id) do
    partition = get_agent_partition(agent_id)
    actor = SystemActor.system(:mapper_config_loader)
    device_uid = resolve_agent_device_uid(agent_id, actor)

    Logger.debug(
      "AgentConfigGenerator: loading mapper config for agent_id=#{inspect(agent_id)}, partition=#{inspect(partition)}"
    )

    case ConfigServer.get_config(:mapper, partition, agent_id,
           actor: actor,
           device_uid: device_uid
         ) do
      {:ok, entry} ->
        entry.config

      {:error, :no_config_found} ->
        Logger.debug(
          "AgentConfigGenerator: no mapper config found for agent #{agent_id} in partition #{partition}"
        )

        %{}

      {:error, reason} ->
        Logger.warning(
          "AgentConfigGenerator: failed to load mapper config for agent #{agent_id}: #{inspect(reason)}"
        )

        %{}
    end
  end

  # Resolve the partition for an agent from the registry
  # Falls back to "default" if agent is not registered or has no partition
  defp get_agent_partition(agent_id) do
    case AgentRegistry.lookup(agent_id) do
      [{_pid, metadata}] ->
        partition = metadata[:partition_id] || "default"

        Logger.debug(
          "AgentConfigGenerator: resolved partition=#{partition} for agent #{agent_id}"
        )

        partition

      [] ->
        Logger.debug(
          "AgentConfigGenerator: agent #{agent_id} not found in registry, using partition=default"
        )

        "default"

      other ->
        Logger.warning(
          "AgentConfigGenerator: unexpected registry lookup result for #{agent_id}: #{inspect(other)}"
        )

        "default"
    end
  end

  # Load sysmon configuration from the AgentConfig system
  # This uses the ConfigServer which compiles sysmon configs from SysmonProfile resources
  defp load_sysmon_config(agent_id) do
    # Resolve partition from agent registry, fall back to "default"
    partition = get_agent_partition(agent_id)
    actor = SystemActor.system(:sysmon_config_loader)
    device_uid = resolve_agent_device_uid(agent_id, actor)

    case ConfigServer.get_config(:sysmon, partition, agent_id,
           actor: actor,
           device_uid: device_uid
         ) do
      {:ok, entry} ->
        entry.config

      {:error, :no_config_found} ->
        Logger.debug("No sysmon config found for agent #{agent_id}, using disabled config")
        SysmonCompiler.disabled_config()

      {:error, reason} ->
        Logger.warning("Failed to load sysmon config for agent #{agent_id}: #{inspect(reason)}")

        SysmonCompiler.disabled_config()
    end
  end

  # Load SNMP configuration from the AgentConfig system
  # This uses the ConfigServer which compiles snmp configs from SNMPProfile resources
  defp load_snmp_config(agent_id) do
    partition = get_agent_partition(agent_id)
    actor = SystemActor.system(:snmp_config_loader)
    device_uid = resolve_agent_device_uid(agent_id, actor)

    case ConfigServer.get_config(:snmp, partition, agent_id, actor: actor, device_uid: device_uid) do
      {:ok, entry} ->
        entry.config

      {:error, :no_config_found} ->
        Logger.debug("No SNMP config found for agent #{agent_id}, using default (disabled)")
        SNMPCompiler.disabled_config()

      {:error, reason} ->
        Logger.warning("Failed to load SNMP config for agent #{agent_id}: #{inspect(reason)}")
        SNMPCompiler.disabled_config()
    end
  end

  # Build the proto-compatible SysmonConfig struct
  defp build_sysmon_proto_config(nil), do: nil

  defp build_sysmon_proto_config(config) when is_map(config) do
    %Monitoring.SysmonConfig{
      enabled: Map.get(config, "enabled", true),
      sample_interval: Map.get(config, "sample_interval", "10s"),
      collect_cpu: Map.get(config, "collect_cpu", true),
      collect_memory: Map.get(config, "collect_memory", true),
      collect_disk: Map.get(config, "collect_disk", true),
      collect_network: Map.get(config, "collect_network", false),
      collect_processes: Map.get(config, "collect_processes", false),
      disk_paths: Map.get(config, "disk_paths", []),
      disk_exclude_paths: Map.get(config, "disk_exclude_paths", []),
      thresholds: Map.get(config, "thresholds", %{}),
      profile_id: Map.get(config, "profile_id", ""),
      profile_name: Map.get(config, "profile_name", ""),
      config_source: Map.get(config, "config_source", "unassigned")
    }
  end

  # Build the proto-compatible SNMPConfig struct
  defp build_snmp_proto_config(nil), do: nil

  defp build_snmp_proto_config(config) when is_map(config) do
    targets =
      config
      |> Map.get("targets", [])
      |> List.wrap()
      |> Enum.map(&build_snmp_target_config/1)

    %Monitoring.SNMPConfig{
      enabled: Map.get(config, "enabled", false),
      profile_id: Map.get(config, "profile_id", "") || "",
      profile_name: Map.get(config, "profile_name", "") || "",
      targets: targets
    }
  end

  defp build_snmp_target_config(target) when is_map(target) do
    v3_auth = build_snmp_v3_auth(Map.get(target, "v3_auth"))
    community = community_for_target(target, v3_auth)
    oids = target |> Map.get("oids", []) |> List.wrap() |> Enum.map(&build_snmp_oid_config/1)

    %Monitoring.SNMPTargetConfig{
      id: Map.get(target, "id", "") || "",
      name: Map.get(target, "name", "") || "",
      host: Map.get(target, "host", "") || "",
      port: Map.get(target, "port", 161) || 161,
      version: snmp_version(Map.get(target, "version")),
      community: community,
      v3_auth: v3_auth,
      poll_interval_seconds: Map.get(target, "poll_interval_seconds", 60) || 60,
      timeout_seconds: Map.get(target, "timeout_seconds", 5) || 5,
      retries: Map.get(target, "retries", 3) || 3,
      oids: oids
    }
  end

  defp build_snmp_target_config(_), do: %Monitoring.SNMPTargetConfig{}

  defp build_snmp_v3_auth(nil), do: nil

  defp build_snmp_v3_auth(auth) when is_map(auth) do
    %Monitoring.SNMPv3Auth{
      username: Map.get(auth, "username", "") || "",
      security_level: snmp_security_level(Map.get(auth, "security_level")),
      auth_protocol: snmp_auth_protocol(Map.get(auth, "auth_protocol")),
      auth_password: Map.get(auth, "auth_password", "") || "",
      priv_protocol: snmp_priv_protocol(Map.get(auth, "priv_protocol")),
      priv_password: Map.get(auth, "priv_password", "") || ""
    }
  end

  defp build_snmp_v3_auth(_), do: nil

  defp community_for_target(target, v3_auth) do
    if v3_auth do
      ""
    else
      Map.get(target, "community", "") || ""
    end
  end

  defp build_snmp_oid_config(oid) when is_map(oid) do
    %Monitoring.SNMPOIDConfig{
      oid: Map.get(oid, "oid", "") || "",
      name: Map.get(oid, "name", "") || "",
      data_type: snmp_data_type(Map.get(oid, "data_type")),
      scale: Map.get(oid, "scale", 1.0) || 1.0,
      delta: Map.get(oid, "delta", false) || false
    }
  end

  defp build_snmp_oid_config(_), do: %Monitoring.SNMPOIDConfig{}

  defp snmp_version("v1"), do: :SNMP_VERSION_V1
  defp snmp_version("v2c"), do: :SNMP_VERSION_V2C
  defp snmp_version("v3"), do: :SNMP_VERSION_V3
  defp snmp_version(:v1), do: :SNMP_VERSION_V1
  defp snmp_version(:v2c), do: :SNMP_VERSION_V2C
  defp snmp_version(:v3), do: :SNMP_VERSION_V3
  defp snmp_version(_), do: :SNMP_VERSION_UNSPECIFIED

  defp snmp_security_level("noAuthNoPriv"), do: :SNMP_SECURITY_LEVEL_NO_AUTH_NO_PRIV
  defp snmp_security_level("authNoPriv"), do: :SNMP_SECURITY_LEVEL_AUTH_NO_PRIV
  defp snmp_security_level("authPriv"), do: :SNMP_SECURITY_LEVEL_AUTH_PRIV
  defp snmp_security_level(:no_auth_no_priv), do: :SNMP_SECURITY_LEVEL_NO_AUTH_NO_PRIV
  defp snmp_security_level(:auth_no_priv), do: :SNMP_SECURITY_LEVEL_AUTH_NO_PRIV
  defp snmp_security_level(:auth_priv), do: :SNMP_SECURITY_LEVEL_AUTH_PRIV
  defp snmp_security_level(_), do: :SNMP_SECURITY_LEVEL_UNSPECIFIED

  defp snmp_auth_protocol("MD5"), do: :SNMP_AUTH_PROTOCOL_MD5
  defp snmp_auth_protocol("SHA"), do: :SNMP_AUTH_PROTOCOL_SHA
  defp snmp_auth_protocol("SHA-224"), do: :SNMP_AUTH_PROTOCOL_SHA224
  defp snmp_auth_protocol("SHA-256"), do: :SNMP_AUTH_PROTOCOL_SHA256
  defp snmp_auth_protocol("SHA-384"), do: :SNMP_AUTH_PROTOCOL_SHA384
  defp snmp_auth_protocol("SHA-512"), do: :SNMP_AUTH_PROTOCOL_SHA512
  defp snmp_auth_protocol(:md5), do: :SNMP_AUTH_PROTOCOL_MD5
  defp snmp_auth_protocol(:sha), do: :SNMP_AUTH_PROTOCOL_SHA
  defp snmp_auth_protocol(:sha224), do: :SNMP_AUTH_PROTOCOL_SHA224
  defp snmp_auth_protocol(:sha256), do: :SNMP_AUTH_PROTOCOL_SHA256
  defp snmp_auth_protocol(:sha384), do: :SNMP_AUTH_PROTOCOL_SHA384
  defp snmp_auth_protocol(:sha512), do: :SNMP_AUTH_PROTOCOL_SHA512
  defp snmp_auth_protocol(_), do: :SNMP_AUTH_PROTOCOL_UNSPECIFIED

  defp snmp_priv_protocol("DES"), do: :SNMP_PRIV_PROTOCOL_DES
  defp snmp_priv_protocol("AES"), do: :SNMP_PRIV_PROTOCOL_AES
  defp snmp_priv_protocol("AES-192"), do: :SNMP_PRIV_PROTOCOL_AES192
  defp snmp_priv_protocol("AES-256"), do: :SNMP_PRIV_PROTOCOL_AES256
  defp snmp_priv_protocol("AES-192-C"), do: :SNMP_PRIV_PROTOCOL_AES192C
  defp snmp_priv_protocol("AES-256-C"), do: :SNMP_PRIV_PROTOCOL_AES256C
  defp snmp_priv_protocol(:des), do: :SNMP_PRIV_PROTOCOL_DES
  defp snmp_priv_protocol(:aes), do: :SNMP_PRIV_PROTOCOL_AES
  defp snmp_priv_protocol(:aes192), do: :SNMP_PRIV_PROTOCOL_AES192
  defp snmp_priv_protocol(:aes256), do: :SNMP_PRIV_PROTOCOL_AES256
  defp snmp_priv_protocol(:aes192c), do: :SNMP_PRIV_PROTOCOL_AES192C
  defp snmp_priv_protocol(:aes256c), do: :SNMP_PRIV_PROTOCOL_AES256C
  defp snmp_priv_protocol(_), do: :SNMP_PRIV_PROTOCOL_UNSPECIFIED

  defp snmp_data_type("counter"), do: :SNMP_DATA_TYPE_COUNTER
  defp snmp_data_type("gauge"), do: :SNMP_DATA_TYPE_GAUGE
  defp snmp_data_type("boolean"), do: :SNMP_DATA_TYPE_BOOLEAN
  defp snmp_data_type("bytes"), do: :SNMP_DATA_TYPE_BYTES
  defp snmp_data_type("string"), do: :SNMP_DATA_TYPE_STRING
  defp snmp_data_type("float"), do: :SNMP_DATA_TYPE_FLOAT
  defp snmp_data_type("timeticks"), do: :SNMP_DATA_TYPE_TIMETICKS
  defp snmp_data_type(:counter), do: :SNMP_DATA_TYPE_COUNTER
  defp snmp_data_type(:gauge), do: :SNMP_DATA_TYPE_GAUGE
  defp snmp_data_type(:boolean), do: :SNMP_DATA_TYPE_BOOLEAN
  defp snmp_data_type(:bytes), do: :SNMP_DATA_TYPE_BYTES
  defp snmp_data_type(:string), do: :SNMP_DATA_TYPE_STRING
  defp snmp_data_type(:float), do: :SNMP_DATA_TYPE_FLOAT
  defp snmp_data_type(:timeticks), do: :SNMP_DATA_TYPE_TIMETICKS
  defp snmp_data_type(_), do: :SNMP_DATA_TYPE_UNSPECIFIED

  # Load dusk configuration from the AgentConfig system
  # This uses the ConfigServer which compiles dusk configs from DuskProfile resources
  defp load_dusk_config(agent_id) do
    partition = get_agent_partition(agent_id)

    Logger.debug(
      "AgentConfigGenerator: loading dusk config for agent_id=#{inspect(agent_id)}, partition=#{inspect(partition)}"
    )

    case ConfigServer.get_config(:dusk, partition, agent_id) do
      {:ok, entry} ->
        entry.config

      {:error, :no_config_found} ->
        # Return default dusk config when none defined (disabled by default)
        Logger.debug("No dusk config found for agent #{agent_id}, using default (disabled)")
        DuskCompiler.default_config()

      {:error, reason} ->
        Logger.warning("Failed to load dusk config for agent #{agent_id}: #{inspect(reason)}")

        DuskCompiler.default_config()
    end
  end

  # Build the proto-compatible DuskConfig struct
  defp build_dusk_proto_config(nil), do: nil

  defp build_dusk_proto_config(config) when is_map(config) do
    %Monitoring.DuskConfig{
      enabled: Map.get(config, "enabled", false),
      node_address: Map.get(config, "node_address", ""),
      timeout: Map.get(config, "timeout", "5m"),
      profile_id: Map.get(config, "profile_id") || "",
      profile_name: Map.get(config, "profile_name") || "",
      config_source: Map.get(config, "config_source", "default")
    }
  end

  defp resolve_agent_device_uid(nil, _actor), do: nil
  defp resolve_agent_device_uid("", _actor), do: nil

  defp resolve_agent_device_uid(agent_id, actor) do
    case Agent.get_by_uid(agent_id, actor: actor) do
      {:ok, agent} ->
        agent.device_uid

      {:error, reason} ->
        Logger.debug(
          "Agent config device lookup failed for agent #{agent_id}: #{inspect(reason)}"
        )

        nil
    end
  end
end
