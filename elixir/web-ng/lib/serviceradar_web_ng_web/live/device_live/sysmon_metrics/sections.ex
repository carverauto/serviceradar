defmodule ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Sections do
  @moduledoc false

  import ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Common, only: [format_error: 1]

  alias ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Query
  alias ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.ReferenceLines
  alias ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Series

  @metrics_limit 300
  # 24h at 5m buckets is 288 points per core; keep CPU above the SRQL default cap.
  @cpu_metrics_limit 20_000
  @disk_metrics_limit @metrics_limit

  def load_metric_sections(_srql_module, [], _scope, _opts), do: []

  def load_metric_sections(srql_module, filter_tokens, scope, opts) do
    time_window = Query.requested_window(Keyword.get(opts, :time_range, "last_24h"))
    reference_lines = ReferenceLines.sysmon_reference_lines(filter_tokens, scope, opts)

    limit =
      2 * Keyword.get(opts, :metrics_limit, @metrics_limit) + Keyword.get(opts, :disk_metrics_limit, @disk_metrics_limit)

    query = Query.summary_query(filter_tokens, limit, metric_query_opts(opts))
    summary = Query.run(srql_module, query, scope, opts)

    Enum.map(
      [
        build_cpu_section(srql_module, filter_tokens, scope, Map.get(reference_lines, :cpu, []), opts, summary),
        build_memory_section(filter_tokens, Map.get(reference_lines, :memory, []), opts, summary),
        build_disk_section(filter_tokens, Map.get(reference_lines, :disk, []), opts, summary)
      ],
      fn section ->
        panels = Enum.map(section.panels, &%{&1 | assigns: Map.put(&1.assigns, :time_window, time_window)})
        %{section | panels: panels}
      end
    )
  end

  defp metric_result({:ok, %{"results" => rows}}, name) when is_list(rows) do
    {:ok, %{"results" => Enum.filter(rows, &(Map.get(&1, "series") == name or Map.get(&1, "metric_name") == name))}}
  end

  defp metric_result(other, _name), do: other

  defp build_cpu_section(srql_module, filter_tokens, scope, reference_lines, opts, summary) do
    query_opts = metric_query_opts(opts)

    overall_query =
      Query.timeseries_metric_query(
        "sysmon.cpu",
        "cpu.usage_percent",
        filter_tokens,
        nil,
        Keyword.get(opts, :metrics_limit, @metrics_limit),
        query_opts
      )

    per_core_query =
      Query.timeseries_metric_query(
        "sysmon.cpu",
        "cpu.usage_percent",
        filter_tokens,
        "core_id",
        Keyword.get(opts, :cpu_metrics_limit, @cpu_metrics_limit),
        Keyword.put(query_opts, :agg, "max")
      )

    base = section_base("cpu", "CPU", "#{window_label(opts)} · overall utilization", overall_query)

    overall = metric_result(summary, "cpu.usage_percent")

    cores =
      case summary do
        {:ok, %{"results" => rows}} when is_list(rows) -> Query.run(srql_module, per_core_query, scope, opts)
        _ -> {:ok, %{"results" => []}}
      end

    case {overall, cores} do
      {{:ok, %{"results" => overall_results}}, {:ok, %{"results" => core_results}}}
      when is_list(overall_results) and is_list(core_results) and (overall_results != [] or core_results != []) ->
        overall_rows =
          overall_results
          |> Series.normalize_metric_results("usage_percent")
          |> overall_cpu_rows()

        core_rows = Series.normalize_metric_results(core_results, "usage_percent")
        display_rows = Series.hottest_series_rows(core_rows, "core_id", "usage_percent")

        overall_viz = Series.timeseries_viz("usage_percent", "series")
        core_viz = Series.timeseries_viz("usage_percent", "core_id")

        panels =
          Series.build_metric_panels(
            %{"results" => overall_rows, "viz" => overall_viz},
            overall_rows,
            "series",
            reference_lines
          ) ++
            (%{"results" => display_rows, "viz" => core_viz}
             |> Series.build_metric_panels(display_rows, "core_id", reference_lines)
             |> Series.title_timeseries_panels("Top cores"))

        %{
          base
          | subtitle: cpu_display_subtitle(core_rows, opts),
            panels: panels,
            header_value: Series.latest_metric_value(overall_rows, "usage_percent"),
            header_stats: Series.metric_stats(overall_rows, "usage_percent")
        }

      {{:ok, %{"results" => overall_results}}, {:ok, %{"results" => core_results}}}
      when is_list(overall_results) and is_list(core_results) ->
        base

      {{:error, reason}, _} ->
        %{base | error: "CPU overall SRQL error: #{format_error(reason)}"}

      {_, {:error, reason}} ->
        %{base | error: "CPU core SRQL error: #{format_error(reason)}"}

      {{:ok, other}, _} ->
        %{base | error: "unexpected CPU overall SRQL response: #{inspect(other)}"}

      {_, {:ok, other}} ->
        %{base | error: "unexpected CPU core SRQL response: #{inspect(other)}"}
    end
  end

  defp build_memory_section(filter_tokens, reference_lines, opts, summary) do
    query =
      Query.timeseries_metric_query(
        "sysmon.memory",
        "memory.used_percent",
        filter_tokens,
        nil,
        Keyword.get(opts, :metrics_limit, @metrics_limit),
        metric_query_opts(opts)
      )

    build_single_series_section(
      metric_result(summary, "memory.used_percent"),
      query,
      "memory",
      "Memory",
      "used_percent",
      reference_lines,
      opts
    )
  end

  defp build_disk_section(filter_tokens, reference_lines, opts, summary) do
    query =
      Query.timeseries_metric_query(
        "sysmon.disk",
        "disk.used_percent",
        filter_tokens,
        nil,
        Keyword.get(opts, :disk_metrics_limit, @disk_metrics_limit),
        metric_query_opts(opts)
      )

    build_single_series_section(
      metric_result(summary, "disk.used_percent"),
      query,
      "disk",
      "Disk",
      "used_percent",
      reference_lines,
      opts
    )
  end

  defp build_single_series_section(result, query, key, title, value_field, reference_lines, opts) do
    base = section_base(key, title, "#{window_label(opts)} · used percent", query)

    case result do
      {:ok, %{"results" => results}} when is_list(results) and results != [] ->
        normalized = Series.normalize_metric_results(results, value_field)
        viz = Series.timeseries_viz(value_field, nil)
        panels = Series.build_metric_panels(%{"results" => normalized, "viz" => viz}, normalized, nil, reference_lines)

        %{
          base
          | panels: panels,
            header_value: Series.latest_metric_value(normalized, value_field),
            header_stats: Series.metric_stats(normalized, value_field)
        }

      {:ok, %{"results" => results}} when is_list(results) ->
        base

      {:ok, other} ->
        %{base | error: "unexpected SRQL response: #{inspect(other)}"}

      {:error, reason} ->
        %{base | error: "SRQL error: #{format_error(reason)}"}
    end
  end

  defp section_base(key, title, subtitle, query) do
    %{
      key: key,
      title: title,
      subtitle: subtitle,
      query: query,
      panels: [],
      error: nil,
      header_value: nil,
      header_stats: nil
    }
  end

  defp overall_cpu_rows(rows) when is_list(rows) do
    Enum.map(rows, fn
      row when is_map(row) -> Map.put(row, "series", "Overall utilization")
      row -> row
    end)
  end

  defp cpu_display_subtitle(rows, opts) when is_list(rows) do
    Series.sysmon_display_subtitle(rows, "core_id", "core", "cores",
      prefix: "overall + ",
      window_label: window_label(opts)
    )
  end

  defp metric_query_opts(opts) do
    time_range = Keyword.get(opts, :time_range, "last_24h")

    [
      time_range: time_range,
      bucket: resolve_bucket(opts, time_range)
    ]
  end

  # An explicit :bucket wins (the anomaly-detail zoom pins it); otherwise size
  # the bucket from the selected range so short windows render fine points.
  defp resolve_bucket(opts, time_range) do
    Keyword.get(opts, :bucket) || Query.bucket_for_time_range(time_range)
  end

  defp window_label(opts) do
    Keyword.get(opts, :window_label, default_window_label(opts))
  end

  defp default_window_label(opts) do
    time_range = Keyword.get(opts, :time_range, "last_24h")

    label =
      time_range
      |> to_string()
      |> String.replace("_", " ")

    "#{label} · #{resolve_bucket(opts, time_range)} buckets"
  end
end
