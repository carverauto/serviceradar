defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceTabRuntime do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, start_async: 3]

  import ServiceRadarWebNGWeb.DeviceLive.VisibilityComponents,
    only: [active_fingerprint_tab_visible?: 2]

  alias ServiceRadarWebNGWeb.DeviceLive.FlowData
  alias ServiceRadarWebNGWeb.DeviceLive.InterfaceData
  alias ServiceRadarWebNGWeb.DeviceLive.MtrRuntime
  alias ServiceRadarWebNGWeb.DeviceLive.NorthboundInterfaceRuntime
  alias ServiceRadarWebNGWeb.DeviceLive.QueryData
  alias ServiceRadarWebNGWeb.DeviceLive.SysmonProfileData

  @valid_tabs ~w(
    details
    software
    interfaces
    flows
    logs
    profiles
    active-fingerprint
    process-listeners
    sysmon
    mtr
    guests
  )

  def normalize_requested_tab(url_tab, fallback_tab) do
    if url_tab in @valid_tabs, do: url_tab, else: fallback_tab
  end

  def same_device_and_limit?(socket, uid, limit) do
    uid == socket.assigns.device_uid and limit == socket.assigns.limit
  end

  def resolve_active_tab(socket, requested_tab) do
    requested_tab
    |> resolve_active_tab(
      socket.assigns.has_ifaces,
      socket.assigns.has_flows,
      socket.assigns.has_logs,
      socket.assigns.has_mtr,
      socket.assigns.has_virtualization_guests
    )
    |> authorize_active_tab(Map.get(socket.assigns, :device_row), socket.assigns.current_scope)
  end

  def resolve_active_tab(requested_tab, has_ifaces, has_flows, has_logs, has_mtr, has_virtualization_guests) do
    case requested_tab do
      "interfaces" when not has_ifaces -> "details"
      "flows" when not has_flows -> "details"
      "logs" when not has_logs -> "details"
      "mtr" when not has_mtr -> "details"
      "guests" when not has_virtualization_guests -> "details"
      tab -> tab
    end
  end

  def authorize_active_tab("active-fingerprint", row, scope) do
    if active_fingerprint_tab_visible?(row, scope), do: "active-fingerprint", else: "details"
  end

  def authorize_active_tab(tab, _row, _scope), do: tab

  # A same-device details refresh sets details_loading while the supplemental
  # batch is in flight. Tabs that already have rows must stay rendered —
  # treating details_loading as a full-tab spinner replaces the table with
  # "Loading network interfaces" on every SNMP last_seen broadcast.
  def tab_content_loading?(tab_loading?, details_loading?, rows) when is_list(rows) do
    tab_loading? or (details_loading? and rows == [])
  end

  def tab_content_loading?(tab_loading?, details_loading?, _rows) do
    tab_loading? or details_loading?
  end

  def reload_interfaces?(assigns) do
    not assigns.interfaces_loading and assigns.network_interfaces == []
  end

  def handle_same_device_params(socket, uid, limit, requested_tab, cursor, srql_module, opts) do
    active_tab = resolve_active_tab(socket, requested_tab)
    srql = QueryData.srql_for_tab_if_needed(active_tab, uid, limit, socket.assigns.srql)

    socket =
      socket
      |> reload_for_active_tab(active_tab, uid, cursor, srql_module, opts)
      |> maybe_load_mtr_for_active_tab(active_tab)

    {:noreply,
     socket
     |> assign(:active_tab, active_tab)
     |> assign(:srql, srql)
     |> NorthboundInterfaceRuntime.maybe_load_actions()}
  end

  def reload_for_active_tab(socket, active_tab, uid, cursor, srql_module, opts) do
    socket
    |> maybe_reload_flows_for_active_tab(active_tab, uid, cursor, srql_module, opts)
    |> maybe_reload_logs_for_active_tab(active_tab, uid, cursor, srql_module, opts)
    |> maybe_reload_interfaces_for_active_tab(active_tab, uid, srql_module)
    |> maybe_reload_profiles_for_active_tab(active_tab, uid)
  end

  def maybe_reload_logs_for_active_tab(socket, "logs", uid, cursor, srql_module, opts) do
    if socket.assigns.logs_loading and socket.assigns.logs_cursor == cursor do
      socket
    else
      begin_logs_load(socket, uid, cursor, srql_module, opts)
    end
  end

  def maybe_reload_logs_for_active_tab(socket, _active_tab, _uid, _cursor, _srql_module, _opts), do: socket

  def maybe_load_mtr_for_active_tab(socket, "mtr") do
    MtrRuntime.load_traces(socket, get_device_ip(socket.assigns.results))
  end

  def maybe_load_mtr_for_active_tab(socket, _active_tab), do: socket

  defp maybe_reload_flows_for_active_tab(socket, "flows", uid, cursor, srql_module, opts) do
    if socket.assigns.flows_loading do
      socket
    else
      begin_flows_load(socket, uid, cursor, srql_module, opts)
    end
  end

  defp maybe_reload_flows_for_active_tab(socket, _active_tab, _uid, _cursor, _srql_module, _opts), do: socket

  defp begin_logs_load(socket, uid, cursor, srql_module, opts) do
    scope = socket.assigns.current_scope
    request_ref = make_ref()

    socket
    |> maybe_reset_logs(Keyword.get(opts, :preserve_rendered, false))
    |> assign(:logs_loading, false)
    |> assign(:logs_request_ref, request_ref)
    |> assign(:logs_cursor, cursor)
    |> assign(:has_logs, true)
    |> maybe_start_logs_async(uid, request_ref, srql_module, scope, cursor, opts)
  end

  # On a same-device refresh (preserve_rendered: true) keep the currently
  # rendered log rows on screen — the async result replaces them wholesale
  # when it lands instead of blanking the tab while the load is in flight.
  defp maybe_reset_logs(socket, true = _preserve_rendered?), do: socket

  defp maybe_reset_logs(socket, false = _preserve_rendered?) do
    socket
    |> assign(:device_logs, [])
    |> assign(:logs_pagination, %{})
    |> assign(:logs_error, nil)
  end

  defp maybe_start_logs_async(socket, uid, request_ref, srql_module, scope, cursor, opts) do
    if connected?(socket) do
      logs_limit = Keyword.fetch!(opts, :logs_limit)

      identities = device_log_identities(socket)

      start_async(socket, {:device_logs, uid, request_ref}, fn ->
        QueryData.load_logs(srql_module, uid, scope, cursor, logs_limit, identities)
      end)
    else
      socket
    end
  end

  def begin_interface_metrics_refresh(socket, uid, srql_module) do
    scope = socket.assigns.current_scope
    request_ref = make_ref()
    favorited = socket.assigns.favorited_interfaces
    metrics_enabled = socket.assigns.metrics_enabled_interfaces
    interfaces = socket.assigns.network_interfaces

    if connected?(socket) do
      # Keep already-rendered favorited metrics on screen. A same-device
      # refresh used to flip this true and replace the table header with
      # "Loading favorited interface metrics" every 30s.
      metrics_loading? = is_nil(socket.assigns.interface_metrics)

      socket
      |> assign(:interface_metrics_loading, metrics_loading?)
      |> assign(:interface_metrics_request_ref, request_ref)
      |> start_async({:interface_metrics, uid, request_ref}, fn ->
        InterfaceData.load_interface_metrics(
          srql_module,
          uid,
          favorited,
          metrics_enabled,
          interfaces,
          scope
        )
      end)
    else
      socket
    end
  end

  defp maybe_reload_interfaces_for_active_tab(socket, "interfaces", uid, srql_module) do
    if reload_interfaces?(socket.assigns) do
      begin_interfaces_load(socket, uid, srql_module)
    else
      socket
    end
  end

  defp maybe_reload_interfaces_for_active_tab(socket, _active_tab, _uid, _srql_module), do: socket

  defp begin_interfaces_load(socket, uid, srql_module) do
    scope = socket.assigns.current_scope
    request_ref = make_ref()
    device_row = Map.get(socket.assigns, :device_row)

    if connected?(socket) do
      socket
      |> assign(:network_interfaces, [])
      |> assign(:interfaces_error, nil)
      |> assign(:interface_metrics, nil)
      |> assign(:interfaces_loading, true)
      |> assign(:interface_availability, :checking)
      |> assign(:has_ifaces, true)
      |> assign(:interfaces_request_ref, request_ref)
      |> start_async({:device_interfaces, uid, request_ref}, fn ->
        {network_interfaces, interfaces_error} =
          InterfaceData.load_interfaces(srql_module, uid, scope)

        interface_settings = InterfaceData.load_interface_settings(scope, uid)

        network_interfaces =
          network_interfaces
          |> InterfaceData.filter_interfaces_for_display(device_row)
          |> InterfaceData.apply_interface_settings(interface_settings.by_uid)

        %{
          network_interfaces: network_interfaces,
          interfaces_error: interfaces_error,
          favorited_interfaces: interface_settings.favorited,
          metrics_enabled_interfaces: interface_settings.metrics_enabled
        }
      end)
    else
      socket
    end
  end

  defp begin_flows_load(socket, uid, cursor, srql_module, opts) do
    scope = socket.assigns.current_scope
    request_ref = make_ref()
    flows_limit = Keyword.fetch!(opts, :flows_limit)

    if connected?(socket) do
      socket
      |> assign(:device_flows, [])
      |> assign(:flows_error, nil)
      |> assign(:flows_pagination, %{})
      |> assign(:flows_loading, true)
      |> assign(:flow_availability, :checking)
      |> assign(:has_flows, true)
      |> assign(:flows_request_ref, request_ref)
      |> start_async({:device_flows, uid, request_ref}, fn ->
        FlowData.load_flows(srql_module, uid, scope, cursor, flows_limit)
      end)
    else
      socket
    end
  end

  defp maybe_reload_profiles_for_active_tab(socket, "profiles", uid) do
    scope = socket.assigns.current_scope
    {profile_info, available_profiles} = SysmonProfileData.load_profile_info(scope, uid)

    socket
    |> assign(:sysmon_profile_info, profile_info)
    |> assign(:available_profiles, available_profiles)
  end

  defp maybe_reload_profiles_for_active_tab(socket, _active_tab, _uid), do: socket

  defp get_device_ip(results) do
    case List.first(Enum.filter(results, &is_map/1)) do
      nil -> nil
      row -> Map.get(row, "ip")
    end
  end

  defp device_log_identities(socket) do
    row = Map.get(socket.assigns, :device_row) || List.first(socket.assigns[:results] || [])

    [
      get_device_ip(socket.assigns[:results] || []),
      row_value(row, "ip"),
      row_value(row, "hostname"),
      row_value(row, "name")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp row_value(row, key) when is_map(row) and is_binary(key) do
    Map.get(row, key) || Map.get(row, known_row_atom(key))
  end

  defp row_value(_row, _key), do: nil

  defp known_row_atom("ip"), do: :ip
  defp known_row_atom("hostname"), do: :hostname
  defp known_row_atom("name"), do: :name
  defp known_row_atom(_), do: nil
end
