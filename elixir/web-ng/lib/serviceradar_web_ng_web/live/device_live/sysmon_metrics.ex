defmodule ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics do
  @moduledoc false

  alias ServiceRadarWebNGWeb.Dashboard.Engine
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Categories, as: CategoriesPlugin
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Table, as: TablePlugin
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries, as: TimeseriesPlugin
  alias ServiceRadarWebNGWeb.SRQL.Viz

  require Logger

  @metrics_limit 300
  @disk_metrics_limit @metrics_limit
  @process_query_limit 10_000

  defp escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp escape_value(other), do: escape_value(to_string(other))

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

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
    cpu_history_by_process = process_metric_history_by_identity(cpu_rows, "cpu_usage")
    memory_by_process = latest_process_metric_by_identity(memory_rows, "memory_usage")

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
        Map.update(acc, process_identity(row), [{dt, value}], fn points -> [{dt, value} | points] end)
      else
        _ -> acc
      end
    end)
    |> Map.new(fn {identity, points} ->
      points =
        points
        |> Enum.sort_by(fn {dt, _value} -> DateTime.to_unix(dt, :millisecond) end)
        |> Enum.take(-60)

      {identity, points}
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
        build_disk_section(srql_module, filter_tokens, scope),
        build_process_count_section(srql_module, filter_tokens, scope)
      ],
      & &1
    )
  end

  def annotate_metric_sections(sections, anomaly_overview, selected_row \\ nil)

  def annotate_metric_sections(sections, anomaly_overview, selected_row) when is_list(sections) do
    annotations_by_section =
      anomaly_overview
      |> anomaly_rows()
      |> Enum.map(&finding_annotation(&1, false))
      |> Enum.reject(&is_nil/1)
      |> maybe_add_selected_annotation(selected_row)
      |> Enum.group_by(& &1.section_key)

    Enum.map(sections, &put_section_annotations(&1, annotations_by_section))
  end

  def annotate_metric_sections(sections, _anomaly_overview, _selected_row), do: sections

  defp build_cpu_section(srql_module, filter_tokens, scope) do
    query =
      timeseries_metric_query(
        "sysmon.cpu",
        "cpu.usage_percent",
        filter_tokens,
        nil,
        @metrics_limit
      )

    base = %{
      key: "cpu",
      title: "CPU",
      subtitle: "last 24h · 5m buckets · avg across cores",
      unit: :percent,
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
    query =
      timeseries_metric_query(
        "sysmon.memory",
        "memory.used_percent",
        filter_tokens,
        nil,
        @metrics_limit
      )

    base = %{
      key: "memory",
      title: "Memory",
      subtitle: "last 24h · 5m buckets · used percent",
      unit: :percent,
      query: query,
      panels: [],
      error: nil,
      header_value: nil,
      header_stats: nil
    }

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) and results != [] ->
        normalized = normalize_metric_results(results, "used_percent")
        viz = timeseries_viz("used_percent", nil)
        panels = build_metric_panels(%{"results" => normalized, "viz" => viz}, normalized, nil)
        header_value = latest_metric_value(normalized, "used_percent")
        header_stats = metric_stats(normalized, "used_percent")
        %{base | panels: panels, header_value: header_value, header_stats: header_stats}

      {:ok, %{"results" => results}} when is_list(results) ->
        base

      {:ok, other} ->
        %{base | error: "unexpected SRQL response: #{inspect(other)}"}

      {:error, reason} ->
        %{base | error: "SRQL error: #{format_error(reason)}"}
    end
  end

  defp build_disk_section(srql_module, filter_tokens, scope) do
    query =
      timeseries_metric_query(
        "sysmon.disk",
        "disk.used_percent",
        filter_tokens,
        nil,
        @disk_metrics_limit
      )

    base = %{
      key: "disk",
      title: "Disk",
      subtitle: "last 24h · 5m buckets · used percent",
      unit: :percent,
      query: query,
      panels: [],
      error: nil,
      header_value: nil,
      header_stats: nil
    }

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) and results != [] ->
        normalized = normalize_metric_results(results, "used_percent")
        viz = timeseries_viz("used_percent", nil)
        panels = build_metric_panels(%{"results" => normalized, "viz" => viz}, normalized, nil)
        header_value = latest_metric_value(normalized, "used_percent")
        header_stats = metric_stats(normalized, "used_percent")
        %{base | panels: panels, header_value: header_value, header_stats: header_stats}

      {:ok, %{"results" => results}} when is_list(results) ->
        base

      {:ok, other} ->
        %{base | error: "unexpected SRQL response: #{inspect(other)}"}

      {:error, reason} ->
        %{base | error: "SRQL error: #{format_error(reason)}"}
    end
  end

  defp build_process_count_section(srql_module, filter_tokens, scope) do
    query =
      timeseries_metric_query(
        "sysmon.process",
        "process.count",
        filter_tokens,
        nil,
        @metrics_limit
      )

    base = %{
      key: "process-count",
      title: "Process Count",
      subtitle: "last 24h · 5m buckets · avg observed processes",
      unit: :count,
      query: query,
      panels: [],
      error: nil,
      header_value: nil,
      header_stats: nil
    }

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) and results != [] ->
        normalized = normalize_metric_results(results, "process_count")
        viz = timeseries_viz("process_count", nil)
        panels = build_metric_panels(%{"results" => normalized, "viz" => viz}, normalized, nil)
        header_value = latest_metric_value(normalized, "process_count")
        header_stats = metric_stats(normalized, "process_count")
        %{base | panels: panels, header_value: header_value, header_stats: header_stats}

      {:ok, %{"results" => results}} when is_list(results) ->
        base

      {:ok, other} ->
        %{base | error: "unexpected SRQL response: #{inspect(other)}"}

      {:error, reason} ->
        %{base | error: "SRQL error: #{format_error(reason)}"}
    end
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

  defp anomaly_rows(%{anomaly_rows: rows}) when is_list(rows), do: Enum.filter(rows, &is_map/1)
  defp anomaly_rows(_), do: []

  defp maybe_add_selected_annotation(annotations, nil), do: annotations

  defp maybe_add_selected_annotation(annotations, selected_row) when is_map(selected_row) do
    case finding_annotation(selected_row, true) do
      nil -> annotations
      annotation -> [annotation | annotations]
    end
  end

  defp maybe_add_selected_annotation(annotations, _selected_row), do: annotations

  defp finding_annotation(row, selected?) when is_map(row) do
    with section_key when is_binary(section_key) <- finding_section_key(row),
         time when is_binary(time) <- finding_time(row) do
      %{
        section_key: section_key,
        dt: time,
        label: finding_annotation_label(row, selected?),
        severity: finding_severity(row),
        series: finding_annotation_series(row, section_key)
      }
    end
  end

  defp finding_annotation(_row, _selected?), do: nil

  defp finding_section_key(row) do
    metric_name =
      row
      |> first_present([
        ["metric_name"],
        ["metadata", "source_identity", "metric_name"],
        ["metadata", "service_radar", "metric_name"],
        ["metadata", "anomaly", "metric_name"],
        ["metadata", "detection_finding", "metric_name"],
        ["raw_data", "metric_name"],
        ["unmapped", "metric_name"]
      ])
      |> normalize_text()

    metric_class =
      row
      |> first_present([
        ["metric_class"],
        ["metadata", "service_radar", "metric_class"],
        ["metadata", "anomaly", "metric_class"],
        ["metadata", "detection_finding", "metric_class"],
        ["raw_data", "metric_class"],
        ["unmapped", "metric_class"]
      ])
      |> normalize_text()

    cond do
      String.contains?(metric_name, "cpu") or metric_class in ["cpu", "cpu_metrics"] ->
        "cpu"

      String.contains?(metric_name, "memory") or metric_class in ["memory", "memory_metrics"] ->
        "memory"

      String.contains?(metric_name, "disk") or metric_class in ["disk", "disk_metrics"] ->
        "disk"

      metric_name == "process.count" or metric_class == "process" ->
        "process-count"

      true ->
        nil
    end
  end

  defp finding_time(row) do
    row
    |> first_present([
      ["time"],
      ["timestamp"],
      ["metadata", "time"],
      ["metadata", "anomaly", "time"],
      ["metadata", "detection_finding", "time"],
      ["raw_data", "time"],
      ["unmapped", "time"]
    ])
    |> case do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> nil
          time -> time
        end

      %DateTime{} = dt ->
        DateTime.to_iso8601(dt)

      %NaiveDateTime{} = ndt ->
        ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

      _ ->
        nil
    end
  end

  defp finding_annotation_label(row, true), do: "Selected: #{finding_title(row)}"
  defp finding_annotation_label(row, false), do: finding_title(row)

  defp finding_title(row) do
    row
    |> first_present([
      ["finding_title"],
      ["finding_info", "title"],
      ["metadata", "finding_info", "title"],
      ["metadata", "detection_finding", "title"],
      ["message"],
      ["raw_data", "finding_info", "title"],
      ["unmapped", "finding_info", "title"]
    ])
    |> case do
      value when is_binary(value) and value != "" -> value
      value when is_atom(value) -> Atom.to_string(value)
      value when is_number(value) -> to_string(value)
      _ -> "Anomaly finding"
    end
  end

  defp finding_severity(row) do
    row
    |> first_present([
      ["severity"],
      ["severity_name"],
      ["metadata", "severity"],
      ["metadata", "detection_finding", "severity"],
      ["raw_data", "severity"],
      ["unmapped", "severity"]
    ])
    |> case do
      value when is_binary(value) and value != "" -> value
      value when is_atom(value) -> Atom.to_string(value)
      _ -> "warning"
    end
  end

  defp finding_annotation_series(row, section_key) when section_key in ["cpu", "disk"] do
    row
    |> first_present([
      ["series_key"],
      ["metadata", "source_identity", "series_key"],
      ["metadata", "service_radar", "series_key"],
      ["raw_data", "series_key"],
      ["unmapped", "series_key"]
    ])
    |> case do
      value when is_binary(value) ->
        value
        |> format_sysmon_series()
        |> case do
          "" -> nil
          series -> series
        end

      _ ->
        nil
    end
  end

  defp finding_annotation_series(_row, _section_key), do: nil

  defp format_sysmon_series(series) when is_binary(series) do
    series
    |> String.split(":", trim: true)
    |> List.last()
    |> case do
      nil -> series
      "" -> series
      value -> value
    end
  end

  defp put_section_annotations(section, annotations_by_section) when is_map(section) do
    annotations = Map.get(annotations_by_section, Map.get(section, :key), [])

    if annotations == [] do
      section
    else
      panels =
        section
        |> Map.get(:panels, [])
        |> Enum.map(&put_panel_annotations(&1, annotations))

      %{section | panels: panels}
    end
  end

  defp put_section_annotations(section, _annotations_by_section), do: section

  defp put_panel_annotations(panel, annotations) when is_map(panel) do
    assigns =
      panel
      |> Map.get(:assigns, %{})
      |> Map.put(:annotations, match_annotations_to_panel(annotations, panel))

    %{panel | assigns: assigns}
  end

  defp put_panel_annotations(panel, _annotations), do: panel

  defp match_annotations_to_panel(annotations, panel) do
    panel_series =
      panel
      |> Map.get(:assigns, %{})
      |> Map.get(:series_points, [])
      |> Enum.map(fn
        {series, _points} -> to_string(series)
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.map(annotations, fn
      %{series: series} = annotation when is_binary(series) ->
        if MapSet.member?(panel_series, series) do
          annotation
        else
          %{annotation | series: nil}
        end

      annotation ->
        annotation
    end)
  end

  defp first_present(row, paths) do
    Enum.find_value(paths, &nested_value(row, &1))
  end

  defp nested_value(value, []), do: value

  defp nested_value(%{} = row, [key | rest]) do
    row
    |> map_value(key)
    |> nested_value(rest)
  end

  defp nested_value(_row, _path), do: nil

  defp normalize_text(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_text(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_text()
  defp normalize_text(value) when is_number(value), do: value |> to_string() |> normalize_text()
  defp normalize_text(_), do: ""

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

  defp timeseries_metric_query(metric_type, metric_name, filter_tokens, series_field, limit, opts \\ []) do
    series_field =
      case series_field do
        nil -> nil
        "" -> nil
        other -> other |> to_string() |> String.trim()
      end

    tokens =
      if Keyword.get(opts, :bucket?, true) do
        [
          "in:timeseries_metrics",
          ~s|metric_type:"#{escape_value(metric_type)}"|,
          ~s|metric_name:"#{escape_value(metric_name)}"|,
          "time:#{Keyword.get(opts, :time_range, "last_24h")}",
          "bucket:5m",
          "agg:avg"
        ]
      else
        [
          "in:timeseries_metrics",
          ~s|metric_type:"#{escape_value(metric_type)}"|,
          ~s|metric_name:"#{escape_value(metric_name)}"|,
          "time:#{Keyword.get(opts, :time_range, "last_24h")}"
        ]
      end

    tokens =
      tokens
      |> maybe_add_token("series", series_field)
      |> Kernel.++(filter_tokens)
      |> Kernel.++(["sort:timestamp:desc", "limit:#{limit}"])

    Enum.join(tokens, " ")
  end

  defp maybe_add_token(tokens, _key, nil), do: tokens
  defp maybe_add_token(tokens, _key, ""), do: tokens

  defp maybe_add_token(tokens, key, value) do
    tokens ++ ["#{key}:#{value}"]
  end

  defp map_value(%{} = row, key) do
    Map.get(row, key) || Map.get(row, to_string(key)) || Map.get(row, existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp map_value(_row, _key), do: nil

  defp existing_atom(key) when is_atom(key), do: key
  defp existing_atom(key) when is_binary(key), do: String.to_existing_atom(key)
end
