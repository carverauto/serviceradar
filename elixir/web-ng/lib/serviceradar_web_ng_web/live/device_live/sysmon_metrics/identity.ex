defmodule ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Identity do
  @moduledoc false

  import ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Common
  import ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Query

  require Logger

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
    device_tokens = sysmon_filter_tokens(identity, :device_uid, "uid")
    agent_tokens = sysmon_filter_tokens(identity, :agent_id, "agent_id")
    host_tokens = sysmon_filter_tokens(identity, :host_id, "host_id")

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
