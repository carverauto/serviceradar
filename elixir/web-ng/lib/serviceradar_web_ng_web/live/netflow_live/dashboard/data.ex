defmodule ServiceRadarWebNGWeb.NetflowLive.Dashboard.Data do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import ServiceRadarWebNGWeb.NetflowLive.Dashboard.Helpers

  alias ServiceRadarWebNGWeb.NetflowLive.Dashboard.Distributions
  alias ServiceRadarWebNGWeb.NetflowLive.Dashboard.Enrichment
  alias ServiceRadarWebNGWeb.NetflowLive.Dashboard.InterfaceSeries
  alias ServiceRadarWebNGWeb.NetflowLive.Dashboard.Summary
  alias ServiceRadarWebNGWeb.NetflowLive.Dashboard.TopLists

  def load_dashboard_stats(socket) do
    tw = socket.assigns.time_window
    mm = socket.assigns.metric_mode
    scope = Map.get(socket.assigns, :current_scope)
    srql_mod = srql_module()
    task_sup = ServiceRadarWebNG.TaskSupervisor
    base = base_flow_query(socket.assigns.query, tw)
    sort_field = if mm == "packets", do: "packets_total", else: "bytes_total"

    tasks = [
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:top_talkers, TopLists.load_top_n(srql_mod, scope, base, "src_endpoint_ip", sort_field)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:top_listeners, TopLists.load_top_n(srql_mod, scope, base, "dst_endpoint_ip", sort_field)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:top_conversations, TopLists.load_top_conversations(srql_mod, scope, base, sort_field)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:top_apps, TopLists.load_top_n(srql_mod, scope, base, "app", sort_field)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:top_protocols, TopLists.load_top_n(srql_mod, scope, base, "protocol_name", sort_field)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:top_ports, TopLists.load_top_n(srql_mod, scope, base, "dst_endpoint_port", sort_field)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:summary, Summary.load_summary(srql_mod, scope, base)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:timeseries, Summary.load_timeseries(srql_mod, scope, base, tw)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:top_interfaces, InterfaceSeries.load_top_interfaces(srql_mod, scope, base, tw)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:subnet_distribution, Distributions.load_subnet_distribution(srql_mod, scope, base)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:tcp_flags, Distributions.load_tcp_flag_distribution(srql_mod, scope, base)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:flow_rate, Distributions.load_flow_rate_timeseries(srql_mod, scope, base, tw)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:duration_dist, Distributions.load_duration_distribution(srql_mod, scope, base)}
      end),
      Task.Supervisor.async_nolink(task_sup, fn ->
        {:data_span, Summary.load_data_span(srql_mod, scope, base)}
      end)
    ]

    results = safe_await_many(tasks, to_timeout(second: 15))

    # §38.1: clamp the covered span to [1, requested] so a partial-coverage
    # window shrinks the rate denominator (recovering the true rate) but a
    # full-coverage window, a failed span query, or a degenerate value all fall
    # back to the requested window (identical to pre-§38.1 behavior).
    requested_seconds = time_window_seconds(tw)
    raw_span = Map.get(results, :data_span)
    covered_span_seconds = clamp_covered_span(raw_span, requested_seconds)

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
    |> assign(:top_interfaces, Map.get(results, :top_interfaces, []))
    |> assign(:subnet_distribution, Map.get(results, :subnet_distribution, []))
    |> assign(:tcp_flags_json, tcp_flags_json)
    |> assign(:flow_rate_points_json, flow_rate_points_json)
    |> assign(:duration_dist_json, duration_dist_json)
    |> assign(:covered_span_seconds, covered_span_seconds)
    |> ensure_selected_interface()
    |> maybe_reload_interface_chart()
    |> Enrichment.enrich_top_n_ips()
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

  defp maybe_reload_interface_chart(%{assigns: %{selected_interface: nil}} = socket), do: socket

  defp maybe_reload_interface_chart(%{assigns: %{selected_interface: key}} = socket) do
    InterfaceSeries.load_interface_timeseries(socket, key)
  end

  def load_interface_timeseries(socket, key), do: InterfaceSeries.load_interface_timeseries(socket, key)
end
