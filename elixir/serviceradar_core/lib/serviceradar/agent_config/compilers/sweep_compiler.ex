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

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Observability.SRQLRunner
  alias ServiceRadar.SRQLQuery
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepProfile
  alias ServiceRadar.SweepJobs.SweepProfile.BannerGrab
  alias ServiceRadar.Types.Cidr

  require Ash.Query
  require Logger

  @srql_page_limit_default 500

  @impl true
  def config_type, do: :sweep

  @impl true
  def source_resources do
    [SweepGroup, SweepProfile]
  end

  @impl true
  def compile(partition, agent_id, opts \\ []) do
    # DB connection's search_path determines the schema
    actor = opts[:actor] || SystemActor.system(:sweep_compiler)

    # Load groups whose fixed subset contains this agent (any device partition)
    # plus partition-wide groups in the agent's own partition. Device partition
    # != agent partition for isolation scans.
    groups = load_sweep_groups(partition, agent_id, actor)

    # Load profiles that might be referenced
    profile_ids =
      groups
      |> Enum.map(& &1.profile_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    profiles = load_profiles(profile_ids, actor)
    profile_map = Map.new(profiles, &{&1.id, &1})

    # Compile each group
    compiled_groups =
      groups
      |> Enum.map(&compile_group(&1, profile_map, actor))
      |> Enum.reject(&is_nil/1)

    Logger.info(
      "SweepCompiler: compiled #{length(compiled_groups)} group(s) for partition=#{inspect(partition)}, agent_id=#{inspect(agent_id)}",
      groups: Enum.map(compiled_groups, &compiled_group_summary/1)
    )

    # Compute config hash for change detection
    config_hash = config_hash(compiled_groups)

    config = %{
      "groups" => compiled_groups,
      "compiled_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "config_hash" => config_hash
    }

    {:ok, config}
  rescue
    e ->
      Logger.error("SweepCompiler: error compiling config - #{inspect(e)}")
      {:error, {:compilation_error, e}}
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

  @doc """
  Computes a deterministic config hash for compiled sweep groups.
  """
  @spec config_hash([map()]) :: String.t()
  def config_hash(compiled_groups) when is_list(compiled_groups) do
    compute_config_hash(compiled_groups)
  end

  @doc """
  Compiled probe settings a sweep group would send to an agent.

  Matches `compile_group/3`: profile as base, group overrides on top,
  TCP-without-ports dropped, modes the Go sweeper does not implement dropped.
  Used by NCO validation runs so they replay scheduled scan settings instead
  of inventing ICMP.
  """
  @spec compiled_scan_settings(SweepGroup.t(), SweepProfile.t() | nil) :: map()
  def compiled_scan_settings(%SweepGroup{} = group, profile) do
    ports = merge_ports(profile, group)
    modes = merge_modes(profile, group)
    {ports, modes} = enforce_tcp_ports(ports, modes, group)
    modes = drop_unsupported_modes(modes, group)
    settings = compile_settings(profile, group)

    %{
      sweep_group_id: group.id,
      profile_id: group.profile_id,
      modes: modes,
      ports: ports,
      settings: settings
    }
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

  defp compiled_group_summary(group) do
    %{
      id: group["id"],
      name: group["name"],
      static_targets: length(group["targets"] || []),
      device_targets: length(group["device_targets"] || []),
      ports: group["ports"] || [],
      modes: group["modes"] || []
    }
  end

  defp load_sweep_groups(partition, agent_id, actor) do
    query =
      Ash.Query.for_read(SweepGroup, :for_agent_partition, %{
        partition: partition,
        agent_id: agent_id
      })

    Logger.debug(
      "SweepCompiler: loading groups for partition=#{inspect(partition)}, agent_id=#{inspect(agent_id)}"
    )

    case Ash.read(query, actor: actor) do
      {:ok, groups} ->
        Logger.debug(
          "SweepCompiler: loaded #{length(groups)} groups: #{inspect(Enum.map(groups, & &1.name))}"
        )

        Enum.each(groups, fn g ->
          Logger.debug(
            "SweepCompiler: group #{g.name} - target_query=#{inspect(g.target_query)}, static_targets=#{inspect(g.static_targets)}, agent_ids=#{inspect(g.agent_ids)}"
          )
        end)

        groups

      {:error, reason} ->
        Logger.warning("SweepCompiler: failed to load groups - #{inspect(reason)}")
        []
    end
  end

  defp load_profiles(profile_ids, _actor) when profile_ids == [], do: []

  defp load_profiles(profile_ids, actor) do
    query = Ash.Query.filter(SweepProfile, id in ^profile_ids)

    case Ash.read(query, actor: actor) do
      {:ok, profiles} ->
        profiles

      {:error, reason} ->
        Logger.warning("SweepCompiler: failed to load profiles - #{inspect(reason)}")
        []
    end
  end

  defp compile_group(group, profile_map, actor) do
    # Get profile settings as base
    profile = Map.get(profile_map, group.profile_id)

    # Build schedule
    schedule = compile_schedule(group)

    # Merge ports from profile and group overrides
    ports = merge_ports(profile, group)

    # Merge sweep modes from profile and group overrides
    modes = merge_modes(profile, group)

    # Guard against TCP modes without ports
    {ports, modes} = enforce_tcp_ports(ports, modes, group)

    # Drop modes the agent sweeper does not implement (historically "arp").
    modes = drop_unsupported_modes(modes, group)

    # Build targets from static CIDRs/IPs and device targets from SRQL rows.
    {targets, device_targets} = compile_targets(group, actor, modes)

    # Build settings from profile with overrides
    settings = compile_settings(profile, group)
    banner_grab = compile_banner_grab(profile, group)

    compiled = %{
      "id" => group.id,
      "sweep_group_id" => group.id,
      "name" => group.name,
      "description" => group.description,
      "schedule" => schedule,
      "targets" => targets,
      "ports" => ports,
      "modes" => modes,
      "banner_grab" => banner_grab,
      "settings" => settings
    }

    if device_targets == [] do
      compiled
    else
      Map.put(compiled, "device_targets", device_targets)
    end
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

  defp compile_targets(group, actor, modes) do
    # Start with static targets
    static_targets = group.static_targets || []

    # Get device targets from SRQL query if defined. These stay separate from
    # static CIDRs so the agent can preserve inventory context while scanning.
    device_targets =
      case group.target_query do
        nil -> []
        "" -> []
        query -> get_device_targets_from_query(query, group, actor, modes)
      end

    {Enum.uniq(static_targets), device_targets}
  end

  defp get_device_targets_from_query(query, group, _actor, modes) when is_binary(query) do
    query = normalize_target_query(query)

    query
    |> fetch_srql_device_targets(nil, %{}, group, modes)
    |> Map.values()
    |> Enum.sort_by(& &1["network"])
  rescue
    _ -> []
  end

  defp get_device_targets_from_query(_query, _group, _actor, _modes), do: []

  defp normalize_target_query(query) do
    SRQLQuery.ensure_target(query, :devices)
  end

  defp fetch_srql_device_targets(_query, _cursor, acc, _group, _modes) when is_nil(acc), do: %{}

  defp fetch_srql_device_targets(query, cursor, acc, group, modes) do
    case SRQLRunner.query_page(query,
           limit: srql_page_limit(),
           cursor: cursor,
           direction: "next",
           text_param_decoder: &decode_cidr_text_param/1
         ) do
      {:ok, %{rows: rows, next_cursor: next_cursor}} ->
        acc = add_device_targets(acc, rows, group, modes)

        if is_binary(next_cursor) do
          fetch_srql_device_targets(query, next_cursor, acc, group, modes)
        else
          acc
        end

      {:error, reason} ->
        Logger.warning("SweepCompiler: SRQL query failed - #{inspect(reason)}")
        acc
    end
  end

  defp srql_page_limit do
    Application.get_env(:serviceradar_core, :sweep_srql_page_limit, @srql_page_limit_default)
  end

  defp add_device_targets(acc, rows, group, modes) when is_list(rows) do
    Enum.reduce(rows, acc, &put_device_target_from_row(&1, &2, group, modes))
  end

  defp put_device_target_from_row(row, targets, group, modes) when is_map(row) do
    case Map.get(row, "ip") do
      value when is_binary(value) ->
        case normalize_device_ip_target(value) do
          nil ->
            targets

          target ->
            Map.put_new(targets, target, device_target_from_row(row, target, group, modes))
        end

      _ ->
        targets
    end
  end

  defp put_device_target_from_row(_row, targets, _group, _modes), do: targets

  defp device_target_from_row(row, target, group, modes) do
    metadata =
      %{
        "sweep_group_id" => group.id,
        "target_query" => group.target_query
      }
      |> maybe_put_string("device_uid", Map.get(row, "uid"))
      |> maybe_put_string("hostname", Map.get(row, "hostname"))
      |> maybe_put_discovery_sources(row)

    %{
      "network" => target,
      "sweep_modes" => modes,
      "query_label" => group.name,
      "source" => "srql",
      "metadata" => metadata
    }
  end

  defp maybe_put_string(metadata, _key, value) when value in [nil, ""], do: metadata

  defp maybe_put_string(metadata, key, value) when is_binary(value),
    do: Map.put(metadata, key, value)

  defp maybe_put_string(metadata, key, value), do: Map.put(metadata, key, to_string(value))

  defp maybe_put_discovery_sources(metadata, row) do
    case Map.get(row, "discovery_sources") do
      sources when is_list(sources) ->
        sources = sources |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

        if sources == [] do
          metadata
        else
          Map.put(metadata, "discovery_sources", Enum.join(sources, ","))
        end

      source when is_binary(source) and source != "" ->
        Map.put(metadata, "discovery_sources", source)

      _ ->
        metadata
    end
  end

  defp normalize_device_ip_target(value) when is_binary(value) do
    value = String.trim(value)

    if valid_ip_address?(value), do: value
  end

  defp valid_ip_address?(value) do
    value != "" and match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(value)))
  end

  defp decode_cidr_text_param(value) when is_binary(value) do
    if String.contains?(value, "/") do
      case Cidr.dump_to_native(value, []) do
        {:ok, inet} -> {:ok, inet}
        _ -> {:ok, value}
      end
    else
      {:ok, value}
    end
  end

  defp merge_ports(nil, group), do: normalize_ports_override(group.ports, [])

  defp merge_ports(profile, group) do
    # Group ports override profile ports if set (treat empty override as inherit)
    normalize_ports_override(group.ports, profile.ports || [])
  end

  defp normalize_ports_override(nil, inherited), do: inherited
  defp normalize_ports_override([], inherited), do: inherited
  defp normalize_ports_override(ports, _inherited), do: ports

  defp enforce_tcp_ports(ports, modes, group) do
    modes = modes || []

    tcp_modes = Enum.filter(modes, &(&1 in ["tcp", "tcp_connect"]))

    if ports == [] and tcp_modes != [] do
      Logger.warning(
        "SweepCompiler: TCP mode enabled but ports empty for group #{group.name} (#{group.id}); dropping TCP modes"
      )

      filtered_modes = Enum.reject(modes, &(&1 in ["tcp", "tcp_connect"]))
      {ports, filtered_modes}
    else
      {ports, modes}
    end
  end

  # Modes the Go sweeper actually executes. Profile/UI historically offered
  # "arp", but parseSweepModes ignores it.
  @agent_supported_modes ["icmp", "tcp", "tcp_connect", "mtr"]

  defp drop_unsupported_modes(modes, group) do
    modes = modes || []
    {supported, dropped} = Enum.split_with(modes, &(&1 in @agent_supported_modes))

    if dropped != [] do
      Logger.debug(
        "SweepCompiler: dropping unsupported modes #{inspect(dropped)} for group #{group.name} (#{group.id})"
      )
    end

    supported
  end

  # A group with no profile and no explicit modes is ICMP-only. Enabling TCP
  # here would immediately trip enforce_tcp_ports/3 and drop TCP anyway.
  defp merge_modes(nil, group), do: normalize_modes_override(group.sweep_modes, ["icmp"])

  defp merge_modes(profile, group) do
    normalize_modes_override(group.sweep_modes, profile.sweep_modes || ["icmp", "tcp"])
  end

  defp normalize_modes_override(nil, inherited), do: inherited
  defp normalize_modes_override([], inherited), do: inherited
  defp normalize_modes_override(modes, _inherited), do: modes

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

    # Apply group overrides, excluding top-level phase blocks.
    overrides = Map.drop(group.overrides || %{}, ["banner_grab", :banner_grab])
    Map.merge(base_settings, overrides)
  end

  defp compile_banner_grab(profile, group) do
    profile
    |> profile_banner_grab()
    |> merge_banner_grab_override(group.overrides || %{})
    |> normalize_banner_grab()
  end

  defp profile_banner_grab(nil), do: BannerGrab.default_input()
  defp profile_banner_grab(%{banner_grab: nil}), do: BannerGrab.default_input()
  defp profile_banner_grab(%{banner_grab: banner_grab}), do: banner_grab

  defp merge_banner_grab_override(banner_grab, %{"banner_grab" => override})
       when is_map(override),
       do: Map.merge(map_from_banner_grab(banner_grab), override)

  defp merge_banner_grab_override(banner_grab, %{banner_grab: override}) when is_map(override),
    do: Map.merge(map_from_banner_grab(banner_grab), override)

  defp merge_banner_grab_override(banner_grab, _overrides), do: banner_grab

  defp normalize_banner_grab(banner_grab) do
    banner_grab = map_from_banner_grab(banner_grab)

    %{
      "enabled" => Map.get(banner_grab, :enabled, Map.get(banner_grab, "enabled", false)),
      "protocols" =>
        normalize_banner_protocols(
          Map.get(banner_grab, :protocols, Map.get(banner_grab, "protocols", []))
        ),
      "ports" =>
        normalize_banner_ports(Map.get(banner_grab, :ports, Map.get(banner_grab, "ports", %{}))),
      "connect_timeout_ms" => banner_int(banner_grab, :connect_timeout_ms, 2_000),
      "read_timeout_ms" => banner_int(banner_grab, :read_timeout_ms, 2_000),
      "max_banner_bytes" => banner_int(banner_grab, :max_banner_bytes, 1_024),
      "max_concurrency_per_host" => banner_int(banner_grab, :max_concurrency_per_host, 4),
      "max_global_concurrency" => banner_int(banner_grab, :max_global_concurrency, 256),
      "max_probe_rate_per_second" => banner_int(banner_grab, :max_probe_rate_per_second, 0),
      "max_candidate_queue" => banner_int(banner_grab, :max_candidate_queue, 8_192),
      "match_batch_size" => banner_int(banner_grab, :match_batch_size, 256),
      "match_batch_max_bytes" => banner_int(banner_grab, :match_batch_max_bytes, 1_048_576),
      "min_reprobe_interval_s" => banner_int(banner_grab, :min_reprobe_interval_s, 86_400),
      "per_host_rate_limit_ms" => banner_int(banner_grab, :per_host_rate_limit_ms, 100)
    }
  end

  defp map_from_banner_grab(%_{} = banner_grab) do
    banner_grab
    |> Map.from_struct()
    |> Map.drop([:__meta__, :__metadata__, :aggregates, :calculations])
  end

  defp map_from_banner_grab(banner_grab) when is_map(banner_grab), do: banner_grab
  defp map_from_banner_grab(_banner_grab), do: BannerGrab.default_input()

  defp normalize_banner_protocols(protocols) when is_list(protocols) do
    protocols
    |> Enum.map(&to_string/1)
    |> Enum.filter(
      &(&1 in Enum.map(BannerGrab.protocols(), fn protocol -> Atom.to_string(protocol) end))
    )
    |> Enum.uniq()
  end

  defp normalize_banner_protocols(_protocols), do: []

  defp normalize_banner_ports(ports) when is_map(ports) do
    Map.new(ports, fn {protocol, values} ->
      {to_string(protocol), normalize_port_list(values)}
    end)
  end

  defp normalize_banner_ports(_ports), do: %{}

  defp normalize_port_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_integer/1)
    |> Enum.filter(&(&1 >= 1 and &1 <= 65_535))
    |> Enum.uniq()
  end

  defp normalize_port_list(_values), do: []

  defp banner_int(banner_grab, key, default) do
    case Map.get(banner_grab, key, Map.get(banner_grab, Atom.to_string(key), default)) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_int(value, default)
      _ -> default
    end
  end

  defp parse_int(value, default) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> default
    end
  end
end
