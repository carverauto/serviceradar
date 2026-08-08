defmodule ServiceRadarWebNGWeb.DashboardLive.Index.MapPanel do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  alias ServiceRadarWebNGWeb.DashboardLive.Index.Common

  attr(:dashboard, :map, required: true)

  def render(%{dashboard: dashboard} = assigns) do
    assigns = Map.merge(assigns, dashboard)

    ~H"""
    <Common.panel title={map_panel_title(@map_view)} class="lg:col-span-7">
      <:actions>
        <select
          id="traffic-map-view-select"
          name="map_view"
          phx-hook="DashboardMapViewSelect"
          class="sr-ops-select"
          aria-label="Dashboard map view"
        >
          <option
            value="netflow"
            selected={@map_view == "netflow"}
          >
            NetFlow Map
          </option>
          <option
            :for={instance <- @dashboard_package_instances}
            value={"dashboard:#{instance.route_slug}"}
            selected={@map_view == "dashboard:#{instance.route_slug}"}
          >
            {instance.name}
          </option>
        </select>
        <.link href={map_fullscreen_path(@map_view)} class="sr-ops-button">
          Full Screen
        </.link>
      </:actions>

      <div class={[
        "sr-ops-map-shell",
        @map_view == "netflow" && "is-netflow-view"
      ]}>
        <div :if={@map_view == "netflow"} class="sr-ops-map-controls">
          <ul class="sr-ops-map-legend" aria-label="NetFlow map legend">
            <li><span class="bg-[#3ecf87]"></span>Network cluster</li>
            <li><span class="bg-[#5bde9b]"></span>Private/public flow</li>
            <li><span class="bg-rose-500"></span>AlienVault IOC match</li>
            <li><span class="bg-violet-400"></span>Busy flow</li>
            <li><span class="bg-orange-400"></span>High volume flow</li>
            <li><span class="bg-[#8fa39a]/60"></span>External-only flow</li>
          </ul>
          <span class="sr-ops-map-window">{@traffic_links_window_label}</span>
        </div>

        <canvas
          :if={@map_view == "netflow"}
          id="ops-traffic-map"
          phx-hook="OperationsTrafficMap"
          class="sr-ops-traffic-canvas"
          data-map-view={@map_view}
          data-topology-links={@topology_links_json}
          data-links={@traffic_links_json}
          data-mtr-overlays={@mtr_overlays_json}
          aria-label="Network traffic map"
        />
        <div :if={@map_view != "netflow"} class="sr-ops-map-empty">
          <p>{map_panel_title(@map_view)}</p>
          <span>Open the full-screen dashboard package view to interact with this map.</span>
        </div>
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
          :if={@map_view == "netflow" and map_empty?(@map_view, @topology_links, @traffic_links)}
          class="sr-ops-map-empty"
          data-testid="traffic-map-empty"
        >
          <p>{map_empty_title(@map_view, @module_states.netflow)}</p>
          <span>{map_empty_detail(@map_view, @module_states.netflow)}</span>
        </div>
      </div>

      <div :if={@map_view == "netflow"} class="sr-ops-map-stats">
        <Common.small_stat
          :for={stat <- @map_stats}
          label={stat.label}
          value={stat.value}
          href={Map.get(stat, :href)}
          aria_label={Map.get(stat, :aria_label)}
        />
      </div>
    </Common.panel>
    """
  end

  defp map_panel_title("dashboard:" <> _route_slug), do: "Dashboard Map"
  defp map_panel_title(_), do: "NetFlow Map"

  defp map_fullscreen_path("dashboard:" <> route_slug), do: ~p"/dashboards/#{route_slug}"
  defp map_fullscreen_path(_), do: ~p"/netflow-map"

  defp map_empty?("netflow", _topology_links, traffic_links) do
    traffic_links == []
  end

  defp map_empty?(_map_view, topology_links, traffic_links), do: topology_links == [] and traffic_links == []

  defp map_empty_title("netflow", :unconfigured), do: "NetFlow collector not configured"
  defp map_empty_title("netflow", :configured_empty), do: "Awaiting observed NetFlow summaries"
  defp map_empty_title("netflow", _state), do: "No NetFlow paths"
  defp map_empty_title(_map_view, :configured_empty), do: "Awaiting observed NetFlow summaries"
  defp map_empty_title(_map_view, :unconfigured), do: "NetFlow collector not configured"
  defp map_empty_title(_map_view, _state), do: "No topology or flow data"

  defp map_empty_detail("netflow", :unconfigured),
    do: "Configure a NetFlow, IPFIX, or sFlow collector to enable this map."

  defp map_empty_detail("netflow", :configured_empty),
    do: "Collector configuration exists, but no recent flow summaries were found."

  defp map_empty_detail("netflow", _state), do: "No recent NetFlow conversations were found in the map window."

  defp map_empty_detail(_map_view, :configured_empty),
    do: "Collector configuration exists, but no recent flow summaries were found."

  defp map_empty_detail(_map_view, :unconfigured), do: "Install a NetFlow, IPFIX, or sFlow collector to animate traffic."

  defp map_empty_detail(_map_view, _state), do: "No synthetic traffic animation is shown."
end
