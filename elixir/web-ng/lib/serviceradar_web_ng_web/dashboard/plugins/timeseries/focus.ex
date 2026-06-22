defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Focus do
  @moduledoc false

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Metrics

  @default_window_ms 15 * 60 * 1000

  def normalize(%{} = focus) do
    case normalize_annotation(focus) do
      %{dt: %DateTime{}} = annotation ->
        annotation
        |> Map.put(:series_candidates, series_candidates(focus, annotation.series))
        |> Map.put(:before_ms, window_ms(focus, :before))
        |> Map.put(:after_ms, window_ms(focus, :after))

      _ ->
        nil
    end
  end

  def normalize(_focus), do: nil

  def apply(series_points, nil), do: {series_points, nil}

  def apply(series_points, %{dt: %DateTime{} = dt} = focus) when is_list(series_points) do
    matched_series = focused_series(series_points, focus)

    series_scoped =
      case matched_series do
        nil -> series_points
        series -> Enum.filter(series_points, fn {raw_series, _points} -> raw_series == series end)
      end

    time_scoped =
      Enum.map(series_scoped, fn {series, points} ->
        {series, Enum.filter(points, &focused_point?(&1, dt, focus.before_ms, focus.after_ms))}
      end)

    filtered =
      if Enum.any?(time_scoped, fn {_series, points} -> points != [] end) do
        time_scoped
      else
        series_scoped
      end

    {filtered, %{focus | series: matched_series || focus.series}}
  end

  def apply(series_points, _focus), do: {series_points, nil}

  defp normalize_annotation(%{} = annotation) do
    dt_value =
      first_present([
        Map.get(annotation, :dt),
        Map.get(annotation, "dt"),
        Map.get(annotation, :time),
        Map.get(annotation, "time"),
        Map.get(annotation, :timestamp),
        Map.get(annotation, "timestamp")
      ])

    case parse_datetime(dt_value) do
      {:ok, dt} ->
        %{
          dt: dt,
          label: annotation_label(annotation),
          severity: annotation_severity(annotation),
          series: annotation_series(annotation)
        }

      _ ->
        nil
    end
  end

  defp annotation_label(annotation) do
    annotation
    |> annotation_value([:label, "label", :title, "title"])
    |> safe_to_string()
    |> String.trim()
    |> case do
      "" -> "Finding"
      value -> value
    end
  end

  defp annotation_severity(annotation) do
    annotation
    |> annotation_value([:severity, "severity", :severity_text, "severity_text"])
    |> safe_to_string()
    |> String.trim()
    |> String.downcase()
    |> case do
      "critical" -> :critical
      "error" -> :critical
      "high" -> :high
      "warning" -> :warning
      "warn" -> :warning
      "medium" -> :warning
      "low" -> :info
      "info" -> :info
      "informational" -> :info
      _ -> :info
    end
  end

  defp annotation_series(annotation) do
    annotation
    |> annotation_value([:series, "series", :series_key, "series_key"])
    |> case do
      nil -> nil
      value -> value |> safe_to_string() |> String.trim() |> blank_to_nil()
    end
  end

  defp series_candidates(focus, annotation_series) do
    [
      annotation_series,
      annotation_value(focus, [:series, "series"]),
      annotation_value(focus, [:series_key, "series_key"]),
      annotation_value(focus, [:metric_name, "metric_name"]),
      annotation_value(focus, [:metric, "metric"]),
      annotation_value(focus, [:resource_key, "resource_key"])
    ]
    |> Enum.map(&safe_to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp window_ms(focus, side) do
    ms_keys =
      case side do
        :before -> [:before_ms, "before_ms"]
        :after -> [:after_ms, "after_ms"]
      end

    second_keys =
      case side do
        :before -> [:before_seconds, "before_seconds"]
        :after -> [:after_seconds, "after_seconds"]
      end

    cond do
      ms = parse_nonnegative_integer(annotation_value(focus, ms_keys)) ->
        ms

      seconds = parse_nonnegative_integer(annotation_value(focus, second_keys)) ->
        seconds * 1000

      seconds = parse_nonnegative_integer(annotation_value(focus, [:window_seconds, "window_seconds"])) ->
        seconds * 1000

      minutes = parse_nonnegative_integer(annotation_value(focus, [:window_minutes, "window_minutes"])) ->
        minutes * 60 * 1000

      true ->
        @default_window_ms
    end
  end

  defp focused_series(series_points, focus) do
    Enum.find_value(series_points, fn
      {series, _points} ->
        if focus_matches_series?(focus, series), do: series

      _entry ->
        nil
    end)
  end

  defp focus_matches_series?(%{series_candidates: candidates}, series) when is_list(candidates) do
    raw = series |> safe_to_string() |> String.trim()
    humanized = Metrics.humanize_series_name(series || "series")

    Enum.any?(candidates, &(&1 in [raw, humanized]))
  end

  defp focus_matches_series?(_focus, _series), do: false

  defp focused_point?({%DateTime{} = point_dt, _value}, %DateTime{} = focus_dt, before_ms, after_ms) do
    diff = DateTime.diff(point_dt, focus_dt, :millisecond)
    diff >= -before_ms and diff <= after_ms
  end

  defp focused_point?(_point, _focus_dt, _before_ms, _after_ms), do: false

  defp annotation_value(annotation, keys), do: Enum.find_value(keys, &Map.get(annotation, &1))

  defp first_present(values) do
    Enum.find(values, fn
      nil -> false
      value when is_binary(value) -> String.trim(value) != ""
      _ -> true
    end)
  end

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

  defp parse_datetime(_value), do: {:error, :not_datetime}

  defp parse_nonnegative_integer(value) when is_integer(value) and value >= 0, do: value

  defp parse_nonnegative_integer(value) when is_float(value) and value >= 0 do
    value |> Float.floor() |> trunc()
  end

  defp parse_nonnegative_integer(value) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp parse_nonnegative_integer(_value), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp safe_to_string(nil), do: ""
  defp safe_to_string(value) when is_binary(value), do: value
  defp safe_to_string(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_to_string(value), do: inspect(value)
end
