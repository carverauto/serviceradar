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
    reference_lines = ReferenceLines.sysmon_reference_lines(filter_tokens, scope, opts)

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
      Query.timeseries_metric_query(
        "sysmon.cpu",
        "cpu.usage_percent",
        filter_tokens,
        "core_id",
        @cpu_metrics_limit,
        agg: "max"
      )

    base = section_base("cpu", "CPU", "last 24h · 5m buckets · max per core", query)

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) and results != [] ->
        normalized = Series.normalize_metric_results(results, "usage_percent")
        display_rows = Series.hottest_series_rows(normalized, "core_id", "usage_percent")
        viz = Series.timeseries_viz("usage_percent", "core_id")

        panels =
          Series.build_metric_panels(%{"results" => display_rows, "viz" => viz}, display_rows, "core_id", reference_lines)
          |> Series.combine_timeseries_panels("CPU cores")

        %{
          base
          | subtitle: Series.sysmon_display_subtitle(normalized, "core_id", "core", "cores"),
            panels: panels,
            header_value: Series.latest_metric_value(normalized, "usage_percent", tie: :max),
            header_stats: Series.metric_stats(normalized, "usage_percent")
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
      Query.timeseries_metric_query(
        "sysmon.memory",
        "memory.used_percent",
        filter_tokens,
        nil,
        @metrics_limit
      )

    build_single_series_section(srql_module, scope, query, "memory", "Memory", "used_percent", reference_lines)
  end

  defp build_disk_section(srql_module, filter_tokens, scope, reference_lines) do
    query =
      Query.timeseries_metric_query(
        "sysmon.disk",
        "disk.used_percent",
        filter_tokens,
        nil,
        @disk_metrics_limit
      )

    build_single_series_section(srql_module, scope, query, "disk", "Disk", "used_percent", reference_lines)
  end

  defp build_single_series_section(srql_module, scope, query, key, title, value_field, reference_lines) do
    base = section_base(key, title, "last 24h · 5m buckets · used percent", query)

    case srql_module.query(query, %{scope: scope}) do
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
end
