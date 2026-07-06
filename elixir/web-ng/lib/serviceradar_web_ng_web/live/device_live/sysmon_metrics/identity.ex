defmodule ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Identity do
  @moduledoc false

  import ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Common
  import ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Query

  alias ServiceRadar.Inventory.MergeAudit

  require Ash.Query
  require Logger

  # Cap the merge-chain walk so a pathological chain can't fan out unbounded.
  @max_merge_depth 25

  def sysmon_identity(device_row, device_uid) do
    device_row = if is_map(device_row), do: device_row, else: %{}

    device_uid =
      case Map.get(device_row, "uid") || Map.get(device_row, :uid) || device_uid do
        value when is_binary(value) -> String.trim(value)
        _ -> ""
      end

    agent_id =
      device_row
      |> then(&(Map.get(&1, "agent_id") || Map.get(&1, :agent_id)))
      |> case do
        value when is_binary(value) -> String.trim(value)
        _ -> ""
      end

    host_id =
      device_row
      |> then(
        &(Map.get(&1, "host_id") || Map.get(&1, :host_id) || Map.get(&1, "hostname") ||
            Map.get(&1, :hostname))
      )
      |> case do
        value when is_binary(value) -> String.trim(value)
        _ -> ""
      end

    %{}
    |> maybe_put_identity(:device_uid, device_uid)
    |> maybe_put_identity(:agent_id, agent_id)
    |> maybe_put_identity(:host_id, host_id)
  end

  def resolve_sysmon_filter_tokens(_srql_module, identity, _scope) when identity == %{} or identity == nil, do: []

  def resolve_sysmon_filter_tokens(srql_module, identity, scope) do
    # Widen the device dimension across every UID this device has been keyed by
    # (current canonical UID + all pre-merge UIDs recorded in merge_audit) so a
    # merged device's detail page shows the full metric history instead of only
    # the short post-merge window. This is read-only alias resolution — the
    # historical metric rows keep their original device_id, no destructive re-key.
    device_uids =
      identity
      |> Map.get(:device_uid)
      |> historical_device_uids(scope)

    device_tokens = device_uid_filter_tokens(device_uids)
    agent_tokens = sysmon_filter_tokens(identity, :agent_id, "agent_id")
    host_tokens = sysmon_filter_tokens(identity, :host_id, "agent_id")

    cond do
      device_tokens != [] and sysmon_filter_has_data?(srql_module, device_tokens, scope) ->
        device_tokens

      agent_tokens != [] and sysmon_filter_has_data?(srql_module, agent_tokens, scope) ->
        agent_tokens

      host_tokens != [] and sysmon_filter_has_data?(srql_module, host_tokens, scope) ->
        host_tokens

      true ->
        []
    end
  end

  @doc """
  Returns every device UID this device has been keyed by: the current canonical
  UID plus all pre-merge UIDs that were merged into it (transitively) per the
  `merge_audit` trail. Falls back to just the canonical UID on any lookup error
  so metric loading never depends on the merge trail being reachable.
  """
  def historical_device_uids(device_uid, scope) when is_binary(device_uid) do
    case String.trim(device_uid) do
      "" ->
        []

      canonical ->
        collect_merged_from(MapSet.new([canonical]), [canonical], scope, 0)
    end
  rescue
    error ->
      Logger.debug("merge_audit history lookup failed for #{inspect(device_uid)}: #{inspect(error)}")
      normalize_uid_list([device_uid])
  end

  def historical_device_uids(_device_uid, _scope), do: []

  defp collect_merged_from(acc, [], _scope, _depth), do: MapSet.to_list(acc)

  defp collect_merged_from(acc, _frontier, _scope, depth) when depth >= @max_merge_depth do
    MapSet.to_list(acc)
  end

  defp collect_merged_from(acc, frontier, scope, depth) do
    new_ids =
      frontier
      |> Enum.flat_map(&merged_from_ids(&1, scope))
      |> Enum.reject(&MapSet.member?(acc, &1))
      |> Enum.uniq()

    if new_ids == [] do
      MapSet.to_list(acc)
    else
      acc = Enum.reduce(new_ids, acc, &MapSet.put(&2, &1))
      collect_merged_from(acc, new_ids, scope, depth + 1)
    end
  end

  defp merged_from_ids(to_device_id, scope) do
    MergeAudit
    |> Ash.Query.for_read(:merged_from, %{to_device_id: to_device_id}, scope: scope)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, rows} ->
        rows
        |> Enum.map(&Map.get(&1, :from_device_id))
        |> normalize_uid_list()

      {:error, _reason} ->
        []
    end
  end

  defp normalize_uid_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp maybe_put_identity(identity, _key, ""), do: identity

  defp maybe_put_identity(identity, key, value) do
    if is_binary(value) and String.trim(value) != "" do
      Map.put(identity, key, value)
    else
      identity
    end
  end

  defp sysmon_filter_has_data?(srql_module, filter_tokens, scope) do
    Enum.any?(
      [
        {"sysmon.cpu", "cpu.usage_percent"},
        {"sysmon.memory", "memory.used_percent"},
        {"sysmon.disk", "disk.used_percent"},
        {"sysmon.process", "process.cpu_usage"},
        {"sysmon.process", "process.count"}
      ],
      fn {metric_type, metric_name} ->
        sysmon_timeseries_has_data?(srql_module, metric_type, metric_name, filter_tokens, scope)
      end
    )
  end

  defp sysmon_timeseries_has_data?(srql_module, metric_type, metric_name, filter_tokens, scope) do
    query =
      timeseries_metric_query(
        metric_type,
        metric_name,
        filter_tokens,
        nil,
        1,
        time_range: "last_24h",
        bucket?: false
      )

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => rows}} when is_list(rows) ->
        rows != []

      {:ok, other} ->
        Logger.warning(
          "Unexpected sysmon #{metric_type}/#{metric_name} presence probe response for filters #{inspect(filter_tokens)}: #{inspect(other)}"
        )

        false

      {:error, reason} ->
        Logger.warning(
          "Failed sysmon #{metric_type}/#{metric_name} presence probe for filters #{inspect(filter_tokens)}: #{format_error(reason)}"
        )

        false
    end
  end

  defp sysmon_filter_tokens(identity, key, field) do
    value = Map.get(identity, key)

    if is_binary(value) and String.trim(value) != "" do
      ["#{field}:\"#{escape_value(value)}\""]
    else
      []
    end
  end
end
