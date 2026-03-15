defmodule ServiceRadar.AgentConfig.Compilers.SysmonCompiler do
  @moduledoc """
  Compiler for sysmon configurations.

  Transforms SysmonProfile Ash resources into agent-consumable sysmon
  configuration format using SRQL-based targeting.

  ## Resolution Order

  When resolving which profile applies to a device:
  1. SRQL targeting profiles (ordered by priority, highest first)
  2. No match returns a disabled sysmon config

  Profiles use `target_query` (SRQL) to define which devices they apply to.
  Example: `target_query: "in:devices tags.role:database"` matches all devices
  with the tag `role=database`.

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
        "disk_paths" => [],
        "disk_exclude_paths" => [],
        "thresholds" => %{
          "cpu_warning" => "80",
          "cpu_critical" => "95"
        },
        "profile_id" => "uuid",
        "profile_name" => "Production Monitoring",
        "config_source" => "remote"
      }
  """

  @behaviour ServiceRadar.AgentConfig.Compiler

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.TargetedProfileResolver
  alias ServiceRadar.SysmonProfiles.SrqlTargetResolver
  alias ServiceRadar.SysmonProfiles.SysmonProfile

  require Ash.Query
  require Logger

  @impl true
  def config_type, do: :sysmon

  @impl true
  def source_resources do
    [SysmonProfile]
  end

  @impl true
  def compile(_partition, _agent_id, opts \\ []) do
    # DB connection's search_path determines the schema
    actor = opts[:actor] || SystemActor.system(:sysmon_compiler)
    device_uid = opts[:device_uid]

    # Resolve the profile for this agent/device
    profile = resolve_profile(device_uid, actor)

    if profile do
      config = compile_profile(profile)
      {:ok, config}
    else
      # Return disabled config if no profile found
      {:ok, disabled_config()}
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
  Resolves the sysmon profile for a device using SRQL targeting.

  Resolution order:
  1. SRQL targeting profiles (ordered by priority, highest first)

  Returns the matching SysmonProfile or nil if no profile matches.
  """
  @spec resolve_profile(String.t() | nil, map()) :: SysmonProfile.t() | nil
  def resolve_profile(device_uid, actor) do
    TargetedProfileResolver.resolve(device_uid, actor,
      resolver: &SrqlTargetResolver.resolve_for_device/2,
      log_prefix: "SysmonCompiler"
    )
  end

  @doc """
  Compiles a profile to the agent config format.
  """
  @spec compile_profile(SysmonProfile.t()) :: map()
  def compile_profile(profile) do
    config_source = "remote"

    %{
      "enabled" => profile.enabled,
      "sample_interval" => profile.sample_interval,
      "collect_cpu" => profile.collect_cpu,
      "collect_memory" => profile.collect_memory,
      "collect_disk" => profile.collect_disk,
      "collect_network" => profile.collect_network,
      "collect_processes" => profile.collect_processes,
      "disk_paths" => profile.disk_paths,
      "disk_exclude_paths" => profile.disk_exclude_paths,
      "thresholds" => profile.thresholds || %{},
      "profile_id" => profile.id,
      "profile_name" => profile.name,
      "config_source" => config_source
    }
  end

  @doc """
  Returns a disabled sysmon configuration when no profile is assigned.
  """
  @spec disabled_config() :: map()
  def disabled_config do
    %{
      "enabled" => false,
      "sample_interval" => "10s",
      "collect_cpu" => false,
      "collect_memory" => false,
      "collect_disk" => false,
      "collect_network" => false,
      "collect_processes" => false,
      "disk_paths" => [],
      "disk_exclude_paths" => [],
      "thresholds" => %{},
      "profile_id" => "",
      "profile_name" => "",
      "config_source" => "unassigned"
    }
  end
end
