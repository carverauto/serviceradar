defmodule ServiceRadarWebNGWeb.NetflowLive.Dashboard do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.FlowStatComponents

  alias ServiceRadar.Observability.IpGeoEnrichmentCache
  alias ServiceRadar.Observability.IpRdnsCache
  alias ServiceRadar.Observability.NetflowInterfaceCache
  alias ServiceRadar.Observability.NetflowLocalCidr


  require Ash.Query
  require Logger

  @refresh_interval_ms :timer.seconds(60)

  @time_windows [
    {"1h", "Last 1 Hour"},
    {"6h", "Last 6 Hours"},
    {"24h", "Last 24 Hours"},
    {"7d", "Last 7 Days"},
    {"30d", "Last 30 Days"}
  ]

  @unit_modes [
    {"bps", "Bits/sec"},
    {"Bps", "Bytes/sec"},
    {"pps", "Packets/sec"}
  ]

  @metric_modes [
    {"bytes", "By Bytes"},
    {"packets", "By Packets"}
  ]

  @top_n 10

  # Well-known port → application name mapping for Top Ports display.
  # Covers the most common services; extend as needed.
  @well_known_ports %{
    "20" => "FTP-Data",
    "21" => "FTP",
    "22" => "SSH",
    "23" => "Telnet",
    "25" => "SMTP",
    "53" => "DNS",
    "67" => "DHCP",
    "68" => "DHCP",
    "80" => "HTTP",
    "110" => "POP3",
    "123" => "NTP",
    "143" => "IMAP",
    "161" => "SNMP",
    "162" => "SNMP-Trap",
    "443" => "HTTPS",
    "465" => "SMTPS",
    "514" => "Syslog",
    "587" => "SMTP-Sub",
    "636" => "LDAPS",
    "993" => "IMAPS",
    "995" => "POP3S",
    "1433" => "MSSQL",
    "1521" => "Oracle",
    "2049" => "NFS",
    "3306" => "MySQL",
    "3389" => "RDP",
    "5432" => "PostgreSQL",
    "5900" => "VNC",
    "6379" => "Redis",
    "8080" => "HTTP-Alt",
    "8443" => "HTTPS-Alt",
    "9200" => "Elasticsearch",
    "27017" => "MongoDB"
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    srql = %{enabled: false, page_path: "/flows"}

    {:ok,
     socket
     |> assign(:page_title, "Flows")
     |> assign(:srql, srql)
     |> assign(:time_window, "1h")
     |> assign(:time_windows, @time_windows)
     |> assign(:unit_mode, "bps")
     |> assign(:unit_modes, @unit_modes)
     |> assign(:loading, true)
     |> assign(:top_talkers, [])
     |> assign(:top_listeners, [])
     |> assign(:top_conversations, [])
     |> assign(:top_apps, [])
     |> assign(:top_protocols, [])
     |> assign(:top_ports, [])
     |> assign(:metric_mode, "bytes")
     |> assign(:metric_modes, @metric_modes)
     |> assign(:total_bytes, 0)
     |> assign(:total_packets, 0)
     |> assign(:active_flows, 0)
     |> assign(:unique_talkers, 0)
     |> assign(:sparkline_json, "[]")
     |> assign(:proto_breakdown_json, "[]")
     |> assign(:top_interfaces, [])
     |> assign(:subnet_distribution, [])
     |> assign(:selected_interface, nil)
     |> assign(:iface_chart_keys_json, "[]")
     |> assign(:iface_chart_points_json, "[]")
     |> assign(:rdns_map, %{})
     |> assign(:geo_iso2_map, %{})
     |> assign(:tcp_flags_json, "[]")
     |> assign(:flow_rate_points_json, "[]")
     |> assign(:duration_dist_json, "[]")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Backward compat: redirect /flows?nf=... to /flows/visualize?nf=...
    if Map.has_key?(params, "nf") do
      qs = URI.encode_query(params)
      {:noreply, push_navigate(socket, to: "/flows/visualize?#{qs}", replace: true)}
    else
      tw = validate_param(Map.get(params, "tw"), @time_windows, socket.assigns.time_window)
      um = validate_param(Map.get(params, "unit"), @unit_modes, socket.assigns.unit_mode)
      mm = validate_param(Map.get(params, "metric"), @metric_modes, socket.assigns.metric_mode)

      socket =
        socket
        |> assign(:time_window, tw)
        |> assign(:unit_mode, um)
        |> assign(:metric_mode, mm)
        |> load_dashboard_stats()

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("change_time_window", %{"tw" => tw}, socket) do
    {:noreply, push_patch(socket, to: ~p"/flows?#{%{tw: tw, unit: socket.assigns.unit_mode, metric: socket.assigns.metric_mode}}")}
  end

  def handle_event("change_unit_mode", %{"unit" => um}, socket) do
    {:noreply, push_patch(socket, to: ~p"/flows?#{%{tw: socket.assigns.time_window, unit: um, metric: socket.assigns.metric_mode}}")}
  end

  def handle_event("change_metric_mode", %{"metric" => mm}, socket) do
    {:noreply, push_patch(socket, to: ~p"/flows?#{%{tw: socket.assigns.time_window, unit: socket.assigns.unit_mode, metric: mm}}")}
  end

  def handle_event("drill_down_talker", %{"row-idx" => idx}, socket) do
    with {:ok, i} <- safe_parse_int(idx),
         row when not is_nil(row) <- Enum.at(socket.assigns.top_talkers, i) do
      {:noreply, drill_down(socket, "src_ip:#{srql_quote(row.ip)}")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("drill_down_listener", %{"row-idx" => idx}, socket) do
    with {:ok, i} <- safe_parse_int(idx),
         row when not is_nil(row) <- Enum.at(socket.assigns.top_listeners, i) do
      {:noreply, drill_down(socket, "dst_ip:#{srql_quote(row.ip)}")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("drill_down_conversation", %{"row-idx" => idx}, socket) do
    with {:ok, i} <- safe_parse_int(idx),
         row when not is_nil(row) <- Enum.at(socket.assigns.top_conversations, i) do
      {:noreply, drill_down(socket, "src_ip:#{srql_quote(row.src_ip)} dst_ip:#{srql_quote(row.dst_ip)}")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("drill_down_app", %{"row-idx" => idx}, socket) do
    with {:ok, i} <- safe_parse_int(idx),
         row when not is_nil(row) <- Enum.at(socket.assigns.top_apps, i) do
      {:noreply, drill_down(socket, "app:#{srql_quote(row.app)}")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("drill_down_protocol", %{"row-idx" => idx}, socket) do
    with {:ok, i} <- safe_parse_int(idx),
         row when not is_nil(row) <- Enum.at(socket.assigns.top_protocols, i) do
      {:noreply, drill_down(socket, "protocol_name:#{srql_quote(row.protocol)}")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("drill_down_port", %{"row-idx" => idx}, socket) do
    with {:ok, i} <- safe_parse_int(idx),
         row when not is_nil(row) <- Enum.at(socket.assigns.top_ports, i) do
      {:noreply, drill_down(socket, "dst_endpoint_port:#{row.port}")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("select_interface", %{"sampler" => ""}, socket) do
    {:noreply,
     socket
     |> assign(:selected_interface, nil)
     |> assign(:iface_chart_keys_json, "[]")
     |> assign(:iface_chart_points_json, "[]")}
  end

  def handle_event("select_interface", %{"sampler" => sampler}, socket) do
    {:noreply,
     socket
     |> assign(:selected_interface, sampler)
     |> load_interface_timeseries(sampler)}
  end

  @impl true
  def handle_info(:refresh_data, socket) do
    schedule_refresh()
    {:noreply, load_dashboard_stats(socket)}
  end

  # --------------------------------------------------------------------------
  # Render
  # --------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="px-4 py-4 space-y-4">
        <%!-- Header with controls --%>
        <div class="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-3">
          <div>
            <h1 class="text-lg font-bold text-base-content">Flow Statistics</h1>
            <p class="text-xs text-base-content/60">Network traffic overview</p>
          </div>

          <div class="flex items-center gap-2">
            <%!-- Time window selector --%>
            <div class="join">
              <button
                :for={{tw, label} <- @time_windows}
                class={["join-item btn btn-xs", tw == @time_window && "btn-active btn-primary"]}
                phx-click="change_time_window"
                phx-value-tw={tw}
              >
                {label}
              </button>
            </div>

            <%!-- Units selector --%>
            <select
              class="select select-xs select-bordered"
              phx-change="change_unit_mode"
              name="unit"
            >
              <option
                :for={{mode, label} <- @unit_modes}
                value={mode}
                selected={mode == @unit_mode}
              >
                {label}
              </option>
            </select>

            <%!-- Metric mode selector --%>
            <select
              class="select select-xs select-bordered"
              phx-change="change_metric_mode"
              name="metric"
            >
              <option
                :for={{mode, label} <- @metric_modes}
                value={mode}
                selected={mode == @metric_mode}
              >
                {label}
              </option>
            </select>

            <%!-- Link to visualize page --%>
            <.link
              navigate={~p"/flows/visualize"}
              class="btn btn-xs btn-ghost gap-1"
            >
              <.icon name="hero-chart-bar-mini" class="w-3.5 h-3.5" />
              Visualize
            </.link>
          </div>
        </div>

        <%!-- Stat cards row --%>
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-3">
          <.stat_card
            title={if @unit_mode == "pps", do: "Total Packets", else: "Total Bandwidth"}
            value={primary_metric(@total_bytes, @total_packets, @unit_mode)}
            unit={unit_suffix(@unit_mode)}
            loading={@loading}
          />
          <.stat_card
            title="Total Packets"
            value={@total_packets}
            unit="pps"
            loading={@loading}
          />
          <.stat_card
            title="Active Flows"
            value={@active_flows}
            loading={@loading}
          />
          <.stat_card
            title="Unique Talkers"
            value={@unique_talkers}
            loading={@loading}
          />
        </div>

        <%!-- Traffic over time sparkline --%>
        <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4">
          <h3 class="text-sm font-semibold text-base-content mb-2">Traffic Over Time</h3>
          <div :if={@loading} class="flex items-center justify-center py-8">
            <span class="loading loading-spinner loading-md"></span>
          </div>
          <.traffic_sparkline
            :if={not @loading}
            id="dashboard-traffic-sparkline"
            data_json={@sparkline_json}
            height={80}
          />
        </div>

        <%!-- Per-interface ingress/egress chart --%>
        <div :if={@top_interfaces != []} class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4">
          <div class="flex items-center justify-between mb-3">
            <div class="flex items-center gap-2">
              <.icon name="hero-arrows-right-left" class="size-4 text-primary" />
              <span class="text-sm font-semibold">Interface Traffic (Ingress vs Egress)</span>
            </div>
            <form phx-change="select_interface">
              <select name="sampler" class="select select-xs select-bordered">
                <option value="">Select interface...</option>
                <option
                  :for={iface <- @top_interfaces}
                  value={iface.sampler}
                  selected={iface.sampler == @selected_interface}
                >
                  {iface.label} ({iface.sampler})
                </option>
              </select>
            </form>
          </div>
          <%= if @selected_interface && @iface_chart_points_json != "[]" do %>
            <div
              id={"iface-ingress-egress-#{@selected_interface}"}
              class="w-full"
              style="height: 220px"
              phx-hook="NetflowStackedAreaChart"
              data-units={@unit_mode}
              data-keys={@iface_chart_keys_json}
              data-points={@iface_chart_points_json}
              data-colors={Jason.encode!(%{"ingress" => "#3b82f6", "egress" => "#f59e0b"})}
              data-overlays="[]"
            >
              <svg class="w-full h-full"></svg>
            </div>
          <% else %>
            <div class="flex items-center justify-center py-8 text-sm text-base-content/50">
              <%= if @selected_interface do %>
                No traffic data for this interface.
              <% else %>
                Select an interface to view ingress/egress traffic.
              <% end %>
            </div>
          <% end %>
        </div>

        <%!-- Top-N tables grid --%>
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
          <.top_n_table
            title="Top Talkers (Source IPs)"
            rows={@top_talkers}
            columns={[
              %{key: :ip, label: "Source IP", format: &format_enriched_ip(&1.ip, @rdns_map, @geo_iso2_map)},
              %{key: :bytes, label: unit_suffix(@unit_mode), format: &format_bytes_cell(&1, @unit_mode)},
              %{key: :packets, label: "Packets"}
            ]}
            on_row_click="drill_down_talker"
            loading={@loading}
          />

          <.top_n_table
            title="Top Listeners (Dest IPs)"
            rows={@top_listeners}
            columns={[
              %{key: :ip, label: "Dest IP", format: &format_enriched_ip(&1.ip, @rdns_map, @geo_iso2_map)},
              %{key: :bytes, label: unit_suffix(@unit_mode), format: &format_bytes_cell(&1, @unit_mode)},
              %{key: :packets, label: "Packets"}
            ]}
            on_row_click="drill_down_listener"
            loading={@loading}
          />

          <.top_n_table
            title="Top Conversations"
            rows={@top_conversations}
            columns={[
              %{key: :src_ip, label: "Source", format: &format_enriched_ip(&1.src_ip, @rdns_map, @geo_iso2_map)},
              %{key: :dst_ip, label: "Dest", format: &format_enriched_ip(&1.dst_ip, @rdns_map, @geo_iso2_map)},
              %{key: :bytes, label: unit_suffix(@unit_mode), format: &format_bytes_cell(&1, @unit_mode)}
            ]}
            on_row_click="drill_down_conversation"
            loading={@loading}
          />

          <.top_n_table
            title="Top Applications"
            rows={@top_apps}
            columns={[
              %{key: :app, label: "Application"},
              %{key: :bytes, label: unit_suffix(@unit_mode), format: &format_bytes_cell(&1, @unit_mode)},
              %{key: :packets, label: "Packets"}
            ]}
            on_row_click="drill_down_app"
            loading={@loading}
          />

          <.top_n_table
            title="Top Protocols"
            rows={@top_protocols}
            columns={[
              %{key: :protocol, label: "Protocol"},
              %{key: :bytes, label: unit_suffix(@unit_mode), format: &format_bytes_cell(&1, @unit_mode)},
              %{key: :packets, label: "Packets"}
            ]}
            on_row_click="drill_down_protocol"
            loading={@loading}
          />

          <.top_n_table
            title="Top Ports (Destination)"
            rows={@top_ports}
            columns={[
              %{key: :port, label: "Port", format: &format_port_cell/1},
              %{key: :bytes, label: unit_suffix(@unit_mode), format: &format_bytes_cell(&1, @unit_mode)},
              %{key: :packets, label: "Packets"}
            ]}
            on_row_click="drill_down_port"
            loading={@loading}
          />

          <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4">
            <h3 class="text-sm font-semibold text-base-content mb-2">Protocol Distribution</h3>
            <div :if={@loading} class="flex items-center justify-center py-8">
              <span class="loading loading-spinner loading-md"></span>
            </div>
            <.protocol_breakdown
              :if={not @loading}
              id="dashboard-proto-breakdown"
              data_json={@proto_breakdown_json}
              height={180}
            />
          </div>

          <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4">
            <h3 class="text-sm font-semibold text-base-content mb-2">TCP Flag Distribution</h3>
            <div :if={@loading} class="flex items-center justify-center py-8">
              <span class="loading loading-spinner loading-md"></span>
            </div>
            <.protocol_breakdown
              :if={not @loading}
              id="dashboard-tcp-flags"
              data_json={@tcp_flags_json}
              height={180}
            />
          </div>

          <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4">
            <h3 class="text-sm font-semibold text-base-content mb-2">Flow Rate (flows/sec)</h3>
            <div :if={@loading} class="flex items-center justify-center py-8">
              <span class="loading loading-spinner loading-md"></span>
            </div>
            <div
              :if={not @loading}
              id="flow-rate-sparkline"
              phx-hook="FlowSparkline"
              data-points={@flow_rate_points_json}
              data-color="oklch(0.65 0.24 150)"
              class="h-[120px] w-full"
            >
              <canvas></canvas>
            </div>
          </div>

          <div class="rounded-xl border border-base-200 bg-base-100 shadow-sm p-4">
            <h3 class="text-sm font-semibold text-base-content mb-2">Flow Duration Distribution</h3>
            <div :if={@loading} class="flex items-center justify-center py-8">
              <span class="loading loading-spinner loading-md"></span>
            </div>
            <.protocol_breakdown
              :if={not @loading}
              id="dashboard-duration-dist"
              data_json={@duration_dist_json}
              height={180}
            />
          </div>
        </div>

        <%!-- Capacity Planning Section --%>
        <div :if={@top_interfaces != [] or @subnet_distribution != []} class="space-y-4">
          <h2 class="text-sm font-bold text-base-content uppercase tracking-wide">Capacity Planning</h2>

          <%!-- Interface bandwidth gauges --%>
          <div :if={@top_interfaces != []} class="grid grid-cols-2 lg:grid-cols-5 gap-3">
            <.bandwidth_gauge
              :for={{iface, idx} <- Enum.with_index(@top_interfaces)}
              :if={iface.capacity_bps > 0}
              id={"iface-gauge-#{idx}"}
              current_bps={iface.bytes / time_window_seconds(@time_window) * 8}
              capacity_bps={iface.capacity_bps * 1.0}
              label={iface.label}
            />
          </div>

          <%!-- Top interfaces table (always shown) --%>
          <.top_n_table
            title="Top Interfaces by Traffic"
            rows={@top_interfaces}
            columns={[
              %{key: :label, label: "Interface"},
              %{key: :sampler, label: "Exporter"},
              %{key: :bytes, label: unit_suffix(@unit_mode), format: &format_bytes_cell(&1, @unit_mode)},
              %{key: :p95_bps, label: "95th % (30d)", format: &format_p95_cell/1},
              %{key: :capacity_bps, label: "Capacity", format: &format_capacity_cell/1}
            ]}
            loading={@loading}
          />

          <%!-- Subnet / VLAN distribution --%>
          <.top_n_table
            :if={@subnet_distribution != []}
            title="Subnet Traffic Distribution"
            rows={@subnet_distribution}
            columns={[
              %{key: :label, label: "Subnet"},
              %{key: :cidr, label: "CIDR"},
              %{key: :bytes, label: unit_suffix(@unit_mode), format: &format_bytes_cell(&1, @unit_mode)}
            ]}
            loading={@loading}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --------------------------------------------------------------------------
  # Data loading
  # --------------------------------------------------------------------------

  defp load_dashboard_stats(socket) do
    tw = socket.assigns.time_window
    mm = socket.assigns.metric_mode
    scope = Map.get(socket.assigns, :current_scope)
    srql_mod = srql_module()
    base = "in:flows time:last_#{tw}"
    sort_field = if mm == "packets", do: "packets_total", else: "bytes_total"

    tasks = [
      Task.async(fn -> {:top_talkers, load_top_n(srql_mod, scope, base, "src_endpoint_ip", sort_field)} end),
      Task.async(fn -> {:top_listeners, load_top_n(srql_mod, scope, base, "dst_endpoint_ip", sort_field)} end),
      Task.async(fn -> {:top_conversations, load_top_conversations(srql_mod, scope, base, sort_field)} end),
      Task.async(fn -> {:top_apps, load_top_n(srql_mod, scope, base, "app", sort_field)} end),
      Task.async(fn -> {:top_protocols, load_top_n(srql_mod, scope, base, "protocol_name", sort_field)} end),
      Task.async(fn -> {:top_ports, load_top_n(srql_mod, scope, base, "dst_endpoint_port", sort_field)} end),
      Task.async(fn -> {:summary, load_summary(srql_mod, scope, base)} end),
      Task.async(fn -> {:timeseries, load_timeseries(srql_mod, scope, base, tw)} end),
      Task.async(fn -> {:top_interfaces, load_top_interfaces(srql_mod, scope, base)} end),
      Task.async(fn -> {:subnet_distribution, load_subnet_distribution(srql_mod, scope, base)} end),
      Task.async(fn -> {:p95, load_interface_p95(srql_mod, scope)} end),
      Task.async(fn -> {:tcp_flags, load_tcp_flag_distribution(srql_mod, scope, base)} end),
      Task.async(fn -> {:flow_rate, load_flow_rate_timeseries(srql_mod, scope, base, tw)} end),
      Task.async(fn -> {:duration_dist, load_duration_distribution(srql_mod, scope, base)} end)
    ]

    results = safe_await_many(tasks, :timer.seconds(15))

    summary = Map.get(results, :summary, %{})
    timeseries = Map.get(results, :timeseries, [])
    top_protocols = Map.get(results, :top_protocols, [])

    proto_breakdown =
      top_protocols
      |> Enum.map(fn row -> %{label: row.protocol || "unknown", value: row.bytes || 0} end)
      |> Jason.encode!()

    sparkline_json =
      timeseries
      |> Enum.map(fn %{t: t, v: v} -> %{t: t, v: v} end)
      |> Jason.encode!()

    tcp_flags_json =
      results
      |> Map.get(:tcp_flags, [])
      |> Enum.map(fn row -> %{label: row.label, value: row.count} end)
      |> Jason.encode!()

    flow_rate_points_json =
      results
      |> Map.get(:flow_rate, [])
      |> Jason.encode!()

    duration_bucket_order = %{"<1s" => 0, "1-10s" => 1, "10-60s" => 2, "1-5m" => 3, ">5m" => 4, "unknown" => 5}

    duration_dist_json =
      results
      |> Map.get(:duration_dist, [])
      |> Enum.sort_by(fn row -> Map.get(duration_bucket_order, row.bucket, 99) end)
      |> Enum.map(fn row -> %{label: row.bucket, value: row.count} end)
      |> Jason.encode!()

    socket
    |> assign(:loading, false)
    |> assign(:top_talkers, Map.get(results, :top_talkers, []))
    |> assign(:top_listeners, Map.get(results, :top_listeners, []))
    |> assign(:top_conversations, Map.get(results, :top_conversations, []))
    |> assign(:top_apps, Map.get(results, :top_apps, []))
    |> assign(:top_protocols, top_protocols)
    |> assign(:top_ports, Map.get(results, :top_ports, []))
    |> assign(:total_bytes, Map.get(summary, :total_bytes, 0))
    |> assign(:total_packets, Map.get(summary, :total_packets, 0))
    |> assign(:active_flows, Map.get(summary, :flow_count, 0))
    |> assign(:unique_talkers, Map.get(summary, :unique_talkers, 0))
    |> assign(:sparkline_json, sparkline_json)
    |> assign(:proto_breakdown_json, proto_breakdown)
    |> assign(:top_interfaces, merge_p95(Map.get(results, :top_interfaces, []), Map.get(results, :p95, %{})))
    |> assign(:subnet_distribution, Map.get(results, :subnet_distribution, []))
    |> assign(:tcp_flags_json, tcp_flags_json)
    |> assign(:flow_rate_points_json, flow_rate_points_json)
    |> assign(:duration_dist_json, duration_dist_json)
    |> maybe_reload_interface_chart()
    |> enrich_top_n_ips()
  end

  defp maybe_reload_interface_chart(%{assigns: %{selected_interface: nil}} = socket), do: socket

  defp maybe_reload_interface_chart(%{assigns: %{selected_interface: sampler}} = socket) do
    load_interface_timeseries(socket, sampler)
  end

  defp load_top_n(srql_mod, scope, base, group_field, sort_field) do
    query =
      "#{base} stats:sum(bytes_total) as bytes_total stats:sum(packets_total) as packets_total by #{group_field} sort:#{sort_field}:desc limit:#{@top_n}"

    case srql_mod.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        Enum.map(results, fn %{"payload" => p} ->
          name = get_field(p, group_field)

          %{
            ip: name,
            app: name,
            protocol: name,
            port: name,
            bytes: to_number(get_field(p, "bytes_total")),
            packets: to_number(get_field(p, "packets_total"))
          }
        end)

      _ ->
        []
    end
  end

  defp load_top_conversations(srql_mod, scope, base, sort_field) do
    query =
      "#{base} stats:sum(bytes_total) as bytes_total stats:sum(packets_total) as packets_total by src_endpoint_ip,dst_endpoint_ip sort:#{sort_field}:desc limit:#{@top_n}"

    case srql_mod.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        Enum.map(results, fn %{"payload" => p} ->
          %{
            src_ip: get_field(p, "src_endpoint_ip"),
            dst_ip: get_field(p, "dst_endpoint_ip"),
            bytes: to_number(get_field(p, "bytes_total")),
            packets: to_number(get_field(p, "packets_total"))
          }
        end)

      _ ->
        []
    end
  end

  defp load_interface_timeseries(socket, sampler) do
    tw = socket.assigns.time_window
    um = socket.assigns.unit_mode
    scope = Map.get(socket.assigns, :current_scope)
    srql_mod = srql_module()
    bucket = timeseries_bucket(tw)
    bucket_secs = bucket_seconds(bucket)
    base = "in:flows time:last_#{tw} sampler_address:#{srql_quote(sampler)}"

    {in_field, out_field} =
      if um == "pps",
        do: {"packets_in", "packets_out"},
        else: {"bytes_in", "bytes_out"}

    tasks = [
      Task.async(fn -> {:ingress, load_iface_downsample(srql_mod, scope, base, bucket, in_field)} end),
      Task.async(fn -> {:egress, load_iface_downsample(srql_mod, scope, base, bucket, out_field)} end)
    ]

    results = safe_await_many(tasks, :timer.seconds(10))
    ingress = Map.get(results, :ingress, [])
    egress = Map.get(results, :egress, [])

    # Convert per-bucket sums to per-second rates.
    # For "bps" mode, also multiply by 8 to convert bytes → bits
    # (nfFormatRateValue expects bits for "bps", bytes for "Bps", packets for "pps").
    rate_factor = if(um == "bps", do: 8, else: 1) / max(bucket_secs, 1)

    to_rate = fn v -> Float.round(v * rate_factor, 2) end

    # Merge into stacked-area chart format: [{t, ingress, egress}, ...]
    egress_map = Map.new(egress, fn %{t: t, v: v} -> {t, to_rate.(v)} end)

    points =
      ingress
      |> Enum.map(fn %{t: t, v: v} ->
        %{"t" => t, "ingress" => to_rate.(v), "egress" => Map.get(egress_map, t, 0)}
      end)
      |> Jason.encode!()

    keys = Jason.encode!(["ingress", "egress"])

    socket
    |> assign(:iface_chart_keys_json, keys)
    |> assign(:iface_chart_points_json, points)
  end

  defp load_iface_downsample(srql_mod, scope, base, bucket, value_field) do
    query = "#{base} bucket:#{bucket} agg:sum value_field:#{value_field}"

    case srql_mod.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        Enum.map(results, fn row ->
          %{
            t: row["timestamp"] || row["bucket"] || row["time_bucket"],
            v: to_number(row["value"] || row[value_field] || 0)
          }
        end)

      _ ->
        []
    end
  end

  defp load_summary(srql_mod, scope, base) do
    queries = [
      {"#{base} stats:sum(bytes_total) as total_bytes", :total_bytes, "total_bytes"},
      {"#{base} stats:sum(packets_total) as total_packets", :total_packets, "total_packets"},
      {"#{base} stats:count(*) as flow_count", :flow_count, "flow_count"},
      {"#{base} stats:count_distinct(src_endpoint_ip) as unique_talkers", :unique_talkers, "unique_talkers"}
    ]

    queries
    |> Enum.map(fn {q, key, field_alias} ->
      Task.async(fn -> {key, query_single_stat(srql_mod, scope, q, field_alias)} end)
    end)
    |> safe_await_many(10_000)
  end

  defp query_single_stat(srql_mod, scope, query, field_alias) do
    case srql_mod.query(query, %{scope: scope}) do
      {:ok, %{"results" => [%{"payload" => p} | _]}} -> to_number(get_field(p, field_alias))
      _ -> 0
    end
  end

  defp load_timeseries(srql_mod, scope, base, tw) do
    bucket = timeseries_bucket(tw)
    query = "#{base} bucket:#{bucket} agg:sum value_field:bytes_total"

    case srql_mod.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        Enum.map(results, fn row ->
          %{
            t: row["timestamp"] || row["bucket"] || row["time_bucket"],
            v: to_number(row["value"] || row["bytes_total"] || 0)
          }
        end)

      _ ->
        []
    end
  end

  defp load_top_interfaces(srql_mod, scope, base) do
    query = "#{base} stats:sum(bytes_total) as bytes_total by sampler_address sort:bytes_total:desc limit:5"

    interface_rows =
      case srql_mod.query(query, %{scope: scope}) do
        {:ok, %{"results" => results}} when is_list(results) ->
          Enum.map(results, fn %{"payload" => p} ->
            %{
              sampler: get_field(p, "sampler_address"),
              bytes: to_number(get_field(p, "bytes_total")),
              packets: 0
            }
          end)

        _ ->
          []
      end

    # Enrich with interface cache for speed/name
    cache_map = load_interface_cache_map(scope)

    Enum.map(interface_rows, fn row ->
      cache_entry = Map.get(cache_map, row.sampler, %{})

      %{
        sampler: row.sampler,
        label: Map.get(cache_entry, :name, row.sampler),
        bytes: row.bytes,
        packets: row.packets,
        capacity_bps: Map.get(cache_entry, :speed_bps, 0)
      }
    end)
  end

  defp load_interface_cache_map(scope) do
    case NetflowInterfaceCache
         |> Ash.Query.for_read(:read)
         |> Ash.read(scope: scope) do
      {:ok, entries} ->
        entries
        |> Enum.group_by(& &1.sampler_address)
        |> Map.new(&best_interface_for_sampler/1)

      _ ->
        %{}
    end
  end

  defp best_interface_for_sampler({sampler, ifaces}) do
    best = Enum.max_by(ifaces, &(&1.if_speed_bps || 0), fn -> hd(ifaces) end)

    {sampler,
     %{
       name: best.if_name || best.if_description || sampler,
       speed_bps: best.if_speed_bps || 0
     }}
  end

  defp load_interface_p95(srql_mod, scope) do
    base_30d = "in:flows time:last_30d"
    query = "#{base_30d} bucket:1h agg:sum value_field:bytes_total series:sampler_address"

    case srql_mod.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        results
        |> Enum.group_by(fn %{"payload" => p} -> get_field(p, "sampler_address") end)
        |> Map.new(&compute_sampler_p95/1)

      _ ->
        %{}
    end
  end

  defp compute_sampler_p95({sampler, rows}) do
    values =
      rows
      |> Enum.map(fn %{"payload" => p} -> to_number(get_field(p, "bytes_total")) end)
      |> Enum.reject(&is_nil/1)

    # Convert bytes/hour to bits/sec: bytes_per_hour * 8 / 3600
    p95_bps = percentile_95(values) * 8 / 3600
    {sampler, p95_bps}
  end

  defp merge_p95(interfaces, p95_map) do
    Enum.map(interfaces, fn iface ->
      Map.put(iface, :p95_bps, Map.get(p95_map, iface.sampler, 0))
    end)
  end

  defp percentile_95([]), do: 0

  defp percentile_95(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    idx = min(n - 1, ceil(0.95 * n) - 1)
    Enum.at(sorted, idx) || 0
  end

  defp load_subnet_distribution(srql_mod, scope, base) do
    cidrs =
      case NetflowLocalCidr
           |> Ash.Query.for_read(:list)
           |> Ash.Query.filter(enabled == true)
           |> Ash.read(scope: scope) do
        {:ok, entries} -> entries
        _ -> []
      end

    if cidrs == [] do
      []
    else
      # Query traffic per local CIDR — run in parallel to avoid sequential round-trips.
      cidrs
      |> Enum.take(10)
      |> Task.async_stream(
        &query_cidr_bytes(&1, srql_mod, scope, base),
        max_concurrency: 5,
        timeout: 15_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, result} -> [result]
        _ -> []
      end)
      |> Enum.sort_by(& &1.bytes, :desc)
    end
  end

  defp query_cidr_bytes(cidr, srql_mod, scope, base) do
    cidr_str = to_string(cidr.cidr)
    query = "#{base} src_cidr:#{srql_quote(cidr_str)} stats:sum(bytes_total) as bytes_total"

    bytes = query_single_stat(srql_mod, scope, query, "bytes_total")

    %{cidr: cidr_str, label: cidr.label || cidr_str, bytes: bytes}
  end

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp load_tcp_flag_distribution(srql_mod, scope, base) do
    query = "#{base} stats:count(*) as count by tcp_flags_label sort:count:desc limit:10"

    case srql_mod.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        Enum.map(results, fn %{"payload" => p} ->
          %{
            label: get_field(p, "tcp_flags_label") || "unknown",
            count: to_number(get_field(p, "count"))
          }
        end)

      _ ->
        []
    end
  end

  defp load_flow_rate_timeseries(srql_mod, scope, base, tw) do
    bucket = timeseries_bucket(tw)
    bucket_secs = bucket_seconds(bucket)
    query = "#{base} bucket:#{bucket} agg:count"

    case srql_mod.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        Enum.map(results, fn row ->
          count = to_number(row["value"] || row["count"] || row["flow_count"] || 0)

          %{
            t: row["timestamp"] || row["bucket"] || row["time_bucket"],
            v: if(bucket_secs > 0, do: Float.round(count / bucket_secs, 2), else: count)
          }
        end)

      _ ->
        []
    end
  end

  defp load_duration_distribution(srql_mod, scope, base) do
    query = "#{base} stats:count(*) as count by duration_bucket"

    case srql_mod.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        Enum.map(results, fn %{"payload" => p} ->
          %{
            bucket: get_field(p, "duration_bucket") || "unknown",
            count: to_number(get_field(p, "count"))
          }
        end)

      _ ->
        []
    end
  end

  defp safe_parse_int(val) when is_integer(val), do: {:ok, val}

  defp safe_parse_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {i, ""} -> {:ok, i}
      _ -> :error
    end
  end

  defp safe_parse_int(_), do: :error

  defp validate_param(nil, _allowed, default), do: default

  defp validate_param(value, allowed, default) do
    if Enum.any?(allowed, fn {k, _} -> k == value end), do: value, else: default
  end

  defp bucket_seconds("1m"), do: 60
  defp bucket_seconds("5m"), do: 300
  defp bucket_seconds("15m"), do: 900
  defp bucket_seconds("1h"), do: 3_600
  defp bucket_seconds("6h"), do: 21_600
  defp bucket_seconds(_), do: 300

  defp time_window_seconds("1h"), do: 3_600
  defp time_window_seconds("6h"), do: 21_600
  defp time_window_seconds("24h"), do: 86_400
  defp time_window_seconds("7d"), do: 604_800
  defp time_window_seconds("30d"), do: 2_592_000
  defp time_window_seconds(_), do: 3_600

  defp timeseries_bucket("1h"), do: "1m"
  defp timeseries_bucket("6h"), do: "5m"
  defp timeseries_bucket("24h"), do: "15m"
  defp timeseries_bucket("7d"), do: "1h"
  defp timeseries_bucket("30d"), do: "6h"
  defp timeseries_bucket(_), do: "5m"

  defp drill_down(socket, filter) do
    q = "in:flows time:last_#{socket.assigns.time_window} #{filter}"
    push_navigate(socket, to: ~p"/flows/visualize?#{%{q: q}}")
  end

  # Escape a value for safe interpolation into an SRQL filter expression.
  # Wraps in double quotes and escapes any internal backslashes/double quotes.
  defp srql_quote(value) when is_binary(value) do
    escaped = value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"#{escaped}\""
  end

  defp srql_quote(value), do: srql_quote(to_string(value))

  defp primary_metric(_bytes, packets, "pps"), do: packets
  defp primary_metric(bytes, _packets, "bps"), do: bytes * 8
  defp primary_metric(bytes, _packets, _mode), do: bytes

  defp display_bandwidth(total_bytes, "bps"), do: total_bytes * 8
  defp display_bandwidth(total_bytes, _mode), do: total_bytes

  defp unit_suffix("bps"), do: "bps"
  defp unit_suffix("Bps"), do: "B/s"
  defp unit_suffix("pps"), do: "pps"
  defp unit_suffix(_), do: ""

  defp format_port_cell(row) do
    port = to_string(row.port)
    app = Map.get(@well_known_ports, port)

    if app do
      Phoenix.HTML.raw(
        "#{Phoenix.HTML.html_escape(port) |> Phoenix.HTML.safe_to_string()}" <>
          " <span class=\"text-xs text-base-content/50\">(#{Phoenix.HTML.html_escape(app) |> Phoenix.HTML.safe_to_string()})</span>"
      )
    else
      port
    end
  end

  defp format_p95_cell(row) do
    p95 = Map.get(row, :p95_bps, 0)
    if p95 > 0, do: format_si(p95 * 1.0, unit: "bps"), else: "—"
  end

  defp format_capacity_cell(row) do
    cap = row.capacity_bps || 0
    if cap > 0, do: format_si(cap * 1.0, unit: "bps"), else: "N/A"
  end

  defp format_bytes_cell(row, "pps") do
    val = row.packets || 0
    ServiceRadarWebNGWeb.FlowStatComponents.format_si(val, unit: "pps")
  end

  defp format_bytes_cell(row, unit_mode) do
    val = display_bandwidth(row.bytes || 0, unit_mode)
    ServiceRadarWebNGWeb.FlowStatComponents.format_si(val, unit: unit_suffix(unit_mode))
  end

  defp get_field(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(payload, key)
  end

  defp to_number(nil), do: 0
  defp to_number(n) when is_number(n), do: n

  defp to_number(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0
    end
  end

  defp to_number(_), do: 0

  defp safe_await_many(tasks, timeout) do
    tasks
    |> Task.yield_many(timeout)
    |> Enum.map(fn {task, result} ->
      case result do
        {:ok, {key, value}} when is_atom(key) -> {key, value}
        {:ok, _unexpected} -> nil
        _ ->
          Task.shutdown(task, :brutal_kill)
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh_data, @refresh_interval_ms)
  end

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  # ---------------------------------------------------------------------------
  # IP enrichment (reads from pre-populated DB caches, no live lookups)
  # ---------------------------------------------------------------------------

  defp enrich_top_n_ips(socket) do
    scope = Map.get(socket.assigns, :current_scope)

    ips =
      Enum.concat([
        Enum.map(socket.assigns.top_talkers, & &1.ip),
        Enum.map(socket.assigns.top_listeners, & &1.ip),
        Enum.flat_map(socket.assigns.top_conversations, fn r -> [r.src_ip, r.dst_ip] end)
      ])
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if ips == [] do
      socket
      |> assign(:rdns_map, %{})
      |> assign(:geo_iso2_map, %{})
    else
      tasks = [
        Task.async(fn -> {:rdns, bulk_rdns(ips, scope)} end),
        Task.async(fn -> {:geo, bulk_geo_iso2(ips, scope)} end)
      ]

      results = safe_await_many(tasks, :timer.seconds(5))

      socket
      |> assign(:rdns_map, Map.get(results, :rdns, %{}))
      |> assign(:geo_iso2_map, Map.get(results, :geo, %{}))
    end
  end

  defp bulk_rdns(ips, scope) do
    query =
      IpRdnsCache
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(ip in ^ips)

    case Ash.read(query, scope: scope) do
      {:ok, rows} when is_list(rows) ->
        rows
        |> Enum.filter(fn r -> r.status == "ok" and is_binary(r.hostname) and String.trim(r.hostname) != "" end)
        |> Map.new(fn r -> {r.ip, r.hostname} end)

      _ ->
        %{}
    end
  end

  defp bulk_geo_iso2(ips, scope) do
    query =
      IpGeoEnrichmentCache
      |> Ash.Query.for_read(:read, %{})
      |> Ash.Query.filter(ip in ^ips)

    case Ash.read(query, scope: scope) do
      {:ok, rows} when is_list(rows) ->
        rows
        |> Enum.filter(fn r -> is_binary(r.country_iso2) and String.length(String.trim(r.country_iso2)) == 2 end)
        |> Map.new(fn r -> {r.ip, String.upcase(String.trim(r.country_iso2))} end)

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp iso2_flag_emoji(nil), do: nil

  defp iso2_flag_emoji(iso2) when is_binary(iso2) do
    iso2 = iso2 |> String.trim() |> String.upcase()

    if String.length(iso2) == 2 do
      <<a::utf8, b::utf8>> = iso2

      if a in ?A..?Z and b in ?A..?Z do
        <<0x1F1E6 + (a - ?A)::utf8, 0x1F1E6 + (b - ?A)::utf8>>
      end
    end
  end

  defp iso2_flag_emoji(_), do: nil

  defp format_enriched_ip(ip, rdns_map, geo_iso2_map) do
    flag = iso2_flag_emoji(Map.get(geo_iso2_map, ip))
    hostname = Map.get(rdns_map, ip)

    parts = [flag, ip] |> Enum.reject(&is_nil/1) |> Enum.join(" ")

    if hostname do
      Phoenix.HTML.raw(
        "<span>#{Phoenix.HTML.html_escape(parts) |> Phoenix.HTML.safe_to_string()}" <>
          "<br/><span class=\"text-xs text-base-content/50\">#{Phoenix.HTML.html_escape(hostname) |> Phoenix.HTML.safe_to_string()}</span></span>"
      )
    else
      parts
    end
  end
end
