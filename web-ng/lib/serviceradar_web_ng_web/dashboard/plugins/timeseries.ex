defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries do
  @moduledoc false

  use Phoenix.LiveComponent

  @behaviour ServiceRadarWebNGWeb.Dashboard.Plugin

  import ServiceRadarWebNGWeb.UIComponents, only: [ui_panel: 1]

  @max_series 6
  @max_points 200
  @chart_width 800
  @chart_height 140
  @chart_pad 8

  @impl true
  def id, do: "timeseries"

  @impl true
  def title, do: "Timeseries"

  @impl true
  def supports?(%{"viz" => %{"suggestions" => suggestions}}) when is_list(suggestions) do
    Enum.any?(suggestions, fn
      %{"kind" => "timeseries"} -> true
      _ -> false
    end)
  end

  def supports?(_), do: false

  @impl true
  def build(%{"results" => results, "viz" => viz} = _srql_response)
      when is_list(results) and is_map(viz) do
    with {:ok, spec} <- parse_timeseries_spec(viz),
         {:ok, series_points} <- extract_series_points(results, spec) do
      {:ok, %{spec: spec, series_points: series_points}}
    end
  end

  def build(_), do: {:error, :invalid_response}

  defp parse_timeseries_spec(%{"suggestions" => suggestions}) when is_list(suggestions) do
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

  defp parse_timeseries_spec(_), do: {:error, :missing_suggestions}

  defp extract_series_points(results, %{x: x, y: y, series: series_key}) do
    rows =
      results
      |> Enum.filter(&is_map/1)
      |> Enum.take(@max_points)

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
      |> Enum.sort_by(fn {series, _points} -> series end)
      |> Enum.take(@max_series)

    {:ok, series_points}
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

  defp safe_to_string(nil), do: ""
  defp safe_to_string(value) when is_binary(value), do: value
  defp safe_to_string(value) when is_integer(value), do: Integer.to_string(value)
  defp safe_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_to_string(value), do: inspect(value)

  defp normalize_series_label(""), do: "overall"
  defp normalize_series_label(nil), do: "overall"
  defp normalize_series_label(value), do: value

  defp chart_paths(points) when is_list(points) do
    values = Enum.map(points, fn {_dt, v} -> v end)

    case values do
      [] ->
        %{line: "", area: "", min: 0.0, max: 0.0, latest: nil}

      _ ->
        min_v = Enum.min(values, fn -> 0 end)
        max_v = Enum.max(values, fn -> 0 end)
        latest = List.last(values)

        coords =
          Enum.with_index(values)
          |> Enum.map(fn {v, idx} ->
            x = idx_to_x(idx, length(values))
            y = value_to_y(v, min_v, max_v)
            {x, y}
          end)

        line =
          coords
          |> Enum.map(fn {x, y} -> "#{x},#{y}" end)
          |> Enum.join(" ")

        area =
          case coords do
            [] ->
              ""

            [{first_x, _} | _] ->
              {last_x, _} = List.last(coords)

              path =
                coords
                |> Enum.map(fn {x, y} -> "#{x},#{y}" end)
                |> Enum.join(" L ")

              "M #{first_x},#{baseline_y()} L " <>
                path <>
                " L #{last_x},#{baseline_y()} Z"
          end

        %{line: line, area: area, min: min_v, max: max_v, latest: latest}
    end
  end

  defp value_to_y(_v, min_v, max_v) when min_v == max_v, do: round(@chart_height / 2)

  defp value_to_y(v, min_v, max_v) do
    usable = @chart_height - @chart_pad * 2
    scaled = (v - min_v) / (max_v - min_v)
    round(@chart_height - @chart_pad - scaled * usable)
  end

  defp baseline_y, do: @chart_height - @chart_pad

  defp idx_to_x(_idx, 0), do: @chart_pad
  defp idx_to_x(0, _len), do: @chart_pad

  defp idx_to_x(idx, len) when len > 1 do
    usable = @chart_width - @chart_pad * 2
    round(@chart_pad + idx / (len - 1) * usable)
  end

  defp series_color(index) do
    # Dracula theme inspired colors
    colors = [
      {"#50fa7b", "rgba(80,250,123,0.25)"},
      {"#8be9fd", "rgba(139,233,253,0.25)"},
      {"#bd93f9", "rgba(189,147,249,0.25)"},
      {"#ff79c6", "rgba(255,121,198,0.25)"},
      {"#ffb86c", "rgba(255,184,108,0.25)"},
      {"#f1fa8c", "rgba(241,250,140,0.25)"}
    ]

    Enum.at(colors, rem(index, length(colors)))
  end

  defp dt_label(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %-d %H:%M")
  defp dt_label(_), do: ""

  defp format_value(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 2)
  defp format_value(v) when is_integer(v), do: Integer.to_string(v)
  defp format_value(_), do: "—"

  @impl true
  def update(%{panel_assigns: panel_assigns} = assigns, socket) do
    compact = Map.get(panel_assigns || %{}, :compact, false)

    socket =
      socket
      |> assign(Map.drop(assigns, [:panel_assigns]))
      |> assign(panel_assigns || %{})
      |> assign(:compact, compact)
      |> assign(:chart_width, @chart_width)
      |> assign(:chart_height, @chart_height)
      |> assign(:chart_pad, @chart_pad)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    compact = Map.get(assigns, :compact, false)
    series_points = assigns.series_points || []

    # Pre-compute chart data for each series for hover functionality
    series_data =
      Enum.with_index(series_points)
      |> Enum.map(fn {{series, points}, idx} ->
        paths = chart_paths(points)
        {stroke, _fill} = series_color(idx)
        point_data = Enum.map(points, fn {dt, v} -> %{dt: dt_label(dt), v: v} end)
        %{series: series, paths: paths, stroke: stroke, idx: idx, point_data: point_data}
      end)

    assigns =
      assigns
      |> assign(:compact, compact)
      |> assign(:series_count, length(series_points))
      |> assign(:series_data, series_data)
      |> assign(:first_dt, first_dt(series_points))
      |> assign(:last_dt, last_dt(series_points))

    if compact do
      render_compact(assigns)
    else
      render_full(assigns)
    end
  end

  defp render_compact(assigns) do
    ~H"""
    <div id={"panel-#{@id}"} class="p-4">
      <div class={[
        "grid gap-3",
        @series_count > 1 && "grid-cols-1 lg:grid-cols-2 xl:grid-cols-3",
        @series_count == 1 && "grid-cols-1"
      ]}>
        <%= for data <- @series_data do %>
          <.chart_card
            id={@id}
            data={data}
            chart_width={@chart_width}
            chart_height={@chart_height}
            chart_pad={@chart_pad}
            compact={true}
          />
        <% end %>
      </div>
    </div>
    """
  end

  defp render_full(assigns) do
    ~H"""
    <div id={"panel-#{@id}"}>
      <.ui_panel>
        <:header>
          <div class="min-w-0">
            <div class="text-sm font-semibold">{@title || "Timeseries"}</div>
          </div>
          <div class="text-xs text-base-content/50 font-mono">
            <span :if={is_struct(@first_dt, DateTime)}>{dt_label(@first_dt)}</span>
            <span class="px-1">→</span>
            <span :if={is_struct(@last_dt, DateTime)}>{dt_label(@last_dt)}</span>
          </div>
        </:header>

        <div class={[
          "grid gap-4",
          @series_count > 1 && "grid-cols-1 md:grid-cols-2",
          @series_count <= 1 && "grid-cols-1"
        ]}>
          <%= for data <- @series_data do %>
            <.chart_card
              id={@id}
              data={data}
              chart_width={@chart_width}
              chart_height={@chart_height}
              chart_pad={@chart_pad}
              compact={false}
            />
          <% end %>
        </div>
      </.ui_panel>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :data, :map, required: true
  attr :chart_width, :integer, required: true
  attr :chart_height, :integer, required: true
  attr :chart_pad, :integer, required: true
  attr :compact, :boolean, default: false

  defp chart_card(assigns) do
    ~H"""
    <div
      id={"chart-#{@id}-#{@data.idx}"}
      class={["rounded-lg border border-base-200 bg-base-100 relative group", @compact && "p-3", not @compact && "p-4"]}
      phx-hook="TimeseriesChart"
      data-points={Jason.encode!(@data.point_data)}
    >
      <div class="flex items-center justify-between gap-3 mb-2">
        <div class="flex items-center gap-2 min-w-0">
          <span class="inline-block size-2 rounded-full shrink-0" style={"background-color: #{@data.stroke}"} />
          <span class={["font-medium truncate", @compact && "text-xs", not @compact && "text-sm"]}>{@data.series}</span>
        </div>
        <div class={["text-base-content/60 font-mono shrink-0", @compact && "text-[10px]", not @compact && "text-xs"]}>
          <span style={"color: #{@data.stroke}"}>{format_value(@data.paths.latest)}</span>
        </div>
      </div>

      <div class="relative">
        <svg
          viewBox={"0 0 #{@chart_width} #{@chart_height}"}
          class={["w-full", @compact && "h-24", not @compact && "h-32"]}
          preserveAspectRatio="none"
        >
          <defs>
            <linearGradient id={"series-fill-#{@id}-#{@data.idx}"} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stop-color={@data.stroke} stop-opacity="0.3" />
              <stop offset="100%" stop-color={@data.stroke} stop-opacity="0.05" />
            </linearGradient>
          </defs>

          <path d={@data.paths.area} fill={"url(#series-fill-#{@id}-#{@data.idx})"} />
          <polyline
            fill="none"
            stroke={@data.stroke}
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
            points={@data.paths.line}
          />
        </svg>

        <!-- Hover tooltip - populated by JS -->
        <div
          class="absolute hidden pointer-events-none bg-base-300 text-base-content text-xs px-2 py-1 rounded shadow-lg z-10 font-mono whitespace-nowrap"
          data-tooltip
        >
        </div>
        <!-- Hover line -->
        <div
          class="absolute hidden pointer-events-none w-px bg-base-content/30 top-0 bottom-0"
          data-hover-line
        >
        </div>
      </div>

      <div class={["flex items-center justify-between text-base-content/50 mt-1", @compact && "text-[10px]", not @compact && "text-xs"]}>
        <span>min: <span class="font-mono">{format_value(@data.paths.min)}</span></span>
        <span>max: <span class="font-mono">{format_value(@data.paths.max)}</span></span>
      </div>
    </div>
    """
  end

  defp first_dt(series_points) when is_list(series_points) do
    series_points
    |> Enum.find_value(fn {_series, points} ->
      case points do
        [{%DateTime{} = dt, _} | _] -> dt
        _ -> nil
      end
    end)
  end

  defp first_dt(_), do: nil

  defp last_dt(series_points) when is_list(series_points) do
    series_points
    |> Enum.find_value(fn {_series, points} ->
      case List.last(points) do
        {%DateTime{} = dt, _} -> dt
        _ -> nil
      end
    end)
  end

  defp last_dt(_), do: nil
end
