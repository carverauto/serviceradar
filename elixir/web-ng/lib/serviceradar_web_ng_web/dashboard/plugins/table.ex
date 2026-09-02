defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Table do
  @moduledoc false

  @behaviour ServiceRadarWebNGWeb.Dashboard.Plugin

  use Phoenix.LiveComponent

  import ServiceRadarWebNGWeb.SRQLComponents, only: [srql_results_table: 1]
  import ServiceRadarWebNGWeb.UIComponents, only: [ui_panel: 1]

  @max_table_rows 500
  @max_columns 20

  @impl true
  def id, do: "table"

  @impl true
  def title, do: "Table"

  @impl true
  def supports?(_srql_response), do: true

  @impl true
  def build(%{} = srql_response) do
    columns = extract_columns(srql_response)

    source_results =
      srql_response
      |> Map.get("results", [])
      |> normalize_results(columns)

    columns =
      columns
      |> resolve_columns(source_results)
      |> Enum.take(@max_columns)
      |> filter_device_id_column()

    total_count = length(source_results)

    {:ok,
     %{
       columns: columns,
       source_results: source_results,
       max_rows: @max_table_rows,
       max_columns: @max_columns,
       results: display_results(source_results, nil, :asc, @max_table_rows),
       sort_col: nil,
       sort_dir: :asc,
       total_count: total_count,
       truncated: total_count > @max_table_rows
     }}
  end

  @impl true
  def update(%{panel_assigns: panel_assigns} = assigns, socket) do
    panel_assigns = panel_assigns || %{}
    source_results = fetch_panel_value(panel_assigns, :source_results, fetch_panel_value(panel_assigns, :results, []))
    max_rows = fetch_panel_value(panel_assigns, :max_rows, @max_table_rows)
    sort_col = Map.get(socket.assigns, :sort_col, fetch_panel_value(panel_assigns, :sort_col))

    sort_dir = Map.get(socket.assigns, :sort_dir, fetch_panel_value(panel_assigns, :sort_dir, :asc))

    timezone =
      case fetch_panel_value(panel_assigns, :timezone) do
        nil -> "Etc/UTC"
        timezone -> timezone
      end

    results = display_results(source_results, sort_col, sort_dir, max_rows)

    socket =
      socket
      |> assign(Map.delete(assigns, :panel_assigns))
      |> assign(panel_assigns)
      |> assign(:source_results, source_results)
      |> assign(:results, results)
      |> assign(:sort_col, sort_col)
      |> assign(:sort_dir, normalize_sort_dir(sort_dir))
      |> assign(:timezone, timezone)

    {:ok, socket}
  end

  @impl true
  def handle_event("sort", %{"col" => col}, socket) do
    columns = socket.assigns[:columns] || []

    if col in columns do
      sort_dir = next_sort_dir(socket.assigns[:sort_col], socket.assigns[:sort_dir], col)
      max_rows = socket.assigns[:max_rows] || @max_table_rows
      source_results = socket.assigns[:source_results] || []

      {:noreply,
       socket
       |> assign(:sort_col, col)
       |> assign(:sort_dir, sort_dir)
       |> assign(:results, display_results(source_results, col, sort_dir, max_rows))}
    else
      {:noreply, socket}
    end
  end

  defp extract_columns(srql_response) do
    Enum.find_value(
      [
        viz_columns(srql_response),
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

  defp viz_columns(%{"viz" => %{"columns" => columns}}) when is_list(columns), do: columns
  defp viz_columns(%{viz: %{columns: columns}}) when is_list(columns), do: columns
  defp viz_columns(_srql_response), do: nil

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

  # Fall back to inferring columns from the rows when none are supplied.
  defp resolve_columns(columns, _rows) when is_list(columns) and columns != [], do: columns
  defp resolve_columns(_columns, rows), do: infer_columns(rows)

  defp infer_columns(rows) do
    Enum.reduce_while(rows, [], fn
      %{} = row, acc ->
        next =
          row
          |> Map.keys()
          |> Enum.map(&to_string/1)
          |> Enum.reduce(acc, fn key, columns ->
            if key in columns, do: columns, else: columns ++ [key]
          end)

        if length(next) >= @max_columns do
          {:halt, Enum.take(next, @max_columns)}
        else
          {:cont, next}
        end

      _row, acc ->
        {:cont, acc}
    end)
  end

  defp filter_device_id_column(columns) when is_list(columns) do
    if "uid" in columns do
      Enum.reject(columns, &(&1 == "device_id"))
    else
      columns
    end
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

  defp fetch_panel_value(panel_assigns, key, default \\ nil) when is_map(panel_assigns) do
    Map.get(panel_assigns, key, Map.get(panel_assigns, to_string(key), default))
  end

  defp display_results(results, sort_col, sort_dir, max_rows) when is_list(results) do
    results
    |> sort_results(sort_col, normalize_sort_dir(sort_dir))
    |> Enum.take(max_rows)
    |> attach_sparklines()
  end

  defp display_results(_results, _sort_col, _sort_dir, _max_rows), do: []

  defp sort_results(results, sort_col, sort_dir) when is_binary(sort_col) do
    results
    |> Enum.with_index()
    |> Enum.sort(fn {left, left_idx}, {right, right_idx} ->
      left_value = Map.get(left, sort_col)
      right_value = Map.get(right, sort_col)

      cond do
        blank_value?(left_value) and blank_value?(right_value) ->
          left_idx <= right_idx

        blank_value?(left_value) ->
          false

        blank_value?(right_value) ->
          true

        true ->
          case compare_present_values(left_value, right_value) do
            :eq -> left_idx <= right_idx
            :lt -> sort_dir == :asc
            :gt -> sort_dir == :desc
          end
      end
    end)
    |> Enum.map(fn {row, _idx} -> row end)
  end

  defp sort_results(results, _sort_col, _sort_dir), do: results

  defp compare_present_values(left, right) do
    with {:ok, left_dt} <- parse_datetime(left),
         {:ok, right_dt} <- parse_datetime(right) do
      compare_terms(DateTime.to_unix(left_dt, :microsecond), DateTime.to_unix(right_dt, :microsecond))
    else
      _ ->
        with {:ok, left_num} <- parse_number(left),
             {:ok, right_num} <- parse_number(right) do
          compare_terms(left_num, right_num)
        else
          _ -> compare_terms(sort_string(left), sort_string(right))
        end
    end
  end

  defp compare_terms(left, right) when left < right, do: :lt
  defp compare_terms(left, right) when left > right, do: :gt
  defp compare_terms(_left, _right), do: :eq

  defp blank_value?(nil), do: true
  defp blank_value?(""), do: true
  defp blank_value?(_), do: false

  defp sort_string(value) do
    value
    |> safe_to_string()
    |> String.downcase()
  end

  defp next_sort_dir(current_col, current_dir, col) when current_col == col do
    case normalize_sort_dir(current_dir) do
      :asc -> :desc
      :desc -> :asc
    end
  end

  defp next_sort_dir(_current_col, _current_dir, _col), do: :asc

  defp normalize_sort_dir(:desc), do: :desc
  defp normalize_sort_dir("desc"), do: :desc
  defp normalize_sort_dir(_), do: :asc

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
  defp safe_to_string(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp safe_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_to_string(value), do: inspect(value)

  @impl true
  def render(assigns) do
    ~H"""
    <div id={"panel-#{@id}"}>
      <.ui_panel>
        <:header>
          <div class="min-w-0">
            <div class="text-sm font-semibold">Table</div>
          </div>
        </:header>

        <div :if={@truncated} class="mb-3 text-xs text-sr-muted">
          Showing first {@max_rows} of {@total_count} rows.
        </div>

        <.srql_results_table
          id={"panel-#{@id}-table"}
          rows={@results}
          columns={@columns}
          max_columns={@max_columns}
          sort_col={@sort_col}
          sort_dir={@sort_dir}
          sort_event="sort"
          sort_target={@myself}
          timezone={@timezone}
          empty_message="No results."
        />
      </.ui_panel>
    </div>
    """
  end
end
