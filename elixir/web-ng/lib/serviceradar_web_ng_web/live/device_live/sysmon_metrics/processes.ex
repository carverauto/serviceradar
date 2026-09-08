defmodule ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Processes do
  @moduledoc false

  import ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Common
  import ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Query

  require Logger

  @process_query_limit 10_000
  @process_sparkline_limit 60

  def load_process_metrics(_srql_module, [], _scope), do: []

  def load_process_metrics(srql_module, filter_tokens, scope) do
    cpu_query = process_metric_query("process.cpu_usage", filter_tokens)
    memory_query = process_metric_query("process.memory_usage", filter_tokens)

    with {:ok, cpu_rows} <- query_process_metric(srql_module, cpu_query, filter_tokens, scope),
         {:ok, memory_rows} <- query_process_metric(srql_module, memory_query, filter_tokens, scope) do
      normalize_process_rows(cpu_rows, memory_rows)
    else
      {:error, _reason} -> []
    end
  end

  defp query_process_metric(srql_module, query, filter_tokens, scope) do
    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        {:ok, results}

      {:ok, other} ->
        Logger.warning(
          "Unexpected sysmon process timeseries SRQL response for filters #{inspect(filter_tokens)}: #{inspect(other)}"
        )

        {:error, {:unexpected_response, other}}

      {:error, reason} ->
        Logger.warning(
          "Failed to load sysmon process timeseries for filters #{inspect(filter_tokens)}: #{format_error(reason)}"
        )

        {:error, reason}
    end
  end

  defp process_metric_query(metric_name, filter_tokens) do
    timeseries_metric_query(
      "sysmon.process",
      metric_name,
      filter_tokens,
      nil,
      @process_query_limit,
      time_range: "last_15m",
      bucket?: false
    )
  end

  defp normalize_process_rows(cpu_rows, memory_rows) when is_list(cpu_rows) and is_list(memory_rows) do
    memory_by_process = latest_process_metric_by_identity(memory_rows, "memory_usage")
    # Per-process CPU history so the table can render a sparkline; a single
    # latest sample hides process spikes (§31.1). Capped + time-sorted.
    cpu_history_by_process = process_metric_history_by_identity(cpu_rows, "cpu_usage")

    cpu_rows
    |> latest_process_metric_by_identity("cpu_usage")
    |> Enum.map(fn {identity, row} ->
      memory_row = Map.get(memory_by_process, identity, %{})

      row
      |> Map.put("memory_usage", Map.get(memory_row, "memory_usage"))
      |> Map.put("_cpu_sparkline", Map.get(cpu_history_by_process, identity, []))
      |> Map.put_new("status", Map.get(memory_row, "status"))
      |> Map.put_new("start_time", Map.get(memory_row, "start_time"))
    end)
    |> Enum.sort_by(&process_cpu_sort_key/1, :desc)
  end

  defp normalize_process_rows(_cpu_rows, _memory_rows), do: []

  defp latest_process_metric_by_identity(rows, value_field) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.map(&normalize_process_metric_row(&1, value_field))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&timestamp_sort_key/1, :desc)
    |> Enum.reduce(%{}, fn row, acc ->
      Map.put_new(acc, process_identity(row), row)
    end)
  end

  defp process_metric_history_by_identity(rows, value_field) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.map(&normalize_process_metric_row(&1, value_field))
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(%{}, fn row, acc ->
      with {:ok, dt} <- parse_datetime(Map.get(row, "timestamp")),
           value when is_number(value) <- parse_number(Map.get(row, value_field)) do
        Map.update(acc, process_identity(row), [{dt, value}], fn points ->
          [{dt, value} | points]
        end)
      else
        _ -> acc
      end
    end)
    |> Map.new(fn {identity, points} ->
      sorted =
        points
        |> Enum.sort_by(fn {dt, _value} -> DateTime.to_unix(dt, :millisecond) end)
        |> Enum.take(-@process_sparkline_limit)

      {identity, sorted}
    end)
  end

  defp normalize_process_metric_row(row, value_field) when is_map(row) do
    tags = map_value(row, "tags") || %{}

    with pid when not is_nil(pid) <- map_value(tags, "pid"),
         name when is_binary(name) <- map_value(tags, "name") do
      %{
        "pid" => pid,
        "name" => name,
        "status" => map_value(tags, "status"),
        "start_time" => map_value(tags, "start_time"),
        "timestamp" => map_value(row, "timestamp"),
        value_field => map_value(row, "value")
      }
    else
      _ -> nil
    end
  end

  defp normalize_process_metric_row(_row, _value_field), do: nil

  defp process_identity(row) when is_map(row), do: {Map.get(row, "pid"), Map.get(row, "name")}
  defp process_identity(_), do: {nil, nil}

  defp process_cpu_sort_key(row) when is_map(row) do
    case parse_number(Map.get(row, "cpu_usage")) do
      value when is_number(value) -> value
      _ -> -1
    end
  end

  defp process_cpu_sort_key(_), do: -1
end
