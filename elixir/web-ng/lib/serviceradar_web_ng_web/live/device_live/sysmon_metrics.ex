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

    Enum.map(sections, &put_section_annotations(&1, annotations_by_section))
  end

  def annotate_metric_sections(sections, _anomaly_overview, _selected_row), do: sections

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
         true <- finding_annotation_visible?(row, section_key, selected?),
         %DateTime{} = time <- finding_marker_time(row) do
      %{
        section_key: section_key,
        dt: time,
        start_dt: finding_episode_start_time(row),
        end_dt: finding_episode_end_time(row),
        label: finding_annotation_label(row, selected?),
        severity: finding_severity(row),
        series: finding_annotation_series(row, section_key)
      }
    else
      _ -> nil
    end
  end

  defp finding_annotation(_row, _selected?), do: nil

  defp finding_annotation_visible?(_row, _section_key, true), do: true
  defp finding_annotation_visible?(row, "cpu", false), do: cpu_annotation_visible?(row)
  defp finding_annotation_visible?(_row, _section_key, _selected?), do: true

  defp cpu_annotation_visible?(row) do
    row
    |> first_present([
      ["anomaly_disposition", "action"],
      ["metadata", "service_radar", "anomaly_disposition", "action"],
      ["metadata", "serviceradar", "anomaly_disposition", "action"],
      ["metadata", "diagnostics", "source", "source_anomaly_disposition", "action"],
      ["metadata", "serviceradar", "diagnostics", "source", "source_anomaly_disposition", "action"],
      ["raw_data", "anomaly_disposition", "action"],
      ["unmapped", "anomaly_disposition", "action"]
    ])
    |> normalize_text()
    |> Kernel.==("escalate")
  end

  defp finding_marker_time(row) do
    episode_peak_time(row) || finding_time(row)
  end

  defp finding_episode_start_time(row) do
    row
    |> first_present([
      ["episode_started_at_unix_nano"],
      ["finding_info", "dimensions", "episode_started_at_unix_nano"],
      ["metadata", "finding_info", "dimensions", "episode_started_at_unix_nano"],
      ["metadata", "detection_finding", "episode_started_at_unix_nano"],
      ["metadata", "anomaly", "episode_started_at_unix_nano"],
      ["raw_data", "anomaly", "episode_started_at_unix_nano"],
      ["unmapped", "anomaly", "episode_started_at_unix_nano"],
      ["anomaly", "episode_started_at_unix_nano"]
    ])
    |> unix_nano_datetime()
  end

  defp finding_episode_end_time(row) do
    row
    |> first_present([
      ["episode_ended_at_unix_nano"],
      ["finding_info", "dimensions", "episode_ended_at_unix_nano"],
      ["metadata", "finding_info", "dimensions", "episode_ended_at_unix_nano"],
      ["metadata", "detection_finding", "episode_ended_at_unix_nano"],
      ["metadata", "anomaly", "episode_ended_at_unix_nano"],
      ["raw_data", "anomaly", "episode_ended_at_unix_nano"],
      ["unmapped", "anomaly", "episode_ended_at_unix_nano"],
      ["anomaly", "episode_ended_at_unix_nano"]
    ])
    |> unix_nano_datetime()
  end

  defp episode_peak_time(row) do
    row
    |> first_present([
      ["episode_peak_at_unix_nano"],
      ["finding_info", "dimensions", "episode_peak_at_unix_nano"],
      ["metadata", "finding_info", "dimensions", "episode_peak_at_unix_nano"],
      ["metadata", "detection_finding", "episode_peak_at_unix_nano"],
      ["metadata", "anomaly", "episode_peak_at_unix_nano"],
      ["raw_data", "anomaly", "episode_peak_at_unix_nano"],
      ["unmapped", "anomaly", "episode_peak_at_unix_nano"],
      ["anomaly", "episode_peak_at_unix_nano"]
    ])
    |> unix_nano_datetime()
  end

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
          time -> parse_datetime(time)
        end

      %DateTime{} = dt ->
        dt

      %NaiveDateTime{} = ndt ->
        DateTime.from_naive!(ndt, "Etc/UTC")

      _ ->
        nil
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    with {:error, _} <- DateTime.from_iso8601(value),
         {:ok, ndt} <- NaiveDateTime.from_iso8601(value) do
      DateTime.from_naive!(ndt, "Etc/UTC")
    else
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  defp unix_nano_datetime(value) when is_integer(value) and value >= 0 do
    value
    |> System.convert_time_unit(:nanosecond, :microsecond)
    |> DateTime.from_unix!(:microsecond)
  rescue
    _ -> nil
  end

  defp unix_nano_datetime(value) when is_float(value) and value >= 0 do
    value
    |> trunc()
    |> unix_nano_datetime()
  end

  defp unix_nano_datetime(value) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {integer, ""} -> unix_nano_datetime(integer)
      _ -> nil
    end
  end

  defp unix_nano_datetime(_value), do: nil

  defp finding_annotation_label(row, selected?) do
    title = finding_title(row)

    cond do
      selected? and not is_nil(episode_peak_time(row)) -> "Selected peak: #{title}"
      selected? -> "Selected finding: #{title}"
      not is_nil(episode_peak_time(row)) -> "Peak: #{title}"
      true -> title
    end
  end

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
    |> Common.map_value(key)
    |> nested_value(rest)
  end

  defp nested_value(_row, _path), do: nil

  defp normalize_text(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_text(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_text()
  defp normalize_text(value) when is_number(value), do: value |> to_string() |> normalize_text()
  defp normalize_text(_), do: ""
end
