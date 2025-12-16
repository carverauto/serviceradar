defmodule ServiceRadarWebNGWeb.SRQL.Viz do
  @moduledoc false

  @type inferred ::
          :none
          | {:timeseries, %{x: String.t(), y: String.t(), points: list({DateTime.t(), number()})}}
          | {:categories,
             %{label: String.t(), value: String.t(), items: list({String.t(), number()})}}

  @max_points 120
  @max_categories 12

  def infer(rows) when is_list(rows) do
    rows = Enum.filter(rows, &is_map/1)

    with {:ok, inferred} <- infer_timeseries(rows) do
      inferred
    else
      _ ->
        case infer_categories(rows) do
          {:ok, inferred} -> inferred
          _ -> :none
        end
    end
  end

  def infer(_), do: :none

  defp infer_timeseries([]), do: {:error, :no_rows}

  defp infer_timeseries([first | _] = rows) do
    keys = Map.keys(first) |> Enum.map(&to_string/1)

    x_key =
      Enum.find(keys, fn k ->
        k in ["timestamp", "ts", "time", "bucket", "inserted_at", "observed_at"]
      end)

    y_key =
      Enum.find(keys, fn k ->
        k in ["value", "count", "avg", "min", "max", "p95", "p99"]
      end) || Enum.find(keys, &numeric_column?(rows, &1))

    with true <- is_binary(x_key),
         true <- is_binary(y_key),
         points when is_list(points) and points != [] <- extract_points(rows, x_key, y_key) do
      {:ok, {:timeseries, %{x: x_key, y: y_key, points: points}}}
    else
      _ -> {:error, :no_timeseries}
    end
  end

  defp infer_categories([]), do: {:error, :no_rows}

  defp infer_categories([first | _] = rows) do
    keys = Map.keys(first) |> Enum.map(&to_string/1)

    value_key =
      Enum.find(keys, fn k ->
        k in ["count", "value"]
      end) || Enum.find(keys, &numeric_column?(rows, &1))

    label_key =
      keys
      |> Enum.reject(&(&1 == value_key))
      |> Enum.find(&stringish_column?(rows, &1))

    with true <- is_binary(label_key),
         true <- is_binary(value_key),
         items when is_list(items) and items != [] <-
           extract_categories(rows, label_key, value_key) do
      {:ok, {:categories, %{label: label_key, value: value_key, items: items}}}
    else
      _ -> {:error, :no_categories}
    end
  end

  defp extract_points(rows, x_key, y_key) do
    rows
    |> Enum.take(@max_points)
    |> Enum.reduce([], fn row, acc ->
      with {:ok, dt} <- parse_datetime(Map.get(row, x_key)),
           {:ok, y} <- parse_number(Map.get(row, y_key)) do
        [{dt, y} | acc]
      else
        _ -> acc
      end
    end)
    |> Enum.reverse()
  end

  defp extract_categories(rows, label_key, value_key) do
    rows
    |> Enum.reduce(%{}, fn row, acc ->
      with label when is_binary(label) <- to_string(Map.get(row, label_key) || ""),
           true <- label != "",
           {:ok, value} <- parse_number(Map.get(row, value_key)) do
        Map.update(acc, label, value, &(&1 + value))
      else
        _ -> acc
      end
    end)
    |> Enum.sort_by(fn {_k, v} -> -v end)
    |> Enum.take(@max_categories)
  end

  defp numeric_column?(rows, key) do
    Enum.any?(rows, fn row ->
      case Map.get(row, key) do
        v when is_integer(v) or is_float(v) ->
          true

        v when is_binary(v) ->
          match?({_, ""}, Float.parse(v)) or match?({_, ""}, Integer.parse(v))

        _ ->
          false
      end
    end)
  end

  defp stringish_column?(rows, key) do
    Enum.any?(rows, fn row ->
      v = Map.get(row, key)
      is_binary(v) and byte_size(v) > 0
    end)
  end

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
end
