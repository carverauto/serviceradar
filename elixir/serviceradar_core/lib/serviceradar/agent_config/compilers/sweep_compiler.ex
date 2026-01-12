defmodule ServiceRadar.AgentConfig.Compilers.SweepCompiler do
  @moduledoc """
  Compiler for sweep configurations.

  Transforms SweepGroup and SweepProfile Ash resources into agent-consumable
  sweep configuration format.

  ## Output Format

  The compiled config follows this structure:

      %{
        "groups" => [
          %{
            "id" => "uuid",
            "name" => "Production Network Sweep",
            "schedule" => %{
              "type" => "interval",
              "interval" => "15m"
            },
            "targets" => ["10.0.1.0/24", "10.0.2.0/24"],
            "ports" => [22, 80, 443],
            "modes" => ["icmp", "tcp"],
            "settings" => %{
              "concurrency" => 50,
              "timeout" => "3s"
            }
          }
        ],
        "version" => "abc123..."
      }
  """

  @behaviour ServiceRadar.AgentConfig.Compiler

  require Ash.Query
  require Logger

  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.SweepJobs.{SweepGroup, SweepProfile, TargetCriteria}
  alias ServiceRadar.Cluster.TenantSchemas

  @impl true
  def config_type, do: :sweep

  @impl true
  def source_resources do
    [SweepGroup, SweepProfile]
  end

  @impl true
  def compile(tenant_id, partition, agent_id, opts \\ []) do
    try do
      actor = opts[:actor] || build_system_actor(tenant_id)
      tenant_schema = TenantSchemas.schema_for_tenant(tenant_id)

      # Load sweep groups for this partition/agent
      groups = load_sweep_groups(tenant_schema, partition, agent_id, actor)

      # Load profiles that might be referenced
      profile_ids =
        groups
        |> Enum.map(& &1.profile_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      profiles = load_profiles(tenant_schema, profile_ids, actor)
      profile_map = Map.new(profiles, &{&1.id, &1})

      # Compile each group
      compiled_groups =
        groups
        |> Enum.map(&compile_group(&1, profile_map, tenant_schema, actor))
        |> Enum.reject(&is_nil/1)

      # Compute config hash for change detection
      config_hash = compute_config_hash(compiled_groups)

      config = %{
        "groups" => compiled_groups,
        "compiled_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "config_hash" => config_hash
      }

      {:ok, config}
    rescue
      e ->
        Logger.error("SweepCompiler: error compiling config - #{inspect(e)}")
        {:error, {:compilation_error, e}}
    end
  end

  @impl true
  def validate(config) when is_map(config) do
    cond do
      not Map.has_key?(config, "groups") ->
        {:error, "Config missing 'groups' key"}

      not is_list(config["groups"]) ->
        {:error, "'groups' must be a list"}

      true ->
        :ok
    end
  end

  # Private helpers

  defp compute_config_hash(compiled_groups) do
    # Sort groups by ID for deterministic hashing
    sorted_groups = Enum.sort_by(compiled_groups, & &1["id"])

    # Compute SHA256 hash of the JSON-encoded config
    sorted_groups
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> String.slice(0, 16)
  end

  defp build_system_actor(tenant_id) do
    %{
      id: "system",
      email: "sweep-compiler@serviceradar",
      role: :admin,
      tenant_id: tenant_id
    }
  end

  defp load_sweep_groups(tenant_schema, partition, agent_id, actor) do
    query =
      SweepGroup
      |> Ash.Query.for_read(:for_agent_partition, %{partition: partition, agent_id: agent_id},
        actor: actor,
        tenant: tenant_schema
      )

    case Ash.read(query, authorize?: false) do
      {:ok, groups} ->
        groups

      {:error, reason} ->
        Logger.warning("SweepCompiler: failed to load groups - #{inspect(reason)}")
        []
    end
  end

  defp load_profiles(_tenant_schema, profile_ids, _actor) when profile_ids == [], do: []

  defp load_profiles(tenant_schema, profile_ids, actor) do
    query =
      SweepProfile
      |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: tenant_schema)
      |> Ash.Query.filter(id in ^profile_ids)

    case Ash.read(query, authorize?: false) do
      {:ok, profiles} ->
        profiles

      {:error, reason} ->
        Logger.warning("SweepCompiler: failed to load profiles - #{inspect(reason)}")
        []
    end
  end

  defp compile_group(group, profile_map, tenant_schema, actor) do
    # Get profile settings as base
    profile = Map.get(profile_map, group.profile_id)

    # Build schedule
    schedule = compile_schedule(group)

    # Build targets from criteria and static targets
    targets = compile_targets(group, tenant_schema, actor)

    # Merge ports from profile and group overrides
    ports = merge_ports(profile, group)

    # Merge sweep modes from profile and group overrides
    modes = merge_modes(profile, group)

    # Build settings from profile with overrides
    settings = compile_settings(profile, group)

    %{
      "id" => group.id,
      "sweep_group_id" => group.id,
      "name" => group.name,
      "description" => group.description,
      "schedule" => schedule,
      "targets" => targets,
      "ports" => ports,
      "modes" => modes,
      "settings" => settings
    }
  end

  defp compile_schedule(group) do
    case group.schedule_type do
      :cron ->
        %{
          "type" => "cron",
          "cron_expression" => group.cron_expression
        }

      _ ->
        %{
          "type" => "interval",
          "interval" => group.interval
        }
    end
  end

  defp compile_targets(group, tenant_schema, actor) do
    # Start with static targets
    static_targets = group.static_targets || []

    # Get targets from device criteria if defined
    criteria_targets =
      if map_size(group.target_criteria || %{}) > 0 do
        get_targets_from_criteria(group.target_criteria, tenant_schema, actor)
      else
        []
      end

    # Combine and deduplicate
    (static_targets ++ criteria_targets)
    |> Enum.uniq()
  end

  defp get_targets_from_criteria(criteria, tenant_schema, actor) do
    query =
      Device
      |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: tenant_schema)

    case Ash.read(query, authorize?: false) do
      {:ok, devices} ->
        TargetCriteria.extract_targets(devices, criteria, [])

      {:error, reason} ->
        Logger.warning("SweepCompiler: failed to load devices - #{inspect(reason)}")
        []
    end
  end

  defp merge_ports(nil, group), do: group.ports || []
  defp merge_ports(profile, group) do
    # Group ports override profile ports if set
    case group.ports do
      nil -> profile.ports || []
      ports -> ports
    end
  end

  defp merge_modes(nil, group), do: group.sweep_modes || ["icmp", "tcp"]
  defp merge_modes(profile, group) do
    case group.sweep_modes do
      nil -> profile.sweep_modes || ["icmp", "tcp"]
      modes -> modes
    end
  end

  defp compile_settings(profile, group) do
    base_settings =
      if profile do
        %{
          "concurrency" => profile.concurrency,
          "timeout" => profile.timeout,
          "icmp_settings" => profile.icmp_settings || %{},
          "tcp_settings" => profile.tcp_settings || %{}
        }
      else
        %{
          "concurrency" => 50,
          "timeout" => "3s",
          "icmp_settings" => %{},
          "tcp_settings" => %{}
        }
      end

    # Apply group overrides
    Map.merge(base_settings, group.overrides || %{})
  end
end
