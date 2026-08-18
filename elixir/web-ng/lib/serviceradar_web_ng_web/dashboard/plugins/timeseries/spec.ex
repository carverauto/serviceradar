defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries.Spec do
  @moduledoc false

  alias ServiceRadarWebNGWeb.SRQL.Viz

  @max_series 6

  def parse_timeseries_spec(%{"suggestions" => suggestions}) when is_list(suggestions) do
    suggestion =
      Enum.find(suggestions, fn
        %{"kind" => "timeseries"} -> true
        _ -> false
      end)

    case suggestion do
      %{"x" => x, "y" => y, "series" => series}
      when is_binary(x) and is_binary(y) and is_binary(series) ->
        {:ok, %{x: x, y: y, series: series}}

      %{"x" => x, "y" => y} when is_binary(x) and is_binary(y) ->
        {:ok, %{x: x, y: y, series: nil}}

      _ ->
        {:error, :missing_timeseries_suggestion}
    end
  end

  def parse_timeseries_spec(_), do: {:error, :missing_suggestions}

  def infer_timeseries_spec(results) when is_list(results) do
    case Viz.infer(results) do
      {:timeseries, %{x: x, y: y}} -> {:ok, %{x: x, y: y, series: nil}}
      _ -> {:error, :missing_timeseries}
    end
  end

  def extract_series_points(results, spec), do: extract_series_points(results, spec, [])

  def extract_series_points(results, %{x: x, y: y, series: series_key}, opts) when is_list(opts) do
    rows = Enum.filter(results, &is_map/1)
    max_series = Keyword.get(opts, :max_series, @max_series)

    {points, units, metadata} =
      Enum.reduce(rows, {%{}, %{}, %{}}, fn row, {points_acc, units_acc, metadata_acc} ->
        series = row_series(row, series_key)

        units_acc = record_series_unit(units_acc, series, row)
        metadata_acc = record_series_metadata(metadata_acc, series, row)

        points_acc =
          with {:ok, dt} <- parse_datetime(Map.get(row, x)),
               {:ok, value} <- parse_number(Map.get(row, y)) do
            Map.update(points_acc, series, [{dt, value}], fn existing -> existing ++ [{dt, value}] end)
          else
            _ -> points_acc
          end

        {points_acc, units_acc, metadata_acc}
      end)

    series_points =
      points
      |> Enum.map(fn {series, series_points} ->
        sorted =
          Enum.sort_by(series_points, fn {dt, _} -> DateTime.to_unix(dt, :millisecond) end)

        {series, sorted}
      end)
      |> Enum.sort_by(fn {series, _points} -> series end)
      |> Enum.take(max_series)

    series_units =
      series_points
      |> Enum.map(fn {series, _points} -> {series, Map.get(units, series)} end)
      |> Enum.reject(fn {_series, unit} -> is_nil(unit) end)
      |> Map.new()

    series_metadata =
      series_points
      |> Enum.map(fn {series, _points} -> {series, Map.get(metadata, series)} end)
      |> Enum.reject(fn {_series, metadata} -> metadata in [nil, %{}] end)
      |> Map.new()

    {:ok, series_points, series_units, series_metadata}
  end

  def series_metadata(series) when is_list(series) do
    series
    |> Enum.map(fn item ->
      name = Map.get(item, :name) || Map.get(item, "name") || "series"
      metadata = counter_metadata(item)

      {to_string(name), metadata}
    end)
    |> Enum.reject(fn {_series, metadata} -> metadata == %{} end)
    |> Map.new()
  end

  def series_metadata(_), do: %{}

  def series_to_points(series) when is_list(series) do
    Enum.map(series, fn item ->
      name = Map.get(item, :name) || Map.get(item, "name") || "series"
      data = Map.get(item, :data) || Map.get(item, "data") || []

      points =
        data
        |> Enum.reduce([], fn point, acc ->
          time = Map.get(point, :time) || Map.get(point, "time")
          value = Map.get(point, :value) || Map.get(point, "value")

          with {:ok, dt} <- parse_datetime(time),
               {:ok, v} <- parse_number(value) do
            [{dt, v} | acc]
          else
            _ -> acc
          end
        end)
        |> Enum.reverse()

      {to_string(name), points}
    end)
  end

  def series_to_points(_), do: []

  def fetch_panel_value(panel_assigns, key, default \\ nil)

  def fetch_panel_value(panel_assigns, key, default) when is_map(panel_assigns) do
    Map.get(panel_assigns, key, Map.get(panel_assigns, to_string(key), default))
  end

  def fetch_panel_value(_panel_assigns, _key, default), do: default

  defp record_series_unit(units, series, row) do
    case Map.get(units, series) || normalize_unit(row_unit(row)) do
      nil -> units
      unit -> Map.put(units, series, unit)
    end
  end

  defp record_series_metadata(metadata, series, row) do
    row_metadata = counter_metadata(row)

    if row_metadata == %{} do
      metadata
    else
      Map.update(metadata, series, row_metadata, &Map.merge(row_metadata, &1))
    end
  end

  defp counter_metadata(%{} = row) do
    nested_metadata = metadata_map(Map.get(row, :metadata) || Map.get(row, "metadata"))

    Enum.reduce(
      [
        {:counter_width,
         first_present([
           Map.get(row, :counter_width),
           Map.get(row, "counter_width"),
           Map.get(nested_metadata, :counter_width),
           Map.get(nested_metadata, "counter_width")
         ])},
        {:counter_bits,
         first_present([
           Map.get(row, :counter_bits),
           Map.get(row, "counter_bits"),
           Map.get(nested_metadata, :counter_bits),
           Map.get(nested_metadata, "counter_bits")
         ])},
        {:pdu_width,
         first_present([
           Map.get(row, :pdu_width),
           Map.get(row, "pdu_width"),
           Map.get(nested_metadata, :pdu_width),
           Map.get(nested_metadata, "pdu_width")
         ])}
      ],
      %{},
      fn
        {_key, nil}, acc -> acc
        {key, value}, acc -> Map.put(acc, key, value)
      end
    )
  end

  defp counter_metadata(_), do: %{}

  defp metadata_map(value) when is_map(value), do: value
  defp metadata_map(_), do: %{}

  defp row_unit(row) do
    first_present([
      Map.get(row, "metric.unit"),
      Map.get(row, :metric_unit),
      Map.get(row, "metric_unit"),
      nested_map_get(row, ["metric", "unit"]),
      nested_map_get(row, [:metric, :unit]),
      Map.get(row, "unit"),
      Map.get(row, :unit)
    ])
  end

  defp nested_map_get(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      nil -> nil
      value -> nested_map_get(value, rest)
    end
  end

  defp nested_map_get(value, []), do: value
  defp nested_map_get(_value, _keys), do: nil

  defp first_present(values) do
    Enum.find(values, fn
      nil -> false
      value when is_binary(value) -> String.trim(value) != ""
      _ -> true
    end)
  end

  defp normalize_unit(unit) when is_atom(unit), do: normalize_unit(Atom.to_string(unit))

  defp normalize_unit(unit) when is_binary(unit) do
    raw = String.trim(unit)
    value = String.downcase(raw)

    cond do
      value in ["%", "percent", "percentage"] ->
        :percent

      raw == "B" or value in ["by", "byte", "bytes"] ->
        :bytes

      raw == "B/s" or value in ["by/s", "bytes/s", "bytes/sec", "bytes_per_sec", "bytes_per_second"] ->
        :bytes_per_sec

      value in ["b/s", "bit/s", "bits/s", "bps", "bits_per_sec", "bits_per_second"] ->
        :bits_per_sec

      value in ["hz", "hertz"] ->
        :hz

      value in ["1/s", "count/s", "counts/s", "count_per_sec", "counts_per_sec"] ->
        :count_per_sec

      true ->
        nil
    end
  end

  defp normalize_unit(_), do: nil

  defp parse_number(value) when is_integer(value), do: {:ok, value * 1.0}
  defp parse_number(value) when is_float(value), do: {:ok, value}

  defp parse_number(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        {:error, :empty}

      match?({_, ""}, Float.parse(value)) ->
        {v, ""} = Float.parse(value)
        {:ok, v}

      match?({_, ""}, Integer.parse(value)) ->
        {v, ""} = Integer.parse(value)
        {:ok, v * 1.0}

      true ->
        {:error, :nan}
    end
  end

  defp parse_number(_), do: {:error, :not_numeric}

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

  defp parse_datetime(_), do: {:error, :not_datetime}

  defp safe_to_string(nil), do: ""
  defp safe_to_string(value) when is_binary(value), do: value
  defp safe_to_string(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_to_string(value), do: inspect(value)

  defp row_series(row, series_key) when is_map(row) and is_binary(series_key) do
    row
    |> Map.get(series_key)
    |> normalize_series_value()
  end

  defp row_series(row, _series_key) when is_map(row) do
    row
    |> inferred_series_value()
    |> normalize_series_value()
  end

  defp row_series(_row, _series_key), do: "series"

  defp inferred_series_value(row) do
    first_present([
      Map.get(row, "mount_point"),
      Map.get(row, :mount_point),
      Map.get(row, "core_id"),
      Map.get(row, :core_id),
      Map.get(row, "series_key"),
      Map.get(row, :series_key)
    ])
  end

  defp normalize_series_value(nil), do: "series"

  defp normalize_series_value(value) do
    value
    |> safe_to_string()
    |> String.trim()
    |> normalize_series_label()
  end

  defp normalize_series_label(""), do: "overall"
  defp normalize_series_label(value), do: value
end
