defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Table do
  @moduledoc false

  @behaviour ServiceRadarWebNGWeb.Dashboard.Plugin

  use Phoenix.LiveComponent

  import ServiceRadarWebNGWeb.SRQLComponents, only: [srql_results_table: 1]
  import ServiceRadarWebNGWeb.UIComponents, only: [ui_panel: 1]

  @impl true
  def id, do: "table"

  @impl true
  def title, do: "Table"

  @impl true
  def supports?(_srql_response), do: true

  @impl true
  def build(%{} = srql_response) do
    results =
      srql_response
      |> Map.get("results", [])
      |> normalize_results()
      |> attach_sparklines()

    {:ok, %{results: results}}
  end

  @impl true
  def update(%{panel_assigns: panel_assigns} = assigns, socket) do
    socket =
      socket
      |> assign(Map.delete(assigns, :panel_assigns))
      |> assign(panel_assigns || %{})

    {:ok, socket}
  end

  defp normalize_results(results) when is_list(results) do
    Enum.map(results, fn
      %{} = row -> row
      value -> %{"value" => value}
    end)
  end

  defp normalize_results(_), do: []

  defp attach_sparklines(results) when is_list(results) do
    with true <- length(results) >= 5,
         {:ok, spec} <- infer_sparkline_spec(results),
         {:ok, spark_by_series} <- build_sparklines(results, spec),
         true <- map_size(spark_by_series) > 0 do
      add_sparklines(results, spec, spark_by_series)
    else
      _ -> results
    end
  end

  defp attach_sparklines(results), do: results

  defp infer_sparkline_spec(results) do
    keys =
      results
      |> Enum.find(&is_map/1)
      |> case do
        %{} = row -> row |> Map.keys() |> Enum.map(&to_string/1)
        _ -> []
      end

    x =
      Enum.find(keys, fn k ->
        k in ["timestamp", "ts", "time", "bucket", "inserted_at", "observed_at"]
      end)

    y =
      Enum.find(keys, fn k -> k in ["value", "avg", "min", "max", "count"] end) ||
        Enum.find(keys, fn k -> String.contains?(k, "usage") end) ||
        Enum.find(keys, fn k -> numeric_column?(results, k) end)

    series_key =
      Enum.find(keys, fn k ->
        k in [
          "series",
          "uid",
          "device_id",
          "agent_id",
          "host_id",
          "gateway_id",
          "mount_point",
          "interface",
          "if_index",
          "name",
          "metric_name"
        ]
      end)

    if is_binary(x) and is_binary(y) do
      {:ok, %{x: x, y: y, series_key: series_key || "series"}}
    else
      {:error, :no_sparkline_spec}
    end
  end

  defp build_sparklines(results, %{x: x, y: y, series_key: series_key}) do
    rows =
      results
      |> Enum.filter(&is_map/1)
      |> Enum.take(200)

    points =
      Enum.reduce(rows, %{}, fn row, acc ->
        with {:ok, dt} <- parse_datetime(Map.get(row, x)),
             {:ok, value} <- parse_number(Map.get(row, y)) do
          series = series_value(row, series_key)
          Map.update(acc, series, [{dt, value}], fn existing -> existing ++ [{dt, value}] end)
        else
          _ -> acc
        end
      end)

    series_count = map_size(points)
    max_points = points |> Map.values() |> Enum.map(&length/1) |> Enum.max(fn -> 0 end)

    if series_count == 0 or series_count > 12 or max_points < 3 do
      {:error, :sparklines_not_worth_it}
    else
      sparklines =
        Map.new(points, fn {series, series_points} ->
          {series, Enum.take(series_points, 60)}
        end)

      {:ok, sparklines}
    end
  end

  defp series_value(row, series_key) when is_map(row) do
    value =
      row
      |> Map.get(series_key)
      |> safe_to_string()
      |> String.trim()

    if value == "", do: "overall", else: value
  end

  defp series_value(_row, _series_key), do: "overall"

  defp add_sparklines(results, spec, spark_by_series) do
    Enum.map(results, fn
      %{} = row ->
        series_key = series_value(row, spec.series_key)

        case Map.get(spark_by_series, series_key) do
          spark when is_list(spark) -> Map.put(row, "_sparkline", spark)
          _ -> row
        end

      other ->
        other
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

  defp safe_to_string(nil), do: ""
  defp safe_to_string(value) when is_binary(value), do: value
  defp safe_to_string(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_to_string(value), do: inspect(value)

  @impl true
  def render(assigns) do
    ~H"""
    <div id={"panel-#{@id}"}>
      <.ui_panel>
        <:header>
          <div class="text-sm font-semibold">Table</div>
        </:header>

        <.srql_results_table id={"panel-#{@id}-table"} rows={@results} empty_message="No results." />
      </.ui_panel>
    </div>
    """
  end
end
