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

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compiler
  alias ServiceRadar.AgentConfig.Compilers.SNMPCompiler
  alias ServiceRadar.AgentConfig.Compilers.SysmonCompiler
  alias ServiceRadar.AgentConfig.ConfigServer
  alias ServiceRadar.AgentRegistry
  alias ServiceRadar.Edge.SNMPProtoMapper
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Integrations.SyncConfigGenerator
  alias ServiceRadar.Inventory.BumblebeeCatalogSnapshot
  alias ServiceRadar.Monitoring.ServiceCheck
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.Plugins.StorageToken

  require Ash.Query
  require Logger

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
          optional(:max_memory_mb) => integer() | nil,
          optional(:max_cpu_ms) => integer() | nil,
          optional(:max_concurrent) => integer() | nil,
          optional(:max_open_connections) => integer() | nil
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
          download_url: String.t() | nil,
          download_token: String.t() | nil
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
    {:ok, generate_config!(agent_id)}
  rescue
    error ->
      Logger.error("Failed to generate config for agent #{agent_id}: #{inspect(error)}")
      {:error, {:database_error, error}}
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
    config = generate_config!(agent_id)

    if config.config_version == current_version do
      Logger.debug("Config not modified for agent #{agent_id}, version: #{current_version}")
      :not_modified
    else
      Logger.info(
        "Config changed for agent #{agent_id}: #{current_version} -> #{config.config_version}"
      )

      {:ok, config}
    end
  rescue
    error ->
      {:error, {:database_error, error}}
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

  @doc """
  Converts a generated config map into an AgentConfigResponse proto struct.
  """
  @spec to_proto_response(map()) :: Monitoring.AgentConfigResponse.t()
  def to_proto_response(config) do
    proto_checks = to_proto_checks(config.checks)

    proto_plugins =
      to_proto_plugin_config(
        config.plugins || [],
        Map.get(config, :plugin_engine_limits, %{})
      )

    %Monitoring.AgentConfigResponse{
      not_modified: false,
      config_version: config.config_version,
      config_timestamp: config.config_timestamp,
      heartbeat_interval_sec: config.heartbeat_interval_sec,
      config_poll_interval_sec: config.config_poll_interval_sec,
      checks: proto_checks,
      config_json: Map.get(config, :config_json, <<>>),
      sysmon_config: Map.get(config, :sysmon_config),
      snmp_config: Map.get(config, :snmp_config),
      visibility_config: Map.get(config, :visibility_config),
      plugin_config: proto_plugins,
      bumblebee_config: Map.get(config, :bumblebee_config),
      endpoint_inventory_config: Map.get(config, :endpoint_inventory_config),
      addons: to_proto_addons(Map.get(config, :addons, []))
    }
  end

  @doc """
  Generates and converts the current agent config directly into a proto response.
  """
  @spec generate_proto_response(String.t()) :: Monitoring.AgentConfigResponse.t()
  def generate_proto_response(agent_id) when is_binary(agent_id) do
    agent_id
    |> generate_config!()
    |> to_proto_response()
  end

  defp generate_config!(agent_id) do
    checks = load_agent_checks!(agent_id)
    sync_payload = load_sync_payload(agent_id)
    sweep_config = load_sweep_config(agent_id)
    mapper_config = load_mapper_config(agent_id)
    sysmon_config = load_sysmon_config(agent_id)
    snmp_config = load_snmp_config(agent_id)
    visibility_config = load_visibility_config(agent_id)
    bumblebee_config = load_bumblebee_config(agent_id)
    endpoint_inventory_config = load_endpoint_inventory_config(agent_id)
    plugin_assignments = load_plugin_assignments(agent_id)
    plugin_engine_limits = load_plugin_engine_limits(agent_id)
    addon_assignments = load_addon_assignments(agent_id)

    plugin_config = %{
      assignments: plugin_assignments,
      engine_limits: plugin_engine_limits
    }

    build_config(
      checks,
      sync_payload,
      sweep_config,
      mapper_config,
      sysmon_config,
      snmp_config,
      visibility_config,
      bumblebee_config,
      endpoint_inventory_config,
      plugin_config,
      addon_assignments
    )
  end

  # Load service checks assigned to this agent from the database
  defp load_agent_checks!(agent_id) do
    # DB connection's search_path determines the schema
    actor = SystemActor.system(:agent_config_generator)

    query =
      ServiceCheck
      |> Ash.Query.for_read(:by_agent, %{agent_uid: agent_id}, actor: actor)
      |> Ash.Query.filter(enabled == true)

    checks = Ash.read!(query, actor: actor)
    Logger.debug("Loaded #{length(checks)} checks for agent #{agent_id}")
    checks
  end

  defp load_plugin_assignments(agent_id) do
    actor = SystemActor.system(:agent_config_generator)

    assignments =
      PluginAssignment
      |> Ash.Query.for_read(:by_agent, %{agent_uid: agent_id}, actor: actor)
      |> Ash.Query.filter(enabled == true)
      |> Ash.Query.sort(updated_at: :desc, inserted_at: :desc)
      |> Ash.Query.load(:plugin_package)
      |> Ash.read!()

    assignments
    |> Enum.map(&ensure_plugin_package_loaded(&1, actor))
    |> Enum.filter(&has_approved_package?/1)
    |> Enum.uniq_by(&logical_plugin_id/1)
    |> Enum.map(&build_plugin_assignment_config/1)
  rescue
    e ->
      Logger.warning("Error loading plugin assignments: #{inspect(e)}")
      []
  end

  defp ensure_plugin_package_loaded(
         %PluginAssignment{plugin_package: %PluginPackage{}} = assignment,
         _actor
       ) do
    assignment
  end

  defp ensure_plugin_package_loaded(%PluginAssignment{} = assignment, actor) do
    case load_plugin_package(assignment.plugin_package_id, actor) do
      {:ok, %PluginPackage{} = package} -> %{assignment | plugin_package: package}
      _ -> assignment
    end
  end

  defp load_plugin_package(package_id, actor) do
    PluginPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^package_id)
    |> Ash.read_one(actor: actor)
  end

  defp has_approved_package?(
         %PluginAssignment{plugin_package: %PluginPackage{status: :approved}} = assignment
       ) do
    if wasm_available?(assignment.plugin_package) do
      true
    else
      Logger.warning(
        "Skipping plugin assignment #{assignment.id}: wasm blob missing for package #{assignment.plugin_package.id}"
      )

      false
    end
  end

  defp has_approved_package?(%PluginAssignment{} = assignment) do
    Logger.warning(
      "Skipping plugin assignment #{assignment.id}: package is not approved or was not loaded"
    )

    false
  end

  defp wasm_available?(%PluginPackage{} = package) do
    key = package.wasm_object_key
    is_binary(key) and String.trim(key) != ""
  end

  defp logical_plugin_id(%PluginAssignment{plugin_package: %PluginPackage{plugin_id: plugin_id}}),
    do: plugin_id

  defp logical_plugin_id(%PluginAssignment{plugin_id: plugin_id}), do: plugin_id

  defp load_addon_assignments(agent_id) do
    actor = SystemActor.system(:agent_config_generator)

    assignments =
      AddonAssignment
      |> Ash.Query.for_read(:by_agent, %{agent_uid: agent_id}, actor: actor)
      |> Ash.Query.filter(enabled == true)
      |> Ash.Query.sort(updated_at: :desc, inserted_at: :desc)
      |> Ash.Query.load(:addon_package)
      |> Ash.read!()
      |> Enum.map(&ensure_addon_package_loaded(&1, actor))
      |> Enum.filter(&approved_addon_package?/1)
      |> Enum.uniq_by(&logical_addon_id/1)

    case assignments do
      [] ->
        []

      _ ->
        # Resolve the agent's platform only when there are assignments to compile,
        # so the common no-add-on path avoids the extra registry lookup.
        {agent_os, agent_arch} = resolve_agent_platform(agent_id, actor)
        Enum.map(assignments, &build_addon_assignment_config(&1, agent_os, agent_arch))
    end
  rescue
    e ->
      Logger.warning("Error loading addon assignments: #{inspect(e)}")
      []
  end

  defp ensure_addon_package_loaded(
         %AddonAssignment{addon_package: %AddonPackage{}} = assignment,
         _actor
       ), do: assignment

  defp ensure_addon_package_loaded(%AddonAssignment{} = assignment, actor) do
    AddonPackage
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^assignment.addon_package_id)
    |> Ash.read_one(actor: actor)
    |> case do
      {:ok, %AddonPackage{} = package} -> %{assignment | addon_package: package}
      _ -> assignment
    end
  end

  defp approved_addon_package?(%AddonAssignment{addon_package: %AddonPackage{status: :approved}}),
    do: true

  defp approved_addon_package?(%AddonAssignment{} = assignment) do
    Logger.warning(
      "Skipping addon assignment #{assignment.id}: package is not approved or was not loaded"
    )

    false
  end

  defp logical_addon_id(%AddonAssignment{addon_package: %AddonPackage{addon_id: addon_id}}),
    do: addon_id

  defp logical_addon_id(%AddonAssignment{addon_id: addon_id}), do: addon_id

  defp build_addon_assignment_config(%AddonAssignment{} = assignment, agent_os, agent_arch) do
    package = assignment.addon_package
    artifact = select_addon_artifact(package.artifacts, agent_os, agent_arch)

    %{
      addon_id: logical_addon_id(assignment),
      version: package.version,
      enabled: assignment.enabled,
      binary_path: addon_binary_path(package),
      args: assignment.args || [],
      params: normalize_map(assignment.params),
      capabilities: effective_addon_capabilities(package),
      os_capabilities: addon_os_capabilities(package),
      delivery: package.delivery,
      supervision: package.supervision,
      artifact_object_key: artifact[:object_key],
      artifact_sha256: artifact[:sha256],
      artifact_signature: artifact[:signature],
      target_os: artifact[:os],
      target_arch: artifact[:arch]
    }
  end

  # Resolves the target agent's {os, arch} from registry metadata so the generator
  # can select the matching per-architecture artifact. Returns {nil, nil} when the
  # agent or its platform metadata is unavailable.
  defp resolve_agent_platform(agent_id, actor) do
    case Agent.get_by_uid(agent_id, actor: actor) do
      {:ok, %{metadata: meta}} when is_map(meta) ->
        {map_string(meta, "os", nil), map_string(meta, "arch", nil)}

      _ ->
        {nil, nil}
    end
  rescue
    _ -> {nil, nil}
  end

  # Selects the per-architecture artifact matching the agent's os/arch from the
  # package's artifacts map (keyed by "os/arch" -> %{object_key, sha256, signature}).
  # Returns an empty map when arch is unknown or no matching artifact exists (e.g.
  # before the signing pipeline populates artifacts), leaving the agent to fall back
  # to binary_path.
  defp select_addon_artifact(artifacts, os, arch)
       when is_map(artifacts) and is_binary(os) and is_binary(arch) and os != "" and arch != "" do
    with entry when is_map(entry) <- Map.get(artifacts, "#{os}/#{arch}"),
         object_key when object_key not in [nil, ""] <- map_string(entry, "object_key", nil),
         sha256 when sha256 not in [nil, ""] <- map_string(entry, "sha256", nil) do
      %{
        object_key: object_key,
        sha256: sha256,
        signature: map_string(entry, "signature", nil),
        os: os,
        arch: arch
      }
    else
      # No matching entry, or an incomplete one (missing object_key/sha256): emit no
      # artifact reference so the agent does not attempt a fetch it cannot verify.
      _ -> %{}
    end
  end

  defp select_addon_artifact(_artifacts, _os, _arch), do: %{}

  # Prefer the operator-approved capability subset when set (mirrors plugin
  # effective_capabilities); fall back to the package's full manifest list.
  defp effective_addon_capabilities(%AddonPackage{} = package) do
    case package.approved_capabilities || [] do
      [] -> package.capabilities || []
      approved -> approved
    end
  end

  # Linux file capabilities the manifest declares under `requires.os_capabilities`.
  # The agent applies these to the staged pushed-artifact binary via the root-owned
  # agent-updater (setcap). Accepts string or atom keys and drops blanks.
  defp addon_os_capabilities(%AddonPackage{requires: requires}) when is_map(requires) do
    case requires["os_capabilities"] || requires[:os_capabilities] do
      list when is_list(list) ->
        list
        |> Enum.map(&to_string/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp addon_os_capabilities(_), do: []

  defp addon_binary_path(%AddonPackage{binary: binary, install_path: install_path})
       when is_binary(binary) and binary != "" do
    Path.join(install_path || "/usr/local/lib/serviceradar/bin", binary)
  end

  defp addon_binary_path(_), do: ""

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
    config_schema = normalize_map(package.config_schema)
    download_request = StorageToken.download_request(package.id, package.wasm_object_key)

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
      params: resolve_plugin_params(config_schema, assignment.params, assignment),
      permissions: effective_permissions(assignment, package, manifest),
      resources: effective_resources(assignment, package, manifest),
      enabled: assignment.enabled,
      interval_sec: assignment.interval_seconds || 60,
      timeout_sec: assignment.timeout_seconds || 10,
      wasm_object_key: package.wasm_object_key,
      content_hash: package.content_hash,
      source_type: normalize_source_type(package.source_type),
      download_url: download_request && download_request.url,
      download_token: download_request && download_request.token
    }
  end

  defp resolve_plugin_params(config_schema, params, %PluginAssignment{} = assignment) do
    params = normalize_map(params)
    config_schema = maybe_add_policy_credential_secret_fields(config_schema, params, assignment)

    case SecretRefs.resolve_runtime_params(config_schema, params) do
      {:ok, resolved} ->
        resolved

      {:error, errors} ->
        Logger.warning(
          "Failed to resolve plugin secret refs for assignment #{assignment.id}: #{Enum.join(errors, "; ")}"
        )

        SecretRefs.public_params(params)
    end
  end

  defp maybe_add_policy_credential_secret_fields(config_schema, params, %PluginAssignment{
         source: :policy
       }) do
    maybe_add_policy_credential_secret_fields(config_schema, params, :policy)
  end

  defp maybe_add_policy_credential_secret_fields(config_schema, params, assignment)
       when is_map(assignment) do
    maybe_add_policy_credential_secret_fields(
      config_schema,
      params,
      Map.get(assignment, :source) || Map.get(assignment, "source")
    )
  end

  defp maybe_add_policy_credential_secret_fields(config_schema, params, :policy) do
    maybe_add_policy_secret_field_from_params(config_schema, params)
  end

  defp maybe_add_policy_credential_secret_fields(config_schema, params, "policy") do
    maybe_add_policy_secret_field_from_params(config_schema, params)
  end

  defp maybe_add_policy_credential_secret_fields(config_schema, _params, _assignment),
    do: config_schema

  defp maybe_add_policy_secret_field_from_params(config_schema, params) do
    params = normalize_map(params)

    if policy_credential_broker_assignment?(params) do
      config_schema
      |> maybe_add_secret_ref_property(params, "api_token_secret_ref")
      |> maybe_add_secret_ref_property(params, "credential_secret")
    else
      config_schema
    end
  end

  defp policy_credential_broker_assignment?(params) do
    params = normalize_map(params)
    broker = fetch_map_value(params, :credential_broker, %{})
    template = normalize_map(fetch_map_value(params, :template, %{}))

    credential_broker_params?(params, broker) or
      (map_present?(template) and
         credential_broker_params?(template, fetch_map_value(template, :credential_broker, %{})))
  end

  defp credential_broker_params?(params, broker) do
    fetch_map_value(broker, :schema) == "serviceradar.edge_credential_broker_grant.v1" and
      (SecretRefs.secret_ref?(fetch_map_value(params, :api_token_secret_ref)) or
         SecretRefs.secret_ref?(fetch_map_value(params, :credential_secret)))
  end

  defp maybe_add_secret_ref_property(config_schema, params, field) do
    if secret_ref_in_params_or_template?(params, field) do
      add_secret_ref_property(config_schema, field)
    else
      config_schema
    end
  end

  defp secret_ref_in_params_or_template?(params, field) do
    params = normalize_map(params)
    template = normalize_map(fetch_map_value(params, :template, %{}))

    SecretRefs.secret_ref?(fetch_map_value(params, field)) or
      SecretRefs.secret_ref?(fetch_map_value(template, field))
  end

  defp add_secret_ref_property(config_schema, field) do
    config_schema = normalize_map(config_schema)
    properties = normalize_map(fetch_map_value(config_schema, :properties, %{}))

    if SecretRefs.secret_ref_property?(Map.get(properties, field)) do
      config_schema
    else
      Map.put(config_schema, "properties", Map.put(properties, field, secret_ref_property()))
    end
  end

  defp secret_ref_property do
    %{
      "type" => "string",
      "secretRef" => true,
      "x-internal" => true
    }
  end

  defp effective_capabilities(%PluginPackage{} = package, manifest) do
    approved = package.approved_capabilities || []

    if approved == [] do
      Map.get(manifest, "capabilities") || Map.get(manifest, :capabilities) || []
    else
      approved
    end
  end

  defp effective_permissions(
         %PluginAssignment{} = assignment,
         %PluginPackage{} = package,
         manifest
       ) do
    manifest
    |> fetch_map_value(:permissions, %{})
    |> normalize_permissions()
    |> narrow_permissions(package.approved_permissions)
    |> narrow_permissions(assignment.permissions_override)
  end

  defp effective_resources(%PluginAssignment{} = assignment, %PluginPackage{} = package, manifest) do
    manifest
    |> fetch_map_value(:resources, %{})
    |> normalize_resources()
    |> narrow_resources(package.approved_resources)
    |> narrow_resources(assignment.resources_override)
  end

  defp map_present?(map) when is_map(map), do: map_size(map) > 0
  defp map_present?(_), do: false

  defp fetch_map_value(map, key, default \\ nil)

  defp fetch_map_value(map, key, default) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, to_string(key)) -> Map.get(map, to_string(key))
      true -> default
    end
  end

  defp fetch_map_value(_map, _key, default), do: default

  defp normalize_permissions(raw) do
    %{
      allowed_domains: normalize_string_list(fetch_map_value(raw, :allowed_domains, [])),
      allowed_networks: normalize_string_list(fetch_map_value(raw, :allowed_networks, [])),
      allowed_ports: normalize_int_list(fetch_map_value(raw, :allowed_ports, []))
    }
  end

  defp narrow_permissions(base, override) do
    override = normalize_map(override)

    %{
      allowed_domains:
        narrow_string_scope(
          Map.get(base, :allowed_domains, []),
          fetch_override_list(override, :allowed_domains)
        ),
      allowed_networks:
        narrow_string_scope(
          Map.get(base, :allowed_networks, []),
          fetch_override_list(override, :allowed_networks)
        ),
      allowed_ports:
        narrow_port_scope(
          Map.get(base, :allowed_ports, []),
          fetch_override_list(override, :allowed_ports)
        )
    }
  end

  defp fetch_override_list(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> {:present, Map.get(map, key)}
      Map.has_key?(map, to_string(key)) -> {:present, Map.get(map, to_string(key))}
      true -> :absent
    end
  end

  defp fetch_override_list(_map, _key), do: :absent

  defp narrow_string_scope(base, :absent), do: base

  defp narrow_string_scope(base, {:present, override}) do
    override = normalize_string_list(override)

    if base == [] do
      []
    else
      allowed = MapSet.new(override)
      Enum.filter(base, &MapSet.member?(allowed, &1))
    end
  end

  defp narrow_port_scope(base, :absent), do: base

  defp narrow_port_scope(base, {:present, override}) do
    override = normalize_int_list(override)

    cond do
      base == [] ->
        override

      override == [] ->
        base

      true ->
        allowed = MapSet.new(override)
        Enum.filter(base, &MapSet.member?(allowed, &1))
    end
  end

  defp normalize_resources(raw) do
    drop_nil_entries(%{
      requested_memory_mb: normalize_positive_int(fetch_map_value(raw, :requested_memory_mb)),
      requested_cpu_ms: normalize_positive_int(fetch_map_value(raw, :requested_cpu_ms)),
      max_open_connections: normalize_nonneg_int(fetch_map_value(raw, :max_open_connections))
    })
  end

  defp narrow_resources(base, override) do
    override = normalize_map(override)

    drop_nil_entries(%{
      requested_memory_mb:
        narrow_positive_resource(
          Map.get(base, :requested_memory_mb),
          fetch_override_value(override, :requested_memory_mb)
        ),
      requested_cpu_ms:
        narrow_positive_resource(
          Map.get(base, :requested_cpu_ms),
          fetch_override_value(override, :requested_cpu_ms)
        ),
      max_open_connections:
        narrow_nonneg_resource(
          Map.get(base, :max_open_connections),
          fetch_override_value(override, :max_open_connections)
        )
    })
  end

  defp fetch_override_value(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> {:present, Map.get(map, key)}
      Map.has_key?(map, to_string(key)) -> {:present, Map.get(map, to_string(key))}
      true -> :absent
    end
  end

  defp fetch_override_value(_map, _key), do: :absent

  defp narrow_positive_resource(base, :absent), do: base

  defp narrow_positive_resource(base, {:present, override}) do
    case normalize_positive_int(override) do
      nil ->
        base

      narrowed when is_integer(base) and base > 0 ->
        min(base, narrowed)

      narrowed ->
        narrowed
    end
  end

  defp narrow_nonneg_resource(base, :absent), do: base

  defp narrow_nonneg_resource(base, {:present, override}) do
    case normalize_nonneg_int(override) do
      nil ->
        base

      0 when is_integer(base) and base > 0 ->
        base

      narrowed when is_integer(base) and base > 0 ->
        min(base, narrowed)

      narrowed ->
        narrowed
    end
  end

  defp normalize_positive_int(value) when is_integer(value) and value > 0, do: value

  defp normalize_positive_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_positive_int(_value), do: nil

  defp normalize_nonneg_int(value) when is_integer(value) and value >= 0, do: value

  defp normalize_nonneg_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_nonneg_int(_value), do: nil

  defp normalize_string_list(list) when is_list(list) do
    list
    |> Enum.map(&normalize_string_item/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_string_list(_list), do: []

  defp normalize_string_item(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      item -> item
    end
  end

  defp normalize_string_item(_value), do: nil

  defp normalize_int_list(list) when is_list(list) do
    list
    |> Enum.map(&normalize_positive_int/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_int_list(_list), do: []

  defp drop_nil_entries(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_map(nil), do: %{}
  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_), do: %{}

  defp map_string(map, key, default \\ "") when is_map(map) do
    case Map.get(map, key, default) do
      nil -> default
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end

  defp map_bool(map, key, default) when is_map(map) do
    case Map.get(map, key, default) do
      value when is_boolean(value) -> value
      _ -> default
    end
  end

  defp map_int(map, key, default \\ 0) when is_map(map) do
    case Map.get(map, key, default) do
      value when is_integer(value) -> value
      _ -> default
    end
  end

  defp map_list(map, key) when is_map(map) do
    case Map.get(map, key, []) do
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      _ -> []
    end
  end

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
         visibility_config,
         bumblebee_config,
         endpoint_inventory_config,
         plugin_config,
         addon_assignments
       ) do
    check_configs = Enum.map(checks, &convert_check_to_config/1)
    plugin_assignments = Map.get(plugin_config, :assignments, [])
    plugin_engine_limits = Map.get(plugin_config, :engine_limits, %{})

    # Merge sweep config into the payload
    full_payload =
      sync_payload
      |> Map.put("sweep", sweep_config)
      |> Map.put("mapper", mapper_config)
      |> Map.put("bumblebee", bumblebee_config)
      |> Map.put("endpoint_inventory", endpoint_inventory_config)

    # Compute version hash from all config components
    config_version =
      compute_version_hash(
        check_configs,
        full_payload,
        sysmon_config,
        snmp_config,
        visibility_config,
        bumblebee_config,
        endpoint_inventory_config,
        plugin_assignments,
        plugin_engine_limits,
        addon_assignments
      )

    config_json =
      full_payload
      |> Map.put("plugins", %{
        "assignments" => plugin_assignments,
        "engine_limits" => plugin_engine_limits
      })
      |> Jason.encode!()

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
      visibility_config: build_visibility_proto_config(visibility_config),
      bumblebee_config: build_bumblebee_proto_config(bumblebee_config),
      endpoint_inventory_config: build_endpoint_inventory_proto_config(endpoint_inventory_config),
      addons: addon_assignments
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
  defp atom_to_check_type(:mtr), do: "mtr"
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
         visibility_config,
         bumblebee_config,
         endpoint_inventory_config,
         plugin_assignments,
         plugin_engine_limits,
         addon_assignments
       ) do
    # Sort checks by ID for deterministic ordering
    sorted_checks = Enum.sort_by(check_configs, & &1.check_id)

    sorted_plugins =
      plugin_assignments
      |> Enum.sort_by(& &1.assignment_id)
      |> Enum.map(&stable_plugin_assignment/1)

    sorted_addons =
      addon_assignments
      |> Enum.sort_by(& &1.addon_id)
      |> Enum.map(&stable_addon_assignment/1)

    version_payload = %{
      checks: sorted_checks,
      sync: stable_config_fragment(sync_payload),
      sysmon: stable_config_fragment(sysmon_config),
      snmp: stable_config_fragment(snmp_config),
      visibility: stable_config_fragment(visibility_config),
      bumblebee: stable_config_fragment(bumblebee_config),
      endpoint_inventory: stable_config_fragment(endpoint_inventory_config),
      plugins: sorted_plugins,
      plugin_engine_limits: plugin_engine_limits,
      addons: sorted_addons
    }

    "v" <> Compiler.content_hash(version_payload)
  end

  # The add-on assignment map carries no volatile/derived fields (unlike plugin
  # assignments, which strip per-poll download tokens), so the whole map joins the
  # config version hash. binary_path is included intentionally: a binary/install_path
  # (or per-arch artifact) change must re-version so a polling agent stops getting
  # `not_modified` and relaunches the new executable.
  defp stable_addon_assignment(assignment), do: assignment

  defp stable_config_fragment(%{} = map) do
    map
    |> Map.drop([:compiled_at, "compiled_at", :generated_at, "generated_at"])
    |> Map.new(fn {key, value} -> {key, stable_config_fragment(value)} end)
  end

  defp stable_config_fragment(list) when is_list(list),
    do: Enum.map(list, &stable_config_fragment/1)

  defp stable_config_fragment(value), do: value

  defp stable_plugin_assignment(assignment) when is_map(assignment) do
    assignment
    |> Map.delete(:download_url)
    |> Map.delete("download_url")
    |> Map.delete(:download_token)
    |> Map.delete("download_token")
  end

  defp stable_plugin_assignment(assignment), do: assignment

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

  defp to_proto_addons(addons) when is_list(addons) do
    Enum.map(addons, fn addon ->
      %Monitoring.AddonAssignmentConfig{
        addon_id: assignment_string(addon[:addon_id]),
        version: assignment_string(addon[:version]),
        enabled: addon[:enabled] || false,
        binary_path: assignment_string(addon[:binary_path]),
        args: addon[:args] || [],
        config_json: encode_json(normalize_map(addon[:params])),
        capabilities: addon[:capabilities] || [],
        os_capabilities: addon[:os_capabilities] || [],
        delivery: assignment_enum_string(addon[:delivery]),
        supervision: assignment_enum_string(addon[:supervision]),
        artifact_object_key: assignment_string(addon[:artifact_object_key]),
        artifact_sha256: assignment_string(addon[:artifact_sha256]),
        artifact_signature: assignment_string(addon[:artifact_signature]),
        target_os: assignment_string(addon[:target_os]),
        target_arch: assignment_string(addon[:target_arch])
      }
    end)
  end

  defp to_proto_addons(_), do: []

  # Add-on delivery/supervision are Ash atoms (e.g. :pushed_artifact); the proto
  # field is a string, so stringify (and tolerate a pre-stringified value).
  defp assignment_enum_string(nil), do: ""
  defp assignment_enum_string(value) when is_atom(value), do: Atom.to_string(value)
  defp assignment_enum_string(value) when is_binary(value), do: value
  defp assignment_enum_string(_), do: ""

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
    params = resolved_assignment_params(assignment)
    source_fields = proto_assignment_source_fields(assignment)

    %Monitoring.PluginAssignmentConfig{
      assignment_id: assignment.assignment_id,
      plugin_id: assignment.plugin_id,
      package_id: assignment.package_id,
      version: assignment.version,
      name: assignment.name,
      entrypoint: assignment.entrypoint,
      runtime: assignment.runtime || "",
      outputs: assignment.outputs,
      capabilities: assignment_capabilities(assignment),
      params_json: encode_json(params),
      permissions_json: encode_json(assignment.permissions),
      resources_json: encode_json(assignment.resources),
      enabled: assignment.enabled,
      interval_sec: assignment.interval_sec,
      timeout_sec: assignment.timeout_sec,
      wasm_object_key: assignment_string(assignment.wasm_object_key),
      content_hash: assignment_string(assignment.content_hash),
      source_type: assignment_string(assignment.source_type),
      source_repo_url: source_fields.source_repo_url,
      source_commit: source_fields.source_commit,
      download_url: assignment_string(assignment.download_url),
      download_token: source_fields.download_token
    }
  end

  defp resolved_assignment_params(assignment) do
    params = normalize_map(assignment.params)

    schema =
      assignment
      |> proto_assignment_config_schema()
      |> maybe_add_policy_credential_secret_fields(params, assignment)

    case SecretRefs.resolve_runtime_params(schema, params) do
      {:ok, resolved} -> resolved
      {:error, _} -> params
    end
  end

  defp proto_assignment_source_fields(assignment) do
    %{
      source_repo_url: Map.get(assignment, :source_repo_url, ""),
      source_commit: Map.get(assignment, :source_commit, ""),
      download_token: assignment_string(Map.get(assignment, :download_token, ""))
    }
  end

  defp assignment_capabilities(assignment), do: assignment.capabilities || []

  defp assignment_string(nil), do: ""
  defp assignment_string(value), do: value

  defp proto_assignment_config_schema(assignment) do
    plugin_package =
      Map.get(assignment, :plugin_package) ||
        Map.get(assignment, "plugin_package") ||
        %{}

    normalize_map(
      Map.get(assignment, :config_schema) ||
        Map.get(assignment, "config_schema") ||
        Map.get(plugin_package, :config_schema) ||
        Map.get(plugin_package, "config_schema") ||
        %{}
    )
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
      [] ->
        Logger.debug(
          "AgentConfigGenerator: agent #{agent_id} not found in registry, using partition=default"
        )

        "default"

      entries ->
        {_pid, metadata} = select_agent_registry_entry(entries)
        partition = metadata[:partition_id] || "default"

        Logger.debug(
          "AgentConfigGenerator: resolved partition=#{partition} for agent #{agent_id}"
        )

        partition
    end
  end

  defp select_agent_registry_entry([entry]), do: entry

  defp select_agent_registry_entry(entries) do
    Enum.max_by(entries, fn {_pid, metadata} ->
      {
        metadata[:status] == :connected,
        metadata[:capabilities] != [],
        metadata_time_score(metadata[:last_heartbeat]),
        metadata_time_score(metadata[:connected_at]),
        metadata_time_score(metadata[:registered_at])
      }
    end)
  end

  defp metadata_time_score(%DateTime{} = timestamp), do: DateTime.to_unix(timestamp, :microsecond)
  defp metadata_time_score(_timestamp), do: 0

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

  # Load visibility configuration from the AgentConfig system.
  defp load_visibility_config(agent_id) do
    partition = get_agent_partition(agent_id)
    actor = SystemActor.system(:visibility_config_loader)
    device_uid = resolve_agent_device_uid(agent_id, actor)

    case ConfigServer.get_config(:visibility, partition, agent_id,
           actor: actor,
           device_uid: device_uid
         ) do
      {:ok, entry} ->
        entry.config

      {:error, :no_config_found} ->
        Logger.debug("No visibility config found for agent #{agent_id}, using disabled config")

        disabled_visibility_config()

      {:error, reason} ->
        Logger.warning(
          "Failed to load visibility config for agent #{agent_id}: #{inspect(reason)}"
        )

        disabled_visibility_config()
    end
  end

  defp load_bumblebee_config(agent_id) do
    partition = get_agent_partition(agent_id)
    actor = SystemActor.system(:bumblebee_config_loader)
    device_uid = resolve_agent_device_uid(agent_id, actor)

    with {:ok, entry} <-
           ConfigServer.get_config(:bumblebee, partition, agent_id,
             actor: actor,
             device_uid: device_uid
           ),
         profile_config when is_map(profile_config) <- entry.config,
         true <- map_bool(profile_config, "enabled", false),
         {:ok, %BumblebeeCatalogSnapshot{} = snapshot} <- active_bumblebee_catalog(actor),
         true <- usable_bumblebee_catalog?(snapshot) do
      profile_config
      |> Map.put("enabled", true)
      |> Map.put("agent_id", agent_id)
      |> Map.put_new("scan_profile", "default")
      |> Map.put_new("root_discovery_mode", "all")
      |> Map.put_new("explicit_roots", [])
      |> Map.put_new("exclude_roots", [])
      |> Map.put_new("ecosystems", [])
      |> Map.put_new("scan_timeout", "10m")
      |> Map.put_new("max_findings", 1000)
      |> Map.put_new("max_output_bytes", 33_554_432)
      |> Map.put_new("cadence", "6h")
      |> Map.put_new("findings_only", true)
      |> Map.put("catalog", bumblebee_catalog_config(snapshot))
    else
      {:error, :no_config_found} ->
        Logger.debug("No Bumblebee config found for agent #{agent_id}, using disabled config")
        disabled_bumblebee_config()

      {:error, reason} ->
        Logger.warning(
          "Failed to load Bumblebee config for agent #{agent_id}: #{inspect(reason)}"
        )

        disabled_bumblebee_config()

      _ ->
        disabled_bumblebee_config()
    end
  end

  defp active_bumblebee_catalog(actor) do
    BumblebeeCatalogSnapshot
    |> Ash.Query.for_read(:active, %{}, actor: actor)
    |> Ash.read_one(actor: actor)
  end

  defp usable_bumblebee_catalog?(%BumblebeeCatalogSnapshot{} = snapshot) do
    present?(snapshot.snapshot_ref) and present?(snapshot.object_key) and
      present?(snapshot.content_sha256) and is_integer(snapshot.object_size_bytes) and
      snapshot.object_size_bytes > 0
  end

  defp bumblebee_catalog_config(snapshot) do
    %{
      "schema_version" => "serviceradar.bumblebee.catalog_assignment.v1",
      "snapshot_ref" => snapshot.snapshot_ref,
      "catalog_version" => snapshot.catalog_version,
      "source_revision" => snapshot.source_revision,
      "object_key" => snapshot.object_key,
      "sha256" => snapshot.content_sha256,
      "size_bytes" => snapshot.object_size_bytes,
      "promoted_at" => snapshot.promoted_at && DateTime.to_iso8601(snapshot.promoted_at)
    }
  end

  defp disabled_bumblebee_config, do: %{"enabled" => false}

  defp load_endpoint_inventory_config(agent_id) do
    partition = get_agent_partition(agent_id)
    actor = SystemActor.system(:endpoint_inventory_config_loader)
    device_uid = resolve_agent_device_uid(agent_id, actor)

    case ConfigServer.get_config(:endpoint_inventory, partition, agent_id,
           actor: actor,
           device_uid: device_uid
         ) do
      {:ok, entry} when is_map(entry.config) ->
        entry.config
        |> Map.put("agent_id", agent_id)
        |> Map.put_new("sources", ["dpkg", "rpm", "apk"])
        |> Map.put_new("scan_timeout", "5m")
        |> Map.put_new("max_packages", 100_000)
        |> Map.put_new("max_output_bytes", 33_554_432)
        |> Map.put_new("cadence", "12h")
        |> Map.put_new("collect_paths", false)
        |> Map.put_new("collect_file_hashes", false)

      {:error, :no_config_found} ->
        Logger.debug(
          "No endpoint inventory config found for agent #{agent_id}, using disabled config"
        )

        disabled_endpoint_inventory_config()

      {:error, reason} ->
        Logger.warning(
          "Failed to load endpoint inventory config for agent #{agent_id}: #{inspect(reason)}"
        )

        disabled_endpoint_inventory_config()
    end
  end

  defp disabled_endpoint_inventory_config, do: %{"enabled" => false}

  defp build_endpoint_inventory_proto_config(config) when is_map(config) do
    %Monitoring.EndpointInventoryConfig{
      enabled: map_bool(config, "enabled", false),
      agent_id: map_string(config, "agent_id"),
      sources: map_list(config, "sources"),
      scan_timeout: map_string(config, "scan_timeout"),
      max_packages: map_int(config, "max_packages"),
      max_output_bytes: map_int(config, "max_output_bytes"),
      cadence: map_string(config, "cadence"),
      collect_paths: map_bool(config, "collect_paths", false),
      collect_file_hashes: map_bool(config, "collect_file_hashes", false),
      force_fresh_enabled: map_bool(config, "force_fresh_enabled", false),
      force_full_scan_interval: map_int(config, "force_full_scan_interval"),
      cache_stale_threshold: map_string(config, "cache_stale_threshold"),
      upload_jitter: map_string(config, "upload_jitter"),
      upload_retry_initial: map_string(config, "upload_retry_initial"),
      upload_retry_max: map_string(config, "upload_retry_max"),
      upload_retry_max_attempts: map_int(config, "upload_retry_max_attempts")
    }
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp build_bumblebee_proto_config(nil), do: nil

  defp build_bumblebee_proto_config(config) when is_map(config) do
    %Monitoring.BumblebeeConfig{
      enabled: map_bool(config, "enabled", false),
      agent_id: map_string(config, "agent_id"),
      scan_profile: map_string(config, "scan_profile"),
      root_discovery_mode: map_string(config, "root_discovery_mode"),
      explicit_roots: map_list(config, "explicit_roots"),
      exclude_roots: map_list(config, "exclude_roots"),
      ecosystems: map_list(config, "ecosystems"),
      scan_timeout: map_string(config, "scan_timeout"),
      max_findings: map_int(config, "max_findings"),
      max_output_bytes: map_int(config, "max_output_bytes"),
      cadence: map_string(config, "cadence"),
      findings_only: map_bool(config, "findings_only", true),
      catalog:
        build_bumblebee_catalog_proto(Map.get(config, "catalog") || Map.get(config, :catalog))
    }
  end

  defp build_bumblebee_proto_config(_), do: nil

  defp build_bumblebee_catalog_proto(nil), do: nil

  defp build_bumblebee_catalog_proto(catalog) when is_map(catalog) do
    %Monitoring.BumblebeeCatalogAssignment{
      schema_version:
        map_string(catalog, "schema_version", "serviceradar.bumblebee.catalog_assignment.v1"),
      snapshot_ref: map_string(catalog, "snapshot_ref"),
      catalog_version: map_string(catalog, "catalog_version"),
      source_revision: map_string(catalog, "source_revision"),
      object_key: map_string(catalog, "object_key"),
      sha256: map_string(catalog, "sha256"),
      size_bytes: map_int(catalog, "size_bytes"),
      promoted_at: map_string(catalog, "promoted_at")
    }
  end

  defp build_bumblebee_catalog_proto(_), do: nil

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
      process_limit: Map.get(config, "process_limit", 0),
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
      version: SNMPProtoMapper.version(Map.get(target, "version")),
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
      security_level: SNMPProtoMapper.security_level(Map.get(auth, "security_level")),
      auth_protocol: SNMPProtoMapper.auth_protocol(Map.get(auth, "auth_protocol")),
      auth_password: Map.get(auth, "auth_password", "") || "",
      priv_protocol: SNMPProtoMapper.priv_protocol(Map.get(auth, "priv_protocol")),
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
      data_type: SNMPProtoMapper.data_type(Map.get(oid, "data_type")),
      scale: Map.get(oid, "scale", 1.0) || 1.0,
      delta: Map.get(oid, "delta", false) || false
    }
  end

  defp build_snmp_oid_config(_), do: %Monitoring.SNMPOIDConfig{}

  defp disabled_visibility_config do
    %{
      "enabled" => false,
      "capture_interfaces" => [],
      "binary_overrides" => %{},
      "device_bindings" => [],
      "dpi" => %{"enabled" => false, "protocols" => []},
      "default_sample_interval_ms" => 0
    }
  end

  defp build_visibility_proto_config(nil), do: nil

  defp build_visibility_proto_config(config) when is_map(config) do
    %Monitoring.VisibilityConfig{
      enabled: Map.get(config, "enabled", false),
      capture_interfaces: config |> Map.get("capture_interfaces", []) |> List.wrap(),
      binary_overrides: build_visibility_binary_overrides(Map.get(config, "binary_overrides")),
      device_bindings:
        config
        |> Map.get("device_bindings", [])
        |> List.wrap()
        |> Enum.map(&build_visibility_device_binding/1),
      dpi: build_visibility_dpi_config(Map.get(config, "dpi")),
      default_sample_interval_ms: Map.get(config, "default_sample_interval_ms", 0) || 0
    }
  end

  defp build_visibility_binary_overrides(overrides) when is_map(overrides) do
    path = Map.get(overrides, "path", "") || ""

    if path == "" do
      nil
    else
      %Monitoring.VisibilityBinaryOverrides{path: path}
    end
  end

  defp build_visibility_binary_overrides(_), do: nil

  defp build_visibility_device_binding(binding) when is_map(binding) do
    %Monitoring.VisibilityDeviceBinding{
      ip: Map.get(binding, "ip", "") || "",
      profile_id: Map.get(binding, "profile_id", "") || "",
      profile_name: Map.get(binding, "profile_name", "") || "",
      fingerprint: build_visibility_fingerprint_config(Map.get(binding, "fingerprint")),
      dpi: build_visibility_dpi_config(Map.get(binding, "dpi")),
      sample_interval_ms: Map.get(binding, "sample_interval_ms", 0) || 0
    }
  end

  defp build_visibility_device_binding(_), do: %Monitoring.VisibilityDeviceBinding{}

  defp build_visibility_fingerprint_config(fingerprint) when is_map(fingerprint) do
    %Monitoring.VisibilityFingerprintConfig{
      tcp: Map.get(fingerprint, "tcp", false),
      tls: Map.get(fingerprint, "tls", false),
      http: Map.get(fingerprint, "http", false)
    }
  end

  defp build_visibility_fingerprint_config(_), do: nil

  defp build_visibility_dpi_config(dpi) when is_map(dpi) do
    %Monitoring.VisibilityDpiConfig{
      enabled: Map.get(dpi, "enabled", false) == true,
      protocols:
        dpi
        |> Map.get("protocols", [])
        |> List.wrap()
        |> Enum.flat_map(fn
          protocol when is_binary(protocol) ->
            protocol = String.trim(protocol)
            if protocol == "", do: [], else: [protocol]

          _ ->
            []
        end)
    }
  end

  defp build_visibility_dpi_config(_), do: nil

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
