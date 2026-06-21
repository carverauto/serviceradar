defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Table do
  @moduledoc false

  @behaviour ServiceRadarWebNGWeb.Dashboard.Plugin

  use Phoenix.LiveComponent

  import ServiceRadarWebNGWeb.CoreComponents, only: [icon: 1]
  import ServiceRadarWebNGWeb.SRQLComponents, only: [srql_results_table: 1]
  import ServiceRadarWebNGWeb.UIComponents, only: [ui_panel: 1]

  @row_cap 500
  @page_size 50
  @max_columns 20

  @impl true
  def id, do: "table"

  @impl true
  def title, do: "Table"

  @impl true
  def supports?(_srql_response), do: true

  @impl true
  def build(%{} = srql_response) do
    raw_results =
      srql_response
      |> Map.get("results", [])
      |> normalize_results()

    columns = table_columns(srql_response, raw_results)

    results =
      raw_results
      |> attach_sparklines()
      |> Enum.take(@row_cap)

    total_rows = length(raw_results)

    {:ok,
     results
     |> table_state(columns, nil, "asc", 1)
     |> Map.merge(%{
       result_count: total_rows,
       capped?: total_rows > @row_cap,
       row_cap: @row_cap,
       page_size: @page_size,
       max_columns: @max_columns
     })}
  end

  @impl true
  def update(%{panel_assigns: panel_assigns} = assigns, socket) do
    socket =
      socket
      |> assign(Map.delete(assigns, :panel_assigns))
      |> assign(panel_assigns || %{})

    {:ok, socket}
  end

  @impl true
  def handle_event("table_sort", %{"field" => field}, socket) do
    field = to_string(field)
    columns = socket.assigns.columns || []

    socket =
      if field in columns and not socket.assigns.capped? do
        sort_dir = next_sort_dir(socket.assigns.sort_field, socket.assigns.sort_dir, field)

        assign_table_state(socket, field, sort_dir, 1)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("table_page", %{"page" => page}, socket) do
    {:noreply, assign_table_state(socket, socket.assigns.sort_field, socket.assigns.sort_dir, page)}
  end

  defp assign_table_state(socket, sort_field, sort_dir, page) do
    state =
      socket.assigns.results
      |> table_state(socket.assigns.columns, sort_field, sort_dir, page)
      |> Map.drop([:results, :columns])

    assign(socket, state)
  end

  defp normalize_results(results) when is_list(results) do
    Enum.map(results, fn
      %{} = row -> row
      value -> %{"value" => value}
    end)
  end

  defp normalize_results(_), do: []

  defp table_columns(srql_response, rows) do
    srql_response
    |> viz_columns()
    |> case do
      [] -> infer_columns(rows)
      columns -> Enum.take(columns, @max_columns)
    end
    |> filter_device_id_column()
  end

  defp viz_columns(%{"viz" => %{"columns" => columns}}) when is_list(columns) do
    columns
    |> Enum.map(fn
      %{"name" => name} -> name
      %{name: name} -> name
      name -> name
    end)
    |> normalize_column_list()
  end

  defp viz_columns(_srql_response), do: []

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

  defp normalize_column_list(columns) do
    columns
    |> Enum.map(&safe_to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp filter_device_id_column(columns) when is_list(columns) do
    if "uid" in columns do
      Enum.reject(columns, &(&1 == "device_id"))
    else
      columns
    end
  end

  defp table_state(results, columns, sort_field, sort_dir, page) do
    sorted = sort_results(results, sort_field, sort_dir)
    total = length(sorted)
    page_count = max(div(total + @page_size - 1, @page_size), 1)
    page = page |> parse_page() |> min(page_count) |> max(1)
    offset = (page - 1) * @page_size
    page_rows = sorted |> Enum.drop(offset) |> Enum.take(@page_size)

    %{
      results: results,
      columns: columns,
      page_rows: page_rows,
      page: page,
      page_count: page_count,
      page_from: if(total == 0, do: 0, else: offset + 1),
      page_to: min(offset + length(page_rows), total),
      visible_rows: total,
      sort_field: sort_field,
      sort_dir: normalize_sort_dir(sort_dir)
    }
  end

  defp parse_page(value) when is_integer(value), do: value

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {page, ""} -> page
      _ -> 1
    end
  end

  defp parse_page(_), do: 1

  defp next_sort_dir(current_field, "asc", field) when current_field == field, do: "desc"
  defp next_sort_dir(_current_field, _current_dir, _field), do: "asc"

  defp normalize_sort_dir("desc"), do: "desc"
  defp normalize_sort_dir(_), do: "asc"

  defp sort_results(results, nil, _sort_dir), do: results
  defp sort_results(results, "", _sort_dir), do: results

  defp sort_results(results, sort_field, sort_dir) do
    direction = normalize_sort_dir(sort_dir)

    results
    |> Enum.with_index()
    |> Enum.sort(fn left, right -> row_precedes?(left, right, sort_field, direction) end)
    |> Enum.map(&elem(&1, 0))
  end

  defp row_precedes?({left, left_idx}, {right, right_idx}, field, direction) do
    case compare_sort_values(Map.get(left, field), Map.get(right, field)) do
      :lt -> direction == "asc"
      :gt -> direction == "desc"
      :eq -> left_idx <= right_idx
    end
  end

  defp compare_sort_values(left, right) do
    left = sortable_value(left)
    right = sortable_value(right)

    cond do
      left == :blank and right == :blank -> :eq
      left == :blank -> :gt
      right == :blank -> :lt
      left < right -> :lt
      left > right -> :gt
      true -> :eq
    end
  end

  defp sortable_value(nil), do: :blank
  defp sortable_value(""), do: :blank
  defp sortable_value(value) when is_integer(value), do: {0, value * 1.0}
  defp sortable_value(value) when is_float(value), do: {0, value}
  defp sortable_value(%DateTime{} = value), do: {1, DateTime.to_unix(value, :microsecond)}
  defp sortable_value(%NaiveDateTime{} = value), do: {1, NaiveDateTime.to_gregorian_seconds(value)}
  defp sortable_value(%Date{} = value), do: {1, Date.to_gregorian_days(value)}

  defp sortable_value(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        :blank

      match?({_, ""}, Float.parse(trimmed)) ->
        {number, ""} = Float.parse(trimmed)
        {0, number}

      match?({:ok, _, _}, DateTime.from_iso8601(trimmed)) ->
        {:ok, dt, _offset} = DateTime.from_iso8601(trimmed)
        {1, DateTime.to_unix(dt, :microsecond)}

      match?({:ok, _}, NaiveDateTime.from_iso8601(trimmed)) ->
        {:ok, ndt} = NaiveDateTime.from_iso8601(trimmed)
        {1, NaiveDateTime.to_gregorian_seconds(ndt)}

      true ->
        {2, String.downcase(trimmed)}
    end
  end

  defp sortable_value(value), do: {3, safe_to_string(value)}

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

  defp table_summary(assigns) do
    ~H"""
    <div class="text-xs text-base-content/60">
      <span :if={@visible_rows > 0}>
        Showing {@page_from}-{@page_to} of {@visible_rows}
      </span>
      <span :if={@visible_rows == 0}>No rows</span>
      <span :if={@capped?}>
        {" "}(showing first {@row_cap} of {@result_count}; sorting disabled)
      </span>
    </div>
    """
  end

  defp pagination_controls(assigns) do
    ~H"""
    <div :if={@page_count > 1} class="mt-3 flex items-center justify-between gap-3">
      <div class="text-xs text-base-content/60">Page {@page} of {@page_count}</div>
      <div class="join">
        <button
          type="button"
          class="btn btn-xs join-item"
          phx-click="table_page"
          phx-target={@myself}
          phx-value-page={@page - 1}
          disabled={@page <= 1}
          aria-label="Previous page"
          title="Previous page"
        >
          <.icon name="hero-chevron-left" class="size-3" />
        </button>
        <button
          type="button"
          class="btn btn-xs join-item"
          phx-click="table_page"
          phx-target={@myself}
          phx-value-page={@page + 1}
          disabled={@page >= @page_count}
          aria-label="Next page"
          title="Next page"
        >
          <.icon name="hero-chevron-right" class="size-3" />
        </button>
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={"panel-#{@id}"}>
      <.ui_panel>
        <:header>
          <div class="min-w-0">
            <div class="text-sm font-semibold">Table</div>
            <.table_summary
              visible_rows={@visible_rows}
              page_from={@page_from}
              page_to={@page_to}
              capped?={@capped?}
              row_cap={@row_cap}
              result_count={@result_count}
            />
          </div>
        </:header>

        <.srql_results_table
          id={"panel-#{@id}-table"}
          rows={@page_rows}
          columns={@columns}
          max_columns={@max_columns}
          empty_message="No results."
          sortable={not @capped?}
          sort_target={@myself}
          sort_field={@sort_field}
          sort_dir={@sort_dir}
        />
        <.pagination_controls page={@page} page_count={@page_count} myself={@myself} />
      </.ui_panel>
    </div>
    """
  end
end
