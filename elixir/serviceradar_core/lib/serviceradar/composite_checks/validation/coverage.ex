defmodule ServiceRadar.CompositeChecks.Validation.Coverage do
  @moduledoc """
  Selects the sweep groups that already cover a device from a vantage agent
  and returns the compiled scan settings those groups would use.
  """

  alias ServiceRadar.AgentConfig.Compilers.SweepCompiler
  alias ServiceRadar.Observability.SRQLRunner
  alias ServiceRadar.SRQLQuery
  alias ServiceRadar.SweepJobs.SweepGroup
  alias ServiceRadar.SweepJobs.SweepProfile

  require Logger

  @type settings :: %{
          modes: [String.t()],
          ports: [integer()],
          settings: map(),
          timeout_ms: pos_integer(),
          sweep_group_ids: [String.t()],
          profile_ids: [String.t()]
        }

  @spec cover(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, settings()} | {:error, :uncovered}
  def cover(device_uid, ip, partition, agent_id, opts \\ [])
      when is_binary(device_uid) and is_binary(ip) and is_binary(agent_id) do
    actor = Keyword.get(opts, :actor) || system_actor()
    partition = if is_binary(partition) and partition != "", do: partition, else: "default"

    groups = load_groups(agent_id, partition, actor)
    covering = Enum.filter(groups, &covers?(&1, device_uid, ip, actor))

    case covering do
      [] -> {:error, :uncovered}
      matched -> {:ok, merge_settings(matched, actor)}
    end
  end

  defp load_groups(agent_id, partition, actor) do
    SweepGroup
    |> Ash.Query.for_read(:for_agent_partition, %{agent_id: agent_id, partition: partition})
    |> Ash.read!(actor: actor)
  end

  defp covers?(group, device_uid, ip, actor) do
    static_hit?(group.static_targets || [], ip) or
      query_hit?(group.target_query, device_uid, actor)
  end

  defp static_hit?(targets, ip) do
    Enum.any?(targets, fn target ->
      target = to_string(target)

      target == ip or cidr_contains?(target, ip)
    end)
  end

  defp query_hit?(query, _device_uid, _actor) when query in [nil, ""], do: false

  defp query_hit?(query, device_uid, _actor) do
    constrained = constrain_uid(query, device_uid)

    case SRQLRunner.query(constrained,
           limit: 1,
           text_param_decoder: &decode_cidr_text_param/1
         ) do
      {:ok, rows} ->
        Enum.any?(rows, fn row ->
          Map.get(row, "uid") == device_uid or Map.get(row, :uid) == device_uid
        end)

      {:error, reason} ->
        Logger.warning("validation coverage SRQL failed: #{inspect(reason)}")
        false
    end
  end

  defp constrain_uid(query, device_uid) do
    escaped = String.replace(to_string(device_uid), "\"", "\\\"")
    SRQLQuery.ensure_target(query, :devices) <> ~s( uid:"#{escaped}")
  end

  defp decode_cidr_text_param(value) when is_binary(value) do
    if String.contains?(value, "/") do
      case ServiceRadar.Types.Cidr.dump_to_native(value, []) do
        {:ok, inet} -> {:ok, inet}
        _ -> {:ok, value}
      end
    else
      {:ok, value}
    end
  end

  defp merge_settings(groups, actor) do
    compiled =
      Enum.map(groups, fn group ->
        profile = load_profile(group.profile_id, actor)
        SweepCompiler.compiled_scan_settings(group, profile)
      end)

    modes = compiled |> Enum.flat_map(& &1.modes) |> Enum.uniq()
    ports = compiled |> Enum.flat_map(& &1.ports) |> Enum.uniq() |> Enum.sort()

    timeouts =
      compiled
      |> Enum.map(&timeout_ms(&1.settings["timeout"]))
      |> Enum.min()

    %{
      modes: modes,
      ports: ports,
      settings: List.first(compiled).settings,
      timeout_ms: timeouts,
      sweep_group_ids: Enum.map(compiled, & &1.sweep_group_id),
      profile_ids: compiled |> Enum.map(& &1.profile_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    }
  end

  defp load_profile(nil, _actor), do: nil

  defp load_profile(id, actor) do
    case Ash.get(SweepProfile, id, actor: actor) do
      {:ok, profile} -> profile
      _ -> nil
    end
  end

  defp timeout_ms(value) when is_integer(value) and value > 0, do: value

  defp timeout_ms(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, rest} when n > 0 ->
        case String.trim(rest) do
          "ms" -> n
          "s" -> n * 1000
          "" -> n * 1000
          _ -> 3_000
        end

      _ ->
        3_000
    end
  end

  defp timeout_ms(_), do: 3_000

  defp cidr_contains?(target, ip) do
    case String.split(target, "/", parts: 2) do
      [base, prefix] ->
        with {bits, ""} <- Integer.parse(prefix),
             {:ok, net} <- :inet.parse_strict_address(String.to_charlist(base)),
             {:ok, addr} <- :inet.parse_strict_address(String.to_charlist(ip)) do
          same_prefix?(net, addr, bits)
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp same_prefix?({a, b, c, d}, {e, f, g, h}, bits) when bits in 0..32 do
    net = :binary.decode_unsigned(<<a, b, c, d>>)
    addr = :binary.decode_unsigned(<<e, f, g, h>>)
    mask = if bits == 0, do: 0, else: Bitwise.bsl(0xFFFFFFFF, 32 - bits)
    Bitwise.band(net, mask) == Bitwise.band(addr, mask)
  end

  defp same_prefix?(_, _, _), do: false

  defp system_actor, do: ServiceRadar.Actors.SystemActor.system(:validation_coverage)
end
