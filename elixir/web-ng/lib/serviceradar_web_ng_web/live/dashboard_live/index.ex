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
              <.link href={~p"/topology"} class="sr-ops-button">Full Topology</.link>
            </:actions>

            <div class="sr-ops-map-shell">
              <div class="sr-ops-map-controls">
                <ul class="sr-ops-map-legend" aria-label="NetFlow map legend">
                  <li><span class="bg-teal-400"></span>Network cluster</li>
                  <li><span class="bg-sky-400"></span>Private/public flow</li>
                  <li><span class="bg-violet-400"></span>Busy flow</li>
                  <li><span class="bg-orange-400"></span>High volume flow</li>
                  <li><span class="bg-slate-400/60"></span>External-only flow</li>
                </ul>
                <span class="sr-ops-map-window">{@traffic_links_window_label}</span>
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
                  <line
                    :for={label <- event_axis_labels(@security_trend)}
                    class="sr-ops-events-x-grid"
                    x1={label.x}
                    x2={label.x}
                    y1="26"
                    y2="180"
                  />
                  <line
                    :for={tick <- event_y_axis_ticks(@security_trend_max)}
                    x1="36"
                    x2="616"
                    y1={tick.y}
                    y2={tick.y}
                  />
                  <line class="sr-ops-events-baseline" x1="36" x2="616" y1="180" y2="180" />
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
                  <text
                    :for={tick <- event_y_axis_ticks(@security_trend_max)}
                    class="sr-ops-events-y-label"
                    x="30"
                    y={tick.y + 4}
                  >
                    {tick.text}
                  </text>
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
            <div class="sr-ops-camera-operations" data-testid="camera-operations">
              <div class="sr-ops-camera-status-list">
                <.camera_status_row
                  label="Available"
                  value={to_string(@camera_summary.online)}
                  icon="hero-video-camera"
                  tone="success"
                />
                <.camera_status_row
                  label="Offline"
                  value={to_string(@camera_summary.offline)}
                  icon="hero-video-camera-slash"
                  tone="error"
                />
                <.camera_status_row
                  label="Recording"
                  value={to_string(@camera_summary.recording)}
                  icon="hero-camera"
                  tone="info"
                />
                <.camera_status_row
                  label="Total Cameras"
                  value={to_string(@camera_summary.total)}
                  icon="hero-squares-2x2"
                  tone="neutral"
                />
              </div>
              <div class="sr-ops-camera-wall">
                <.link
                  :for={tile <- @camera_preview_tiles}
                  href={~p"/cameras/#{tile.camera_source_id}"}
                  class="sr-ops-camera-tile sr-ops-camera-tile-live"
                  aria-label={"Open #{tile.label}"}
                >
                  <CameraRelayComponents.relay_player
                    :if={tile.session}
                    session={tile.session}
                    id_prefix="dashboard-camera-relay"
                  />
                  <div :if={!tile.session} class="sr-ops-camera-tile-error">
                    <.icon name="hero-video-camera-slash" class="size-6" />
                    <span>{tile.error || "Relay unavailable"}</span>
                  </div>
                  <div class="sr-ops-camera-tile-caption">
                    <span>
                      <i class={camera_status_dot_class(tile.source_status)}></i>{tile.label}
                    </span>
                    <small>{camera_preview_detail(tile)}</small>
                  </div>
                </.link>
                <.link
                  :for={tile <- camera_tiles(@camera_summary.tiles, @camera_preview_tiles)}
                  href={camera_tile_href(tile)}
                  class="sr-ops-camera-tile"
                  aria-label={"Open #{tile.label}"}
                >
                  <div class="sr-ops-camera-thumbnail" aria-hidden="true">
                    <.icon name="hero-video-camera" class="size-7" />
                  </div>
                  <div class="sr-ops-camera-tile-caption">
                    <span><i class={camera_status_dot_class(tile.status)}></i>{tile.label}</span>
                    <small>{camera_status_label(tile.status)}</small>
                  </div>
                </.link>
              </div>
            </div>
          </.panel>
        </section>

        <section class="sr-ops-grid-bottom">
          <.panel title="Observability Metrics" class="lg:col-span-4">
            <div class="sr-ops-metric-grid">
              <div
                :for={metric <- @observability_metrics}
                class={[
                  "sr-ops-metric-card",
                  "tone-#{metric.tone}",
                  if(metric.available, do: nil, else: "is-empty")
                ]}
              >
                <span>{metric.label}</span>
                <div class="sr-ops-metric-value-row">
                  <strong>{metric.value}</strong>
                  <small :if={metric.scale != ""}>{metric.scale}</small>
                </div>
                <div class="sr-ops-metric-sparkline-wrap">
                  <span class="sr-ops-metric-axis sr-ops-metric-axis-top">{metric.axis_max}</span>
                  <span class="sr-ops-metric-axis sr-ops-metric-axis-mid">{metric.axis_mid}</span>
                  <span class="sr-ops-metric-axis sr-ops-metric-axis-bottom">{metric.axis_min}</span>
                  <.sparkline
                    values={metric.sparkline}
                    tone={metric.tone}
                    class="sr-ops-metric-sparkline"
                  />
                </div>
              </div>
            </div>
          </.panel>

          <.panel title="Top Vulnerable Assets" class="lg:col-span-3">
            <div class="sr-ops-feed-empty is-asset-feed" data-testid="vulnerable-assets-empty">
              <div class="sr-ops-empty-feed-shell" aria-hidden="true">
                <div class="sr-ops-empty-feed-header">
                  <span>Asset</span>
                  <span>Risk</span>
                  <span>Status</span>
                </div>
                <span :for={_ <- 1..5} class="sr-ops-empty-feed-row"></span>
              </div>
              <div class="sr-ops-empty-feed-message">
                <.icon name="hero-shield-exclamation" class="size-7 text-amber-400" />
                <p>Vulnerability tracking is not connected</p>
                <span>No fabricated risk counts are displayed.</span>
              </div>
            </div>
          </.panel>

          <.panel title="Alerts Feed" class="lg:col-span-5">
            <:actions>
              <.link href={~p"/alerts"} class="sr-ops-button">
                View All Alerts
              </.link>
            </:actions>
            <div
              :if={@alert_feed == []}
              class="sr-ops-feed-empty is-alert-feed"
              data-testid="alerts-feed-empty"
            >
              <div class="sr-ops-empty-feed-shell" aria-hidden="true">
                <div class="sr-ops-empty-feed-header">
                  <span>Time</span>
                  <span>Alert</span>
                  <span>Status</span>
                </div>
                <span :for={_ <- 1..5} class="sr-ops-empty-feed-row"></span>
              </div>
              <div class="sr-ops-empty-feed-message">
                <.icon name="hero-bell-alert" class="size-7 text-rose-400" />
                <p>No recent alerts</p>
                <span>Live alerts from the existing alert stream will appear here.</span>
              </div>
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
      <.sparkline values={@card.sparkline} tone={@card.tone} class="sr-ops-kpi-sparkline" />
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

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:icon, :string, required: true)
  attr(:tone, :string, default: "neutral")

  defp camera_status_row(assigns) do
    ~H"""
    <div class={["sr-ops-camera-status-row", "tone-#{@tone}"]}>
      <span>
        <.icon name={@icon} class="size-4" />
        {@label}
      </span>
      <strong>{@value}</strong>
    </div>
    """
  end

  attr(:values, :list, default: [])
  attr(:tone, :string, default: "neutral")
  attr(:class, :string, default: "")

  defp sparkline(assigns) do
    assigns =
      assigns
      |> assign(:spark_values, sparkline_values(assigns.values))
      |> assign(:line_path, sparkline_line_path(assigns.values))
      |> assign(:area_path, sparkline_area_path(assigns.values))

    ~H"""
    <svg
      class={["sr-ops-sparkline", "tone-#{@tone}", @class]}
      viewBox="0 0 100 32"
      preserveAspectRatio="none"
      aria-hidden="true"
    >
      <line
        :if={@spark_values == []}
        class="sr-ops-sparkline-baseline"
        x1="0"
        x2="100"
        y1="24"
        y2="24"
      />
      <g class="sr-ops-sparkline-grid" aria-hidden="true">
        <line x1="0" x2="100" y1="8" y2="8" />
        <line x1="0" x2="100" y1="16" y2="16" />
        <line x1="0" x2="100" y1="24" y2="24" />
        <line x1="25" x2="25" y1="5" y2="29" />
        <line x1="50" x2="50" y1="5" y2="29" />
        <line x1="75" x2="75" y1="5" y2="29" />
      </g>
      <path :if={@spark_values != []} class="sr-ops-sparkline-area" d={@area_path} />
      <path :if={@spark_values != []} class="sr-ops-sparkline-line" d={@line_path} />
    </svg>
    """
  end

  defp assign_dashboard(socket, dashboard_assigns) when is_map(dashboard_assigns) do
    Enum.reduce(dashboard_assigns, socket, fn {key, value}, acc ->
      assign(acc, key, value)
    end)
  end

  defp camera_tiles(tiles, preview_tiles) do
    remaining = max(4 - length(preview_tiles), 0)
    preview_ids = MapSet.new(preview_tiles, &camera_tile_id/1)

    visible_tiles =
      tiles
      |> List.wrap()
      |> Enum.reject(&(camera_tile_id(&1) in preview_ids))
      |> Enum.take(remaining)

    visible_tiles ++ camera_placeholder_tiles(remaining - length(visible_tiles))
  end

  defp camera_placeholder_tiles(count) when count > 0 do
    Enum.map(1..count, fn index ->
      %{id: nil, label: "No preview", status: "empty", slot: index}
    end)
  end

  defp camera_placeholder_tiles(_count), do: []

  defp camera_tile_href(%{id: id}) when is_binary(id) and id != "", do: ~p"/cameras/#{id}"
  defp camera_tile_href(_tile), do: ~p"/cameras"

  defp camera_tile_id(%{camera_source_id: id}) when is_binary(id), do: id
  defp camera_tile_id(%{id: id}) when is_binary(id), do: id
  defp camera_tile_id(_tile), do: nil

  defp camera_status_label(value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      status when status in ["available", "online", "active", "healthy"] -> "Online"
      status when status in ["offline", "unavailable", "failed", "error"] -> "Offline"
      "empty" -> "No relay"
      "" -> "Unknown"
      status -> String.capitalize(status)
    end
  end

  defp camera_preview_detail(%{session: session, detail: detail}) when not is_nil(session), do: detail

  defp camera_preview_detail(%{error: error}) when is_binary(error) and error != "" do
    cond do
      String.contains?(error, "Assigned agent") and String.contains?(error, "offline") -> "Agent offline"
      String.contains?(error, "No relay-capable") -> "No relay profile"
      true -> error
    end
  end

  defp camera_preview_detail(_tile), do: "No relay"

  defp camera_status_dot_class(value) do
    case camera_status_label(value) do
      "Online" -> "is-online"
      "Offline" -> "is-offline"
      _ -> "is-unknown"
    end
  end

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

  defp normalize_map_view(_), do: "netflow"

  defp map_panel_title(_), do: "NetFlow Map"

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

  defp event_y_axis_ticks(max_total) do
    max_total = max(to_int(max_total), 0)

    max_total
    |> event_tick_values()
    |> Enum.map(fn value ->
      {_x, y} = event_xy(0, 1, value, max(max_total, 1))
      %{y: y, text: event_tick_label(value)}
    end)
  end

  defp event_tick_values(0), do: [0]

  defp event_tick_values(max_total) do
    Enum.uniq([max_total, round(max_total * 0.75), round(max_total * 0.5), round(max_total * 0.25), 0])
  end

  defp event_tick_label(value) when value >= 1_000_000, do: "#{event_tick_decimal(value / 1_000_000)}M"
  defp event_tick_label(value) when value >= 1_000, do: "#{event_tick_decimal(value / 1_000)}K"
  defp event_tick_label(value), do: Integer.to_string(value)

  defp event_tick_decimal(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.trim_trailing(".0")
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

  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: round(value)
  defp to_int(_value), do: 0

  defp sparkline_values(values) do
    values
    |> List.wrap()
    |> Enum.map(&sparkline_value/1)
    |> Enum.filter(&is_number/1)
  end

  defp sparkline_value(%{value: value}), do: sparkline_value(value)
  defp sparkline_value(value) when is_integer(value), do: value * 1.0
  defp sparkline_value(value) when is_float(value), do: value
  defp sparkline_value(_), do: nil

  defp sparkline_line_path(values) do
    values
    |> sparkline_coordinates()
    |> case do
      [] -> ""
      [{x, y} | rest] -> "M #{x} #{y} " <> Enum.map_join(rest, " ", fn {px, py} -> "L #{px} #{py}" end)
    end
  end

  defp sparkline_area_path(values) do
    case sparkline_coordinates(values) do
      [] ->
        ""

      [{x, y} | rest] ->
        top = "M #{x} #{y} " <> Enum.map_join(rest, " ", fn {px, py} -> "L #{px} #{py}" end)
        "#{top} L 100 32 L 0 32 Z"
    end
  end

  defp sparkline_coordinates(values) do
    values = sparkline_values(values)
    count = length(values)

    if count == 0 do
      []
    else
      min_value = Enum.min(values)
      max_value = Enum.max(values)
      range = max(max_value - min_value, 1.0)

      values
      |> Enum.with_index()
      |> Enum.map(fn {value, idx} ->
        x = Float.round(idx * 100 / max(count - 1, 1), 2)
        y = Float.round(28 - (value - min_value) / range * 22, 2)
        {x, y}
      end)
    end
  end

  defp map_empty?("netflow", _topology_links, traffic_links) do
    not Enum.any?(traffic_links, &Map.get(&1, :geo_mapped, false))
  end

  defp map_empty?(_map_view, topology_links, traffic_links), do: topology_links == [] and traffic_links == []

  defp map_empty_title("netflow", _state), do: "No NetFlow paths"
  defp map_empty_title(_map_view, :configured_empty), do: "Awaiting observed NetFlow summaries"
  defp map_empty_title(_map_view, :unconfigured), do: "NetFlow collector not configured"
  defp map_empty_title(_map_view, _state), do: "No topology or flow data"

  defp map_empty_detail("netflow", _state),
    do: "Recent flow conversations need GeoIP enrichment or private-network anchors before they can be mapped."

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
