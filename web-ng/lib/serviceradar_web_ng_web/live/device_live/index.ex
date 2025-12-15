defmodule ServiceRadarWebNGWeb.DeviceLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_limit 20
  @max_limit 100
  @sparkline_device_cap 200
  @sparkline_points_per_device 20
  @sparkline_bucket "5m"
  @sparkline_window "last_1h"
  @sparkline_threshold_ms 100.0

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Devices")
     |> assign(:devices, [])
     |> assign(:icmp_sparklines, %{})
     |> assign(:icmp_error, nil)
     |> assign(:limit, @default_limit)
     |> SRQLPage.init("devices", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    socket =
      socket
      |> SRQLPage.load_list(params, uri, :devices,
        default_limit: @default_limit,
        max_limit: @max_limit
      )

    {icmp_sparklines, icmp_error} = load_icmp_sparklines(srql_module(), socket.assigns.devices)

    {:noreply, assign(socket, icmp_sparklines: icmp_sparklines, icmp_error: icmp_error)}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: "/devices")}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "devices")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_run", %{}, fallback_path: "/devices")}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "devices")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "devices")}
  end

  @impl true
  def render(assigns) do
    pagination = get_in(assigns, [:srql, :pagination]) || %{}
    assigns = assign(assigns, :pagination, pagination)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <.header>
          Devices
          <:subtitle>Network device inventory.</:subtitle>
          <:actions>
            <.link class="btn btn-ghost btn-sm" patch={~p"/devices"}>
              Reset
            </.link>
          </:actions>
        </.header>

        <.ui_panel>
          <:header>
            <div class="flex items-center gap-2">
              <span class="text-sm text-base-content/70">Click a device row to view details</span>
              <div :if={is_binary(@icmp_error)} class="badge badge-warning badge-sm">
                ICMP: {@icmp_error}
              </div>
            </div>
          </:header>

          <div class="overflow-x-auto">
            <table class="table table-sm table-zebra w-full">
              <thead>
                <tr>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Device</th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Hostname</th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">IP</th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Health</th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Poller</th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Last Seen</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@devices == []}>
                  <td colspan="6" class="py-8 text-center text-sm text-base-content/60">
                    No devices found.
                  </td>
                </tr>

                <%= for row <- Enum.filter(@devices, &is_map/1) do %>
                  <% device_id = Map.get(row, "device_id") || Map.get(row, "id") %>
                  <% icmp =
                    if is_binary(device_id), do: Map.get(@icmp_sparklines, device_id), else: nil %>
                  <tr class="hover:bg-base-200/40">
                    <td class="font-mono text-xs">
                      <.link
                        :if={is_binary(device_id)}
                        navigate={~p"/devices/#{device_id}"}
                        class="link link-hover"
                      >
                        {device_id}
                      </.link>
                      <span :if={not is_binary(device_id)} class="text-base-content/70">—</span>
                    </td>
                    <td class="text-sm max-w-[18rem] truncate">{Map.get(row, "hostname") || "—"}</td>
                    <td class="font-mono text-xs">{Map.get(row, "ip") || "—"}</td>
                    <td class="text-xs">
                      <div class="flex items-center gap-2">
                        <.availability_badge available={Map.get(row, "is_available")} />
                        <.icmp_sparkline :if={is_map(icmp)} spark={icmp} />
                      </div>
                    </td>
                    <td class="font-mono text-xs">{Map.get(row, "poller_id") || "—"}</td>
                    <td class="font-mono text-xs">
                      <.srql_cell col="last_seen" value={Map.get(row, "last_seen")} />
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>

          <div class="mt-4 pt-4 border-t border-base-200">
            <.ui_pagination
              prev_cursor={Map.get(@pagination, "prev_cursor")}
              next_cursor={Map.get(@pagination, "next_cursor")}
              base_path="/devices"
              query={Map.get(@srql, :query, "")}
              limit={@limit}
              result_count={length(@devices)}
            />
          </div>
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end

  attr :available, :any, default: nil

  def availability_badge(assigns) do
    {label, variant} =
      case assigns.available do
        true -> {"Online", "success"}
        false -> {"Offline", "error"}
        _ -> {"Unknown", "ghost"}
      end

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  attr :spark, :map, required: true

  def icmp_sparkline(assigns) do
    points = Map.get(assigns.spark, :points, [])
    {stroke_path, area_path} = sparkline_smooth_paths(points)

    assigns =
      assigns
      |> assign(:points, points)
      |> assign(:latest_ms, Map.get(assigns.spark, :latest_ms, 0.0))
      |> assign(:tone, Map.get(assigns.spark, :tone, "success"))
      |> assign(:title, Map.get(assigns.spark, :title))
      |> assign(:stroke_path, stroke_path)
      |> assign(:area_path, area_path)
      |> assign(:stroke_color, tone_stroke(Map.get(assigns.spark, :tone, "success")))
      |> assign(:spark_id, "spark-#{:erlang.phash2(Map.get(assigns.spark, :title, ""))}")

    ~H"""
    <div class="flex items-center gap-2">
      <div class="h-8 w-20 rounded-md border border-base-200 bg-base-100/60 px-1 py-0.5 overflow-hidden">
        <svg viewBox="0 0 400 120" class="w-full h-full" preserveAspectRatio="none">
          <title>{@title || "ICMP latency"}</title>
          <defs>
            <linearGradient id={@spark_id} x1="0" y1="0" x2="0" y2="1">
              <stop offset="5%" stop-color={@stroke_color} stop-opacity="0.5" />
              <stop offset="95%" stop-color={@stroke_color} stop-opacity="0.05" />
            </linearGradient>
          </defs>
          <path d={@area_path} fill={"url(##{@spark_id})"} />
          <path
            d={@stroke_path}
            fill="none"
            stroke={@stroke_color}
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        </svg>
      </div>
      <div class="tabular-nums text-[11px] font-medium text-base-content">
        {format_ms(@latest_ms)}
      </div>
    </div>
    """
  end

  defp tone_stroke("error"), do: "#ff5555"
  defp tone_stroke("warning"), do: "#ffb86c"
  defp tone_stroke("success"), do: "#50fa7b"
  defp tone_stroke(_), do: "#6272a4"

  defp tone_text("error"), do: "text-error"
  defp tone_text("warning"), do: "text-warning"
  defp tone_text("success"), do: "text-success"
  defp tone_text(_), do: "text-base-content/70"

  defp format_ms(value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 1) <> "ms"
  end

  defp format_ms(value) when is_integer(value), do: Integer.to_string(value) <> "ms"
  defp format_ms(_), do: "—"

  # Generate smooth SVG paths using monotone cubic interpolation (Catmull-Rom spline)
  defp sparkline_smooth_paths(values) when is_list(values) do
    values = Enum.filter(values, &is_number/1)

    case {values, Enum.min(values, fn -> 0 end), Enum.max(values, fn -> 0 end)} do
      {[], _, _} ->
        {"", ""}

      {[_single], _, _} ->
        # Single point - just draw a small line
        {"M 200,60 L 200,60", ""}

      {_values, min_v, max_v} ->
        # Normalize values to coordinates
        range = if max_v == min_v, do: 1.0, else: max_v - min_v
        len = length(values)

        coords =
          Enum.with_index(values)
          |> Enum.map(fn {v, idx} ->
            x = idx_to_x(idx, len)
            y = 110.0 - (v - min_v) / range * 100.0
            {x * 1.0, y}
          end)

        stroke_path = monotone_curve_path(coords)
        area_path = monotone_area_path(coords)
        {stroke_path, area_path}
    end
  end

  defp sparkline_smooth_paths(_), do: {"", ""}

  # Monotone cubic interpolation for smooth curves that don't overshoot
  defp monotone_curve_path([]), do: ""
  defp monotone_curve_path([{x, y}]), do: "M #{fmt(x)},#{fmt(y)}"

  defp monotone_curve_path(coords) do
    [{x0, y0} | _rest] = coords
    tangents = compute_tangents(coords)

    # Start with first point
    segments = ["M #{fmt(x0)},#{fmt(y0)}"]

    # Build cubic bezier segments
    curve_segments =
      Enum.zip([coords, tl(coords), tangents, tl(tangents)])
      |> Enum.map(fn {{x0, y0}, {x1, y1}, t0, t1} ->
        dx = (x1 - x0) / 3.0
        cp1x = x0 + dx
        cp1y = y0 + t0 * dx
        cp2x = x1 - dx
        cp2y = y1 - t1 * dx
        "C #{fmt(cp1x)},#{fmt(cp1y)} #{fmt(cp2x)},#{fmt(cp2y)} #{fmt(x1)},#{fmt(y1)}"
      end)

    Enum.join(segments ++ curve_segments, " ")
  end

  defp monotone_area_path([]), do: ""
  defp monotone_area_path([_]), do: ""

  defp monotone_area_path(coords) do
    [{first_x, _} | _] = coords
    {last_x, _} = List.last(coords)
    baseline = 115.0

    stroke = monotone_curve_path(coords)
    "#{stroke} L #{fmt(last_x)},#{fmt(baseline)} L #{fmt(first_x)},#{fmt(baseline)} Z"
  end

  # Compute tangents for monotone interpolation
  defp compute_tangents(coords) when length(coords) < 2, do: []

  defp compute_tangents(coords) do
    # Compute slopes between consecutive points
    slopes =
      Enum.zip(coords, tl(coords))
      |> Enum.map(fn {{x0, y0}, {x1, y1}} ->
        dx = x1 - x0
        if dx == 0, do: 0.0, else: (y1 - y0) / dx
      end)

    # Compute tangents using monotone method
    n = length(coords)

    Enum.map(0..(n - 1), fn i ->
      cond do
        i == 0 ->
          # First point - use first slope
          Enum.at(slopes, 0) || 0.0

        i == n - 1 ->
          # Last point - use last slope
          List.last(slopes) || 0.0

        true ->
          # Interior points - average of adjacent slopes, clamped for monotonicity
          s0 = Enum.at(slopes, i - 1) || 0.0
          s1 = Enum.at(slopes, i) || 0.0

          if s0 * s1 <= 0 do
            # Different signs - use 0 to avoid overshooting
            0.0
          else
            # Same sign - use harmonic mean for smoothness
            2.0 * s0 * s1 / (s0 + s1)
          end
      end
    end)
  end

  defp fmt(num) when is_float(num), do: :erlang.float_to_binary(num, decimals: 1)
  defp fmt(num) when is_integer(num), do: Integer.to_string(num)

  defp idx_to_x(_idx, 0), do: 0
  defp idx_to_x(0, _len), do: 0

  defp idx_to_x(idx, len) when len > 1 do
    round(idx / (len - 1) * 400)
  end

  defp load_icmp_sparklines(srql_module, devices) do
    device_ids =
      devices
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn row -> Map.get(row, "device_id") || Map.get(row, "id") end)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.take(@sparkline_device_cap)

    if device_ids == [] do
      {%{}, nil}
    else
      query =
        [
          "in:timeseries_metrics",
          "metric_type:icmp",
          "device_id:(#{Enum.map_join(device_ids, ",", &escape_list_value/1)})",
          "time:#{@sparkline_window}",
          "bucket:#{@sparkline_bucket}",
          "agg:avg",
          "series:device_id",
          "limit:#{min(length(device_ids) * @sparkline_points_per_device, 4000)}"
        ]
        |> Enum.join(" ")

      case srql_module.query(query) do
        {:ok, %{"results" => rows}} when is_list(rows) ->
          {build_icmp_sparklines(rows), nil}

        {:ok, other} ->
          {%{}, "unexpected SRQL response: #{inspect(other)}"}

        {:error, reason} ->
          {%{}, format_error(reason)}
      end
    end
  end

  defp escape_list_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> then(&"\"#{&1}\"")
  end

  defp build_icmp_sparklines(rows) when is_list(rows) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, fn row, acc ->
      device_id = Map.get(row, "series") || Map.get(row, "device_id")
      timestamp = Map.get(row, "timestamp")
      value_ms = latency_ms(Map.get(row, "value"))

      if is_binary(device_id) and value_ms > 0 do
        Map.update(
          acc,
          device_id,
          [%{ts: timestamp, v: value_ms}],
          fn existing -> existing ++ [%{ts: timestamp, v: value_ms}] end
        )
      else
        acc
      end
    end)
    |> Map.new(fn {device_id, points} ->
      points =
        points
        |> Enum.sort_by(fn p -> p.ts end)
        |> Enum.take(-@sparkline_points_per_device)

      values = Enum.map(points, & &1.v)
      latest_ms = List.last(values) || 0.0

      tone =
        cond do
          latest_ms >= @sparkline_threshold_ms -> "warning"
          latest_ms > 0 -> "success"
          true -> "ghost"
        end

      title =
        case List.last(points) do
          %{ts: ts} when is_binary(ts) -> "ICMP #{format_ms(latest_ms)} · #{ts}"
          _ -> "ICMP #{format_ms(latest_ms)}"
        end

      {device_id, %{points: values, latest_ms: latest_ms, tone: tone, title: title}}
    end)
  end

  defp build_icmp_sparklines(_), do: %{}

  defp latency_ms(value) when is_float(value) or is_integer(value) do
    raw = if is_integer(value), do: value * 1.0, else: value
    if raw > 1_000_000.0, do: raw / 1_000_000.0, else: raw
  end

  defp latency_ms(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> latency_ms(parsed)
      _ -> 0.0
    end
  end

  defp latency_ms(_), do: 0.0

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
