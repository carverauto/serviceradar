defmodule ServiceRadar.AgentConfig.DependencyCatalog do
  @moduledoc """
  Declarative catalog of resources that affect agent-delivered configuration.

  The catalog is intentionally code-owned: entries describe the resource,
  config type, generator/compiler, affected-agent resolver, dispatch strategy,
  and redaction policy that bind UI/resource changes to agent config delivery.
  """

  alias Ash.Notifier.Notification
  alias ServiceRadar.AgentConfig.Compiler
  alias ServiceRadar.AgentConfig.Compilers.MapperCompiler
  alias ServiceRadar.AgentConfig.Compilers.SNMPCompiler
  alias ServiceRadar.AgentConfig.Compilers.SweepCompiler
  alias ServiceRadar.AgentConfig.Compilers.VisibilityCompiler
  alias ServiceRadar.AgentConfig.DependencyResolvers
  alias ServiceRadar.Edge.AgentConfigGenerator
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Inventory.VisibilityProfile
  alias ServiceRadar.Monitoring.ServiceCheck
  alias ServiceRadar.Plugins.AddonAssignment
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage

  defmodule Entry do
    @moduledoc "One resource-to-agent-config dependency declaration."

    @enforce_keys [
      :id,
      :resource,
      :config_type,
      :generator,
      :affected_agents,
      :dispatch
    ]
    defstruct [
      :id,
      :resource,
      :config_type,
      :generator,
      :affected_agents,
      :dispatch,
      :description,
      lifecycle_actions: [:create, :update, :destroy],
      action_names: [],
      secret_fields: []
    ]
  end

  @type entry :: %Entry{
          id: atom(),
          resource: module(),
          config_type: atom(),
          generator: module(),
          lifecycle_actions: [atom()],
          action_names: [atom()],
          affected_agents: {module(), atom(), list()},
          dispatch: :push_affected_agents | :invalidate_config_type | :push_config_for_type,
          secret_fields: [atom() | String.t()],
          description: String.t() | nil
        }

  @dispatch_strategies [:push_affected_agents, :invalidate_config_type, :push_config_for_type]
  @extra_config_types [:agent, :sync]

  @doc "Returns every declared dependency catalog entry."
  @spec entries() :: [entry()]
  def entries do
    [
      %Entry{
        id: :integration_source_sync_config,
        resource: IntegrationSource,
        config_type: :sync,
        generator: ServiceRadar.Integrations.SyncConfigGenerator,
        affected_agents: {DependencyResolvers, :record_agent_id, []},
        dispatch: :push_affected_agents,
        action_names: [:create, :update, :enable, :disable, :delete],
        secret_fields: [:api_key, :api_secret, :secret_key, "api_key", "api_secret", "secret_key"],
        description:
          "Integration sources are embedded in config_json.sources for the assigned agent."
      },
      %Entry{
        id: :service_check_agent_config,
        resource: ServiceCheck,
        config_type: :agent,
        generator: AgentConfigGenerator,
        affected_agents: {DependencyResolvers, :record_agent_id, []},
        dispatch: :push_affected_agents,
        action_names: [:create, :update, :destroy, :enable, :disable, :reassign_device],
        description: "Service checks are delivered in the unified agent check list."
      },
      %Entry{
        id: :plugin_assignment_agent_config,
        resource: PluginAssignment,
        config_type: :agent,
        generator: AgentConfigGenerator,
        affected_agents: {DependencyResolvers, :record_agent_id, []},
        dispatch: :push_affected_agents,
        action_names: [:create, :update, :destroy],
        secret_fields: [:params, "params"],
        description: "Plugin assignments are delivered in the unified plugin_config section."
      },
      %Entry{
        id: :plugin_package_agent_config,
        resource: PluginPackage,
        config_type: :agent,
        generator: AgentConfigGenerator,
        affected_agents: {DependencyResolvers, :all_online, []},
        dispatch: :push_config_for_type,
        action_names: [:update, :approve, :revoke, :destroy],
        description:
          "Plugin package approval or artifact changes can alter assigned plugin payloads."
      },
      %Entry{
        id: :addon_assignment_agent_config,
        resource: AddonAssignment,
        config_type: :agent,
        generator: AgentConfigGenerator,
        affected_agents: {DependencyResolvers, :record_agent_id, []},
        dispatch: :push_affected_agents,
        action_names: [:create, :update, :destroy],
        secret_fields: [:params, "params"],
        description:
          "Add-on (feature set) assignments are delivered in the unified addons section."
      },
      %Entry{
        id: :addon_package_agent_config,
        resource: AddonPackage,
        config_type: :agent,
        generator: AgentConfigGenerator,
        affected_agents: {DependencyResolvers, :all_online, []},
        dispatch: :push_config_for_type,
        action_names: [:update, :approve, :revoke, :destroy],
        description:
          "Add-on package approval or artifact changes can alter assigned add-on payloads."
      },
      %Entry{
        id: :agent_engine_limits_config,
        resource: ServiceRadar.Infrastructure.Agent,
        config_type: :agent,
        generator: AgentConfigGenerator,
        affected_agents: {DependencyResolvers, :record_uid, []},
        dispatch: :push_affected_agents,
        action_names: [:update],
        description:
          "Agent records carry plugin engine limits and identity metadata used during config generation."
      },
      config_server_entry(
        :sweep_group_config,
        ServiceRadar.SweepJobs.SweepGroup,
        :sweep,
        SweepCompiler,
        action_names: [
          :create,
          :update,
          :destroy,
          :enable,
          :disable,
          :add_targets,
          :remove_targets
        ]
      ),
      config_server_entry(
        :sweep_profile_config,
        ServiceRadar.SweepJobs.SweepProfile,
        :sweep,
        SweepCompiler
      ),
      config_server_entry(
        :mapper_job_config,
        ServiceRadar.NetworkDiscovery.MapperJob,
        :mapper,
        MapperCompiler,
        action_names: [:create, :update, :destroy]
      ),
      config_server_entry(
        :mapper_seed_config,
        ServiceRadar.NetworkDiscovery.MapperSeed,
        :mapper,
        MapperCompiler
      ),
      config_server_entry(
        :mapper_unifi_controller_config,
        ServiceRadar.NetworkDiscovery.MapperUnifiController,
        :mapper,
        MapperCompiler,
        secret_fields: [:api_key, :password, "api_key", "password"]
      ),
      config_server_entry(
        :mapper_mikrotik_controller_config,
        ServiceRadar.NetworkDiscovery.MapperMikrotikController,
        :mapper,
        MapperCompiler,
        secret_fields: [:password, "password"]
      ),
      config_server_entry(
        :snmp_profile_config,
        ServiceRadar.SNMPProfiles.SNMPProfile,
        :snmp,
        SNMPCompiler,
        action_names: [:create, :update, :destroy, :set_as_default, :unset_default],
        secret_fields: [:community, :auth_password, :priv_password]
      ),
      config_server_entry(
        :snmp_oid_template_config,
        ServiceRadar.SNMPProfiles.SNMPOIDTemplate,
        :snmp,
        SNMPCompiler
      ),
      config_server_entry(
        :snmp_target_config,
        ServiceRadar.SNMPProfiles.SNMPTarget,
        :snmp,
        SNMPCompiler,
        secret_fields: [:community, :auth_password, :priv_password]
      ),
      config_server_entry(
        :snmp_oid_config,
        ServiceRadar.SNMPProfiles.SNMPOIDConfig,
        :snmp,
        SNMPCompiler,
        action_names: [:create, :create_bulk, :update, :destroy]
      ),
      config_server_entry(
        :device_snmp_config,
        ServiceRadar.Inventory.Device,
        :snmp,
        SNMPCompiler
      ),
      config_server_entry(
        :sysmon_profile_config,
        ServiceRadar.SysmonProfiles.SysmonProfile,
        :sysmon,
        ServiceRadar.AgentConfig.Compilers.SysmonCompiler
      ),
      config_server_entry(
        :visibility_profile_config,
        VisibilityProfile,
        :visibility,
        VisibilityCompiler
      )
    ]
  end

  @doc "Returns entries for a resource module."
  @spec for_resource(module()) :: [entry()]
  def for_resource(resource) do
    Enum.filter(entries(), &(&1.resource == resource))
  end

  @doc "Returns entries matching an Ash notification resource and action."
  @spec for_notification(Notification.t()) :: [entry()]
  def for_notification(%Notification{resource: resource, action: action}) do
    resource
    |> for_resource()
    |> Enum.filter(&matches_action?(&1, action))
  end

  def for_notification(_notification), do: []

  defp matches_action?(%Entry{} = entry, action) do
    action_type = Map.get(action, :type)
    action_name = Map.get(action, :name)

    action_type in entry.lifecycle_actions and
      (entry.action_names == [] or action_name in entry.action_names)
  end

  @doc "Resolves affected agents for a catalog entry and changed record."
  @spec affected_agents(entry(), map() | struct()) :: DependencyResolvers.affected_agents()
  def affected_agents(%Entry{affected_agents: {module, function, extra_args}}, record) do
    apply(module, function, [record | extra_args])
  end

  @doc "Builds redacted diagnostics for a cataloged resource change."
  @spec diagnostics(entry(), map() | struct()) :: map()
  def diagnostics(%Entry{} = entry, record) do
    %{
      dependency_id: entry.id,
      resource: inspect(entry.resource),
      resource_id: resource_value(record, [:id, "id"]),
      resource_name: resource_value(record, [:name, "name", :uid, "uid"]),
      config_type: entry.config_type,
      generator: inspect(entry.generator),
      dispatch: entry.dispatch,
      affected_agents: affected_agents(entry, record),
      secrets: secret_presence(entry, record)
    }
  end

  @doc "Validates catalog shape and source-resource coverage."
  @spec validate([entry()]) :: :ok | {:error, [String.t()]}
  def validate(entries \\ entries()) do
    errors =
      []
      |> Kernel.++(duplicate_id_errors(entries))
      |> Kernel.++(invalid_config_type_errors(entries))
      |> Kernel.++(invalid_dispatch_errors(entries))
      |> Kernel.++(invalid_resolver_errors(entries))
      |> Kernel.++(missing_source_resource_errors(entries))

    if errors == [], do: :ok, else: {:error, errors}
  end

  @doc "Raises if the catalog is invalid."
  @spec validate!() :: :ok
  def validate! do
    case validate() do
      :ok ->
        :ok

      {:error, errors} ->
        raise ArgumentError, "invalid agent config dependency catalog: #{inspect(errors)}"
    end
  end

  @doc "Resources known to be read by current agent config generators/compilers."
  @spec required_source_resources() :: [module()]
  def required_source_resources do
    Enum.uniq(
      compiler_source_resources() ++
        [
          IntegrationSource,
          ServiceCheck,
          PluginAssignment,
          PluginPackage,
          AddonAssignment,
          AddonPackage,
          ServiceRadar.Infrastructure.Agent
        ]
    )
  end

  @doc "Returns whether a value names a supported agent config type."
  @spec known_config_type?(atom()) :: boolean()
  def known_config_type?(config_type) do
    config_type in known_config_types()
  end

  defp config_server_entry(id, resource, config_type, compiler, opts \\ []) do
    %Entry{
      id: id,
      resource: resource,
      config_type: config_type,
      generator: compiler,
      affected_agents: {DependencyResolvers, :all_online, []},
      dispatch: :invalidate_config_type,
      action_names: Keyword.get(opts, :action_names, []),
      secret_fields: Keyword.get(opts, :secret_fields, []),
      description:
        Keyword.get(
          opts,
          :description,
          "#{inspect(resource)} contributes to #{config_type} config compilation."
        )
    }
  end

  defp known_config_types do
    Enum.uniq(@extra_config_types ++ Compiler.config_types())
  end

  defp compiler_source_resources do
    Enum.flat_map(Compiler.config_types(), fn config_type ->
      case Compiler.compiler_for(config_type) do
        {:ok, compiler} -> compiler.source_resources()
        {:error, :unknown_config_type} -> []
      end
    end)
  end

  defp duplicate_id_errors(entries) do
    entries
    |> Enum.group_by(& &1.id)
    |> Enum.flat_map(fn
      {_id, [_entry]} ->
        []

      {id, duplicates} ->
        ["duplicate dependency id #{inspect(id)} (#{length(duplicates)} entries)"]
    end)
  end

  defp invalid_config_type_errors(entries) do
    entries
    |> Enum.reject(&known_config_type?(&1.config_type))
    |> Enum.map(&"#{inspect(&1.id)} uses unknown config type #{inspect(&1.config_type)}")
  end

  defp invalid_dispatch_errors(entries) do
    entries
    |> Enum.reject(&(&1.dispatch in @dispatch_strategies))
    |> Enum.map(&"#{inspect(&1.id)} uses unsupported dispatch strategy #{inspect(&1.dispatch)}")
  end

  defp invalid_resolver_errors(entries) do
    entries
    |> Enum.reject(fn %Entry{affected_agents: resolver} ->
      case resolver do
        {module, function, args} when is_atom(function) and is_list(args) ->
          Code.ensure_loaded?(module) and function_exported?(module, function, length(args) + 1)

        _ ->
          false
      end
    end)
    |> Enum.map(&"#{inspect(&1.id)} has an invalid affected-agent resolver")
  end

  defp missing_source_resource_errors(entries) do
    covered = MapSet.new(Enum.map(entries, & &1.resource))

    required_source_resources()
    |> Enum.reject(&MapSet.member?(covered, &1))
    |> Enum.map(&"missing dependency catalog entry for #{inspect(&1)}")
  end

  defp secret_presence(%Entry{secret_fields: []}, _record), do: %{}

  defp secret_presence(%Entry{secret_fields: fields}, record) do
    credentials = value(record, :credentials) || value(record, "credentials") || %{}

    fields
    |> Enum.map(fn field ->
      {field, present?(value(record, field) || value(credentials, field))}
    end)
    |> Map.new(fn {field, present?} -> {to_string(field), present?} end)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_nil(value), do: false
  defp present?(_value), do: true

  defp resource_value(record, keys) do
    Enum.find_value(keys, &value(record, &1))
  end

  defp value(record, key) when is_atom(key) do
    Map.get(record, key) || if(is_struct(record), do: Map.get(record, key))
  end

  defp value(record, key) when is_binary(key), do: Map.get(record, key)
end
