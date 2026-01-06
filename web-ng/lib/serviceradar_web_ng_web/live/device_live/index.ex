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
  @presence_window "last_24h"
  @presence_bucket "24h"
  @presence_device_cap 200

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Devices")
     |> assign(:devices, [])
     |> assign(:icmp_sparklines, %{})
     |> assign(:icmp_error, nil)
     |> assign(:snmp_presence, %{})
     |> assign(:sysmon_presence, %{})
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

    actor = Map.get(socket.assigns, :actor)

    {icmp_sparklines, icmp_error} =
      load_icmp_sparklines(srql_module(), socket.assigns.devices, actor)

    {snmp_presence, sysmon_presence} =
      load_metric_presence(srql_module(), socket.assigns.devices, actor)

    {:noreply,
     assign(socket,
       icmp_sparklines: icmp_sparklines,
       icmp_error: icmp_error,
       snmp_presence: snmp_presence,
       sysmon_presence: sysmon_presence
     )}
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
        <.ui_panel>
          <:header>
            <div :if={is_binary(@icmp_error)} class="badge badge-warning badge-sm">
              ICMP: {@icmp_error}
            </div>
          </:header>

          <div class="overflow-x-auto">
            <table class="table table-sm table-zebra w-full">
              <thead>
                <tr>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">UID</th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Hostname</th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">IP</th>
                  <th
                    class="text-xs font-semibold text-base-content/70 bg-base-200/60"
                    title="OCSF Device Type"
                  >
                    Type
                  </th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Vendor</th>
                  <th
                    class="text-xs font-semibold text-base-content/70 bg-base-200/60"
                    title="GRPC Health Check Status"
                  >
                    Status
                  </th>
                  <th
                    class="text-xs font-semibold text-base-content/70 bg-base-200/60"
                    title="ICMP Network Tests"
                  >
                    Network
                  </th>
                  <th
                    class="text-xs font-semibold text-base-content/70 bg-base-200/60"
                    title="Telemetry availability for this device"
                  >
                    Metrics
                  </th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Risk</th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Poller</th>
                  <th class="text-xs font-semibold text-base-content/70 bg-base-200/60">Last Seen</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@devices == []}>
                  <td colspan="11" class="py-8 text-center text-sm text-base-content/60">
                    No devices found.
                  </td>
                </tr>

                <%= for row <- Enum.filter(@devices, &is_map/1) do %>
                  <% device_uid = Map.get(row, "uid") || Map.get(row, "id") %>
                  <% icmp =
                    if is_binary(device_uid), do: Map.get(@icmp_sparklines, device_uid), else: nil %>
                  <% has_snmp =
                    is_binary(device_uid) and Map.get(@snmp_presence, device_uid, false) == true %>
                  <% has_sysmon =
                    is_binary(device_uid) and Map.get(@sysmon_presence, device_uid, false) == true %>
                  <tr class="hover:bg-base-200/40">
                    <td class="font-mono text-xs">
                      <.link
                        :if={is_binary(device_uid)}
                        navigate={~p"/devices/#{device_uid}"}
                        class="link link-hover"
                      >
                        {device_uid}
                      </.link>
                      <span :if={not is_binary(device_uid)} class="text-base-content/70">—</span>
                    </td>
                    <td class="text-sm max-w-[18rem] truncate">{Map.get(row, "hostname") || "—"}</td>
                    <td class="font-mono text-xs">{Map.get(row, "ip") || "—"}</td>
                    <td class="text-xs">
                      <.device_type_badge
                        type={Map.get(row, "type")}
                        type_id={Map.get(row, "type_id")}
                      />
                    </td>
                    <td class="text-xs max-w-[8rem] truncate">
                      {Map.get(row, "vendor_name") || "—"}
                    </td>
                    <td class="text-xs">
                      <.availability_badge available={Map.get(row, "is_available")} />
                    </td>
                    <td class="text-xs">
                      <.icmp_sparkline :if={is_map(icmp)} spark={icmp} />
                      <span :if={not is_map(icmp)} class="text-base-content/40">—</span>
                    </td>
                    <td class="text-xs">
                      <.metrics_presence
                        device_uid={device_uid}
                        has_snmp={has_snmp}
                        has_sysmon={has_sysmon}
                      />
                    </td>
                    <td class="text-xs">
                      <.risk_level_badge risk_level={Map.get(row, "risk_level")} />
                    </td>
                    <td class="font-mono text-xs">{Map.get(row, "gateway_id") || "—"}</td>
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

  attr :type, :string, default: nil
  attr :type_id, :integer, default: nil

  def device_type_badge(assigns) do
    label = device_type_label(assigns.type, assigns.type_id)
    icon = device_type_icon(assigns.type_id)

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:icon, icon)

    ~H"""
    <div class="flex items-center gap-1" title={"Type ID: #{@type_id}"}>
      <.icon :if={@icon} name={@icon} class="size-3.5 text-base-content/60" />
      <span class="text-base-content/80">{@label}</span>
    </div>
    """
  end

  defp device_type_label(type, _type_id) when is_binary(type) and type != "", do: type
  defp device_type_label(_type, 0), do: "Unknown"
  defp device_type_label(_type, 1), do: "Server"
  defp device_type_label(_type, 2), do: "Desktop"
  defp device_type_label(_type, 3), do: "Laptop"
  defp device_type_label(_type, 4), do: "Tablet"
  defp device_type_label(_type, 5), do: "Mobile"
  defp device_type_label(_type, 6), do: "Virtual"
  defp device_type_label(_type, 7), do: "IOT"
  defp device_type_label(_type, 8), do: "Browser"
  defp device_type_label(_type, 9), do: "Firewall"
  defp device_type_label(_type, 10), do: "Switch"
  defp device_type_label(_type, 11), do: "Hub"
  defp device_type_label(_type, 12), do: "Router"
  defp device_type_label(_type, 13), do: "IDS"
  defp device_type_label(_type, 14), do: "IPS"
  defp device_type_label(_type, 15), do: "Load Balancer"
  defp device_type_label(_type, 99), do: "Other"
  defp device_type_label(_type, _type_id), do: "—"

  defp device_type_icon(1), do: "hero-server"
  defp device_type_icon(2), do: "hero-computer-desktop"
  defp device_type_icon(3), do: "hero-computer-desktop"
  defp device_type_icon(4), do: "hero-device-tablet"
  defp device_type_icon(5), do: "hero-device-phone-mobile"
  defp device_type_icon(6), do: "hero-cube"
  defp device_type_icon(7), do: "hero-cpu-chip"
  defp device_type_icon(9), do: "hero-shield-check"
  defp device_type_icon(10), do: "hero-square-3-stack-3d"
  defp device_type_icon(12), do: "hero-arrows-right-left"
  defp device_type_icon(15), do: "hero-scale"
  defp device_type_icon(_), do: nil

  attr :risk_level, :string, default: nil

  def risk_level_badge(assigns) do
    {label, variant} = risk_level_style(assigns.risk_level)

    assigns =
      assigns
      |> assign(:label, label)
      |> assign(:variant, variant)

    ~H"""
    <.ui_badge :if={@label != "—"} variant={@variant} size="xs">{@label}</.ui_badge>
    <span :if={@label == "—"} class="text-base-content/40">—</span>
    """
  end

  defp risk_level_style("Critical"), do: {"Critical", "error"}
  defp risk_level_style("High"), do: {"High", "warning"}
  defp risk_level_style("Medium"), do: {"Medium", "info"}
  defp risk_level_style("Low"), do: {"Low", "success"}
  defp risk_level_style("Info"), do: {"Info", "ghost"}
  defp risk_level_style(_), do: {"—", "ghost"}

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
      <div class="h-8 w-20 rounded-md bg-base-200/30 px-1 py-0.5 overflow-hidden">
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
      <div class="tabular-nums text-[11px] font-bold text-base-content">
        {format_ms(@latest_ms)}
      </div>
    </div>
    """
  end

  attr :device_uid, :string, default: nil
  attr :has_snmp, :boolean, default: false
  attr :has_sysmon, :boolean, default: false

  def metrics_presence(assigns) do
    device_path =
      if is_binary(assigns.device_uid) and String.trim(assigns.device_uid) != "" do
        ~p"/devices/#{assigns.device_uid}"
      else
        nil
      end

    assigns = assign(assigns, :device_path, device_path)

    ~H"""
    <div :if={@has_snmp or @has_sysmon} class="flex items-center gap-2">
      <.link
        :if={@has_snmp and is_binary(@device_path)}
        navigate={@device_path}
        class="tooltip inline-flex hover:opacity-90"
        data-tip="SNMP metrics available (last 24h)"
        aria-label="View device details (SNMP metrics available)"
      >
        <.icon name="hero-signal" class="size-4 text-info" />
      </.link>
      <span
        :if={@has_snmp and not is_binary(@device_path)}
        class="tooltip"
        data-tip="SNMP metrics available (last 24h)"
      >
        <.icon name="hero-signal" class="size-4 text-info" />
      </span>

      <.link
        :if={@has_sysmon and is_binary(@device_path)}
        navigate={@device_path}
        class="tooltip inline-flex hover:opacity-90"
        data-tip="Sysmon metrics available (last 24h)"
        aria-label="View device details (Sysmon metrics available)"
      >
        <.icon name="hero-cpu-chip" class="size-4 text-success" />
      </.link>
      <span
        :if={@has_sysmon and not is_binary(@device_path)}
        class="tooltip"
        data-tip="Sysmon metrics available (last 24h)"
      >
        <.icon name="hero-cpu-chip" class="size-4 text-success" />
      </span>
    </div>
    <span :if={not @has_snmp and not @has_sysmon} class="text-base-content/40">—</span>
    """
  end

  defp tone_stroke("error"), do: "#ff5555"
  defp tone_stroke("warning"), do: "#ffb86c"
  defp tone_stroke("success"), do: "#50fa7b"
  defp tone_stroke(_), do: "#6272a4"

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
      tangent_for_index(i, n, slopes)
    end)
  end

  defp tangent_for_index(0, _n, slopes), do: Enum.at(slopes, 0) || 0.0
  defp tangent_for_index(i, n, slopes) when i == n - 1, do: List.last(slopes) || 0.0

  defp tangent_for_index(i, _n, slopes) do
    s0 = Enum.at(slopes, i - 1) || 0.0
    s1 = Enum.at(slopes, i) || 0.0

    if s0 * s1 <= 0 do
      0.0
    else
      2.0 * s0 * s1 / (s0 + s1)
    end
  end

  defp fmt(num) when is_float(num), do: :erlang.float_to_binary(num, decimals: 1)
  defp fmt(num) when is_integer(num), do: Integer.to_string(num)

  defp idx_to_x(_idx, 0), do: 0
  defp idx_to_x(0, _len), do: 0

  defp idx_to_x(idx, len) when len > 1 do
    round(idx / (len - 1) * 400)
  end

  defp load_icmp_sparklines(srql_module, devices, actor) do
    device_uids =
      devices
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn row -> Map.get(row, "uid") || Map.get(row, "id") end)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.take(@sparkline_device_cap)

    if device_uids == [] do
      {%{}, nil}
    else
      query =
        [
          "in:timeseries_metrics",
          "metric_type:icmp",
          "uid:(#{Enum.map_join(device_uids, ",", &escape_list_value/1)})",
          "time:#{@sparkline_window}",
          "bucket:#{@sparkline_bucket}",
          "agg:avg",
          "series:uid",
          "limit:#{min(length(device_uids) * @sparkline_points_per_device, 4000)}"
        ]
        |> Enum.join(" ")

      case srql_module.query(query, %{actor: actor}) do
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

  defp load_metric_presence(srql_module, devices, actor) do
    device_uids =
      devices
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn row -> Map.get(row, "uid") || Map.get(row, "id") end)
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.take(@presence_device_cap)

    if device_uids == [] do
      {%{}, %{}}
    else
      list = Enum.map_join(device_uids, ",", &escape_list_value/1)
      limit = min(length(device_uids) * 3, 2000)

      snmp_query =
        [
          "in:snmp_metrics",
          "uid:(#{list})",
          "time:#{@presence_window}",
          "bucket:#{@presence_bucket}",
          "agg:count",
          "series:uid",
          "limit:#{limit}"
        ]
        |> Enum.join(" ")

      sysmon_query =
        [
          "in:cpu_metrics",
          "uid:(#{list})",
          "time:#{@presence_window}",
          "bucket:#{@presence_bucket}",
          "agg:count",
          "series:uid",
          "limit:#{limit}"
        ]
        |> Enum.join(" ")

      {snmp_presence, sysmon_presence} =
        [snmp: snmp_query, sysmon: sysmon_query]
        |> Task.async_stream(
          fn {key, query} -> {key, srql_module.query(query, %{actor: actor})} end,
          ordered: false,
          timeout: 30_000
        )
        |> Enum.reduce({%{}, %{}}, fn
          {:ok, {:snmp, {:ok, %{"results" => rows}}}}, {_snmp, sysmon} ->
            {presence_from_downsample(rows), sysmon}

          {:ok, {:sysmon, {:ok, %{"results" => rows}}}}, {snmp, _sysmon} ->
            {snmp, presence_from_downsample(rows)}

          _, acc ->
            acc
        end)

      {snmp_presence, sysmon_presence}
    end
  end

  defp presence_from_downsample(rows) when is_list(rows) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, fn row, acc ->
      series = Map.get(row, "series")
      value = Map.get(row, "value")

      if is_binary(series) and series != "" and is_number(value) and value > 0 do
        Map.put(acc, series, true)
      else
        acc
      end
    end)
  end

  defp presence_from_downsample(_), do: %{}

  defp build_icmp_sparklines(rows) when is_list(rows) do
    rows
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(%{}, &accumulate_icmp_point/2)
    |> Map.new(fn {device_uid, points} ->
      {device_uid, icmp_sparkline_data(points)}
    end)
  end

  defp build_icmp_sparklines(_), do: %{}

  defp accumulate_icmp_point(row, acc) do
    device_uid = Map.get(row, "series") || Map.get(row, "uid") || Map.get(row, "device_id")
    timestamp = Map.get(row, "timestamp")
    value_ms = latency_ms(Map.get(row, "value"))

    if is_binary(device_uid) and value_ms > 0 do
      Map.update(
        acc,
        device_uid,
        [%{ts: timestamp, v: value_ms}],
        fn existing -> existing ++ [%{ts: timestamp, v: value_ms}] end
      )
    else
      acc
    end
  end

  defp icmp_sparkline_data(points) do
    points =
      points
      |> Enum.sort_by(fn p -> p.ts end)
      |> Enum.take(-@sparkline_points_per_device)

    values = Enum.map(points, & &1.v)
    latest_ms = List.last(values) || 0.0
    tone = icmp_tone(latest_ms)
    title = icmp_title(points, latest_ms)

    %{points: values, latest_ms: latest_ms, tone: tone, title: title}
  end

  defp icmp_tone(latest_ms) do
    cond do
      latest_ms >= @sparkline_threshold_ms -> "warning"
      latest_ms > 0 -> "success"
      true -> "ghost"
    end
  end

  defp icmp_title(points, latest_ms) do
    case List.last(points) do
      %{ts: ts} when is_binary(ts) -> "ICMP #{format_ms(latest_ms)} · #{ts}"
      _ -> "ICMP #{format_ms(latest_ms)}"
    end
  end

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
