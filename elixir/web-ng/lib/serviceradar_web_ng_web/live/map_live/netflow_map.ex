defmodule ServiceRadarWebNGWeb.MapLive.NetflowMap do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNGWeb.DashboardLive.Data

  @netflow_map_path "/netflow-map"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "NetFlow Map")
      |> assign(:current_path, @netflow_map_path)
      |> assign_netflow_map(empty_netflow_map())

    socket =
      if connected?(socket) do
        start_async(socket, :netflow_map_load, fn ->
          Data.load_netflow_map(socket.assigns.current_scope)
        end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_async(:netflow_map_load, {:ok, map_assigns}, socket) do
    {:noreply, assign_netflow_map(socket, map_assigns)}
  end

  def handle_async(:netflow_map_load, {:exit, _reason}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      page_title={@page_title}
      shell={:operations}
      hide_breadcrumb
    >
      <div class="sr-netflow-map-app" data-testid="netflow-map-page">
        <header class="sr-netflow-map-topbar">
          <.link navigate={~p"/dashboard"} class="sr-netflow-map-back" aria-label="Back to dashboard">
            <.icon name="hero-arrow-left" class="size-5" />
          </.link>
          <div class="sr-netflow-map-heading">
            <strong>NetFlow Map</strong>
            <span>{@traffic_links_window_label}</span>
          </div>
          <div class="sr-netflow-map-stats">
            <.netflow_stat :for={stat <- @map_stats} label={stat.label} value={stat.value} />
          </div>
        </header>

        <main class="sr-netflow-map-stage">
          <div class="sr-ops-map-shell sr-netflow-map-shell is-netflow-view">
            <div class="sr-ops-map-controls">
              <ul class="sr-ops-map-legend" aria-label="NetFlow map legend">
                <li><span class="bg-teal-400"></span>Network cluster</li>
                <li><span class="bg-sky-400"></span>Private/public flow</li>
                <li><span class="bg-rose-500"></span>AlienVault IOC match</li>
                <li><span class="bg-violet-400"></span>Busy flow</li>
                <li><span class="bg-orange-400"></span>High volume flow</li>
                <li><span class="bg-slate-400/60"></span>External-only flow</li>
              </ul>
            </div>

            <canvas
              id="netflow-fullscreen-map"
              phx-hook="OperationsTrafficMap"
              class="sr-ops-traffic-canvas"
              data-map-view="netflow"
              data-topology-links={@topology_links_json}
              data-links={@traffic_links_json}
              data-mtr-overlays={@mtr_overlays_json}
              aria-label="NetFlow traffic map"
            />
            <svg
              phx-update="ignore"
              class="sr-ops-world-map-background"
              preserveAspectRatio="xMidYMid meet"
              aria-hidden="true"
            />
            <svg
              phx-update="ignore"
              class="sr-ops-traffic-overlay"
              preserveAspectRatio="xMidYMid meet"
              aria-hidden="true"
            />
            <div phx-update="ignore" class="sr-ops-map-interaction-controls" />

            <div
              :if={netflow_map_empty?(@traffic_links)}
              class="sr-ops-map-empty"
              data-testid="netflow-map-empty"
            >
              <p>{@map_empty_title}</p>
              <span>{@map_empty_detail}</span>
            </div>
          </div>
        </main>
      </div>
    </Layouts.app>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  defp netflow_stat(assigns) do
    ~H"""
    <div class="sr-netflow-map-stat">
      <span>{@label}</span>
      <strong>{@value}</strong>
    </div>
    """
  end

  defp assign_netflow_map(socket, map_assigns) do
    Enum.reduce(map_assigns, socket, fn {key, value}, acc ->
      assign(acc, key, value)
    end)
  end

  defp empty_netflow_map do
    empty = Data.empty()

    %{
      netflow_state: :loading,
      map_stats: empty.map_stats,
      traffic_links_window_label: empty.traffic_links_window_label,
      topology_links: empty.topology_links,
      topology_links_json: empty.topology_links_json,
      traffic_links: empty.traffic_links,
      traffic_links_json: empty.traffic_links_json,
      mtr_overlays: empty.mtr_overlays,
      mtr_overlays_json: empty.mtr_overlays_json,
      map_empty_title: empty.map_empty_title,
      map_empty_detail: empty.map_empty_detail
    }
  end

  defp netflow_map_empty?(traffic_links) do
    not Enum.any?(List.wrap(traffic_links), &Map.get(&1, :geo_mapped, false))
  end
end
