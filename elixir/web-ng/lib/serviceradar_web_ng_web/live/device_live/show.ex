defmodule ServiceRadarWebNGWeb.DeviceLive.Show do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  alias ServiceRadar.Inventory.DevicePubSub
  alias ServiceRadar.Observability.MtrPubSub
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Dashboard.Engine
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Categories, as: CategoriesPlugin
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Table, as: TablePlugin
  alias ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityData
  alias ServiceRadarWebNGWeb.DeviceLive.AnsiblePanelRuntime
  alias ServiceRadarWebNGWeb.DeviceLive.CameraData
  alias ServiceRadarWebNGWeb.DeviceLive.CameraRelayRuntime
  alias ServiceRadarWebNGWeb.DeviceLive.DeviceActionRuntime
  alias ServiceRadarWebNGWeb.DeviceLive.DeviceMountAssigns
  alias ServiceRadarWebNGWeb.DeviceLive.DeviceStateData
  alias ServiceRadarWebNGWeb.DeviceLive.DeviceSupplementalData
  alias ServiceRadarWebNGWeb.DeviceLive.DeviceTabRuntime
  alias ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryData
  alias ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryRuntime
  alias ServiceRadarWebNGWeb.DeviceLive.FlowRuntime
  alias ServiceRadarWebNGWeb.DeviceLive.IndexPath
  alias ServiceRadarWebNGWeb.DeviceLive.InterfaceData
  alias ServiceRadarWebNGWeb.DeviceLive.InterfaceRuntime
  alias ServiceRadarWebNGWeb.DeviceLive.MetadataData
  alias ServiceRadarWebNGWeb.DeviceLive.MtrRuntime
  alias ServiceRadarWebNGWeb.DeviceLive.NorthboundInterfaceRuntime
  alias ServiceRadarWebNGWeb.DeviceLive.QueryData
  alias ServiceRadarWebNGWeb.DeviceLive.RemoteAccessData
  alias ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics
  alias ServiceRadarWebNGWeb.DeviceLive.VirtualizationData
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  require Logger

  @default_limit 50
  @max_limit 200
  @flows_limit 50
  @logs_limit 50
  @details_supplemental_timeout_ms 3_000
  @tab_supplemental_timeout_ms 15_000
  # Minimum spacing between :device_updated-triggered refreshes of the
  # currently displayed device. Core broadcasts on a global topic for every
  # Ash device update, so busy devices get touched every 30s–2.5min on
  # clustered deployments; without a cooldown each broadcast forced a full
  # reload. Overridable for tests via :device_refresh_cooldown_ms app env.
  @device_refresh_cooldown_ms 30_000
  @slow_device_task_ms 1_500
  @detail_metric_bucket "1m"
  @detail_metric_min_window_seconds 14_400
  @detail_metric_window_padding_seconds 1_800

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      DevicePubSub.subscribe()
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "agent:commands")
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, MtrPubSub.topic())
    end

    socket =
      DeviceMountAssigns.assign_defaults(socket,
        default_limit: @default_limit,
        flows_limit: @flows_limit,
        logs_limit: @logs_limit
      )

    {:ok, AnsiblePanelRuntime.assign_defaults(socket)}
  end

  @impl true
  def handle_params(%{"uid" => uid} = params, uri, socket) do
    socket =
      socket
      |> assign(:last_params, params)
      |> assign(:last_uri, uri)
      |> assign(:devices_return_path, devices_return_path(params, socket))

    limit = QueryData.parse_limit(Map.get(params, "limit"), @default_limit, @max_limit)
    # Read tab from URL params, fall back to current or default
    url_tab = Map.get(params, "tab")
    cursor = QueryData.normalize_cursor(Map.get(params, "cursor"))
    mtr_page = QueryData.parse_positive_page(Map.get(params, "mtr_page"))
    mtr_page_size = MtrRuntime.default_page_size()

    requested_tab = DeviceTabRuntime.normalize_requested_tab(url_tab, socket.assigns.active_tab)
    socket = socket |> assign(:mtr_page, mtr_page) |> assign(:mtr_page_size, mtr_page_size)

    cond do
      DeviceTabRuntime.same_device_and_limit?(socket, uid, limit) ->
        DeviceTabRuntime.handle_same_device_params(
          socket,
          uid,
          limit,
          requested_tab,
          cursor,
          srql_module(),
          tab_runtime_opts()
        )

      connected?(socket) ->
        load_device_data(socket, uid, limit, requested_tab, params, uri)

      true ->
        # Disconnected render — show page shell with empty defaults from mount/3
        {:noreply,
         socket
         |> assign(:device_uid, uid)
         |> assign(:limit, limit)
         |> assign(:mtr_page, mtr_page)
         |> assign(:mtr_page_size, mtr_page_size)
         |> assign(:active_tab, requested_tab)}
    end
  end

  @impl true
  def handle_info({:device_created, uid, _device}, socket) do
    maybe_refresh_current_device(socket, uid)
  end

  def handle_info({:device_updated, uid, _device}, socket) do
    maybe_refresh_current_device(socket, uid)
  end

  def handle_info({:device_deleted, uid}, socket) do
    maybe_refresh_current_device(socket, uid)
  end

  # Trailing refresh scheduled by coalesce_device_refresh/2: a broadcast
  # arrived during the cooldown window, so exactly one deferred refresh runs
  # at cooldown expiry to make the page converge on the latest data.
  def handle_info({:deferred_device_refresh, uid}, socket) do
    socket = assign(socket, :device_refresh_timer, nil)
    maybe_refresh_current_device(socket, uid)
  end

  def handle_info({:command_result, %{command_type: "mtr.run"} = msg}, socket) do
    {:noreply, MtrRuntime.refresh_if_relevant(socket, msg, get_device_ip(socket.assigns.results))}
  end

  def handle_info({:command_ack, %{command_type: "mtr.run"} = msg}, socket) do
    {:noreply, MtrRuntime.refresh_if_relevant(socket, msg, get_device_ip(socket.assigns.results))}
  end

  def handle_info({:command_progress, %{command_type: "mtr.run"} = msg}, socket) do
    {:noreply, MtrRuntime.refresh_if_relevant(socket, msg, get_device_ip(socket.assigns.results))}
  end

  def handle_info({:command_result, %{command_type: "endpoint_inventory." <> _} = msg}, socket) do
    {:noreply, EndpointInventoryRuntime.apply_command_update(socket, :result, msg)}
  end

  def handle_info({:command_ack, %{command_type: "endpoint_inventory." <> _} = msg}, socket) do
    {:noreply, EndpointInventoryRuntime.apply_command_update(socket, :ack, msg)}
  end

  def handle_info({:command_progress, %{command_type: "endpoint_inventory." <> _} = msg}, socket) do
    {:noreply, EndpointInventoryRuntime.apply_command_update(socket, :progress, msg)}
  end

  def handle_info({:mtr_trace_ingested, event}, socket) do
    {:noreply, MtrRuntime.refresh_if_relevant(socket, event, get_device_ip(socket.assigns.results))}
  end

  def handle_info({:flow_stats_loaded, device_uid, request_ref, stats_bundle}, socket) do
    current_ref = Map.get(socket.assigns, :flow_stats_request_ref)

    if device_uid == socket.assigns.device_uid and request_ref == current_ref do
      {:noreply, apply_flow_stats_bundle(socket, stats_bundle)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:flow_ip_enrichment_loaded, device_uid, request_ref, rdns_map, geo_iso2_map}, socket) do
    current_ref = Map.get(socket.assigns, :flow_ip_request_ref)

    if device_uid == socket.assigns.device_uid and request_ref == current_ref do
      {:noreply, apply_flow_ip_enrichment(socket, rdns_map, geo_iso2_map)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:device_details_loaded, device_uid, request_ref, assigns}, socket) do
    current_ref = Map.get(socket.assigns, :device_details_request_ref)

    if device_uid == socket.assigns.device_uid and request_ref == current_ref do
      {:noreply, apply_device_details_assigns(socket, assigns)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:device_metrics_loaded, device_uid, request_ref, assigns}, socket) do
    current_ref = Map.get(socket.assigns, :device_metrics_request_ref)

    if device_uid == socket.assigns.device_uid and request_ref == current_ref do
      {:noreply, apply_device_metrics_assigns(socket, assigns)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:command_result, _result}, socket), do: {:noreply, socket}
  def handle_info({:command_ack, _ack}, socket), do: {:noreply, socket}
  def handle_info({:command_progress, _progress}, socket), do: {:noreply, socket}

  def handle_info({:refresh_camera_relay_session, relay_session_id}, socket) do
    {:noreply, CameraRelayRuntime.refresh_session(socket, relay_session_id)}
  end

  def handle_info(msg, socket) do
    Logger.debug(fn ->
      "[DeviceLive.Show] unhandled message summary: " <> inspect(summarize_unhandled_msg(msg))
    end)

    {:noreply, socket}
  end

  @impl true
  def handle_async({:device_details, device_uid, request_ref}, {:ok, assigns}, socket) do
    current_ref = Map.get(socket.assigns, :device_details_request_ref)

    if device_uid == socket.assigns.device_uid and request_ref == current_ref do
      {:noreply, apply_device_details_assigns(socket, assigns)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:device_details, device_uid, request_ref}, {:exit, reason}, socket) do
    Logger.warning("Device details task failed for #{device_uid}: #{inspect(reason)}")

    if device_uid == socket.assigns.device_uid and
         request_ref == socket.assigns.device_details_request_ref do
      {:noreply, socket |> assign(:details_loading, false) |> assign(:device_details_request_ref, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:device_endpoint_inventory, device_uid, request_ref}, {:ok, inventory}, socket) do
    current_ref = Map.get(socket.assigns, :endpoint_inventory_request_ref)

    if device_uid == socket.assigns.device_uid and request_ref == current_ref do
      {:noreply, apply_endpoint_inventory_assigns(socket, inventory)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:device_endpoint_inventory, device_uid, request_ref}, {:exit, reason}, socket) do
    Logger.warning("Endpoint inventory task failed for #{device_uid}: #{inspect(reason)}")

    if device_uid == socket.assigns.device_uid and
         request_ref == socket.assigns.endpoint_inventory_request_ref do
      {:noreply,
       socket
       |> assign(:endpoint_inventory_loading, false)
       |> assign(:endpoint_inventory_request_ref, nil)
       |> assign(:endpoint_inventory_error, "Failed to load endpoint software inventory.")}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:device_metrics, device_uid, request_ref}, {:ok, assigns}, socket) do
    current_ref = Map.get(socket.assigns, :device_metrics_request_ref)

    if device_uid == socket.assigns.device_uid and request_ref == current_ref do
      {:noreply, apply_device_metrics_assigns(socket, assigns)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:device_metrics, device_uid, request_ref}, {:exit, reason}, socket) do
    Logger.warning("Device metrics task failed for #{device_uid}: #{inspect(reason)}")

    if device_uid == socket.assigns.device_uid and
         request_ref == socket.assigns.device_metrics_request_ref do
      {:noreply, socket |> assign(:metrics_loading, false) |> assign(:device_metrics_request_ref, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:device_interfaces, device_uid, request_ref}, {:ok, assigns}, socket) do
    if device_uid == socket.assigns.device_uid and request_ref == socket.assigns.interfaces_request_ref do
      interfaces = Map.get(assigns, :network_interfaces, [])
      error = Map.get(assigns, :interfaces_error)

      availability =
        cond do
          is_binary(error) -> :unknown
          interfaces != [] -> :available
          not is_nil(socket.assigns.discovery_job) -> :available
          true -> :unavailable
        end

      socket =
        socket
        |> assign(assigns)
        |> assign(:interfaces_loading, false)
        |> assign(:interfaces_request_ref, nil)
        |> assign(:interface_availability, availability)
        |> assign(:has_ifaces, availability != :unavailable)

      socket = maybe_leave_unavailable_tab(socket, "interfaces", availability)

      socket =
        if socket.assigns.active_tab == "interfaces" and availability != :unavailable do
          DeviceTabRuntime.begin_interface_metrics_refresh(socket, device_uid, srql_module())
        else
          socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:device_interfaces, device_uid, request_ref}, {:exit, reason}, socket) do
    Logger.warning("Device interfaces task failed for #{device_uid}: #{inspect(reason)}")

    if device_uid == socket.assigns.device_uid and request_ref == socket.assigns.interfaces_request_ref do
      {:noreply,
       socket
       |> assign(:interfaces_error, "Interface availability could not be confirmed. Retry this tab.")
       |> assign(:interfaces_loading, false)
       |> assign(:interfaces_request_ref, nil)
       |> assign(:interface_availability, :unknown)
       |> assign(:has_ifaces, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:interface_metrics, device_uid, request_ref}, {:ok, metrics}, socket) do
    if device_uid == socket.assigns.device_uid and request_ref == socket.assigns.interface_metrics_request_ref do
      {:noreply,
       socket
       |> assign(:interface_metrics, metrics)
       |> assign(:interface_metrics_loading, false)
       |> assign(:interface_metrics_request_ref, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:interface_metrics, device_uid, request_ref}, {:exit, reason}, socket) do
    Logger.warning("Interface metrics task failed for #{device_uid}: #{inspect(reason)}")

    if device_uid == socket.assigns.device_uid and request_ref == socket.assigns.interface_metrics_request_ref do
      {:noreply,
       socket
       |> assign(:interface_metrics, %{
         has_favorited: socket.assigns.favorited_interfaces != MapSet.new(),
         panels: [],
         error: "Failed to load favorited interface metrics",
         favorited_count: MapSet.size(socket.assigns.favorited_interfaces)
       })
       |> assign(:interface_metrics_loading, false)
       |> assign(:interface_metrics_request_ref, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:device_flows, device_uid, request_ref}, {:ok, {flows, pagination, error}}, socket) do
    if device_uid == socket.assigns.device_uid and request_ref == socket.assigns.flows_request_ref do
      availability =
        cond do
          is_binary(error) -> :unknown
          flows != [] -> :available
          true -> :unavailable
        end

      socket =
        socket
        |> assign(:device_flows, flows)
        |> assign(:flows_pagination, pagination)
        |> assign(:flows_error, error)
        |> assign(:flows_loading, false)
        |> assign(:flows_request_ref, nil)
        |> assign(:flow_availability, availability)
        |> assign(:has_flows, availability != :unavailable)

      socket = maybe_leave_unavailable_tab(socket, "flows", availability)

      socket =
        if socket.assigns.active_tab == "flows" and availability != :unavailable do
          socket
          |> FlowRuntime.begin_stats_refresh(device_uid, srql_module())
          |> FlowRuntime.begin_ip_enrichment(device_uid, flows)
        else
          socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:device_flows, device_uid, request_ref}, {:exit, reason}, socket) do
    Logger.warning("Device flows task failed for #{device_uid}: #{inspect(reason)}")

    if device_uid == socket.assigns.device_uid and request_ref == socket.assigns.flows_request_ref do
      {:noreply,
       socket
       |> assign(:flows_error, "Flow availability could not be confirmed. Retry this tab.")
       |> assign(:flows_loading, false)
       |> assign(:flows_request_ref, nil)
       |> assign(:flow_availability, :unknown)
       |> assign(:has_flows, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:flow_stats, device_uid, request_ref}, {:ok, stats_bundle}, socket) do
    current_ref = Map.get(socket.assigns, :flow_stats_request_ref)

    if device_uid == socket.assigns.device_uid and request_ref == current_ref do
      {:noreply, apply_flow_stats_bundle(socket, stats_bundle)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:flow_stats, device_uid, request_ref}, {:exit, reason}, socket) do
    Logger.warning("Device flow stats task failed for #{device_uid}: #{inspect(reason)}")

    if device_uid == socket.assigns.device_uid and
         request_ref == socket.assigns.flow_stats_request_ref do
      {:noreply, assign(socket, :flow_stats_loading, false)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:flow_ip_enrichment, device_uid, request_ref}, {:ok, {rdns_map, geo_iso2_map}}, socket) do
    current_ref = Map.get(socket.assigns, :flow_ip_request_ref)

    if device_uid == socket.assigns.device_uid and request_ref == current_ref do
      {:noreply, apply_flow_ip_enrichment(socket, rdns_map, geo_iso2_map)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:flow_ip_enrichment, device_uid, _request_ref}, {:exit, reason}, socket) do
    Logger.warning("Device flow IP enrichment task failed for #{device_uid}: #{inspect(reason)}")
    {:noreply, socket}
  end

  def handle_async({:device_logs, device_uid, request_ref}, {:ok, {logs, pagination, logs_error}}, socket) do
    if device_uid == socket.assigns.device_uid and request_ref == socket.assigns.logs_request_ref do
      {:noreply,
       socket
       |> assign(:device_logs, logs)
       |> assign(:logs_pagination, pagination)
       |> assign(:logs_error, logs_error)
       |> assign(:logs_loading, false)
       |> assign(:logs_request_ref, nil)
       |> assign(:has_logs, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:device_logs, device_uid, request_ref}, {:exit, reason}, socket) do
    Logger.warning("Device logs task failed for #{device_uid}: #{inspect(reason)}")

    if device_uid == socket.assigns.device_uid and request_ref == socket.assigns.logs_request_ref do
      {:noreply,
       socket
       |> assign(:device_logs, [])
       |> assign(:logs_pagination, %{})
       |> assign(:logs_error, "Failed to load logs")
       |> assign(:logs_loading, false)
       |> assign(:logs_request_ref, nil)
       |> assign(:has_logs, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(:northbound_interface_actions, {:ok, actions}, socket) when is_list(actions) do
    {:noreply,
     socket
     |> assign(:northbound_interface_actions, actions)
     |> assign(:northbound_interface_actions_loading, false)
     |> assign(:northbound_interface_actions_loaded, true)}
  end

  def handle_async(:northbound_interface_actions, {:exit, reason}, socket) do
    Logger.warning("Failed to load northbound interface actions: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:northbound_interface_actions, [])
     |> assign(:northbound_interface_actions_loading, false)
     |> assign(:northbound_interface_actions_loaded, true)}
  end

  defp apply_device_details_assigns(socket, assigns) do
    {requested_tab, device_row, srql_module, scope, params, supplemental_assigns} =
      pop_details_meta(assigns)

    refresh? = Map.get(socket.assigns, :device_load_mode, :full) == :refresh

    supplemental_assigns =
      socket
      |> preserve_virtualization_guests(supplemental_assigns, refresh?)
      |> then(&preserve_loaded_interfaces(socket, &1, refresh?))
      |> then(&preserve_loaded_flows(socket, &1, refresh?))

    socket =
      socket
      |> assign(supplemental_assigns)
      |> assign(:details_loading, false)
      |> assign(:device_details_request_ref, nil)

    resolve_active_tab_after_details(
      socket,
      requested_tab,
      device_row,
      srql_module,
      scope,
      params,
      supplemental_assigns,
      refresh?
    )
  end

  # A PVE node's Guests tab must not flicker off when a same-device refresh
  # transiently fails to reload the virtualization inventory.
  # load_virtualization_summary/2 rescues errors to nil, and a contended guest
  # read can return an empty list — either flips has_virtualization_guests false
  # and unmounts the tab (resolve_active_tab downgrades "guests" -> "details").
  # On a refresh, keep the previously rendered non-empty summary when the
  # incoming batch would otherwise hide the tab. Full loads / device switches
  # (refresh? == false) still swap wholesale so a genuinely guest-less host or a
  # different device never keeps stale guests.
  defp preserve_virtualization_guests(socket, supplemental_assigns, true = _refresh?) do
    incoming_has_guests? = Map.get(supplemental_assigns, :has_virtualization_guests, false)
    current_has_guests? = Map.get(socket.assigns, :has_virtualization_guests, false)
    current_summary = Map.get(socket.assigns, :virtualization_summary)

    if current_has_guests? and not incoming_has_guests? and is_map(current_summary) do
      supplemental_assigns
      |> Map.put(:has_virtualization_guests, true)
      |> Map.put(:virtualization_summary, current_summary)
    else
      supplemental_assigns
    end
  end

  defp preserve_virtualization_guests(_socket, supplemental_assigns, false = _refresh?) do
    supplemental_assigns
  end

  # Same-device refresh can time out the interface/flow tasks in the 15s
  # supplemental batch. An empty incoming list would wipe the already-rendered
  # table and (via resolve_active_tab) bounce the user back to Details.
  defp preserve_loaded_interfaces(socket, supplemental_assigns, true = _refresh?) do
    incoming = Map.get(supplemental_assigns, :network_interfaces, [])
    current = Map.get(socket.assigns, :network_interfaces, [])

    if current != [] and incoming == [] do
      supplemental_assigns
      |> Map.put(:network_interfaces, current)
      |> Map.put(:has_ifaces, true)
      |> Map.put(:interface_availability, Map.get(socket.assigns, :interface_availability, :available))
      |> Map.put(:interfaces_error, Map.get(socket.assigns, :interfaces_error))
      |> Map.put(:favorited_interfaces, Map.get(socket.assigns, :favorited_interfaces, MapSet.new()))
      |> Map.put(
        :metrics_enabled_interfaces,
        Map.get(socket.assigns, :metrics_enabled_interfaces, MapSet.new())
      )
    else
      supplemental_assigns
    end
  end

  defp preserve_loaded_interfaces(_socket, supplemental_assigns, false = _refresh?) do
    supplemental_assigns
  end

  defp preserve_loaded_flows(socket, supplemental_assigns, true = _refresh?) do
    incoming = Map.get(supplemental_assigns, :device_flows, [])
    current = Map.get(socket.assigns, :device_flows, [])

    if current != [] and incoming == [] do
      supplemental_assigns
      |> Map.put(:device_flows, current)
      |> Map.put(:has_flows, true)
      |> Map.put(:flow_availability, Map.get(socket.assigns, :flow_availability, :available))
      |> Map.put(:flows_error, Map.get(socket.assigns, :flows_error))
      |> Map.put(:flows_pagination, Map.get(socket.assigns, :flows_pagination, %{}))
    else
      supplemental_assigns
    end
  end

  defp preserve_loaded_flows(_socket, supplemental_assigns, false = _refresh?) do
    supplemental_assigns
  end

  defp pop_details_meta(assigns) do
    requested_tab = Map.get(assigns, :__requested_tab__, "details")
    device_row = Map.get(assigns, :__device_row__)
    srql_module = Map.get(assigns, :__srql_module__, srql_module())
    scope = Map.get(assigns, :__scope__)
    params = Map.get(assigns, :__params__, %{})

    supplemental_assigns =
      Map.drop(assigns, [:__requested_tab__, :__device_row__, :__srql_module__, :__scope__, :__params__])

    {requested_tab, device_row, srql_module, scope, params, supplemental_assigns}
  end

  # The details tab is fixed, so there is nothing to re-resolve and no
  # tab-specific follow-up loads.
  defp resolve_active_tab_after_details(socket, "details", _row, _srql, _scope, _params, _supp, _refresh?) do
    assign(socket, :active_tab, "details")
  end

  # Other tabs: now that the supplemental batch reported which tabs have data,
  # re-resolve the active tab (it may downgrade to "details") and kick the
  # tab-specific background loads that must run in the LiveView process. On a
  # same-device refresh those follow-up loads preserve the rendered data
  # instead of blanking it while their async results are in flight.
  defp resolve_active_tab_after_details(socket, requested_tab, device_row, srql_module, scope, params, supp, refresh?) do
    active_tab =
      requested_tab
      |> DeviceTabRuntime.resolve_active_tab(
        Map.get(supp, :has_ifaces, false),
        Map.get(supp, :has_flows, false),
        Map.get(supp, :has_logs, false),
        Map.get(supp, :has_mtr, false),
        Map.get(supp, :has_virtualization_guests, false)
      )
      |> DeviceTabRuntime.authorize_active_tab(device_row, scope)

    srql =
      QueryData.srql_for_tab_if_needed(active_tab, socket.assigns.device_uid, socket.assigns.limit, socket.assigns.srql)

    socket
    |> assign(:active_tab, active_tab)
    |> assign(:srql, srql)
    |> maybe_begin_interface_metrics_refresh(active_tab, socket.assigns.device_uid, srql_module)
    |> DeviceTabRuntime.maybe_load_mtr_for_active_tab(active_tab)
    |> DeviceTabRuntime.maybe_reload_logs_for_active_tab(
      active_tab,
      socket.assigns.device_uid,
      QueryData.normalize_cursor(Map.get(params, "cursor")),
      srql_module,
      tab_runtime_opts() ++ [preserve_rendered: refresh?]
    )
    |> FlowRuntime.begin_background_loads(
      active_tab,
      socket.assigns.device_uid,
      Map.get(supp, :device_flows, []),
      srql_module,
      preserve_rendered: refresh?
    )
  end

  defp maybe_begin_interface_metrics_refresh(socket, "interfaces", uid, srql_module) do
    DeviceTabRuntime.begin_interface_metrics_refresh(socket, uid, srql_module)
  end

  defp maybe_begin_interface_metrics_refresh(socket, _active_tab, _uid, _srql_module), do: socket

  defp maybe_leave_unavailable_tab(socket, tab, :unavailable) do
    if socket.assigns.active_tab == tab do
      socket
      |> assign(:active_tab, "details")
      |> push_patch(to: ~p"/devices/#{socket.assigns.device_uid}", replace: true)
    else
      socket
    end
  end

  defp maybe_leave_unavailable_tab(socket, _tab, _availability), do: socket

  defp apply_device_metrics_assigns(socket, assigns) do
    assigns = annotate_metric_section_assigns(assigns, Map.get(socket.assigns, :anomaly_capacity_detail))

    socket
    |> assign(assigns)
    |> assign(:metrics_loading, false)
    |> assign(:device_metrics_request_ref, nil)
  end

  defp annotate_metric_section_assigns(assigns, selected_detail) when is_map(assigns) do
    case {Map.get(assigns, :metric_sections), Map.get(assigns, :anomaly_capacity)} do
      {sections, anomaly_capacity} when is_list(sections) and is_map(anomaly_capacity) ->
        selected_row = selected_anomaly_row(selected_detail)

        Map.put(
          assigns,
          :metric_sections,
          SysmonMetrics.annotate_metric_sections(sections, anomaly_capacity, selected_row)
        )

      _ ->
        assigns
    end
  end

  defp annotate_metric_section_assigns(assigns, _selected_detail), do: assigns

  defp selected_anomaly_row(%{kind: kind, row: %{} = row}) when kind in ["anomaly", "capacity_notice"], do: row
  defp selected_anomaly_row(_), do: nil

  defp apply_flow_stats_bundle(socket, stats_bundle) do
    {flow_stats, sparkline_json, proto_json, chart_keys, chart_points, top_talkers_json, top_destinations_json,
     top_peers_json, top_ports_json, top_protocols_json, facets} = stats_bundle

    socket
    |> assign(:flow_stats, flow_stats)
    |> assign(:flow_stats_loading, false)
    |> assign(:flow_sparkline_json, sparkline_json)
    |> assign(:flow_proto_json, proto_json)
    |> assign(:flow_chart_keys_json, chart_keys)
    |> assign(:flow_chart_points_json, chart_points)
    |> assign(:flow_top_talkers_json, top_talkers_json)
    |> assign(:flow_top_destinations_json, top_destinations_json)
    |> assign(:flow_top_peers_json, top_peers_json)
    |> assign(:flow_top_ports_json, top_ports_json)
    |> assign(:flow_top_protocols_json, top_protocols_json)
    |> assign(:flow_facets, facets)
  end

  defp apply_flow_ip_enrichment(socket, rdns_map, geo_iso2_map) do
    socket
    |> assign(:rdns_map, rdns_map)
    |> assign(:geo_iso2_map, geo_iso2_map)
  end

  defp summarize_unhandled_msg(msg) when is_tuple(msg) do
    %{kind: :tuple, tuple_size: tuple_size(msg), first: elem(msg, 0)}
  end

  defp summarize_unhandled_msg(msg) when is_map(msg) do
    %{kind: :map, map_size: map_size(msg)}
  end

  defp summarize_unhandled_msg(msg) when is_list(msg) do
    %{kind: :list, length: length(msg)}
  end

  defp summarize_unhandled_msg(msg), do: %{kind: :other, type: msg |> term_type() |> to_string()}

  defp term_type(term) when is_atom(term), do: :atom
  defp term_type(term) when is_binary(term), do: :binary
  defp term_type(term) when is_boolean(term), do: :boolean
  defp term_type(term) when is_float(term), do: :float
  defp term_type(term) when is_function(term), do: :function
  defp term_type(term) when is_integer(term), do: :integer
  defp term_type(term) when is_pid(term), do: :pid
  defp term_type(term) when is_port(term), do: :port
  defp term_type(term) when is_reference(term), do: :reference
  defp term_type(term) when is_bitstring(term), do: :bitstring
  defp term_type(_term), do: :unknown

  # Device lifecycle broadcasts arrive on a global topic for every device in
  # the deployment, so the currently displayed device can be "refreshed" far
  # more often than its data meaningfully changes. Refreshes of the
  # already-loaded device are therefore (a) non-destructive — mode: :refresh
  # keeps the rendered supplemental data on screen while the async batch
  # fetches fresh values — and (b) coalesced: broadcasts are ignored while a
  # refresh is in flight, and rate-limited to one per cooldown window with a
  # single trailing refresh scheduled so the page still converges.
  defp maybe_refresh_current_device(socket, uid) when is_binary(uid) do
    if uid == socket.assigns.device_uid do
      coalesce_device_refresh(socket, uid)
    else
      {:noreply, socket}
    end
  end

  defp maybe_refresh_current_device(socket, _uid), do: {:noreply, socket}

  defp coalesce_device_refresh(socket, uid) do
    cond do
      device_refresh_in_flight?(socket) ->
        {:noreply, socket}

      device_refresh_cooldown_remaining(socket) > 0 ->
        {:noreply, schedule_trailing_device_refresh(socket, uid)}

      true ->
        refresh_current_device(socket, uid)
    end
  end

  defp refresh_current_device(socket, uid) do
    params =
      socket.assigns
      |> Map.get(:last_params, %{})
      |> Map.put("uid", uid)

    uri = Map.get(socket.assigns, :last_uri, "/devices/#{uid}")
    limit = QueryData.parse_limit(Map.get(params, "limit"), socket.assigns.limit, @max_limit)

    requested_tab =
      DeviceTabRuntime.normalize_requested_tab(
        Map.get(params, "tab"),
        socket.assigns.active_tab
      )

    load_device_data(socket, uid, limit, requested_tab, params, uri, mode: :refresh)
  end

  defp device_refresh_in_flight?(socket) do
    is_reference(Map.get(socket.assigns, :device_details_request_ref))
  end

  defp device_refresh_cooldown_remaining(socket) do
    case Map.get(socket.assigns, :device_refresh_last_at) do
      nil ->
        0

      last_at ->
        device_refresh_cooldown_ms() - (System.monotonic_time(:millisecond) - last_at)
    end
  end

  # Cancel/replace any pending trailing timer so rapid broadcast bursts
  # collapse into exactly one deferred refresh at cooldown expiry.
  defp schedule_trailing_device_refresh(socket, uid) do
    socket = cancel_trailing_device_refresh(socket)
    delay = max(device_refresh_cooldown_remaining(socket), 0)
    timer = Process.send_after(self(), {:deferred_device_refresh, uid}, delay)
    assign(socket, :device_refresh_timer, timer)
  end

  defp cancel_trailing_device_refresh(socket) do
    case Map.get(socket.assigns, :device_refresh_timer) do
      nil ->
        socket

      timer ->
        Process.cancel_timer(timer)
        assign(socket, :device_refresh_timer, nil)
    end
  end

  defp device_refresh_cooldown_ms do
    Application.get_env(:serviceradar_web_ng, :device_refresh_cooldown_ms, @device_refresh_cooldown_ms)
  end

  defp begin_device_metrics_refresh(socket, uid, srql_module, sysmon_identity, scope) do
    request_ref = make_ref()
    can_view_anomaly_capacity? = RBAC.can?(scope, "observability.alerts.view")
    anomaly_filters = Map.get(socket.assigns, :anomaly_capacity_filters, %{})
    time_range = sysmon_time_range(socket)
    metric_opts = [time_range: time_range]

    # Remember the resolved identity + range so the range selector can re-run
    # this async load without re-deriving the device identity.
    socket =
      socket
      |> assign(:sysmon_identity, sysmon_identity)
      |> assign(:sysmon_time_range, time_range)

    if Application.get_env(:serviceradar_web_ng, :env) == :test do
      sysmon_filters =
        SysmonMetrics.resolve_sysmon_filter_tokens(srql_module, sysmon_identity, scope)

      assigns = %{
        metric_sections: SysmonMetrics.load_metric_sections(srql_module, sysmon_filters, scope, metric_opts),
        process_metrics: SysmonMetrics.load_process_metrics(srql_module, sysmon_filters, scope),
        sysmon_presence: sysmon_filters != [],
        can_view_anomaly_capacity: can_view_anomaly_capacity?,
        anomaly_capacity:
          maybe_load_anomaly_capacity(
            can_view_anomaly_capacity?,
            srql_module,
            sysmon_identity,
            scope,
            anomaly_filters
          )
      }

      socket
      |> assign(:device_metrics_request_ref, request_ref)
      |> assign(:metrics_loading, false)
      |> apply_device_metrics_assigns(assigns)
    else
      socket
      |> assign(:device_metrics_request_ref, request_ref)
      |> assign(:metrics_loading, true)
      |> start_async({:device_metrics, uid, request_ref}, fn ->
        sysmon_filters =
          SysmonMetrics.resolve_sysmon_filter_tokens(srql_module, sysmon_identity, scope)

        %{
          metric_sections: SysmonMetrics.load_metric_sections(srql_module, sysmon_filters, scope, metric_opts),
          process_metrics: SysmonMetrics.load_process_metrics(srql_module, sysmon_filters, scope),
          sysmon_presence: sysmon_filters != [],
          can_view_anomaly_capacity: can_view_anomaly_capacity?,
          anomaly_capacity:
            maybe_load_anomaly_capacity(
              can_view_anomaly_capacity?,
              srql_module,
              sysmon_identity,
              scope,
              anomaly_filters
            )
        }
      end)
    end
  end

  @sysmon_time_ranges ~w(last_1h last_6h last_24h last_7d)

  defp sysmon_time_range(socket) do
    case Map.get(socket.assigns, :sysmon_time_range) do
      range when range in @sysmon_time_ranges -> range
      _ -> "last_24h"
    end
  end

  # Switch the sysmon charts to a new window and re-run the metric load using the
  # already-resolved device identity, so the bucket resizes to the range.
  defp apply_sysmon_time_range(socket, range) when range in @sysmon_time_ranges do
    if range == sysmon_time_range(socket) do
      socket
    else
      socket = assign(socket, :sysmon_time_range, range)

      case Map.get(socket.assigns, :sysmon_identity) do
        identity when is_map(identity) and map_size(identity) > 0 ->
          begin_device_metrics_refresh(
            socket,
            socket.assigns.device_uid,
            srql_module(),
            identity,
            socket.assigns.current_scope
          )

        _ ->
          socket
      end
    end
  end

  defp apply_sysmon_time_range(socket, _range), do: socket

  defp maybe_load_anomaly_capacity(true, srql_module, sysmon_identity, scope, filters) do
    AnomalyCapacityData.load(srql_module, sysmon_identity, scope, anomaly_load_opts(filters))
  end

  defp maybe_load_anomaly_capacity(false, _srql_module, _sysmon_identity, _scope, _filters) do
    AnomalyCapacityData.empty()
  end

  defp load_device_data(socket, uid, limit, requested_tab, params, uri, opts \\ []) do
    refresh? = Keyword.get(opts, :mode, :full) == :refresh
    default_query = QueryData.default_device_query(uid, limit)

    query = normalized_device_query(params, default_query)

    srql_module = srql_module()
    scope = Map.get(socket.assigns, :current_scope)

    # Phase 1: Main device query (must be first — everything depends on device_row)
    {results, error, viz} = QueryData.execute(srql_module, query, scope)

    page_path = uri |> to_string() |> URI.parse() |> Map.get(:path)
    active_camera_relay_session = CameraRelayRuntime.preserve_active_session(socket, uid)
    last_camera_relay_session = CameraRelayRuntime.preserve_last_session(socket, uid)

    base_srql =
      Map.merge(socket.assigns.srql, %{
        entity: "devices",
        page_path: page_path,
        query: query,
        draft: query,
        error: error,
        viz: viz,
        loading: false
      })

    srql_response = %{"results" => results, "viz" => viz}

    # Resolve the agent linkage once (platform.ocsf_agents device_uid) and tag
    # the device rows so render-time badge predicates never re-query. Panels
    # above are built from the untagged SRQL response, so the virtual keys do
    # not leak into table panels.
    results = DeviceStateData.tag_agent_device(results, uid)

    device_row =
      results
      |> Enum.find(&is_map/1)
      |> MetadataData.enrich_integration_metadata(scope)

    device_ip = get_device_ip(results)
    show_stale = socket.assigns.show_stale_aliases
    request_ref = make_ref()

    supplemental_context = %{
      srql_module: srql_module,
      uid: uid,
      scope: scope,
      params: params,
      requested_tab: requested_tab,
      device_row: device_row,
      device_ip: device_ip,
      show_stale: show_stale,
      include_metrics?: false,
      current_scope: socket.assigns.current_scope
    }

    # Phase 2: render the page shell immediately on the device row alone. Every
    # supplemental panel (availability, virtualization, cameras, interfaces,
    # flows, logs, MTR, …) is template-guarded by safe defaults, so the shell is
    # fully valid before the supplemental batch resolves. The expensive batch is
    # streamed in via start_async/{:device_details} (handle_async →
    # apply_device_details_assigns). active_tab is resolved optimistically to the
    # requested tab and re-resolved once the batch reports which tabs have data.
    socket
    |> cancel_trailing_device_refresh()
    |> assign(:device_refresh_last_at, System.monotonic_time(:millisecond))
    |> assign(:device_load_mode, if(refresh?, do: :refresh, else: :full))
    |> assign(:device_uid, uid)
    |> assign(:limit, limit)
    |> assign(:results, results)
    |> maybe_reset_supplemental_defaults(refresh?)
    |> assign(:active_tab, requested_tab)
    |> assign(
      :panels,
      srql_response
      |> Engine.build_panels()
      |> drop_low_value_categories()
      |> drop_table_panels()
    )
    |> assign(:active_camera_relay_session, active_camera_relay_session)
    |> assign(:last_camera_relay_session, last_camera_relay_session)
    |> assign(:device_snmp_credential, socket.assigns.device_snmp_credential)
    |> assign(:srql, base_srql)
    |> AnsiblePanelRuntime.assign_device_ansible(device_row, uid, scope, refresh?)
    |> assign(:device_details_request_ref, request_ref)
    |> assign(:details_loading, true)
    |> begin_device_metrics_refresh(
      uid,
      srql_module,
      SysmonMetrics.sysmon_identity(device_row, uid),
      scope
    )
    |> begin_device_details_refresh(uid, request_ref, supplemental_context)
    |> begin_endpoint_inventory_refresh(uid, scope)
    |> then(&{:noreply, &1})
  end

  # On a same-device refresh (mode: :refresh) keep the currently rendered
  # supplemental data on screen — the async batch swaps in fresh values
  # wholesale when it lands, so the tabs never unmount mid-refresh. Initial
  # mounts and device switches still reset to safe defaults so stale data
  # from a previously viewed device never leaks into the new shell.
  defp maybe_reset_supplemental_defaults(socket, true = _refresh?), do: socket

  defp maybe_reset_supplemental_defaults(socket, false = _refresh?) do
    reset_supplemental_defaults(socket)
  end

  # Reset every supplemental assign to a safe default before the async batch
  # repopulates them. Keeps stale data from a previously viewed device out of
  # the shell while the new batch is in flight.
  defp reset_supplemental_defaults(socket) do
    socket
    |> assign(:network_interfaces, [])
    |> assign(:interfaces_error, nil)
    |> assign(:has_ifaces, false)
    |> assign(:interface_availability, :checking)
    |> assign(:interfaces_loading, false)
    |> assign(:interfaces_request_ref, nil)
    |> assign(:device_flows, [])
    |> assign(:flows_error, nil)
    |> assign(:flows_pagination, %{})
    |> assign(:has_flows, false)
    |> assign(:flow_availability, :checking)
    |> assign(:flows_loading, false)
    |> assign(:flows_request_ref, nil)
    |> assign(:device_logs, [])
    |> assign(:logs_error, nil)
    |> assign(:logs_pagination, %{})
    |> assign(:logs_loading, false)
    |> assign(:logs_request_ref, nil)
    |> assign(:logs_cursor, nil)
    |> assign(:has_logs, false)
    |> assign(:has_mtr, false)
    |> assign(:discovery_job, nil)
    |> assign(:favorited_interfaces, MapSet.new())
    |> assign(:interface_metrics, nil)
    |> assign(:interface_metrics_loading, false)
    |> assign(:interface_metrics_request_ref, nil)
    |> assign(:metrics_enabled_interfaces, MapSet.new())
    |> assign(:ip_aliases, [])
    |> assign(:ip_alias_error, nil)
    |> assign(:availability, nil)
    |> assign(:agent_availability, [])
    |> assign(:composite_verdicts, [])
    |> assign(:healthcheck_summary, nil)
    |> assign(:virtualization_summary, nil)
    |> assign(:has_virtualization_guests, false)
    |> assign(:rdp_desktop_target, nil)
    |> assign(:sweep_results, nil)
    |> assign(:metric_sections, [])
    |> assign(:sysmon_presence, false)
    |> assign(:process_metrics, nil)
    |> assign(:process_metrics_search, "")
    |> assign(:process_metrics_page, 1)
    |> assign(:process_listeners_search, "")
    |> assign(:process_listeners_page, 1)
    |> assign(:camera_sources, [])
    |> assign(:camera_inventory_error, nil)
    |> assign(:sysmon_profile_info, nil)
    |> assign(:available_profiles, [])
    |> assign(:snmp_polling_source, ServiceRadarWebNGWeb.DeviceLive.SNMPPollingSource.empty())
    |> assign(:northbound_device_history, [])
    |> assign(:northbound_device_history_error, nil)
    |> assign(:endpoint_inventory_scan, nil)
    |> assign(:endpoint_inventory_scans, [])
    |> assign(:endpoint_inventory_packages, [])
    |> assign(:endpoint_inventory_package_total, 0)
    |> assign(:endpoint_inventory_artifacts, [])
    |> assign(:endpoint_inventory_vulnerability_assessments, EndpointInventoryData.empty_assessment_pages())
    |> assign(:endpoint_inventory_cpe_catalog_current, true)
    |> assign(:endpoint_inventory_error, nil)
    |> assign(:has_software_inventory, false)
    |> assign(:endpoint_inventory_loading, true)
    |> assign(:endpoint_inventory_request_ref, nil)
    |> assign(:bumblebee_postures, [])
    |> assign(:bumblebee_findings, [])
    |> assign(:bumblebee_error, nil)
    |> assign(:has_bumblebee_exposure, false)
  end

  # Loads the full supplemental batch (virtualization, cameras, availability,
  # interfaces, flows, logs, MTR detection, …). In the test env we run it
  # synchronously so LiveViewTest's initial render is fully populated (mirrors
  # begin_device_metrics_refresh); in prod it runs off-process via start_async
  # so handle_params returns immediately after the device row resolves.
  defp begin_device_details_refresh(socket, uid, request_ref, context) do
    if Application.get_env(:serviceradar_web_ng, :env) == :test do
      assigns = load_device_details_assigns(context)
      apply_device_details_assigns(socket, assigns)
    else
      start_async(socket, {:device_details, uid, request_ref}, fn ->
        load_device_details_assigns(context)
      end)
    end
  end

  # Software packages + vulnerability matches must not wait on the details
  # batch. That batch's yield_many also runs has_ifaces/has_flows SRQL probes,
  # which can take the full 15s tab timeout and kept Software empty until they
  # finished.
  defp begin_endpoint_inventory_refresh(socket, uid, scope) do
    request_ref = make_ref()
    keep_existing? = software_inventory_present?(socket.assigns)

    if Application.get_env(:serviceradar_web_ng, :env) == :test do
      apply_endpoint_inventory_assigns(socket, EndpointInventoryData.load(scope, uid))
    else
      socket
      |> assign(:endpoint_inventory_request_ref, request_ref)
      |> assign(:endpoint_inventory_loading, not keep_existing?)
      |> start_async({:device_endpoint_inventory, uid, request_ref}, fn ->
        EndpointInventoryData.load(scope, uid)
      end)
    end
  end

  defp apply_endpoint_inventory_assigns(socket, inventory) when is_map(inventory) do
    socket
    |> assign(:endpoint_inventory_scan, Map.get(inventory, :scan))
    |> assign(:endpoint_inventory_scans, Map.get(inventory, :scans, []))
    |> assign(:endpoint_inventory_packages, Map.get(inventory, :packages, []))
    |> assign(:endpoint_inventory_package_total, Map.get(inventory, :package_total, 0))
    |> assign(:endpoint_inventory_package_page, Map.get(inventory, :package_page, 1))
    |> assign(
      :endpoint_inventory_package_page_size,
      Map.get(inventory, :package_page_size, EndpointInventoryData.default_page_size())
    )
    |> assign(
      :endpoint_inventory_stored_package_count,
      Map.get(inventory, :stored_package_count, 0)
    )
    |> assign(:endpoint_inventory_artifacts, Map.get(inventory, :artifacts, []))
    |> assign(
      :endpoint_inventory_vulnerability_assessments,
      Map.get(inventory, :vulnerability_assessments, EndpointInventoryData.empty_assessment_pages())
    )
    |> assign(:endpoint_inventory_cpe_catalog_current, Map.get(inventory, :cpe_catalog_current, true))
    |> assign(:endpoint_inventory_error, Map.get(inventory, :error))
    |> assign(:has_software_inventory, Map.get(inventory, :has_inventory, false))
    |> assign(:endpoint_inventory_loading, false)
    |> assign(:endpoint_inventory_request_ref, nil)
  end

  defp software_inventory_present?(assigns) do
    assigns.endpoint_inventory_packages != [] or
      assessment_total(assigns.endpoint_inventory_vulnerability_assessments) > 0
  end

  defp assessment_total(pages) when is_map(pages) do
    pages
    |> Map.values()
    |> Enum.reduce(0, fn page, total ->
      total + if(is_map(page), do: Map.get(page, :total, Map.get(page, "total", 0)), else: 0)
    end)
  end

  defp assessment_total(_pages), do: 0

  # Runs inside the async task (or synchronously in tests). Returns a plain map
  # of assigns; the follow-up tab resolution and background loads that must run
  # in the LiveView process happen in apply_device_details_assigns/2.
  defp load_device_details_assigns(context) do
    %{
      srql_module: srql_module,
      uid: uid,
      scope: scope,
      device_row: device_row,
      requested_tab: requested_tab
    } = context

    virtualization_summary = VirtualizationData.load_virtualization_summary(scope, uid)

    rdp_desktop_target =
      case RemoteAccessData.rdp_target_for_device(scope, uid) do
        {:ok, target} -> target
        {:error, _reason} -> nil
      end

    {camera_sources, camera_inventory_error} =
      CameraData.load_sources(scope, uid, device_row, &DeviceActionRuntime.format_ash_error/1)

    timeout_ms =
      if requested_tab == "details", do: @details_supplemental_timeout_ms, else: @tab_supplemental_timeout_ms

    load_context =
      context
      |> Map.put(:virtualization_summary, virtualization_summary)
      |> Map.put(:camera_sources, camera_sources)
      |> Map.put(:camera_inventory_error, camera_inventory_error)
      |> Map.put(:supplemental_timeout_ms, timeout_ms)

    supplemental_assigns =
      DeviceSupplementalData.load(load_context, supplemental_load_opts())

    Map.merge(supplemental_assigns, %{
      rdp_desktop_target: rdp_desktop_target,
      __requested_tab__: Map.get(context, :requested_tab, "details"),
      __device_row__: device_row,
      __srql_module__: srql_module,
      __scope__: scope,
      __params__: Map.get(context, :params, %{})
    })
  end

  defp supplemental_load_opts do
    [
      slow_device_task_ms: @slow_device_task_ms,
      flows_limit: @flows_limit,
      logs_limit: @logs_limit,
      supplemental_timeout_ms: @tab_supplemental_timeout_ms
    ]
  end

  defp tab_runtime_opts do
    [
      flows_limit: @flows_limit,
      logs_limit: @logs_limit
    ]
  end

  defp normalized_device_query(params, default_query) do
    params
    |> Map.get("q", default_query)
    |> to_string()
    |> String.trim()
    |> case do
      "" -> default_query
      other -> other
    end
  end

  @impl true
  def handle_event("srql_change", %{"q" => q}, socket) do
    {:noreply, assign(socket, :srql, Map.put(socket.assigns.srql, :draft, to_string(q)))}
  end

  def handle_event("srql_paginate", params, socket) do
    cursor = QueryData.normalize_cursor(Map.get(params, "cursor"))

    page =
      case Integer.parse(to_string(Map.get(params, "page") || "1")) do
        {n, ""} when n > 0 -> n
        _ -> 1
      end

    uid = socket.assigns.device_uid
    tab = socket.assigns.active_tab

    socket =
      socket
      |> assign(:pagination_page, page)
      |> DeviceTabRuntime.reload_for_active_tab(
        tab,
        uid,
        cursor,
        srql_module(),
        tab_runtime_opts()
      )

    {:noreply, socket}
  end

  def handle_event("srql_reset", _params, socket) do
    page_path = socket.assigns.srql[:page_path] || "/devices/#{socket.assigns.device_uid}"
    query = QueryData.default_device_query(socket.assigns.device_uid, socket.assigns.limit)

    {:noreply, push_patch(socket, to: page_path <> "?" <> URI.encode_query(%{"q" => query}))}
  end

  def handle_event("srql_submit", %{"q" => q}, socket) do
    page_path = socket.assigns.srql[:page_path] || "/devices/#{socket.assigns.device_uid}"

    raw_query =
      q
      |> to_string()
      |> String.trim()
      |> case do
        "" -> to_string(socket.assigns.srql[:query] || "")
        other -> other
      end

    query = SRQLPage.shortcut_query(raw_query)

    # Only route a devices query to the index when it is NOT scoped to a single
    # device via `uid:`. The device-details default query is
    # `in:devices uid:"<uid>" ...`; reclassifying it to "/devices" turned a
    # same-page submit into a push_navigate to the index (a self-inflicted
    # remount). A broad `in:devices` search (no uid:) still navigates to the list.
    page_path =
      if String.starts_with?(query, "in:devices") and not String.contains?(query, "uid:") do
        "/devices"
      else
        page_path
      end

    current_path = socket.assigns.srql[:page_path] || "/devices/#{socket.assigns.device_uid}"

    target =
      page_path <> "?" <> URI.encode_query(%{"q" => query, "limit" => socket.assigns.limit})

    socket =
      if page_path == current_path do
        push_patch(socket, to: target)
      else
        push_navigate(socket, to: target)
      end

    {:noreply, socket}
  end

  def handle_event("toggle_edit", _params, socket) do
    {:noreply, DeviceActionRuntime.toggle_edit(socket)}
  end

  def handle_event("delete_device", _params, socket) do
    {:noreply, DeviceActionRuntime.delete_device(socket)}
  end

  def handle_event("restore_device", _params, socket) do
    {:noreply, DeviceActionRuntime.restore_device(socket)}
  end

  def handle_event("mark_device_active", _params, socket) do
    {:noreply, DeviceActionRuntime.mark_active(socket, true)}
  end

  def handle_event("mark_device_inactive", _params, socket) do
    {:noreply, DeviceActionRuntime.mark_active(socket, false)}
  end

  def handle_event("toggle_aliases", _params, socket) do
    {:noreply, DeviceActionRuntime.toggle_aliases(socket)}
  end

  def handle_event("set_availability_source", %{"agent_id" => agent_id}, socket) do
    {:noreply, DeviceActionRuntime.set_availability_source(socket, agent_id)}
  end

  def handle_event(
        "open_camera_relay",
        %{"camera_source_id" => camera_source_id, "stream_profile_id" => stream_profile_id} = params,
        socket
      ) do
    {:noreply, DeviceActionRuntime.open_camera_relay(socket, camera_source_id, stream_profile_id, params)}
  end

  def handle_event("close_camera_relay", _params, socket) do
    {:noreply, DeviceActionRuntime.close_camera_relay(socket)}
  end

  def handle_event("ansible_launch_open", _params, socket) do
    {:noreply, AnsiblePanelRuntime.open_launch(socket)}
  end

  def handle_event("ansible_launch_close", _params, socket) do
    {:noreply, AnsiblePanelRuntime.close_launch(socket)}
  end

  def handle_event("ansible_launch_change", params, socket) do
    {:noreply, AnsiblePanelRuntime.change_launch(socket, params)}
  end

  def handle_event("ansible_launch", params, socket) do
    {:noreply, AnsiblePanelRuntime.launch(socket, params)}
  end

  def handle_event("validate_device", %{"device" => params}, socket) do
    {:noreply, DeviceActionRuntime.validate_device(socket, params)}
  end

  def handle_event("save_device", %{"device" => params}, socket) do
    {:noreply, DeviceActionRuntime.save_device(socket, params)}
  end

  def handle_event("snmp_form_change", %{"snmp" => params}, socket) do
    {:noreply, DeviceActionRuntime.change_snmp_form(socket, params)}
  end

  def handle_event("save_snmp_credentials", %{"snmp" => params}, socket) do
    {:noreply, DeviceActionRuntime.save_snmp_credentials(socket, params)}
  end

  def handle_event("clear_snmp_credentials", _params, socket) do
    {:noreply, DeviceActionRuntime.clear_snmp_credentials(socket)}
  end

  def handle_event("sysmon_set_range", %{"range" => range}, socket) do
    {:noreply, apply_sysmon_time_range(socket, range)}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab = DeviceTabRuntime.resolve_active_tab(socket, tab)

    srql =
      QueryData.srql_for_tab(
        tab,
        socket.assigns.device_uid,
        socket.assigns.limit,
        socket.assigns.srql
      )

    # Update URL with tab parameter for shareable/bookmarkable links
    path =
      IndexPath.show_path(socket.assigns.device_uid,
        tab: tab,
        return_to: socket.assigns.devices_return_path
      )

    uid = socket.assigns.device_uid

    socket =
      socket
      |> DeviceTabRuntime.reload_for_active_tab(tab, uid, nil, srql_module(), tab_runtime_opts())
      |> DeviceTabRuntime.maybe_load_mtr_for_active_tab(tab)

    {:noreply,
     socket
     |> assign(:active_tab, tab)
     |> assign(:srql, srql)
     |> push_patch(to: path, replace: true)}
  end

  def handle_event("run_mtr", _params, socket) do
    device_ip = get_device_ip(socket.assigns.results)

    case MtrRuntime.queue_trace(socket, device_ip) do
      {:ok, queued_on} ->
        {:noreply,
         socket
         |> put_flash(:info, "MTR trace queued on #{queued_on}")
         |> MtrRuntime.load_traces(device_ip)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  def handle_event("endpoint_inventory_query", %{"endpoint_inventory_query" => params} = event, socket) do
    socket =
      case Map.get(event, "action") do
        "force_refresh" -> EndpointInventoryRuntime.dispatch_force_refresh(socket, params)
        _ -> EndpointInventoryRuntime.dispatch_device_query(socket, params)
      end

    {:noreply, socket}
  end

  def handle_event("endpoint_inventory_force_refresh", %{"endpoint_inventory_query" => params}, socket) do
    {:noreply, EndpointInventoryRuntime.dispatch_force_refresh(socket, params)}
  end

  def handle_event("endpoint_inventory_cohort_query", %{"endpoint_inventory_cohort_query" => params}, socket) do
    {:noreply, EndpointInventoryRuntime.dispatch_cohort_query(socket, params)}
  end

  def handle_event("endpoint_inventory_package_filter", %{"endpoint_inventory_filter" => params}, socket) do
    {:noreply, EndpointInventoryRuntime.apply_package_filter(socket, params)}
  end

  def handle_event("endpoint_inventory_package_page", %{"page" => page}, socket) do
    {:noreply, EndpointInventoryRuntime.change_package_page(socket, page)}
  end

  def handle_event("process_listeners_search", %{"search" => search}, socket) do
    {:noreply,
     socket
     |> assign(:process_listeners_search, to_string(search))
     |> assign(:process_listeners_page, 1)}
  end

  def handle_event("process_listeners_prev_page", _params, socket) do
    {:noreply, assign(socket, :process_listeners_page, max(socket.assigns.process_listeners_page - 1, 1))}
  end

  def handle_event("process_listeners_next_page", _params, socket) do
    {:noreply, assign(socket, :process_listeners_page, socket.assigns.process_listeners_page + 1)}
  end

  def handle_event("process_metrics_search", %{"search" => search}, socket) do
    {:noreply,
     socket
     |> assign(:process_metrics_search, to_string(search))
     |> assign(:process_metrics_page, 1)}
  end

  def handle_event("process_metrics_prev_page", _params, socket) do
    {:noreply, assign(socket, :process_metrics_page, max(socket.assigns.process_metrics_page - 1, 1))}
  end

  def handle_event("process_metrics_next_page", _params, socket) do
    {:noreply, assign(socket, :process_metrics_page, socket.assigns.process_metrics_page + 1)}
  end

  def handle_event("anomaly_findings_prev_page", _params, socket) do
    cursor = get_in(socket.assigns, [:anomaly_capacity, :anomaly_pagination, "prev_cursor"])
    {:noreply, reload_anomaly_capacity_page(socket, cursor, -1)}
  end

  def handle_event("anomaly_findings_next_page", _params, socket) do
    cursor = get_in(socket.assigns, [:anomaly_capacity, :anomaly_pagination, "next_cursor"])
    {:noreply, reload_anomaly_capacity_page(socket, cursor, 1)}
  end

  def handle_event("anomaly_findings_filter", %{"anomaly_filters" => filters}, socket) do
    filters = normalize_anomaly_filters(filters)
    {:noreply, reload_anomaly_capacity_first_page(socket, filters)}
  end

  def handle_event("anomaly_findings_filter", _params, socket), do: {:noreply, socket}

  def handle_event("endpoint_inventory_open_package", %{"ref" => ref}, socket) do
    {:noreply, EndpointInventoryRuntime.open_package_detail(socket, ref)}
  end

  def handle_event("endpoint_inventory_close_package", _params, socket) do
    {:noreply, EndpointInventoryRuntime.close_package_detail(socket)}
  end

  def handle_event("endpoint_inventory_open_match", %{"id" => id}, socket) do
    {:noreply, EndpointInventoryRuntime.open_match_detail(socket, id)}
  end

  def handle_event("endpoint_inventory_close_match", _params, socket) do
    {:noreply, EndpointInventoryRuntime.close_match_detail(socket)}
  end

  def handle_event("open_anomaly_capacity_detail", %{"kind" => kind, "index" => raw_index}, socket) do
    with {index, ""} <- Integer.parse(raw_index),
         rows when is_list(rows) <- anomaly_capacity_detail_rows(socket.assigns.anomaly_capacity, kind),
         %{} = row <- Enum.at(rows, index) do
      detail = %{kind: kind, row: row}
      detail_metric_sections = load_anomaly_capacity_detail_metric_sections(socket, detail)

      {:noreply,
       socket
       |> assign(:anomaly_capacity_detail, detail)
       |> assign(:selected_anomaly_capacity_detail, detail)
       |> assign(:anomaly_capacity_detail_metric_sections, detail_metric_sections)
       |> assign(
         :metric_sections,
         SysmonMetrics.annotate_metric_sections(
           Map.get(socket.assigns, :metric_sections),
           Map.get(socket.assigns, :anomaly_capacity),
           selected_anomaly_row(detail)
         )
       )}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("close_anomaly_capacity_detail", _params, socket) do
    {:noreply,
     socket
     |> assign(:anomaly_capacity_detail, nil)
     |> assign(:selected_anomaly_capacity_detail, nil)
     |> assign(:anomaly_capacity_detail_metric_sections, [])
     |> assign(
       :metric_sections,
       SysmonMetrics.annotate_metric_sections(
         Map.get(socket.assigns, :metric_sections),
         Map.get(socket.assigns, :anomaly_capacity)
       )
     )}
  end

  def handle_event("view_mtr_trace", %{"id" => trace_id}, socket) do
    case MtrRuntime.get_trace_detail(socket.assigns.current_scope, trace_id) do
      {:ok, trace, hops} ->
        {:noreply,
         socket
         |> assign(:selected_mtr_trace, trace)
         |> assign(:selected_mtr_hops, hops)
         |> assign(:show_mtr_trace_modal, true)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "MTR trace not found")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to load MTR trace details")}
    end
  end

  def handle_event("close_mtr_trace_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_mtr_trace_modal, false)
     |> assign(:selected_mtr_trace, nil)
     |> assign(:selected_mtr_hops, [])}
  end

  # ---------------------------------------------------------------------------
  # Interface Selection Events
  # ---------------------------------------------------------------------------

  def handle_event("toggle_interface_select", %{"uid" => uid}, socket) do
    {:noreply, InterfaceRuntime.toggle_select(socket, uid)}
  end

  def handle_event("toggle_select_all_interfaces", _params, socket) do
    {:noreply, InterfaceRuntime.toggle_select_all(socket)}
  end

  def handle_event("clear_interface_selection", _params, socket) do
    {:noreply, InterfaceRuntime.clear_selection(socket)}
  end

  def handle_event("run_action_for_interface_selection", _params, socket) do
    {:noreply, InterfaceRuntime.run_action_for_selection(socket)}
  end

  def handle_event("close_northbound_interface_action_modal", _params, socket) do
    {:noreply, NorthboundInterfaceRuntime.close_modal(socket)}
  end

  def handle_event("northbound_interface_action_change", %{"action" => params}, socket) do
    {:noreply, NorthboundInterfaceRuntime.change_action(socket, params)}
  end

  def handle_event("launch_northbound_interface_action", %{"action" => params}, socket) do
    {:noreply, NorthboundInterfaceRuntime.launch(socket, params)}
  end

  def handle_event("open_interfaces_bulk_edit", _params, socket) do
    {:noreply, InterfaceRuntime.open_bulk_edit(socket)}
  end

  def handle_event("close_interfaces_bulk_edit", _params, socket) do
    {:noreply, InterfaceRuntime.close_bulk_edit(socket)}
  end

  def handle_event("apply_interfaces_bulk_edit", %{"bulk" => params}, socket) do
    {:noreply, InterfaceRuntime.apply_bulk_edit(socket, params, srql_module())}
  end

  def handle_event("toggle_interface_favorite", %{"uid" => uid}, socket) do
    {:noreply, InterfaceRuntime.toggle_favorite(socket, uid, srql_module())}
  end

  def handle_event("toggle_interface_metrics", %{"uid" => uid}, socket) do
    {:noreply, InterfaceRuntime.toggle_metrics(socket, uid, srql_module())}
  end

  def handle_event("enable_favorited_interface_metrics", _params, socket) do
    {:noreply, InterfaceRuntime.enable_favorited_metrics(socket, srql_module())}
  end

  @allowed_flow_filter_fields ~w(
    src_endpoint_ip dst_endpoint_ip dst_endpoint_port protocol_name
    protocol_group protocol_num proto direction_label dst_service_label app sampler_address
    src_port dst_port
  )

  def handle_event("topn_filter", %{"field" => field, "value" => value}, socket)
      when field in @allowed_flow_filter_fields do
    {:noreply,
     FlowRuntime.apply_topn_filter(
       socket,
       %{"field" => field, "value" => value},
       srql_module(),
       @flows_limit
     )}
  end

  def handle_event("topn_filter", _params, socket), do: {:noreply, socket}

  def handle_event("clear_topn_filter", _params, socket) do
    {:noreply, FlowRuntime.clear_topn_filter(socket, srql_module(), @flows_limit)}
  end

  def handle_event("facet_toggle", %{"field" => field, "value" => value}, socket)
      when field in @allowed_flow_filter_fields do
    {:noreply,
     FlowRuntime.toggle_facet(
       socket,
       %{"field" => field, "value" => value},
       srql_module(),
       @flows_limit
     )}
  end

  def handle_event("facet_toggle", _params, socket), do: {:noreply, socket}

  def handle_event("facet_clear", _params, socket) do
    {:noreply, FlowRuntime.clear_facets(socket, srql_module(), @flows_limit)}
  end

  def handle_event("chart_zoom", params, socket) do
    {:noreply, FlowRuntime.apply_chart_zoom(socket, params, srql_module(), @flows_limit)}
  end

  def handle_event("clear_zoom", _params, socket) do
    {:noreply, FlowRuntime.clear_zoom(socket, srql_module(), @flows_limit)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp anomaly_capacity_detail_rows(%{anomaly_rows: rows}, "anomaly"), do: rows
  defp anomaly_capacity_detail_rows(%{anomaly_rows: rows}, "capacity_notice"), do: rows
  defp anomaly_capacity_detail_rows(%{capacity_rows: rows}, "capacity"), do: rows
  defp anomaly_capacity_detail_rows(_overview, _kind), do: nil

  defp reload_anomaly_capacity_page(socket, cursor, page_delta) when is_binary(cursor) and cursor != "" do
    identity = Map.get(socket.assigns.anomaly_capacity || %{}, :identity)

    data =
      AnomalyCapacityData.load(
        srql_module(),
        identity,
        socket.assigns.current_scope,
        anomaly_load_opts(Map.get(socket.assigns, :anomaly_capacity_filters, %{}), anomaly_cursor: cursor)
      )

    page =
      socket.assigns
      |> Map.get(:anomaly_capacity_page, 1)
      |> Kernel.+(page_delta)
      |> max(1)

    socket
    |> assign(:anomaly_capacity, data)
    |> assign(:anomaly_capacity_page, page)
    |> assign(:anomaly_capacity_detail, nil)
    |> assign(:selected_anomaly_capacity_detail, nil)
    |> assign(:anomaly_capacity_detail_metric_sections, [])
    |> assign(
      :metric_sections,
      SysmonMetrics.annotate_metric_sections(Map.get(socket.assigns, :metric_sections), data)
    )
  end

  defp reload_anomaly_capacity_page(socket, _cursor, _page_delta), do: socket

  defp reload_anomaly_capacity_first_page(socket, filters) do
    identity = Map.get(socket.assigns.anomaly_capacity || %{}, :identity)

    data =
      AnomalyCapacityData.load(
        srql_module(),
        identity,
        socket.assigns.current_scope,
        anomaly_load_opts(filters)
      )

    socket
    |> assign(:anomaly_capacity, data)
    |> assign(:anomaly_capacity_filters, filters)
    |> assign(:anomaly_capacity_page, 1)
    |> assign(:anomaly_capacity_detail, nil)
    |> assign(:selected_anomaly_capacity_detail, nil)
    |> assign(:anomaly_capacity_detail_metric_sections, [])
    |> assign(
      :metric_sections,
      SysmonMetrics.annotate_metric_sections(Map.get(socket.assigns, :metric_sections), data)
    )
  end

  defp normalize_anomaly_filters(filters) when is_map(filters) do
    %{
      "severity" => normalize_anomaly_filter_value(Map.get(filters, "severity"), ~w(all critical high medium low), "all"),
      "status" => normalize_anomaly_filter_value(Map.get(filters, "status"), ~w(all open pending cleared), "all"),
      "sort" => normalize_anomaly_filter_value(Map.get(filters, "sort"), ~w(newest oldest severity), "newest")
    }
  end

  defp normalize_anomaly_filters(_filters), do: %{"severity" => "all", "status" => "all", "sort" => "newest"}

  defp normalize_anomaly_filter_value(value, allowed, default) when is_binary(value) do
    value = String.trim(value)
    if value in allowed, do: value, else: default
  end

  defp normalize_anomaly_filter_value(_value, _allowed, default), do: default

  defp anomaly_load_opts(filters, extra \\ []) do
    filters = normalize_anomaly_filters(filters)

    Keyword.merge(
      [
        anomaly_severity: empty_filter_to_nil(Map.get(filters, "severity")),
        anomaly_status: empty_filter_to_nil(Map.get(filters, "status")),
        anomaly_sort: Map.get(filters, "sort", "newest")
      ],
      extra
    )
  end

  defp empty_filter_to_nil(value) when value in [nil, "", "all"], do: nil
  defp empty_filter_to_nil(value), do: value

  defp load_anomaly_capacity_detail_metric_sections(socket, %{row: %{} = row} = detail) do
    if interface_or_snmp_finding?(row) do
      load_anomaly_capacity_detail_interface_sections(socket, row)
    else
      load_anomaly_capacity_detail_sysmon_sections(socket, row, detail)
    end
  end

  defp load_anomaly_capacity_detail_metric_sections(_socket, _detail), do: []

  defp load_anomaly_capacity_detail_sysmon_sections(socket, row, detail) do
    with identity when is_map(identity) <- Map.get(socket.assigns.anomaly_capacity || %{}, :identity),
         time_range when is_binary(time_range) <- detail_time_range(row),
         sysmon_filters =
           SysmonMetrics.resolve_sysmon_filter_tokens(srql_module(), identity, socket.assigns.current_scope),
         true <- sysmon_filters != [] do
      srql_module()
      |> SysmonMetrics.load_metric_sections(sysmon_filters, socket.assigns.current_scope,
        time_range: time_range,
        bucket: @detail_metric_bucket,
        window_label: detail_window_label(row),
        metrics_limit: 500,
        cpu_metrics_limit: 20_000,
        disk_metrics_limit: 500
      )
      |> SysmonMetrics.annotate_metric_sections(socket.assigns.anomaly_capacity, selected_anomaly_row(detail))
      |> put_detail_section_subtitle_time(row)
    else
      _ -> []
    end
  end

  defp load_anomaly_capacity_detail_interface_sections(socket, row) do
    with device_uid when is_binary(device_uid) <- Map.get(socket.assigns, :device_uid),
         time_range when is_binary(time_range) <- detail_time_range(row),
         {:ok, panels} <-
           InterfaceData.load_interface_metric_section(
             srql_module(),
             device_uid,
             row,
             Map.get(socket.assigns, :interfaces, []),
             socket.assigns.current_scope,
             time_range: time_range,
             bucket: @detail_metric_bucket,
             limit: 1_000
           ) do
      [
        %{
          key: "interfaces",
          title: "Interface metrics",
          subtitle: detail_window_label(row),
          subtitle_time: detail_center_time(row),
          error: nil,
          panels: panels
        }
      ]
    else
      _ -> []
    end
  end

  defp interface_or_snmp_finding?(row) do
    text =
      [
        Map.get(row, "metric_class"),
        Map.get(row, "metric_name"),
        Map.get(row, "finding_title"),
        Map.get(row, "reason")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(" ", &to_string/1)
      |> String.downcase()

    String.contains?(text, "snmp") or String.contains?(text, "interface") or String.contains?(text, "if_")
  end

  defp detail_time_range(row) do
    with %DateTime{} = center <- detail_center_time(row),
         {start_dt, end_dt} <- detail_window_bounds(row, center) do
      "[#{DateTime.to_iso8601(start_dt)},#{DateTime.to_iso8601(end_dt)}]"
    end
  end

  defp detail_window_label(_row), do: "selected finding window"

  defp put_detail_section_subtitle_time(sections, row) when is_list(sections) do
    case detail_center_time(row) do
      %DateTime{} = center ->
        Enum.map(sections, fn
          section when is_map(section) -> Map.put(section, :subtitle_time, center)
          section -> section
        end)

      _ ->
        sections
    end
  end

  defp put_detail_section_subtitle_time(sections, _row), do: sections

  defp detail_window_bounds(row, center) do
    start_dt = parse_detail_datetime(Map.get(row, "triggered_at") || Map.get(row, "window_started_at"))
    end_dt = parse_detail_datetime(Map.get(row, "cleared_at") || Map.get(row, "window_ended_at"))

    {start_dt, end_dt} =
      if match?(%DateTime{}, start_dt) and match?(%DateTime{}, end_dt) do
        {
          DateTime.add(start_dt, -@detail_metric_window_padding_seconds, :second),
          DateTime.add(end_dt, @detail_metric_window_padding_seconds, :second)
        }
      else
        half_window = div(@detail_metric_min_window_seconds, 2)
        {DateTime.add(center, -half_window, :second), DateTime.add(center, half_window, :second)}
      end

    expand_detail_window_to_minimum(start_dt, end_dt, center)
  end

  defp expand_detail_window_to_minimum(start_dt, end_dt, center) do
    if DateTime.diff(end_dt, start_dt, :second) >= @detail_metric_min_window_seconds do
      {start_dt, end_dt}
    else
      half_window = div(@detail_metric_min_window_seconds, 2)
      {DateTime.add(center, -half_window, :second), DateTime.add(center, half_window, :second)}
    end
  end

  defp detail_center_time(row) do
    row
    |> first_present_detail_time(["time", "timestamp", "window_ended_at", "projected_exhaustion_at", "forecasted_at"])
    |> parse_detail_datetime()
  end

  defp first_present_detail_time(row, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(row, key) do
        value when is_binary(value) and value != "" -> value
        %DateTime{} = value -> value
        %NaiveDateTime{} = value -> value
        _ -> nil
      end
    end)
  end

  defp parse_detail_datetime(%DateTime{} = dt), do: dt
  defp parse_detail_datetime(%NaiveDateTime{} = ndt), do: DateTime.from_naive!(ndt, "Etc/UTC")

  defp parse_detail_datetime(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      nil
    else
      case DateTime.from_iso8601(value) do
        {:ok, dt, _offset} -> dt
        _ -> nil
      end
    end
  end

  defp parse_detail_datetime(_value), do: nil

  @impl true
  def render(assigns), do: ServiceRadarWebNGWeb.DeviceLive.ShowTemplate.render(assigns)

  defp drop_low_value_categories(panels) when is_list(panels) do
    Enum.reject(panels, &low_value_categories_panel?/1)
  end

  defp drop_table_panels(panels) when is_list(panels) do
    Enum.reject(panels, &(&1.plugin == TablePlugin))
  end

  defp low_value_categories_panel?(%{plugin: CategoriesPlugin, assigns: assigns}) do
    case Map.get(assigns, :viz) do
      {:categories, %{label: label, value: value}} ->
        normalize_viz_key(label) == "modified" and normalize_viz_key(value) == "type_id"

      _ ->
        false
    end
  end

  defp low_value_categories_panel?(_), do: false

  defp normalize_viz_key(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  # ---------------------------------------------------------------------------
  # Data Loading Functions
  # ---------------------------------------------------------------------------

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  defp devices_return_path(params, socket) do
    case Map.get(params, "return_to") do
      value when is_binary(value) -> IndexPath.sanitize(value)
      _ -> socket.assigns[:devices_return_path] || "/devices"
    end
  end

  defp get_device_ip(results) do
    case List.first(Enum.filter(results, &is_map/1)) do
      nil -> nil
      row -> Map.get(row, "ip")
    end
  end
end
