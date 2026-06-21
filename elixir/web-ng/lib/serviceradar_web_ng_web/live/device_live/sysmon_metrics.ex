defmodule ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics do
  @moduledoc false

  alias ServiceRadarWebNGWeb.Dashboard.Engine
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Categories, as: CategoriesPlugin
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Table, as: TablePlugin
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries, as: TimeseriesPlugin
  alias ServiceRadarWebNGWeb.DeviceLive.SysmonProfileData
  alias ServiceRadarWebNGWeb.SRQL.Viz

  require Logger

  @metrics_limit 300
  @disk_metrics_limit @metrics_limit
  @process_query_limit 10_000
  @sysmon_display_series_limit 6

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

  @process_sparkline_limit 60

  # Builds a per-process history series `{dt, value}` for sparkline rendering.
  # Distinct from `latest_process_metric_by_identity/2`, which keeps only the
  # most-recent sample per identity — a latest-only view hides short CPU spikes.
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

  def load_metric_sections(srql_module, filter_tokens, scope, opts \\ [])

  def load_metric_sections(_srql_module, [], _scope, _opts), do: []

  def load_metric_sections(srql_module, filter_tokens, scope, opts) do
    reference_lines = sysmon_reference_lines(filter_tokens, scope, opts)

    Enum.filter(
      [
        build_cpu_section(srql_module, filter_tokens, scope, Map.get(reference_lines, :cpu, [])),
        build_memory_section(srql_module, filter_tokens, scope, Map.get(reference_lines, :memory, [])),
        build_disk_section(srql_module, filter_tokens, scope, Map.get(reference_lines, :disk, []))
      ],
      & &1
    )
  end

  defp build_cpu_section(srql_module, filter_tokens, scope, reference_lines) do
    query =
      timeseries_metric_query(
        "sysmon.cpu",
        "cpu.usage_percent",
        filter_tokens,
        "core_id",
        nil,
        agg: "max"
      )

    base = %{
      key: "cpu",
      title: "CPU",
      subtitle: "last 24h · 5m buckets · max per core",
      query: query,
      panels: [],
      error: nil,
      header_value: nil,
      header_stats: nil
    }

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) and results != [] ->
        normalized = normalize_metric_results(results, "usage_percent")
        display_rows = hottest_series_rows(normalized, "core_id", "usage_percent")
        viz = timeseries_viz("usage_percent", "core_id")

        panels =
          build_metric_panels(%{"results" => display_rows, "viz" => viz}, display_rows, "core_id", reference_lines)

        header_value = latest_metric_value(normalized, "usage_percent", tie: :max)
        header_stats = metric_stats(normalized, "usage_percent")

        %{
          base
          | subtitle: sysmon_display_subtitle(normalized, "core_id", "core", "cores"),
            panels: panels,
            header_value: header_value,
            header_stats: header_stats
        }

      {:ok, %{"results" => results}} when is_list(results) ->
        base

      {:ok, other} ->
        %{base | error: "unexpected SRQL response: #{inspect(other)}"}

      {:error, reason} ->
        %{base | error: "SRQL error: #{format_error(reason)}"}
    end
  end

  defp build_memory_section(srql_module, filter_tokens, scope, reference_lines) do
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
        panels = build_metric_panels(%{"results" => normalized, "viz" => viz}, normalized, nil, reference_lines)
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

  defp build_disk_section(srql_module, filter_tokens, scope, reference_lines) do
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
        panels = build_metric_panels(%{"results" => normalized, "viz" => viz}, normalized, nil, reference_lines)
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

  defp latest_metric_value(rows, field, opts \\ [])

  defp latest_metric_value(rows, field, opts) when is_list(rows) do
    rows
    |> latest_metric_tuple(field, Keyword.get(opts, :tie))
    |> extract_metric_value()
  end

  defp latest_metric_value(_rows, _field, _opts), do: nil

  defp latest_metric_tuple(rows, field, tie) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(nil, &update_latest_metric(&1, field, tie, &2))
  end

  defp extract_metric_value({_dt, value}), do: value
  defp extract_metric_value(_), do: nil

  defp update_latest_metric(row, field, tie, acc) do
    with {:ok, dt} <- parse_datetime(Map.get(row, "timestamp")),
         value when is_number(value) <- parse_number(Map.get(row, field)) do
      pick_latest_metric({dt, value}, acc, tie)
    else
      _ -> acc
    end
  end

  defp pick_latest_metric(current, nil, _tie), do: current

  defp pick_latest_metric({dt, value} = current, {prev_dt, prev_value} = previous, :max) do
    case DateTime.compare(dt, prev_dt) do
      :gt -> current
      :eq when value > prev_value -> current
      _ -> previous
    end
  end

  defp pick_latest_metric({dt, _} = current, {prev_dt, _} = previous, _tie) do
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

  defp hottest_series_rows(rows, series_field, value_field) when is_list(rows) do
    selected_series =
      rows
      |> series_max_values(series_field, value_field)
      |> Enum.sort_by(fn {series, max_value} -> {-max_value, series} end)
      |> Enum.take(@sysmon_display_series_limit)
      |> MapSet.new(fn {series, _max_value} -> series end)

    if MapSet.size(selected_series) == 0 do
      rows
    else
      Enum.filter(rows, fn row ->
        row
        |> series_key(series_field)
        |> then(&MapSet.member?(selected_series, &1))
      end)
    end
  end

  defp hottest_series_rows(rows, _series_field, _value_field), do: rows

  defp series_max_values(rows, series_field, value_field) do
    Enum.reduce(rows, %{}, fn
      row, acc when is_map(row) ->
        with series when is_binary(series) <- series_key(row, series_field),
             value when is_number(value) <- parse_number(map_value(row, value_field)) do
          Map.update(acc, series, value, &max(&1, value))
        else
          _ -> acc
        end

      _row, acc ->
        acc
    end)
  end

  defp series_key(row, series_field) when is_map(row) do
    row
    |> map_value(series_field)
    |> safe_series_key()
  end

  defp series_key(_row, _series_field), do: nil

  defp safe_series_key(value) when is_binary(value) do
    case String.trim(value) do
      "" -> "overall"
      trimmed -> trimmed
    end
  end

  defp safe_series_key(value) when is_atom(value), do: value |> Atom.to_string() |> safe_series_key()
  defp safe_series_key(value) when is_number(value), do: value |> to_string() |> safe_series_key()
  defp safe_series_key(_value), do: nil

  defp sysmon_display_subtitle(rows, series_field, singular, plural) when is_list(rows) do
    count =
      rows
      |> Enum.map(&series_key(&1, series_field))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()
      |> MapSet.size()

    noun = if count == 1, do: singular, else: plural

    if count > @sysmon_display_series_limit do
      "last 24h · 5m buckets · top #{@sysmon_display_series_limit} of #{count} #{plural} by max"
    else
      "last 24h · 5m buckets · all #{count} #{noun} by max"
    end
  end

  defp sysmon_display_subtitle(_rows, _series_field, singular, _plural) do
    "last 24h · 5m buckets · max per #{singular}"
  end

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

  defp build_metric_panels(resp, results, series_field, reference_lines) do
    srql_response = %{"results" => results, "viz" => extract_viz(resp)}

    panels =
      srql_response
      |> Engine.build_panels()
      |> prefer_visual_panels(results)
      |> drop_category_panels_when_timeseries()

    panels
    |> maybe_force_timeseries(results, series_field)
    |> drop_category_panels_when_timeseries()
    |> attach_reference_lines(reference_lines)
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

  defp attach_reference_lines(panels, []), do: panels

  defp attach_reference_lines(panels, reference_lines) when is_list(panels) and is_list(reference_lines) do
    Enum.map(panels, fn
      %{plugin: TimeseriesPlugin, assigns: assigns} = panel when is_map(assigns) ->
        %{panel | assigns: Map.put(assigns, :reference_lines, reference_lines)}

      panel ->
        panel
    end)
  end

  defp attach_reference_lines(panels, _reference_lines), do: panels

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

  defp sysmon_reference_lines(filter_tokens, scope, opts) do
    thresholds =
      opts
      |> Keyword.get(:thresholds)
      |> case do
        thresholds when is_map(thresholds) -> thresholds
        _ -> profile_thresholds_for_filter_tokens(filter_tokens, scope)
      end

    %{
      cpu: threshold_reference_lines(thresholds, "cpu", "CPU"),
      memory: threshold_reference_lines(thresholds, "memory", "Memory"),
      disk: threshold_reference_lines(thresholds, "disk", "Disk")
    }
  end

  defp profile_thresholds_for_filter_tokens(filter_tokens, scope) do
    with uid when is_binary(uid) <- device_uid_from_filter_tokens(filter_tokens),
         {%{profile: profile}, _available_profiles} <- SysmonProfileData.load_profile_info(scope, uid),
         thresholds when is_map(thresholds) <- Map.get(profile || %{}, :thresholds) do
      thresholds
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp device_uid_from_filter_tokens(filter_tokens) when is_list(filter_tokens) do
    Enum.find_value(filter_tokens, fn
      "uid:\"" <> rest ->
        quoted_filter_value(rest)

      "device_id:\"" <> rest ->
        quoted_filter_value(rest)

      _ ->
        nil
    end)
  end

  defp device_uid_from_filter_tokens(_filter_tokens), do: nil

  defp quoted_filter_value(rest) do
    rest
    |> String.trim_trailing("\"")
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp threshold_reference_lines(thresholds, prefix, label_prefix) when is_map(thresholds) do
    Enum.flat_map(
      [
        {:critical, "#{label_prefix} critical"},
        {:warning, "#{label_prefix} warning"}
      ],
      fn {severity, label} ->
        case threshold_value(thresholds, threshold_keys(prefix, severity)) do
          value when is_number(value) ->
            [%{value: value, label: label, severity: severity, series: nil}]

          _ ->
            []
        end
      end
    )
  end

  defp threshold_reference_lines(_thresholds, _prefix, _label_prefix), do: []

  defp threshold_keys(prefix, severity) do
    severity = Atom.to_string(severity)

    [
      "#{prefix}_#{severity}",
      "#{prefix}.#{severity}",
      "#{prefix}_usage_percent_#{severity}",
      "#{prefix}.usage_percent.#{severity}",
      "#{prefix}_used_percent_#{severity}",
      "#{prefix}.used_percent.#{severity}"
    ]
  end

  defp threshold_value(thresholds, keys) do
    thresholds
    |> map_find_value(keys)
    |> parse_number()
  end

  defp map_find_value(map, keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key) || atom_map_value(map, key)
    end)
  end

  defp atom_map_value(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
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
          "agg:#{Keyword.get(opts, :agg, "avg")}"
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
      |> Kernel.++(["sort:timestamp:desc"])
      |> maybe_add_limit(limit)

    Enum.join(tokens, " ")
  end

  defp maybe_add_limit(tokens, nil), do: tokens
  defp maybe_add_limit(tokens, ""), do: tokens
  defp maybe_add_limit(tokens, limit), do: tokens ++ ["limit:#{limit}"]

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
