defmodule ServiceRadarWebNGWeb.DashboardLive.Index do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNG.RBAC
  alias ServiceRadar.Integrations.MapboxSettings
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
      |> assign(:mapbox, nil)
      |> assign_dashboard(Data.empty())

    socket =
      if connected?(socket) do
        scope = socket.assigns.current_scope

        socket
        |> start_async(:dashboard_load, fn -> Data.load(scope) end)
        |> start_async(:fieldsurvey_summary_load, fn -> Data.load_survey_summary(scope) end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_async(:dashboard_load, {:ok, dashboard_assigns}, socket) do
    dashboard_assigns = preserve_loaded_survey_summary(socket, dashboard_assigns)

    socket =
      socket
      |> assign(:mapbox, read_mapbox(socket.assigns.current_scope.user))
      |> assign_dashboard(dashboard_assigns)
      |> maybe_start_camera_previews()

    {:noreply, socket}
  end

  def handle_async(:fieldsurvey_summary_load, {:ok, survey_summary}, socket) do
    {:noreply, assign_survey_summary(socket, survey_summary)}
  end

  def handle_async(_name, {:exit, _reason}, socket), do: {:noreply, socket}

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
          <.kpi_card :for={card <- visible_kpi_cards(@kpi_cards, @camera_summary, @survey_summary)} card={card} />
        </section>

        <section class="sr-ops-grid-primary">
          <.panel title={map_panel_title(@map_view)} class="lg:col-span-7">
            <:actions>
              <select
                id="traffic-map-view-select"
                name="map_view"
                phx-hook="DashboardMapViewSelect"
                class="sr-ops-select"
                aria-label="Dashboard map view"
              >
                <option :if={netflow_map_available?(@module_states)} value="netflow" selected={@map_view == "netflow"}>
                  NetFlow Map
                </option>
                <option :if={wifi_map_available?(@module_states)} value="wifi_map" selected={@map_view == "wifi_map"}>
                  WiFi Map
                </option>
              </select>
              <.link href={map_fullscreen_path(@map_view)} class="sr-ops-button">
                Full Screen
              </.link>
            </:actions>

            <div class={[
              "sr-ops-map-shell",
              @map_view == "netflow" && "is-netflow-view",
              @map_view == "wifi_map" && "is-wifi-map-view"
            ]}>
              <div :if={@map_view == "netflow"} class="sr-ops-map-controls">
                <ul class="sr-ops-map-legend" aria-label="NetFlow map legend">
                  <li><span class="bg-teal-400"></span>Network cluster</li>
                  <li><span class="bg-sky-400"></span>Private/public flow</li>
                  <li><span class="bg-rose-500"></span>AlienVault IOC match</li>
                  <li><span class="bg-violet-400"></span>Busy flow</li>
                  <li><span class="bg-orange-400"></span>High volume flow</li>
                  <li><span class="bg-slate-400/60"></span>External-only flow</li>
                </ul>
                <span class="sr-ops-map-window">{@traffic_links_window_label}</span>
              </div>

              <.link
                :if={@map_view == "wifi_map"}
                navigate={~p"/wifi-map"}
                class="sr-ops-wifi-map-open"
                aria-label="Open full screen WiFi map"
              >
                Full Screen
              </.link>

              <div
                :if={@map_view == "wifi_map"}
                id="dashboard-wifi-site-map"
                phx-hook="WifiSiteMap"
                phx-update="ignore"
                data-sites={@wifi_map_sites_json}
                data-enabled={mapbox_enabled?(@mapbox)}
                data-access-token={mapbox_access_token(@mapbox)}
                data-style-light={mapbox_style_light(@mapbox)}
                data-style-dark={mapbox_style_dark(@mapbox)}
                data-compact="true"
                class="sr-ops-wifi-map-preview"
              >
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
              <svg
                id="ops-traffic-map-world"
                phx-update="ignore"
                class="sr-ops-world-map-background"
                preserveAspectRatio="xMidYMid meet"
                aria-hidden="true"
              />
              <svg
                id="ops-traffic-map-overlay"
                phx-update="ignore"
                class="sr-ops-traffic-overlay"
                preserveAspectRatio="xMidYMid meet"
                aria-hidden="true"
              />
              <div
                id="ops-traffic-map-interaction-controls"
                phx-update="ignore"
                class="sr-ops-map-interaction-controls"
              />

              <div
                :if={
                  @map_view == "netflow" and map_empty?(@map_view, @topology_links, @traffic_links)
                }
                class="sr-ops-map-empty"
                data-testid="traffic-map-empty"
              >
                <p>{map_empty_title(@map_view, @module_states.netflow)}</p>
                <span>{map_empty_detail(@map_view, @module_states.netflow)}</span>
              </div>
            </div>

            <div :if={@map_view == "netflow"} class="sr-ops-map-stats">
              <.small_stat :for={stat <- @map_stats} label={stat.label} value={stat.value} />
            </div>
            <div :if={@map_view == "wifi_map"} class="sr-ops-map-stats">
              <.small_stat label="Sites" value={format_count(@wifi_map_summary.site_count)} />
              <.small_stat label="APs" value={format_count(@wifi_map_summary.ap_count)} />
              <.small_stat label="Down" value={format_count(@wifi_map_summary.down_count)} />
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
          <.panel :if={survey_panel_visible?(@survey_summary)} title="FieldSurvey Heatmap" class="lg:col-span-6">
            <:actions>
              <.link href={~p"/spatial/field-surveys"} class="sr-ops-button">Open FieldSurvey</.link>
            </:actions>
            <div
              class={[
                "sr-ops-heatmap-placeholder",
                "sr-ops-field-survey-card-map",
                @survey_summary.raster_cell_count > 0 && "sr-ops-heatmap-real"
              ]}
              style={fieldsurvey_heatmap_style(@survey_summary)}
              data-testid="fieldsurvey-heatmap"
            >
              <svg
                :if={@survey_summary.floorplan_segment_count > 0}
                class="sr-ops-field-survey-floorplan"
                viewBox="0 0 100 100"
                preserveAspectRatio="none"
                aria-hidden="true"
              >
                <line
                  :for={segment <- @survey_summary.floorplan_segments}
                  x1={segment.start_x_pct}
                  y1={segment.start_z_pct}
                  x2={segment.end_x_pct}
                  y2={segment.end_z_pct}
                  class={"sr-ops-floorplan-line sr-ops-floorplan-line-#{segment.kind}"}
                />
              </svg>
              <div :if={@survey_summary.ap_marker_count > 0} class="sr-ops-field-survey-ap-layer">
                <.link
                  :for={ap <- Enum.filter(@survey_summary.ap_markers, &Map.get(&1, :device_uid))}
                  navigate={~p"/devices/#{ap.device_uid}"}
                  class="sr-ops-field-survey-ap-marker is-linked"
                  style={fieldsurvey_ap_marker_style(ap)}
                  title={fieldsurvey_ap_marker_title(ap)}
                  aria-label={fieldsurvey_ap_marker_title(ap)}
                >
                  <.icon name="hero-wifi" class="size-3.5" />
                  <.fieldsurvey_ap_tooltip ap={ap} />
                </.link>
                <span
                  :for={ap <- Enum.reject(@survey_summary.ap_markers, &Map.get(&1, :device_uid))}
                  class="sr-ops-field-survey-ap-marker"
                  style={fieldsurvey_ap_marker_style(ap)}
                  title={fieldsurvey_ap_marker_title(ap)}
                  aria-label={fieldsurvey_ap_marker_title(ap)}
                  tabindex="0"
                  role="button"
                >
                  <.icon name="hero-wifi" class="size-3.5" />
                  <.fieldsurvey_ap_tooltip ap={ap} />
                </span>
              </div>
              <div
                :if={@survey_summary.raster_cell_count > 0}
                class="sr-ops-field-survey-raster-cells"
                aria-label="Latest FieldSurvey Wi-Fi RSSI raster"
              >
                <span
                  :for={cell <- @survey_summary.raster_cells}
                  class="sr-ops-field-survey-raster-cell"
                  style={fieldsurvey_raster_cell_style(cell)}
                >
                </span>
              </div>
              <div
                :if={@survey_summary.raster_cell_count > 0}
                class="sr-ops-field-survey-legend"
                aria-label="FieldSurvey signal strength legend"
              >
                <span><i class="excellent"></i>-55+</span>
                <span><i class="good"></i>-65</span>
                <span><i class="fair"></i>-75</span>
                <span><i class="poor"></i>-82</span>
                <span><i class="weak"></i>weak</span>
              </div>
              <div
                :if={@survey_summary.raster_playlist_diagnostics != []}
                class="sr-ops-field-survey-diagnostics"
                aria-label="FieldSurvey playlist diagnostics"
              >
                <.icon name="hero-exclamation-triangle" class="size-3.5" />
                <span>{fieldsurvey_playlist_diagnostic(@survey_summary)}</span>
              </div>
              <div :if={@survey_summary.raster_cell_count == 0} class="sr-ops-floor-grid">
                <span :for={_ <- 1..18}></span>
              </div>
              <div
                :if={
                  @module_states.fieldsurvey == :loading and @survey_summary.sample_count == 0 and
                    @survey_summary.raster_cell_count == 0
                }
                class="sr-ops-heatmap-empty sr-ops-heatmap-summary"
              >
                <.icon name="hero-wifi" class="size-8" />
                <p>Loading FieldSurvey heatmap</p>
                <span>Checking persisted Wi-Fi rasters and floorplan artifacts.</span>
              </div>
              <div
                :if={
                  @module_states.fieldsurvey != :loading and @survey_summary.sample_count == 0 and
                    @survey_summary.raster_cell_count == 0
                }
                class="sr-ops-heatmap-empty"
              >
                <.icon name="hero-wifi" class="size-8" />
                <p>No FieldSurvey heatmap data</p>
                <span>Survey overlays will render here when floorplan samples exist.</span>
              </div>
              <div
                :if={@survey_summary.sample_count > 0 and @survey_summary.raster_cell_count == 0}
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

          <.panel :if={camera_panel_visible?(@camera_summary)} title="Camera Operations" class="lg:col-span-6">
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

          <.panel title="Threat Intel" class="lg:col-span-3">
            <:actions>
              <.link href={~p"/settings/networks/threat-intel"} class="sr-ops-button">
                Manage
              </.link>
            </:actions>
            <div class="sr-ops-threat-intel" data-testid="threat-intel-summary">
              <div class="sr-ops-threat-sync">
                <span class={[
                  "sr-ops-threat-status",
                  threat_status_class(@threat_intel_summary.latest_status)
                ]}>
                  {threat_status_label(@threat_intel_summary.latest_status)}
                </span>
                <div>
                  <strong>{threat_source_label(@threat_intel_summary)}</strong>
                  <small>{threat_sync_label(@threat_intel_summary)}</small>
                </div>
              </div>

              <div class="sr-ops-threat-stat-grid">
                <.small_stat
                  label="IOCs"
                  value={format_compact_count(@threat_intel_summary.imported_indicators)}
                />
                <.small_stat
                  label="Objects"
                  value={format_compact_count(@threat_intel_summary.source_objects)}
                />
                <.small_stat
                  label="Matched IPs"
                  value={format_compact_count(@threat_intel_summary.matched_ips)}
                />
                <.small_stat
                  label="IOC Hits"
                  value={format_compact_count(@threat_intel_summary.indicator_matches)}
                />
              </div>

              <div class="sr-ops-threat-detail">
                <span>Max severity</span>
                <strong>{@threat_intel_summary.max_severity}</strong>
              </div>
              <div class="sr-ops-threat-message">
                {threat_message(@threat_intel_summary)}
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
  def handle_info({_ref, {:access_token_present, _field, _result}}, socket) do
    {:noreply, socket}
  end

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

  defp fieldsurvey_heatmap_style(%{raster_aspect_ratio: ratio}) when is_number(ratio) do
    ratio =
      ratio
      |> max(0.72)
      |> min(3.2)
      |> Float.round(3)

    "aspect-ratio: #{ratio} / 1;"
  end

  defp fieldsurvey_heatmap_style(_summary), do: nil

  defp fieldsurvey_playlist_diagnostic(%{raster_playlist_diagnostics: [diagnostic | _]}) do
    Map.get(diagnostic, :message) || "Using fallback FieldSurvey heatmap"
  end

  defp fieldsurvey_playlist_diagnostic(_summary), do: "Using fallback FieldSurvey heatmap"

  defp fieldsurvey_ap_marker_style(%{x_pct: x, z_pct: z}) when is_number(x) and is_number(z) do
    "left: #{Float.round(x, 3)}%; top: #{Float.round(z, 3)}%;"
  end

  defp fieldsurvey_ap_marker_style(_ap), do: nil

  attr(:ap, :map, required: true)

  defp fieldsurvey_ap_tooltip(assigns) do
    ~H"""
    <span class="sr-ops-field-survey-ap-tooltip">
      <strong>{Map.get(@ap, :ssid) || "Hidden SSID"}</strong>
      <span>{Map.get(@ap, :bssid) || "unknown BSSID"}</span>
      <span>
        {format_ap_rssi(Map.get(@ap, :strongest_rssi))} dBm - ch {format_ap_channel(@ap)} - {format_marker_count(
          Map.get(@ap, :sample_count, 0)
        )} samples
      </span>
      <span>
        {format_marker_percent((Map.get(@ap, :confidence) || 0.0) * 100)} placement confidence
      </span>
      <span :if={Map.get(@ap, :device_uid)} class="sr-ops-field-survey-ap-device">
        {fieldsurvey_ap_device_label(@ap)}
      </span>
    </span>
    """
  end

  defp fieldsurvey_raster_cell_style(%{x_pct: x, z_pct: z, radius_pct: radius, rssi: rssi, confidence: confidence})
       when is_number(x) and is_number(z) do
    diameter = max((radius || 1.0) * 3.0, 2.8)
    opacity = 0.16 + min(max((confidence || 0.0) * 1.0, 0.0), 1.0) * 0.34
    color = fieldsurvey_rssi_color(rssi || -95)

    "left: calc(#{Float.round(x, 3)}% - #{Float.round(diameter / 2, 3)}%); top: calc(#{Float.round(z, 3)}% - #{Float.round(diameter / 2, 3)}%); width: #{Float.round(diameter, 3)}%; height: #{Float.round(diameter, 3)}%; background: radial-gradient(circle, #{color} 0%, #{color} 62%, transparent 88%); opacity: #{Float.round(opacity, 3)};"
  end

  defp fieldsurvey_raster_cell_style(_cell), do: nil

  defp fieldsurvey_rssi_color(rssi) when is_number(rssi) and rssi >= -55, do: "#5fd38a"
  defp fieldsurvey_rssi_color(rssi) when is_number(rssi) and rssi >= -65, do: "#8bd94f"
  defp fieldsurvey_rssi_color(rssi) when is_number(rssi) and rssi >= -75, do: "#ffd25a"
  defp fieldsurvey_rssi_color(rssi) when is_number(rssi) and rssi >= -82, do: "#ff7d3f"
  defp fieldsurvey_rssi_color(_rssi), do: "#ef4444"

  defp fieldsurvey_ap_marker_title(ap) do
    ssid = Map.get(ap, :ssid) || "Hidden"
    bssid = Map.get(ap, :bssid) || "unknown BSSID"
    rssi = Map.get(ap, :strongest_rssi)
    samples = Map.get(ap, :sample_count, 0)

    "#{ssid} #{bssid}: strongest #{format_ap_rssi(rssi)} dBm, #{samples} samples"
  end

  defp format_ap_rssi(rssi) when is_number(rssi), do: rssi |> Kernel.*(1.0) |> Float.round(1) |> to_string()
  defp format_ap_rssi(_rssi), do: "unknown"

  defp format_marker_count(value) when is_integer(value), do: Integer.to_string(value)
  defp format_marker_count(value) when is_number(value), do: value |> round() |> Integer.to_string()
  defp format_marker_count(_value), do: "0"

  defp format_marker_percent(value) when is_number(value) do
    "#{(value * 1.0) |> Float.round(0) |> trunc()}%"
  end

  defp format_marker_percent(_value), do: "0%"

  defp format_ap_channel(%{channel: channel, frequency_mhz: frequency}) when is_number(channel) and is_number(frequency),
    do: "#{channel} / #{frequency} MHz"

  defp format_ap_channel(%{channel: channel}) when is_number(channel), do: to_string(channel)
  defp format_ap_channel(%{frequency_mhz: frequency}) when is_number(frequency), do: "#{frequency} MHz"
  defp format_ap_channel(_ap), do: "unknown"

  defp fieldsurvey_ap_device_label(ap) do
    [Map.get(ap, :device_name), Map.get(ap, :device_vendor), Map.get(ap, :device_model)]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> case do
      [] -> "Open matched device"
      parts -> "Open " <> Enum.join(parts, " ")
    end
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
    dashboard_assigns = ensure_valid_map_view(dashboard_assigns)

    Enum.reduce(dashboard_assigns, socket, fn {key, value}, acc ->
      assign(acc, key, value)
    end)
  end

  defp ensure_valid_map_view(%{module_states: states} = assigns) do
    map_view = Map.get(assigns, :map_view, "netflow")

    valid_view =
      cond do
        map_view == "netflow" and netflow_map_available?(states) -> "netflow"
        map_view == "wifi_map" and wifi_map_available?(states) -> "wifi_map"
        wifi_map_available?(states) -> "wifi_map"
        netflow_map_available?(states) -> "netflow"
        true -> "wifi_map"
      end

    Map.put(assigns, :map_view, valid_view)
  end

  defp ensure_valid_map_view(assigns), do: assigns

  defp assign_survey_summary(socket, survey_summary) do
    survey_sparkline =
      socket.assigns.kpi_cards
      |> Enum.find(%{}, &(&1.title == "Wi-Fi Coverage"))
      |> Map.get(:sparkline, [])

    survey_card = Data.survey_kpi_card(survey_summary, survey_sparkline)

    kpi_cards =
      Enum.map(socket.assigns.kpi_cards, fn
        %{title: "Wi-Fi Coverage"} -> survey_card
        card -> card
      end)

    socket
    |> assign(:survey_summary, survey_summary)
    |> assign(:kpi_cards, kpi_cards)
  end

  defp preserve_loaded_survey_summary(socket, dashboard_assigns) do
    current = socket.assigns.survey_summary
    incoming = Map.get(dashboard_assigns, :survey_summary)

    if survey_raster_cell_count(current) > survey_raster_cell_count(incoming) do
      survey_card = Data.survey_kpi_card(current, survey_sparkline_from(dashboard_assigns))

      dashboard_assigns
      |> Map.put(:survey_summary, current)
      |> Map.put(:kpi_cards, replace_survey_kpi_card(Map.get(dashboard_assigns, :kpi_cards, []), survey_card))
    else
      dashboard_assigns
    end
  end

  defp survey_sparkline_from(%{kpi_cards: kpi_cards}) when is_list(kpi_cards) do
    kpi_cards
    |> Enum.find(%{}, &(&1.title == "Wi-Fi Coverage"))
    |> Map.get(:sparkline, [])
  end

  defp survey_sparkline_from(_assigns), do: []

  defp replace_survey_kpi_card(kpi_cards, survey_card) when is_list(kpi_cards) do
    Enum.map(kpi_cards, fn
      %{title: "Wi-Fi Coverage"} -> survey_card
      card -> card
    end)
  end

  defp replace_survey_kpi_card(_kpi_cards, _survey_card), do: []

  defp visible_kpi_cards(kpi_cards, camera_summary, survey_summary) when is_list(kpi_cards) do
    Enum.reject(kpi_cards, fn
      %{title: "Camera Fleet"} -> not camera_panel_visible?(camera_summary)
      %{title: "Wi-Fi Coverage"} -> not survey_panel_visible?(survey_summary)
      _card -> false
    end)
  end

  defp visible_kpi_cards(_kpi_cards, _camera_summary, _survey_summary), do: []

  defp survey_raster_cell_count(%{raster_cell_count: count}) when is_integer(count), do: count
  defp survey_raster_cell_count(_summary), do: 0

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

  defp normalize_map_view("wifi_map"), do: "wifi_map"
  defp normalize_map_view(_), do: "netflow"

  defp map_panel_title("wifi_map"), do: "WiFi Map"
  defp map_panel_title(_), do: "NetFlow Map"

  defp map_fullscreen_path("wifi_map"), do: ~p"/wifi-map"
  defp map_fullscreen_path(_), do: ~p"/netflow-map"

  defp netflow_map_available?(states), do: Map.get(states || %{}, :netflow) == :active
  defp wifi_map_available?(states), do: Map.get(states || %{}, :wifi_map) == :active

  defp survey_panel_visible?(summary) do
    survey_raster_cell_count(summary) > 0 or Map.get(summary || %{}, :sample_count, 0) > 0
  end

  defp camera_panel_visible?(summary), do: Map.get(summary || %{}, :total, 0) > 0

  defp format_count(value) when is_integer(value), do: value |> Integer.to_string() |> delimit_integer_string()
  defp format_count(value), do: value |> to_int() |> Integer.to_string() |> delimit_integer_string()

  defp delimit_integer_string(value) do
    value
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp read_mapbox(nil), do: nil

  defp read_mapbox(user) do
    case MapboxSettings.get_settings(actor: user) do
      {:ok, %MapboxSettings{} = settings} -> settings
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp mapbox_enabled?(%MapboxSettings{} = settings), do: settings.enabled
  defp mapbox_enabled?(_), do: false

  defp mapbox_access_token(%MapboxSettings{} = settings), do: settings.access_token || ""
  defp mapbox_access_token(_), do: ""

  defp mapbox_style_light(%MapboxSettings{} = settings), do: settings.style_light || "mapbox://styles/mapbox/light-v11"
  defp mapbox_style_light(_), do: "mapbox://styles/mapbox/light-v11"

  defp mapbox_style_dark(%MapboxSettings{} = settings), do: settings.style_dark || "mapbox://styles/mapbox/dark-v11"
  defp mapbox_style_dark(_), do: "mapbox://styles/mapbox/dark-v11"

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

  defp threat_status_label(nil), do: "idle"
  defp threat_status_label(""), do: "idle"
  defp threat_status_label("ok"), do: "ok"
  defp threat_status_label(status) when is_binary(status), do: String.downcase(status)
  defp threat_status_label(_), do: "idle"

  defp threat_status_class("ok"), do: "is-ok"
  defp threat_status_class("error"), do: "is-error"
  defp threat_status_class("failed"), do: "is-error"
  defp threat_status_class("timeout"), do: "is-warning"
  defp threat_status_class(_), do: "is-idle"

  defp threat_source_label(%{latest_provider: provider, latest_source: source}) do
    [provider, source]
    |> Enum.filter(&present_text?/1)
    |> Enum.join(" / ")
    |> case do
      "" -> "No feed sync yet"
      label -> label
    end
  end

  defp threat_source_label(_), do: "No feed sync yet"

  defp threat_sync_label(%{latest_success_label: label}) when is_binary(label) and label != "",
    do: "Last success #{label} UTC"

  defp threat_sync_label(%{latest_attempt_label: label}) when is_binary(label) and label != "",
    do: "Last attempt #{label} UTC"

  defp threat_sync_label(_), do: "Waiting for OTX sync"

  defp threat_message(%{latest_message: message}) when is_binary(message) and message != "", do: message
  defp threat_message(%{imported_indicators: count}) when count > 0, do: "Indicators are ready for NetFlow matching."
  defp threat_message(_), do: "Assign the OTX plugin and sync to populate threat context."

  defp present_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_text?(_), do: false

  defp format_compact_count(value) do
    value = to_int(value)

    cond do
      value >= 1_000_000 -> "#{compact_decimal(value / 1_000_000)}M"
      value >= 1_000 -> "#{compact_decimal(value / 1_000)}K"
      true -> Integer.to_string(value)
    end
  end

  defp compact_decimal(value) do
    value
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
    |> String.trim_trailing(".0")
  end

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
