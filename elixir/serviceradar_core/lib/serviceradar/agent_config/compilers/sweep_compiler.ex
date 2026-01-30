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

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Repo
  alias ServiceRadar.SweepJobs.{SweepGroup, SweepProfile}

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
    gateway_id = opts[:gateway_id]

    # Load sweep groups for this partition/agent/gateway
    groups = load_sweep_groups(partition, agent_id, gateway_id, actor)

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

    # Compute config hash for change detection
    config_hash = config_hash(compiled_groups)

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

  defp load_sweep_groups(partition, agent_id, gateway_id, actor) do
    query =
      SweepGroup
      |> Ash.Query.for_read(:for_agent_partition, %{
        partition: partition,
        agent_id: agent_id,
        gateway_id: gateway_id
      })

    Logger.debug(
      "SweepCompiler: loading groups for partition=#{inspect(partition)}, agent_id=#{inspect(agent_id)}, gateway_id=#{inspect(gateway_id)}"
    )

    case Ash.read(query, actor: actor) do
      {:ok, groups} ->
        Logger.debug(
          "SweepCompiler: loaded #{length(groups)} groups: #{inspect(Enum.map(groups, & &1.name))}"
        )

        Enum.each(groups, fn g ->
          Logger.debug(
            "SweepCompiler: group #{g.name} - target_query=#{inspect(g.target_query)}, static_targets=#{inspect(g.static_targets)}, gateway_id=#{inspect(g.gateway_id)}"
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
    query =
      SweepProfile
      |> Ash.Query.filter(id in ^profile_ids)

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

    # Build targets from SRQL query and static targets
    targets = compile_targets(group, actor)

    # Merge ports from profile and group overrides
    ports = merge_ports(profile, group)

    # Merge sweep modes from profile and group overrides
    modes = merge_modes(profile, group)

    # Guard against TCP modes without ports
    {ports, modes} = enforce_tcp_ports(ports, modes, group)

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

  defp compile_targets(group, actor) do
    # Start with static targets
    static_targets = group.static_targets || []

    # Get targets from SRQL query if defined
    srql_targets =
      case group.target_query do
        nil -> []
        "" -> []
        query -> get_targets_from_query(query, actor)
      end

    # Combine and deduplicate
    (static_targets ++ srql_targets)
    |> Enum.uniq()
  end

  defp get_targets_from_query(query, _actor) when is_binary(query) do
    query = normalize_target_query(query)

    query
    |> fetch_srql_device_ips(nil, MapSet.new())
    |> MapSet.to_list()
    |> Enum.sort()
  rescue
    _ -> []
  end

  defp get_targets_from_query(_query, _actor), do: []

  defp normalize_target_query(query) do
    query = String.trim(query)

    if String.starts_with?(query, "in:") do
      query
    else
      "in:devices " <> query
    end
  end

  defp fetch_srql_device_ips(_query, _cursor, acc) when is_nil(acc), do: MapSet.new()

  defp fetch_srql_device_ips(query, cursor, acc) do
    case translate_srql(query, cursor) do
      {:ok, %{"sql" => sql} = translation} when is_binary(sql) ->
        params = Map.get(translation, "params", [])

        with {:ok, decoded_params} <- decode_params(params),
             {:ok, result} <- run_sql(sql, decoded_params) do
          acc = add_ips(acc, result)
          next_cursor = next_cursor(translation, result)

          if is_binary(next_cursor) do
            fetch_srql_device_ips(query, next_cursor, acc)
          else
            acc
          end
        else
          {:error, reason} ->
            Logger.warning("SweepCompiler: SRQL query failed - #{inspect(reason)}")
            acc
        end

      {:error, reason} ->
        Logger.warning("SweepCompiler: SRQL translate failed - #{inspect(reason)}")
        acc

      other ->
        Logger.warning("SweepCompiler: SRQL translate returned #{inspect(other)}")
        acc
    end
  end

  defp translate_srql(query, cursor) do
    case ServiceRadarSRQL.Native.translate(query, srql_page_limit(), cursor, "next", nil) do
      {:ok, json} when is_binary(json) -> Jason.decode(json)
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_srql_translate_result, other}}
    end
  end

  defp srql_page_limit do
    Application.get_env(:serviceradar_core, :sweep_srql_page_limit, @srql_page_limit_default)
  end

  defp run_sql(sql, params) do
    Ecto.Adapters.SQL.query(Repo, sql, params)
  end

  defp add_ips(acc, %Postgrex.Result{columns: columns, rows: rows}) do
    case Enum.find_index(columns, &(&1 == "ip")) do
      nil ->
        acc

      index ->
        Enum.reduce(rows, acc, &put_ip_from_row(&1, &2, index))
    end
  end

  defp add_ips(acc, _), do: acc

  defp put_ip_from_row(row, set, index) do
    case Enum.at(row, index) do
      value when is_binary(value) -> MapSet.put(set, value)
      _ -> set
    end
  end

  defp next_cursor(translation, %Postgrex.Result{rows: rows}) do
    limit = get_in(translation, ["pagination", "limit"])
    candidate = get_in(translation, ["pagination", "next_cursor"])

    if is_integer(limit) and is_binary(candidate) and length(rows) >= limit do
      candidate
    else
      nil
    end
  end

  defp next_cursor(_translation, _result), do: nil

  defp decode_params(params) when is_list(params) do
    params
    |> Enum.reduce_while({:ok, []}, fn param, {:ok, acc} ->
      case decode_param(param) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_params(_), do: {:error, :invalid_srql_params}

  defp decode_param(%{"t" => "text", "v" => value}) when is_binary(value), do: {:ok, value}
  defp decode_param(%{"t" => "bool", "v" => value}) when is_boolean(value), do: {:ok, value}
  defp decode_param(%{"t" => "int", "v" => value}) when is_integer(value), do: {:ok, value}

  defp decode_param(%{"t" => "int_array", "v" => values}) when is_list(values) do
    if Enum.all?(values, &is_integer/1) do
      {:ok, values}
    else
      {:error, :invalid_int_array_param}
    end
  end

  defp decode_param(%{"t" => "float", "v" => value}) when is_float(value), do: {:ok, value}
  defp decode_param(%{"t" => "float", "v" => value}) when is_integer(value), do: {:ok, value / 1}

  defp decode_param(%{"t" => "text_array", "v" => values}) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      {:ok, values}
    else
      {:error, :invalid_text_array_param}
    end
  end

  defp decode_param(%{"t" => "timestamptz", "v" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_timestamptz_param}
    end
  end

  defp decode_param(%{"t" => "uuid", "v" => value}) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, binary_uuid} -> {:ok, binary_uuid}
      :error -> {:error, :invalid_uuid_param}
    end
  end

  defp decode_param(_), do: {:error, :invalid_srql_param}

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
