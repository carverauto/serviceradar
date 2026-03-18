defmodule ServiceRadarWebNGWeb.BGPLive.Components do
  @moduledoc """
  BGP visualization components.

  Reusable function components for displaying BGP routing information:
  - Traffic by AS bar chart
  - Top BGP communities
  - AS path diversity metrics
  - AS topology graph
  """

  use Phoenix.Component

  import ServiceRadarWebNGWeb.CoreComponents, only: [icon: 1]

  @doc """
  Traffic by AS bar chart with click-to-filter.
  """
  attr :traffic_data, :list, required: true
  attr :max_bytes, :integer, required: true
  attr :selected_as, :integer, default: nil

  def bgp_traffic_by_as_view(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-200 shadow-sm">
      <div class="card-body">
        <h3 class="card-title text-base">Traffic by AS Number</h3>

        <%= if Enum.empty?(@traffic_data) do %>
          <p class="text-sm text-base-content/60">No AS traffic data available</p>
        <% else %>
          <div class="space-y-3">
            <%= for item <- @traffic_data do %>
              <div class="flex items-center gap-3">
                <!-- AS Number -->
                <div class="w-32 flex-shrink-0 flex gap-1">
                  <button
                    phx-click="filter_by_as"
                    phx-value-as={item.as_number}
                    class={[
                      "btn btn-xs font-mono flex-1",
                      (@selected_as == item.as_number && "btn-primary") || "btn-ghost"
                    ]}
                    title="Filter BGP view"
                  >
                    AS {item.as_number}
                  </button>
                  <.link
                    navigate={"/observability?tab=netflows&q=#{URI.encode_www_form("as_path contains [#{item.as_number}]")}"}
                    class="btn btn-xs btn-ghost"
                    title="View NetFlow flows"
                  >
                    <.icon name="hero-arrow-top-right-on-square" class="size-3" />
                  </.link>
                </div>
                
    <!-- Traffic Bar -->
                <div class="flex-1">
                  <div class="relative h-6 bg-base-200 rounded overflow-hidden">
                    <div
                      class="absolute inset-y-0 left-0 bg-primary transition-all"
                      style={"width: #{calculate_percentage(item.bytes, @max_bytes)}%"}
                    >
                    </div>
                    <div class="absolute inset-0 flex items-center px-2">
                      <span class="text-xs font-medium text-base-content">
                        {format_bytes(item.bytes)}
                      </span>
                    </div>
                  </div>
                </div>
                
    <!-- Flow Count -->
                <div class="w-20 text-right text-xs text-base-content/60">
                  {item.flow_count} flows
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Top BGP communities with decoded names.
  """
  attr :communities, :list, required: true
  attr :max_bytes, :integer, required: true
  attr :selected_community, :integer, default: nil

  def bgp_top_communities_view(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-200 shadow-sm">
      <div class="card-body">
        <h3 class="card-title text-base">Top BGP Communities</h3>

        <%= if Enum.empty?(@communities) do %>
          <p class="text-sm text-base-content/60">No BGP community data available</p>
        <% else %>
          <div class="space-y-3">
            <%= for item <- @communities do %>
              <div class="flex items-center gap-3">
                <!-- Community Name -->
                <div class="w-32 flex-shrink-0">
                  <button
                    phx-click="filter_by_community"
                    phx-value-community={item.community}
                    class={[
                      "btn btn-xs font-mono",
                      (@selected_community == item.community && "btn-secondary") || "btn-ghost"
                    ]}
                  >
                    {decode_community(item.community)}
                  </button>
                </div>
                
    <!-- Traffic Bar -->
                <div class="flex-1">
                  <div class="relative h-6 bg-base-200 rounded overflow-hidden">
                    <div
                      class="absolute inset-y-0 left-0 bg-secondary transition-all"
                      style={"width: #{calculate_percentage(item.bytes, @max_bytes)}%"}
                    >
                    </div>
                    <div class="absolute inset-0 flex items-center px-2">
                      <span class="text-xs font-medium text-base-content">
                        {format_bytes(item.bytes)}
                      </span>
                    </div>
                  </div>
                </div>
                
    <!-- Flow Count -->
                <div class="w-20 text-right text-xs text-base-content/60">
                  {item.flow_count} flows
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  AS path diversity metrics panel.
  """
  attr :path_diversity, :map, required: true

  def bgp_path_diversity_panel(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-200 shadow-sm">
      <div class="card-body">
        <h3 class="card-title text-base">AS Path Diversity</h3>

        <div class="grid grid-cols-2 gap-4">
          <!-- Unique Paths -->
          <div class="stat bg-base-200 rounded-lg">
            <div class="stat-value text-primary">{@path_diversity.unique_paths}</div>
            <div class="stat-title">Unique Paths</div>
          </div>
          
    <!-- Average Path Length -->
          <div class="stat bg-base-200 rounded-lg">
            <div class="stat-value text-secondary">
              {Float.round(@path_diversity.avg_path_length, 1)}
            </div>
            <div class="stat-title">Avg Hops</div>
          </div>
        </div>
        
    <!-- Hop Distribution -->
        <%= if map_size(@path_diversity.hop_distribution) > 0 do %>
          <div class="mt-4">
            <h4 class="text-sm font-medium text-base-content/70 mb-2">
              Path Length Distribution
            </h4>
            <div class="space-y-2">
              <%= for {hops, count} <- Enum.sort(@path_diversity.hop_distribution) do %>
                <div class="flex items-center gap-2">
                  <span class="text-xs text-base-content/60 w-16">
                    {hops} hops
                  </span>
                  <div class="flex-1 h-4 bg-base-200 rounded overflow-hidden">
                    <div
                      class="h-full bg-success"
                      style={"width: #{calculate_hop_percentage(count, @path_diversity.hop_distribution)}%"}
                    >
                    </div>
                  </div>
                  <span class="text-xs text-base-content/60 w-12 text-right">
                    {count}
                  </span>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  AS topology visualization with SVG graph.
  """
  attr :topology, :list, required: true

  def bgp_topology_visualization(assigns) do
    assigns = assign(assigns, :max_edge_bytes, calculate_max_edge_bytes(assigns.topology))

    ~H"""
    <div class="card bg-base-100 border border-base-200 shadow-sm lg:col-span-2">
      <div class="card-body">
        <h3 class="card-title text-base">AS Topology Graph</h3>

        <%= if Enum.empty?(@topology) do %>
          <p class="text-sm text-base-content/60">No topology data available</p>
        <% else %>
          <div class="overflow-x-auto">
            <svg
              viewBox="0 0 1200 400"
              class="w-full h-auto"
              xmlns="http://www.w3.org/2000/svg"
            >
              <!-- Draw edges (connections between ASes) -->
              <%= for {edge, index} <- Enum.with_index(@topology) do %>
                <% # Calculate positions (simple horizontal layout)
                x1 = 100 + index * 150
                y1 = 200
                x2 = x1 + 100
                y2 = 200
                stroke_width = calculate_edge_width(edge.bytes, @max_edge_bytes) %>
                <!-- Connection line -->
                <line
                  x1={x1}
                  y1={y1}
                  x2={x2}
                  y2={y2}
                  stroke="currentColor"
                  stroke-width={stroke_width}
                  class="text-primary"
                />
                <!-- Arrow head -->
                <polygon
                  points={"#{x2 - 5},#{y2 - 5} #{x2},#{y2} #{x2 - 5},#{y2 + 5}"}
                  fill="currentColor"
                  class="text-primary"
                />
                <!-- Edge label (traffic) -->
                <text
                  x={x1 + 50}
                  y={y1 - 15}
                  text-anchor="middle"
                  class="text-xs fill-base-content/60"
                >
                  {format_bytes(edge.bytes)}
                </text>
              <% end %>
              <!-- Draw nodes (ASes) -->
              <%= for {edge, index} <- Enum.with_index(@topology) do %>
                <% x_from = 100 + index * 150
                x_to = x_from + 100
                y = 200 %>
                <!-- From AS node -->
                <circle
                  cx={x_from}
                  cy={y}
                  r="20"
                  fill="currentColor"
                  class="text-primary"
                />
                <text
                  x={x_from}
                  y={y + 5}
                  text-anchor="middle"
                  class="text-xs font-bold fill-primary-content"
                >
                  {edge.from_as}
                </text>
                <!-- To AS node (only for last edge to avoid duplicates) -->
                <%= if index == length(@topology) - 1 do %>
                  <circle
                    cx={x_to}
                    cy={y}
                    r="20"
                    fill="currentColor"
                    class="text-primary"
                  />
                  <text
                    x={x_to}
                    y={y + 5}
                    text-anchor="middle"
                    class="text-xs font-bold fill-primary-content"
                  >
                    {edge.to_as}
                  </text>
                <% end %>
              <% end %>
            </svg>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Helper functions

  defp calculate_percentage(bytes, max_bytes) when max_bytes > 0 do
    min(100, div(bytes * 100, max_bytes))
  end

  defp calculate_percentage(_, _), do: 0

  defp format_bytes(nil), do: "0 B"
  defp format_bytes(bytes) when not is_number(bytes), do: "0 B"

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_099_511_627_776 ->
        "#{Float.round(bytes / 1_099_511_627_776, 1)} TB"

      bytes >= 1_073_741_824 ->
        "#{Float.round(bytes / 1_073_741_824, 1)} GB"

      bytes >= 1_048_576 ->
        "#{Float.round(bytes / 1_048_576, 1)} MB"

      bytes >= 1024 ->
        "#{Float.round(bytes / 1024, 1)} KB"

      true ->
        "#{bytes} B"
    end
  end

  defp decode_community(community) when is_integer(community) do
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

  defp decode_community(_), do: "Unknown"

  defp calculate_hop_percentage(count, distribution) do
    total = Enum.reduce(distribution, 0, fn {_, c}, acc -> acc + c end)

    if total > 0 do
      min(100, div(count * 100, total))
    else
      0
    end
  end

  defp calculate_max_edge_bytes(topology) do
    case Enum.max_by(topology, & &1.bytes, fn -> %{bytes: 1} end) do
      %{bytes: bytes} -> bytes
      _ -> 1
    end
  end

  defp calculate_edge_width(bytes, max_bytes) when max_bytes > 0 do
    # Scale stroke width between 2 and 8 based on traffic
    min_width = 2
    max_width = 8
    range = max_width - min_width

    width = min_width + div(bytes * range, max_bytes)
    max(min_width, min(max_width, width))
  end

  defp calculate_edge_width(_, _), do: 2

  @doc """
  Data sources panel showing samplers reporting BGP data.
  """
  attr :sources, :list, required: true

  def data_sources_panel(assigns) do
    ~H"""
    <%= if !Enum.empty?(@sources) do %>
      <div class="card bg-base-100 border border-base-200 shadow-sm mb-6">
        <div class="card-body">
          <h3 class="card-title text-base">Data Sources</h3>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Sampler Address</th>
                  <th class="text-right">Observations</th>
                  <th class="text-right">Flows</th>
                  <th class="text-right">Traffic</th>
                </tr>
              </thead>
              <tbody>
                <%= for source <- @sources do %>
                  <tr>
                    <td class="font-mono text-sm">{source.sampler_address}</td>
                    <td class="text-right">{source.observation_count}</td>
                    <td class="text-right">{source.flow_count}</td>
                    <td class="text-right">{format_bytes(source.bytes)}</td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Traffic time series chart.
  """
  attr :timeseries, :map, required: true

  def traffic_timeseries_chart(assigns) do
    ~H"""
    <%= if !Enum.empty?(@timeseries.data) do %>
      <div class="card bg-base-100 border border-base-200 shadow-sm mb-6">
        <div class="card-body">
          <h3 class="card-title text-base">Traffic Over Time (Top ASes)</h3>
          <div
            class="h-64"
            id="timeseries-chart"
            phx-hook="BGPTimeSeriesChart"
            data-series={Jason.encode!(@timeseries.series)}
            data-data={Jason.encode!(@timeseries.data)}
          >
            <!-- Chart will be rendered here by JS hook -->
            <div class="flex items-center justify-center h-full text-base-content/60">
              Chart rendering...
            </div>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  AS Path details table with traffic stats.
  """
  attr :paths, :list, required: true

  def as_path_details_table(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-200 shadow-sm mt-6">
      <div class="card-body">
        <h3 class="card-title text-base">AS Path Details</h3>

        <%= if Enum.empty?(@paths) do %>
          <p class="text-sm text-base-content/60">No AS path data available</p>
        <% else %>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>AS Path</th>
                  <th class="text-center">Length</th>
                  <th class="text-right">Traffic</th>
                  <th class="text-right">Packets</th>
                  <th class="text-right">Flows</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for path <- @paths do %>
                  <tr>
                    <td class="font-mono text-sm">
                      {Enum.join(path.as_path, " → ")}
                    </td>
                    <td class="text-center">
                      <span class="badge badge-sm">{path.path_length}</span>
                    </td>
                    <td class="text-right">{format_bytes(path.bytes)}</td>
                    <td class="text-right">{format_number(path.packets)}</td>
                    <td class="text-right">{path.flow_count}</td>
                    <td>
                      <.link
                        navigate={"/observability?tab=netflows&q=#{build_as_path_filter(path.as_path)}"}
                        class="btn btn-xs btn-ghost"
                      >
                        View Flows →
                      </.link>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Prefix analysis table showing destination prefixes by AS.
  """
  attr :prefixes, :list, required: true

  def prefix_analysis_table(assigns) do
    ~H"""
    <div class="card bg-base-100 border border-base-200 shadow-sm mt-6">
      <div class="card-body">
        <h3 class="card-title text-base">Destination Prefix Analysis</h3>

        <%= if Enum.empty?(@prefixes) do %>
          <p class="text-sm text-base-content/60">No prefix data available</p>
        <% else %>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Prefix</th>
                  <th>AS Number</th>
                  <th class="text-right">Traffic</th>
                  <th class="text-right">Flows</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <%= for prefix <- @prefixes do %>
                  <tr>
                    <td class="font-mono text-sm">{prefix.prefix}</td>
                    <td>
                      <.link
                        navigate={"/observability?tab=netflows&q=as_path+contains+[#{prefix.as_number}]"}
                        class="btn btn-xs btn-ghost font-mono"
                      >
                        AS {prefix.as_number}
                      </.link>
                    </td>
                    <td class="text-right">{format_bytes(prefix.bytes)}</td>
                    <td class="text-right">{prefix.flow_count}</td>
                    <td>
                      <.link
                        navigate={"/observability?tab=netflows&q=dst_ip+in+subnet+#{URI.encode_www_form(prefix.prefix)}"}
                        class="btn btn-xs btn-ghost"
                      >
                        View Flows →
                      </.link>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Helper to format large numbers with commas
  defp format_number(nil), do: "0"

  defp format_number(num) when is_integer(num) do
    num
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  # Helper to build AS path filter for NetFlow
  defp build_as_path_filter(as_path) when is_list(as_path) do
    path_str = Enum.join(as_path, ",")
    URI.encode_www_form("as_path contains [#{path_str}]")
  end
end
