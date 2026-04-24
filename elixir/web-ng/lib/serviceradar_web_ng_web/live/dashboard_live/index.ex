defmodule ServiceRadarWebNGWeb.DashboardLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.CameraMultiview
  alias ServiceRadarWebNGWeb.CameraRelayComponents
  alias ServiceRadarWebNGWeb.DashboardLive.Data

  @camera_preview_limit 4
  @camera_relay_poll_interval_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Unified Operations Dashboard")
      |> assign(:current_path, "/dashboard")
      |> assign(:camera_preview_tiles, [])
      |> assign_dashboard(Data.empty())

    socket =
      if connected?(socket) do
        socket
        |> assign_dashboard(Data.load(socket.assigns.current_scope))
        |> maybe_start_camera_previews()
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      shell={:operations}
      hide_breadcrumb
    >
      <div
        class="sr-ops-dashboard"
        data-testid="operations-dashboard"
        data-dashboard-modules={Enum.join(@dashboard_modules, " ")}
      >
        <section class="sr-ops-kpi-grid" aria-label="Operational summary">
          <.kpi_card :for={card <- @kpi_cards} card={card} />
        </section>

        <section class="sr-ops-grid-primary">
          <.panel title={map_panel_title(@map_view)} class="lg:col-span-7">
            <:actions>
              <.link href={~p"/topology"} class="sr-ops-button">Open Topology</.link>
            </:actions>

            <div class="sr-ops-map-shell">
              <svg
                class="sr-ops-world-map"
                viewBox="-180 -90 360 180"
                preserveAspectRatio="xMidYMid meet"
                aria-hidden="true"
              >
                <g>
                  <path d="M-168 -51 L-138 -58 L-104 -50 L-82 -28 L-93 -8 L-124 3 L-152 -14 Z" />
                  <path d="M-116 5 L-78 8 L-63 28 L-72 59 L-91 72 L-105 43 Z" />
                  <path d="M-26 -36 L18 -39 L49 -25 L41 -4 L11 3 L-7 19 L-31 9 L-42 -17 Z" />
                  <path d="M14 2 L36 12 L48 40 L38 72 L16 61 L7 32 Z" />
                  <path d="M45 -42 L94 -48 L139 -36 L163 -13 L141 8 L94 12 L67 -2 L39 -14 Z" />
                  <path d="M96 16 L128 10 L155 25 L151 47 L119 43 L101 31 Z" />
                  <path d="M-52 61 L-35 58 L-19 64 L-28 75 L-50 73 Z" />
                </g>
              </svg>

              <div class="sr-ops-map-controls">
                <form id="traffic-map-view-form" phx-change="select_map_view">
                  <select
                    id="traffic-map-view-select"
                    name="map_view"
                    class="sr-ops-select"
                    aria-label="Traffic map view"
                    phx-hook="DashboardMapViewSelect"
                    phx-change="select_map_view"
                  >
                    <option value="topology_traffic" selected={@map_view == "topology_traffic"}>
                      Topology + Traffic
                    </option>
                    <option value="netflow" selected={@map_view == "netflow"}>NetFlow Map</option>
                  </select>
                </form>
                <ul class="sr-ops-map-legend">
                  <li><span class="bg-sky-400"></span>Core</li>
                  <li><span class="bg-teal-400"></span>Distribution</li>
                  <li><span class="bg-emerald-400"></span>Access</li>
                  <li><span class="bg-violet-400"></span>Wireless AP</li>
                  <li><span class="bg-amber-400"></span>Camera</li>
                  <li><span class="border border-slate-300"></span>Site</li>
                </ul>
              </div>

              <canvas
                id="ops-traffic-map"
                phx-hook="OperationsTrafficMap"
                class="sr-ops-traffic-canvas"
                data-map-view={@map_view}
                data-topology-links={@topology_links_json}
                data-links={@traffic_links_json}
                data-mtr-overlays={@mtr_overlays_json}
                aria-label="Network traffic map"
              />

              <div
                :if={map_empty?(@map_view, @topology_links, @traffic_links)}
                class="sr-ops-map-empty"
                data-testid="traffic-map-empty"
              >
                <p>{map_empty_title(@map_view, @module_states.netflow)}</p>
                <span>{map_empty_detail(@map_view, @module_states.netflow)}</span>
              </div>
            </div>

            <div class="sr-ops-map-stats">
              <.small_stat :for={stat <- @map_stats} label={stat.label} value={stat.value} />
            </div>
          </.panel>

          <.panel title="Events Over Time" class="lg:col-span-5">
            <:actions>
              <span class="sr-ops-select">{@time_window_label}</span>
            </:actions>
            <div
              :if={@security_trend == []}
              class="sr-ops-empty-chart"
              data-testid="security-events-empty"
            >
              <.icon name="hero-chart-bar" class="size-8 text-slate-500" />
              <p>No event trend data</p>
              <span>OCSF events will populate this chart when recent records exist.</span>
            </div>
            <.link
              :if={@security_trend != []}
              href={~p"/events"}
              class="sr-ops-security-chart sr-ops-clickable-panel"
              data-testid="security-events-chart"
              aria-label="Open event details"
            >
              <svg
                class="sr-ops-events-area-chart"
                viewBox="0 0 640 220"
                preserveAspectRatio="none"
                role="img"
                aria-label="Events over time"
              >
                <g class="sr-ops-events-grid">
                  <line :for={y <- [42, 82, 122, 162]} x1="36" x2="616" y1={y} y2={y} />
                </g>
                <path
                  class="sr-ops-events-area-low"
                  d={event_area_path(@security_trend, @security_trend_max, :low)}
                />
                <path
                  class="sr-ops-events-area-medium"
                  d={event_area_path(@security_trend, @security_trend_max, :medium)}
                />
                <path
                  class="sr-ops-events-area-high"
                  d={event_area_path(@security_trend, @security_trend_max, :high)}
                />
                <path
                  class="sr-ops-events-area-critical"
                  d={event_area_path(@security_trend, @security_trend_max, :critical)}
                />
                <polyline
                  class="sr-ops-events-line"
                  points={event_line_points(@security_trend, @security_trend_max)}
                />
                <g class="sr-ops-events-axis">
                  <text :for={label <- event_axis_labels(@security_trend)} x={label.x} y="204">
                    {label.text}
                  </text>
                </g>
              </svg>
              <div class="sr-ops-events-legend">
                <span><i class="sr-ops-events-dot critical"></i>Critical</span>
                <span><i class="sr-ops-events-dot high"></i>High</span>
                <span><i class="sr-ops-events-dot medium"></i>Medium</span>
                <span><i class="sr-ops-events-dot low"></i>Low</span>
              </div>
            </.link>
          </.panel>
        </section>

        <section class="sr-ops-grid-secondary">
          <.panel title="FieldSurvey Heatmap" class="lg:col-span-6">
            <:actions>
              <.link href={~p"/spatial"} class="sr-ops-button">Open FieldSurvey</.link>
            </:actions>
            <div class="sr-ops-heatmap-placeholder" data-testid="fieldsurvey-empty">
              <div class="sr-ops-floor-grid">
                <span :for={_ <- 1..18}></span>
              </div>
              <div :if={@survey_summary.sample_count == 0} class="sr-ops-heatmap-empty">
                <.icon name="hero-wifi" class="size-8" />
                <p>No FieldSurvey heatmap data</p>
                <span>Survey overlays will render here when floorplan samples exist.</span>
              </div>
              <div
                :if={@survey_summary.sample_count > 0}
                class="sr-ops-heatmap-empty sr-ops-heatmap-summary"
                data-testid="fieldsurvey-summary"
              >
                <.icon name="hero-wifi" class="size-8" />
                <p>{@survey_summary.session_count} survey sessions</p>
                <span>
                  {@survey_summary.sample_count} samples, {@survey_summary.avg_rssi} dBm average RSSI
                </span>
              </div>
            </div>
          </.panel>

          <.panel title="Camera Operations" class="lg:col-span-6">
            <:actions>
              <.link href={~p"/cameras"} class="sr-ops-button">
                View All Cameras
              </.link>
            </:actions>
            <div class="sr-ops-camera-empty" data-testid="camera-operations-empty">
              <div class="sr-ops-camera-stats">
                <.small_stat
                  label="Online"
                  value={to_string(@camera_summary.online)}
                  icon="hero-video-camera"
                />
                <.small_stat
                  label="Offline"
                  value={to_string(@camera_summary.offline)}
                  icon="hero-video-camera-slash"
                />
                <.small_stat
                  label="Recording"
                  value={to_string(@camera_summary.recording)}
                  icon="hero-camera"
                />
                <.small_stat label="Total Cameras" value={to_string(@camera_summary.total)} />
              </div>
              <div class="sr-ops-camera-grid">
                <.link
                  :for={tile <- @camera_preview_tiles}
                  href={~p"/cameras/#{tile.camera_source_id}"}
                  class="sr-ops-camera-tile sr-ops-camera-tile-live"
                  aria-label={"Open #{tile.label}"}
                >
                  <div class="sr-ops-camera-tile-header">
                    <span>{tile.label}</span>
                    <small>{tile.detail}</small>
                  </div>
                  <CameraRelayComponents.relay_player
                    :if={tile.session}
                    session={tile.session}
                    id_prefix="dashboard-camera-relay"
                  />
                  <div :if={!tile.session} class="sr-ops-camera-tile-error">
                    <.icon name="hero-video-camera-slash" class="size-6" />
                    <span>{tile.error || "Relay unavailable"}</span>
                  </div>
                </.link>
                <.link
                  :for={tile <- camera_tiles(@camera_summary.tiles, @camera_preview_tiles)}
                  href={camera_tile_href(tile)}
                  class="sr-ops-camera-tile"
                  aria-label={"Open #{tile.label}"}
                >
                  <.icon name="hero-video-camera" class="size-7 text-slate-500" />
                  <span>{tile.label}</span>
                  <small>{tile.status}</small>
                </.link>
              </div>
            </div>
          </.panel>
        </section>

        <section class="sr-ops-grid-bottom">
          <.panel title="Observability Metrics" class="lg:col-span-4">
            <div class="sr-ops-metric-grid">
              <div :for={metric <- @observability_metrics} class="sr-ops-metric-card">
                <span>{metric.label}</span>
                <strong>{metric.value}</strong>
                <small>{metric.scale}</small>
                <div class="sr-ops-metric-empty-line"></div>
              </div>
            </div>
          </.panel>

          <.panel title="Top Vulnerable Assets" class="lg:col-span-3">
            <div class="sr-ops-feed-empty" data-testid="vulnerable-assets-empty">
              <.icon name="hero-shield-exclamation" class="size-8 text-amber-400" />
              <p>Vulnerability tracking is not connected</p>
              <span>No fabricated risk counts are displayed.</span>
            </div>
          </.panel>

          <.panel title="Alerts Feed" class="lg:col-span-5">
            <:actions>
              <.link href={~p"/alerts"} class="sr-ops-button">
                View All Alerts
              </.link>
            </:actions>
            <div :if={@alert_feed == []} class="sr-ops-feed-empty" data-testid="alerts-feed-empty">
              <.icon name="hero-bell-alert" class="size-8 text-rose-400" />
              <p>No recent alerts</p>
              <span>Live alerts from the existing alert stream will appear here.</span>
            </div>
            <div :if={@alert_feed != []} class="sr-ops-alert-feed" data-testid="alerts-feed">
              <.link
                :for={alert <- @alert_feed}
                href={~p"/alerts/#{alert.id}"}
                class="sr-ops-alert-row"
              >
                <span class={["sr-ops-alert-severity", alert_severity_class(alert.severity)]}>
                  {alert_severity_label(alert.severity)}
                </span>
                <span class="sr-ops-alert-main">
                  <strong>{alert.title}</strong>
                  <small>{alert_subtitle(alert)}</small>
                </span>
                <span class="sr-ops-alert-meta">
                  <em>{alert_status_label(alert.status)}</em>
                  <small>{alert.observed_label}</small>
                </span>
              </.link>
            </div>
          </.panel>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("select_map_view", %{"map_view" => map_view}, socket) do
    {:noreply, assign(socket, :map_view, normalize_map_view(map_view))}
  end

  def handle_event("select_map_view", %{"value" => map_view}, socket) do
    {:noreply, assign(socket, :map_view, normalize_map_view(map_view))}
  end

  @impl true
  def handle_info({:refresh_dashboard_camera_relay_session, relay_session_id}, socket) do
    tiles =
      Enum.map(socket.assigns.camera_preview_tiles, fn tile ->
        if CameraMultiview.session_id(tile) == relay_session_id do
          refreshed = CameraMultiview.refresh_tile_session(socket.assigns.current_scope, tile)
          schedule_camera_preview_refresh(refreshed)
          refreshed
        else
          tile
        end
      end)

    {:noreply, assign(socket, :camera_preview_tiles, tiles)}
  end

  attr(:card, :map, required: true)

  defp kpi_card(assigns) do
    ~H"""
    <article class={["sr-ops-kpi-card", "tone-#{@card.tone}"]}>
      <div class="sr-ops-kpi-icon">
        <.icon name={@card.icon} class="size-9" />
      </div>
      <div class="min-w-0">
        <p>{@card.title}</p>
        <strong>{@card.value}</strong>
        <span>{@card.detail}</span>
      </div>
      <div class="sr-ops-kpi-sparkline" aria-hidden="true"></div>
    </article>
    """
  end

  attr(:title, :string, required: true)
  attr(:class, :string, default: "")
  slot(:actions)
  slot(:inner_block, required: true)

  defp panel(assigns) do
    ~H"""
    <article class={["sr-ops-panel", @class]}>
      <header class="sr-ops-panel-header">
        <h2>{@title}</h2>
        <div :if={@actions != []} class="flex items-center gap-2">{render_slot(@actions)}</div>
      </header>
      {render_slot(@inner_block)}
    </article>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:icon, :string, default: nil)

  defp small_stat(assigns) do
    ~H"""
    <div class="sr-ops-small-stat">
      <span class="flex items-center gap-2">
        <.icon :if={@icon} name={@icon} class="size-4" />
        {@label}
      </span>
      <strong>{@value}</strong>
    </div>
    """
  end

  defp assign_dashboard(socket, dashboard_assigns) when is_map(dashboard_assigns) do
    Enum.reduce(dashboard_assigns, socket, fn {key, value}, acc ->
      assign(acc, key, value)
    end)
  end

  defp camera_tiles(tiles, preview_tiles) do
    remaining = max(4 - length(preview_tiles), 0)

    tiles
    |> List.wrap()
    |> Enum.take(remaining)
    |> then(fn visible ->
      visible ++ fallback_camera_tiles(length(visible), remaining)
    end)
    |> Enum.take(remaining)
  end

  defp fallback_camera_tiles(_visible_count, 0), do: []

  defp fallback_camera_tiles(visible_count, remaining) do
    for idx <- (visible_count + 1)..remaining//1 do
      %{label: "Camera #{idx}", status: "feed unavailable"}
    end
  end

  defp camera_tile_href(%{id: id}) when is_binary(id) and id != "", do: ~p"/cameras/#{id}"
  defp camera_tile_href(_tile), do: ~p"/cameras"

  defp maybe_start_camera_previews(socket) do
    if RBAC.can?(socket.assigns.current_scope, "devices.view") do
      tiles = CameraMultiview.open_preview_tiles(socket.assigns.current_scope, @camera_preview_limit)
      Enum.each(tiles, &schedule_camera_preview_refresh/1)
      assign(socket, :camera_preview_tiles, tiles)
    else
      socket
    end
  end

  defp schedule_camera_preview_refresh(tile) do
    case CameraMultiview.session_id(tile) do
      session_id when is_binary(session_id) ->
        Process.send_after(
          self(),
          {:refresh_dashboard_camera_relay_session, session_id},
          camera_relay_poll_interval_ms()
        )

      _ ->
        :ok
    end
  end

  defp camera_relay_poll_interval_ms do
    case Application.get_env(:serviceradar_web_ng, :camera_relay_poll_interval_ms, @camera_relay_poll_interval_ms) do
      value when is_integer(value) and value > 0 -> value
      _other -> @camera_relay_poll_interval_ms
    end
  end

  defp normalize_map_view("netflow"), do: "netflow"
  defp normalize_map_view(_), do: "topology_traffic"

  defp map_panel_title("netflow"), do: "NetFlow Map"
  defp map_panel_title(_), do: "Topology & Traffic"

  defp event_area_path(points, max_total, layer), do: event_layer_path(points, max_total, event_layer_index(layer))

  defp event_line_points(points, max_total) do
    points
    |> Enum.with_index()
    |> Enum.map(fn {point, idx} -> event_xy(idx, length(points), point.total, max_total) end)
    |> Enum.map_join(" ", fn {x, y} -> "#{x},#{y}" end)
  end

  defp event_axis_labels(points) do
    count = length(points)
    step = max(div(count, 5), 1)

    points
    |> Enum.with_index()
    |> Enum.filter(fn {_point, idx} -> idx == 0 or idx == count - 1 or rem(idx, step) == 0 end)
    |> Enum.map(fn {point, idx} ->
      {x, _y} = event_xy(idx, count, 0, 1)
      %{x: x, text: point.label}
    end)
  end

  defp event_layer_index(:low), do: 0
  defp event_layer_index(:medium), do: 1
  defp event_layer_index(:high), do: 2
  defp event_layer_index(:critical), do: 3

  defp event_layer_path(points, max_total, layer_index) when points != [] and max_total > 0 do
    count = length(points)

    top =
      points
      |> Enum.with_index()
      |> Enum.map(fn {point, idx} ->
        event_xy(idx, count, event_cumulative(point, layer_index), max_total)
      end)

    bottom =
      points
      |> Enum.with_index()
      |> Enum.map(fn {point, idx} ->
        event_xy(idx, count, event_cumulative(point, layer_index - 1), max_total)
      end)
      |> Enum.reverse()

    [first | rest] = top ++ bottom
    {x, y} = first
    "M #{x} #{y} " <> Enum.map_join(rest, " ", fn {px, py} -> "L #{px} #{py}" end) <> " Z"
  end

  defp event_layer_path(_points, _max_total, _layer_index), do: ""

  defp event_cumulative(point, layer_index) do
    [:low, :medium, :high, :critical]
    |> Enum.take(layer_index + 1)
    |> Enum.map(&Map.get(point, &1, 0))
    |> Enum.sum()
  end

  defp event_xy(idx, count, value, max_total) do
    width = 580
    left = 36
    top = 26
    height = 154
    x = left + round(width * idx / max(count - 1, 1))
    y = top + height - round(height * value / max(max_total, 1))
    {x, y}
  end

  defp map_empty?("netflow", _topology_links, traffic_links), do: traffic_links == []

  defp map_empty?(_map_view, topology_links, traffic_links), do: topology_links == [] and traffic_links == []

  defp map_empty_title("netflow", _state), do: "No NetFlow paths"
  defp map_empty_title(_map_view, :configured_empty), do: "Awaiting observed NetFlow summaries"
  defp map_empty_title(_map_view, :unconfigured), do: "NetFlow collector not configured"
  defp map_empty_title(_map_view, _state), do: "No topology or flow data"

  defp map_empty_detail("netflow", _state),
    do: "Recent flow conversations will appear here when NetFlow, IPFIX, or sFlow records exist."

  defp map_empty_detail(_map_view, :configured_empty),
    do: "Collector configuration exists, but no recent flow summaries were found."

  defp map_empty_detail(_map_view, :unconfigured), do: "Install a NetFlow, IPFIX, or sFlow collector to animate traffic."
  defp map_empty_detail(_map_view, _state), do: "No synthetic traffic animation is shown."

  defp alert_severity_class(value) do
    case value |> to_string() |> String.downcase() do
      severity when severity in ["critical", "emergency"] -> "is-critical"
      "warning" -> "is-warning"
      "info" -> "is-info"
      _ -> "is-neutral"
    end
  end

  defp alert_severity_label(value) do
    case value |> to_string() |> String.trim() do
      "" -> "Alert"
      label -> String.capitalize(label)
    end
  end

  defp alert_status_label(value) do
    case value |> to_string() |> String.trim() do
      "" -> "Open"
      label -> label |> String.replace("_", " ") |> String.capitalize()
    end
  end

  defp alert_subtitle(alert) do
    [alert.source_type, alert.device_uid]
    |> Enum.reject(&(is_nil(&1) or to_string(&1) == ""))
    |> Enum.join(" / ")
    |> case do
      "" -> "ServiceRadar alert"
      value -> value
    end
  end
end
