defmodule ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics do
  @moduledoc false

  alias ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Common
  alias ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Identity
  alias ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Processes
  alias ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics.Sections

  defdelegate load_process_metrics(srql_module, filter_tokens, scope), to: Processes

  def load_metric_sections(srql_module, filter_tokens, scope, opts \\ []) do
    Sections.load_metric_sections(srql_module, filter_tokens, scope, opts)
  end

  defdelegate sysmon_identity(device_row, device_uid), to: Identity

  defdelegate resolve_sysmon_filter_tokens(srql_module, identity, scope), to: Identity

  def annotate_metric_sections(sections, anomaly_overview, selected_row \\ nil)

  def annotate_metric_sections(sections, anomaly_overview, selected_row) when is_list(sections) do
    annotations_by_section =
      anomaly_overview
      |> anomaly_rows()
      |> Enum.map(&finding_annotation(&1, false))
      |> Enum.reject(&is_nil/1)
      |> maybe_add_selected_annotation(selected_row)
      |> Enum.group_by(& &1.section_key)

    overlays_by_section =
      anomaly_overview
      |> anomaly_rows()
      |> Enum.map(&finding_overlay(&1, false))
      |> Enum.reject(&is_nil/1)
      |> maybe_add_selected_overlay(selected_row)
      |> Enum.group_by(& &1.section_key)

    reference_lines_by_section =
      anomaly_overview
      |> capacity_rows()
      |> Enum.flat_map(&capacity_reference_lines/1)
      |> Enum.group_by(& &1.section_key)

    capacity_overlays_by_section =
      anomaly_overview
      |> capacity_rows()
      |> Enum.map(&capacity_overlay/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.group_by(& &1.section_key)

    Enum.map(
      sections,
      &put_section_overlays(&1, %{
        annotations: annotations_by_section,
        overlays:
          Map.merge(overlays_by_section, capacity_overlays_by_section, fn _key, left, right ->
            left ++ right
          end),
        reference_lines: reference_lines_by_section
      })
    )
  end

  def annotate_metric_sections(sections, _anomaly_overview, _selected_row), do: sections

  defp anomaly_rows(%{anomaly_rows: rows}) when is_list(rows), do: Enum.filter(rows, &is_map/1)
  defp anomaly_rows(_), do: []

  defp capacity_rows(%{capacity_rows: rows}) when is_list(rows), do: Enum.filter(rows, &is_map/1)
  defp capacity_rows(_), do: []

  defp maybe_add_selected_annotation(annotations, nil), do: annotations

  defp maybe_add_selected_annotation(annotations, selected_row) when is_map(selected_row) do
    case finding_annotation(selected_row, true) do
      nil -> annotations
      annotation -> [annotation | annotations]
    end
  end

  defp maybe_add_selected_annotation(annotations, _selected_row), do: annotations

  defp maybe_add_selected_overlay(overlays, nil), do: overlays

  defp maybe_add_selected_overlay(overlays, selected_row) when is_map(selected_row) do
    case finding_overlay(selected_row, true) do
      nil -> overlays
      overlay -> [overlay | overlays]
    end
  end

  defp maybe_add_selected_overlay(overlays, _selected_row), do: overlays

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

  defp finding_overlay(row, selected?) when is_map(row) do
    with section_key when is_binary(section_key) <- finding_section_key(row),
         time when is_binary(time) <- finding_time(row) do
      %{
        kind: :anomaly,
        section_key: section_key,
        dt: time,
        window_started_at: finding_window_started_at(row),
        window_ended_at: finding_window_ended_at(row),
        value: finding_peak_or_metric_value(row),
        threshold_value: number_value(finding_threshold_value(row)),
        score: number_value(finding_score(row)),
        label: finding_annotation_label(row, selected?),
        severity: finding_effective_severity(row),
        disposition: finding_disposition(row),
        reason: finding_reason(row),
        selected: selected?,
        series: finding_overlay_series(row, section_key)
      }
    end
  end

  defp finding_overlay(_row, _selected?), do: nil

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

  defp finding_effective_severity(row) do
    row
    |> first_present([
      ["effective_severity"],
      ["severity"],
      ["severity_name"],
      ["metadata", "service_radar", "effective_severity"],
      ["metadata", "anomaly", "effective_severity"],
      ["metadata", "detection_finding", "effective_severity"],
      ["metadata", "severity"],
      ["metadata", "detection_finding", "severity"],
      ["raw_data", "effective_severity"],
      ["raw_data", "severity"],
      ["unmapped", "effective_severity"],
      ["unmapped", "severity"]
    ])
    |> case do
      value when is_binary(value) and value != "" -> value
      value when is_atom(value) -> Atom.to_string(value)
      _ -> "warning"
    end
  end

  defp finding_disposition(row) do
    row
    |> first_present([
      ["disposition"],
      ["metadata", "service_radar", "disposition"],
      ["metadata", "anomaly", "disposition"],
      ["metadata", "detection_finding", "disposition"],
      ["raw_data", "disposition"],
      ["unmapped", "disposition"]
    ])
    |> safe_string()
  end

  defp finding_reason(row) do
    row
    |> first_present([
      ["reason"],
      ["metadata", "service_radar", "reason"],
      ["metadata", "anomaly", "reason"],
      ["metadata", "detection_finding", "reason"],
      ["raw_data", "reason"],
      ["unmapped", "reason"]
    ])
    |> safe_string()
  end

  defp finding_window_started_at(row) do
    first_present(row, [
      ["window_started_at"],
      ["window_start"],
      ["metadata", "service_radar", "window_started_at"],
      ["metadata", "anomaly", "window_started_at"],
      ["metadata", "anomaly", "window_start"],
      ["metadata", "detection_finding", "window_started_at"],
      ["raw_data", "window_started_at"],
      ["unmapped", "window_started_at"]
    ])
  end

  defp finding_window_ended_at(row) do
    first_present(row, [
      ["window_ended_at"],
      ["window_end"],
      ["metadata", "service_radar", "window_ended_at"],
      ["metadata", "anomaly", "window_ended_at"],
      ["metadata", "anomaly", "window_end"],
      ["metadata", "detection_finding", "window_ended_at"],
      ["raw_data", "window_ended_at"],
      ["unmapped", "window_ended_at"]
    ])
  end

  defp finding_peak_or_metric_value(row) do
    row
    |> first_present([
      ["peak_value"],
      ["metric_value"],
      ["metadata", "service_radar", "peak_value"],
      ["metadata", "service_radar", "metric_value"],
      ["metadata", "anomaly", "peak_value"],
      ["metadata", "anomaly", "peak"],
      ["metadata", "anomaly", "value"],
      ["metadata", "anomaly", "metric_value"],
      ["raw_data", "peak_value"],
      ["raw_data", "metric_value"],
      ["unmapped", "peak_value"],
      ["unmapped", "metric_value"]
    ])
    |> number_value()
  end

  defp finding_threshold_value(row) do
    first_present(row, [
      ["threshold_value"],
      ["metadata", "service_radar", "threshold_value"],
      ["metadata", "anomaly", "threshold_value"],
      ["raw_data", "threshold_value"],
      ["unmapped", "threshold_value"]
    ])
  end

  defp finding_score(row) do
    first_present(row, [
      ["score"],
      ["metadata", "service_radar", "score"],
      ["metadata", "anomaly", "score"],
      ["metadata", "anomaly", "z_score"],
      ["raw_data", "score"],
      ["unmapped", "score"]
    ])
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

  defp finding_overlay_series(row, section_key) when section_key in ["cpu", "disk"] do
    finding_annotation_series(row, section_key)
  end

  defp finding_overlay_series(_row, _section_key), do: nil

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

  defp capacity_reference_lines(row) when is_map(row) do
    with "disk" <- capacity_section_key(row),
         value when is_number(value) <- row |> Common.map_value("exhaustion_threshold") |> number_value(),
         true <- capacity_percent_unit?(Common.map_value(row, "value_unit")) do
      [
        %{
          section_key: "disk",
          value: value,
          label: capacity_label(row, "Capacity threshold"),
          severity: capacity_severity(row),
          series: capacity_series(row)
        }
      ]
    else
      _ -> []
    end
  end

  defp capacity_reference_lines(_row), do: []

  defp capacity_overlay(row) when is_map(row) do
    with "disk" <- capacity_section_key(row),
         true <- capacity_percent_unit?(Common.map_value(row, "value_unit")) do
      %{
        kind: :capacity,
        section_key: "disk",
        dt: Common.map_value(row, "projected_exhaustion_at"),
        forecasted_at: Common.map_value(row, "forecasted_at"),
        label: capacity_label(row, "Capacity forecast"),
        severity: capacity_severity(row),
        series: capacity_series(row),
        current_value: row |> Common.map_value("current_value") |> number_value(),
        projected_value: row |> Common.map_value("projected_value") |> number_value(),
        threshold_value: row |> Common.map_value("exhaustion_threshold") |> number_value(),
        lower_bound: row |> Common.map_value("lower_bound") |> number_value(),
        upper_bound: row |> Common.map_value("upper_bound") |> number_value(),
        confidence: row |> Common.map_value("confidence") |> number_value(),
        status: row |> Common.map_value("status") |> safe_string()
      }
    else
      _ -> nil
    end
  end

  defp capacity_overlay(_row), do: nil

  defp capacity_section_key(row) do
    metric_name = row |> Common.map_value("metric_name") |> normalize_text()
    metric_class = row |> Common.map_value("metric_class") |> normalize_text()
    resource_type = row |> Common.map_value("resource_type") |> normalize_text()

    if String.contains?(metric_name, "disk") or metric_class == "disk" or resource_type == "disk" do
      "disk"
    end
  end

  defp capacity_percent_unit?(unit) do
    unit
    |> normalize_text()
    |> case do
      "" -> true
      "%" -> true
      "percent" -> true
      "percentage" -> true
      _ -> false
    end
  end

  defp capacity_label(row, fallback) do
    label =
      row
      |> Common.map_value("resource_label")
      |> safe_string()

    if label == "", do: fallback, else: "#{fallback}: #{label}"
  end

  defp capacity_severity(row) do
    case row |> Common.map_value("status") |> normalize_text() do
      "exhaustion_projected" -> "critical"
      "at_risk" -> "warning"
      _ -> "info"
    end
  end

  defp capacity_series(_row), do: nil

  defp put_section_overlays(section, groups) when is_map(section) do
    annotations = groups |> Map.get(:annotations, %{}) |> Map.get(Map.get(section, :key), [])
    overlays = groups |> Map.get(:overlays, %{}) |> Map.get(Map.get(section, :key), [])
    reference_lines = groups |> Map.get(:reference_lines, %{}) |> Map.get(Map.get(section, :key), [])

    if annotations == [] and overlays == [] and reference_lines == [] do
      section
    else
      panels =
        section
        |> Map.get(:panels, [])
        |> Enum.map(&put_panel_overlays(&1, annotations, overlays, reference_lines, Map.get(section, :key)))

      %{section | panels: panels}
    end
  end

  defp put_section_overlays(section, _groups), do: section

  defp put_panel_overlays(panel, annotations, overlays, reference_lines, section_key) when is_map(panel) do
    assigns =
      panel
      |> Map.get(:assigns, %{})
      |> Map.put(:annotations, match_annotations_to_panel(annotations, panel))
      |> Map.put(:chart_overlays, match_overlays_to_panel(overlays, panel, section_key))
      |> append_reference_lines(reference_lines)

    %{panel | assigns: assigns}
  end

  defp put_panel_overlays(panel, _annotations, _overlays, _reference_lines, _section_key), do: panel

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

  defp match_overlays_to_panel(overlays, panel, section_key) do
    panel_series = panel_series(panel)
    overall_panel? = section_key == "cpu" and MapSet.member?(panel_series, "Overall utilization")

    overlays
    |> Enum.flat_map(fn
      %{series: series} = overlay when is_binary(series) ->
        cond do
          MapSet.member?(panel_series, series) ->
            [overlay]

          overall_panel? ->
            [%{overlay | series: nil}]

          true ->
            []
        end

      overlay ->
        [overlay]
    end)
    |> Enum.take(12)
  end

  defp append_reference_lines(assigns, []), do: assigns

  defp append_reference_lines(assigns, reference_lines) do
    existing = Map.get(assigns, :reference_lines, [])

    lines =
      Enum.uniq_by(existing ++ reference_lines, fn line ->
        {Map.get(line, :value), Map.get(line, :label), Map.get(line, :series)}
      end)

    Map.put(assigns, :reference_lines, lines)
  end

  defp panel_series(panel) do
    panel
    |> Map.get(:assigns, %{})
    |> Map.get(:series_points, [])
    |> Enum.map(fn
      {series, _points} -> to_string(series)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp first_present(row, paths) do
    Enum.find_value(paths, &nested_value(row, &1))
  end

  defp nested_value(value, []), do: value

  defp nested_value(%{} = row, [key | rest]) do
    row
    |> Common.map_value(key)
    |> nested_value(rest)
  end

  defp nested_value(_row, _path), do: nil

  defp normalize_text(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_text(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_text()
  defp normalize_text(value) when is_number(value), do: value |> to_string() |> normalize_text()
  defp normalize_text(_), do: ""

  defp number_value(value) when is_integer(value), do: value * 1.0
  defp number_value(value) when is_float(value), do: value

  defp number_value(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp number_value(_), do: nil

  defp safe_string(nil), do: ""
  defp safe_string(value) when is_binary(value), do: String.trim(value)
  defp safe_string(value) when is_atom(value), do: value |> Atom.to_string() |> String.trim()
  defp safe_string(value) when is_number(value), do: value |> to_string() |> String.trim()
  defp safe_string(value), do: value |> inspect() |> String.trim()
end
