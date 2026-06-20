defmodule ServiceRadarWebNGWeb.NetflowLive.Dashboard do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.FlowStatComponents

  alias ServiceRadar.Observability.IpGeoEnrichmentCache
  alias ServiceRadar.Observability.IpRdnsCache
  alias ServiceRadar.Observability.NetflowLocalCidr
  alias ServiceRadar.ReferenceData.ServicePorts
  alias ServiceRadarWebNGWeb.NetFlow.EnrichmentExpiry
  alias ServiceRadarWebNGWeb.NetFlow.InterfaceSeries

  require Ash.Query
  require Logger

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  @refresh_interval_ms to_timeout(minute: 1)

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

  @sections [
    {"overview", "Overview"},
    {"topn", "Top Lists"},
    {"traffic", "Traffic"},
    {"capacity", "Interfaces"},
    {"all", "Show All"}
  ]

  @top_n 10

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
     |> assign(:section, "overview")
     |> assign(:sections, @sections)
     |> assign(:query, nil)
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
    tw = validate_param(Map.get(params, "tw"), @time_windows, socket.assigns.time_window)
    um = validate_param(Map.get(params, "unit"), @unit_modes, socket.assigns.unit_mode)
    mm = validate_param(Map.get(params, "metric"), @metric_modes, socket.assigns.metric_mode)
    section = validate_param(Map.get(params, "section"), @sections, socket.assigns.section)
    query = normalize_optional_query(Map.get(params, "q"))

    socket =
      socket
      |> assign(:time_window, tw)
      |> assign(:unit_mode, um)
      |> assign(:metric_mode, mm)
      |> assign(:section, section)
      |> assign(:query, query)
      |> load_dashboard_stats()

    {:noreply, socket}
  end

  @impl true
  def handle_event("change_time_window", %{"tw" => tw}, socket) do
    {:noreply, push_patch(socket, to: ~p"/flows?#{patch_params(socket, %{tw: tw})}")}
  end

  def handle_event("change_unit_mode", %{"unit" => um}, socket) do
    {:noreply, push_patch(socket, to: ~p"/flows?#{patch_params(socket, %{unit: um})}")}
  end

  def handle_event("change_metric_mode", %{"metric" => mm}, socket) do
    {:noreply, push_patch(socket, to: ~p"/flows?#{patch_params(socket, %{metric: mm})}")}
  end

  def handle_event("change_section", %{"section" => section}, socket) do
    section = validate_param(section, @sections, socket.assigns.section)

    {:noreply, push_patch(socket, to: ~p"/flows?#{patch_params(socket, %{section: section})}")}
  end

  def handle_event("clear_query", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/flows?#{patch_params(socket, %{q: nil})}")}
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
      {:noreply, drill_down(socket, bidirectional_conversation_filter(row))}
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
         row when not is_nil(row) <- Enum.at(socket.assigns.top_ports, i),
         port when not is_nil(port) <- row.port,
         {:ok, port_int} <- safe_parse_int(to_string(port)),
         true <- port_int > 0 do
      {:noreply, drill_down(socket, "dst_endpoint_port:#{srql_quote(to_string(port_int))}")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("select_interface", params, socket) do
    selected = Map.get(params, "interface") || Map.get(params, "sampler") || ""

    if selected == "" do
      {:noreply,
       socket
       |> assign(:selected_interface, nil)
       |> assign(:iface_chart_keys_json, "[]")
       |> assign(:iface_chart_points_json, "[]")}
    else
      {:noreply,
       socket
       |> assign(:selected_interface, selected)
       |> load_interface_timeseries(selected)}
    end
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
            <form phx-change="change_unit_mode">
              <select
                class="select select-xs select-bordered"
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
            </form>

            <%!-- Metric mode selector --%>
            <form phx-change="change_metric_mode">
              <select
                class="select select-xs select-bordered"
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
            </form>
          </div>
        </div>

        <div :if={@query} class="alert alert-info py-2 px-3 text-xs">
          <.icon name="hero-funnel-mini" class="w-4 h-4 shrink-0" />
          <span class="truncate">
            Active flow filter: <code class="font-mono">{@query}</code>
          </span>
          <button class="btn btn-ghost btn-xs" phx-click="clear_query">Clear</button>
        </div>

        <div class="flex flex-wrap gap-2">
          <button
            :for={{section_key, section_label} <- @sections}
            class={[
              "btn btn-xs",
              if(@section == section_key, do: "btn-primary", else: "btn-outline")
            ]}
            phx-click="change_section"
            phx-value-section={section_key}
          >
            {section_label}
          </button>
        </div>

        <%!-- Overview section --%>
        <div :if={section_visible?(@section, "overview")} class="space-y-4">
          <div class="grid grid-cols-2 lg:grid-cols-4 gap-3">
            <.stat_card
              title={if @unit_mode == "pps", do: "Average Packet Rate", else: "Average Bandwidth"}
              value={primary_metric(@total_bytes, @total_packets, @unit_mode, @time_window)}
              unit={unit_suffix(@unit_mode)}
              loading={@loading}
            />
            <.stat_card
              title="Total Packets"
              value={@total_packets}
              unit="pkts"
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
          <div class="rounded-xl border border-base-200 bg-base-100 p-4">
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
        </div>

        <%!-- Per-interface ingress/egress chart --%>
        <div
          :if={section_visible?(@section, "traffic") and @top_interfaces != []}
          class="rounded-xl border border-base-200 bg-base-100 p-4"
        >
          <div class="flex items-center justify-between mb-3">
            <div class="flex items-center gap-2">
              <.icon name="hero-arrows-right-left" class="size-4 text-primary" />
              <span class="text-sm font-semibold">Interface Traffic (Ingress vs Egress)</span>
            </div>
            <form phx-change="select_interface">
              <select name="interface" class="select select-xs select-bordered">
                <option value="">Select interface...</option>
                <option
                  :for={iface <- @top_interfaces}
                  value={iface.key}
                  selected={iface.key == @selected_interface}
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

        <%!-- Top-N and chart panels --%>
        <div
          :if={section_visible?(@section, "topn") or section_visible?(@section, "traffic")}
          class="grid grid-cols-1 lg:grid-cols-2 gap-4"
        >
          <.top_n_table
            :if={section_visible?(@section, "topn")}
            title="Top Talkers (Source IPs)"
            rows={@top_talkers}
            columns={[
              %{
                key: :ip,
                label: "Source IP",
                format: &format_enriched_ip(&1.ip, @rdns_map, @geo_iso2_map)
              },
              %{
                key: :bytes,
                label: primary_metric_col_label(@unit_mode, @metric_mode),
                format: &format_primary_cell(&1, @unit_mode, @metric_mode, @time_window)
              },
              %{key: :packets, label: "Packets"}
            ]}
            on_row_click="drill_down_talker"
            loading={@loading}
          />

          <.top_n_table
            :if={section_visible?(@section, "topn")}
            title="Top Listeners (Dest IPs)"
            rows={@top_listeners}
            columns={[
              %{
                key: :ip,
                label: "Dest IP",
                format: &format_enriched_ip(&1.ip, @rdns_map, @geo_iso2_map)
              },
              %{
                key: :bytes,
                label: primary_metric_col_label(@unit_mode, @metric_mode),
                format: &format_primary_cell(&1, @unit_mode, @metric_mode, @time_window)
              },
              %{key: :packets, label: "Packets"}
            ]}
            on_row_click="drill_down_listener"
            loading={@loading}
          />

          <.top_n_table
            :if={section_visible?(@section, "topn")}
            title="Top Conversations"
            rows={@top_conversations}
            columns={[
              %{
                key: :src_ip,
                label: "Source",
                format: &format_enriched_ip(&1.src_ip, @rdns_map, @geo_iso2_map)
              },
              %{
                key: :dst_ip,
                label: "Dest",
                format: &format_enriched_ip(&1.dst_ip, @rdns_map, @geo_iso2_map)
              },
              %{
                key: :bytes,
                label: primary_metric_col_label(@unit_mode, @metric_mode),
                format: &format_primary_cell(&1, @unit_mode, @metric_mode, @time_window)
              }
            ]}
            on_row_click="drill_down_conversation"
            loading={@loading}
          />

          <.top_n_table
            :if={section_visible?(@section, "topn")}
            title="Top Applications"
            rows={@top_apps}
            columns={[
              %{key: :app, label: "Application"},
              %{
                key: :bytes,
                label: primary_metric_col_label(@unit_mode, @metric_mode),
                format: &format_primary_cell(&1, @unit_mode, @metric_mode, @time_window)
              },
              %{key: :packets, label: "Packets"}
            ]}
            on_row_click="drill_down_app"
            loading={@loading}
          />

          <.top_n_table
            :if={section_visible?(@section, "topn")}
            title="Top Protocols"
            rows={@top_protocols}
            columns={[
              %{key: :protocol, label: "Protocol"},
              %{
                key: :bytes,
                label: primary_metric_col_label(@unit_mode, @metric_mode),
                format: &format_primary_cell(&1, @unit_mode, @metric_mode, @time_window)
              },
              %{key: :packets, label: "Packets"}
            ]}
            on_row_click="drill_down_protocol"
            loading={@loading}
          />

          <.top_n_table
            :if={section_visible?(@section, "topn")}
            title="Top Ports (Destination)"
            rows={@top_ports}
            columns={[
              %{key: :port, label: "Port", format: &format_port_cell/1},
              %{
                key: :bytes,
                label: primary_metric_col_label(@unit_mode, @metric_mode),
                format: &format_primary_cell(&1, @unit_mode, @metric_mode, @time_window)
              },
              %{key: :packets, label: "Packets"}
            ]}
            on_row_click="drill_down_port"
            loading={@loading}
          />

          <div
            :if={section_visible?(@section, "traffic")}
            class="rounded-xl border border-base-200 bg-base-100 p-4"
          >
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

          <div
            :if={section_visible?(@section, "traffic")}
            class="rounded-xl border border-base-200 bg-base-100 p-4"
          >
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

          <div
            :if={section_visible?(@section, "traffic")}
            class="rounded-xl border border-base-200 bg-base-100 p-4"
          >
            <h3 class="text-sm font-semibold text-base-content mb-2">Flow Rate (flows/sec)</h3>
            <div :if={@loading} class="flex items-center justify-center py-8">
              <span class="loading loading-spinner loading-md"></span>
            </div>
            <div
              :if={not @loading}
              id="flow-rate-chart"
              phx-hook="FlowRateChart"
              data-points={@flow_rate_points_json}
              data-color="oklch(0.65 0.24 150)"
              class="h-[180px] w-full"
            >
              <canvas></canvas>
            </div>
          </div>

          <div
            :if={section_visible?(@section, "traffic")}
            class="rounded-xl border border-base-200 bg-base-100 p-4"
          >
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

        <%!-- Interface utilization section --%>
        <div
          :if={
            section_visible?(@section, "capacity") and
              (@top_interfaces != [] or @subnet_distribution != [])
          }
          class="space-y-4"
        >
          <h2 class="text-sm font-bold text-base-content uppercase tracking-wide">
            Interface Utilization
          </h2>

          <%!-- Interface bandwidth gauges --%>
          <div :if={@top_interfaces != []} class="grid grid-cols-2 lg:grid-cols-5 gap-3">
            <.bandwidth_gauge
              :for={{iface, idx} <- Enum.with_index(@top_interfaces)}
              :if={iface.capacity_bps > 0}
              id={"iface-gauge-#{idx}"}
              current_bps={Map.get(iface, :gauge_bytes, 0) / time_window_seconds(@time_window) * 8}
              capacity_bps={iface.capacity_bps * 1.0}
              label={iface.label}
              current_label={"Avg #{@time_window}"}
            />
          </div>

          <%!-- Top interfaces table (always shown) --%>
          <.top_n_table
            title="Top Interfaces by Traffic"
            rows={@top_interfaces}
            columns={[
              %{key: :label, label: "Interface"},
              %{key: :sampler, label: "Exporter"},
              %{
                key: :bytes,
                label: unit_suffix(@unit_mode),
                format: &format_bytes_cell(&1, @unit_mode, @time_window)
              },
              %{key: :p95_bps, label: "P95 Rate (#{@time_window})", format: &format_p95_cell/1},
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
              %{
                key: :bytes,
                label: unit_suffix(@unit_mode),
                format: &format_bytes_cell(&1, @unit_mode, @time_window)
              }
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
    task_sup = ServiceRadarWebNG.TaskSupervisor
    base = base_flow_query(socket.assigns.query, tw)
    sort_field = if mm == "packets", do: "packets_total", else: "bytes_total"

    tasks = [
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:top_talkers, load_top_n(srql_mod, scope, base, "src_endpoint_ip", sort_field)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:top_listeners, load_top_n(srql_mod, scope, base, "dst_endpoint_ip", sort_field)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:top_conversations, load_top_conversations(srql_mod, scope, base, sort_field)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:top_apps, load_top_n(srql_mod, scope, base, "app", sort_field)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:top_protocols, load_top_n(srql_mod, scope, base, "protocol_name", sort_field)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:top_ports, load_top_n(srql_mod, scope, base, "dst_endpoint_port", sort_field)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:summary, load_summary(srql_mod, scope, base)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:timeseries, load_timeseries(srql_mod, scope, base, tw)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:top_interfaces, load_top_interfaces(srql_mod, scope, base)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:subnet_distribution, load_subnet_distribution(srql_mod, scope, base)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:tcp_flags, load_tcp_flag_distribution(srql_mod, scope, base)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:flow_rate, load_flow_rate_timeseries(srql_mod, scope, base, tw)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:duration_dist, load_duration_distribution(srql_mod, scope, base)}
      end)
    ]

    results = safe_await_many(tasks, to_timeout(second: 15))

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

    duration_bucket_order = %{
      "<1s" => 0,
      "1-10s" => 1,
      "10-60s" => 2,
      "1-5m" => 3,
      ">5m" => 4,
      "unknown" => 5
    }

    duration_dist_json =
      results
      |> Map.get(:duration_dist, [])
      |> Enum.sort_by(fn row -> Map.get(duration_bucket_order, row.bucket, 99) end)
      |> Enum.map(fn row -> %{label: row.bucket, value: row.count} end)
      |> Jason.encode!()

    top_interfaces =
      results
      |> Map.get(:top_interfaces, [])
      |> attach_interface_p95(srql_mod, scope, tw)

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
    |> assign(:top_interfaces, top_interfaces)
    |> assign(:subnet_distribution, Map.get(results, :subnet_distribution, []))
    |> assign(:tcp_flags_json, tcp_flags_json)
    |> assign(:flow_rate_points_json, flow_rate_points_json)
    |> assign(:duration_dist_json, duration_dist_json)
    |> ensure_selected_interface()
    |> maybe_reload_interface_chart()
    |> enrich_top_n_ips()
  end

  defp ensure_selected_interface(%{assigns: %{top_interfaces: []}} = socket), do: assign(socket, :selected_interface, nil)

  defp ensure_selected_interface(%{assigns: %{selected_interface: selected, top_interfaces: top_interfaces}} = socket) do
    keys = MapSet.new(top_interfaces, & &1.key)

    if is_binary(selected) and MapSet.member?(keys, selected) do
      socket
    else
      assign(socket, :selected_interface, top_interfaces |> List.first() |> Map.get(:key))
    end
  end

  defp section_visible?("all", _section), do: true
  defp section_visible?(current, section), do: current == section

  defp maybe_reload_interface_chart(%{assigns: %{selected_interface: nil}} = socket), do: socket

  defp maybe_reload_interface_chart(%{assigns: %{selected_interface: sampler}} = socket) do
    load_interface_timeseries(socket, sampler)
  end

  defp load_top_n(srql_mod, scope, base, group_field, sort_field) do
    query =
      "#{base} stats:sum(bytes_total) as bytes_total stats:sum(packets_total) as packets_total by #{group_field} sort:#{sort_field}:desc limit:#{@top_n}"

    srql_mod
    |> srql_results(query, scope)
    |> Enum.map(fn row ->
      p = row_payload(row)
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
  end

  defp load_top_conversations(srql_mod, scope, base, sort_field) do
    query =
      "#{base} stats:sum(bytes_total) as bytes_total stats:sum(packets_total) as packets_total by conversation_a_ip,conversation_b_ip sort:#{sort_field}:desc limit:#{@top_n}"

    srql_mod
    |> srql_results(query, scope)
    |> Enum.map(fn row ->
      p = row_payload(row)

      %{
        src_ip: get_field(p, "conversation_a_ip"),
        dst_ip: get_field(p, "conversation_b_ip"),
        bytes: to_number(get_field(p, "bytes_total")),
        packets: to_number(get_field(p, "packets_total"))
      }
    end)
  end

  defp bidirectional_conversation_filter(%{src_ip: src_ip, dst_ip: dst_ip}) do
    endpoints =
      [src_ip, dst_ip]
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or &1 == "Unknown"))
      |> Enum.uniq()

    case endpoints do
      [one] ->
        quoted = srql_quote(one)
        "src_ip:#{quoted} dst_ip:#{quoted}"

      [a, b | _] ->
        list = "#{srql_quote(a)},#{srql_quote(b)}"
        "src_ip:(#{list}) dst_ip:(#{list})"

      _ ->
        ""
    end
  end

  defp load_interface_timeseries(socket, interface_key) do
    tw = socket.assigns.time_window
    um = socket.assigns.unit_mode
    scope = Map.get(socket.assigns, :current_scope)
    srql_mod = srql_module()
    bucket = timeseries_bucket(tw)
    bucket_secs = bucket_seconds(bucket)
    limit = interface_downsample_limit(tw, bucket_secs, 2)

    case decode_interface_key(interface_key) do
      {:ok, sampler, interface_name} ->
        base = "in:flows time:last_#{tw} sampler_address:#{srql_quote(sampler)}"
        value_field = if(um == "pps", do: "packets_total", else: "bytes_total")

        {ingress, egress} =
          srql_mod
          |> load_interface_direction_points(scope, base, interface_name, bucket, value_field, limit)
          |> split_interface_direction_points()

        points =
          ingress
          |> interface_direction_points(egress, bucket_secs, um)
          |> Jason.encode!()

        keys = Jason.encode!(["ingress", "egress"])

        socket
        |> assign(:iface_chart_keys_json, keys)
        |> assign(:iface_chart_points_json, points)

      _ ->
        socket
        |> assign(:selected_interface, nil)
        |> assign(:iface_chart_keys_json, "[]")
        |> assign(:iface_chart_points_json, "[]")
    end
  end

  defp load_interface_direction_points(srql_mod, scope, base, interface_name, bucket, value_field, limit) do
    query =
      "#{base} interface:#{srql_quote(interface_name)} bucket:#{bucket} agg:sum " <>
        "value_field:#{value_field} series:interface limit:#{limit}"

    srql_mod
    |> srql_results(query, scope)
    |> Enum.map(&interface_direction_point/1)
    |> Enum.filter(& &1)
  end

  defp split_interface_direction_points(rows) do
    rows
    |> Enum.group_by(&Map.get(&1, :direction))
    |> then(fn grouped -> {Map.get(grouped, :ingress, []), Map.get(grouped, :egress, [])} end)
  end

  defp interface_direction_points(ingress, egress, bucket_secs, unit_mode) do
    rate_factor = if(unit_mode == "bps", do: 8, else: 1) / max(bucket_secs, 1)
    to_rate = fn v -> Float.round(v * rate_factor, 2) end

    ingress_map = Map.new(ingress, fn %{t: t, v: v} -> {t, to_rate.(v)} end)
    egress_map = Map.new(egress, fn %{t: t, v: v} -> {t, to_rate.(v)} end)

    ingress_map
    |> Map.keys()
    |> Enum.concat(Map.keys(egress_map))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn t ->
      %{
        "t" => t,
        "ingress" => Map.get(ingress_map, t, 0),
        "egress" => Map.get(egress_map, t, 0)
      }
    end)
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
    srql_mod
    |> srql_results(query, scope)
    |> List.first()
    |> row_payload()
    |> get_field(field_alias)
    |> to_number()
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
    query =
      "#{base} stats:sum(bytes_total) as bytes_total by sampler_address,interface,if_speed_bps " <>
        "sort:bytes_total:desc limit:#{@top_n * 2}"

    srql_mod
    |> srql_results(query, scope)
    |> Enum.map(&top_interface_row/1)
    |> Enum.filter(& &1)
    |> Enum.reduce(%{}, &merge_interface_direction_row/2)
    |> Map.values()
    |> Enum.map(&finalize_interface_row/1)
    |> Enum.sort_by(&(-Map.get(&1, :bytes, 0)))
    |> Enum.take(5)
  end

  defp top_interface_row(row) do
    p = row_payload(row)
    sampler = get_field(p, "sampler_address")
    interface_name = p |> get_field("interface") |> normalize_interface_name()

    with true <- is_binary(sampler) and String.trim(sampler) != "",
         true <- is_binary(interface_name) and interface_name != "",
         {:ok, direction} <- normalize_if_direction(get_field(p, "if_direction")) do
      %{
        sampler: sampler,
        interface_name: interface_name,
        direction: direction,
        bytes: to_number(get_field(p, "bytes_total")),
        capacity_bps: p |> get_field("if_speed_bps") |> to_number() |> trunc()
      }
    else
      _ -> nil
    end
  end

  defp merge_interface_direction_row(row, acc) do
    key = {row.sampler, row.interface_name}

    Map.update(acc, key, row_to_interface_acc(row), fn existing ->
      direction_key = if(row.direction == :ingress, do: :ingress_bytes, else: :egress_bytes)

      existing
      |> Map.update!(:bytes, &(&1 + row.bytes))
      |> Map.update!(direction_key, &(&1 + row.bytes))
      |> Map.update!(:capacity_bps, &max(&1, row.capacity_bps))
    end)
  end

  defp row_to_interface_acc(row) do
    %{
      sampler: row.sampler,
      interface_name: row.interface_name,
      label: interface_label(row.interface_name),
      bytes: row.bytes,
      ingress_bytes: if(row.direction == :ingress, do: row.bytes, else: 0),
      egress_bytes: if(row.direction == :egress, do: row.bytes, else: 0),
      capacity_bps: row.capacity_bps,
      p95_bps: 0
    }
  end

  defp finalize_interface_row(row) do
    row
    |> Map.put(:key, interface_key(row.sampler, row.interface_name))
    |> Map.put(:gauge_bytes, max(row.ingress_bytes, row.egress_bytes))
  end

  defp attach_interface_p95([], _srql_mod, _scope, _tw), do: []

  defp attach_interface_p95(interfaces, srql_mod, scope, tw) do
    p95_by_interface = load_interfaces_p95(srql_mod, scope, tw, interfaces)

    Enum.map(interfaces, fn iface ->
      p95 = Map.get(p95_by_interface, {Map.get(iface, :sampler), Map.get(iface, :interface_name)}, 0)
      Map.put(iface, :p95_bps, p95)
    end)
  end

  defp load_interfaces_p95(srql_mod, scope, tw, interfaces) do
    bucket = timeseries_bucket(tw)
    bucket_secs = bucket_seconds(bucket)
    limit = interface_downsample_limit(tw, bucket_secs, length(interfaces) * 2)

    tasks =
      interfaces
      |> Enum.group_by(&Map.get(&1, :sampler))
      |> Enum.reject(fn {sampler, rows} -> not is_binary(sampler) or String.trim(sampler) == "" or rows == [] end)
      |> Enum.flat_map(fn {sampler, rows} ->
        interface_names =
          rows
          |> Enum.map(&Map.get(&1, :interface_name))
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        if interface_names == [] do
          []
        else
          [
            Task.async(fn ->
              load_interface_p95_points(srql_mod, scope, tw, sampler, interface_names, bucket, limit)
            end)
          ]
        end
      end)

    tasks
    |> safe_await_values(to_timeout(second: 10))
    |> List.flatten()
    |> InterfaceSeries.busier_direction_p95_bps(bucket_secs)
  end

  defp load_interface_p95_points(srql_mod, scope, tw, sampler, interface_names, bucket, limit) do
    query =
      "in:flows time:last_#{tw} sampler_address:#{srql_quote(sampler)} " <>
        "interface:#{srql_list(interface_names)} bucket:#{bucket} agg:sum " <>
        "value_field:bytes_total series:interface limit:#{limit}"

    srql_mod
    |> srql_results(query, scope)
    |> Enum.map(&interface_direction_point(&1, sampler))
    |> Enum.filter(& &1)
  end

  defp interface_downsample_limit(tw, bucket_secs, series_count) do
    bucket_count = ceil(time_window_seconds(tw) / max(bucket_secs, 1)) + 2
    max(max(series_count, 1) * bucket_count, 100)
  end

  defp interface_direction_point(row, sampler \\ nil) do
    p = row_payload(row)

    with {:ok, direction, interface_name} <- parse_interface_series(get_field(p, "series")),
         true <- is_binary(interface_name),
         t when not is_nil(t) <- get_field(p, "timestamp") || get_field(p, "bucket") || get_field(p, "time_bucket") do
      %{
        sampler: sampler,
        interface_name: interface_name,
        direction: direction,
        t: t,
        v: p |> get_field("value") |> to_number()
      }
    else
      _ -> nil
    end
  end

  defp parse_interface_series(series) when is_binary(series) do
    case String.split(series, ":", parts: 2) do
      [direction, interface_name] ->
        with {:ok, direction} <- normalize_if_direction(direction),
             interface_name when is_binary(interface_name) <- normalize_interface_name(interface_name) do
          {:ok, direction, interface_name}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_interface_series(_), do: :error

  defp normalize_if_direction(direction) when is_atom(direction) do
    direction
    |> Atom.to_string()
    |> normalize_if_direction()
  end

  defp normalize_if_direction(direction) when is_binary(direction) do
    case direction |> String.trim() |> String.downcase() do
      "ingress" -> {:ok, :ingress}
      "egress" -> {:ok, :egress}
      _ -> :error
    end
  end

  defp normalize_if_direction(_), do: :error

  defp normalize_interface_name(name) when is_binary(name) do
    name = String.trim(name)
    if name in ["", "Unknown", "unknown"], do: nil, else: name
  end

  defp normalize_interface_name(_), do: nil

  defp interface_label(interface_name) when is_binary(interface_name), do: interface_name
  defp interface_label(_), do: "Unknown interface"

  defp interface_key(sampler, interface_name) do
    %{sampler: sampler, interface: interface_name}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_interface_key(key) when is_binary(key) do
    with {:ok, json} <- Base.url_decode64(key, padding: false),
         {:ok, %{"sampler" => sampler, "interface" => interface_name}} <- Jason.decode(json),
         true <- is_binary(sampler) and String.trim(sampler) != "",
         true <- is_binary(interface_name) and String.trim(interface_name) != "" do
      {:ok, sampler, interface_name}
    else
      _ -> :error
    end
  end

  defp decode_interface_key(_), do: :error

  defp load_subnet_distribution(srql_mod, scope, base) do
    cidrs =
      case NetflowLocalCidr
           |> Ash.Query.for_read(:list)
           |> Ash.Query.filter(enabled == true)
           |> Ash.read(scope: scope) do
        {:ok, entries} -> ash_results(entries)
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
      |> Enum.reject(&((&1.bytes || 0) <= 0))
      |> Enum.sort_by(& &1.bytes, :desc)
    end
  end

  defp query_cidr_bytes(cidr, srql_mod, scope, base) do
    cidr_str = to_string(cidr.cidr)
    src_query = "#{base} src_cidr:#{srql_quote(cidr_str)} stats:sum(bytes_total) as bytes_total"
    dst_query = "#{base} dst_cidr:#{srql_quote(cidr_str)} stats:sum(bytes_total) as bytes_total"

    src_bytes = query_single_stat(srql_mod, scope, src_query, "bytes_total")
    dst_bytes = query_single_stat(srql_mod, scope, dst_query, "bytes_total")
    bytes = src_bytes + dst_bytes

    %{cidr: cidr_str, label: cidr.label || cidr_str, bytes: bytes}
  end

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  defp load_tcp_flag_distribution(srql_mod, scope, base) do
    query = "#{base} stats:count(*) as count by tcp_flags_label sort:count:desc limit:10"

    srql_mod
    |> srql_results(query, scope)
    |> Enum.map(fn row ->
      p = row_payload(row)

      %{
        label: get_field(p, "tcp_flags_label") || "unknown",
        count: to_number(get_field(p, "count"))
      }
    end)
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
            v: Float.round(count / bucket_secs, 2)
          }
        end)

      _ ->
        []
    end
  end

  defp load_duration_distribution(srql_mod, scope, base) do
    query = "#{base} stats:count(*) as count by duration_bucket"

    srql_mod
    |> srql_results(query, scope)
    |> Enum.map(fn row ->
      p = row_payload(row)

      %{
        bucket: get_field(p, "duration_bucket") || "unknown",
        count: to_number(get_field(p, "count"))
      }
    end)
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

  defp normalize_optional_query(nil), do: nil

  defp normalize_optional_query(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_optional_query(_), do: nil

  defp base_flow_query(nil, tw), do: "in:flows time:last_#{tw}"

  defp base_flow_query(query, tw) when is_binary(query) do
    query
    |> String.trim()
    |> ensure_flow_entity()
    |> ensure_flow_time_window(tw)
  end

  defp ensure_flow_entity(query) do
    if String.contains?(query, "in:flows"), do: query, else: "in:flows #{query}"
  end

  defp ensure_flow_time_window(query, tw) do
    if Regex.match?(~r/\btime:/, query), do: query, else: "#{query} time:last_#{tw}"
  end

  defp patch_params(socket, overrides) do
    %{
      tw: socket.assigns.time_window,
      unit: socket.assigns.unit_mode,
      metric: socket.assigns.metric_mode,
      section: socket.assigns.section,
      q: socket.assigns.query
    }
    |> Map.merge(overrides)
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
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
    base = base_flow_query(socket.assigns.query, socket.assigns.time_window)
    q = "#{base} #{filter}"
    push_patch(socket, to: ~p"/flows?#{patch_params(socket, %{q: q, section: "topn"})}")
  end

  # Escape a value for safe interpolation into an SRQL filter expression.
  # Wraps in double quotes and escapes any internal backslashes/double quotes.
  defp srql_quote(value) when is_binary(value) do
    escaped = value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
    "\"#{escaped}\""
  end

  defp srql_quote(value), do: srql_quote(to_string(value))

  defp srql_list(values) do
    values
    |> List.wrap()
    |> Enum.map_join(",", &srql_quote/1)
    |> then(&"(#{&1})")
  end

  defp primary_metric(_bytes, packets, "pps", time_window), do: packets / time_window_seconds(time_window)
  defp primary_metric(bytes, _packets, unit_mode, time_window), do: display_rate(bytes, unit_mode, time_window)

  defp display_rate(total_bytes, "bps", time_window), do: total_bytes * 8 / time_window_seconds(time_window)
  defp display_rate(total_bytes, "Bps", time_window), do: total_bytes / time_window_seconds(time_window)
  defp display_rate(total_bytes, _mode, _time_window), do: total_bytes

  defp unit_suffix("bps"), do: "bps"
  defp unit_suffix("Bps"), do: "B/s"
  defp unit_suffix("pps"), do: "pps"
  defp unit_suffix(_), do: ""

  @sobelow_skip ["XSS.Raw"]
  defp format_port_cell(row) do
    port = to_string(row.port)

    app =
      case safe_parse_int(port) do
        {:ok, port_num} -> ServicePorts.label(port_num)
        :error -> nil
      end

    if app do
      Phoenix.HTML.raw(
        "#{port |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()}" <>
          " <span class=\"text-xs text-base-content/50\">(#{app |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()})</span>"
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

  defp format_bytes_cell(row, "pps", time_window) do
    val = (row.packets || 0) / time_window_seconds(time_window)
    ServiceRadarWebNGWeb.FlowStatComponents.format_si(val, unit: "pps")
  end

  defp format_bytes_cell(row, unit_mode, time_window) do
    val = display_rate(row.bytes || 0, unit_mode, time_window)
    ServiceRadarWebNGWeb.FlowStatComponents.format_si(val, unit: unit_suffix(unit_mode))
  end

  defp format_primary_cell(row, _unit_mode, "packets", _time_window) do
    val = row.packets || 0
    ServiceRadarWebNGWeb.FlowStatComponents.format_si(val, unit: "pkts")
  end

  defp format_primary_cell(row, unit_mode, _metric_mode, time_window) do
    format_bytes_cell(row, unit_mode, time_window)
  end

  defp primary_metric_col_label("pps", _metric_mode), do: "Packets/sec"
  defp primary_metric_col_label(_unit_mode, "packets"), do: "Packets"
  defp primary_metric_col_label(unit_mode, _metric_mode), do: unit_suffix(unit_mode)

  defp get_field(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(payload, key)
  end

  defp row_payload(%{"payload" => payload}) when is_map(payload), do: payload
  defp row_payload(%{} = row), do: row
  defp row_payload(_), do: %{}

  defp srql_results(srql_mod, query, scope) do
    case srql_mod.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) -> results
      _ -> []
    end
  end

  defp ash_results(%Ash.Page.Keyset{results: results}) when is_list(results), do: results
  defp ash_results(results) when is_list(results), do: results
  defp ash_results(_), do: []

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
        {:ok, {key, value}} when is_atom(key) ->
          {key, value}

        {:ok, _unexpected} ->
          nil

        _ ->
          Task.shutdown(task, :brutal_kill)
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp safe_await_values(tasks, timeout) do
    tasks
    |> Task.yield_many(timeout)
    |> Enum.flat_map(fn {task, result} ->
      case result do
        {:ok, value} ->
          [value]

        _ ->
          Task.shutdown(task, :brutal_kill)
          []
      end
    end)
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
      [
        Enum.map(socket.assigns.top_talkers, & &1.ip),
        Enum.map(socket.assigns.top_listeners, & &1.ip),
        Enum.flat_map(socket.assigns.top_conversations, fn r -> [r.src_ip, r.dst_ip] end)
      ]
      |> Enum.concat()
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

      results = safe_await_many(tasks, to_timeout(second: 5))

      socket
      |> assign(:rdns_map, Map.get(results, :rdns, %{}))
      |> assign(:geo_iso2_map, Map.get(results, :geo, %{}))
    end
  end

  defp bulk_rdns(ips, scope) do
    now = DateTime.utc_now()

    query =
      IpRdnsCache
      |> Ash.Query.for_read(:read, %{})
      |> EnrichmentExpiry.live_for_ips(ips, now)

    case Ash.read(query, scope: scope) do
      {:ok, rows} ->
        rows = ash_results(rows)

        rows
        |> Enum.filter(fn r ->
          r.status == "ok" and is_binary(r.hostname) and String.trim(r.hostname) != ""
        end)
        |> Map.new(fn r -> {r.ip, r.hostname} end)

      _ ->
        %{}
    end
  end

  defp bulk_geo_iso2(ips, scope) do
    now = DateTime.utc_now()

    query =
      IpGeoEnrichmentCache
      |> Ash.Query.for_read(:read, %{})
      |> EnrichmentExpiry.live_for_ips(ips, now)

    case Ash.read(query, scope: scope) do
      {:ok, rows} ->
        rows = ash_results(rows)

        rows
        |> Enum.filter(fn r ->
          is_binary(r.country_iso2) and String.length(String.trim(r.country_iso2)) == 2
        end)
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

  @sobelow_skip ["XSS.Raw"]
  defp format_enriched_ip(ip, rdns_map, geo_iso2_map) do
    flag = iso2_flag_emoji(Map.get(geo_iso2_map, ip))
    hostname = Map.get(rdns_map, ip)

    parts = [flag, ip] |> Enum.reject(&is_nil/1) |> Enum.join(" ")

    if hostname do
      Phoenix.HTML.raw(
        "<span>#{parts |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()}" <>
          "<br/><span class=\"text-xs text-base-content/50\">#{hostname |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()}</span></span>"
      )
    else
      parts
    end
  end
end
