defmodule ServiceRadarWebNGWeb.InterfaceLive.MetricsPanels do
  @moduledoc false

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Spec
  alias ServiceRadarWebNGWeb.InterfaceLive.SnmpMetricNames

  @max_interface_series 32

  def from_srql(srql_response, opts \\ []) when is_map(srql_response) do
    results =
      srql_response
      |> Map.get("results", [])
      |> SnmpMetricNames.rewrite_result_rows()

    spec = timeseries_spec(srql_response, results)

    case Spec.extract_series_points(results, spec, max_series: @max_interface_series) do
      {:ok, series_points, series_units, series_metadata} when series_points != [] ->
        series_points = SnmpMetricNames.prefer_hc_series(series_points)

        spec =
          spec
          |> Map.put(:series_units, series_units)
          |> Map.put(:series_metadata, series_metadata)

        [
          %{
            id: Keyword.get(opts, :id, "timeseries"),
            plugin: Timeseries,
            title: Keyword.get(opts, :title, "Timeseries"),
            assigns:
              maybe_put(
                %{
                  spec: spec,
                  series_points: series_points,
                  chart_mode: Keyword.get(opts, :chart_mode, :combined),
                  rate_mode: :rate,
                  max_speed_bytes_per_sec: Keyword.get(opts, :max_speed_bytes_per_sec),
                  reference_lines: Keyword.get(opts, :reference_lines, [])
                },
                :interface_label,
                Keyword.get(opts, :interface_label)
              )
          }
        ]

      _ ->
        []
    end
  end

  defp timeseries_spec(srql_response, results) do
    spec =
      case Spec.parse_timeseries_spec(Map.get(srql_response, "viz")) do
        {:ok, spec} -> spec
        _ -> %{x: "timestamp", y: "value", series: "metric_name"}
      end

    %{spec | series: series_key(results, spec.series), x: x_key(results, spec.x)}
  end

  defp series_key(results, preferred) do
    first = List.first(results) || %{}

    cond do
      present?(first, preferred) -> preferred
      present?(first, "series") -> "series"
      present?(first, "metric_name") -> "metric_name"
      true -> preferred || "metric_name"
    end
  end

  defp x_key(results, preferred) do
    first = List.first(results) || %{}

    cond do
      present?(first, preferred) -> preferred
      present?(first, "timestamp") -> "timestamp"
      present?(first, "time") -> "time"
      # spec.x is always binary here (guard-pinned by parse_timeseries_spec).
      true -> preferred
    end
  end

  defp present?(row, key) when is_map(row) and is_binary(key) do
    value = Map.get(row, key)
    not is_nil(value) and value != ""
  end

  defp present?(_row, _key), do: false

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
