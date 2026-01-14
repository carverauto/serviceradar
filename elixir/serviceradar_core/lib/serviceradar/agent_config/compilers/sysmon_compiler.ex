defmodule ServiceRadar.AgentConfig.Compilers.SysmonCompiler do
  @moduledoc """
  Compiler for sysmon configurations.

  Transforms SysmonProfile and SysmonProfileAssignment Ash resources into
  agent-consumable sysmon configuration format.

  ## Resolution Order

  When resolving which profile applies to a device:
  1. Device-specific assignment (legacy, for backwards compatibility)
  2. SRQL targeting profiles (ordered by priority, highest first)
  3. Tag-based assignments (legacy, for backwards compatibility)
  4. Default tenant profile (fallback)

  SRQL targeting is the preferred method. Device and tag assignments are
  maintained for backwards compatibility during the migration period.

  ## Output Format

  The compiled config follows this structure:

      %{
        "enabled" => true,
        "sample_interval" => "10s",
        "collect_cpu" => true,
        "collect_memory" => true,
        "collect_disk" => true,
        "collect_network" => false,
        "collect_processes" => false,
        "disk_paths" => ["/"],
        "thresholds" => %{
          "cpu_warning" => "80",
          "cpu_critical" => "95"
        },
        "profile_id" => "uuid",
        "profile_name" => "Production Monitoring",
        "config_source" => "srql"
      }
  """

  @behaviour ServiceRadar.AgentConfig.Compiler

  require Ash.Query
  require Logger

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Cluster.TenantSchemas
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.SysmonProfiles.{SysmonProfile, SysmonProfileAssignment}
  alias ServiceRadar.SysmonProfiles.SrqlTargetResolver

  @impl true
  def config_type, do: :sysmon

  @impl true
  def source_resources do
    [SysmonProfile, SysmonProfileAssignment]
  end

  @impl true
  def compile(tenant_id, _partition, agent_id, opts \\ []) do
    actor = opts[:actor] || SystemActor.for_tenant(tenant_id, :sysmon_compiler)
    tenant_schema = TenantSchemas.schema_for_tenant(tenant_id)
    device_uid = opts[:device_uid]

    # Resolve the profile for this agent/device
    profile = resolve_profile(tenant_schema, device_uid, agent_id, actor)

    if profile do
      config = compile_profile(profile, tenant_schema, actor)
      {:ok, config}
    else
      # Return default config if no profile found
      {:ok, default_config()}
    end
  rescue
    e ->
      Logger.error("SysmonCompiler: error compiling config - #{inspect(e)}")
      {:error, {:compilation_error, e}}
  end

  @impl true
  def validate(config) when is_map(config) do
    cond do
      not Map.has_key?(config, "enabled") ->
        {:error, "Config missing 'enabled' key"}

      not Map.has_key?(config, "sample_interval") ->
        {:error, "Config missing 'sample_interval' key"}

      true ->
        :ok
    end
  end

  @doc """
  Resolves the sysmon profile for a device.

  Resolution order:
  1. Device-specific assignment (legacy, for backwards compatibility)
  2. SRQL targeting profiles (ordered by priority, highest first)
  3. Tag-based assignment (legacy, for backwards compatibility)
  4. Default profile for tenant

  Returns `{profile, config_source}` tuple where config_source indicates
  how the profile was resolved ("device", "srql", "tag", or "default").
  """
  @spec resolve_profile(String.t(), String.t() | nil, String.t() | nil, map()) ::
          SysmonProfile.t() | nil
  def resolve_profile(tenant_schema, device_uid, _agent_id, actor) do
    # Try device-specific assignment first (legacy)
    profile = try_device_assignment(tenant_schema, device_uid, actor)

    if profile do
      profile
    else
      # Try SRQL targeting profiles
      profile = try_srql_targeting(tenant_schema, device_uid, actor)

      if profile do
        profile
      else
        # Try tag-based assignment (legacy)
        profile =
          if not is_nil(device_uid) do
            try_tag_assignment(tenant_schema, device_uid, actor)
          else
            nil
          end

        # Fall back to default profile
        profile || get_default_profile(tenant_schema, actor)
      end
    end
  end

  # Try to find a matching profile via SRQL targeting
  defp try_srql_targeting(_tenant_schema, nil, _actor), do: nil

  defp try_srql_targeting(tenant_schema, device_uid, actor) do
    case SrqlTargetResolver.resolve_for_device(tenant_schema, device_uid, actor) do
      {:ok, profile} -> profile
      {:error, reason} ->
        Logger.warning("SysmonCompiler: SRQL targeting failed - #{inspect(reason)}")
        nil
    end
  end

  @doc """
  Compiles a profile to the agent config format.
  """
  @spec compile_profile(SysmonProfile.t(), String.t(), map()) :: map()
  def compile_profile(profile, _tenant_schema, _actor, config_source \\ "profile") do
    %{
      "enabled" => profile.enabled,
      "sample_interval" => profile.sample_interval,
      "collect_cpu" => profile.collect_cpu,
      "collect_memory" => profile.collect_memory,
      "collect_disk" => profile.collect_disk,
      "collect_network" => profile.collect_network,
      "collect_processes" => profile.collect_processes,
      "disk_paths" => profile.disk_paths,
      "thresholds" => profile.thresholds || %{},
      "profile_id" => profile.id,
      "profile_name" => profile.name,
      "config_source" => config_source
    }
  end

  @doc """
  Returns default sysmon configuration when no profile is assigned.
  """
  @spec default_config() :: map()
  def default_config do
    %{
      "enabled" => true,
      "sample_interval" => "10s",
      "collect_cpu" => true,
      "collect_memory" => true,
      "collect_disk" => true,
      "collect_network" => false,
      "collect_processes" => false,
      "disk_paths" => ["/"],
      "thresholds" => %{},
      "profile_id" => nil,
      "profile_name" => "Default",
      "config_source" => "default"
    }
  end

  # Private helpers

  defp try_device_assignment(_tenant_schema, nil, _actor), do: nil

  defp try_device_assignment(tenant_schema, device_uid, actor) do
    query =
      SysmonProfileAssignment
      |> Ash.Query.for_read(:for_device, %{device_uid: device_uid},
        actor: actor,
        tenant: tenant_schema
      )
      |> Ash.Query.load(:profile)

    case Ash.read_one(query, actor: actor) do
      {:ok, nil} ->
        nil

      {:ok, assignment} ->
        assignment.profile

      {:error, reason} ->
        Logger.warning("SysmonCompiler: failed to load device assignment - #{inspect(reason)}")
        nil
    end
  end

  defp try_tag_assignment(tenant_schema, device_uid, actor) do
    # Load device to get its tags
    device = load_device(tenant_schema, device_uid, actor)

    if device && is_map(device.tags) && map_size(device.tags) > 0 do
      # Get all tag assignments and find the highest priority match
      assignments = load_tag_assignments(tenant_schema, actor)

      matching_assignment =
        assignments
        |> Enum.filter(&tag_matches_device?(&1, device.tags))
        |> Enum.sort_by(& &1.priority, :desc)
        |> List.first()

      if matching_assignment do
        matching_assignment.profile
      else
        nil
      end
    else
      nil
    end
  end

  defp load_device(tenant_schema, device_uid, actor) do
    query =
      Device
      |> Ash.Query.for_read(:by_uid, %{uid: device_uid}, actor: actor, tenant: tenant_schema)

    case Ash.read_one(query, actor: actor) do
      {:ok, device} -> device
      {:error, _} -> nil
    end
  end

  defp load_tag_assignments(tenant_schema, actor) do
    query =
      SysmonProfileAssignment
      |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: tenant_schema)
      |> Ash.Query.filter(assignment_type == :tag)
      |> Ash.Query.load(:profile)

    case Ash.read(query, actor: actor) do
      {:ok, assignments} -> assignments
      {:error, _} -> []
    end
  end

  defp tag_matches_device?(assignment, device_tags) do
    tag_key = assignment.tag_key
    tag_value = assignment.tag_value

    device_value = Map.get(device_tags, tag_key)

    cond do
      # Device doesn't have this tag
      is_nil(device_value) -> false
      # Assignment matches any value for this key
      is_nil(tag_value) -> true
      # Assignment matches specific value
      true -> device_value == tag_value
    end
  end

  defp get_default_profile(tenant_schema, actor) do
    query =
      SysmonProfile
      |> Ash.Query.for_read(:get_default, %{}, actor: actor, tenant: tenant_schema)

    case Ash.read_one(query, actor: actor) do
      {:ok, profile} -> profile
      {:error, _} -> nil
    end
  end
end
