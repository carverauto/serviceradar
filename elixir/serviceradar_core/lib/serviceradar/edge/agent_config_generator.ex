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
      {:ok, config} = AgentConfigGenerator.generate_config(agent_id, authenticated_partition_id)

      # Check if config has changed (returns :not_modified or {:ok, config})
      result =
        AgentConfigGenerator.get_config_if_changed(
          agent_id,
          authenticated_partition_id,
          current_version
        )
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compiler
  alias ServiceRadar.AgentConfig.Compilers.SNMPCompiler
  alias ServiceRadar.AgentConfig.Compilers.SysmonCompiler
  alias ServiceRadar.AgentConfig.ConfigServer
  alias ServiceRadar.Credentials.SecretBroker
  alias ServiceRadar.Edge.AgentArtifacts
  alias ServiceRadar.Edge.DirectLeafEligibility
  alias ServiceRadar.Edge.DirectLeafScope
  alias ServiceRadar.Edge.RemoteConsoleTargetResolver
  alias ServiceRadar.Edge.SNMPProtoMapper
  alias ServiceRadar.Infrastructure.Agent
  alias ServiceRadar.Integrations.SyncConfigGenerator
  alias ServiceRadar.Inventory.BumblebeeCatalogSnapshot
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.ProxmoxSourceScopeResolver
  alias ServiceRadar.Monitoring.ServiceCheck
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.ConfigSchema
  alias ServiceRadar.Plugins.CredentialBrokerDelivery
  alias ServiceRadar.Plugins.MapUtils
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.ProxmoxHostAuthority
  alias ServiceRadar.Plugins.RetiredNativeAddons
  alias ServiceRadar.Plugins.SecretRefs
  alias ServiceRadar.Plugins.StorageToken

  require Ash.Query
  require Logger

  # Default intervals
  @default_heartbeat_interval_sec 30
  @default_config_poll_interval_sec 300
  # Process-scoped accumulator for credential-resolution audits deferred during
  # config generation. Flushed only when the generated config is actually
  # delivered to the agent, so `:not_modified` polls don't write an audit row per
  # credential per poll (fj #4428).
  @audit_collector_key :agent_config_deferred_credential_audits
  @required_addons_config_key :required_agent_addons
  @default_required_addon_ids ["otel-collector"]
  @controller_secret_schema %{
    "properties" => %{
      "api_token_secret_ref" => %{"secretRef" => true}
    }
  }
  @awx_inventory_sync_plugin_id "awx-inventory-sync"
  @awx_inventory_sync_entrypoint "inventory_sync"
  @awx_inventory_host_credential_sentinel "__SERVICERADAR_AWX_INVENTORY_HOST_CREDENTIAL__"
  @awx_inventory_host_credentials_key "_serviceradar_host_credentials"
  @awx_inventory_host_credentials_schema "serviceradar.awx_inventory_host_credentials.v1"

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
          host_params: map() | nil,
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
  def generate_config(_agent_id), do: {:error, :authenticated_partition_required}

  @spec generate_config(String.t(), String.t()) :: {:ok, agent_config()} | {:error, term()}
  def generate_config(agent_id, partition_id) do
    with {:ok, partition_id} <- authenticated_partition(partition_id) do
      {config, audits} = generate_collecting_audits(agent_id, partition_id)
      commit_deferred_audits(audits)
      {:ok, config}
    end
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
    _ = {agent_id, current_version}
    {:error, :authenticated_partition_required}
  end

  @spec get_config_if_changed(String.t(), String.t(), String.t()) ::
          :not_modified | {:ok, agent_config()} | {:error, term()}
  def get_config_if_changed(agent_id, partition_id, current_version) do
    with {:ok, partition_id} <- authenticated_partition(partition_id) do
      do_get_config_if_changed(agent_id, partition_id, current_version)
    end
  end

  defp do_get_config_if_changed(agent_id, partition_id, current_version) do
    {config, deferred_audits} = generate_collecting_audits(agent_id, partition_id)

    if config.config_version == current_version do
      # Nothing delivered this poll — drop the audits collected while resolving
      # credentials for the version hash (fj #4428).
      Logger.debug("Config not modified for agent #{agent_id}, version: #{current_version}")
      :not_modified
    else
      commit_deferred_audits(deferred_audits)
      # An empty current_version is a first fetch / not-yet-committed agent (e.g. a config
      # section that deferred its version commit), not an operator config change. It would
      # otherwise log "Config changed ...:  -> v<hash>" on every poll, so keep it at debug
      # and reserve info for a genuine version-to-version change (fj #4301).
      if current_version == "" do
        Logger.debug(
          "Config changed for agent #{agent_id}: #{current_version} -> #{config.config_version}"
        )
      else
        Logger.info(
          "Config changed for agent #{agent_id}: #{current_version} -> #{config.config_version}"
        )
      end

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
      addons: to_proto_addons(Map.get(config, :addons, []), Map.get(config, :agent_id))
    }
  end

  @doc """
  Generates and converts the current agent config directly into a proto response.
  """
  @spec generate_proto_response(String.t()) :: {:error, :authenticated_partition_required}
  def generate_proto_response(_agent_id), do: {:error, :authenticated_partition_required}

  @spec generate_proto_response(String.t(), String.t()) ::
          Monitoring.AgentConfigResponse.t() | {:error, term()}
  def generate_proto_response(agent_id, partition_id) when is_binary(agent_id) do
    with {:ok, partition_id} <- authenticated_partition(partition_id) do
      {config, audits} = generate_collecting_audits(agent_id, partition_id)
      commit_deferred_audits(audits)
      to_proto_response(config)
    end
  end

  defp generate_config!(agent_id, partition_id) do
    checks = load_agent_checks!(agent_id)
    sync_payload = load_sync_payload!(agent_id)
    sweep_config = load_sweep_config(partition_id, agent_id)
    mapper_config = load_mapper_config(partition_id, agent_id)
    sysmon_config = load_sysmon_config(partition_id, agent_id)
    snmp_config = load_snmp_config(partition_id, agent_id)
    visibility_config = load_visibility_config(partition_id, agent_id)
    bumblebee_config = load_bumblebee_config(partition_id, agent_id)
    endpoint_inventory_config = load_endpoint_inventory_config(partition_id, agent_id)
    plugin_assignments = load_plugin_assignments(agent_id, partition_id)
    plugin_engine_limits = load_plugin_engine_limits(agent_id)
    addon_assignments = load_addon_assignments(agent_id)

    plugin_config = %{
      assignments: plugin_assignments,
      engine_limits: plugin_engine_limits
    }

    checks
    |> build_config(
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
    # Carried for delivery-refusal telemetry/log context in `to_proto_addons/2`
    # (fj#4383); deliberately not a version-hash input, so it cannot perturb
    # config-change detection.
    |> Map.put(:agent_id, agent_id)
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

  defp load_plugin_assignments(agent_id, partition_id) do
    actor = SystemActor.system(:agent_config_generator)

    assignments =
      PluginAssignment
      |> Ash.Query.for_read(
        :by_edge_principal,
        %{agent_uid: agent_id, partition_id: partition_id},
        actor: actor
      )
      |> Ash.Query.filter(enabled == true)
      |> Ash.Query.sort(updated_at: :desc, inserted_at: :desc)
      |> Ash.Query.load(:plugin_package)
      |> Ash.read!()

    assignments
    |> Enum.map(&ensure_plugin_package_loaded(&1, actor))
    |> Enum.filter(&has_approved_package?/1)
    |> Enum.uniq_by(&logical_plugin_id/1)
    |> Enum.map(&build_plugin_assignment_config/1)
    |> Enum.reject(&is_nil/1)
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
      |> Ash.Query.sort(source: :asc, updated_at: :desc, inserted_at: :desc)
      |> Ash.Query.load([:addon_package, :rollout_package, edge_site: :nats_leaf_server])
      |> Ash.read!()
      |> Enum.map(&ensure_addon_package_loaded(&1, actor))
      |> Enum.map(&apply_rollout_package_override/1)
      |> Enum.reject(&retired_addon_assignment?/1)
      |> Enum.filter(&approved_addon_package?/1)
      |> select_effective_addon_assignments()

    assigned_addon_ids = MapSet.new(assignments, &logical_addon_id/1)
    required_addons = required_agent_addon_specs(assigned_addon_ids)

    if assignments == [] and required_addons == [] do
      []
    else
      profile = resolve_agent_addon_profile(agent_id, actor)

      assignment_configs =
        assignments
        |> Enum.map(&build_deliverable_addon_assignment_config(&1, profile))
        |> Enum.reject(&is_nil/1)

      required_configs =
        required_addons
        |> Enum.map(&build_deliverable_required_addon_config(&1, profile, actor))
        |> Enum.reject(&is_nil/1)

      assignment_configs ++ required_configs
    end
  rescue
    e ->
      Logger.warning("Error loading addon assignments: #{inspect(e)}")
      []
  end

  defp required_agent_addon_specs(assigned_addon_ids) do
    :serviceradar_core
    |> Application.get_env(@required_addons_config_key, @default_required_addon_ids)
    |> List.wrap()
    |> Enum.map(&normalize_required_agent_addon_spec/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&RetiredNativeAddons.retired?(&1.addon_id))
    |> Enum.reject(&MapSet.member?(assigned_addon_ids, &1.addon_id))
    |> Enum.uniq_by(& &1.addon_id)
  end

  defp normalize_required_agent_addon_spec(addon_id) when is_binary(addon_id) do
    case String.trim(addon_id) do
      "" -> nil
      addon_id -> %{addon_id: addon_id, enabled: true, args: [], params: %{}}
    end
  end

  defp normalize_required_agent_addon_spec(spec) when is_map(spec) do
    spec = normalize_map(spec)
    addon_id = spec |> fetch_map_value(:addon_id, "") |> to_string() |> String.trim()

    if addon_id == "" do
      nil
    else
      %{
        addon_id: addon_id,
        enabled: fetch_map_value(spec, :enabled, true) != false,
        args: normalize_string_list(fetch_map_value(spec, :args, [])),
        params: normalize_map(fetch_map_value(spec, :params, %{}))
      }
    end
  end

  defp normalize_required_agent_addon_spec(_spec), do: nil

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

  # The authoritative assignment/profile package remains stable while a rollout
  # advances one target at a time. Config generation alone resolves the persisted
  # per-target override, so profile reconciliation cannot bypass the batch gate.
  defp apply_rollout_package_override(
         %AddonAssignment{rollout_id: rollout_id, rollout_package: %AddonPackage{} = package} =
           assignment
       )
       when not is_nil(rollout_id), do: %{assignment | addon_package: package}

  defp apply_rollout_package_override(%AddonAssignment{} = assignment), do: assignment

  defp approved_addon_package?(%AddonAssignment{
         addon_package: %AddonPackage{status: :approved, verification_status: "blob_missing"}
       }) do
    Logger.warning(
      "Skipping addon assignment because package artifact is missing from object storage"
    )

    false
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

  defp retired_addon_assignment?(%AddonAssignment{} = assignment) do
    addon_id = logical_addon_id(assignment)

    if RetiredNativeAddons.retired?(addon_id) do
      Logger.debug(
        "Skipping retired add-on assignment #{addon_id}: #{RetiredNativeAddons.reason(addon_id)}"
      )

      true
    else
      false
    end
  end

  @doc false
  # One effective assignment per logical add-on id, chosen by a deterministic
  # total order so duplicate enabled profiles (legacy data the enable-path
  # validation now prevents) resolve stably instead of by DB read order.
  def select_effective_addon_assignments(assignments) do
    ranked = Enum.sort_by(assignments, &addon_assignment_precedence/1)
    effective = Enum.uniq_by(ranked, &logical_addon_id/1)

    ranked
    |> Enum.group_by(&logical_addon_id/1)
    |> Enum.each(fn
      {_addon_id, [_winner]} ->
        :ok

      {addon_id, [winner | shadowed]} ->
        Enum.each(shadowed, &warn_shadowed_addon_assignment(addon_id, &1, winner))
    end)

    effective
  end

  # Config generation runs on every agent poll, so persistent legacy duplicates
  # would repeat this warning proportional to agents x poll rate. Mirror the
  # addon_delivery_marker_key pattern: warn once per shadowing pair via a
  # persistent_term marker, then drop to debug.
  defp warn_shadowed_addon_assignment(addon_id, shadowed, winner) do
    message =
      "Duplicate enabled add-on assignments for #{addon_id}: " <>
        "#{describe_addon_assignment(shadowed)} is shadowed by #{describe_addon_assignment(winner)}"

    marker_key = shadowed_addon_marker_key(addon_id, shadowed.id, winner.id)

    if :persistent_term.get(marker_key, :none) == :warned do
      Logger.debug(message)
    else
      :persistent_term.put(marker_key, :warned)
      Logger.warning(message)
    end
  end

  defp shadowed_addon_marker_key(addon_id, shadowed_assignment_id, winner_assignment_id),
    do: {__MODULE__, :shadowed_addon, addon_id, shadowed_assignment_id, winner_assignment_id}

  defp describe_addon_assignment(
         %AddonAssignment{source: :profile, profile_metadata: %{"profile_name" => name}} =
           assignment
       )
       when is_binary(name) do
    "profile \"#{name}\" (assignment #{assignment.id})"
  end

  defp describe_addon_assignment(%AddonAssignment{source: source} = assignment) do
    "#{source} assignment #{assignment.id}"
  end

  defp addon_assignment_precedence(%AddonAssignment{} = assignment) do
    {rank, priority} = addon_assignment_rank(assignment)
    {rank, priority, -addon_assignment_recency(assignment), to_string(assignment.id)}
  end

  defp addon_assignment_rank(%AddonAssignment{source: :manual}), do: {0, 0}

  defp addon_assignment_rank(%AddonAssignment{source: :profile, profile_metadata: metadata})
       when is_map(metadata) do
    {1, map_int(metadata, "priority", 100)}
  end

  defp addon_assignment_rank(%AddonAssignment{source: :profile}), do: {1, 100}
  defp addon_assignment_rank(%AddonAssignment{}), do: {2, 100}

  defp addon_assignment_recency(%AddonAssignment{updated_at: %DateTime{} = updated_at}),
    do: DateTime.to_unix(updated_at, :microsecond)

  defp addon_assignment_recency(%AddonAssignment{inserted_at: %DateTime{} = inserted_at}),
    do: DateTime.to_unix(inserted_at, :microsecond)

  defp addon_assignment_recency(_assignment), do: 0

  defp build_deliverable_addon_assignment_config(%AddonAssignment{} = assignment, profile) do
    package = assignment.addon_package
    artifact = select_addon_artifact(package.artifacts, profile.os, profile.arch)
    params = normalize_map(assignment.params)

    with {:ok, params} <- prepare_direct_leaf_params(assignment, params),
         true <- deliverable_addon_assignment?(assignment, profile, artifact) do
      build_addon_config(logical_addon_id(assignment), package, artifact,
        enabled: assignment.enabled,
        args: assignment.args || [],
        params: params,
        assignment_id: assignment.id
      )
    else
      _ -> nil
    end
  end

  defp prepare_direct_leaf_params(%AddonAssignment{} = assignment, params) do
    edge_site = Map.get(assignment, :edge_site)
    leaf_server = if is_map(edge_site), do: Map.get(edge_site, :nats_leaf_server)

    case DirectLeafEligibility.validate(params, edge_site, leaf_server) do
      {:ok, params} ->
        if DirectLeafEligibility.direct?(params) do
          if direct_access_ready?(assignment, params) do
            case inject_direct_leaf_identity(assignment, params) do
              {:ok, params} ->
                {:ok, params}

              {:error, reason} ->
                report_direct_leaf_pending(assignment, reason)
                {:error, reason}
            end
          else
            report_direct_leaf_pending(assignment, :direct_leaf_access_not_ready)
            {:error, :direct_leaf_access_not_ready}
          end
        else
          {:ok, params}
        end

      {:error, reason} ->
        report_direct_leaf_pending(assignment, reason)
        {:error, reason}
    end
  end

  defp direct_access_ready?(%AddonAssignment{} = assignment, params) do
    status = Map.get(assignment, :direct_access_status, :not_requested)
    expires_at = Map.get(assignment, :direct_access_expires_at)

    with :ready <- status,
         %DateTime{} <- expires_at,
         :gt <- DateTime.compare(expires_at, DateTime.utc_now()),
         {:ok, scope} <- DirectLeafScope.build(params),
         true <- Map.get(assignment, :direct_subject_scope, %{}) == scope do
      true
    else
      _ -> false
    end
  end

  defp inject_direct_leaf_identity(%AddonAssignment{} = assignment, params) do
    with {:ok, certificate_pem} <-
           decrypt_direct_identity_field(assignment, :encrypted_direct_certificate_pem),
         {:ok, private_key_pem} <-
           decrypt_direct_identity_field(assignment, :encrypted_direct_private_key_pem),
         {:ok, ca_chain_pem} <-
           decrypt_direct_identity_field(assignment, :encrypted_direct_ca_chain_pem) do
      nats = map_value(params, :nats) || %{}
      tls = map_value(nats, :tls) || %{}

      tls =
        tls
        |> put_map_value(:cert_pem, certificate_pem)
        |> put_map_value(:key_pem, private_key_pem)
        |> put_map_value(:ca_pem, ca_chain_pem)

      {:ok, put_map_value(params, :nats, put_map_value(nats, :tls, tls))}
    end
  end

  defp decrypt_direct_identity_field(assignment, attribute) do
    case Map.get(assignment, attribute) do
      ciphertext when is_binary(ciphertext) and byte_size(ciphertext) > 0 ->
        case ServiceRadar.Vault.decrypt(ciphertext) do
          {:ok, plaintext} when is_binary(plaintext) and byte_size(plaintext) > 0 ->
            {:ok, plaintext}

          _ ->
            {:error, :direct_leaf_identity_decrypt_failed}
        end

      _ ->
        {:error, :direct_leaf_identity_material_missing}
    end
  rescue
    _error -> {:error, :direct_leaf_identity_decrypt_failed}
  end

  defp map_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_value(_map, _key), do: nil

  defp put_map_value(map, key, value) when is_map(map) do
    string_key = Atom.to_string(key)

    if Map.has_key?(map, string_key),
      do: Map.put(map, string_key, value),
      else: Map.put(map, key, value)
  end

  defp report_direct_leaf_pending(%AddonAssignment{} = assignment, reason) do
    addon_id = logical_addon_id(assignment)
    marker = {__MODULE__, :direct_leaf_pending, assignment.id, reason}

    if :persistent_term.get(marker, :none) == :warned do
      Logger.debug(
        "Direct-leaf add-on assignment remains pending: " <>
          "assignment=#{assignment.id} addon=#{addon_id} reason=#{reason}"
      )
    else
      :persistent_term.put(marker, :warned)

      Logger.warning(
        "Direct-leaf add-on assignment is pending: " <>
          "assignment=#{assignment.id} addon=#{addon_id} reason=#{reason}"
      )
    end

    :telemetry.execute(
      [:serviceradar, :addon_config, :direct_leaf_pending],
      %{count: 1},
      %{assignment_id: assignment.id, addon_id: addon_id, reason: reason}
    )
  end

  defp build_deliverable_required_addon_config(%{addon_id: addon_id} = spec, profile, actor) do
    with %AddonPackage{} = package <- load_required_addon_package(addon_id, actor) do
      artifact = select_addon_artifact(package.artifacts, profile.os, profile.arch)

      if deliverable_required_addon_package?(package, profile, artifact) do
        build_addon_config(addon_id, package, artifact,
          enabled: spec.enabled,
          args: spec.args,
          params: spec.params
        )
      end
    end
  end

  defp load_required_addon_package(addon_id, actor) do
    AddonPackage
    |> Ash.Query.for_read(:by_addon_id, %{addon_id: addon_id}, actor: actor)
    |> Ash.Query.filter(status == :approved)
    |> Ash.Query.sort(approved_at: :desc, updated_at: :desc, inserted_at: :desc)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, packages} ->
        packages
        |> Enum.reject(&(&1.verification_status == "blob_missing"))
        |> List.first()

      {:error, error} ->
        Logger.warning(
          "Skipping required add-on #{addon_id}: package lookup failed: #{inspect(error)}"
        )

        nil
    end
    |> case do
      nil ->
        Logger.debug("Skipping required add-on #{addon_id}: no approved package is available")
        nil

      %AddonPackage{} = package ->
        package
    end
  end

  defp build_addon_config(addon_id, %AddonPackage{} = package, artifact, opts) do
    enabled = Keyword.get(opts, :enabled, true)
    args = Keyword.get(opts, :args, [])
    params = Keyword.get(opts, :params, %{})

    # Mint a gateway-proxied download request for the selected per-arch artifact so
    # agents fetch it over HTTPS through the agent-gateway artifact endpoint instead
    # of touching web-ng or object storage directly.
    # nil when no artifact is selected or the storage URL/secret is unconfigured; the
    # agent then falls back to its existing direct-store path.
    download_request = StorageToken.download_addon_request(package.id, artifact[:object_key])

    %{
      addon_id: addon_id,
      version: package.version,
      enabled: enabled,
      binary_path: addon_binary_path(package),
      args: args,
      params: normalize_map(params),
      # Threaded through to `to_proto_addons/2` so assignment params can be
      # schema-coerced at the delivery choke point, right before `config_json`
      # encoding (fj#4381), and validated post-coercion so uncoercible params
      # refuse delivery instead of shipping undecodable JSON (fj#4383).
      config_schema: package.config_schema,
      # nil for required (config-declared) add-ons, which have no assignment row.
      assignment_id: Keyword.get(opts, :assignment_id),
      capabilities: effective_addon_capabilities(package),
      os_capabilities: addon_os_capabilities(package),
      resources: normalize_map(package.resources),
      delivery: package.delivery,
      supervision: package.supervision,
      artifact_object_key: artifact[:object_key],
      artifact_sha256: artifact[:sha256],
      artifact_signature: artifact[:signature],
      target_os: artifact[:os],
      target_arch: artifact[:arch],
      download_url: download_request && download_request.url,
      download_token: download_request && download_request.token
    }
  end

  defp deliverable_addon_assignment?(
         %AddonAssignment{addon_package: %AddonPackage{} = package} = assignment,
         profile,
         artifact
       ) do
    missing_agent_capabilities =
      missing_required_agent_capabilities(package, profile.capabilities)

    cond do
      not agent_platform_allowed?(package, profile.os) ->
        Logger.warning(
          "Skipping addon assignment #{assignment.id}: package #{package.id} does not support agent platform #{inspect(profile.os)}"
        )

        false

      not agent_version_allowed?(package, profile.version) ->
        Logger.warning(
          "Skipping addon assignment #{assignment.id}: package #{package.id} requires base agent #{inspect(addon_base_agent_requirement(package))}, got #{inspect(profile.version)}"
        )

        false

      missing_agent_capabilities != [] ->
        Logger.warning(
          "Skipping addon assignment #{assignment.id}: package #{package.id} requires agent capabilities #{inspect(missing_agent_capabilities)}"
        )

        false

      package.delivery == :pushed_artifact and not artifact_selected?(artifact) ->
        Logger.warning(
          "Skipping addon assignment #{assignment.id}: package #{package.id} has no verified artifact for #{inspect(profile.os)}/#{inspect(profile.arch)}"
        )

        false

      true ->
        true
    end
  end

  defp deliverable_addon_assignment?(_assignment, _profile, _artifact), do: false

  defp deliverable_required_addon_package?(%AddonPackage{} = package, profile, artifact) do
    missing_agent_capabilities =
      missing_required_agent_capabilities(package, profile.capabilities)

    cond do
      not agent_platform_allowed?(package, profile.os) ->
        Logger.warning(
          "Skipping required add-on #{package.addon_id}: package #{package.id} does not support agent platform #{inspect(profile.os)}"
        )

        false

      not agent_version_allowed?(package, profile.version) ->
        Logger.warning(
          "Skipping required add-on #{package.addon_id}: package #{package.id} requires base agent #{inspect(addon_base_agent_requirement(package))}, got #{inspect(profile.version)}"
        )

        false

      missing_agent_capabilities != [] ->
        Logger.warning(
          "Skipping required add-on #{package.addon_id}: package #{package.id} requires agent capabilities #{inspect(missing_agent_capabilities)}"
        )

        false

      package.delivery == :pushed_artifact and not artifact_selected?(artifact) ->
        Logger.warning(
          "Skipping required add-on #{package.addon_id}: package #{package.id} has no verified artifact for #{inspect(profile.os)}/#{inspect(profile.arch)}"
        )

        false

      true ->
        true
    end
  end

  # Resolves the target agent's add-on compatibility profile from registry
  # metadata. Platform comes from metadata because Go agents report runtime
  # OS/arch there; version and capabilities come from first-class agent fields.
  defp resolve_agent_addon_profile(agent_id, actor) do
    case Agent.get_by_uid(agent_id, actor: actor) do
      {:ok, %{metadata: meta} = agent} when is_map(meta) ->
        %{
          os: map_string(meta, "os", nil),
          arch: map_string(meta, "arch", nil),
          version: agent.version,
          capabilities: normalize_string_list(agent.capabilities)
        }

      _ ->
        %{os: nil, arch: nil, version: nil, capabilities: []}
    end
  rescue
    _ -> %{os: nil, arch: nil, version: nil, capabilities: []}
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

  defp artifact_selected?(artifact) when is_map(artifact) do
    fetch_map_value(artifact, :object_key) not in [nil, ""] and
      fetch_map_value(artifact, :sha256) not in [nil, ""]
  end

  defp artifact_selected?(_), do: false

  defp agent_platform_allowed?(%AddonPackage{requires: requires}, agent_os)
       when is_map(requires) do
    case fetch_map_value(requires, :platforms, []) do
      [] ->
        true

      platforms when is_list(platforms) ->
        is_binary(agent_os) and agent_os in Enum.map(platforms, &to_string/1)

      _ ->
        true
    end
  end

  defp agent_platform_allowed?(_package, _agent_os), do: true

  defp agent_version_allowed?(%AddonPackage{} = package, agent_version) do
    case addon_base_agent_requirement(package) do
      nil -> true
      "" -> true
      requirement -> version_requirement_satisfied?(agent_version, requirement)
    end
  end

  defp addon_base_agent_requirement(%AddonPackage{requires: requires}) when is_map(requires) do
    fetch_map_value(requires, :base_agent)
  end

  defp addon_base_agent_requirement(_package), do: nil

  defp missing_required_agent_capabilities(%AddonPackage{} = package, agent_capabilities) do
    actual = agent_capabilities |> normalize_string_list() |> MapSet.new()

    package
    |> required_agent_capabilities()
    |> Enum.reject(&MapSet.member?(actual, &1))
  end

  defp required_agent_capabilities(%AddonPackage{requires: requires}) when is_map(requires) do
    requires
    |> fetch_map_value(:agent_capabilities, [])
    |> normalize_string_list()
  end

  defp required_agent_capabilities(_package), do: []

  defp version_requirement_satisfied?(agent_version, requirement)
       when is_binary(agent_version) and is_binary(requirement) do
    case Regex.run(~r/^\s*>?=\s*v?(\d+)\.(\d+)\.(\d+)(?:[-+][0-9A-Za-z.-]+)?\s*$/, requirement) do
      [_, req_major, req_minor, req_patch] ->
        with {:ok, current} <- parse_semver(agent_version),
             {req_major, ""} <- Integer.parse(req_major),
             {req_minor, ""} <- Integer.parse(req_minor),
             {req_patch, ""} <- Integer.parse(req_patch) do
          current >= {req_major, req_minor, req_patch}
        else
          _ -> false
        end

      _ ->
        true
    end
  end

  defp version_requirement_satisfied?(_agent_version, _requirement), do: false

  defp parse_semver(version) when is_binary(version) do
    case Regex.run(~r/v?(\d+)\.(\d+)\.(\d+)(?:[-+][0-9A-Za-z.-]+)?/, version) do
      [_, major, minor, patch] ->
        with {major, ""} <- Integer.parse(major),
             {minor, ""} <- Integer.parse(minor),
             {patch, ""} <- Integer.parse(patch) do
          {:ok, {major, minor, patch}}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

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

    with {:ok, source_scope} <- resolve_proxmox_assignment_scope(assignment, package),
         resolved_params = resolve_plugin_params(config_schema, assignment.params, assignment),
         {:ok, resolved_params} <-
           maybe_enrich_proxmox_host_authority_targets(
             resolved_params,
             package.plugin_id,
             package.entrypoint,
             assignment,
             source_scope
           ),
         {wasm_params, host_params} =
           partition_plugin_host_params(
             package.plugin_id,
             package.entrypoint,
             resolved_params,
             assignment.id
           ),
         :ok <-
           ensure_proxmox_host_authority(
             package.plugin_id,
             package.entrypoint,
             host_params
           ) do
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
        params: wasm_params,
        host_params: host_params,
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
    else
      # The reason belongs in the MESSAGE, not in Logger keyword metadata: the
      # console metadata allowlist is [:request_id, :node], so a reason: keyword
      # is silently dropped from the deployed release's logs -- which is how this
      # skip stayed opaque while a whole integration sat dead.
      #
      # inspect/1 rather than bare interpolation: two reachable reasons are
      # tuples wrapping arbitrary Ash terms, and a Protocol.UndefinedError raised
      # HERE would unwind into the rescue around the caller and drop every plugin
      # assignment for the agent, not just this one.
      {:error, reason} ->
        Logger.warning(
          "Skipping plugin assignment #{assignment.id}: authoritative source and host " <>
            "binding validation failed: plugin=#{package.plugin_id} " <>
            "entrypoint=#{package.entrypoint} agent=#{assignment.agent_uid} " <>
            "reason=#{inspect(reason)}"
        )

        nil
    end
  end

  defp resolve_proxmox_assignment_scope(
         %PluginAssignment{} = assignment,
         %PluginPackage{} = package
       ) do
    if ProxmoxHostAuthority.assignment?(package.plugin_id, package.entrypoint) do
      ProxmoxSourceScopeResolver.resolve_assignment(assignment,
        actor: SystemActor.system(:proxmox_assignment_source_scope),
        agent_id: assignment.agent_uid,
        partition_id: assignment.partition_id,
        assignment_id: assignment.id,
        plugin_id: package.plugin_id
      )
    else
      {:ok, nil}
    end
  end

  defp ensure_proxmox_host_authority(plugin_id, entrypoint, host_params) do
    if ProxmoxHostAuthority.assignment?(plugin_id, entrypoint) do
      case host_params do
        %{"schema" => "serviceradar.plugin_host_authority.v1", "bindings" => [_ | _]} -> :ok
        _ -> {:error, :proxmox_host_authority_unavailable}
      end
    else
      :ok
    end
  end

  # Scheduled AWX inventory tokens are transported to the trusted agent host in
  # one reserved envelope, but never remain in the params map that backs Wasm
  # get_config. The agent removes the envelope, retains exact origin bindings in
  # host memory, and exposes only the sentinel to the plugin.
  defp partition_plugin_host_params(
         @awx_inventory_sync_plugin_id,
         @awx_inventory_sync_entrypoint,
         params,
         _assignment_id
       )
       when is_map(params) do
    params = normalize_map(params)

    case Map.get(params, "controllers") do
      controllers when is_list(controllers) and controllers != [] ->
        {wasm_controllers, host_controllers} =
          Enum.map_reduce(controllers, [], fn controller, host_controllers ->
            controller = normalize_map(controller)

            host_controller = %{
              "controller_id" => Map.get(controller, "controller_id"),
              "base_url" => Map.get(controller, "base_url"),
              "api_token" => Map.get(controller, "api_token"),
              "insecure_skip_verify" => Map.get(controller, "insecure_skip_verify", false) == true
            }

            wasm_controller =
              controller
              |> Map.drop([
                "credential_broker",
                "api_token_secret_ref",
                "_secret_material",
                "api_token"
              ])
              |> Map.put("api_token", @awx_inventory_host_credential_sentinel)

            {wasm_controller, [host_controller | host_controllers]}
          end)

        host_params = %{
          "schema" => @awx_inventory_host_credentials_schema,
          "controllers" => Enum.reverse(host_controllers)
        }

        wasm_params =
          params
          |> Map.drop([
            @awx_inventory_host_credentials_key,
            "credential_broker",
            "api_token_secret_ref",
            "_secret_material",
            "api_token"
          ])
          |> Map.put("controllers", wasm_controllers)

        {wasm_params, host_params}

      _ ->
        # A malformed assignment must not fall back to exposing an inline
        # secret. The agent will receive no host binding and deny all scheduled
        # AWX HTTP requests for this assignment.
        {%{}, nil}
    end
  end

  defp partition_plugin_host_params(plugin_id, entrypoint, params, assignment_id) do
    if ProxmoxHostAuthority.assignment?(plugin_id, entrypoint) do
      ProxmoxHostAuthority.partition(plugin_id, entrypoint, params, assignment_id)
    else
      {params, nil}
    end
  end

  # Proxmox assignment source UUIDs come only from the current policy assignment
  # and its immutable credential rule. Result-owned or SRQL-projected provenance
  # is overwritten before host authority is built. Console items additionally
  # resolve the authoritative v3 guest -> owner PVE chain; any missing,
  # ambiguous, or cross-source item rejects the whole assignment.
  defp maybe_enrich_proxmox_host_authority_targets(
         params,
         "proxmox-inventory",
         "run_check",
         assignment,
         source_scope
       )
       when is_map(params) and is_map(source_scope) do
    params = normalize_map(params)

    with :ok <- ensure_proxmox_target_collection(params) do
      params
      |> stamp_proxmox_source_scope(source_scope, assignment)
      |> map_proxmox_target_collections(fn item ->
        {:ok, stamp_proxmox_source_scope(item, source_scope, assignment)}
      end)
    end
  end

  defp maybe_enrich_proxmox_host_authority_targets(
         params,
         "proxmox-console",
         "run_console",
         assignment,
         source_scope
       )
       when is_map(params) and is_map(source_scope) do
    params = normalize_map(params)
    actor = SystemActor.system(:proxmox_host_authority_target)

    with :ok <- ensure_proxmox_target_collection(params) do
      params
      |> stamp_proxmox_source_scope(source_scope, assignment)
      |> map_proxmox_target_collections(
        &enrich_proxmox_console_target(&1, actor, source_scope, assignment)
      )
    end
  end

  defp maybe_enrich_proxmox_host_authority_targets(
         _params,
         plugin_id,
         entrypoint,
         _assignment,
         _source_scope
       )
       when plugin_id in ["proxmox-inventory", "proxmox-console"] and
              entrypoint in ["run_check", "run_console"],
       do: {:error, :proxmox_source_scope_unavailable}

  defp maybe_enrich_proxmox_host_authority_targets(
         params,
         _plugin_id,
         _entrypoint,
         _assignment,
         _source_scope
       ),
       do: {:ok, params}

  defp stamp_proxmox_source_scope(map, source_scope, assignment) when is_map(map) do
    map
    |> normalize_map()
    |> Map.put("integration_id", to_string(source_scope.integration_id))
    |> Map.put("controller_id", to_string(source_scope.controller_id))
    |> Map.put("credential_rule_id", to_string(source_scope.credential_rule_id))
    |> Map.put("plugin_assignment_id", to_string(source_scope.assignment_id))
    |> Map.put("agent_id", to_string(assignment.agent_uid))
  end

  defp ensure_proxmox_target_collection(params) do
    targets = List.wrap(Map.get(params, "targets"))

    input_items =
      params
      |> Map.get("inputs")
      |> List.wrap()
      |> Enum.flat_map(fn
        %{} = input -> input |> normalize_map() |> Map.get("items") |> List.wrap()
        _input -> []
      end)

    if Enum.any?(targets ++ input_items, &is_map/1),
      do: :ok,
      else: {:error, :proxmox_assignment_targets_missing}
  end

  defp map_proxmox_target_collections(params, mapper) when is_function(mapper, 1) do
    with {:ok, params} <- map_proxmox_input_items(params, mapper) do
      map_proxmox_direct_targets(params, mapper)
    end
  end

  defp map_proxmox_input_items(params, mapper) do
    case Map.get(params, "inputs") do
      nil ->
        {:ok, params}

      inputs when is_list(inputs) ->
        with {:ok, mapped_inputs} <-
               map_result(inputs, fn
                 %{} = input ->
                   input = normalize_map(input)

                   case Map.get(input, "items") do
                     nil ->
                       {:ok, input}

                     items when is_list(items) ->
                       with {:ok, mapped_items} <- map_result(items, mapper) do
                         {:ok, Map.put(input, "items", mapped_items)}
                       end

                     _items ->
                       {:error, :invalid_proxmox_input_items}
                   end

                 _input ->
                   {:error, :invalid_proxmox_input}
               end) do
          {:ok, Map.put(params, "inputs", mapped_inputs)}
        end

      _inputs ->
        {:error, :invalid_proxmox_inputs}
    end
  end

  defp map_proxmox_direct_targets(params, mapper) do
    case Map.get(params, "targets") do
      nil ->
        {:ok, params}

      targets when is_list(targets) ->
        with {:ok, mapped_targets} <- map_result(targets, mapper) do
          {:ok, Map.put(params, "targets", mapped_targets)}
        end

      _targets ->
        {:error, :invalid_proxmox_targets}
    end
  end

  defp map_result(values, mapper) when is_list(values) and is_function(mapper, 1) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case mapper.(value) do
        {:ok, mapped} -> {:cont, {:ok, [mapped | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enrich_proxmox_console_target(item, actor, source_scope, assignment) when is_map(item) do
    item = normalize_map(item)
    device_uid = Map.get(item, "device_uid") || Map.get(item, "uid") || Map.get(item, "device_id")

    with device_uid when is_binary(device_uid) and device_uid != "" <- device_uid,
         {:ok, %Device{} = device} <- Device.get_by_uid(device_uid, false, actor: actor),
         {:ok, target} <-
           RemoteConsoleTargetResolver.resolve_proxmox(device, %{}, ash_opts: [actor: actor]),
         :ok <- ensure_proxmox_target_source_scope(target, source_scope) do
      controller = Map.get(target, :controller, %{})

      item
      |> stamp_proxmox_source_scope(source_scope, assignment)
      |> put_present_string("device_uid", device.uid)
      |> put_present_string("proxmox_base_url", Map.get(controller, :base_url))
      |> put_present_string("integration_id", Map.get(target, :integration_id))
      |> put_present_string("identity_version", Map.get(target, :identity_version))
      |> put_present_string("identity_state", Map.get(target, :identity_state))
      |> put_present_string("controller_id", Map.get(target, :controller_id))
      |> put_present_string("provider_ref", Map.get(target, :provider_ref))
      |> put_present_string("provider_instance_ref", Map.get(target, :provider_instance_ref))
      |> put_present_string("native_cluster_id", Map.get(target, :native_cluster_id))
      |> put_present_string("object_kind", Map.get(target, :object_kind))
      |> put_present_string("native_object_id", Map.get(target, :native_object_id))
      |> put_present_string("inventory_row_id", Map.get(target, :inventory_row_id))
      |> put_present_string("owner_host_id", Map.get(target, :owner_host_id))
      |> put_present_string("node", Map.get(target, :node))
      |> put_present_string("cluster", Map.get(target, :cluster))
      |> put_present_string("vmid", Map.get(target, :vmid))
      |> put_present_string("target_kind", Map.get(target, :target_kind))
      |> put_present_string("controller_device_uid", Map.get(controller, :device_uid))
      |> put_present_string("controller_integration_id", Map.get(controller, :integration_id))
      |> put_present_string("controller_identity_version", Map.get(controller, :identity_version))
      |> put_present_string("controller_identity_state", Map.get(controller, :identity_state))
      |> put_present_string("controller_provider_ref", Map.get(controller, :provider_ref))
      |> put_present_string(
        "controller_provider_instance_ref",
        Map.get(controller, :provider_instance_ref)
      )
      |> put_present_string(
        "controller_native_cluster_id",
        Map.get(controller, :native_cluster_id)
      )
      |> put_present_string("controller_object_kind", Map.get(controller, :object_kind))
      |> put_present_string("controller_native_object_id", Map.get(controller, :native_object_id))
      |> put_present_string(
        "controller_virtualization_host_id",
        Map.get(controller, :virtualization_host_id)
      )
      |> then(&{:ok, &1})
    else
      _ -> {:error, :authoritative_proxmox_console_target_unavailable}
    end
  end

  defp enrich_proxmox_console_target(_item, _actor, _source_scope, _assignment),
    do: {:error, :invalid_proxmox_console_target}

  defp ensure_proxmox_target_source_scope(target, source_scope) do
    if target.integration_id == source_scope.integration_id and
         target.controller_id == source_scope.controller_id,
       do: :ok,
       else: {:error, :proxmox_console_source_scope_mismatch}
  end

  defp put_present_string(map, _key, nil), do: map

  defp put_present_string(map, key, value) do
    value = if is_atom(value), do: Atom.to_string(value), else: to_string(value)
    value = String.trim(value)
    if value == "", do: map, else: Map.put(map, key, value)
  end

  defp resolve_plugin_params(config_schema, params, %PluginAssignment{} = assignment) do
    params = normalize_map(params)
    package = assignment.plugin_package

    if policy_assignment?(assignment) and
         ProxmoxHostAuthority.assignment?(package.plugin_id, package.entrypoint) do
      # Proxmox credentials are resolved only by the trusted agent-side broker
      # connector. Config delivery refreshes the short-lived grant, but never
      # resolves the referenced secret into control-plane params or Wasm memory.
      {refreshed_params, _grant} =
        CredentialBrokerDelivery.refresh_embedded_grant(params,
          agent_id: assignment.agent_uid,
          consumer_id: logical_plugin_id(assignment)
        )

      refreshed_params
    else
      config_schema = maybe_add_policy_credential_secret_fields(config_schema, params, assignment)
      params = materialize_controller_credentials(params, assignment)
      {params, resolve_opts} = materialize_credential_broker_grant(params, assignment)

      case SecretRefs.resolve_runtime_params(config_schema, params, resolve_opts) do
        {:ok, resolved} ->
          resolved

        {:error, errors} ->
          Logger.warning(
            "Failed to resolve plugin secret refs for assignment #{assignment.id}: #{Enum.join(errors, "; ")}"
          )

          SecretRefs.public_params(params)
      end
    end
  end

  defp policy_assignment?(%PluginAssignment{source: source}), do: source in [:policy, "policy"]

  # Task 3.2 (refactor-device-identity-reconciliation): policy assignments carry
  # a short-TTL credential-broker grant payload minted at reconcile time.
  # Scheduled WASM plugin runs never call the broker themselves, so config
  # delivery must (a) never embed an already-expired grant payload — re-mint on
  # expiry — and (b) resolve the granted secret to runtime material (e.g.
  # `api_token`) with an audit row per resolution.
  defp materialize_credential_broker_grant(params, %PluginAssignment{source: source} = assignment)
       when source in [:policy, "policy"] do
    if policy_credential_broker_assignment?(params) do
      case CredentialBrokerDelivery.refresh_embedded_grant(params,
             agent_id: assignment.agent_uid,
             consumer_id: logical_plugin_id(assignment)
           ) do
        {refreshed_params, nil} ->
          {refreshed_params, []}

        {refreshed_params, grant} ->
          {refreshed_params,
           [
             grant: grant,
             broker_opts:
               grant
               |> CredentialBrokerDelivery.broker_resolution_opts(agent_id: assignment.agent_uid)
               |> with_audit_sink()
           ]}
      end
    else
      {params, []}
    end
  end

  defp materialize_credential_broker_grant(params, _assignment), do: {params, []}

  # Adds a deferred-audit sink to broker opts so credential-resolution audits are
  # collected during generation and only committed on delivery (fj #4428).
  defp with_audit_sink(broker_opts) when is_list(broker_opts),
    do: Keyword.put(broker_opts, :audit_sink, &deferred_audit_sink/1)

  # Sink invoked by SecretBroker during resolution. When a collector is active
  # (config generation), append the audit; otherwise write it immediately so any
  # resolution outside a delivery path stays audited (defensive).
  defp deferred_audit_sink(attrs) do
    case Process.get(@audit_collector_key) do
      collected when is_list(collected) ->
        Process.put(@audit_collector_key, [attrs | collected])

      _ ->
        SecretBroker.write_audit(attrs)
    end

    :ok
  end

  # Generates a config with a deferred-audit collector active, returning the
  # config plus the audits collected during generation (chronological order).
  # The collector is always restored, even on error.
  defp generate_collecting_audits(agent_id, partition_id) do
    previous = Process.put(@audit_collector_key, [])

    try do
      config = generate_config!(agent_id, partition_id)
      {config, Enum.reverse(Process.get(@audit_collector_key, []))}
    after
      case previous do
        nil -> Process.delete(@audit_collector_key)
        prev -> Process.put(@audit_collector_key, prev)
      end
    end
  end

  defp authenticated_partition(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :authenticated_partition_required}
      partition_id -> {:ok, partition_id}
    end
  end

  defp authenticated_partition(_value), do: {:error, :authenticated_partition_required}

  defp commit_deferred_audits(audits), do: Enum.each(audits, &SecretBroker.write_audit/1)

  defp materialize_controller_credentials(params, %PluginAssignment{source: source} = assignment)
       when source in [:policy, "policy"] do
    {params, grants} =
      CredentialBrokerDelivery.refresh_controller_grants(params,
        agent_id: assignment.agent_uid,
        consumer_id: logical_plugin_id(assignment)
      )

    resolve_controller_credentials(params, grants, assignment)
  end

  defp materialize_controller_credentials(params, _assignment), do: params

  defp resolve_controller_credentials(params, [], _assignment), do: params

  defp resolve_controller_credentials(params, grants, assignment) do
    grants_by_index = Map.new(grants)

    case Map.get(params, "controllers") do
      controllers when is_list(controllers) ->
        controllers =
          controllers
          |> Enum.with_index()
          |> Enum.map(fn {controller, index} ->
            resolve_controller_credential(
              controller,
              Map.get(grants_by_index, index),
              assignment,
              index
            )
          end)

        Map.put(params, "controllers", controllers)

      _ ->
        params
    end
  end

  defp resolve_controller_credential(controller, nil, _assignment, _index), do: controller

  defp resolve_controller_credential(controller, grant, assignment, index)
       when is_map(controller) do
    resolve_opts = [
      grant: grant,
      broker_opts:
        grant
        |> CredentialBrokerDelivery.broker_resolution_opts(agent_id: assignment.agent_uid)
        |> with_audit_sink()
    ]

    case SecretRefs.resolve_runtime_params(@controller_secret_schema, controller, resolve_opts) do
      {:ok, resolved} ->
        resolved

      {:error, errors} ->
        Logger.warning(
          "Failed to resolve controller plugin secret refs for assignment #{assignment.id}: #{Enum.join(errors, "; ")}",
          controller_index: index,
          controller_id:
            Map.get(controller, "controller_id") || Map.get(controller, :controller_id)
        )

        SecretRefs.public_params(controller)
    end
  end

  defp resolve_controller_credential(controller, _grant, _assignment, _index), do: controller

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

  # These four names are a hardcoded coupling between a plugin manifest and
  # config delivery, and nothing validates it.
  #
  # A manifest's `$source: secret_ref` param may be named anything: the
  # integration descriptor validates the template, not the key. Resolution only
  # works because the key lands in this list, which synthesizes the secretRef
  # property the delivered config schema needs. Rename the param in a manifest
  # -- `api_token_secret_ref` to `token_secret_ref`, say -- and the manifest
  # still validates, the assignment still materializes, and the credential is
  # silently never resolved at delivery.
  #
  # A manifest adding a secret_ref param must therefore use one of these names,
  # or add its name here in the same change. Do not generalize this to "any key
  # ending in _secret_ref": the allowlist is what keeps a package from teaching
  # config generation to mint secretRef properties of its own choosing.
  defp maybe_add_policy_secret_field_from_params(config_schema, params) do
    params = normalize_map(params)

    if policy_credential_broker_assignment?(params) do
      config_schema
      |> maybe_add_secret_ref_property(params, "api_token_secret_ref")
      |> maybe_add_secret_ref_property(params, "credential_secret")
      |> maybe_add_secret_ref_property(params, "password_secret_ref")
      |> maybe_add_secret_ref_property(params, "api_key_secret_ref")
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
         SecretRefs.secret_ref?(fetch_map_value(params, :credential_secret)) or
         SecretRefs.secret_ref?(fetch_map_value(params, :password_secret_ref)) or
         SecretRefs.secret_ref?(fetch_map_value(params, :api_key_secret_ref)))
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

  @doc """
  Computes the permission scope that is actually delivered to an agent.

  Security-sensitive callers that mint a second, narrower authority (for
  example a notification credential grant) must use this function rather than
  reimplementing the package/assignment narrowing rules.
  """
  @spec effective_permissions(map(), map(), map()) :: %{
          allowed_domains: [String.t()],
          allowed_networks: [String.t()],
          allowed_ports: [integer()]
        }
  def effective_permissions(assignment, package, manifest)
      when is_map(assignment) and is_map(package) and is_map(manifest) do
    manifest
    |> fetch_map_value(:permissions, %{})
    |> normalize_permissions()
    |> narrow_permissions(Map.get(package, :approved_permissions, %{}))
    |> narrow_permissions(Map.get(assignment, :permissions_override, %{}))
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

  # Wildcard-aware narrowing of a manifest scope (`base`) by an operator/assignment
  # override. Security-sensitive: the result must never exceed what BOTH the
  # manifest and the override allow.
  #
  #   * `base == []`          -> `[]`       (manifest allows nothing)
  #   * `"*"` in override     -> `base`     (override allows anything => keep manifest scope)
  #   * `"*"` in base         -> `override` (manifest allows anything => narrow to approved set)
  #   * otherwise             -> `base ∩ override`
  #
  # Order matters: `base == []` is checked first so an empty manifest scope always
  # denies, and the `"*"`-in-override case is checked before `"*"`-in-base so a
  # wildcard-vs-wildcard narrow resolves to the manifest scope (`base`).
  defp narrow_string_scope(base, {:present, override}) do
    override = normalize_string_list(override)

    cond do
      base == [] ->
        []

      "*" in override ->
        base

      "*" in base ->
        override

      true ->
        allowed = MapSet.new(override)
        Enum.filter(base, &MapSet.member?(allowed, &1))
    end
  end

  defp narrow_port_scope(base, :absent), do: base

  defp narrow_port_scope(base, {:present, override}) do
    override = normalize_int_list(override)

    cond do
      base == [] ->
        []

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
        # host_params is transport material for the typed plugin_config proto,
        # never part of the generic JSON config surface.
        "assignments" => Enum.map(plugin_assignments, &public_plugin_assignment/1),
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

  defp public_plugin_assignment(assignment) when is_map(assignment) do
    assignment
    |> Map.delete(:host_params)
    |> Map.delete("host_params")
  end

  defp public_plugin_assignment(assignment), do: assignment

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
    require Logger
    # Sort checks by ID for deterministic ordering
    sorted_checks = Enum.sort_by(check_configs, & &1.check_id)

    sorted_plugins =
      plugin_assignments
      |> Enum.sort_by(& &1.assignment_id)
      |> Enum.map(&plugin_assignment_version_projection/1)

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
      # NOTE: download_token_epoch is intentionally NOT folded into the version
      # hash. Doing so re-versioned the whole config every ~half-TTL (~7 min),
      # which relaunched every agent's running plugins on a timer — a proxmox/AWX/
      # camera inventory run longer than that window could never finish. The
      # artifact download token is still minted fresh on every generation and
      # delivered in the config; an agent applies a fresh token whenever a real
      # change re-versions the config (a new content_hash — which is when a
      # download is actually needed) and on its startup config fetch. Cached-wasm
      # plugins therefore no longer re-version for a token rotation they never use.
    }

    "v" <> Compiler.content_hash(version_payload)
  end

  # Task 3.3 (refactor-device-identity-reconciliation): artifact download
  # tokens are HMAC-signed with a bounded TTL and minted fresh on every config
  # generation, but agents only *apply* them when the config version changes —
  # `not_modified` polls never refresh the token an agent is holding. Folding a
  # coarse time epoch into the version hash whenever any assignment carries a
  # signed download request guarantees the config re-versions (and the agent
  # receives a freshly minted token) well before the previous token's TTL
  # elapses. The epoch is half the token TTL, floored at 5 minutes.
  @doc false
  @spec download_token_epoch([map()], [map()], non_neg_integer() | nil) :: non_neg_integer()
  def download_token_epoch(plugin_assignments, addon_assignments, now_seconds \\ nil) do
    has_download_token? =
      Enum.any?(List.wrap(plugin_assignments), &assignment_download_token?/1) or
        Enum.any?(List.wrap(addon_assignments), &assignment_download_token?/1)

    if has_download_token? do
      now_seconds = now_seconds || System.os_time(:second)
      div(now_seconds, download_token_epoch_seconds())
    else
      0
    end
  end

  @doc false
  @spec download_token_epoch_seconds() :: pos_integer()
  def download_token_epoch_seconds do
    configured =
      :serviceradar_core
      |> Application.get_env(:plugin_storage, [])
      |> plugin_storage_epoch_override()

    case configured do
      seconds when is_integer(seconds) and seconds > 0 ->
        seconds

      _ ->
        max(div(StorageToken.download_ttl_seconds(), 2), 300)
    end
  end

  defp plugin_storage_epoch_override(config) when is_list(config),
    do: Keyword.get(config, :download_token_epoch_seconds)

  defp plugin_storage_epoch_override(_config), do: nil

  defp assignment_download_token?(assignment) when is_map(assignment) do
    token = Map.get(assignment, :download_token) || Map.get(assignment, "download_token")
    is_binary(token) and token != ""
  end

  defp assignment_download_token?(_assignment), do: false

  # Strip the per-poll gateway download fields before hashing: download_token is a
  # freshly-minted (rotating) signed token each generation and download_url, while
  # stable, is derived from it — including them would change the config version hash
  # every poll and cause a polling agent to perpetually relaunch. The artifact
  # object_key/sha256/signature (which DO drive re-versioning on a real change) stay
  # in the hashed map. binary_path is included intentionally: a binary/install_path
  # (or per-arch artifact) change must re-version so a polling agent stops getting
  # `not_modified` and relaunches the new executable.
  defp stable_addon_assignment(assignment) when is_map(assignment) do
    # Recurse the WHOLE assignment through the volatile strip — addon params
    # nest per-generation values (artifact download URLs/tokens, re-minted
    # credential-broker grant timestamps) just like plugin params do. Stripping
    # only the top-level download fields left the `addons` version-hash
    # component rotating on every generation (observed live: 14/14 consecutive
    # generations), which re-pushed the config and restarted running plugins.
    stable_config_fragment(assignment)
  end

  defp stable_addon_assignment(assignment), do: assignment

  # Per-generation volatile fields that must not perturb the config version
  # hash, stripped at ANY depth. The delivered config still carries fresh
  # values; agents apply them whenever a real change re-versions the config or
  # on their startup fetch. `sync`/`visibility`/`endpoint_inventory`/`addons`
  # embed artifact download URLs+tokens (HMAC-minted fresh each generation)
  # and grant timestamps — observed live rotating the version hash on EVERY
  # generation (14/14 and 16/16 consecutive gens across gateway + core), which
  # re-pushed the config and restarted every running plugin ~1/min, so any
  # inventory run longer than a minute could never finish.
  @volatile_version_keys [
    :compiled_at,
    "compiled_at",
    :generated_at,
    "generated_at",
    :download_url,
    "download_url",
    :download_token,
    "download_token",
    :grant_id,
    "grant_id",
    :expires_at,
    "expires_at",
    :issued_at,
    "issued_at",
    :not_before,
    "not_before"
  ]

  defp stable_config_fragment(%{} = map) do
    map
    |> Map.drop(@volatile_version_keys)
    |> Map.new(fn {key, value} -> {key, stable_config_fragment(value)} end)
  end

  defp stable_config_fragment(list) when is_list(list),
    do: Enum.map(list, &stable_config_fragment/1)

  defp stable_config_fragment(value), do: value

  @doc false
  @spec plugin_assignment_version_projection(term()) :: term()
  def plugin_assignment_version_projection(assignment) when is_map(assignment) do
    assignment
    |> Map.delete(:download_url)
    |> Map.delete("download_url")
    |> Map.delete(:download_token)
    |> Map.delete("download_token")
    |> stable_assignment_params()
    |> fingerprint_host_only_params()
  end

  def plugin_assignment_version_projection(assignment), do: assignment

  # The raw token is required only in the typed proto delivered to the trusted
  # agent host. Version computation needs token-rotation sensitivity, not the
  # credential itself, so replace every host-only api_token value with a
  # deterministic fixed-width fingerprint before canonical JSON hashing.
  defp fingerprint_host_only_params(assignment) do
    assignment
    |> fingerprint_host_only_params_key(:host_params)
    |> fingerprint_host_only_params_key("host_params")
  end

  defp fingerprint_host_only_params_key(assignment, key) do
    case Map.fetch(assignment, key) do
      {:ok, host_params} -> Map.put(assignment, key, fingerprint_host_param_value(host_params))
      :error -> assignment
    end
  end

  defp fingerprint_host_param_value(%{} = value) do
    Map.new(value, fn
      {key, secret} when key in [:api_token, "api_token"] ->
        {key, host_param_secret_fingerprint(secret)}

      {key, nested} ->
        {key, fingerprint_host_param_value(nested)}
    end)
  end

  defp fingerprint_host_param_value(value) when is_list(value),
    do: Enum.map(value, &fingerprint_host_param_value/1)

  defp fingerprint_host_param_value(value), do: value

  defp host_param_secret_fingerprint(secret) when is_binary(secret) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, secret), case: :lower)
  end

  defp host_param_secret_fingerprint(secret) do
    encoded = :erlang.term_to_binary(secret, [:deterministic])
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, encoded), case: :lower)
  end

  # The delivered `credential_broker` grant payload rotates whenever the
  # embedded grant is re-minted on expiry (task 3.2), which can happen on every
  # generation for short-TTL grants. Like download_token above, it must not
  # perturb the config version hash or polling agents would refetch (and
  # relaunch plugins) perpetually. The stable inputs that should re-version the
  # config — the secret ref, targets, template fields — remain hashed.
  defp stable_assignment_params(assignment) do
    case Map.get(assignment, :params) || Map.get(assignment, "params") do
      params when is_map(params) ->
        # Strip BOTH the rotating grant AND the per-generation `generated_at`/
        # `compiled_at` timestamps. Unlike every other config fragment, plugin
        # assignment params were not run through `stable_config_fragment`, so a
        # fresh `generated_at` stamped on every generation perturbed the version
        # hash — a polling agent saw a "new" config every cycle and relaunched
        # the plugin perpetually (a proxmox/AWX/camera inventory run longer than
        # the poll interval could never finish).
        stable_params =
          params
          |> strip_credential_broker_payload()
          |> stable_config_fragment()

        assignment
        |> Map.replace(:params, stable_params)
        |> Map.replace("params", stable_params)

      _ ->
        assignment
    end
  end

  defp strip_credential_broker_payload(params) do
    params = Map.drop(params, [:credential_broker, "credential_broker"])
    params = strip_controller_credential_broker_payloads(params)

    case Map.get(params, "template") || Map.get(params, :template) do
      template when is_map(template) ->
        stable_template = Map.drop(template, [:credential_broker, "credential_broker"])

        params
        |> Map.replace("template", stable_template)
        |> Map.replace(:template, stable_template)

      _ ->
        params
    end
  end

  defp strip_controller_credential_broker_payloads(params) do
    cond do
      is_list(Map.get(params, "controllers")) ->
        Map.put(
          params,
          "controllers",
          Enum.map(Map.fetch!(params, "controllers"), &strip_nested_credential_broker_payload/1)
        )

      is_list(Map.get(params, :controllers)) ->
        Map.put(
          params,
          :controllers,
          Enum.map(Map.fetch!(params, :controllers), &strip_nested_credential_broker_payload/1)
        )

      true ->
        params
    end
  end

  defp strip_nested_credential_broker_payload(controller) when is_map(controller),
    do: Map.drop(controller, [:credential_broker, "credential_broker"])

  defp strip_nested_credential_broker_payload(controller), do: controller

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

  defp to_proto_addons(addons, agent_id) when is_list(addons) do
    addons
    |> Enum.map(&to_proto_addon(&1, agent_id))
    |> Enum.reject(&is_nil/1)
  end

  defp to_proto_addons(_, _agent_id), do: []

  defp to_proto_addon(addon, agent_id) do
    params = coerce_addon_params(addon)

    case validate_coerced_addon_params(addon, params) do
      :ok ->
        note_addon_delivery_resumed(addon, agent_id)

        %Monitoring.AddonAssignmentConfig{
          addon_id: assignment_string(addon[:addon_id]),
          version: assignment_string(addon[:version]),
          enabled: addon[:enabled] || false,
          binary_path: assignment_string(addon[:binary_path]),
          args: addon[:args] || [],
          config_json: encode_json(params),
          capabilities: addon[:capabilities] || [],
          os_capabilities: addon[:os_capabilities] || [],
          delivery: assignment_enum_string(addon[:delivery]),
          supervision: assignment_enum_string(addon[:supervision]),
          artifact_object_key: assignment_string(addon[:artifact_object_key]),
          artifact_sha256: assignment_string(addon[:artifact_sha256]),
          artifact_signature: assignment_string(addon[:artifact_signature]),
          target_os: assignment_string(addon[:target_os]),
          target_arch: assignment_string(addon[:target_arch]),
          download_url: assignment_string(addon[:download_url]),
          download_token: assignment_string(addon[:download_token]),
          resources: to_proto_addon_resources(addon[:resources])
        }

      {:error, errors} ->
        refuse_addon_delivery(addon, agent_id, params, errors)
        nil
    end
  end

  # fj#4381: assignment params are persisted JSONB and can carry
  # representational drift that the typed Go add-on decoders reject — the demo
  # netprobe outage stored `capture_interfaces` as a scalar string, the agent's
  # `[]string` decode failed permanently, and the agent never acked another
  # config version (flow attribution stopped fleet-wide). Coerce params against
  # the package's declared `config_schema` at the delivery choke point, right
  # before `config_json` encoding, so we never ship JSON the agent decoder is
  # known to reject. Packages with an absent/empty schema (or one without
  # properties) pass params through unchanged — there is nothing to coerce
  # against, and delivery must not invent shapes the package never declared.
  #
  # Keys are stringified first (fj#4383) so post-coercion schema validation
  # sees the same shape the agent will decode from JSON — atom-keyed test/dev
  # params would otherwise read as "missing property + unknown key" to
  # ExJsonSchema and refuse delivery spuriously. Encoding is unaffected: Jason
  # writes atom and string keys identically.
  defp coerce_addon_params(addon) do
    ConfigSchema.coerce_params(
      addon[:config_schema],
      MapUtils.stringify_keys_or_empty(normalize_map(addon[:params]))
    )
  end

  # fj#4383: coercion handles the drift shapes it knows how to fix; anything
  # still schema-invalid afterwards is known-undecodable and MUST NOT ship
  # (spec `agent-config`, "Uncoercible params refuse delivery visibly").
  # An absent/empty schema validates vacuously — the empty-schema policy is
  # owned by `Validations.AddonAssignmentParams` at write time.
  defp validate_coerced_addon_params(addon, params) do
    schema = addon[:config_schema]

    if is_map(schema) do
      ConfigSchema.validate_params(schema, params)
    else
      :ok
    end
  end

  # Refusing delivery must be loud but not a 5-second-cycle log storm: the
  # config generator runs on every agent poll, so the error log is deduped via
  # a persistent_term last-state marker keyed by (agent, addon) storing the
  # refused params hash. Telemetry fires on every refusal (cheap; consumers
  # aggregate). There is currently no per-assignment validation-status field to
  # persist the error on (`profile_reconcile_status`/`_error` are owned by the
  # profile reconciler lifecycle and get overwritten on reconcile) — surfacing
  # the refusal on the assignment record itself is deferred to fj#4386b.
  defp refuse_addon_delivery(addon, agent_id, params, errors) do
    addon_id = assignment_string(addon[:addon_id])
    assignment_id = addon[:assignment_id]

    :telemetry.execute(
      [:serviceradar, :addon_config, :delivery_refused],
      %{count: 1},
      %{
        agent_id: agent_id,
        addon_id: addon_id,
        assignment_id: assignment_id,
        errors: errors
      }
    )

    marker_key = addon_delivery_marker_key(agent_id, addon_id)
    params_hash = :erlang.phash2(params)

    if :persistent_term.get(marker_key, :none) != {:refused, params_hash} do
      :persistent_term.put(marker_key, {:refused, params_hash})

      Logger.error(
        "Refusing add-on config delivery for #{addon_id} to agent #{inspect(agent_id)}" <>
          assignment_suffix(assignment_id) <>
          ": params failed schema validation after coercion: #{Enum.join(errors, "; ")}. " <>
          "The add-on section is withheld from the agent config until the assignment " <>
          "params are fixed (see mix serviceradar.validate_addon_params)."
      )
    end

    :ok
  end

  # Transition marker back to delivered so a later re-breakage of the same
  # (agent, addon) logs again, and operators get one recovery line. Writes to
  # persistent_term only happen on refusal/recovery transitions, never on the
  # steady-state delivery path.
  defp note_addon_delivery_resumed(addon, agent_id) do
    addon_id = assignment_string(addon[:addon_id])
    marker_key = addon_delivery_marker_key(agent_id, addon_id)

    case :persistent_term.get(marker_key, :none) do
      {:refused, _hash} ->
        :persistent_term.put(marker_key, :delivered)

        Logger.info(
          "Add-on config delivery resumed for #{addon_id} to agent #{inspect(agent_id)}: " <>
            "params now pass schema validation"
        )

      _ ->
        :ok
    end

    :ok
  end

  defp addon_delivery_marker_key(agent_id, addon_id),
    do: {__MODULE__, :addon_delivery_state, agent_id, addon_id}

  defp assignment_suffix(nil), do: ""
  defp assignment_suffix(assignment_id), do: " (assignment #{assignment_id})"

  # Manifest `resources` (addon.yaml) → the proto AddonResources the agent
  # supervisor enforces. The package attribute is JSONB (string keys); a missing
  # or empty block delivers no message (nil), which the agent reads as "unbounded".
  defp to_proto_addon_resources(resources) when is_map(resources) do
    if map_present?(resources) do
      %Monitoring.AddonResources{
        cpu_max_percent: resource_number(resources, "cpu_max_percent"),
        memory_max_bytes: resource_integer(resources, "memory_max_bytes"),
        memory_high_bytes: resource_integer(resources, "memory_high_bytes"),
        tasks_max: resource_integer(resources, "tasks_max"),
        slice: resource_string(resources, "slice")
      }
    end
  end

  defp to_proto_addon_resources(_), do: nil

  # Resource sub-map accessors: tolerate string (JSONB) or atom (test) keys and
  # coerce to the proto field's numeric type, defaulting unset/invalid to 0/"".
  defp resource_value(resources, key) do
    case Map.get(resources, key) do
      nil -> Map.get(resources, String.to_existing_atom(key))
      value -> value
    end
  rescue
    ArgumentError -> nil
  end

  defp resource_number(resources, key) do
    case resource_value(resources, key) do
      value when is_number(value) -> value / 1
      _ -> 0.0
    end
  end

  defp resource_integer(resources, key) do
    case resource_value(resources, key) do
      value when is_integer(value) -> value
      value when is_float(value) -> trunc(value)
      _ -> 0
    end
  end

  defp resource_string(resources, key) do
    case resource_value(resources, key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

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
    host_params = Map.get(assignment, :host_params) || Map.get(assignment, "host_params")
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
      download_token: source_fields.download_token,
      # Deliberately separate from params_json for mixed-version safety. An old
      # agent ignores unknown protobuf field 23 and therefore cannot expose the
      # host-only envelope through Wasm get_config.
      host_params_json: encode_json(host_params)
    }
  end

  defp resolved_assignment_params(assignment) do
    params = normalize_map(assignment.params)
    plugin_id = Map.get(assignment, :plugin_id) || Map.get(assignment, "plugin_id") || ""
    entrypoint = Map.get(assignment, :entrypoint) || Map.get(assignment, "entrypoint") || ""

    if ProxmoxHostAuthority.assignment?(plugin_id, entrypoint) do
      # Defensive mixed-version boundary: even callers that construct proto
      # assignments directly cannot re-resolve legacy inline Proxmox secrets.
      # Without a separately prepared host authority the old/new agent both see
      # only the public sentinel and fail closed.
      ProxmoxHostAuthority.public_params(plugin_id, params)
    else
      schema =
        assignment
        |> proto_assignment_config_schema()
        |> maybe_add_policy_credential_secret_fields(params, assignment)

      case SecretRefs.resolve_runtime_params(schema, params) do
        {:ok, resolved} -> resolved
        {:error, _} -> params
      end
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

  defp load_sync_payload!(agent_id) do
    case SyncConfigGenerator.build_payload(agent_id, audit_sink: &deferred_audit_sink/1) do
      {:ok, payload} ->
        payload

      {:error, reason} ->
        raise "failed to load integration config for agent #{agent_id}: #{inspect(reason)}"
    end
  end

  # Load sweep configuration from the AgentConfig system
  # This uses the ConfigServer which compiles sweep configs from SweepGroup/SweepProfile resources
  defp load_sweep_config(partition, agent_id) do
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
  defp load_mapper_config(partition, agent_id) do
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

  # Load sysmon configuration from the AgentConfig system
  # This uses the ConfigServer which compiles sysmon configs from SysmonProfile resources
  defp load_sysmon_config(partition, agent_id) do
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
  defp load_snmp_config(partition, agent_id) do
    actor = SystemActor.system(:snmp_config_loader)
    device_uid = resolve_agent_device_uid(agent_id, actor)

    case ConfigServer.get_config(:snmp, partition, agent_id,
           actor: actor,
           device_uid: device_uid,
           agent_id: agent_id
         ) do
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
  defp load_visibility_config(partition, agent_id) do
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

  defp load_bumblebee_config(partition, agent_id) do
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
      |> maybe_put_config_value("device_uid", device_uid)
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
      |> Map.put("catalog", catalog_assignment_config(snapshot))
    else
      {:error, :no_config_found} ->
        Logger.debug("No Bumblebee config found for agent #{agent_id}, using disabled config")
        disabled_feature_config()

      {:error, reason} ->
        Logger.warning(
          "Failed to load Bumblebee config for agent #{agent_id}: #{inspect(reason)}"
        )

        disabled_feature_config()

      _ ->
        disabled_feature_config()
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

  defp catalog_assignment_config(snapshot) do
    case AgentArtifacts.publish_catalog_assignment(%{
           source_id: snapshot.source_id || snapshot.snapshot_ref,
           snapshot_ref: snapshot.snapshot_ref,
           catalog_version: snapshot.catalog_version,
           source_revision: snapshot.source_revision,
           object_key: snapshot.object_key,
           sha256: snapshot.content_sha256,
           size_bytes: snapshot.object_size_bytes,
           promoted_at: snapshot.promoted_at,
           metadata: %{
             "snapshot_ref" => snapshot.snapshot_ref,
             "catalog_version" => snapshot.catalog_version,
             "source_revision" => snapshot.source_revision
           }
         }) do
      {:ok, assignment} ->
        assignment

      {:error, reason} ->
        Logger.warning("Failed to publish agent catalog artifact", reason: inspect(reason))

        %{
          "schema_version" => "serviceradar.catalog_assignment.v1",
          "snapshot_ref" => snapshot.snapshot_ref,
          "catalog_version" => snapshot.catalog_version,
          "source_revision" => snapshot.source_revision,
          "object_key" => snapshot.object_key,
          "sha256" => snapshot.content_sha256,
          "size_bytes" => snapshot.object_size_bytes,
          "promoted_at" => snapshot.promoted_at && DateTime.to_iso8601(snapshot.promoted_at)
        }
    end
  end

  defp disabled_feature_config, do: %{"enabled" => false}

  defp load_endpoint_inventory_config(partition, agent_id) do
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
        # No explicit per-agent config: default to enabled with standard collection
        # settings rather than hard-disabled. Endpoint inventory only actually runs on
        # agents that have the collector add-on staged/assigned (the in-cluster "k8s-agent"
        # pod and agents without the add-on never write the runtime profile / start the
        # scanner), so add-on assignment is the real opt-in gate. A missing config row must
        # not silently keep an assigned collector disabled forever.
        Logger.debug(
          "No stored endpoint inventory config for agent #{agent_id}; using enabled defaults"
        )

        default_endpoint_inventory_config(agent_id)

      {:error, reason} ->
        # On an actual load error (not a missing config) fail safe to disabled.
        Logger.warning(
          "Failed to load endpoint inventory config for agent #{agent_id}: #{inspect(reason)}"
        )

        disabled_endpoint_inventory_config()
    end
  end

  defp disabled_endpoint_inventory_config, do: %{"enabled" => false}

  defp default_endpoint_inventory_config(agent_id) do
    %{
      "enabled" => true,
      "agent_id" => agent_id,
      "sources" => ["dpkg", "rpm", "apk"],
      "scan_timeout" => "5m",
      "max_packages" => 100_000,
      "max_output_bytes" => 33_554_432,
      "cadence" => "12h",
      "collect_paths" => false,
      "collect_file_hashes" => false
    }
  end

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

  defp maybe_put_config_value(config, _key, value) when value in [nil, ""], do: config

  defp maybe_put_config_value(config, key, value) when is_map(config) and is_binary(key) do
    Map.put(config, key, value)
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
      delta: Map.get(oid, "delta", false) || false,
      mode: oid_mode(oid),
      max_rows: oid_positive_int(oid, "max_rows"),
      walk_timeout_seconds: oid_positive_int(oid, "walk_timeout_seconds")
    }
  end

  defp build_snmp_oid_config(_), do: %Monitoring.SNMPOIDConfig{}

  defp oid_mode(oid) do
    case Map.get(oid, "mode") || Map.get(oid, :mode) do
      mode when mode in [:walk, "walk"] -> "walk"
      _ -> ""
    end
  end

  defp oid_positive_int(oid, key) do
    case Map.get(oid, key) || Map.get(oid, String.to_existing_atom(key)) do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> 0
        end

      _ ->
        0
    end
  rescue
    ArgumentError -> 0
  end

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
      default_sample_interval_ms: Map.get(config, "default_sample_interval_ms", 0) || 0,
      flow_table_max_entries: Map.get(config, "flow_table_max_entries", 0) || 0
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
