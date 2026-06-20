defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Table do
  @moduledoc false

  @behaviour ServiceRadarWebNGWeb.Dashboard.Plugin

  use Phoenix.LiveComponent

  import ServiceRadarWebNGWeb.SRQLComponents, only: [srql_results_table: 1]
  import ServiceRadarWebNGWeb.UIComponents, only: [ui_panel: 1]

  @max_table_rows 500

  @impl true
  def id, do: "table"

  @impl true
  def title, do: "Table"

  @impl true
  def supports?(_srql_response), do: true

  @impl true
  def build(%{} = srql_response) do
    columns = extract_columns(srql_response)

    results =
      srql_response
      |> Map.get("results", [])
      |> normalize_results(columns)

    total_count = length(results)

    results =
      results
      |> Enum.take(@max_table_rows)
      |> attach_sparklines()

    {:ok,
     %{
       columns: columns,
       max_rows: @max_table_rows,
       results: results,
       total_count: total_count,
       truncated: total_count > @max_table_rows
     }}
  end

  @impl true
  def update(%{panel_assigns: panel_assigns} = assigns, socket) do
    socket =
      socket
      |> assign(Map.delete(assigns, :panel_assigns))
      |> assign(panel_assigns || %{})

    {:ok, socket}
  end

  defp extract_columns(srql_response) do
    Enum.find_value(
      [
        Map.get(srql_response, "columns"),
        Map.get(srql_response, :columns),
        get_in(srql_response, ["schema", "columns"]),
        get_in(srql_response, [:schema, :columns]),
        get_in(srql_response, ["viz", "columns"]),
        get_in(srql_response, [:viz, :columns])
      ],
      &normalize_columns/1
    )
  end

  defp normalize_columns(columns) when is_list(columns) do
    columns =
      columns
      |> Enum.map(&column_name/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if columns == [], do: nil, else: columns
  end

  defp normalize_columns(_), do: nil

  defp column_name(%{} = column) do
    column
    |> fetch_first([:name, "name", :field, "field", :id, "id"])
    |> column_name()
  end

  defp column_name(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp column_name(value) when is_atom(value), do: value |> Atom.to_string() |> column_name()
  defp column_name(_), do: nil

  defp fetch_first(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp normalize_results(results, [single_column]) when is_list(results) and is_binary(single_column) do
    Enum.map(results, fn
      %{} = row -> stringify_keys(row)
      value -> %{single_column => value}
    end)
  end

  defp normalize_results(results, _columns) when is_list(results) do
    Enum.map(results, fn
      %{} = row -> stringify_keys(row)
      value -> %{"value" => value}
    end)
  end

  defp normalize_results(_, _), do: []

  defp stringify_keys(row) when is_map(row) do
    Map.new(row, fn {key, value} -> {to_string(key), value} end)
  end

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

        <div :if={@truncated} class="mb-3 text-xs text-base-content/60">
          Showing first {@max_rows} of {@total_count} rows.
        </div>

        <.srql_results_table
          id={"panel-#{@id}-table"}
          rows={@results}
          columns={@columns}
          empty_message="No results."
        />
      </.ui_panel>
    </div>
    """
  end
end
