defmodule ServiceRadarWebNGWeb.NetflowLive.Dashboard do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadarWebNGWeb.NetflowLive.Dashboard.Data
  alias ServiceRadarWebNGWeb.NetflowLive.Dashboard.Helpers
  alias ServiceRadarWebNGWeb.NetflowLive.Dashboard.View

  @refresh_interval_ms to_timeout(minute: 1)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    srql = %{enabled: false, page_path: "/flows"}

    {:ok,
     socket
     |> assign(:page_title, "Flows")
     |> assign(:srql, srql)
     |> assign(:time_window, "1h")
     |> assign(:time_windows, Helpers.time_windows())
     |> assign(:covered_span_seconds, 3_600)
     |> assign(:section, "overview")
     |> assign(:sections, Helpers.sections())
     |> assign(:query, nil)
     |> assign(:unit_mode, "bps")
     |> assign(:unit_modes, Helpers.unit_modes())
     |> assign(:loading, true)
     |> assign(:top_talkers, [])
     |> assign(:top_listeners, [])
     |> assign(:top_conversations, [])
     |> assign(:top_apps, [])
     |> assign(:top_protocols, [])
     |> assign(:top_ports, [])
     |> assign(:metric_mode, "bytes")
     |> assign(:metric_modes, Helpers.metric_modes())
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
    tw =
      Helpers.validate_param(
        Map.get(params, "tw"),
        Helpers.time_windows(),
        socket.assigns.time_window
      )

    um =
      Helpers.validate_param(
        Map.get(params, "unit"),
        Helpers.unit_modes(),
        socket.assigns.unit_mode
      )

    mm =
      Helpers.validate_param(
        Map.get(params, "metric"),
        Helpers.metric_modes(),
        socket.assigns.metric_mode
      )

    section =
      Helpers.validate_param(
        Map.get(params, "section"),
        Helpers.sections(),
        socket.assigns.section
      )

    query = Helpers.normalize_optional_query(Map.get(params, "q"))

    socket =
      socket
      |> assign(:time_window, tw)
      |> assign(:unit_mode, um)
      |> assign(:metric_mode, mm)
      |> assign(:section, section)
      |> assign(:query, query)
      |> Data.load_dashboard_stats()

    {:noreply, socket}
  end

  @impl true
  def handle_event("change_time_window", %{"tw" => tw}, socket) do
    {:noreply, push_patch(socket, to: ~p"/flows?#{Helpers.patch_params(socket, %{tw: tw})}")}
  end

  def handle_event("change_unit_mode", %{"unit" => um}, socket) do
    {:noreply, push_patch(socket, to: ~p"/flows?#{Helpers.patch_params(socket, %{unit: um})}")}
  end

  def handle_event("change_metric_mode", %{"metric" => mm}, socket) do
    {:noreply, push_patch(socket, to: ~p"/flows?#{Helpers.patch_params(socket, %{metric: mm})}")}
  end

  def handle_event("change_section", %{"section" => section}, socket) do
    section = Helpers.validate_param(section, Helpers.sections(), socket.assigns.section)

    {:noreply, push_patch(socket, to: ~p"/flows?#{Helpers.patch_params(socket, %{section: section})}")}
  end

  def handle_event("clear_query", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/flows?#{Helpers.patch_params(socket, %{q: nil})}")}
  end

  def handle_event("drill_down_talker", %{"row-idx" => idx}, socket) do
    with {:ok, i} <- Helpers.safe_parse_int(idx),
         row when not is_nil(row) <- Enum.at(socket.assigns.top_talkers, i) do
      {:noreply, drill_down(socket, "src_ip:#{Helpers.srql_quote(row.ip)}")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("drill_down_listener", %{"row-idx" => idx}, socket) do
    with {:ok, i} <- Helpers.safe_parse_int(idx),
         row when not is_nil(row) <- Enum.at(socket.assigns.top_listeners, i) do
      {:noreply, drill_down(socket, "dst_ip:#{Helpers.srql_quote(row.ip)}")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("drill_down_conversation", %{"row-idx" => idx}, socket) do
    with {:ok, i} <- Helpers.safe_parse_int(idx),
         row when not is_nil(row) <- Enum.at(socket.assigns.top_conversations, i) do
      {:noreply,
       drill_down(
         socket,
         "src_ip:#{Helpers.srql_quote(row.src_ip)} dst_ip:#{Helpers.srql_quote(row.dst_ip)}"
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("drill_down_app", %{"row-idx" => idx}, socket) do
    with {:ok, i} <- Helpers.safe_parse_int(idx),
         row when not is_nil(row) <- Enum.at(socket.assigns.top_apps, i) do
      {:noreply, drill_down(socket, "app:#{Helpers.srql_quote(row.app)}")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("drill_down_protocol", %{"row-idx" => idx}, socket) do
    with {:ok, i} <- Helpers.safe_parse_int(idx),
         row when not is_nil(row) <- Enum.at(socket.assigns.top_protocols, i) do
      {:noreply, drill_down(socket, "protocol_name:#{Helpers.srql_quote(row.protocol)}")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("drill_down_port", %{"row-idx" => idx}, socket) do
    with {:ok, i} <- Helpers.safe_parse_int(idx),
         row when not is_nil(row) <- Enum.at(socket.assigns.top_ports, i),
         port when not is_nil(port) <- row.port,
         {:ok, port_int} <- Helpers.safe_parse_int(to_string(port)),
         true <- port_int > 0 do
      {:noreply, drill_down(socket, "dst_endpoint_port:#{Helpers.srql_quote(to_string(port_int))}")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("select_interface", %{"interface" => ""}, socket) do
    {:noreply,
     socket
     |> assign(:selected_interface, nil)
     |> assign(:iface_chart_keys_json, "[]")
     |> assign(:iface_chart_points_json, "[]")}
  end

  def handle_event("select_interface", %{"interface" => key}, socket) do
    {:noreply,
     socket
     |> assign(:selected_interface, key)
     |> Data.load_interface_timeseries(key)}
  end

  @impl true
  def handle_info(:refresh_data, socket) do
    schedule_refresh()
    {:noreply, Data.load_dashboard_stats(socket)}
  end

  @impl true
  def render(assigns), do: View.render(assigns)

  defp drill_down(socket, filter) do
    base = Helpers.base_flow_query(socket.assigns.query, socket.assigns.time_window)
    q = "#{base} #{filter}"
    push_patch(socket, to: ~p"/flows?#{Helpers.patch_params(socket, %{q: q, section: "topn"})}")
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh_data, @refresh_interval_ms)
  end
end
