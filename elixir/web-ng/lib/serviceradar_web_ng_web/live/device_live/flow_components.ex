defmodule ServiceRadarWebNGWeb.DeviceLive.FlowComponents do
  @moduledoc false

  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DeviceLive.FlowComponents.Formatters
  import ServiceRadarWebNGWeb.DeviceLive.FlowComponents.Table
  import ServiceRadarWebNGWeb.DeviceLive.FlowComponents.Widgets
  import ServiceRadarWebNGWeb.FlowStatComponents
  # ---------------------------------------------------------------------------
  # Flows Tab Content
  # ---------------------------------------------------------------------------

  attr(:flows, :list, required: true)
  attr(:error, :string, default: nil)
  attr(:pagination, :map, default: %{})
  attr(:pagination_page, :integer, default: 1)
  attr(:rdns_map, :map, default: %{})
  attr(:geo_iso2_map, :map, default: %{})
  attr(:device_uid, :string, required: true)
  attr(:query, :string, required: true)
  attr(:limit, :integer, required: true)
  attr(:flow_stats, :map, default: %{})
  attr(:loading, :boolean, default: false)
  attr(:flow_stats_loading, :boolean, default: true)
  attr(:sparkline_json, :string, default: "[]")
  attr(:proto_json, :string, default: "[]")
  attr(:flow_chart_keys_json, :string, default: "[]")
  attr(:flow_chart_points_json, :string, default: "[]")
  attr(:top_talkers_json, :string, default: "[]")
  attr(:top_destinations_json, :string, default: "[]")
  # §37.3: canonical per-peer ranking (device's peers merged across both
  # directions). Renders as "Top Peers", replacing the direction-split widgets.
  attr(:top_peers_json, :string, default: "[]")
  attr(:top_ports_json, :string, default: "[]")
  attr(:top_protocols_json, :string, default: "[]")
  attr(:facets, :map, default: %{protocols: [], directions: [], services: []})
  attr(:active_facets, :map, default: %{})
  attr(:active_topn, :map, default: nil)
  attr(:zoom_range, :map, default: nil)
  attr(:timezone, :string, required: true)

  def flows_tab_content(assigns) do
    max_bytes =
      assigns.flows
      |> Enum.map(&to_safe_number(Map.get(&1, "bytes_total")))
      |> Enum.max(fn -> 1 end)
      |> max(1)

    max_packets =
      assigns.flows
      |> Enum.map(&to_safe_number(Map.get(&1, "packets_total")))
      |> Enum.max(fn -> 1 end)
      |> max(1)

    assigns =
      assigns
      |> assign(:max_bytes, max_bytes)
      |> assign(:max_packets, max_packets)
      |> assign_new(:total_bw, fn ->
        bytes = Map.get(assigns.flow_stats, :total_bytes, 0)
        format_si(bytes * 8, unit: "bps")
      end)
      |> assign_new(:total_packets, fn ->
        format_si(Map.get(assigns.flow_stats, :total_packets, 0), unit: "pps")
      end)

    ~H"""
    <div class="space-y-4">
      <div :if={@loading} class="rounded-xl border border-sr-line bg-sr-surface p-8 text-center">
        <.ui_spinner size="md" />
        <p class="mt-3 text-sm font-semibold">Loading recent flows</p>
        <p class="mt-1 text-xs text-sr-muted">
          Searching this device's last 24 hours of flow data.
        </p>
      </div>

      <%!-- Stats overview row --%>
      <div :if={!@loading} class="grid grid-cols-2 lg:grid-cols-4 gap-3">
        <.stat_card
          title="Total Bandwidth"
          value={@total_bw}
          loading={@flow_stats_loading}
        >
          <:sparkline>
            <.traffic_sparkline
              id="device-flow-sparkline"
              data_json={@sparkline_json}
              height={28}
            />
          </:sparkline>
        </.stat_card>
        <.stat_card
          title="Total Packets"
          value={@total_packets}
          loading={@flow_stats_loading}
        />
        <.stat_card
          title="Active Flows"
          value={format_si(Map.get(@flow_stats, :flow_count, 0))}
          loading={@flow_stats_loading}
        />
        <.stat_card
          title="Unique Sources"
          value={format_si(Map.get(@flow_stats, :unique_talkers, 0))}
          loading={@flow_stats_loading}
        />
      </div>

      <%!-- Traffic Profile chart --%>
      <div
        :if={@flow_chart_points_json != "[]"}
        class="rounded-xl border border-sr-line bg-sr-surface p-4"
      >
        <div class="flex items-center gap-2 mb-3">
          <.icon name="hero-chart-bar" class="size-4 text-sr-brand" />
          <span class="text-sm font-semibold">Traffic Profile</span>
          <span class="text-xs text-sr-muted">(last 24h · drag to zoom)</span>
        </div>
        <div
          id="device-flow-traffic-profile"
          class="w-full"
          style="height: 220px"
          phx-hook="NetflowStackedAreaChart"
          data-timezone={@timezone}
          data-units="bytes"
          data-keys={@flow_chart_keys_json}
          data-points={@flow_chart_points_json}
          data-colors={Jason.encode!(%{})}
          data-overlays="[]"
          data-zoomable="true"
        >
          <svg class="w-full h-full"></svg>
        </div>
      </div>

      <%!-- Top-N widgets + protocol breakdown share one 4-column row --%>
      <div
        :if={
          @top_peers_json != "[]" or @top_ports_json != "[]" or
            @top_protocols_json != "[]" or @proto_json != "[]"
        }
        class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-3"
      >
        <.top_n_widget
          :if={@top_peers_json != "[]"}
          title="Top Peers"
          icon="hero-user-group"
          items_json={@top_peers_json}
          filter_field="src_endpoint_ip"
        />
        <.top_n_widget
          :if={@top_ports_json != "[]"}
          title="Top Ports"
          icon="hero-hashtag"
          items_json={@top_ports_json}
          filter_field="dst_endpoint_port"
        />
        <.top_n_widget
          :if={@top_protocols_json != "[]"}
          title="Top Protocols"
          icon="hero-signal"
          items_json={@top_protocols_json}
          filter_field="proto"
        />
        <div
          :if={@proto_json != "[]"}
          class="rounded-xl border border-sr-line bg-sr-surface p-4"
        >
          <div class="flex items-center gap-2 mb-3">
            <.icon name="hero-chart-pie" class="size-4 text-sr-brand" />
            <span class="text-sm font-semibold">Protocol Breakdown</span>
            <span class="text-xs text-sr-muted">(last 24h)</span>
          </div>
          <.protocol_breakdown
            id="device-proto-donut"
            data_json={@proto_json}
            height={140}
            chrome={false}
          />
        </div>
      </div>

      <%!-- Quick filters / faceting --%>
      <div
        :if={@facets.protocols != [] or @facets.directions != [] or @facets.services != []}
        class="rounded-xl border border-sr-line bg-sr-surface p-4"
      >
        <div class="flex items-center gap-2 mb-3">
          <.icon name="hero-funnel" class="size-4 text-sr-brand" />
          <span class="text-sm font-semibold">Quick Filters</span>
          <button
            :if={@active_facets != %{}}
            phx-click="facet_clear"
            class="ml-auto text-xs text-error hover:underline"
          >
            Clear all
          </button>
        </div>
        <div class="flex flex-wrap gap-4">
          <.facet_group
            :if={@facets.protocols != []}
            label="Protocol"
            field="proto"
            items={@facets.protocols}
            active_facets={@active_facets}
          />
          <.facet_group
            :if={@facets.directions != []}
            label="Direction"
            field="direction_label"
            items={@facets.directions}
            active_facets={@active_facets}
          />
          <.facet_group
            :if={@facets.services != []}
            label="Service"
            field="dst_service_label"
            items={@facets.services}
            active_facets={@active_facets}
          />
        </div>
      </div>

      <%!-- Active filter indicators --%>
      <div
        :if={@zoom_range}
        class="flex items-center gap-2 px-3 py-2 rounded-lg bg-info/10 border border-info/20 text-sm"
      >
        <.icon name="hero-magnifying-glass-plus-solid" class="size-4 text-info" />
        <span class="text-sr-muted">Zoomed to</span>
        <.ui_badge size="sm" variant="info" class="font-mono">
          <.user_time
            id="device-flow-zoom-start"
            value={@zoom_range.start}
            timezone={@timezone}
            style={:compact}
            fallback={@zoom_range.start}
          />
        </.ui_badge>
        <span class="text-sr-muted">&rarr;</span>
        <.ui_badge size="sm" variant="info" class="font-mono">
          <.user_time
            id="device-flow-zoom-end"
            value={@zoom_range.end}
            timezone={@timezone}
            style={:compact}
            fallback={@zoom_range.end}
          />
        </.ui_badge>
        <.ui_button phx-click="clear_zoom" size="xs" variant="ghost" class="ml-auto text-error">
          <.icon name="hero-x-mark-mini" class="size-3.5" /> Reset
        </.ui_button>
      </div>
      <div
        :if={@active_topn}
        class="flex items-center gap-2 px-3 py-2 rounded-lg bg-sr-brand/10 border border-sr-brand/20 text-sm"
      >
        <.icon name="hero-funnel-solid" class="size-4 text-sr-brand" />
        <span class="text-sr-muted">Filtered by</span>
        <span class="font-semibold">{@active_topn.field}:</span>
        <.ui_badge size="sm" variant="primary">{@active_topn.value}</.ui_badge>
        <.ui_button phx-click="clear_topn_filter" size="xs" variant="ghost" class="ml-auto text-error">
          <.icon name="hero-x-mark-mini" class="size-3.5" /> Clear
        </.ui_button>
      </div>

      <.flow_table
        :if={!@loading}
        flows={@flows}
        error={@error}
        pagination={@pagination}
        pagination_page={@pagination_page}
        rdns_map={@rdns_map}
        geo_iso2_map={@geo_iso2_map}
        device_uid={@device_uid}
        query={@query}
        limit={@limit}
        max_bytes={@max_bytes}
        max_packets={@max_packets}
        timezone={@timezone}
      />
    </div>
    """
  end
end
