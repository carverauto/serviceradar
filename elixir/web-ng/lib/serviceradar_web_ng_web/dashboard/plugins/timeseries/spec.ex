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

  def extract_series_points(results, %{x: x, y: y, series: series_key}) do
    rows = Enum.filter(results, &is_map/1)

    points =
      Enum.reduce(rows, %{}, fn row, acc ->
        series =
          if is_binary(series_key) do
            row
            |> Map.get(series_key)
            |> safe_to_string()
            |> String.trim()
            |> normalize_series_label()
          else
            "series"
          end

        with {:ok, dt} <- parse_datetime(Map.get(row, x)),
             {:ok, value} <- parse_number(Map.get(row, y)) do
          Map.update(acc, series, [{dt, value}], fn existing -> existing ++ [{dt, value}] end)
        else
          _ -> acc
        end
      end)

    series_points =
      points
      |> Enum.map(fn {series, series_points} ->
        sorted =
          Enum.sort_by(series_points, fn {dt, _} -> DateTime.to_unix(dt, :millisecond) end)

        {series, sorted}
      end)
      |> Enum.sort_by(fn {series, _points} -> series end)
      |> Enum.take(@max_series)

    {:ok, series_points}
  end

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

  defp normalize_series_label(""), do: "overall"
  defp normalize_series_label(value), do: value
end
