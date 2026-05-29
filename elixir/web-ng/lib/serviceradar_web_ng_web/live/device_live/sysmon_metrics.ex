defmodule ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics do
  @moduledoc false

  alias ServiceRadarWebNGWeb.Dashboard.Engine
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Categories, as: CategoriesPlugin
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Table, as: TablePlugin
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries, as: TimeseriesPlugin
  alias ServiceRadarWebNGWeb.SRQL.Viz

  @metrics_limit 300
  @disk_panel_limit 6
  @disk_metrics_limit @metrics_limit * @disk_panel_limit
  @process_limit 25
  @process_query_limit 200

  defp escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp escape_value(other), do: escape_value(to_string(other))

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  def load_process_metrics(_srql_module, [], _scope), do: []

  def load_process_metrics(srql_module, filter_tokens, scope) do
    query = process_metrics_query(filter_tokens)

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        normalize_process_rows(results)

      {:ok, _} ->
        []

      {:error, _} ->
        []
    end
  end

  defp process_metrics_query(filter_tokens) do
    [
      "in:process_metrics",
      "time:last_15m"
    ]
    |> Kernel.++(filter_tokens)
    |> Kernel.++(["sort:timestamp:desc", "limit:#{@process_query_limit}"])
    |> Enum.join(" ")
  end

  defp normalize_process_rows(rows) when is_list(rows) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.sort_by(&timestamp_sort_key/1, :desc)
    |> Enum.reduce(%{}, fn row, acc ->
      Map.put_new(acc, process_identity(row), row)
    end)
    |> Map.values()
    |> Enum.sort_by(&process_cpu_sort_key/1, :desc)
    |> Enum.take(@process_limit)
  end

  defp normalize_process_rows(_), do: []

  defp process_identity(row) when is_map(row) do
    {Map.get(row, "pid"), Map.get(row, "name")}
  end

  defp process_identity(_), do: {nil, nil}

  defp process_cpu_sort_key(row) when is_map(row) do
    case parse_number(Map.get(row, "cpu_usage")) do
      value when is_number(value) -> value
      _ -> -1
    end
  end

  defp process_cpu_sort_key(_), do: -1

  def load_metric_sections(_srql_module, [], _scope), do: []

  def load_metric_sections(srql_module, filter_tokens, scope) do
    Enum.filter(
      [
        build_cpu_section(srql_module, filter_tokens, scope),
        build_memory_section(srql_module, filter_tokens, scope),
        build_disk_section(srql_module, filter_tokens, scope)
      ],
      & &1
    )
  end

  defp build_cpu_section(srql_module, filter_tokens, scope) do
    query = metric_query("cpu_metrics", filter_tokens, nil, "usage_percent", @metrics_limit)

    base = %{
      key: "cpu",
      title: "CPU",
      subtitle: "last 24h · 5m buckets · avg across cores",
      query: query,
      panels: [],
      error: nil,
      header_value: nil,
      header_stats: nil
    }

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) and results != [] ->
        normalized = normalize_metric_results(results, "usage_percent")
        viz = timeseries_viz("usage_percent", nil)
        panels = build_metric_panels(%{"results" => normalized, "viz" => viz}, normalized, nil)
        header_value = latest_metric_value(normalized, "usage_percent")
        header_stats = metric_stats(normalized, "usage_percent")
        %{base | panels: panels, header_value: header_value, header_stats: header_stats}

      {:ok, %{"results" => results}} when is_list(results) ->
        base

      {:ok, other} ->
        %{base | error: "unexpected SRQL response: #{inspect(other)}"}

      {:error, reason} ->
        %{base | error: "SRQL error: #{format_error(reason)}"}
    end
  end

  defp build_memory_section(srql_module, filter_tokens, scope) do
    series_limit = @metrics_limit
    used_query = metric_query("memory_metrics", filter_tokens, nil, "used_bytes", series_limit)

    available_query =
      metric_query("memory_metrics", filter_tokens, nil, "available_bytes", series_limit)

    base = %{
      key: "memory",
      title: "Memory",
      subtitle: "last 24h · 5m buckets · avg",
      query: used_query,
      panels: [],
      error: nil
    }

    with {:ok, %{"results" => used_rows}} when is_list(used_rows) <-
           srql_module.query(used_query, %{scope: scope}),
         {:ok, %{"results" => available_rows}} when is_list(available_rows) <-
           srql_module.query(available_query, %{scope: scope}) do
      combined =
        used_rows
        |> build_series_rows("Used", "bytes")
        |> Kernel.++(build_series_rows(available_rows, "Available", "bytes"))
        |> sort_rows_by_timestamp()

      if combined == [] do
        base
      else
        viz = timeseries_viz("bytes", "series")
        panels = build_metric_panels(%{"results" => combined, "viz" => viz}, combined, "series")

        panels =
          apply_panel_assigns(panels, %{
            combine_all_series: true,
            combined_title: "Memory (Used vs Available)"
          })

        %{base | panels: panels}
      end
    else
      {:ok, other} ->
        %{base | error: "unexpected SRQL response: #{inspect(other)}"}

      {:error, reason} ->
        %{base | error: "SRQL error: #{format_error(reason)}"}
    end
  end

  defp build_disk_section(srql_module, filter_tokens, scope) do
    series_field = resolve_disk_series_field(srql_module, filter_tokens, scope)

    used_query =
      metric_query("disk_metrics", filter_tokens, series_field, "used_bytes", @disk_metrics_limit)

    total_query =
      metric_query(
        "disk_metrics",
        filter_tokens,
        series_field,
        "total_bytes",
        @disk_metrics_limit
      )

    base = %{
      key: "disk",
      title: "Disk",
      subtitle: "last 24h · 5m buckets · avg",
      query: used_query,
      panels: [],
      error: nil
    }

    with {:ok, %{"results" => used_rows}} when is_list(used_rows) <-
           srql_module.query(used_query, %{scope: scope}),
         {:ok, %{"results" => total_rows}} when is_list(total_rows) <-
           srql_module.query(total_query, %{scope: scope}) do
      panels = build_disk_panels(used_rows, total_rows)
      %{base | panels: panels}
    else
      {:ok, other} ->
        %{base | error: "unexpected SRQL response: #{inspect(other)}"}

      {:error, reason} ->
        %{base | error: "SRQL error: #{format_error(reason)}"}
    end
  end

  defp resolve_disk_series_field(srql_module, filter_tokens, scope) do
    probe_query = metric_probe_query("disk_metrics", filter_tokens)

    case srql_module.query(probe_query, %{scope: scope}) do
      {:ok, %{"results" => [row | _]}} when is_map(row) ->
        cond do
          present?(Map.get(row, "device_name")) -> "device_name"
          present?(Map.get(row, "partition")) -> "partition"
          present?(Map.get(row, "mount_point")) -> "mount_point"
          true -> "mount_point"
        end

      _ ->
        "mount_point"
    end
  end

  defp build_disk_panels(used_rows, total_rows) do
    used_by_series = group_rows_by_series(used_rows)
    total_by_series = group_rows_by_series(total_rows)

    used_by_series
    |> disk_series_keys(total_by_series)
    |> Enum.take(@disk_panel_limit)
    |> Enum.map(&build_disk_series_panels(&1, used_by_series, total_by_series))
    |> Enum.flat_map(& &1)
  end

  defp disk_series_keys(used_by_series, total_by_series) do
    (Map.keys(used_by_series) ++ Map.keys(total_by_series))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp build_disk_series_panels(series, used_by_series, total_by_series) do
    combined =
      used_by_series
      |> Map.get(series, [])
      |> build_series_rows("Used", "bytes")
      |> Kernel.++(build_series_rows(Map.get(total_by_series, series, []), "Total", "bytes"))
      |> sort_rows_by_timestamp()

    if combined == [] do
      []
    else
      viz = timeseries_viz("bytes", "series")

      %{"results" => combined, "viz" => viz}
      |> build_metric_panels(combined, "series")
      |> Enum.map(fn panel ->
        Map.put(panel, :title, "Disk · #{series_label(series)}")
      end)
    end
  end

  defp group_rows_by_series(rows) when is_list(rows) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.group_by(fn row ->
      series_label(Map.get(row, "series"))
    end)
  end

  defp group_rows_by_series(_), do: %{}

  defp series_label(nil), do: "unknown"

  defp series_label(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "unknown"
      other -> other
    end
  end

  defp series_label(value), do: series_label(to_string(value))

  defp build_series_rows(rows, series_label, output_field) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.reduce([], fn row, acc ->
      value = Map.get(row, "value")

      if is_nil(value) do
        acc
      else
        [
          %{
            "timestamp" => Map.get(row, "timestamp"),
            output_field => value,
            "series" => series_label
          }
          | acc
        ]
      end
    end)
    |> Enum.reverse()
  end

  defp sort_rows_by_timestamp(rows) when is_list(rows) do
    Enum.sort_by(rows, &timestamp_sort_key/1)
  end

  defp timestamp_sort_key(row) when is_map(row) do
    case parse_datetime(Map.get(row, "timestamp")) do
      {:ok, dt} -> DateTime.to_unix(dt, :millisecond)
      _ -> 0
    end
  end

  defp timestamp_sort_key(_), do: 0

  defp parse_datetime(%DateTime{} = dt), do: {:ok, dt}

  defp parse_datetime(%NaiveDateTime{} = ndt) do
    {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
  end

  defp parse_datetime(value) when is_binary(value) do
    value = String.trim(value)

    with {:error, _} <- DateTime.from_iso8601(value),
         {:ok, ndt} <- NaiveDateTime.from_iso8601(value) do
      {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
    else
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _} -> {:error, :invalid_datetime}
    end
  end

  defp parse_datetime(_), do: {:error, :invalid_datetime}

  defp parse_number(value) when is_integer(value), do: value * 1.0
  defp parse_number(value) when is_float(value), do: value

  defp parse_number(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      match?({_, ""}, Float.parse(value)) ->
        {v, ""} = Float.parse(value)
        v

      match?({_, ""}, Integer.parse(value)) ->
        {v, ""} = Integer.parse(value)
        v * 1.0

      true ->
        nil
    end
  end

  defp parse_number(_), do: nil

  defp latest_metric_value(rows, field) when is_list(rows) do
    rows
    |> latest_metric_tuple(field)
    |> extract_metric_value()
  end

  defp latest_metric_value(_rows, _field), do: nil

  defp latest_metric_tuple(rows, field) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(nil, &update_latest_metric(&1, field, &2))
  end

  defp extract_metric_value({_dt, value}), do: value
  defp extract_metric_value(_), do: nil

  defp update_latest_metric(row, field, acc) do
    with {:ok, dt} <- parse_datetime(Map.get(row, "timestamp")),
         value when is_number(value) <- parse_number(Map.get(row, field)) do
      pick_latest_metric({dt, value}, acc)
    else
      _ -> acc
    end
  end

  defp pick_latest_metric(current, nil), do: current

  defp pick_latest_metric({dt, _} = current, {prev_dt, _} = previous) do
    if DateTime.after?(dt, prev_dt), do: current, else: previous
  end

  defp metric_stats(rows, field) when is_list(rows) do
    {min, max, sum, count} =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.reduce({nil, nil, 0.0, 0}, &accumulate_metric_stat(&1, field, &2))

    if count > 0 do
      %{min: min, max: max, avg: sum / count}
    end
  end

  defp metric_stats(_rows, _field), do: nil

  defp accumulate_metric_stat(row, field, {min_v, max_v, sum_v, count_v}) do
    case parse_number(Map.get(row, field)) do
      value when is_number(value) ->
        {min_value(min_v, value), max_value(max_v, value), sum_v + value, count_v + 1}

      _ ->
        {min_v, max_v, sum_v, count_v}
    end
  end

  defp min_value(nil, value), do: value
  defp min_value(min_v, value) when value < min_v, do: value
  defp min_value(min_v, _value), do: min_v

  defp max_value(nil, value), do: value
  defp max_value(max_v, value) when value > max_v, do: value
  defp max_value(max_v, _value), do: max_v

  defp normalize_metric_results(results, target_field) when is_list(results) do
    Enum.map(results, fn
      row when is_map(row) ->
        value = Map.get(row, "value")

        if is_nil(value) do
          row
        else
          Map.put(row, target_field, value)
        end

      other ->
        other
    end)
  end

  defp normalize_metric_results(results, _target_field), do: results

  defp timeseries_viz(y_field, series_field) do
    suggestion =
      maybe_put_series(
        %{"kind" => "timeseries", "x" => "timestamp", "y" => y_field},
        series_field
      )

    %{"suggestions" => [suggestion]}
  end

  defp maybe_put_series(viz, nil), do: viz
  defp maybe_put_series(viz, ""), do: viz

  defp maybe_put_series(viz, series_field) do
    Map.put(viz, "series", series_field)
  end

  defp metric_probe_query(entity, filter_tokens) do
    [
      "in:#{entity}",
      "time:last_24h",
      "sort:timestamp:desc",
      "limit:1"
    ]
    |> Kernel.++(filter_tokens)
    |> Enum.join(" ")
  end

  defp build_metric_panels(resp, results, series_field) do
    srql_response = %{"results" => results, "viz" => extract_viz(resp)}

    panels =
      srql_response
      |> Engine.build_panels()
      |> prefer_visual_panels(results)
      |> drop_category_panels_when_timeseries()

    panels
    |> maybe_force_timeseries(results, series_field)
    |> drop_category_panels_when_timeseries()
  end

  defp apply_panel_assigns(panels, assigns) when is_list(panels) and is_map(assigns) do
    Enum.map(panels, fn panel ->
      Map.update(panel, :assigns, assigns, &Map.merge(&1, assigns))
    end)
  end

  defp apply_panel_assigns(panels, _assigns), do: panels

  defp extract_viz(resp) do
    case Map.get(resp, "viz") do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  defp prefer_visual_panels(panels, results) when is_list(panels) do
    has_non_table? = Enum.any?(panels, &(&1.plugin != TablePlugin))

    if results != [] and has_non_table? do
      Enum.reject(panels, &(&1.plugin == TablePlugin))
    else
      panels
    end
  end

  defp drop_category_panels_when_timeseries(panels) when is_list(panels) do
    has_timeseries = Enum.any?(panels, &(&1.plugin == TimeseriesPlugin))

    if has_timeseries do
      Enum.reject(panels, &(&1.plugin == CategoriesPlugin))
    else
      panels
    end
  end

  defp maybe_force_timeseries(panels, results, series_field) do
    has_visual = Enum.any?(panels, &(&1.plugin != TablePlugin))

    if has_visual do
      panels
    else
      case inferred_timeseries_viz(results, series_field) do
        nil ->
          panels

        viz ->
          %{"results" => results, "viz" => %{"suggestions" => [viz]}}
          |> Engine.build_panels()
          |> prefer_visual_panels(results)
      end
    end
  end

  defp inferred_timeseries_viz(results, series_field) do
    case Viz.infer(results) do
      {:timeseries, %{x: x, y: y}} ->
        base = %{"kind" => "timeseries", "x" => x, "y" => y}

        if is_binary(series_field) and String.trim(series_field) != "" do
          Map.put(base, "series", series_field)
        else
          base
        end

      _ ->
        nil
    end
  end

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

    %{}
    |> maybe_put_identity(:device_uid, device_uid)
    |> maybe_put_identity(:agent_id, agent_id)
  end

  defp maybe_put_identity(identity, _key, ""), do: identity

  defp maybe_put_identity(identity, key, value) do
    if is_binary(value) and String.trim(value) != "" do
      Map.put(identity, key, value)
    else
      identity
    end
  end

  def resolve_sysmon_filter_tokens(_srql_module, identity, _scope) when identity == %{} or identity == nil, do: []

  def resolve_sysmon_filter_tokens(srql_module, identity, scope) do
    device_tokens = sysmon_filter_tokens(identity, :device_uid, "device_id")
    agent_tokens = sysmon_filter_tokens(identity, :agent_id, "agent_id")

    cond do
      device_tokens != [] and sysmon_filter_has_data?(srql_module, device_tokens, scope) ->
        device_tokens

      agent_tokens != [] and sysmon_filter_has_data?(srql_module, agent_tokens, scope) ->
        agent_tokens

      true ->
        []
    end
  end

  defp sysmon_filter_has_data?(srql_module, filter_tokens, scope) do
    Enum.any?(
      ["cpu_metrics", "memory_metrics", "disk_metrics", "process_metrics"],
      &sysmon_entity_has_data?(srql_module, &1, filter_tokens, scope)
    )
  end

  defp sysmon_entity_has_data?(srql_module, entity, filter_tokens, scope) do
    query =
      Enum.join(
        [
          "in:#{entity}",
          Enum.join(filter_tokens, " "),
          "time:last_24h",
          "sort:timestamp:desc",
          "limit:1"
        ],
        " "
      )

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => rows}} when is_list(rows) -> rows != []
      _ -> false
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

  defp metric_query(entity, filter_tokens, series_field, value_field, limit) do
    series_field =
      case series_field do
        nil -> nil
        "" -> nil
        other -> other |> to_string() |> String.trim()
      end

    value_field =
      case value_field do
        "" -> nil
        other -> other |> to_string() |> String.trim()
      end

    tokens =
      [
        "in:#{entity}",
        "time:last_24h",
        "bucket:5m",
        "agg:avg"
      ]

    tokens =
      tokens
      |> maybe_add_token("series", series_field)
      |> maybe_add_token("value_field", value_field)
      |> Kernel.++(filter_tokens)
      |> Kernel.++(["sort:timestamp:desc", "limit:#{limit}"])

    Enum.join(tokens, " ")
  end

  defp maybe_add_token(tokens, _key, nil), do: tokens
  defp maybe_add_token(tokens, _key, ""), do: tokens

  defp maybe_add_token(tokens, key, value) do
    tokens ++ ["#{key}:#{value}"]
  end
end
