defmodule ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries do
  @moduledoc false

  use Phoenix.LiveComponent

  @behaviour ServiceRadarWebNGWeb.Dashboard.Plugin

  import ServiceRadarWebNGWeb.UIComponents, only: [ui_panel: 1]

  @max_series 6
  @max_points 200
  @chart_width 600
  @chart_height 180
  @chart_pad 14

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
    colors = [
      {"#22c55e", "rgba(34,197,94,0.18)"},
      {"#3b82f6", "rgba(59,130,246,0.18)"},
      {"#f97316", "rgba(249,115,22,0.18)"},
      {"#a855f7", "rgba(168,85,247,0.18)"},
      {"#eab308", "rgba(234,179,8,0.18)"},
      {"#14b8a6", "rgba(20,184,166,0.18)"}
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
    socket =
      socket
      |> assign(Map.drop(assigns, [:panel_assigns]))
      |> assign(panel_assigns || %{})
      |> assign(:chart_width, @chart_width)
      |> assign(:chart_height, @chart_height)
      |> assign(:chart_pad, @chart_pad)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:series_count, length(assigns.series_points || []))
      |> assign(:first_dt, first_dt(assigns.series_points))
      |> assign(:last_dt, last_dt(assigns.series_points))

    ~H"""
    <div id={"panel-#{@id}"}>
      <.ui_panel>
        <:header>
          <div class="min-w-0">
            <div class="text-sm font-semibold">Timeseries</div>
            <div class="text-xs text-base-content/70">
              <span class="font-mono">{@spec[:y]}</span>
              <span class="opacity-70"> over </span>
              <span class="font-mono">{@spec[:x]}</span>
              <span :if={@spec[:series]} class="opacity-70">
                (series: <span class="font-mono">{@spec[:series]}</span>)
              </span>
            </div>
          </div>
        </:header>

        <div class="text-xs text-base-content/60 flex items-center justify-between gap-3 mb-3">
          <div class="flex items-center gap-2">
            <span class="font-semibold">{@series_count}</span>
            <span>series</span>
          </div>
          <div class="font-mono">
            <span :if={is_struct(@first_dt, DateTime)}>{dt_label(@first_dt)}</span>
            <span class="opacity-60 px-1">→</span>
            <span :if={is_struct(@last_dt, DateTime)}>{dt_label(@last_dt)}</span>
          </div>
        </div>

        <div class={[
          "grid gap-4",
          @series_count > 1 && "grid-cols-1 md:grid-cols-2",
          @series_count <= 1 && "grid-cols-1"
        ]}>
          <%= for {{series, points}, idx} <- Enum.with_index(@series_points) do %>
            <% paths = chart_paths(points) %>
            <% {stroke, _fill} = series_color(idx) %>
            <div class="rounded-xl border border-base-200 bg-base-100 p-4">
              <div class="flex items-start justify-between gap-3 mb-2">
                <div class="min-w-0">
                  <div class="text-xs font-semibold truncate">{series}</div>
                  <div class="text-[11px] text-base-content/60">
                    <span class="font-mono">{format_value(paths.latest)}</span>
                    <span class="opacity-60"> latest</span>
                    <span class="opacity-60 px-1">·</span>
                    <span class="font-mono">{format_value(paths.min)}</span>
                    <span class="opacity-60"> min</span>
                    <span class="opacity-60 px-1">·</span>
                    <span class="font-mono">{format_value(paths.max)}</span>
                    <span class="opacity-60"> max</span>
                  </div>
                </div>

                <div class="shrink-0 flex items-center gap-2">
                  <span
                    class="inline-block size-2 rounded-full"
                    style={"background-color: #{stroke}"}
                  />
                </div>
              </div>

              <svg viewBox={"0 0 #{@chart_width} #{@chart_height}"} class="w-full h-40">
                <defs>
                  <linearGradient id={"series-fill-#{@id}-#{idx}"} x1="0" y1="0" x2="0" y2="1">
                    <stop offset="0%" stop-color={stroke} stop-opacity="0.22" />
                    <stop offset="100%" stop-color={stroke} stop-opacity="0.04" />
                  </linearGradient>
                </defs>

                <line
                  x1={@chart_pad}
                  y1={baseline_y()}
                  x2={@chart_width - @chart_pad}
                  y2={baseline_y()}
                  stroke="currentColor"
                  stroke-opacity="0.12"
                  stroke-width="1"
                />

                <path d={paths.area} fill={"url(#series-fill-#{@id}-#{idx})"} />
                <polyline
                  fill="none"
                  stroke={stroke}
                  stroke-width="2.25"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  points={paths.line}
                />
              </svg>
            </div>
          <% end %>
        </div>
      </.ui_panel>
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
