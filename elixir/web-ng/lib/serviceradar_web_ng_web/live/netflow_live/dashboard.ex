defmodule ServiceRadarWebNGWeb.NetflowLive.Dashboard do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.FlowStatComponents

  alias ServiceRadar.Observability.NetflowInterfaceCache
  alias ServiceRadar.Observability.NetflowLocalCidr
  alias ServiceRadar.Actors.SystemActor

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
     |> assign(:unit_mode, "bps")
     |> assign(:unit_modes, @unit_modes)
     |> assign(:loading, true)
     |> assign(:top_talkers, [])
     |> assign(:top_listeners, [])
     |> assign(:top_conversations, [])
     |> assign(:top_apps, [])
     |> assign(:top_protocols, [])
     |> assign(:total_bytes, 0)
     |> assign(:total_packets, 0)
     |> assign(:active_flows, 0)
     |> assign(:unique_talkers, 0)
     |> assign(:sparkline_json, "[]")
     |> assign(:proto_breakdown_json, "[]")
     |> assign(:top_interfaces, [])
     |> assign(:subnet_distribution, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Backward compat: redirect /flows?nf=... to /flows/visualize?nf=...
    if Map.has_key?(params, "nf") do
      qs = URI.encode_query(params)
      {:noreply, push_navigate(socket, to: "/flows/visualize?#{qs}", replace: true)}
    else
      tw = Map.get(params, "tw", socket.assigns.time_window)
      um = Map.get(params, "unit", socket.assigns.unit_mode)

      socket =
        socket
        |> assign(:time_window, tw)
        |> assign(:unit_mode, um)
        |> load_dashboard_stats()

      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("change_time_window", %{"tw" => tw}, socket) do
    {:noreply, push_patch(socket, to: ~p"/flows?#{%{tw: tw, unit: socket.assigns.unit_mode}}")}
  end

  def handle_event("change_unit_mode", %{"unit" => um}, socket) do
    {:noreply, push_patch(socket, to: ~p"/flows?#{%{tw: socket.assigns.time_window, unit: um}}")}
  end

  def handle_event("drill_down_talker", %{"row-idx" => idx}, socket) do
    row = Enum.at(socket.assigns.top_talkers, String.to_integer(idx))
    if row, do: {:noreply, drill_down(socket, "src_ip:#{row.ip}")}, else: {:noreply, socket}
  end

  def handle_event("drill_down_listener", %{"row-idx" => idx}, socket) do
    row = Enum.at(socket.assigns.top_listeners, String.to_integer(idx))
    if row, do: {:noreply, drill_down(socket, "dst_ip:#{row.ip}")}, else: {:noreply, socket}
  end

  def handle_event("drill_down_conversation", %{"row-idx" => idx}, socket) do
    row = Enum.at(socket.assigns.top_conversations, String.to_integer(idx))

    if row do
      {:noreply, drill_down(socket, "src_ip:#{row.src_ip} dst_ip:#{row.dst_ip}")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("drill_down_app", %{"row-idx" => idx}, socket) do
    row = Enum.at(socket.assigns.top_apps, String.to_integer(idx))
    if row, do: {:noreply, drill_down(socket, "app:#{row.app}")}, else: {:noreply, socket}
  end

  def handle_event("drill_down_protocol", %{"row-idx" => idx}, socket) do
    row = Enum.at(socket.assigns.top_protocols, String.to_integer(idx))

    if row do
      {:noreply, drill_down(socket, "protocol_name:#{row.protocol}")}
    else
      {:noreply, socket}
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
            title="Total Bandwidth"
            value={display_bandwidth(@total_bytes, @unit_mode)}
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

        <%!-- Top-N tables grid --%>
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
          <.top_n_table
            title="Top Talkers (Source IPs)"
            rows={@top_talkers}
            columns={[
              %{key: :ip, label: "Source IP"},
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
              %{key: :ip, label: "Dest IP"},
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
              %{key: :src_ip, label: "Source"},
              %{key: :dst_ip, label: "Dest"},
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
              current_bps={display_bandwidth(iface.bytes, @unit_mode) * 8}
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
    scope = Map.get(socket.assigns, :current_scope)
    srql_mod = srql_module()
    base = "in:flows time:last_#{tw}"

    tasks = [
      Task.async(fn -> {:top_talkers, load_top_n(srql_mod, scope, base, "src_endpoint_ip", "bytes_total")} end),
      Task.async(fn -> {:top_listeners, load_top_n(srql_mod, scope, base, "dst_endpoint_ip", "bytes_total")} end),
      Task.async(fn -> {:top_conversations, load_top_conversations(srql_mod, scope, base)} end),
      Task.async(fn -> {:top_apps, load_top_n(srql_mod, scope, base, "app", "bytes_total")} end),
      Task.async(fn -> {:top_protocols, load_top_n(srql_mod, scope, base, "protocol_name", "bytes_total")} end),
      Task.async(fn -> {:summary, load_summary(srql_mod, scope, base)} end),
      Task.async(fn -> {:timeseries, load_timeseries(srql_mod, scope, base, tw)} end),
      Task.async(fn -> {:top_interfaces, load_top_interfaces(srql_mod, scope, base)} end),
      Task.async(fn -> {:subnet_distribution, load_subnet_distribution(srql_mod, scope, base)} end)
    ]

    results =
      tasks
      |> Task.await_many(:timer.seconds(15))
      |> Map.new()

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

    socket
    |> assign(:loading, false)
    |> assign(:top_talkers, Map.get(results, :top_talkers, []))
    |> assign(:top_listeners, Map.get(results, :top_listeners, []))
    |> assign(:top_conversations, Map.get(results, :top_conversations, []))
    |> assign(:top_apps, Map.get(results, :top_apps, []))
    |> assign(:top_protocols, top_protocols)
    |> assign(:total_bytes, Map.get(summary, :total_bytes, 0))
    |> assign(:total_packets, Map.get(summary, :total_packets, 0))
    |> assign(:active_flows, Map.get(summary, :flow_count, 0))
    |> assign(:unique_talkers, Map.get(summary, :unique_talkers, 0))
    |> assign(:sparkline_json, sparkline_json)
    |> assign(:proto_breakdown_json, proto_breakdown)
    |> assign(:top_interfaces, Map.get(results, :top_interfaces, []))
    |> assign(:subnet_distribution, Map.get(results, :subnet_distribution, []))
  end

  defp load_top_n(srql_mod, scope, base, group_field, value_field) do
    query = "#{base} stats:#{value_field},packets_total by #{group_field} sort:#{value_field}:desc limit:#{@top_n}"

    case srql_mod.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        Enum.map(results, fn %{"payload" => p} ->
          %{
            ip: get_field(p, group_field),
            app: get_field(p, group_field),
            protocol: get_field(p, group_field),
            bytes: to_number(get_field(p, value_field)),
            packets: to_number(get_field(p, "packets_total"))
          }
        end)

      _ ->
        []
    end
  end

  defp load_top_conversations(srql_mod, scope, base) do
    query = "#{base} stats:bytes_total by src_endpoint_ip,dst_endpoint_ip sort:bytes_total:desc limit:#{@top_n}"

    case srql_mod.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        Enum.map(results, fn %{"payload" => p} ->
          %{
            src_ip: get_field(p, "src_endpoint_ip"),
            dst_ip: get_field(p, "dst_endpoint_ip"),
            bytes: to_number(get_field(p, "bytes_total"))
          }
        end)

      _ ->
        []
    end
  end

  defp load_summary(srql_mod, scope, base) do
    query = "#{base} stats:bytes_total,packets_total,count,count_distinct(src_endpoint_ip)"

    case srql_mod.query(query, %{scope: scope}) do
      {:ok, %{"results" => [%{"payload" => p} | _]}} ->
        %{
          total_bytes: to_number(get_field(p, "bytes_total")),
          total_packets: to_number(get_field(p, "packets_total")),
          flow_count: to_number(get_field(p, "count")),
          unique_talkers: to_number(get_field(p, "count_distinct_src_endpoint_ip"))
        }

      _ ->
        %{}
    end
  end

  defp load_timeseries(srql_mod, scope, base, tw) do
    bucket = timeseries_bucket(tw)
    query = "#{base} downsample:#{bucket}:bytes_total:sum"

    case srql_mod.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        Enum.map(results, fn %{"payload" => p} ->
          %{
            t: get_field(p, "bucket") || get_field(p, "time_bucket"),
            v: to_number(get_field(p, "bytes_total"))
          }
        end)

      _ ->
        []
    end
  end

  defp load_top_interfaces(srql_mod, scope, base) do
    query = "#{base} stats:bytes_total,packets_total by sampler_address sort:bytes_total:desc limit:5"

    interface_rows =
      case srql_mod.query(query, %{scope: scope}) do
        {:ok, %{"results" => results}} when is_list(results) ->
          Enum.map(results, fn %{"payload" => p} ->
            %{
              sampler: get_field(p, "sampler_address"),
              bytes: to_number(get_field(p, "bytes_total")),
              packets: to_number(get_field(p, "packets_total"))
            }
          end)

        _ ->
          []
      end

    # Enrich with interface cache for speed/name
    cache_map = load_interface_cache_map()

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

  defp load_interface_cache_map do
    actor = SystemActor.system(:flow_dashboard)

    case NetflowInterfaceCache
         |> Ash.Query.for_read(:read)
         |> Ash.read(actor: actor) do
      {:ok, entries} ->
        # Group by sampler_address, take the highest speed interface per sampler
        entries
        |> Enum.group_by(& &1.sampler_address)
        |> Map.new(fn {sampler, ifaces} ->
          best = Enum.max_by(ifaces, & (&1.if_speed_bps || 0), fn -> hd(ifaces) end)

          {sampler,
           %{
             name: best.if_name || best.if_description || sampler,
             speed_bps: best.if_speed_bps || 0
           }}
        end)

      _ ->
        %{}
    end
  end

  defp load_subnet_distribution(srql_mod, scope, base) do
    actor = SystemActor.system(:flow_dashboard)

    cidrs =
      case NetflowLocalCidr
           |> Ash.Query.for_read(:list)
           |> Ash.Query.filter(enabled == true)
           |> Ash.read(actor: actor) do
        {:ok, entries} -> entries
        _ -> []
      end

    if cidrs == [] do
      []
    else
      # Query traffic per local CIDR by checking src_ip matches
      cidrs
      |> Enum.take(10)
      |> Enum.map(fn cidr ->
        cidr_str = to_string(cidr.cidr)
        query = "#{base} src_ip:#{cidr_str} stats:bytes_total,packets_total"

        bytes =
          case srql_mod.query(query, %{scope: scope}) do
            {:ok, %{"results" => [%{"payload" => p} | _]}} ->
              to_number(get_field(p, "bytes_total"))

            _ ->
              0
          end

        %{
          cidr: cidr_str,
          label: cidr.label || cidr_str,
          bytes: bytes
        }
      end)
      |> Enum.sort_by(& &1.bytes, :desc)
    end
  end

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

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

  defp display_bandwidth(total_bytes, "bps"), do: total_bytes * 8
  defp display_bandwidth(total_bytes, _mode), do: total_bytes

  defp unit_suffix("bps"), do: "bps"
  defp unit_suffix("Bps"), do: "B/s"
  defp unit_suffix("pps"), do: "pps"
  defp unit_suffix(_), do: ""

  defp format_capacity_cell(row) do
    cap = row.capacity_bps || 0
    if cap > 0, do: format_si(cap * 1.0, unit: "bps"), else: "N/A"
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

  defp schedule_refresh do
    Process.send_after(self(), :refresh_data, @refresh_interval_ms)
  end

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end
end
