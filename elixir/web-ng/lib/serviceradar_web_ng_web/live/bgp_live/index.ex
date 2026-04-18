defmodule ServiceRadarWebNGWeb.BGPLive.Index do
  @moduledoc """
  BGP Routing observability interface.

  Displays BGP routing information aggregated from multiple sources:
  - NetFlow v9/IPFIX
  - sFlow
  - BMP (BGP Monitoring Protocol)

  Features:
  - Traffic by AS number
  - Top BGP communities
  - AS path diversity metrics
  - AS topology graph
  - Real-time updates via PubSub
  """

  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.BGPLive.Components

  alias ServiceRadar.BGP.Stats

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to BGP observation updates
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ServiceRadarWebNG.PubSub, "bgp:observations")
    end

    {:ok,
     socket
     |> assign(:page_title, "BGP Routing")
     |> assign(:srql, %{enabled: false, page_path: "/observability/bgp"})}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Read filters from URL params
    time_range = Map.get(params, "time_range", "last_1h")
    source_protocol = Map.get(params, "source_protocol")
    selected_as = parse_int(Map.get(params, "as"))
    selected_community = parse_int(Map.get(params, "community"))

    socket =
      socket
      |> assign(:time_range, time_range)
      |> assign(:source_protocol, source_protocol)
      |> assign(:selected_as, selected_as)
      |> assign(:selected_community, selected_community)
      |> load_bgp_statistics()

    {:noreply, socket}
  end

  @impl true
  def handle_info({:bgp_observation, _action, _observation_id, _metadata}, socket) do
    # Refresh data when new BGP observations arrive
    {:noreply, load_bgp_statistics(socket)}
  end

  @impl true
  def handle_event("filter_by_as", %{"as" => as_number}, socket) do
    params =
      build_params(socket, %{
        as: as_number,
        community: nil
      })

    {:noreply, push_patch(socket, to: ~p"/observability/bgp?#{params}")}
  end

  @impl true
  def handle_event("filter_by_community", %{"community" => community}, socket) do
    params =
      build_params(socket, %{
        as: nil,
        community: community
      })

    {:noreply, push_patch(socket, to: ~p"/observability/bgp?#{params}")}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    params =
      build_params(socket, %{
        as: nil,
        community: nil
      })

    {:noreply, push_patch(socket, to: ~p"/observability/bgp?#{params}")}
  end

  @impl true
  def handle_event("change_time_range", %{"time_range" => time_range}, socket) do
    params = build_params(socket, %{time_range: time_range})
    {:noreply, push_patch(socket, to: ~p"/observability/bgp?#{params}")}
  end

  @impl true
  def handle_event("change_source_protocol", %{"source_protocol" => protocol}, socket) do
    protocol = if protocol == "all", do: nil, else: protocol
    params = build_params(socket, %{source_protocol: protocol})
    {:noreply, push_patch(socket, to: ~p"/observability/bgp?#{params}")}
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    csv_data = generate_csv_export(socket)

    {:noreply,
     push_event(socket, "download_csv", %{
       filename: "bgp_routing_#{socket.assigns.time_range}_#{DateTime.to_unix(DateTime.utc_now())}.csv",
       content: csv_data
     })}
  end

  # Load BGP statistics from Stats module
  defp load_bgp_statistics(socket) do
    time_range = socket.assigns[:time_range] || "last_1h"
    source_protocol = socket.assigns[:source_protocol]

    # Fetch all BGP statistics
    traffic_data = Stats.get_traffic_by_as(time_range, source_protocol, 10)
    communities = Stats.get_top_communities(time_range, source_protocol, 10)
    path_diversity = Stats.get_path_diversity(time_range, source_protocol)
    topology = Stats.get_as_topology(time_range, source_protocol, 50)

    # New enhanced data
    as_path_details = Stats.get_as_path_details(time_range, source_protocol, 50)
    data_sources = Stats.get_data_sources(time_range)
    traffic_timeseries = Stats.get_traffic_timeseries(time_range, source_protocol, 5)
    prefix_analysis = Stats.get_prefix_analysis(time_range, source_protocol, 20)

    # Calculate max values for percentage bars
    max_bytes =
      case Enum.max_by(traffic_data, & &1.bytes, fn -> %{bytes: 1} end) do
        %{bytes: bytes} -> bytes
        _ -> 1
      end

    socket
    |> assign(:traffic_data, traffic_data)
    |> assign(:communities, communities)
    |> assign(:path_diversity, path_diversity)
    |> assign(:topology, topology)
    |> assign(:as_path_details, as_path_details)
    |> assign(:data_sources, data_sources)
    |> assign(:traffic_timeseries, traffic_timeseries)
    |> assign(:prefix_analysis, prefix_analysis)
    |> assign(:max_bytes, max_bytes)
    |> assign(:has_data, has_data?(traffic_data, communities, topology))
  end

  defp has_data?(traffic_data, communities, topology) do
    !Enum.empty?(traffic_data) or !Enum.empty?(communities) or !Enum.empty?(topology)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="max-w-screen-2xl mx-auto px-4 sm:px-6 lg:px-8 py-6 space-y-6">
        <.observability_chrome active_pane="bgp" />
        
    <!-- Header -->
        <div class="flex justify-between items-center">
          <div>
            <h1 class="text-2xl font-semibold text-base-content">
              BGP Routing
            </h1>
            <p class="text-sm text-base-content/60 mt-1">
              BGP routing information from NetFlow, sFlow, and BMP sources
            </p>
          </div>

    <!-- Filters -->
          <div class="flex gap-3">
            <!-- Time Range Selector -->
            <select
              phx-change="change_time_range"
              name="time_range"
              class="select select-sm select-bordered"
            >
              <option value="last_1h" selected={@time_range == "last_1h"}>Last 1 Hour</option>
              <option value="last_6h" selected={@time_range == "last_6h"}>Last 6 Hours</option>
              <option value="last_24h" selected={@time_range == "last_24h"}>Last 24 Hours</option>
              <option value="last_7d" selected={@time_range == "last_7d"}>Last 7 Days</option>
            </select>

    <!-- Source Protocol Selector -->
            <select
              phx-change="change_source_protocol"
              name="source_protocol"
              class="select select-sm select-bordered"
            >
              <option value="all" selected={is_nil(@source_protocol)}>All Sources</option>
              <option value="netflow" selected={@source_protocol == "netflow"}>NetFlow</option>
              <option value="sflow" selected={@source_protocol == "sflow"}>sFlow</option>
              <option value="bgp_peering" selected={@source_protocol == "bgp_peering"}>
                BGP Peering
              </option>
            </select>

    <!-- Clear Filters Button -->
            <%= if @selected_as || @selected_community do %>
              <button phx-click="clear_filters" class="btn btn-sm btn-ghost">
                Clear Filters
              </button>
            <% end %>
          </div>
        </div>

    <!-- Active Filters Display -->
        <%= if @selected_as || @selected_community do %>
          <div class="alert alert-info">
            <div class="flex items-center gap-2">
              <span class="text-sm font-medium">Active Filters:</span>
              <%= if @selected_as do %>
                <span class="badge badge-primary">AS {@selected_as}</span>
              <% end %>
              <%= if @selected_community do %>
                <span class="badge badge-primary">
                  Community {format_community(@selected_community)}
                </span>
              <% end %>
            </div>
          </div>
        <% end %>

        <%= if @has_data do %>
          <!-- Export Button -->
          <div class="flex justify-end mb-4">
            <button phx-click="export_csv" class="btn btn-sm btn-outline gap-2">
              <.icon name="hero-arrow-down-tray" class="size-4" /> Export CSV
            </button>
          </div>

    <!-- Data Sources Panel -->
          <.data_sources_panel sources={@data_sources} />

    <!-- Traffic Time Series -->
          <.traffic_timeseries_chart timeseries={@traffic_timeseries} />
          
    <!-- Main Statistics Grid -->
          <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
            <!-- Traffic by AS -->
            <.bgp_traffic_by_as_view
              traffic_data={@traffic_data}
              max_bytes={@max_bytes}
              selected_as={@selected_as}
            />

    <!-- Top BGP Communities -->
            <.bgp_top_communities_view
              communities={@communities}
              max_bytes={@max_bytes}
              selected_community={@selected_community}
            />

    <!-- AS Path Diversity -->
            <.bgp_path_diversity_panel path_diversity={@path_diversity} />

    <!-- AS Topology Graph -->
            <.bgp_topology_visualization topology={@topology} />
          </div>

    <!-- AS Path Details Table -->
          <.as_path_details_table paths={@as_path_details} />

    <!-- Prefix Analysis Table -->
          <.prefix_analysis_table prefixes={@prefix_analysis} />
        <% else %>
          <!-- Empty State -->
          <div class="text-center py-16">
            <svg
              class="mx-auto h-12 w-12 text-base-content/40"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
              />
            </svg>
            <h3 class="mt-2 text-sm font-medium text-base-content">
              No BGP Routing Data
            </h3>
            <p class="mt-1 text-sm text-base-content/60">
              No BGP observations found for the selected time range and filters.
            </p>
            <p class="mt-1 text-xs text-base-content/40">
              BGP data is populated from NetFlow, sFlow, or BMP sources.
            </p>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # Helper function to format BGP community values
  defp format_community(community) when is_integer(community) do
    cond do
      # Well-known communities
      community == 4_294_967_041 ->
        "NO_EXPORT"

      community == 4_294_967_042 ->
        "NO_ADVERTISE"

      community == 4_294_967_043 ->
        "NO_EXPORT_SUBCONFED"

      # Standard format (AS:value)
      true ->
        as_number = div(community, 65_536)
        value = rem(community, 65_536)
        "#{as_number}:#{value}"
    end
  end

  defp format_community(_), do: "Unknown"

  # Build URL params from current socket state with updates
  defp build_params(socket, updates) do
    %{
      time_range: Map.get(updates, :time_range, socket.assigns.time_range),
      source_protocol: Map.get(updates, :source_protocol, socket.assigns.source_protocol),
      as: Map.get(updates, :as, socket.assigns.selected_as),
      community: Map.get(updates, :community, socket.assigns.selected_community)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # Parse integer from string, returning nil if invalid
  defp parse_int(nil), do: nil

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(int) when is_integer(int), do: int

  # Generate CSV export of current data
  defp generate_csv_export(socket) do
    [
      # Header
      ["Type", "AS Number", "AS Path", "Prefix", "Community", "Bytes", "Packets", "Flow Count"],

      # Traffic by AS rows
      Enum.map(socket.assigns.traffic_data, fn item ->
        ["Traffic by AS", item.as_number, "", "", "", item.bytes, "", item.flow_count]
      end),

      # AS Path details rows
      Enum.map(socket.assigns.as_path_details, fn item ->
        path_str = Enum.join(item.as_path, " -> ")
        ["AS Path", "", path_str, "", "", item.bytes, item.packets, item.flow_count]
      end),

      # Prefix analysis rows
      Enum.map(socket.assigns.prefix_analysis, fn item ->
        ["Prefix", item.as_number, "", item.prefix, "", item.bytes, "", item.flow_count]
      end)
    ]
    |> List.flatten()
    |> Enum.map_join("\n", fn row ->
      Enum.map_join(row, ",", &to_string/1)
    end)
  end
end
