defmodule ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Series do
  @moduledoc false

  import ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Common

  alias ServiceRadarWebNGWeb.Dashboard.Engine
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Categories, as: CategoriesPlugin
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Table, as: TablePlugin
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries, as: TimeseriesPlugin
  alias ServiceRadarWebNGWeb.SRQL.Viz

  @sysmon_display_series_limit 6
  @sysmon_window_label "last 24h · 5m buckets"

  def latest_metric_value(rows, field, opts \\ [])

  def latest_metric_value(rows, field, opts) when is_list(rows) do
    rows
    |> latest_metric_tuple(field, Keyword.get(opts, :tie))
    |> extract_metric_value()
  end

  def latest_metric_value(_rows, _field, _opts), do: nil

  def metric_stats(rows, field) when is_list(rows) do
    {min, max, sum, count} =
      rows
      |> Enum.filter(&is_map/1)
      |> Enum.reduce({nil, nil, 0.0, 0}, &accumulate_metric_stat(&1, field, &2))

    if count > 0 do
      %{min: min, max: max, avg: sum / count}
    end
  end

  def metric_stats(_rows, _field), do: nil

  def normalize_metric_results(results, target_field) when is_list(results) do
    Enum.map(results, fn
      row when is_map(row) ->
        value = Map.get(row, "value")

        row =
          if is_nil(value) do
            row
          else
            Map.put(row, target_field, value)
          end

        if is_binary(target_field) and is_nil(map_value(row, target_field)) do
          case Map.get(row, "series") || Map.get(row, :series) do
            nil -> row
            series -> Map.put(row, target_field, series)
          end
        else
          row
        end

      other ->
        other
    end)
  end

  def normalize_metric_results(results, _target_field), do: results

  def hottest_series_rows(rows, series_field, value_field) when is_list(rows) do
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

  def hottest_series_rows(rows, _series_field, _value_field), do: rows

  def sysmon_display_subtitle(rows, series_field, singular, plural, opts \\ [])

  def sysmon_display_subtitle(rows, series_field, singular, plural, opts) when is_list(rows) do
    window_label = Keyword.get(opts, :window_label, @sysmon_window_label)

    "#{window_label} · #{Keyword.get(opts, :prefix, "")}#{sysmon_display_subtitle_detail(rows, series_field, singular, plural)}"
  end

  def sysmon_display_subtitle(_rows, _series_field, singular, _plural, opts) do
    window_label = Keyword.get(opts, :window_label, @sysmon_window_label)
    "#{window_label} · #{Keyword.get(opts, :prefix, "")}max per #{singular}"
  end

  defp sysmon_display_subtitle_detail(rows, series_field, singular, plural) when is_list(rows) do
    count =
      rows
      |> Enum.map(&series_key(&1, series_field))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()
      |> MapSet.size()

    noun = if count == 1, do: singular, else: plural

    if count > @sysmon_display_series_limit do
      "top #{@sysmon_display_series_limit} of #{count} #{plural} by max"
    else
      "all #{count} #{noun} by max"
    end
  end

  defp sysmon_display_subtitle_detail(_rows, _series_field, singular, _plural), do: "max per #{singular}"

  def timeseries_viz(y_field, series_field) do
    suggestion =
      maybe_put_series(
        %{"kind" => "timeseries", "x" => "timestamp", "y" => y_field},
        series_field
      )

    %{"suggestions" => [suggestion]}
  end

  def build_metric_panels(resp, results, series_field, reference_lines) do
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

  def title_timeseries_panels(panels, title) when is_list(panels) do
    Enum.map(panels, fn
      %{plugin: TimeseriesPlugin, assigns: assigns} = panel when is_map(assigns) ->
        %{panel | assigns: Map.put(assigns, :compact_title, title)}

      panel ->
        panel
    end)
  end

  def title_timeseries_panels(panels, _title), do: panels

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

  defp maybe_put_series(viz, nil), do: viz
  defp maybe_put_series(viz, ""), do: viz
  defp maybe_put_series(viz, series_field), do: Map.put(viz, "series", series_field)

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

    if has_timeseries, do: Enum.reject(panels, &(&1.plugin == CategoriesPlugin)), else: panels
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

        if is_binary(series_field) and String.trim(series_field) != "",
          do: Map.put(base, "series", series_field),
          else: base

      _ ->
        nil
    end
  end
end
