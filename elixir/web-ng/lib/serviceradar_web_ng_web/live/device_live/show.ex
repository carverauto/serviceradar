defmodule ServiceRadarWebNGWeb.DeviceLive.Show do
  @moduledoc false
  use ServiceRadarWebNGWeb, :live_view

  import Bitwise
  import ServiceRadarWebNGWeb.DeviceLive.AgentComponents
  import ServiceRadarWebNGWeb.DeviceLive.AvailabilityComponents
  import ServiceRadarWebNGWeb.DeviceLive.CameraComponents
  import ServiceRadarWebNGWeb.DeviceLive.DeviceEditComponents
  import ServiceRadarWebNGWeb.DeviceLive.DeviceHeaderComponents
  import ServiceRadarWebNGWeb.DeviceLive.DevicePropertiesComponents
  import ServiceRadarWebNGWeb.DeviceLive.DeviceSummaryComponents
  import ServiceRadarWebNGWeb.DeviceLive.DeviceTabsComponents
  import ServiceRadarWebNGWeb.DeviceLive.FlowComponents
  import ServiceRadarWebNGWeb.DeviceLive.HealthcheckComponents
  import ServiceRadarWebNGWeb.DeviceLive.InterfaceComponents
  import ServiceRadarWebNGWeb.DeviceLive.LogComponents
  import ServiceRadarWebNGWeb.DeviceLive.MetricSectionComponents
  import ServiceRadarWebNGWeb.DeviceLive.MtrComponents
  import ServiceRadarWebNGWeb.DeviceLive.OcsfComponents
  import ServiceRadarWebNGWeb.DeviceLive.ProcessMetricsComponents
  import ServiceRadarWebNGWeb.DeviceLive.SweepComponents
  import ServiceRadarWebNGWeb.DeviceLive.SysmonProfileComponents
  import ServiceRadarWebNGWeb.DeviceLive.VirtualizationComponents
  import ServiceRadarWebNGWeb.DeviceLive.VisibilityComponents

  import ServiceRadarWebNGWeb.NorthboundActionComponents,
    only: [northbound_action_history: 1, northbound_action_modal: 1]

  alias Ash.Error.Invalid
  alias ServiceRadar.AgentConfig.Compilers.SysmonCompiler
  alias ServiceRadar.Automation.Northbound.Catalog, as: NorthboundCatalog
  alias ServiceRadar.Automation.Northbound.History, as: NorthboundHistory
  alias ServiceRadar.Automation.Northbound.InvocationService, as: NorthboundInvocationService
  alias ServiceRadar.Camera.RelaySession
  alias ServiceRadar.Camera.Source, as: CameraSource
  alias ServiceRadar.Edge.AgentCommandBus
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DevicePubSub
  alias ServiceRadar.Inventory.DeviceSNMPCredential
  alias ServiceRadar.Inventory.InterfaceSettings
  alias ServiceRadar.Inventory.VirtualizationCluster
  alias ServiceRadar.Inventory.VirtualizationDatastore
  alias ServiceRadar.Inventory.VirtualizationGuest
  alias ServiceRadar.Inventory.VirtualizationHost
  alias ServiceRadar.Inventory.VirtualizationHostDisk
  alias ServiceRadar.Inventory.VirtualizationNetworkInterface
  alias ServiceRadar.Inventory.VirtualizationStorageSystem
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.Observability.IpGeoEnrichmentCache
  alias ServiceRadar.Observability.IpRdnsCache
  alias ServiceRadar.Observability.MtrAutomationDispatcher
  alias ServiceRadar.Observability.MtrPolicy
  alias ServiceRadar.Observability.MtrPubSub
  alias ServiceRadar.Observability.MtrSettingsRuntime
  alias ServiceRadar.SweepJobs.SweepHostResult
  alias ServiceRadar.SysmonProfiles.SysmonProfile
  alias ServiceRadarWebNG.Northbound.ActionForm, as: NorthboundActionForm
  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Dashboard.Engine
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Categories, as: CategoriesPlugin
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Table, as: TablePlugin
  alias ServiceRadarWebNGWeb.DeviceLive.AvailabilityData
  alias ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrData
  alias ServiceRadarWebNGWeb.FeatureFlags
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  require Ash.Query
  require Logger

  @default_limit 50
  @max_limit 200
  @metrics_limit 300
  @snmp_metrics_limit @metrics_limit * 12
  @interfaces_limit 200
  @flows_limit 50
  @mtr_device_limit 50
  @logs_limit 50
  @camera_relay_poll_interval_ms 1_000
  @details_supplemental_timeout_ms 3_000
  @tab_supplemental_timeout_ms 15_000
  @slow_device_task_ms 1_500

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      DevicePubSub.subscribe()
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, "agent:commands")
      Phoenix.PubSub.subscribe(ServiceRadar.PubSub, MtrPubSub.topic())
    end

    srql = %{
      enabled: true,
      entity: "devices",
      page_path: nil,
      query: nil,
      draft: nil,
      error: nil,
      viz: nil,
      loading: false,
      builder_available: false,
      builder_open: false,
      builder_supported: false,
      builder_sync: false,
      builder: %{}
    }

    {:ok,
     socket
     |> assign(:page_title, "Device")
     |> assign(:device_uid, nil)
     |> assign(:device_details_request_ref, nil)
     |> assign(:details_loading, false)
     |> assign(:results, [])
     |> assign(:panels, [])
     |> assign(:metric_sections, [])
     |> assign(:sysmon_presence, false)
     |> assign(:sysmon_profile_info, nil)
     |> assign(:available_profiles, [])
     |> assign(:availability, nil)
     |> assign(:agent_availability, [])
     |> assign(:healthcheck_summary, nil)
     |> assign(:virtualization_summary, nil)
     |> assign(:has_virtualization_guests, false)
     |> assign(:sweep_results, nil)
     |> assign(:process_metrics, nil)
     |> assign(:limit, @default_limit)
     |> assign(:flows_limit, @flows_limit)
     |> assign(:srql, srql)
     # Edit mode
     |> assign(:editing, false)
     |> assign(:device_form, to_form(%{}, as: :device))
     |> assign(:device_snmp_credential, nil)
     |> assign(:snmp_credential_form, to_form(%{}, as: :snmp))
     # Network interfaces for dedicated tab
     |> assign(:network_interfaces, [])
     |> assign(:interfaces_error, nil)
     |> assign(:has_ifaces, false)
     |> assign(:discovery_job, nil)
     # Interface selection state
     |> assign(:selected_interfaces, MapSet.new())
     |> assign(:favorited_interfaces, MapSet.new())
     |> assign(:northbound_interface_actions, [])
     |> assign(:northbound_interface_actions_loading, false)
     |> assign(:northbound_interface_actions_loaded, false)
     |> assign(:show_northbound_interface_action_modal, false)
     |> assign(:northbound_interface_action_form, to_form(%{}, as: :action))
     |> assign(:northbound_interface_action_error, nil)
     |> assign(:northbound_interface_launch_action, nil)
     |> assign(:northbound_device_history, [])
     |> assign(:northbound_device_history_error, nil)
     |> assign(:northbound_launch_notice, nil)
     |> assign(:show_interfaces_bulk_edit, false)
     |> assign(:interfaces_bulk_edit_form, to_form(%{"action" => "favorite"}, as: :bulk))
     # Interface metrics for favorited interfaces
     |> assign(:interface_metrics, nil)
     |> assign(:interface_metrics_layout, "two")
     |> assign(:device_flows, [])
     |> assign(:flows_error, nil)
     |> assign(:rdns_map, %{})
     |> assign(:geo_iso2_map, %{})
     |> assign(:flows_pagination, %{})
     |> assign(:has_flows, false)
     |> assign(:device_logs, [])
     |> assign(:logs_error, nil)
     |> assign(:logs_pagination, %{})
     |> assign(:logs_loading, false)
     |> assign(:logs_request_ref, nil)
     |> assign(:logs_cursor, nil)
     |> assign(:has_logs, false)
     |> assign(:logs_limit, @logs_limit)
     |> assign(:flow_stats, %{})
     |> assign(:flow_stats_loading, true)
     |> assign(:flow_sparkline_json, "[]")
     |> assign(:flow_proto_json, "[]")
     |> assign(:flow_chart_keys_json, "[]")
     |> assign(:flow_chart_points_json, "[]")
     |> assign(:flow_top_talkers_json, "[]")
     |> assign(:flow_top_destinations_json, "[]")
     |> assign(:flow_top_ports_json, "[]")
     |> assign(:flow_top_protocols_json, "[]")
     |> assign(:flow_facets, %{protocols: [], directions: [], services: []})
     |> assign(:flow_stats_request_ref, nil)
     |> assign(:flow_ip_request_ref, nil)
     |> assign(:device_metrics_request_ref, nil)
     |> assign(:metrics_loading, false)
     |> assign(:flow_active_facets, %{})
     |> assign(:flow_active_topn, nil)
     |> assign(:flow_zoom_range, nil)
     |> assign(:ip_aliases, [])
     |> assign(:ip_alias_error, nil)
     |> assign(:show_stale_aliases, false)
     # MTR diagnostics tab
     |> assign(:mtr_traces, [])
     |> assign(:mtr_pending_jobs, [])
     |> assign(:mtr_trends, %{hops: [], latency: []})
     |> assign(:mtr_page, 1)
     |> assign(:mtr_page_size, @mtr_device_limit)
     |> assign(:mtr_total_count, 0)
     |> assign(:mtr_coverage, %{trace_count: 0, earliest_time: nil, latest_time: nil})
     |> assign(:mtr_retention_status, %{configured_days: 30, status: :degraded, tables: %{}})
     |> assign(:has_mtr, false)
     |> assign(:show_mtr_trace_modal, false)
     |> assign(:selected_mtr_trace, nil)
     |> assign(:selected_mtr_hops, [])
     |> assign(:camera_sources, [])
     |> assign(:camera_inventory_error, nil)
     |> assign(:active_camera_relay_session, nil)
     |> assign(:last_camera_relay_session, nil)
     # Tab state for device details
     |> assign(:active_tab, "details")}
  end

  @impl true
  def handle_params(%{"uid" => uid} = params, uri, socket) do
    socket =
      socket
      |> assign(:last_params, params)
      |> assign(:last_uri, uri)

    limit = parse_limit(Map.get(params, "limit"), @default_limit, @max_limit)
    # Read tab from URL params, fall back to current or default
    url_tab = Map.get(params, "tab")
    cursor = normalize_cursor(Map.get(params, "cursor"))
    mtr_page = parse_positive_page(Map.get(params, "mtr_page"))
    mtr_page_size = mtr_default_page_size()

    requested_tab = normalize_requested_tab(url_tab, socket.assigns.active_tab)
    socket = socket |> assign(:mtr_page, mtr_page) |> assign(:mtr_page_size, mtr_page_size)

    cond do
      same_device_and_limit?(socket, uid, limit) ->
        handle_same_device_params(socket, uid, limit, requested_tab, cursor)

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

  def handle_info({:command_result, %{command_type: "mtr.run"} = msg}, socket) do
    {:noreply, refresh_mtr_if_relevant(socket, msg)}
  end

  def handle_info({:command_ack, %{command_type: "mtr.run"} = msg}, socket) do
    {:noreply, refresh_mtr_if_relevant(socket, msg)}
  end

  def handle_info({:command_progress, %{command_type: "mtr.run"} = msg}, socket) do
    {:noreply, refresh_mtr_if_relevant(socket, msg)}
  end

  def handle_info({:mtr_trace_ingested, event}, socket) do
    {:noreply, refresh_mtr_if_relevant(socket, event)}
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
    active_session = socket.assigns.active_camera_relay_session

    cond do
      is_nil(active_session) ->
        {:noreply, socket}

      active_session.id != relay_session_id ->
        {:noreply, socket}

      true ->
        case fetch_camera_relay_session(socket.assigns.current_scope, relay_session_id) do
          {:ok, nil} ->
            {:noreply, clear_active_camera_relay_session(socket)}

          {:ok, session} ->
            {:noreply, apply_camera_relay_session_update(socket, session)}

          {:error, _reason} ->
            schedule_camera_relay_refresh(relay_session_id)
            {:noreply, socket}
        end
    end
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
    socket
    |> assign(assigns)
    |> assign(:details_loading, false)
    |> assign(:device_details_request_ref, nil)
  end

  defp apply_device_metrics_assigns(socket, assigns) do
    socket
    |> assign(assigns)
    |> assign(:metrics_loading, false)
    |> assign(:device_metrics_request_ref, nil)
  end

  defp apply_flow_stats_bundle(socket, stats_bundle) do
    {flow_stats, sparkline_json, proto_json, chart_keys, chart_points, top_talkers_json, top_destinations_json,
     top_ports_json, top_protocols_json, facets} = stats_bundle

    socket
    |> assign(:flow_stats, flow_stats)
    |> assign(:flow_stats_loading, false)
    |> assign(:flow_sparkline_json, sparkline_json)
    |> assign(:flow_proto_json, proto_json)
    |> assign(:flow_chart_keys_json, chart_keys)
    |> assign(:flow_chart_points_json, chart_points)
    |> assign(:flow_top_talkers_json, top_talkers_json)
    |> assign(:flow_top_destinations_json, top_destinations_json)
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

  defp normalize_cursor(nil), do: nil
  defp normalize_cursor(""), do: nil

  defp normalize_cursor(cursor) when is_binary(cursor) do
    cursor = String.trim(cursor)
    if cursor == "", do: nil, else: cursor
  end

  defp normalize_cursor(_), do: nil

  defp maybe_refresh_current_device(socket, uid) when is_binary(uid) do
    if uid == socket.assigns.device_uid do
      params =
        socket.assigns
        |> Map.get(:last_params, %{})
        |> Map.put("uid", uid)

      uri = Map.get(socket.assigns, :last_uri, "/devices/#{uid}")
      limit = parse_limit(Map.get(params, "limit"), socket.assigns.limit, @max_limit)
      requested_tab = normalize_requested_tab(Map.get(params, "tab"), socket.assigns.active_tab)

      load_device_data(socket, uid, limit, requested_tab, params, uri)
    else
      {:noreply, socket}
    end
  end

  defp maybe_refresh_current_device(socket, _uid), do: {:noreply, socket}

  defp begin_device_metrics_refresh(socket, uid, srql_module, sysmon_identity, scope) do
    request_ref = make_ref()

    if Application.get_env(:serviceradar_web_ng, :env) == :test do
      sysmon_filters = SysmonMetrics.resolve_sysmon_filter_tokens(srql_module, sysmon_identity, scope)

      assigns = %{
        metric_sections: SysmonMetrics.load_metric_sections(srql_module, sysmon_filters, scope),
        process_metrics: SysmonMetrics.load_process_metrics(srql_module, sysmon_filters, scope),
        sysmon_presence: sysmon_filters != []
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
        sysmon_filters = SysmonMetrics.resolve_sysmon_filter_tokens(srql_module, sysmon_identity, scope)

        %{
          metric_sections: SysmonMetrics.load_metric_sections(srql_module, sysmon_filters, scope),
          process_metrics: SysmonMetrics.load_process_metrics(srql_module, sysmon_filters, scope),
          sysmon_presence: sysmon_filters != []
        }
      end)
    end
  end

  defp normalize_requested_tab(url_tab, fallback_tab) do
    if url_tab in [
         "details",
         "interfaces",
         "flows",
         "logs",
         "profiles",
         "active-fingerprint",
         "process-listeners",
         "sysmon",
         "mtr",
         "guests"
       ],
       do: url_tab,
       else: fallback_tab
  end

  defp same_device_and_limit?(socket, uid, limit) do
    uid == socket.assigns.device_uid and limit == socket.assigns.limit
  end

  defp maybe_load_northbound_interface_actions(socket) do
    cond do
      not connected?(socket) ->
        socket

      Map.get(socket.assigns, :northbound_interface_actions_loading) == true ->
        socket

      Map.get(socket.assigns, :northbound_interface_actions_loaded) == true ->
        socket

      true ->
        scope = socket.assigns.current_scope

        socket
        |> assign(:northbound_interface_actions_loading, true)
        |> start_async(:northbound_interface_actions, fn ->
          northbound_catalog_module().eligible_interface_actions(scope)
        end)
    end
  end

  defp handle_same_device_params(socket, uid, limit, requested_tab, cursor) do
    active_tab =
      requested_tab
      |> resolve_active_tab(
        socket.assigns.has_ifaces,
        socket.assigns.has_flows,
        socket.assigns.has_logs,
        socket.assigns.has_mtr,
        socket.assigns.has_virtualization_guests
      )
      |> authorize_active_tab(Map.get(socket.assigns, :device_row), socket.assigns.current_scope)

    srql = srql_for_tab_if_needed(active_tab, uid, limit, socket.assigns.srql)

    socket =
      socket
      |> maybe_reload_flows_for_active_tab(
        active_tab,
        uid,
        cursor
      )
      |> maybe_reload_logs_for_active_tab(active_tab, uid, cursor)
      |> maybe_reload_interfaces_for_active_tab(active_tab, uid)
      |> maybe_reload_profiles_for_active_tab(active_tab, uid)
      |> maybe_load_mtr_for_active_tab(active_tab)

    {:noreply,
     socket
     |> assign(:active_tab, active_tab)
     |> assign(:srql, srql)
     |> maybe_load_northbound_interface_actions()}
  end

  defp maybe_reload_flows_for_active_tab(socket, "flows", uid, cursor) do
    scope = socket.assigns.current_scope
    srql_mod = srql_module()

    {flows, pagination, flows_error} = load_flows(srql_mod, uid, scope, cursor)

    socket
    |> assign(:device_flows, flows)
    |> assign(:flows_pagination, pagination)
    |> assign(:flows_error, flows_error)
    |> begin_flow_stats_refresh(uid)
    |> begin_flow_ip_enrichment(uid, flows)
  end

  defp maybe_reload_flows_for_active_tab(socket, _active_tab, _uid, _cursor), do: socket

  defp maybe_reload_logs_for_active_tab(socket, "logs", uid, cursor) do
    if socket.assigns.logs_loading and socket.assigns.logs_cursor == cursor do
      socket
    else
      begin_logs_load(socket, uid, cursor)
    end
  end

  defp maybe_reload_logs_for_active_tab(socket, _active_tab, _uid, _cursor), do: socket

  defp begin_logs_load(socket, uid, cursor) do
    scope = socket.assigns.current_scope
    srql_mod = srql_module()
    request_ref = make_ref()

    socket
    |> assign(:device_logs, [])
    |> assign(:logs_pagination, %{})
    |> assign(:logs_error, nil)
    |> assign(:logs_loading, false)
    |> assign(:logs_request_ref, request_ref)
    |> assign(:logs_cursor, cursor)
    |> assign(:has_logs, true)
    |> maybe_start_logs_async(uid, request_ref, srql_mod, scope, cursor)
  end

  defp maybe_start_logs_async(socket, uid, request_ref, srql_mod, scope, cursor) do
    if connected?(socket) do
      start_async(socket, {:device_logs, uid, request_ref}, fn ->
        load_logs(srql_mod, uid, scope, cursor)
      end)
    else
      socket
    end
  end

  defp maybe_reload_interfaces_for_active_tab(socket, "interfaces", uid) do
    scope = socket.assigns.current_scope
    srql_mod = srql_module()

    {network_interfaces, interfaces_error} = load_interfaces(srql_mod, uid, scope)

    interface_settings =
      load_interface_settings(scope, uid)

    network_interfaces = apply_interface_settings(network_interfaces, interface_settings.by_uid)

    interface_metrics =
      load_interface_metrics(
        srql_mod,
        uid,
        interface_settings.favorited,
        interface_settings.metrics_enabled,
        network_interfaces,
        scope
      )

    has_ifaces =
      is_binary(interfaces_error) or
        (is_list(network_interfaces) and network_interfaces != []) or
        not is_nil(socket.assigns.discovery_job)

    socket
    |> assign(:network_interfaces, network_interfaces)
    |> assign(:interfaces_error, interfaces_error)
    |> assign(:favorited_interfaces, interface_settings.favorited)
    |> assign(:interface_metrics, interface_metrics)
    |> assign(:has_ifaces, has_ifaces)
  end

  defp maybe_reload_interfaces_for_active_tab(socket, _active_tab, _uid), do: socket

  defp maybe_reload_profiles_for_active_tab(socket, "profiles", uid) do
    scope = socket.assigns.current_scope
    {profile_info, available_profiles} = load_sysmon_profile_info(scope, uid)

    socket
    |> assign(:sysmon_profile_info, profile_info)
    |> assign(:available_profiles, available_profiles)
  end

  defp maybe_reload_profiles_for_active_tab(socket, _active_tab, _uid), do: socket

  defp srql_for_tab_if_needed("interfaces", uid, limit, srql), do: srql_for_tab("interfaces", uid, limit, srql)

  defp srql_for_tab_if_needed("flows", uid, limit, srql), do: srql_for_tab("flows", uid, limit, srql)

  defp srql_for_tab_if_needed("logs", uid, limit, srql), do: srql_for_tab("logs", uid, limit, srql)

  defp srql_for_tab_if_needed(_active_tab, _uid, _limit, srql), do: srql

  defp load_device_data(socket, uid, limit, requested_tab, params, uri) do
    default_query = default_device_query(uid, limit)

    query = normalized_device_query(params, default_query)

    srql_module = srql_module()
    scope = Map.get(socket.assigns, :current_scope)

    # Phase 1: Main device query (must be first — everything depends on device_row)
    {results, error, viz} = execute_srql_query(srql_module, query, scope)

    page_path = uri |> to_string() |> URI.parse() |> Map.get(:path)
    active_camera_relay_session = preserve_camera_relay_session(socket, uid)
    last_camera_relay_session = preserve_last_camera_relay_session(socket, uid)

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

    device_row =
      results
      |> Enum.find(&is_map/1)
      |> enrich_integration_metadata(scope)

    device_ip = get_device_ip(results)
    show_stale = socket.assigns.show_stale_aliases
    virtualization_summary = load_virtualization_summary(scope, uid)
    has_virtualization_guests = virtualization_guests?(virtualization_summary)
    {camera_sources, camera_inventory_error} = load_camera_sources(scope, uid, device_row)

    supplemental_context = %{
      socket: socket,
      srql_module: srql_module,
      uid: uid,
      scope: scope,
      params: params,
      requested_tab: requested_tab,
      device_row: device_row,
      device_ip: device_ip,
      show_stale: show_stale,
      virtualization_summary: virtualization_summary,
      camera_sources: camera_sources,
      camera_inventory_error: camera_inventory_error
    }

    if requested_tab == "details" do
      base_context = Map.put(supplemental_context, :include_metrics?, false)

      base_context =
        Map.put(base_context, :supplemental_timeout_ms, @details_supplemental_timeout_ms)

      supplemental_assigns = load_device_supplemental_assigns(base_context)

      {:noreply,
       socket
       |> assign(:device_uid, uid)
       |> assign(:device_details_request_ref, nil)
       |> assign(:details_loading, false)
       |> assign(:limit, limit)
       |> assign(:results, results)
       |> assign(:network_interfaces, [])
       |> assign(:interfaces_error, nil)
       |> assign(:has_ifaces, false)
       |> assign(:device_flows, [])
       |> assign(:flows_error, nil)
       |> assign(:flows_pagination, %{})
       |> assign(:has_flows, false)
       |> assign(:device_logs, [])
       |> assign(:logs_error, nil)
       |> assign(:logs_pagination, %{})
       |> assign(:logs_loading, false)
       |> assign(:logs_request_ref, nil)
       |> assign(:logs_cursor, nil)
       |> assign(:has_logs, false)
       |> assign(:discovery_job, nil)
       |> assign(:favorited_interfaces, MapSet.new())
       |> assign(:interface_metrics, nil)
       |> assign(:ip_aliases, [])
       |> assign(:ip_alias_error, nil)
       |> assign(:active_tab, "details")
       |> assign(
         :panels,
         srql_response
         |> Engine.build_panels()
         |> drop_low_value_categories()
         |> drop_table_panels()
       )
       |> assign(:metric_sections, [])
       |> assign(:sysmon_presence, false)
       |> assign(:sysmon_profile_info, nil)
       |> assign(:available_profiles, [])
       |> assign(:process_metrics, nil)
       |> assign(:camera_sources, camera_sources)
       |> assign(:camera_inventory_error, camera_inventory_error)
       |> assign(:active_camera_relay_session, active_camera_relay_session)
       |> assign(:last_camera_relay_session, last_camera_relay_session)
       |> assign(:availability, nil)
       |> assign(:healthcheck_summary, nil)
       |> assign(:virtualization_summary, virtualization_summary)
       |> assign(:has_virtualization_guests, has_virtualization_guests)
       |> assign(:sweep_results, nil)
       |> assign(:device_snmp_credential, socket.assigns.device_snmp_credential)
       |> assign(:srql, base_srql)
       |> assign(supplemental_assigns)
       |> begin_device_metrics_refresh(uid, srql_module, SysmonMetrics.sysmon_identity(device_row, uid), scope)}
    else
      supplemental_assigns = load_device_supplemental_assigns(supplemental_context)

      has_ifaces = Map.get(supplemental_assigns, :has_ifaces, false)
      has_flows = Map.get(supplemental_assigns, :has_flows, false)
      has_logs = Map.get(supplemental_assigns, :has_logs, false)
      has_mtr = Map.get(supplemental_assigns, :has_mtr, false)
      has_virtualization_guests = Map.get(supplemental_assigns, :has_virtualization_guests, false)

      active_tab =
        requested_tab
        |> resolve_active_tab(
          has_ifaces,
          has_flows,
          has_logs,
          has_mtr,
          has_virtualization_guests
        )
        |> authorize_active_tab(device_row, scope)

      srql = srql_for_tab_if_needed(active_tab, uid, limit, base_srql)

      {:noreply,
       socket
       |> assign(:device_uid, uid)
       |> assign(:device_details_request_ref, nil)
       |> assign(:details_loading, false)
       |> assign(:limit, limit)
       |> assign(:results, results)
       |> assign(:active_tab, active_tab)
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
       |> assign(:srql, srql)
       |> assign(supplemental_assigns)
       |> maybe_load_mtr_for_active_tab(active_tab)
       |> maybe_reload_logs_for_active_tab(
         active_tab,
         uid,
         normalize_cursor(Map.get(params, "cursor"))
       )
       |> maybe_begin_flow_background_loads(
         active_tab,
         uid,
         Map.get(supplemental_assigns, :device_flows, [])
       )}
    end
  end

  defp load_device_supplemental_assigns(context) do
    socket = Map.fetch!(context, :socket)
    srql_module = Map.fetch!(context, :srql_module)
    uid = Map.fetch!(context, :uid)
    scope = Map.get(context, :scope)
    params = Map.get(context, :params, %{})
    requested_tab = Map.get(context, :requested_tab, "details")
    device_row = Map.get(context, :device_row)
    device_ip = Map.get(context, :device_ip)
    show_stale = Map.get(context, :show_stale, false)
    include_metrics? = Map.get(context, :include_metrics?, true)
    virtualization_summary = Map.get(context, :virtualization_summary)

    supplemental_timeout_ms =
      Map.get(context, :supplemental_timeout_ms, @tab_supplemental_timeout_ms)

    camera_sources = Map.get(context, :camera_sources, [])
    camera_inventory_error = Map.get(context, :camera_inventory_error)

    load_interfaces_data? = requested_tab == "interfaces"
    load_flows_data? = requested_tab == "flows"
    load_logs_data? = load_logs_synchronously?(requested_tab)
    sysmon_identity = SysmonMetrics.sysmon_identity(device_row, uid)

    parallel_tasks =
      build_device_parallel_tasks(%{
        socket: socket,
        srql_module: srql_module,
        uid: uid,
        scope: scope,
        params: params,
        requested_tab: requested_tab,
        device_ip: device_ip,
        device_row: device_row,
        show_stale: show_stale,
        load_interfaces_data?: load_interfaces_data?,
        load_flows_data?: load_flows_data?,
        load_logs_data?: load_logs_data?
      })

    sysmon_filters =
      if include_metrics? do
        SysmonMetrics.resolve_sysmon_filter_tokens(srql_module, sysmon_identity, scope)
      else
        []
      end

    metric_tasks =
      if include_metrics? do
        [
          timed_device_task(:metrics, fn ->
            SysmonMetrics.load_metric_sections(srql_module, sysmon_filters, scope)
          end),
          timed_device_task(:process, fn ->
            SysmonMetrics.load_process_metrics(srql_module, sysmon_filters, scope)
          end)
        ]
      else
        []
      end

    parallel_results =
      safe_yield_many(parallel_tasks ++ metric_tasks, supplemental_timeout_ms)

    {network_interfaces, interfaces_error} =
      extract_interface_results(parallel_results, load_interfaces_data?)

    {device_flows, flows_pagination, flows_error} =
      extract_flow_results(parallel_results, load_flows_data?)

    {device_logs, logs_pagination, logs_error} =
      extract_log_results(parallel_results, load_logs_data?)

    discovery_jobs = Map.get(parallel_results, :mapper, [])
    discovery_job = pick_discovery_job(discovery_jobs)
    has_discovery_job = not is_nil(discovery_job)
    network_interfaces = filter_interfaces_for_display(network_interfaces, device_row)

    interface_settings = extract_interface_settings(parallel_results, load_interfaces_data?)
    favorited_interfaces = interface_settings.favorited
    metrics_enabled_interfaces = interface_settings.metrics_enabled

    interface_metrics =
      maybe_load_interface_metrics(
        load_interfaces_data?,
        srql_module,
        uid,
        favorited_interfaces,
        metrics_enabled_interfaces,
        network_interfaces,
        scope
      )

    network_interfaces = apply_interface_settings(network_interfaces, interface_settings.by_uid)

    has_ifaces =
      determine_has_ifaces(
        load_interfaces_data?,
        interfaces_error,
        network_interfaces,
        has_discovery_job,
        Map.get(parallel_results, :has_ifaces, false)
      )

    has_flows =
      determine_has_flows(
        load_flows_data?,
        flows_error,
        device_flows,
        Map.get(parallel_results, :has_flows, false)
      )

    has_logs =
      determine_has_logs(
        load_logs_data?,
        logs_error,
        device_logs,
        Map.get(parallel_results, :has_logs, false)
      )

    has_mtr = detect_has_mtr(scope, uid, device_ip)

    {sysmon_profile_info, available_profiles} = Map.get(parallel_results, :profile, {nil, []})

    {ip_aliases, ip_alias_error} = Map.get(parallel_results, :aliases, {[], nil})

    {northbound_device_history, northbound_device_history_error} =
      Map.get(parallel_results, :northbound_history, {[], nil})

    base_assigns = %{
      availability: Map.get(parallel_results, :availability, %{}),
      agent_availability: Map.get(parallel_results, :agent_availability, []),
      healthcheck_summary: Map.get(parallel_results, :healthcheck, %{}),
      virtualization_summary: virtualization_summary,
      has_virtualization_guests: virtualization_guests?(virtualization_summary),
      sweep_results: Map.get(parallel_results, :sweep, []),
      sysmon_profile_info: sysmon_profile_info,
      available_profiles: available_profiles,
      network_interfaces: network_interfaces,
      interfaces_error: interfaces_error,
      device_flows: device_flows,
      flows_pagination: flows_pagination,
      flows_error: flows_error,
      device_logs: device_logs,
      logs_pagination: logs_pagination,
      logs_error: logs_error,
      discovery_job: discovery_job,
      camera_sources: camera_sources,
      camera_inventory_error: camera_inventory_error,
      favorited_interfaces: favorited_interfaces,
      interface_metrics: interface_metrics,
      ip_aliases: ip_aliases,
      ip_alias_error: ip_alias_error,
      northbound_device_history: northbound_device_history,
      northbound_device_history_error: northbound_device_history_error,
      has_ifaces: has_ifaces,
      has_flows: has_flows,
      has_logs: has_logs,
      has_mtr: has_mtr
    }

    if include_metrics? do
      Map.merge(base_assigns, %{
        metric_sections: Map.get(parallel_results, :metrics, []),
        process_metrics: Map.get(parallel_results, :process, []),
        sysmon_presence: sysmon_filters != []
      })
    else
      base_assigns
    end
  end

  defp build_device_parallel_tasks(%{
         socket: socket,
         srql_module: srql_module,
         uid: uid,
         scope: scope,
         params: params,
         requested_tab: requested_tab,
         device_ip: device_ip,
         device_row: device_row,
         show_stale: show_stale,
         load_interfaces_data?: load_interfaces_data?,
         load_flows_data?: load_flows_data?,
         load_logs_data?: load_logs_data?
       }) do
    base_tasks = [
      timed_device_task(:availability, fn -> AvailabilityData.load_availability(srql_module, uid, scope) end),
      timed_device_task(:agent_availability, fn -> AvailabilityData.load_agent_availability(scope, uid) end),
      timed_device_task(:healthcheck, fn -> AvailabilityData.load_healthcheck_summary(srql_module, uid, scope) end),
      timed_device_task(:sweep, fn ->
        load_sweep_results(socket.assigns.current_scope, device_ip)
      end),
      timed_device_task(:mapper, fn -> load_mapper_jobs_for_device(scope, device_row) end),
      timed_device_task(:aliases, fn -> load_ip_aliases(scope, uid, show_stale) end),
      timed_device_task(:northbound_history, fn -> load_northbound_device_history(scope, uid) end)
    ]

    base_tasks
    |> maybe_add_profile_task(requested_tab, uid, scope)
    |> maybe_add_interface_tasks(load_interfaces_data?, srql_module, uid, scope)
    |> maybe_add_flow_tasks(load_flows_data?, srql_module, uid, scope, params)
    |> maybe_add_log_tasks(load_logs_data?, srql_module, uid, scope, params)
  end

  defp maybe_add_profile_task(tasks, "profiles", uid, scope) do
    tasks ++ [timed_device_task(:profile, fn -> load_sysmon_profile_info(scope, uid) end)]
  end

  defp maybe_add_profile_task(tasks, _active_tab, _uid, _scope), do: tasks

  defp maybe_add_interface_tasks(tasks, true, srql_module, uid, scope) do
    tasks ++
      [
        timed_device_task(:interfaces, fn -> load_interfaces(srql_module, uid, scope) end),
        timed_device_task(:iface_settings, fn -> load_interface_settings(scope, uid) end)
      ]
  end

  defp maybe_add_interface_tasks(tasks, false, srql_module, uid, scope) do
    tasks ++
      [timed_device_task(:has_ifaces, fn -> detect_has_interfaces(srql_module, uid, scope) end)]
  end

  defp maybe_add_flow_tasks(tasks, true, srql_module, uid, scope, params) do
    tasks ++
      [
        timed_device_task(:flows, fn ->
          load_flows(srql_module, uid, scope, normalize_cursor(Map.get(params, "cursor")))
        end)
      ]
  end

  defp maybe_add_flow_tasks(tasks, false, srql_module, uid, scope, _params) do
    tasks ++ [timed_device_task(:has_flows, fn -> detect_has_flows(srql_module, uid, scope) end)]
  end

  defp maybe_add_log_tasks(tasks, true, srql_module, uid, scope, params) do
    tasks ++
      [
        timed_device_task(:logs, fn ->
          load_logs(srql_module, uid, scope, normalize_cursor(Map.get(params, "cursor")))
        end)
      ]
  end

  defp maybe_add_log_tasks(tasks, false, _srql_module, _uid, _scope, _params), do: tasks

  defp load_logs_synchronously?(requested_tab) do
    requested_tab == "logs" and
      Application.get_env(:serviceradar_web_ng, :device_logs_sync_preload?, false)
  end

  defp extract_interface_results(parallel_results, true), do: Map.get(parallel_results, :interfaces, {[], nil})

  defp extract_interface_results(_parallel_results, false), do: {[], nil}

  defp extract_flow_results(parallel_results, true), do: Map.get(parallel_results, :flows, {[], %{}, nil})

  defp extract_flow_results(_parallel_results, false), do: {[], %{}, nil}

  defp extract_log_results(parallel_results, true), do: Map.get(parallel_results, :logs, {[], %{}, nil})

  defp extract_log_results(_parallel_results, false), do: {[], %{}, nil}

  defp extract_interface_settings(parallel_results, true) do
    Map.get(parallel_results, :iface_settings, %{
      favorited: MapSet.new(),
      metrics_enabled: MapSet.new(),
      by_uid: %{}
    })
  end

  defp extract_interface_settings(_parallel_results, false) do
    %{favorited: MapSet.new(), metrics_enabled: MapSet.new(), by_uid: %{}}
  end

  defp maybe_load_interface_metrics(
         true,
         srql_module,
         uid,
         favorited_interfaces,
         metrics_enabled_interfaces,
         network_interfaces,
         scope
       ) do
    load_interface_metrics(
      srql_module,
      uid,
      favorited_interfaces,
      metrics_enabled_interfaces,
      network_interfaces,
      scope
    )
  end

  defp maybe_load_interface_metrics(
         false,
         _srql_module,
         _uid,
         _favorited_interfaces,
         _metrics_enabled_interfaces,
         _network_interfaces,
         _scope
       ), do: nil

  defp determine_has_ifaces(true, interfaces_error, network_interfaces, has_discovery_job, _probe) do
    is_binary(interfaces_error) or
      (is_list(network_interfaces) and network_interfaces != []) or has_discovery_job
  end

  defp determine_has_ifaces(false, _interfaces_error, _network_interfaces, has_discovery_job, probe) do
    probe or has_discovery_job
  end

  defp determine_has_flows(true, flows_error, device_flows, _probe) do
    is_binary(flows_error) or (is_list(device_flows) and device_flows != [])
  end

  defp determine_has_flows(false, _flows_error, _device_flows, probe), do: probe

  defp determine_has_logs(true, logs_error, device_logs, _probe) do
    is_binary(logs_error) or is_list(device_logs)
  end

  defp determine_has_logs(false, _logs_error, _device_logs, _probe), do: true

  defp detect_has_interfaces(srql_module, device_uid, scope) do
    query =
      "in:interfaces device_id:\"#{escape_value(device_uid)}\" latest:true time:last_3d " <>
        "stats:count() as interface_count"

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        interface_count =
          results
          |> List.first(%{})
          |> Map.get("interface_count", 0)

        if to_safe_number(interface_count) > 0 do
          true
        else
          legacy_detect_has_interfaces(srql_module, device_uid, scope)
        end

      _ ->
        legacy_detect_has_interfaces(srql_module, device_uid, scope)
    end
  end

  defp legacy_detect_has_interfaces(srql_module, device_uid, scope) do
    query =
      "in:interfaces device_id:\"#{escape_value(device_uid)}\" latest:true time:last_3d limit:1"

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => [_ | _]}} -> true
      _ -> false
    end
  end

  defp detect_has_flows(srql_module, device_uid, scope) do
    query = default_flows_query(device_uid) <> " limit:1"

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => [_ | _]}} -> true
      _ -> false
    end
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

  defp resolve_active_tab("interfaces", false, _has_flows, _has_logs, _has_mtr, _has_guests), do: "details"

  defp resolve_active_tab("flows", _has_ifaces, false, _has_logs, _has_mtr, _has_guests), do: "details"

  defp resolve_active_tab("logs", _has_ifaces, _has_flows, false, _has_mtr, _has_guests), do: "details"

  defp resolve_active_tab("mtr", _has_ifaces, _has_flows, _has_logs, false, _has_guests), do: "details"

  defp resolve_active_tab("guests", _has_ifaces, _has_flows, _has_logs, _has_mtr, false), do: "details"

  defp resolve_active_tab(requested_tab, _has_ifaces, _has_flows, _has_logs, _has_mtr, _has_guests), do: requested_tab

  defp authorize_active_tab("active-fingerprint", row, scope) do
    if active_fingerprint_tab_visible?(row, scope), do: "active-fingerprint", else: "details"
  end

  defp authorize_active_tab(tab, _row, _scope), do: tab

  @impl true
  def handle_event("srql_change", %{"q" => q}, socket) do
    {:noreply, assign(socket, :srql, Map.put(socket.assigns.srql, :draft, to_string(q)))}
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

    page_path =
      if String.starts_with?(query, "in:devices") do
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
    if socket.assigns.editing do
      # Cancel editing - reset form
      {:noreply,
       socket
       |> assign(:editing, false)
       |> assign(:device_form, to_form(%{}, as: :device))
       |> assign(:snmp_credential_form, to_form(%{}, as: :snmp))}
    else
      # Start editing - populate form with current device data
      device_row = List.first(Enum.filter(socket.assigns.results, &is_map/1))
      scope = socket.assigns.current_scope

      device_snmp_credential =
        socket.assigns.device_snmp_credential ||
          load_device_snmp_credential(scope, socket.assigns.device_uid)

      form_data =
        if device_row do
          %{
            "hostname" => Map.get(device_row, "hostname", ""),
            "ip" => Map.get(device_row, "ip", ""),
            "type" => Map.get(device_row, "type", ""),
            "vendor_name" => Map.get(device_row, "vendor_name", ""),
            "model" => Map.get(device_row, "model", ""),
            "is_managed" => Map.get(device_row, "is_managed", false),
            "is_trusted" => Map.get(device_row, "is_trusted", false),
            "tags" => format_tags_for_edit(Map.get(device_row, "tags"))
          }
        else
          %{}
        end

      {:noreply,
       socket
       |> assign(:editing, true)
       |> assign(:device_snmp_credential, device_snmp_credential)
       |> assign(:device_form, to_form(form_data, as: :device))
       |> assign(
         :snmp_credential_form,
         to_form(snmp_credential_form_data(device_snmp_credential), as: :snmp)
       )}
    end
  end

  def handle_event("delete_device", _params, socket) do
    scope = socket.assigns.current_scope
    device_uid = socket.assigns.device_uid

    case load_device(scope, device_uid) do
      {:ok, device} ->
        deleted_by = deleted_by_from_scope(scope)

        case Device.soft_delete(device, "ui_delete", deleted_by, scope: scope) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Device deleted")
             |> push_patch(to: device_show_path(socket, device_uid))}

          {:error, reason} ->
            Logger.error("Device delete failed for #{device_uid}: #{inspect(reason)}")

            {:noreply, put_flash(socket, :error, "Failed to delete device: #{format_ash_error(reason)}")}
        end

      {:error, reason} ->
        Logger.error("Device load failed for delete #{device_uid}: #{inspect(reason)}")

        {:noreply, put_flash(socket, :error, "Failed to load device: #{format_ash_error(reason)}")}
    end
  end

  def handle_event("restore_device", _params, socket) do
    scope = socket.assigns.current_scope
    device_uid = socket.assigns.device_uid

    case restore_device(scope, device_uid) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Device restored")
         |> push_patch(to: device_show_path(socket, device_uid))}

      {:error, reason} ->
        Logger.error("Device restore failed for #{device_uid}: #{inspect(reason)}")

        {:noreply, put_flash(socket, :error, "Failed to restore device: #{format_ash_error(reason)}")}
    end
  end

  def handle_event("mark_device_active", _params, socket) do
    update_device_active_state(socket, true)
  end

  def handle_event("mark_device_inactive", _params, socket) do
    update_device_active_state(socket, false)
  end

  def handle_event("toggle_aliases", _params, socket) do
    show_stale = not socket.assigns.show_stale_aliases
    scope = socket.assigns.current_scope
    device_uid = socket.assigns.device_uid

    {ip_aliases, ip_alias_error} = load_ip_aliases(scope, device_uid, show_stale)

    {:noreply,
     socket
     |> assign(:show_stale_aliases, show_stale)
     |> assign(:ip_aliases, ip_aliases)
     |> assign(:ip_alias_error, ip_alias_error)}
  end

  def handle_event("set_availability_source", %{"agent_id" => agent_id}, socket) do
    scope = socket.assigns.current_scope
    device_uid = socket.assigns.device_uid

    availability_source_agent_id =
      agent_id
      |> to_string()
      |> String.trim()
      |> case do
        "" -> nil
        value -> value
      end

    case load_device(scope, device_uid) do
      {:ok, device} ->
        result =
          device
          |> Ash.Changeset.for_update(:set_availability_source, %{
            availability_source_agent_id: availability_source_agent_id,
            availability_source_profile_id: nil
          })
          |> Ash.update(scope: scope)

        case result do
          {:ok, _updated} ->
            {:noreply,
             socket
             |> put_flash(:info, "Availability source updated")
             |> push_patch(to: device_show_path(socket, device_uid))}

          {:error, reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Failed to update availability source: #{format_ash_error(reason)}"
             )}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to load device: #{format_ash_error(reason)}")}
    end
  end

  def handle_event(
        "open_camera_relay",
        %{"camera_source_id" => camera_source_id, "stream_profile_id" => stream_profile_id} = params,
        socket
      ) do
    scope = socket.assigns.current_scope
    insecure_skip_verify = parse_bool_param(params["insecure_skip_verify"]) == true

    cond do
      not can_view_device?(scope) ->
        {:noreply, put_flash(socket, :error, "You are not authorized to start a camera relay")}

      not is_nil(socket.assigns.active_camera_relay_session) ->
        {:noreply, put_flash(socket, :error, "Close the current camera relay before starting another")}

      true ->
        with {:ok, camera_source_id} <- normalize_uuid_param(camera_source_id),
             {:ok, stream_profile_id} <- normalize_uuid_param(stream_profile_id),
             {:ok, session} <-
               relay_session_manager().request_open(
                 camera_source_id,
                 stream_profile_id,
                 scope: scope,
                 insecure_skip_verify: insecure_skip_verify
               ) do
          {:noreply,
           socket
           |> clear_flash(:error)
           |> assign(:active_camera_relay_session, session)
           |> assign(:last_camera_relay_session, nil)
           |> tap(fn _socket -> schedule_camera_relay_refresh(session.id) end)
           |> put_flash(:info, "Camera relay requested")}
        else
          {:error, reason} ->
            {:noreply, put_flash(socket, :error, format_camera_relay_error(reason))}
        end
    end
  end

  def handle_event("close_camera_relay", _params, socket) do
    scope = socket.assigns.current_scope
    active_session = socket.assigns.active_camera_relay_session

    cond do
      not can_view_device?(scope) ->
        {:noreply, put_flash(socket, :error, "You are not authorized to stop a camera relay")}

      is_nil(active_session) ->
        {:noreply, socket}

      true ->
        case relay_session_manager().request_close(
               active_session.id,
               reason: "viewer closed device details",
               scope: scope
             ) do
          {:ok, session} ->
            {:noreply,
             socket
             |> assign(:active_camera_relay_session, session)
             |> tap(fn _socket -> schedule_camera_relay_refresh(session.id) end)
             |> put_flash(:info, "Camera relay closing")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, format_camera_relay_error(reason))}
        end
    end
  end

  def handle_event("validate_device", %{"device" => params}, socket) do
    {:noreply, assign(socket, :device_form, to_form(params, as: :device))}
  end

  def handle_event("save_device", %{"device" => params}, socket) do
    scope = socket.assigns.current_scope
    device_uid = socket.assigns.device_uid

    case update_device(scope, device_uid, params) do
      {:ok, _device} ->
        {:noreply,
         socket
         |> assign(:editing, false)
         |> put_flash(:info, "Device updated successfully.")
         |> push_patch(to: ~p"/devices/#{device_uid}")}

      {:error, %Invalid{} = error} ->
        {:noreply, put_flash(socket, :error, format_ash_error(error))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update device: #{inspect(reason)}")}
    end
  end

  def handle_event("snmp_form_change", %{"snmp" => params}, socket) do
    current = socket.assigns.snmp_credential_form.source || %{}
    updated = Map.merge(current, params)

    {:noreply, assign(socket, :snmp_credential_form, to_form(updated, as: :snmp))}
  end

  def handle_event("save_snmp_credentials", %{"snmp" => params}, socket) do
    scope = socket.assigns.current_scope
    device_uid = socket.assigns.device_uid
    editing = not is_nil(socket.assigns.device_snmp_credential)
    normalized = normalize_snmp_credential_params(params, editing)

    if editing or snmp_params_present?(normalized) do
      case DeviceSNMPCredential.upsert_for_device(device_uid, normalized, scope: scope) do
        {:ok, credential} ->
          {:noreply,
           socket
           |> assign(:device_snmp_credential, credential)
           |> assign(
             :snmp_credential_form,
             to_form(snmp_credential_form_data(credential), as: :snmp)
           )
           |> put_flash(:info, "SNMP credentials saved")}

        {:error, %Invalid{} = error} ->
          {:noreply, put_flash(socket, :error, format_ash_error(error))}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to save SNMP credentials: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :info, "Provide SNMP credentials to create an override")}
    end
  end

  def handle_event("clear_snmp_credentials", _params, socket) do
    scope = socket.assigns.current_scope

    case socket.assigns.device_snmp_credential do
      nil ->
        {:noreply, socket}

      credential ->
        case Ash.destroy(credential, scope: scope) do
          :ok ->
            {:noreply,
             socket
             |> assign(:device_snmp_credential, nil)
             |> assign(:snmp_credential_form, to_form(%{}, as: :snmp))
             |> put_flash(:info, "SNMP credential override cleared")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to clear SNMP credentials: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab =
      tab
      |> resolve_active_tab(
        socket.assigns.has_ifaces,
        socket.assigns.has_flows,
        socket.assigns.has_logs,
        socket.assigns.has_mtr,
        socket.assigns.has_virtualization_guests
      )
      |> authorize_active_tab(Map.get(socket.assigns, :device_row), socket.assigns.current_scope)

    srql = srql_for_tab(tab, socket.assigns.device_uid, socket.assigns.limit, socket.assigns.srql)

    # Update URL with tab parameter for shareable/bookmarkable links
    path =
      if tab == "details" do
        ~p"/devices/#{socket.assigns.device_uid}"
      else
        ~p"/devices/#{socket.assigns.device_uid}?tab=#{tab}"
      end

    uid = socket.assigns.device_uid

    socket =
      socket
      |> maybe_reload_flows_for_active_tab(tab, uid, nil)
      |> maybe_reload_logs_for_active_tab(tab, uid, nil)
      |> maybe_reload_interfaces_for_active_tab(tab, uid)
      |> maybe_reload_profiles_for_active_tab(tab, uid)
      |> maybe_load_mtr_for_active_tab(tab)

    {:noreply,
     socket
     |> assign(:active_tab, tab)
     |> assign(:srql, srql)
     |> push_patch(to: path, replace: true)}
  end

  def handle_event("run_mtr", _params, socket) do
    device_ip = get_device_ip(socket.assigns.results)

    case queue_mtr_trace(socket, device_ip) do
      {:ok, queued_on} ->
        {:noreply,
         socket
         |> put_flash(:info, "MTR trace queued on #{queued_on}")
         |> load_mtr_traces()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, reason)}
    end
  end

  def handle_event("view_mtr_trace", %{"id" => trace_id}, socket) do
    case MtrData.get_trace_detail(socket.assigns.current_scope, trace_id) do
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
    selected = socket.assigns.selected_interfaces

    updated =
      if MapSet.member?(selected, uid) do
        MapSet.delete(selected, uid)
      else
        MapSet.put(selected, uid)
      end

    {:noreply, assign(socket, :selected_interfaces, updated)}
  end

  def handle_event("toggle_select_all_interfaces", _params, socket) do
    interfaces = socket.assigns.network_interfaces
    selected = socket.assigns.selected_interfaces

    all_uids =
      interfaces |> Enum.map(&Map.get(&1, "interface_uid")) |> Enum.filter(& &1) |> MapSet.new()

    updated =
      if MapSet.size(selected) == MapSet.size(all_uids) and MapSet.equal?(selected, all_uids) do
        MapSet.new()
      else
        all_uids
      end

    {:noreply, assign(socket, :selected_interfaces, updated)}
  end

  def handle_event("clear_interface_selection", _params, socket) do
    {:noreply, assign(socket, :selected_interfaces, MapSet.new())}
  end

  def handle_event("run_task_for_interface_selection", _params, socket) do
    cond do
      not can_launch_northbound_actions?(socket.assigns.current_scope) ->
        {:noreply, put_flash(socket, :error, northbound_launch_permission_error())}

      MapSet.size(socket.assigns.selected_interfaces) == 0 ->
        {:noreply, put_flash(socket, :error, "Select at least one interface before Run Task.")}

      socket.assigns.northbound_interface_actions == [] ->
        {:noreply, put_flash(socket, :error, "No launchable interface task integrations are configured.")}

      true ->
        action = List.first(socket.assigns.northbound_interface_actions)
        {:noreply, open_northbound_interface_action_modal(socket, action)}
    end
  end

  def handle_event("close_northbound_interface_action_modal", _params, socket) do
    {:noreply, close_northbound_interface_action_modal(socket)}
  end

  def handle_event("northbound_interface_action_change", %{"action" => params}, socket) do
    action =
      params
      |> Map.get("action_id")
      |> find_northbound_action(socket.assigns.northbound_interface_actions)

    params = NorthboundActionForm.ensure_params(params, action)

    {:noreply,
     socket
     |> assign(:northbound_interface_launch_action, action)
     |> assign(:northbound_interface_action_form, to_form(params, as: :action))
     |> assign(:northbound_interface_action_error, nil)}
  end

  def handle_event("launch_northbound_interface_action", %{"action" => params}, socket) do
    with {:ok, action} <-
           selected_northbound_action(params, socket.assigns.northbound_interface_actions),
         {:ok, input_values} <- NorthboundActionForm.parse_input(action, params),
         {:ok, targets} <- selected_interface_action_targets(socket),
         {:ok, invocation} <- create_northbound_invocation(socket, action, targets, input_values) do
      {history, history_error} =
        load_northbound_device_history(socket.assigns.current_scope, socket.assigns.device_uid)

      {:noreply,
       socket
       |> close_northbound_interface_action_modal()
       |> assign(:selected_interfaces, MapSet.new())
       |> assign(:northbound_device_history, history)
       |> assign(:northbound_device_history_error, history_error)
       |> assign(:northbound_launch_notice, %{
         title: "Task dispatched for #{length(targets)} interface(s)",
         invocation_id: invocation.id
       })
       |> put_flash(
         :info,
         "Task dispatched. Watch Task History for results."
       )}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:northbound_interface_action_form, to_form(params, as: :action))
         |> assign(
           :northbound_interface_action_error,
           NorthboundActionForm.format_launch_error(reason, "interface")
         )}
    end
  end

  def handle_event("open_interfaces_bulk_edit", _params, socket) do
    {:noreply, assign(socket, :show_interfaces_bulk_edit, true)}
  end

  def handle_event("close_interfaces_bulk_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_interfaces_bulk_edit, false)
     |> assign(:interfaces_bulk_edit_form, to_form(%{"action" => "favorite"}, as: :bulk))}
  end

  def handle_event("apply_interfaces_bulk_edit", %{"bulk" => params}, socket) do
    selected = socket.assigns.selected_interfaces
    device_uid = socket.assigns.device_uid
    scope = socket.assigns.current_scope
    action = Map.get(params, "action", "favorite")

    {socket, success_count, action_label} =
      case action do
        "favorite" ->
          # Add all selected to favorites and persist
          {count, new_favorites} =
            bulk_update_favorites(
              scope,
              device_uid,
              selected,
              true,
              socket.assigns.favorited_interfaces
            )

          {assign(socket, :favorited_interfaces, new_favorites), count, "added to favorites"}

        "unfavorite" ->
          # Remove all selected from favorites and persist
          {count, new_favorites} =
            bulk_update_favorites(
              scope,
              device_uid,
              selected,
              false,
              socket.assigns.favorited_interfaces
            )

          {assign(socket, :favorited_interfaces, new_favorites), count, "removed from favorites"}

        "enable_metrics" ->
          # Enable metrics collection for all selected interfaces
          count = bulk_update_metrics(scope, device_uid, selected, true)
          {socket, count, "enabled for metrics collection"}

        "disable_metrics" ->
          # Disable metrics collection for all selected interfaces
          count = bulk_update_metrics(scope, device_uid, selected, false)
          {socket, count, "disabled for metrics collection"}

        "add_tags" ->
          # Add tags to all selected interfaces
          tags_string = Map.get(params, "tags", "")
          tags = parse_tags(tags_string)

          if tags == [] do
            {socket, 0, "tagged (no tags provided)"}
          else
            count = bulk_update_tags(scope, device_uid, selected, tags)
            {socket, count, "tagged with: #{Enum.join(tags, ", ")}"}
          end

        _ ->
          {socket, 0, "updated"}
      end

    {:noreply,
     socket
     |> assign(:show_interfaces_bulk_edit, false)
     |> assign(:selected_interfaces, MapSet.new())
     |> assign(:interfaces_bulk_edit_form, to_form(%{"action" => "favorite"}, as: :bulk))
     |> put_flash(:info, "#{success_count} interface(s) #{action_label}")}
  end

  def handle_event("toggle_interface_favorite", %{"uid" => uid}, socket) do
    favorited = socket.assigns.favorited_interfaces
    device_uid = socket.assigns.device_uid
    scope = socket.assigns.current_scope
    new_favorite_state = not MapSet.member?(favorited, uid)

    # Persist to backend
    case upsert_interface_setting(scope, device_uid, uid, %{favorited: new_favorite_state}) do
      {:ok, _setting} ->
        updated =
          if new_favorite_state do
            MapSet.put(favorited, uid)
          else
            MapSet.delete(favorited, uid)
          end

        {:noreply, assign(socket, :favorited_interfaces, updated)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update favorite status")}
    end
  end

  def handle_event("set_interface_metrics_layout", %{"layout" => layout}, socket) do
    {:noreply, assign(socket, :interface_metrics_layout, normalize_interface_metrics_layout(layout))}
  end

  @allowed_flow_filter_fields ~w(
    src_endpoint_ip dst_endpoint_ip dst_endpoint_port protocol_name
    protocol_group protocol_num proto direction_label dst_service_label app sampler_address
    src_port dst_port
  )

  def handle_event("topn_filter", %{"field" => field, "value" => value}, socket)
      when field in @allowed_flow_filter_fields do
    uid = socket.assigns.device_uid
    scope = socket.assigns.current_scope
    srql_mod = srql_module()

    base =
      "in:flows device_id:\"#{escape_value(uid)}\" #{field}:\"#{escape_value(value)}\" time:last_24h"

    query = "#{base} sort:time:desc"
    opts = %{scope: scope, limit: @flows_limit, cursor: nil}

    flows_task = Task.async(fn -> {:flows, load_zoomed_flows(srql_mod, query, opts)} end)

    stats_task =
      Task.async(fn -> {:stats, load_device_flow_stats(srql_mod, uid, scope, base)} end)

    results = safe_yield_many([flows_task, stats_task], 15_000)

    {flows, pagination, flows_error} = Map.get(results, :flows, {[], %{}, nil})

    {flow_stats, sparkline_json, proto_json, chart_keys, chart_points, top_talkers_json, top_destinations_json,
     top_ports_json, top_protocols_json, facets} =
      Map.get(
        results,
        :stats,
        {%{}, "[]", "[]", "[]", "[]", "[]", "[]", "[]", "[]", %{protocols: [], directions: [], services: []}}
      )

    srql = socket.assigns.srql |> Map.put(:query, base) |> Map.put(:draft, base)

    {:noreply,
     socket
     |> assign(:srql, srql)
     |> assign(:flow_zoom_range, nil)
     |> assign(:flow_active_facets, %{})
     |> assign(:device_flows, flows)
     |> assign(:flows_pagination, pagination)
     |> assign(:flows_error, flows_error)
     |> assign(:flow_stats, flow_stats)
     |> assign(:flow_sparkline_json, sparkline_json)
     |> assign(:flow_proto_json, proto_json)
     |> assign(:flow_chart_keys_json, chart_keys)
     |> assign(:flow_chart_points_json, chart_points)
     |> assign(:flow_top_talkers_json, top_talkers_json)
     |> assign(:flow_top_destinations_json, top_destinations_json)
     |> assign(:flow_top_ports_json, top_ports_json)
     |> assign(:flow_top_protocols_json, top_protocols_json)
     |> assign(:flow_facets, facets)
     |> assign(:flow_active_topn, %{field: field, value: value})
     |> enrich_flow_ips()}
  end

  def handle_event("topn_filter", _params, socket), do: {:noreply, socket}

  def handle_event("clear_topn_filter", _params, socket) do
    uid = socket.assigns.device_uid
    scope = socket.assigns.current_scope
    srql_mod = srql_module()

    {flows, pagination, flows_error} = load_flows(srql_mod, uid, scope, nil)

    default_query = default_flows_query(uid)
    srql = socket.assigns.srql |> Map.put(:query, default_query) |> Map.put(:draft, default_query)

    {:noreply,
     socket
     |> assign(:srql, srql)
     |> assign(:flow_active_topn, nil)
     |> assign(:device_flows, flows)
     |> assign(:flows_pagination, pagination)
     |> assign(:flows_error, flows_error)
     |> enrich_flow_ips()}
  end

  def handle_event("facet_toggle", %{"field" => field, "value" => value}, socket)
      when field in @allowed_flow_filter_fields do
    uid = socket.assigns.device_uid
    active = socket.assigns.flow_active_facets

    # Toggle: if same facet+value is active, remove it; otherwise set it
    updated =
      if Map.get(active, field) == value,
        do: Map.delete(active, field),
        else: Map.put(active, field, value)

    {:noreply,
     socket
     |> assign(:flow_active_facets, updated)
     |> reload_flows_with_facets(uid, updated)}
  end

  def handle_event("facet_toggle", _params, socket), do: {:noreply, socket}

  def handle_event("facet_clear", _params, socket) do
    uid = socket.assigns.device_uid

    {:noreply,
     socket
     |> assign(:flow_active_facets, %{})
     |> reload_flows_with_facets(uid, %{})}
  end

  def handle_event("chart_zoom", %{"start" => start, "end" => end_t}, socket) do
    with {:ok, start_dt, _} <- DateTime.from_iso8601(start),
         {:ok, end_dt, _} <- DateTime.from_iso8601(end_t),
         :lt <- DateTime.compare(start_dt, end_dt) do
      safe_start = DateTime.to_iso8601(start_dt)
      safe_end = DateTime.to_iso8601(end_dt)
      uid = socket.assigns.device_uid
      scope = socket.assigns.current_scope
      srql_mod = srql_module()
      zoomed_base = "in:flows device_id:\"#{escape_value(uid)}\" time:[#{safe_start},#{safe_end}]"
      query = "#{zoomed_base} sort:time:desc"
      opts = %{scope: scope, limit: @flows_limit, cursor: nil}

      # Reload flows table and stats in parallel for the zoomed range
      flows_task =
        Task.async(fn ->
          try do
            {:flows, load_zoomed_flows(srql_mod, query, opts)}
          rescue
            _ -> {:flows, {[], %{}, "Failed to load flows for selected range"}}
          end
        end)

      stats_task =
        Task.async(fn ->
          try do
            {:stats, load_device_flow_stats(srql_mod, uid, scope, zoomed_base)}
          rescue
            _ ->
              {:stats,
               {%{}, "[]", "[]", "[]", "[]", "[]", "[]", "[]", "[]", %{protocols: [], directions: [], services: []}}}
          end
        end)

      results = safe_yield_many([flows_task, stats_task], 15_000)

      {flows, pagination, flows_error} = Map.get(results, :flows, {[], %{}, nil})

      {flow_stats, sparkline_json, proto_json, chart_keys, chart_points, top_talkers_json, top_destinations_json,
       top_ports_json, top_protocols_json, facets} =
        Map.get(
          results,
          :stats,
          {%{}, "[]", "[]", "[]", "[]", "[]", "[]", "[]", "[]", %{protocols: [], directions: [], services: []}}
        )

      srql = socket.assigns.srql |> Map.put(:query, zoomed_base) |> Map.put(:draft, zoomed_base)

      {:noreply,
       socket
       |> assign(:srql, srql)
       |> assign(:device_flows, flows)
       |> assign(:flows_pagination, pagination)
       |> assign(:flows_error, flows_error)
       |> assign(:flow_zoom_range, %{start: safe_start, end: safe_end})
       |> assign(:flow_stats, flow_stats)
       |> assign(:flow_sparkline_json, sparkline_json)
       |> assign(:flow_proto_json, proto_json)
       |> assign(:flow_chart_keys_json, chart_keys)
       |> assign(:flow_chart_points_json, chart_points)
       |> assign(:flow_top_talkers_json, top_talkers_json)
       |> assign(:flow_top_destinations_json, top_destinations_json)
       |> assign(:flow_top_ports_json, top_ports_json)
       |> assign(:flow_top_protocols_json, top_protocols_json)
       |> assign(:flow_facets, facets)
       |> assign(:flow_active_facets, %{})
       |> assign(:flow_active_topn, nil)
       |> enrich_flow_ips()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("clear_zoom", _params, socket) do
    uid = socket.assigns.device_uid
    scope = socket.assigns.current_scope
    srql_mod = srql_module()

    flows_task = Task.async(fn -> {:flows, load_flows(srql_mod, uid, scope, nil)} end)
    stats_task = Task.async(fn -> {:stats, load_device_flow_stats(srql_mod, uid, scope)} end)

    results = safe_yield_many([flows_task, stats_task], 15_000)

    {flows, pagination, flows_error} = Map.get(results, :flows, {[], %{}, nil})

    {flow_stats, sparkline_json, proto_json, chart_keys, chart_points, top_talkers_json, top_destinations_json,
     top_ports_json, top_protocols_json, facets} =
      Map.get(
        results,
        :stats,
        {%{}, "[]", "[]", "[]", "[]", "[]", "[]", "[]", "[]", %{protocols: [], directions: [], services: []}}
      )

    default_query = default_flows_query(uid)
    srql = socket.assigns.srql |> Map.put(:query, default_query) |> Map.put(:draft, default_query)

    {:noreply,
     socket
     |> assign(:srql, srql)
     |> assign(:flow_zoom_range, nil)
     |> assign(:device_flows, flows)
     |> assign(:flows_pagination, pagination)
     |> assign(:flows_error, flows_error)
     |> assign(:flow_stats, flow_stats)
     |> assign(:flow_sparkline_json, sparkline_json)
     |> assign(:flow_proto_json, proto_json)
     |> assign(:flow_chart_keys_json, chart_keys)
     |> assign(:flow_chart_points_json, chart_points)
     |> assign(:flow_top_talkers_json, top_talkers_json)
     |> assign(:flow_top_destinations_json, top_destinations_json)
     |> assign(:flow_top_ports_json, top_ports_json)
     |> assign(:flow_top_protocols_json, top_protocols_json)
     |> assign(:flow_facets, facets)
     |> assign(:flow_active_facets, %{})
     |> assign(:flow_active_topn, nil)
     |> enrich_flow_ips()}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp can_launch_northbound_actions?(scope) do
    RBAC.can?(scope, "northbound.actions.launch")
  end

  defp northbound_launch_permission_error do
    "You are not authorized to launch tasks. Missing permission: northbound.actions.launch."
  end

  defp open_northbound_interface_action_modal(socket, nil) do
    put_flash(socket, :error, "No launchable interface task integration was selected.")
  end

  defp open_northbound_interface_action_modal(socket, action) do
    params = NorthboundActionForm.default_params(action)

    socket
    |> assign(:show_northbound_interface_action_modal, true)
    |> assign(:northbound_interface_launch_action, action)
    |> assign(:northbound_interface_action_form, to_form(params, as: :action))
    |> assign(:northbound_interface_action_error, nil)
  end

  defp close_northbound_interface_action_modal(socket) do
    socket
    |> assign(:show_northbound_interface_action_modal, false)
    |> assign(:northbound_interface_launch_action, nil)
    |> assign(:northbound_interface_action_form, to_form(%{}, as: :action))
    |> assign(:northbound_interface_action_error, nil)
  end

  defp selected_northbound_action(params, actions) do
    params
    |> Map.get("action_id")
    |> find_northbound_action(actions)
    |> case do
      nil -> {:error, :action_not_found}
      action -> {:ok, action}
    end
  end

  defp find_northbound_action(id, actions) when is_binary(id) and is_list(actions) do
    Enum.find(actions, &(&1.id == id))
  end

  defp find_northbound_action(_id, actions) when is_list(actions), do: List.first(actions)
  defp find_northbound_action(_id, _actions), do: nil

  defp selected_interface_action_targets(socket) do
    device_uid = socket.assigns.device_uid

    targets =
      socket.assigns.selected_interfaces
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()
      |> Enum.map(&%{kind: "interface", device_uid: device_uid, interface_uid: &1})

    if targets == [], do: {:error, :targets_required}, else: {:ok, targets}
  end

  defp create_northbound_invocation(socket, action, targets, input_values) do
    northbound_invocation_service_module().create_and_dispatch(
      %{
        descriptor_id: Map.get(action, :descriptor_id),
        targets: targets,
        input_values: input_values,
        source: :user,
        metadata: %{
          "ui_surface" => "device_interfaces",
          "selected_target_count" => length(targets)
        }
      },
      actor: northbound_scope_actor(socket.assigns.current_scope)
    )
  end

  defp northbound_scope_actor(%{user: user, permissions: %MapSet{} = permissions}) when not is_nil(user) do
    permissions = fresh_northbound_permissions(user, permissions)

    user
    |> Map.take([:id, :email, :role, :role_profile_id])
    |> Map.put(:permissions, permissions)
  end

  defp northbound_scope_actor(%{user: user}) when not is_nil(user), do: user
  defp northbound_scope_actor(_scope), do: nil

  defp fresh_northbound_permissions(%ServiceRadar.Identity.User{} = user, _permissions) do
    ServiceRadar.Identity.RBAC.permissions_for_user(user, fresh?: true)
  end

  defp fresh_northbound_permissions(_user, permissions), do: permissions

  defp northbound_catalog_module do
    Application.get_env(:serviceradar_web_ng, :northbound_catalog_module, NorthboundCatalog)
  end

  defp northbound_invocation_service_module do
    Application.get_env(
      :serviceradar_web_ng,
      :northbound_invocation_service_module,
      NorthboundInvocationService
    )
  end

  defp validate_device_ip(device_ip) when is_binary(device_ip) and device_ip != "", do: :ok
  defp validate_device_ip(_), do: {:error, "No device IP available for MTR"}

  defp first_connected_agent_id do
    case list_connected_agents() do
      [first | _] ->
        agent_id = Map.get(first, :agent_id) || Map.get(first, "agent_id")

        if is_binary(agent_id) and String.trim(agent_id) != "" do
          {:ok, agent_id}
        else
          {:error, "Connected agent is missing an agent_id"}
        end

      [] ->
        {:error, "No agents connected"}
    end
  end

  defp list_connected_agents do
    AgentCommandBus.list_online_agents()
  rescue
    _ -> []
  end

  defp queue_mtr_trace(socket, device_ip) do
    with :ok <- validate_device_ip(device_ip) do
      target_ctx = build_mtr_target_ctx(socket, device_ip)

      case dispatch_with_automation_policy(target_ctx) do
        {:ok, [agent_id | _]} ->
          {:ok, agent_id}

        {:error, _} ->
          with {:ok, agent_id} <- first_connected_agent_id() do
            dispatch_direct_mtr_trace(socket, agent_id, device_ip)
          end
      end
    end
  end

  defp dispatch_direct_mtr_trace(socket, agent_id, device_ip) do
    payload = %{"target" => device_ip, "protocol" => "icmp"}
    context = %{"device_uid" => socket.assigns.device_uid, "target_ip" => device_ip}

    case AgentCommandBus.dispatch(agent_id, "mtr.run", payload, context: context) do
      {:ok, _command_id} ->
        {:ok, agent_id}

      {:error, {:agent_busy, :too_many_concurrent_mtr_traces}} ->
        {:error, "Agent is already running the maximum number of concurrent MTR traces"}

      {:error, reason} ->
        {:error, "Failed to run MTR: #{inspect(reason)}"}
    end
  end

  defp dispatch_with_automation_policy(target_ctx) do
    case MtrPolicy.list_enabled() do
      {:ok, policies} when is_list(policies) ->
        dispatch_with_first_matching_policy(policies, target_ctx)

      _ ->
        {:error, :no_enabled_policy}
    end
  end

  defp dispatch_with_first_matching_policy([], _target_ctx), do: {:error, :no_matching_policy}

  defp dispatch_with_first_matching_policy([policy | rest], target_ctx) do
    policy =
      policy
      |> Map.put_new(:baseline_canary_vantages, 0)
      |> Map.put_new("baseline_canary_vantages", 0)

    case MtrAutomationDispatcher.dispatch_for_mode(target_ctx, policy, :baseline) do
      {:ok, selected_agents} when is_list(selected_agents) and selected_agents != [] ->
        {:ok, selected_agents}

      _ ->
        dispatch_with_first_matching_policy(rest, target_ctx)
    end
  end

  defp build_mtr_target_ctx(socket, target_ip) do
    device_row = socket.assigns[:device_row] || %{}
    partition_id = device_row["partition"] || device_row["partition_id"] || "default"

    %{
      target: target_ip,
      target_ip: target_ip,
      target_device_uid: socket.assigns.device_uid,
      partition_id: partition_id,
      gateway_id: device_row["gateway_id"],
      target_key: "device:#{socket.assigns.device_uid}"
    }
  end

  defp format_tags_for_edit(nil), do: ""
  defp format_tags_for_edit(tags) when is_list(tags), do: Enum.join(tags, "\n")

  defp format_tags_for_edit(tags) when is_map(tags) do
    Enum.map_join(tags, "\n", fn {k, v} -> if v, do: "#{k}=#{v}", else: k end)
  end

  defp format_tags_for_edit(_), do: ""

  defp load_device_snmp_credential(_scope, nil), do: nil

  defp load_device_snmp_credential(scope, device_uid) do
    case DeviceSNMPCredential.get_by_device(device_uid, scope: scope) do
      {:ok, credential} -> credential
      {:error, _} -> nil
    end
  end

  defp snmp_credential_form_data(nil) do
    %{
      "version" => "v2c",
      "username" => "",
      "security_level" => "no_auth_no_priv",
      "auth_protocol" => "",
      "priv_protocol" => ""
    }
  end

  defp snmp_credential_form_data(%DeviceSNMPCredential{} = credential) do
    %{
      "version" => to_string(credential.version || :v2c),
      "username" => credential.username || "",
      "security_level" => to_string(credential.security_level || :no_auth_no_priv),
      "auth_protocol" => to_string(credential.auth_protocol || ""),
      "priv_protocol" => to_string(credential.priv_protocol || "")
    }
  end

  defp normalize_snmp_credential_params(params, editing) do
    params =
      if editing do
        drop_blank(params, ["community", "auth_password", "priv_password"])
      else
        params
      end

    params =
      case Map.get(params, "version") do
        nil -> Map.put(params, "version", "v2c")
        "" -> Map.put(params, "version", "v2c")
        _ -> params
      end

    case Map.get(params, "version") do
      "v1" ->
        Map.drop(params, [
          "username",
          "security_level",
          "auth_protocol",
          "auth_password",
          "priv_protocol",
          "priv_password"
        ])

      "v2c" ->
        Map.drop(params, [
          "username",
          "security_level",
          "auth_protocol",
          "auth_password",
          "priv_protocol",
          "priv_password"
        ])

      "v3" ->
        Map.delete(params, "community")

      _ ->
        params
    end
  end

  defp snmp_params_present?(params) do
    Enum.any?(["community", "username", "auth_password", "priv_password"], fn key ->
      value = Map.get(params, key)
      is_binary(value) and String.trim(value) != ""
    end)
  end

  defp drop_blank(params, keys) do
    Enum.reduce(keys, params, fn key, acc ->
      case Map.get(acc, key) do
        nil -> acc
        "" -> Map.delete(acc, key)
        _ -> acc
      end
    end)
  end

  defp load_interfaces(srql_module, device_uid, scope) do
    query = default_interfaces_query(device_uid)

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        {Enum.filter(results, &is_map/1), nil}

      {:ok, other} ->
        {[], "unexpected SRQL response: #{inspect(other)}"}

      {:error, reason} ->
        {[], "SRQL error: #{format_error(reason)}"}
    end
  end

  defp load_flows(srql_module, device_uid, scope, cursor) do
    query = default_flows_query(device_uid)
    opts = %{scope: scope, limit: @flows_limit, cursor: cursor}

    case srql_module.query(query, opts) do
      {:ok, %{"results" => results, "pagination" => pagination}} when is_list(results) ->
        {Enum.filter(results, &is_map/1), pagination || %{}, nil}

      {:ok, %{"results" => results}} when is_list(results) ->
        {Enum.filter(results, &is_map/1), %{}, nil}

      {:ok, %{"error" => error}} when is_binary(error) ->
        {[], %{}, error}

      {:ok, other} ->
        Logger.warning("Unexpected SRQL flows response for #{device_uid}: #{inspect(other)}")
        {[], %{}, "Failed to load flows data"}

      {:error, reason} ->
        Logger.warning("Failed to load device flows for #{device_uid}: #{inspect(reason)}")
        {[], %{}, "Failed to load flows data"}
    end
  end

  defp load_logs(srql_module, device_uid, scope, cursor) do
    query = default_logs_query(device_uid)
    opts = %{scope: scope, limit: @logs_limit, cursor: cursor}

    case srql_module.query(query, opts) do
      {:ok, %{"results" => results, "pagination" => pagination}} when is_list(results) ->
        {Enum.filter(results, &is_map/1), pagination || %{}, nil}

      {:ok, %{"results" => results}} when is_list(results) ->
        {Enum.filter(results, &is_map/1), %{}, nil}

      {:ok, %{"error" => error}} when is_binary(error) ->
        {[], %{}, error}

      {:ok, other} ->
        Logger.warning("Unexpected SRQL logs response for #{device_uid}: #{inspect(other)}")
        {[], %{}, "Failed to load logs"}

      {:error, reason} ->
        Logger.warning("Failed to load device logs for #{device_uid}: #{inspect(reason)}")
        {[], %{}, "Failed to load logs"}
    end
  end

  defp load_zoomed_flows(srql_mod, query, opts) do
    case srql_mod.query(query, opts) do
      {:ok, %{"results" => results, "pagination" => p}} when is_list(results) ->
        {Enum.filter(results, &is_map/1), p || %{}, nil}

      {:ok, %{"results" => results}} when is_list(results) ->
        {Enum.filter(results, &is_map/1), %{}, nil}

      _ ->
        {[], %{}, "Failed to load flows for selected range"}
    end
  end

  defp reload_flows_with_facets(socket, uid, facets) do
    scope = socket.assigns.current_scope
    srql_mod = srql_module()

    facet_tokens =
      facets
      |> Enum.filter(fn {field, _} -> field in @allowed_flow_filter_fields end)
      |> Enum.map_join(" ", fn {field, value} ->
        "#{field}:\"#{escape_value(value)}\""
      end)

    base = "in:flows device_id:\"#{escape_value(uid)}\" time:last_24h #{facet_tokens}"
    query = "#{base} sort:time:desc"
    opts = %{scope: scope, limit: @flows_limit, cursor: nil}

    flows_task = Task.async(fn -> {:flows, load_zoomed_flows(srql_mod, query, opts)} end)

    stats_task =
      Task.async(fn -> {:stats, load_device_flow_stats(srql_mod, uid, scope, base)} end)

    results = safe_yield_many([flows_task, stats_task], 15_000)

    {flows, pagination, flows_error} = Map.get(results, :flows, {[], %{}, nil})

    {flow_stats, sparkline_json, proto_json, chart_keys, chart_points, top_talkers_json, top_destinations_json,
     top_ports_json, top_protocols_json, facet_data} =
      Map.get(
        results,
        :stats,
        {%{}, "[]", "[]", "[]", "[]", "[]", "[]", "[]", "[]", %{protocols: [], directions: [], services: []}}
      )

    socket
    |> assign(:device_flows, flows)
    |> assign(:flows_pagination, pagination)
    |> assign(:flows_error, flows_error)
    |> assign(:flow_stats, flow_stats)
    |> assign(:flow_sparkline_json, sparkline_json)
    |> assign(:flow_proto_json, proto_json)
    |> assign(:flow_chart_keys_json, chart_keys)
    |> assign(:flow_chart_points_json, chart_points)
    |> assign(:flow_top_talkers_json, top_talkers_json)
    |> assign(:flow_top_destinations_json, top_destinations_json)
    |> assign(:flow_top_ports_json, top_ports_json)
    |> assign(:flow_top_protocols_json, top_protocols_json)
    |> assign(:flow_facets, facet_data)
    |> enrich_flow_ips()
  end

  defp maybe_begin_flow_background_loads(socket, "flows", uid, flows) do
    socket
    |> begin_flow_stats_refresh(uid)
    |> begin_flow_ip_enrichment(uid, flows)
  end

  defp maybe_begin_flow_background_loads(socket, _active_tab, _uid, _flows), do: socket

  defp empty_flow_stats_bundle do
    {%{}, "[]", "[]", "[]", "[]", "[]", "[]", "[]", "[]", %{protocols: [], directions: [], services: []}}
  end

  defp begin_flow_stats_refresh(socket, uid) do
    scope = socket.assigns.current_scope
    srql_mod = srql_module()
    request_ref = make_ref()

    {flow_stats, sparkline_json, proto_json, chart_keys, chart_points, top_talkers_json, top_destinations_json,
     top_ports_json, top_protocols_json, facets} =
      empty_flow_stats_bundle()

    socket
    |> assign(:flow_stats_request_ref, request_ref)
    |> assign(:flow_stats, flow_stats)
    |> assign(:flow_stats_loading, true)
    |> assign(:flow_sparkline_json, sparkline_json)
    |> assign(:flow_proto_json, proto_json)
    |> assign(:flow_chart_keys_json, chart_keys)
    |> assign(:flow_chart_points_json, chart_points)
    |> assign(:flow_top_talkers_json, top_talkers_json)
    |> assign(:flow_top_destinations_json, top_destinations_json)
    |> assign(:flow_top_ports_json, top_ports_json)
    |> assign(:flow_top_protocols_json, top_protocols_json)
    |> assign(:flow_facets, facets)
    |> start_async({:flow_stats, uid, request_ref}, fn ->
      load_device_flow_stats(srql_mod, uid, scope)
    end)
  end

  defp begin_flow_ip_enrichment(socket, uid, flows) do
    request_ref = make_ref()
    scope = Map.get(socket.assigns, :current_scope)
    ips = flow_ips(flows)

    if ips == [] do
      socket
      |> assign(:flow_ip_request_ref, request_ref)
      |> assign(:rdns_map, %{})
      |> assign(:geo_iso2_map, %{})
    else
      socket
      |> assign(:flow_ip_request_ref, request_ref)
      |> assign(:rdns_map, %{})
      |> assign(:geo_iso2_map, %{})
      |> start_async({:flow_ip_enrichment, uid, request_ref}, fn ->
        rdns_map = bulk_rdns(ips, scope)
        geo_iso2_map = bulk_geo_iso2(ips, scope)
        {rdns_map, geo_iso2_map}
      end)
    end
  end

  defp load_device_flow_stats(srql_mod, device_uid, scope) do
    load_device_flow_stats(
      srql_mod,
      device_uid,
      scope,
      "in:flows device_id:\"#{escape_value(device_uid)}\" time:last_24h"
    )
  end

  defp load_device_flow_stats(srql_mod, _device_uid, scope, base) do
    tasks = [
      Task.async(fn -> {:summary, load_device_flow_summary(srql_mod, scope, base)} end),
      Task.async(fn ->
        {:protocols, load_device_flow_protocols(srql_mod, scope, base)}
      end),
      Task.async(fn ->
        {:talkers, load_device_flow_top_n(srql_mod, scope, base, "src_endpoint_ip")}
      end),
      Task.async(fn ->
        {:destinations, load_device_flow_top_n(srql_mod, scope, base, "dst_endpoint_ip")}
      end),
      Task.async(fn ->
        {:ports, load_device_flow_top_n(srql_mod, scope, base, "dst_endpoint_port")}
      end),
      Task.async(fn ->
        {:directions, load_device_flow_top_n(srql_mod, scope, base, "direction")}
      end),
      Task.async(fn ->
        {:services, load_device_flow_top_n(srql_mod, scope, base, "dst_service_label")}
      end),
      Task.async(fn -> {:timeseries, load_device_flow_timeseries(srql_mod, scope, base)} end)
    ]

    results = safe_yield_many(tasks, 10_000)

    summary = Map.get(results, :summary, %{})
    protocols = Map.get(results, :protocols, [])
    talkers = Map.get(results, :talkers, [])
    destinations = Map.get(results, :destinations, [])
    ports = Map.get(results, :ports, [])
    directions = Map.get(results, :directions, [])
    services = Map.get(results, :services, [])
    timeseries = Map.get(results, :timeseries, [])

    proto_json =
      protocols
      |> Enum.map(fn row -> %{label: row[:name] || "unknown", value: row[:bytes] || 0} end)
      |> Jason.encode!()

    sparkline_json =
      timeseries
      |> Enum.map(fn %{t: t, v: v} -> %{t: t, v: v} end)
      |> Jason.encode!()

    chart_points =
      timeseries
      |> Enum.map(fn %{t: t, v: v} -> %{"t" => t, "bytes_total" => v} end)
      |> Jason.encode!()

    chart_keys = Jason.encode!(["bytes_total"])

    top_talkers_json = encode_top_n(talkers)
    top_destinations_json = encode_top_n(destinations)
    top_ports_json = encode_top_n(ports)
    top_protocols_json = encode_top_n(protocols)

    facets = %{
      protocols:
        Enum.map(protocols, fn row ->
          %{
            label: row[:name] || "unknown",
            value: row[:bytes] || 0,
            filter_value: row[:filter_value] || row[:name] || "unknown"
          }
        end),
      directions:
        Enum.map(directions, fn row ->
          %{label: row[:name] || "unknown", value: row[:bytes] || 0}
        end),
      services:
        services
        |> Enum.map(fn row ->
          %{label: row[:name] || "unknown", value: row[:bytes] || 0}
        end)
        |> Enum.reject(&(&1.label == "unknown"))
    }

    {summary, sparkline_json, proto_json, chart_keys, chart_points, top_talkers_json, top_destinations_json,
     top_ports_json, top_protocols_json, facets}
  end

  defp load_device_flow_summary(srql_mod, scope, base) do
    queries = [
      {"#{base} stats:sum(bytes_total) as total_bytes", :total_bytes, "total_bytes"},
      {"#{base} stats:sum(packets_total) as total_packets", :total_packets, "total_packets"},
      {"#{base} stats:count(*) as flow_count", :flow_count, "flow_count"},
      {"#{base} stats:count_distinct(src_endpoint_ip) as unique_talkers", :unique_talkers, "unique_talkers"}
    ]

    queries
    |> Enum.map(fn {q, key, alias_field} ->
      Task.async(fn -> {key, query_single_stat(srql_mod, scope, q, alias_field)} end)
    end)
    |> safe_yield_many(10_000)
  end

  defp query_single_stat(srql_mod, scope, query, alias_field) do
    srql_mod
    |> srql_results(query, scope)
    |> List.first()
    |> row_payload()
    |> flow_stat_number(alias_field)
  end

  defp load_device_flow_top_n(srql_mod, scope, base, group_field) do
    query =
      "#{base} stats:sum(bytes_total) as bytes_total by #{group_field} sort:bytes_total:desc limit:5"

    srql_mod
    |> srql_results(query, scope)
    |> Enum.map(fn row ->
      p = row_payload(row)

      %{
        name: flow_stat_field(p, group_field),
        bytes: flow_stat_number(p, "bytes_total")
      }
    end)
  end

  defp load_device_flow_protocols(srql_mod, scope, base) do
    query =
      ~s|#{base} stats:"sum(bytes_total) as bytes_total by protocol_num, protocol_name" sort:bytes_total:desc limit:5|

    srql_mod
    |> srql_results(query, scope)
    |> Enum.map(fn row ->
      p = row_payload(row)
      protocol_num = flow_stat_field(p, "protocol_num")
      protocol_name = flow_stat_field(p, "protocol_name")

      %{
        name: protocol_label(protocol_num, protocol_name),
        filter_value: protocol_filter_value(protocol_num, protocol_name),
        bytes: flow_stat_number(p, "bytes_total")
      }
    end)
  end

  defp load_device_flow_timeseries(srql_mod, scope, base) do
    query = "#{base} bucket:5m agg:sum value_field:bytes_total"

    case srql_mod.query(query, %{scope: scope}) do
      {:ok, %{"results" => results}} when is_list(results) ->
        results
        |> Enum.map(fn row ->
          raw_t = row["timestamp"] || row["bucket"] || row["time_bucket"]

          %{
            t: parse_timestamp_ms(raw_t),
            v: to_safe_number(row["value"] || row["bytes_total"] || 0)
          }
        end)
        |> Enum.reject(&is_nil(&1.t))

      _ ->
        []
    end
  end

  defp parse_timestamp_ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)

  defp parse_timestamp_ms(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)

  defp parse_timestamp_ms(raw) when is_integer(raw), do: if(raw < 1_000_000_000_000, do: raw * 1000, else: raw)

  defp parse_timestamp_ms(raw) when is_float(raw) do
    ms = trunc(raw)
    if ms < 1_000_000_000_000, do: ms * 1000, else: ms
  end

  defp parse_timestamp_ms(raw) when is_binary(raw) do
    with :error <- parse_iso8601_ms(raw),
         :error <- parse_naive_iso8601_ms(raw),
         do: nil
  end

  defp parse_timestamp_ms(_), do: nil

  defp parse_iso8601_ms(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> :error
    end
  end

  defp parse_naive_iso8601_ms(str) do
    case NaiveDateTime.from_iso8601(str) do
      {:ok, ndt} -> ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)
      _ -> :error
    end
  end

  defp encode_top_n(rows) do
    rows
    |> Enum.take(5)
    |> Enum.map(fn row ->
      %{
        label: row[:name] || "unknown",
        value: row[:bytes] || 0,
        filter_value: row[:filter_value] || row[:name] || "unknown"
      }
    end)
    |> Jason.encode!()
  end

  defp protocol_label(protocol_num, protocol_name) do
    case parse_protocol_num(protocol_num) do
      1 -> "ICMP"
      6 -> "TCP"
      17 -> "UDP"
      47 -> "GRE"
      50 -> "ESP"
      51 -> "AH"
      58 -> "ICMPv6"
      89 -> "OSPF"
      132 -> "SCTP"
      n when is_integer(n) -> normalized_protocol_name(protocol_name) || "proto #{n}"
      nil -> normalized_protocol_name(protocol_name) || "unknown"
    end
  end

  defp protocol_filter_value(protocol_num, protocol_name) do
    case parse_protocol_num(protocol_num) do
      n when is_integer(n) -> Integer.to_string(n)
      nil -> normalized_protocol_name(protocol_name) || "unknown"
    end
  end

  defp parse_protocol_num(n) when is_integer(n), do: n

  defp parse_protocol_num(n) when is_binary(n) do
    case Integer.parse(String.trim(n)) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp parse_protocol_num(_), do: nil

  defp normalized_protocol_name(name) when is_binary(name) do
    name = String.trim(name)
    if name == "", do: nil, else: String.upcase(name)
  end

  defp normalized_protocol_name(_), do: nil

  defp flow_stat_field(payload, key) when is_map(payload) do
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

  defp flow_stat_number(payload, key) do
    case flow_stat_field(payload, key) do
      n when is_number(n) ->
        n

      s when is_binary(s) ->
        case Float.parse(s) do
          {f, _} -> f
          :error -> 0
        end

      _ ->
        0
    end
  end

  defp to_safe_number(n) when is_number(n), do: n
  defp to_safe_number(nil), do: 0

  defp to_safe_number(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> 0
    end
  end

  defp to_safe_number(_), do: 0

  defp filter_interfaces_for_display(interfaces, device_row) when is_list(interfaces) and is_map(device_row) do
    if switch_device?(device_row) do
      front_panel = Enum.filter(interfaces, &front_panel_switch_interface?/1)

      # Keep the full list unless we found a meaningful front-panel subset.
      if length(front_panel) >= 8 and length(front_panel) < length(interfaces) do
        Enum.sort_by(front_panel, &Map.get(&1, "if_index"))
      else
        interfaces
      end
    else
      interfaces
    end
  end

  defp filter_interfaces_for_display(interfaces, _device_row), do: interfaces

  defp switch_device?(device_row) when is_map(device_row) do
    type =
      device_row
      |> Map.get("type", "")
      |> to_string()
      |> String.downcase()
      |> String.trim()

    type_id = Map.get(device_row, "type_id")
    type in ["switch", "l2 switch"] or type_id == 10
  end

  defp front_panel_switch_interface?(iface) when is_map(iface) do
    if_index = Map.get(iface, "if_index")
    if_name = normalize_interface_label(Map.get(iface, "if_name"))
    if_descr = normalize_interface_label(Map.get(iface, "if_descr"))

    is_integer(if_index) and if_index > 0 and if_index <= 256 and
      (numeric_port_label?(if_name) or numeric_port_label?(if_descr))
  end

  defp front_panel_switch_interface?(_), do: false

  defp normalize_interface_label(nil), do: ""

  defp normalize_interface_label(value) do
    value
    |> to_string()
    |> String.trim()
  end

  defp numeric_port_label?(label) when is_binary(label) do
    label != "" and String.match?(label, ~r/^(?:port\s*)?\d+$/i)
  end

  defp load_interface_settings(_scope, nil), do: empty_interface_settings()

  defp load_interface_settings(scope, device_uid) do
    case InterfaceSettings.list_by_device(device_uid, scope: scope) do
      {:ok, settings} ->
        by_uid = Map.new(settings, &{&1.interface_uid, &1})

        favorited =
          settings
          |> Enum.filter(& &1.favorited)
          |> MapSet.new(& &1.interface_uid)

        metrics_enabled =
          settings
          |> Enum.filter(&metrics_enabled_setting?/1)
          |> MapSet.new(& &1.interface_uid)

        %{favorited: favorited, metrics_enabled: metrics_enabled, by_uid: by_uid}

      {:error, _reason} ->
        empty_interface_settings()
    end
  end

  defp empty_interface_settings do
    %{favorited: MapSet.new(), metrics_enabled: MapSet.new(), by_uid: %{}}
  end

  defp metrics_enabled_setting?(setting) do
    setting.metrics_enabled == true and is_list(setting.metrics_selected) and
      setting.metrics_selected != []
  end

  defp apply_interface_settings(interfaces, settings_by_uid) when is_list(interfaces) do
    Enum.map(interfaces, fn iface ->
      uid = Map.get(iface, "interface_uid")

      case Map.get(settings_by_uid, uid) do
        nil ->
          iface

        setting ->
          iface
          |> Map.put("metrics_enabled", metrics_enabled_setting?(setting))
          |> Map.put("favorited", setting.favorited)
      end
    end)
  end

  defp apply_interface_settings(interfaces, _settings_by_uid), do: interfaces

  defp load_interface_metrics(_srql_module, _device_uid, favorited, _metrics_enabled, _interfaces, _scope)
       when map_size(favorited) == 0 do
    %{
      has_favorited: false,
      panels: [],
      error: nil,
      favorited_count: 0
    }
  end

  defp load_interface_metrics(srql_module, device_uid, favorited_uids, metrics_enabled_uids, interfaces, scope) do
    total_favorited = MapSet.size(favorited_uids)
    enabled_favorited_uids = MapSet.intersection(favorited_uids, metrics_enabled_uids)

    if MapSet.size(enabled_favorited_uids) == 0 do
      %{
        has_favorited: total_favorited > 0,
        panels: [],
        error: nil,
        favorited_count: total_favorited,
        message: "Metrics collection is disabled for favorited interfaces."
      }
    else
      build_favorited_interface_metrics(
        srql_module,
        device_uid,
        enabled_favorited_uids,
        interfaces,
        scope,
        total_favorited
      )
    end
  end

  defp build_favorited_interface_metrics(
         srql_module,
         device_uid,
         enabled_favorited_uids,
         interfaces,
         scope,
         total_favorited
       ) do
    # Get the favorited interfaces with their if_index, name, and speed
    favorited_interfaces =
      interfaces
      |> Enum.filter(fn iface ->
        uid = Map.get(iface, "interface_uid")

        is_binary(uid) and MapSet.member?(enabled_favorited_uids, uid) and
          is_integer(Map.get(iface, "if_index"))
      end)
      |> Enum.map(fn iface ->
        # Get interface speed for proper graph scaling (bps -> bytes per second)
        if_speed_bps = Map.get(iface, "speed_bps") || Map.get(iface, "if_speed")
        if_speed_bytes_per_sec = if is_number(if_speed_bps), do: if_speed_bps / 8

        %{
          if_index: Map.get(iface, "if_index"),
          name:
            Map.get(iface, "if_name") || Map.get(iface, "if_descr") ||
              "Interface #{Map.get(iface, "if_index")}",
          max_speed_bytes_per_sec: if_speed_bytes_per_sec
        }
      end)

    if favorited_interfaces == [] do
      %{
        has_favorited: total_favorited > 0,
        panels: [],
        error: nil,
        favorited_count: total_favorited,
        message: "No interface metrics available. Favorited interfaces may not have SNMP indices."
      }
    else
      # Query SNMP metrics for each favorited interface separately and build panels per interface
      # Use agg:max to pull the latest counter values per bucket; rate deltas are calculated in UI
      {all_panels, errors} =
        Enum.reduce(favorited_interfaces, {[], []}, fn fav_iface, {panels_acc, errs} ->
          query_interface_metrics(srql_module, device_uid, fav_iface, scope, panels_acc, errs)
        end)

      cond do
        all_panels != [] ->
          %{
            has_favorited: total_favorited > 0,
            panels: all_panels,
            error: nil,
            favorited_count: total_favorited
          }

        errors != [] ->
          %{
            has_favorited: total_favorited > 0,
            panels: [],
            error: "Failed to load metrics: #{Enum.join(Enum.uniq(errors), "; ")}",
            favorited_count: total_favorited
          }

        true ->
          %{
            has_favorited: total_favorited > 0,
            panels: [],
            error: nil,
            favorited_count: total_favorited,
            message: "No metrics data available yet. Ensure SNMP polling is configured for this device."
          }
      end
    end
  end

  # Helper to query metrics for a single interface (extracted to reduce nesting depth)
  defp query_interface_metrics(srql_module, device_uid, fav_iface, scope, panels_acc, errs) do
    %{if_index: if_index, name: iface_name, max_speed_bytes_per_sec: max_speed} = fav_iface

    query =
      "in:snmp_metrics device_id:\"#{escape_value(device_uid)}\" if_index:#{if_index} " <>
        "time:last_24h bucket:5m agg:max series:metric_name limit:#{@snmp_metrics_limit}"

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => results} = response} when is_list(results) and results != [] ->
        interface_panels = build_interface_panels(response, iface_name, if_index, max_speed)
        {panels_acc ++ interface_panels, errs}

      {:ok, %{"results" => []}} ->
        {panels_acc, errs}

      {:error, reason} ->
        {panels_acc, [format_error(reason) | errs]}

      _ ->
        {panels_acc, errs}
    end
  end

  # Build panels for interface metrics (extracted to reduce nesting depth)
  # Takes full SRQL response (including viz) to properly handle series grouping
  defp build_interface_panels(srql_response, iface_name, if_index, max_speed) do
    srql_response
    |> Engine.build_panels()
    |> Enum.reject(&(&1.plugin == TablePlugin))
    |> Enum.map(fn panel ->
      assigns =
        panel.assigns
        |> Map.put(:interface_label, "#{iface_name} (ifIndex: #{if_index})")
        |> Map.put(:max_speed_bytes_per_sec, max_speed)
        # Enable combined chart mode for traffic metrics (inbound + outbound on same chart)
        |> Map.put(:chart_mode, :combined)
        |> Map.put(:rate_mode, :counter)

      %{panel | assigns: assigns}
    end)
  end

  defp upsert_interface_setting(_scope, nil, _interface_uid, _attrs), do: {:error, :no_device}
  defp upsert_interface_setting(_scope, _device_uid, nil, _attrs), do: {:error, :no_interface}

  defp upsert_interface_setting(scope, device_uid, interface_uid, attrs) do
    InterfaceSettings.upsert(device_uid, interface_uid, attrs, scope: scope)
  end

  defp bulk_update_favorites(scope, device_uid, selected_uids, favorited, current_favorites) do
    # Persist each selected interface's favorite status
    results =
      selected_uids
      |> MapSet.to_list()
      |> Enum.map(fn uid ->
        case upsert_interface_setting(scope, device_uid, uid, %{favorited: favorited}) do
          {:ok, _} -> {:ok, uid}
          {:error, _} -> {:error, uid}
        end
      end)

    success_count = Enum.count(results, fn {status, _} -> status == :ok end)

    # Update the MapSet based on success
    successful_uids =
      results
      |> Enum.filter(fn {status, _} -> status == :ok end)
      |> MapSet.new(fn {_, uid} -> uid end)

    new_favorites =
      if favorited do
        MapSet.union(current_favorites, successful_uids)
      else
        MapSet.difference(current_favorites, successful_uids)
      end

    {success_count, new_favorites}
  end

  defp bulk_update_metrics(scope, device_uid, selected_uids, metrics_enabled) do
    # Persist each selected interface's metrics_enabled status
    results =
      selected_uids
      |> MapSet.to_list()
      |> Enum.map(fn uid ->
        case upsert_interface_setting(scope, device_uid, uid, %{metrics_enabled: metrics_enabled}) do
          {:ok, _} -> :ok
          {:error, _} -> :error
        end
      end)

    Enum.count(results, &(&1 == :ok))
  end

  defp bulk_update_tags(scope, device_uid, selected_uids, tags) do
    # Add tags to each selected interface (preserving existing tags)
    results =
      selected_uids
      |> MapSet.to_list()
      |> Enum.map(fn uid ->
        # First get existing settings to merge tags
        existing_tags =
          case InterfaceSettings.get_by_interface(device_uid, uid, scope: scope) do
            {:ok, settings} -> settings.tags || []
            _ -> []
          end

        merged_tags = Enum.uniq(existing_tags ++ tags)

        case upsert_interface_setting(scope, device_uid, uid, %{tags: merged_tags}) do
          {:ok, _} -> :ok
          {:error, _} -> :error
        end
      end)

    Enum.count(results, &(&1 == :ok))
  end

  defp parse_tags(tags_string) when is_binary(tags_string) do
    tags_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp parse_tags(_), do: []

  defp load_ip_aliases(_scope, nil, _show_stale), do: {[], nil}
  defp load_ip_aliases(nil, _device_uid, _show_stale), do: {[], "Scope unavailable"}

  defp load_ip_aliases(scope, device_uid, show_stale) do
    require Ash.Query

    query =
      DeviceAliasState
      |> Ash.Query.for_read(:read, %{}, scope: scope)
      |> Ash.Query.filter(device_id == ^device_uid and alias_type == :ip)
      |> maybe_filter_alias_states(show_stale)
      |> Ash.Query.sort(alias_value: :asc)

    case Ash.read(query, scope: scope) do
      {:ok, aliases} -> {aliases, nil}
      {:error, reason} -> {[], format_error(reason)}
    end
  end

  defp maybe_filter_alias_states(query, true), do: query

  defp maybe_filter_alias_states(query, false) do
    Ash.Query.filter(query, state in [:detected, :confirmed, :updated])
  end

  defp load_northbound_device_history(nil, _device_uid), do: {[], nil}
  defp load_northbound_device_history(_scope, nil), do: {[], nil}

  defp load_northbound_device_history(scope, device_uid) do
    if RBAC.can?(scope, "northbound.actions.view") do
      case NorthboundHistory.list_for_device(device_uid, scope: scope, limit: 10) do
        {:ok, entries} ->
          {entries, nil}

        {:error, reason} ->
          Logger.warning("Failed to load northbound device action history: #{inspect(reason)}")
          {[], "Failed to load task history."}
      end
    else
      {[], nil}
    end
  end

  @impl true
  def render(assigns) do
    device_row = List.first(Enum.filter(assigns.results, &is_map/1))

    assigns =
      assigns
      |> assign(:device_row, device_row)
      |> assign(:can_edit, can_edit_device?(assigns.current_scope))
      |> assign(:can_manage, can_manage_device?(assigns.current_scope))
      |> assign(:can_console, can_console_device?(assigns.current_scope))
      |> assign(:can_remote_access, can_remote_access_device?(assigns.current_scope, device_row))
      |> assign(:can_remote_access_app, can_remote_access_app?(assigns.current_scope))
      |> assign(
        :can_manage_rdp_targets,
        can_manage_rdp_targets?(assigns.current_scope, device_row)
      )
      |> assign(:can_run_ansible, can_run_ansible?(assigns.current_scope))
      |> assign(
        :can_view_northbound_history,
        RBAC.can?(assigns.current_scope, "northbound.actions.view")
      )
      |> assign(:device_ansible_managed, ansible_managed?(device_row))
      |> assign(:device_deleted, deleted_device?(device_row))
      |> assign(:device_active, device_active_state(device_row, row_metadata(device_row)))
      |> assign(:device_display_name, device_display_name(device_row))
      |> assign(:agent_device, agent_device?(device_row))
      |> assign(:proxmox_console_target, proxmox_console_target?(Map.get(assigns, :virtualization_summary)))
      |> assign(
        :proxmox_console_path,
        proxmox_console_path(assigns.device_uid, Map.get(assigns, :virtualization_summary))
      )
      |> assign(:proxmox_console_action_label, proxmox_console_action_label(Map.get(assigns, :virtualization_summary)))
      |> assign(:rdp_target_path, rdp_target_new_path(assigns.device_uid, device_row))
      |> assign(
        :active_fingerprint_tab_visible,
        active_fingerprint_tab_visible?(device_row, assigns.current_scope)
      )
      |> assign(:process_listeners_tab_visible, process_listeners_tab_visible?(device_row))
      |> assign(:sysmon_metrics_visible, sysmon_metrics_visible?(assigns))
      |> assign(
        :metric_sections_to_render,
        if sysmon_metrics_visible?(assigns) do
          Enum.filter(assigns.metric_sections, fn section ->
            is_binary(Map.get(section, :error)) or
              Map.get(section, :panels, []) != [] or Map.get(section, :rows, []) != [] or
              not is_nil(Map.get(section, :header_value)) or
              not is_nil(Map.get(section, :header_stats))
          end)
        else
          []
        end
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <.device_show_header
          active_tab={@active_tab}
          device_uid={@device_uid}
          device_display_name={@device_display_name}
          agent_device={@agent_device}
          device_deleted={@device_deleted}
          device_active={@device_active}
          device_ansible_managed={@device_ansible_managed}
          can_run_ansible={@can_run_ansible}
          can_console={@can_console}
          can_remote_access={@can_remote_access}
          can_remote_access_app={@can_remote_access_app}
          can_manage_rdp_targets={@can_manage_rdp_targets}
          can_edit={@can_edit}
          can_manage={@can_manage}
          editing={@editing}
          proxmox_console_target={@proxmox_console_target}
          proxmox_console_path={@proxmox_console_path}
          proxmox_console_action_label={@proxmox_console_action_label}
          rdp_target_path={@rdp_target_path}
        />

        <div class="grid grid-cols-1 gap-4">
          <div :if={is_nil(@device_row)} class="text-sm text-base-content/70 p-4">
            No device row returned for this query.
          </div>

    <!-- View Mode -->
          <.device_summary_section
            :if={is_map(@device_row) and not @editing}
            device_row={@device_row}
            device_deleted={@device_deleted}
            editing={@editing}
          />

    <!-- Edit Mode -->
          <.device_edit_section
            :if={is_map(@device_row) and @editing}
            device_row={@device_row}
            device_form={@device_form}
            device_snmp_credential={@device_snmp_credential}
            snmp_credential_form={@snmp_credential_form}
          />

    <!-- Tabs Navigation -->
          <.device_tabs
            :if={is_map(@device_row)}
            device_row={@device_row}
            active_tab={@active_tab}
            has_virtualization_guests={@has_virtualization_guests}
            has_ifaces={@has_ifaces}
            has_flows={@has_flows}
            has_logs={@has_logs}
            sysmon_presence={@sysmon_presence}
            active_fingerprint_tab_visible={@active_fingerprint_tab_visible}
            process_listeners_tab_visible={@process_listeners_tab_visible}
            has_mtr={@has_mtr}
          />

    <!-- Details Tab Content -->
          <div :if={@active_tab == "details"}>
            <div class="grid grid-cols-1 gap-4">
              <.ocsf_info_section :if={is_map(@device_row)} device_row={@device_row} />

              <.metadata_summary_section :if={is_map(@device_row)} device_row={@device_row} />

              <.network_visibility_section :if={is_map(@device_row)} device_row={@device_row} />

              <.agents_section :if={is_map(@device_row)} device_row={@device_row} />

              <.camera_streams_section
                :if={
                  camera_streams_visible?(
                    @camera_sources,
                    @camera_inventory_error,
                    @active_camera_relay_session,
                    @last_camera_relay_session
                  )
                }
                camera_sources={@camera_sources}
                inventory_error={@camera_inventory_error}
                active_session={@active_camera_relay_session}
                last_session={@last_camera_relay_session}
              />

              <.availability_section :if={is_map(@availability)} availability={@availability} />

              <.agent_availability_section
                :if={is_list(@agent_availability)}
                rows={@agent_availability}
                device_row={@device_row}
                sweep_results={@sweep_results}
              />

              <.healthcheck_section
                :if={is_map(@healthcheck_summary)}
                summary={@healthcheck_summary}
              />

              <.virtualization_section
                :if={is_map(@virtualization_summary)}
                summary={@virtualization_summary}
              />

              <.sweep_status_section :if={is_map(@sweep_results)} sweep_results={@sweep_results} />

              <.ip_aliases_section
                :if={is_list(@ip_aliases)}
                aliases={@ip_aliases}
                show_stale={@show_stale_aliases}
                error={@ip_alias_error}
              />

              <.northbound_action_history
                :if={@can_view_northbound_history}
                title="Task History"
                subtitle="Recent actions for this device and its interfaces"
                entries={@northbound_device_history}
                error={@northbound_device_history_error}
                notice={@northbound_launch_notice}
                empty_message="No task invocations have been recorded for this device yet."
              />

              <.metric_sections_content
                sections={@metric_sections_to_render}
                device_uid={@device_uid}
              />

              <.process_metrics_section
                :if={@sysmon_metrics_visible and is_list(@process_metrics)}
                metrics={@process_metrics}
              />

              <%= for panel <- @panels do %>
                <%= if panel.plugin == TablePlugin and length(@results) == 1 and is_map(@device_row) do %>
                  <.device_properties_card row={@device_row} />
                <% else %>
                  <.live_component
                    module={panel.plugin}
                    id={"device-#{panel.id}"}
                    title={panel.title}
                    panel_assigns={panel.assigns}
                  />
                <% end %>
              <% end %>
            </div>
          </div>

    <!-- Guests Tab Content -->
          <div :if={@active_tab == "guests" and @has_virtualization_guests}>
            <.virtualization_guests_tab summary={@virtualization_summary} />
          </div>

    <!-- Interfaces Tab Content -->
          <div :if={@active_tab == "interfaces" and @has_ifaces}>
            <.interfaces_tab_content
              interfaces={@network_interfaces}
              error={@interfaces_error}
              selected_interfaces={@selected_interfaces}
              favorited_interfaces={@favorited_interfaces}
              device_uid={@device_uid}
              interface_metrics={@interface_metrics}
              discovery_job={@discovery_job}
              interface_metrics_layout={@interface_metrics_layout}
              northbound_actions={@northbound_interface_actions}
              northbound_actions_loading={@northbound_interface_actions_loading}
              can_launch_northbound={can_launch_northbound_actions?(@current_scope)}
            />
          </div>

    <!-- Flows Tab Content -->
          <div :if={@active_tab == "flows" and @has_flows}>
            <.flows_tab_content
              flows={@device_flows}
              error={@flows_error}
              pagination={@flows_pagination}
              rdns_map={@rdns_map}
              geo_iso2_map={@geo_iso2_map}
              device_uid={@device_uid}
              query={default_flows_query(@device_uid)}
              limit={@flows_limit}
              flow_stats={@flow_stats}
              flow_stats_loading={@flow_stats_loading}
              sparkline_json={@flow_sparkline_json}
              proto_json={@flow_proto_json}
              flow_chart_keys_json={@flow_chart_keys_json}
              flow_chart_points_json={@flow_chart_points_json}
              top_talkers_json={@flow_top_talkers_json}
              top_destinations_json={@flow_top_destinations_json}
              top_ports_json={@flow_top_ports_json}
              top_protocols_json={@flow_top_protocols_json}
              facets={@flow_facets}
              active_facets={@flow_active_facets}
              active_topn={@flow_active_topn}
              zoom_range={@flow_zoom_range}
            />
          </div>
          <!-- Logs Tab Content -->
          <div :if={@active_tab == "logs" and @has_logs}>
            <.device_logs_tab_content
              logs={@device_logs}
              error={@logs_error}
              loading={@logs_loading}
              pagination={@logs_pagination}
              device_uid={@device_uid}
              query={default_logs_query(@device_uid)}
              limit={@logs_limit}
            />
          </div>

    <!-- Profiles Tab Content (only when sysmon is active) -->
          <div :if={@active_tab == "profiles" and @sysmon_presence}>
            <div class="grid grid-cols-1 gap-4">
              <.sysmon_profile_card
                :if={is_map(@sysmon_profile_info)}
                profile_info={@sysmon_profile_info}
                available_profiles={@available_profiles}
                device_uid={@device_uid}
              />
            </div>
          </div>

    <!-- Active Fingerprint Tab Content -->
          <div :if={
            @active_tab == "active-fingerprint" and can_view_active_fingerprint?(@current_scope)
          }>
            <.active_fingerprint_tab_content device_row={@device_row} />
          </div>

    <!-- Process Listeners Tab Content -->
          <div :if={@active_tab == "process-listeners"}>
            <.process_listeners_tab_content device_row={@device_row} />
          </div>

    <!-- MTR Diagnostics Tab Content -->
          <.mtr_tab_content
            :if={@active_tab == "mtr"}
            device_uid={@device_uid}
            fallback_target={get_device_ip(@results)}
            traces={@mtr_traces}
            pending_jobs={@mtr_pending_jobs}
            trends={@mtr_trends}
            total_count={@mtr_total_count}
            coverage={@mtr_coverage}
            retention_status={@mtr_retention_status}
            page={@mtr_page}
            page_size={@mtr_page_size}
          />
        </div>
      </div>

      <.mtr_trace_modal
        show={@show_mtr_trace_modal}
        trace={@selected_mtr_trace}
        hops={@selected_mtr_hops}
      />

      <%!-- Interfaces Bulk Edit Modal --%>
      <.interfaces_bulk_edit_modal
        :if={@show_interfaces_bulk_edit}
        form={@interfaces_bulk_edit_form}
        selected_count={MapSet.size(@selected_interfaces)}
      />

      <.northbound_action_modal
        :if={@show_northbound_interface_action_modal}
        id="northbound_interface_action_modal"
        title="Run Interface Task"
        subtitle={"#{MapSet.size(@selected_interfaces)} selected interface(s)"}
        form={@northbound_interface_action_form}
        actions={@northbound_interface_actions}
        action={@northbound_interface_launch_action}
        error={@northbound_interface_action_error}
        close_event="close_northbound_interface_action_modal"
        change_event="northbound_interface_action_change"
        submit_event="launch_northbound_interface_action"
      />
    </Layouts.app>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, default: nil)
  attr(:mono, :boolean, default: false)

  def kv_inline(assigns) do
    ~H"""
    <div class="flex items-start gap-2">
      <span class="shrink-0 text-base-content/60">{@label}:</span>
      <span class={[
        "min-w-0 flex-1 break-words whitespace-normal text-base-content",
        @mono && "font-mono text-xs"
      ]}>
        {format_value(@value)}
      </span>
    </div>
    """
  end

  defp format_value(nil), do: "—"
  defp format_value(""), do: "—"
  defp format_value(v) when is_binary(v), do: v
  defp format_value(v), do: to_string(v)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp row_metadata(row) when is_map(row) do
    case Map.get(row, "metadata") || Map.get(row, :metadata) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp row_metadata(_row), do: %{}

  defp enrich_integration_metadata(nil, _scope), do: nil

  defp enrich_integration_metadata(row, scope) when is_map(row) do
    metadata = row_metadata(row)
    sync_service_id = Map.get(metadata, "sync_service_id")

    metadata =
      metadata
      |> maybe_put_sync_service_path(sync_service_id)
      |> maybe_put_armis_device_url(sync_service_id, scope)

    Map.put(row, "metadata", metadata)
  end

  defp maybe_put_sync_service_path(metadata, sync_service_id)
       when is_map(metadata) and is_binary(sync_service_id) and sync_service_id != "" do
    Map.put(metadata, "sync_service_path", ~p"/settings/networks/integrations/#{sync_service_id}")
  end

  defp maybe_put_sync_service_path(metadata, _sync_service_id), do: metadata

  defp maybe_put_armis_device_url(metadata, sync_service_id, scope)
       when is_map(metadata) and is_binary(sync_service_id) and sync_service_id != "" do
    armis_id =
      metadata_first_value(metadata, ["armis_device_id", "source_device_id", "integration_id"])

    if metadata_lookup(metadata, "integration_type") == "armis" and present?(armis_id) do
      case IntegrationSource.get_by_id(sync_service_id, scope: scope) do
        {:ok, %IntegrationSource{endpoint: endpoint}} ->
          Map.put(metadata, "armis_device_url", armis_device_url(endpoint, armis_id))

        _ ->
          metadata
      end
    else
      metadata
    end
  rescue
    _ -> metadata
  end

  defp maybe_put_armis_device_url(metadata, _sync_service_id, _scope), do: metadata

  defp armis_device_url(endpoint, armis_id) when is_binary(endpoint) do
    endpoint
    |> String.trim()
    |> String.trim_trailing("/")
    |> Kernel.<>("/inventory/devices/#{armis_id}/")
  end

  defp armis_device_url(_endpoint, _armis_id), do: nil

  defp metadata_value(row, key) when is_map(row) and is_binary(key) do
    row
    |> row_metadata()
    |> Map.get(key)
  end

  defp metadata_value(_row, _key), do: nil

  defp metadata_first_value(metadata, keys) when is_map(metadata) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(metadata, key) do
        value when value in [nil, ""] -> nil
        value -> value
      end
    end)
  end

  defp enrich_flow_ips(socket) do
    flows = socket.assigns.device_flows
    scope = Map.get(socket.assigns, :current_scope)
    ips = flow_ips(flows)

    if ips == [] do
      socket |> assign(:rdns_map, %{}) |> assign(:geo_iso2_map, %{})
    else
      tasks = [
        Task.async(fn -> {:rdns, bulk_rdns(ips, scope)} end),
        Task.async(fn -> {:geo, bulk_geo_iso2(ips, scope)} end)
      ]

      results = safe_yield_many(tasks, 3_000)

      socket
      |> assign(:rdns_map, Map.get(results, :rdns, %{}))
      |> assign(:geo_iso2_map, Map.get(results, :geo, %{}))
    end
  end

  defp flow_ips(flows) when is_list(flows) do
    flows
    |> Enum.flat_map(fn flow ->
      [Map.get(flow, "src_endpoint_ip"), Map.get(flow, "dst_endpoint_ip")]
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(200)
  end

  defp flow_ips(_), do: []

  defp bulk_rdns(ips, scope) do
    query = IpRdnsCache |> Ash.Query.for_read(:read, %{}) |> Ash.Query.filter(ip in ^ips)

    case Ash.read(query, scope: scope) do
      {:ok, rows} when is_list(rows) ->
        rows
        |> Enum.filter(&rdns_row_valid?/1)
        |> Map.new(fn r -> {r.ip, r.hostname} end)

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp rdns_row_valid?(r) do
    ok? =
      case r.status do
        :ok -> true
        "ok" -> true
        s when is_binary(s) -> String.downcase(String.trim(s)) == "ok"
        _ -> false
      end

    ok? and is_binary(r.hostname) and String.trim(r.hostname) != ""
  end

  defp bulk_geo_iso2(ips, scope) do
    query = IpGeoEnrichmentCache |> Ash.Query.for_read(:read, %{}) |> Ash.Query.filter(ip in ^ips)

    case Ash.read(query, scope: scope) do
      {:ok, rows} when is_list(rows) ->
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

  attr(:label, :string, required: true)
  attr(:value, :any, default: nil)

  defp kv_block(assigns) do
    ~H"""
    <div>
      <div class="text-xs text-base-content/50">{@label}</div>
      <div class="font-medium">{format_value(@value)}</div>
    </div>
    """
  end

  defp parse_limit(nil, default, _max), do: default

  defp parse_limit(limit, default, max) when is_binary(limit) do
    case Integer.parse(limit) do
      {value, ""} -> parse_limit(value, default, max)
      _ -> default
    end
  end

  defp parse_limit(limit, _default, max) when is_integer(limit) and limit > 0 do
    min(limit, max)
  end

  defp parse_limit(_limit, default, _max), do: default

  defp parse_positive_page(nil), do: 1

  defp parse_positive_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {value, ""} when value > 0 -> value
      _ -> 1
    end
  end

  defp parse_positive_page(page) when is_integer(page) and page > 0, do: page
  defp parse_positive_page(_), do: 1

  defp timed_device_task(key, fun) when is_atom(key) and is_function(fun, 0) do
    {key,
     Task.async(fn ->
       started_at = System.monotonic_time(:millisecond)
       value = fun.()
       elapsed_ms = System.monotonic_time(:millisecond) - started_at

       if elapsed_ms >= @slow_device_task_ms do
         Logger.warning("Device details task #{key} took #{elapsed_ms}ms")
       end

       {key, value}
     end)}
  end

  # Returns a map of results; timed-out or crashed tasks are silently omitted.
  defp safe_yield_many(tasks, timeout) do
    keyed_tasks = Enum.map(tasks, &normalize_timed_task/1)
    key_by_ref = Map.new(keyed_tasks, fn {key, task} -> {task.ref, key} end)

    keyed_tasks
    |> Enum.map(fn {_key, task} -> task end)
    |> Task.yield_many(timeout)
    |> Enum.map(fn {task, result} ->
      key = Map.get(key_by_ref, task.ref)

      case result do
        {:ok, {key, value}} when is_atom(key) ->
          {key, value}

        {:ok, _unexpected} ->
          nil

        _ ->
          if not is_nil(key) do
            Logger.warning("Device details task #{key} timed out after #{timeout}ms")
          end

          Task.shutdown(task, :brutal_kill)
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp normalize_timed_task({key, %Task{} = task}) when is_atom(key), do: {key, task}
  defp normalize_timed_task(%Task{} = task), do: {nil, task}

  defp escape_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp escape_value(other), do: escape_value(to_string(other))

  defp first_present(values) when is_list(values) do
    Enum.find_value(values, fn
      nil -> nil
      "" -> nil
      value -> value
    end)
  end

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

  defp sysmon_metrics_visible?(assigns) do
    Map.get(assigns, :sysmon_presence, false)
  end

  defp format_error(%Jason.DecodeError{} = err), do: Exception.message(err)
  defp format_error(%ArgumentError{} = err), do: Exception.message(err)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp execute_srql_query(srql_module, query, scope) do
    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => results} = resp} when is_list(results) ->
        viz = if is_map(resp["viz"]), do: resp["viz"]
        {results, nil, viz}

      {:ok, other} ->
        {[], "unexpected SRQL response: #{inspect(other)}", nil}

      {:error, reason} ->
        {[], "SRQL error: #{format_error(reason)}", nil}
    end
  end

  # ---------------------------------------------------------------------------
  # Data Loading Functions
  # ---------------------------------------------------------------------------

  defp load_virtualization_summary(nil, _device_uid), do: nil

  defp load_virtualization_summary(scope, device_uid) do
    host = load_virtualization_host(scope, device_uid)
    guest = load_virtualization_guest(scope, device_uid)

    cond do
      host ->
        host_id = host.id

        %{
          kind: :host,
          host: host,
          cluster: load_virtualization_cluster(scope, host.cluster_id),
          guest: nil,
          datastores: load_virtualization_datastores(scope, host_id),
          disks: load_virtualization_disks(scope, host_id),
          network_interfaces: load_virtualization_network_interfaces(scope, host_id),
          storage_systems: load_virtualization_storage_systems(scope, host_id),
          guests: load_virtualization_guests_for_host(scope, host_id)
        }

      guest ->
        %{
          kind: :guest,
          host: nil,
          cluster: nil,
          guest: guest,
          datastores: [],
          disks: [],
          network_interfaces: load_virtualization_network_interfaces_for_guest(scope, guest.id),
          storage_systems: [],
          guests: []
        }

      true ->
        nil
    end
  rescue
    error ->
      Logger.warning("Failed to load virtualization summary for #{device_uid}: #{inspect(error)}")

      nil
  end

  defp load_virtualization_host(scope, device_uid) do
    VirtualizationHost
    |> virtualization_query(scope)
    |> Ash.Query.filter(device_uid == ^device_uid)
    |> Ash.Query.sort(observed_at: :desc)
    |> Ash.Query.limit(1)
    |> ash_read_first(scope)
  end

  defp load_virtualization_guest(scope, device_uid) do
    VirtualizationGuest
    |> virtualization_query(scope)
    |> Ash.Query.filter(device_uid == ^device_uid)
    |> Ash.Query.sort(observed_at: :desc)
    |> Ash.Query.limit(1)
    |> ash_read_first(scope)
  end

  defp load_virtualization_cluster(_scope, nil), do: nil

  defp load_virtualization_cluster(scope, cluster_id) do
    VirtualizationCluster
    |> virtualization_query(scope)
    |> Ash.Query.filter(id == ^cluster_id)
    |> Ash.Query.limit(1)
    |> ash_read_first(scope)
  end

  defp load_virtualization_datastores(scope, host_id) do
    VirtualizationDatastore
    |> virtualization_query(scope)
    |> Ash.Query.filter(host_id == ^host_id)
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.limit(24)
    |> ash_read_many(scope)
  end

  defp load_virtualization_disks(scope, host_id) do
    VirtualizationHostDisk
    |> virtualization_query(scope)
    |> Ash.Query.filter(host_id == ^host_id)
    |> Ash.Query.sort(path: :asc)
    |> Ash.Query.limit(24)
    |> ash_read_many(scope)
  end

  defp load_virtualization_network_interfaces(scope, host_id) do
    VirtualizationNetworkInterface
    |> virtualization_query(scope)
    |> Ash.Query.filter(host_id == ^host_id)
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.limit(32)
    |> ash_read_many(scope)
  end

  defp load_virtualization_network_interfaces_for_guest(scope, guest_id) do
    VirtualizationNetworkInterface
    |> virtualization_query(scope)
    |> Ash.Query.filter(guest_id == ^guest_id)
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.limit(32)
    |> ash_read_many(scope)
  end

  defp load_virtualization_storage_systems(scope, host_id) do
    VirtualizationStorageSystem
    |> virtualization_query(scope)
    |> Ash.Query.filter(host_id == ^host_id)
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.limit(16)
    |> ash_read_many(scope)
  end

  defp load_virtualization_guests_for_host(scope, host_id) do
    VirtualizationGuest
    |> virtualization_query(scope)
    |> Ash.Query.filter(host_id == ^host_id)
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.limit(100)
    |> ash_read_many(scope)
  end

  defp virtualization_query(resource, nil), do: Ash.Query.for_read(resource, :read, %{})

  defp virtualization_query(resource, scope), do: Ash.Query.for_read(resource, :read, %{}, scope: scope)

  defp ash_read_first(query, scope) do
    case ash_read_many(query, scope) do
      [first | _] -> first
      _ -> nil
    end
  end

  defp ash_read_many(query, scope) do
    result =
      if scope do
        Ash.read(query, scope: scope)
      else
        Ash.read(query)
      end

    case result do
      {:ok, rows} when is_list(rows) -> rows
      {:ok, %Ash.Page.Keyset{results: rows}} -> rows
      {:ok, %Ash.Page.Offset{results: rows}} -> rows
      _ -> []
    end
  end

  defp srql_module do
    Application.get_env(:serviceradar_web_ng, :srql_module, ServiceRadarWebNG.SRQL)
  end

  defp default_device_query(device_uid, limit) do
    "in:devices uid:\"#{escape_value(device_uid)}\" include_deleted:true limit:#{limit}"
  end

  defp default_interfaces_query(device_uid) do
    "in:interfaces device_id:\"#{escape_value(device_uid)}\" latest:true time:last_3d " <>
      "sort:if_name:asc limit:#{@interfaces_limit}"
  end

  defp default_flows_query(device_uid) do
    "in:flows device_id:\"#{escape_value(device_uid)}\" time:last_24h sort:time:desc"
  end

  defp default_logs_query(device_uid) do
    "in:logs device_id:\"#{escape_value(device_uid)}\" time:last_24h sort:timestamp:desc"
  end

  defp srql_for_tab("interfaces", device_uid, _limit, srql) when is_binary(device_uid) and device_uid != "" do
    query = default_interfaces_query(device_uid)

    srql
    |> Map.put(:entity, "interfaces")
    |> Map.put(:query, query)
    |> Map.put(:draft, query)
    |> Map.put(:error, nil)
    |> Map.put(:loading, false)
  end

  defp srql_for_tab("flows", device_uid, _limit, srql) when is_binary(device_uid) and device_uid != "" do
    query = default_flows_query(device_uid)

    srql
    |> Map.put(:entity, "flows")
    |> Map.put(:query, query)
    |> Map.put(:draft, query)
    |> Map.put(:error, nil)
    |> Map.put(:loading, false)
  end

  defp srql_for_tab("logs", device_uid, _limit, srql) when is_binary(device_uid) and device_uid != "" do
    query = default_logs_query(device_uid)

    srql
    |> Map.put(:entity, "logs")
    |> Map.put(:query, query)
    |> Map.put(:draft, query)
    |> Map.put(:error, nil)
    |> Map.put(:loading, false)
  end

  defp srql_for_tab(_tab, device_uid, limit, srql) when is_binary(device_uid) and device_uid != "" do
    query = default_device_query(device_uid, limit)

    srql
    |> Map.put(:entity, "devices")
    |> Map.put(:query, query)
    |> Map.put(:draft, query)
    |> Map.put(:error, nil)
    |> Map.put(:loading, false)
  end

  defp srql_for_tab(_tab, _device_uid, _limit, srql), do: srql

  # ---------------------------------------------------------------------------
  # MTR Traces
  # ---------------------------------------------------------------------------

  defp maybe_load_mtr_for_active_tab(socket, "mtr"), do: load_mtr_traces(socket)
  defp maybe_load_mtr_for_active_tab(socket, _active_tab), do: socket

  defp maybe_refresh_mtr_tab(socket) do
    if socket.assigns.active_tab == "mtr" do
      load_mtr_traces(socket)
    else
      socket
    end
  end

  defp refresh_mtr_if_relevant(socket, msg) when is_map(msg) do
    device_uid = socket.assigns.device_uid
    device_ip = get_device_ip(socket.assigns.results)
    msg_device_uid = mtr_msg_device_uid(msg)
    msg_target_ip = mtr_msg_target_ip(msg)

    if msg_matches_device?(msg_device_uid, device_uid) or
         msg_matches_device?(msg_target_ip, device_ip) do
      maybe_refresh_mtr_tab(socket)
    else
      socket
    end
  end

  defp refresh_mtr_if_relevant(socket, _msg), do: socket

  defp mtr_msg_device_uid(msg) do
    context = map_get_any(msg, [:context, "context"], %{})
    map_get_any(context, [:device_uid, "device_uid"], nil)
  end

  defp mtr_msg_target_ip(msg) do
    context = map_get_any(msg, [:context, "context"], %{})
    payload = map_get_any(msg, [:payload, "payload"], %{})
    trace = map_get_any(payload, [:trace, "trace"], %{})

    map_get_any(context, [:target_ip, "target_ip"], nil) ||
      map_get_any(msg, [:target, "target", :target_ip, "target_ip"], nil) ||
      map_get_any(payload, [:target, "target"], nil) ||
      map_get_any(trace, [:target_ip, "target_ip", :target, "target"], nil)
  end

  defp msg_matches_device?(candidate, expected) when is_binary(candidate) and is_binary(expected) do
    candidate = String.trim(candidate)
    expected = String.trim(expected)

    candidate != "" and candidate == expected
  end

  defp msg_matches_device?(_, _), do: false

  defp map_get_any(map, keys, default) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, default, fn key ->
      case Map.get(map, key) do
        nil -> nil
        value -> value
      end
    end)
  end

  defp map_get_any(_map, _keys, default), do: default

  defp load_mtr_traces(socket) do
    device_uid = socket.assigns.device_uid
    device_ip = get_device_ip(socket.assigns.results)

    if is_nil(device_uid) and is_nil(device_ip) do
      socket
      |> assign(:mtr_traces, [])
      |> assign(:mtr_pending_jobs, [])
      |> assign(:mtr_trends, %{hops: [], latency: []})
      |> assign(:mtr_total_count, 0)
      |> assign(:mtr_coverage, %{trace_count: 0, earliest_time: nil, latest_time: nil})
      |> assign(:mtr_retention_status, MtrData.retention_status(socket.assigns.current_scope))
    else
      page = Map.get(socket.assigns, :mtr_page, 1)
      page_size = Map.get(socket.assigns, :mtr_page_size, mtr_default_page_size())

      traces_result =
        MtrData.list_traces_paginated(
          device_uid: device_uid,
          device_ip: device_ip,
          limit: page_size,
          page: page
        )

      coverage_result = MtrData.trace_coverage(device_uid: device_uid, device_ip: device_ip)

      pending_result =
        MtrData.list_pending_jobs(socket.assigns.current_scope,
          device_uid: device_uid,
          device_ip: device_ip
        )

      traces =
        case traces_result do
          {:ok, %{rows: rows}} -> rows
          _ -> []
        end

      total_count =
        case traces_result do
          {:ok, %{total_count: total}} -> total || 0
          _ -> 0
        end

      coverage =
        case coverage_result do
          {:ok, value} -> value
          _ -> %{trace_count: total_count, earliest_time: nil, latest_time: nil}
        end

      pending_jobs =
        case pending_result do
          {:ok, rows} -> rows
          _ -> []
        end

      pending_jobs = MtrData.suppress_completed_pending_jobs(pending_jobs, traces)

      socket
      |> assign(:mtr_traces, traces)
      |> assign(:mtr_total_count, total_count)
      |> assign(:mtr_coverage, coverage)
      |> assign(:mtr_retention_status, MtrData.retention_status(socket.assigns.current_scope))
      |> assign(:mtr_pending_jobs, pending_jobs)
      |> assign(:mtr_trends, MtrData.build_trends(traces))
    end
  end

  defp detect_has_mtr(scope, device_uid, device_ip) do
    traces? =
      case MtrData.list_traces(device_uid: device_uid, device_ip: device_ip, limit: 1) do
        {:ok, [_ | _]} -> true
        _ -> false
      end

    pending? =
      case MtrData.list_pending_jobs(scope, device_uid: device_uid, device_ip: device_ip) do
        {:ok, [_ | _]} -> true
        _ -> false
      end

    traces? or pending?
  rescue
    _ -> false
  end

  defp mtr_default_page_size do
    MtrSettingsRuntime.settings()
    |> Map.get(:mtr_history_page_size_default, @mtr_device_limit)
    |> parse_limit(@mtr_device_limit, 200)
  rescue
    _ -> @mtr_device_limit
  end

  defp get_device_ip(results) do
    case List.first(Enum.filter(results, &is_map/1)) do
      nil -> nil
      row -> Map.get(row, "ip")
    end
  end

  defp load_mapper_jobs_for_device(nil, _device_row), do: []
  defp load_mapper_jobs_for_device(_scope, nil), do: []

  defp load_mapper_jobs_for_device(scope, device_row) do
    partition =
      device_row
      |> Map.get("partition", Map.get(device_row, "partition_id", "default"))
      |> to_string()
      |> String.trim()
      |> case do
        "" -> "default"
        value -> value
      end

    ip = Map.get(device_row, "ip")
    hostname = Map.get(device_row, "hostname")

    query =
      MapperJob
      |> Ash.Query.for_read(:enabled_by_partition, %{partition: partition}, scope: scope)
      |> Ash.Query.load(:seeds)

    case Ash.read(query, scope: scope) do
      {:ok, jobs} ->
        Enum.filter(jobs, &mapper_job_targets_device?(&1, ip, hostname))

      {:error, _} ->
        []
    end
  end

  defp mapper_job_targets_device?(job, ip, hostname) do
    job
    |> mapper_job_seeds()
    |> Enum.any?(&seed_matches_device?(&1, ip, hostname))
  end

  defp mapper_job_seeds(%{seeds: %Ash.NotLoaded{}}), do: []
  defp mapper_job_seeds(%{seeds: seeds}) when is_list(seeds), do: Enum.map(seeds, & &1.seed)
  defp mapper_job_seeds(_), do: []

  defp seed_matches_device?(seed, ip, hostname) when is_binary(seed) do
    trimmed = String.trim(seed)

    cond do
      trimmed == "" ->
        false

      is_binary(ip) and trimmed == ip ->
        true

      is_binary(hostname) and String.downcase(trimmed) == String.downcase(hostname) ->
        true

      is_binary(ip) and ip_in_cidr?(ip, trimmed) ->
        true

      true ->
        false
    end
  end

  defp seed_matches_device?(_, _ip, _hostname), do: false

  defp ip_in_cidr?(ip, cidr) when is_binary(ip) and is_binary(cidr) do
    with {:ok, ip_tuple} <- parse_ip(ip),
         {:ok, cidr_ip, prefix} <- parse_cidr(cidr),
         true <- tuple_size(ip_tuple) == tuple_size(cidr_ip) do
      mask_bits = prefix
      ip_int = tuple_to_int(ip_tuple)
      cidr_int = tuple_to_int(cidr_ip)

      max_bits = tuple_size(ip_tuple) * bits_per_segment(ip_tuple)
      mask = mask_for_bits(max_bits, mask_bits)

      (ip_int &&& mask) == (cidr_int &&& mask)
    else
      _ -> false
    end
  end

  defp ip_in_cidr?(_, _), do: false

  defp parse_ip(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, tuple} -> {:ok, tuple}
      _ -> :error
    end
  end

  defp parse_cidr(cidr) do
    case String.split(cidr, "/") do
      [ip, prefix_str] ->
        with {:ok, ip_tuple} <- parse_ip(ip),
             {prefix, ""} <- Integer.parse(prefix_str) do
          {:ok, ip_tuple, prefix}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp tuple_to_int(tuple) when tuple_size(tuple) == 4 do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(0, fn octet, acc -> acc * 256 + octet end)
  end

  defp tuple_to_int(tuple) when tuple_size(tuple) == 8 do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(0, fn segment, acc -> acc * 65_536 + segment end)
  end

  defp bits_per_segment(tuple) when tuple_size(tuple) == 4, do: 8
  defp bits_per_segment(tuple) when tuple_size(tuple) == 8, do: 16

  defp mask_for_bits(_max_bits, 0), do: 0

  defp mask_for_bits(max_bits, bits) when bits >= max_bits do
    (1 <<< max_bits) - 1
  end

  defp mask_for_bits(max_bits, bits) do
    ((1 <<< bits) - 1) <<< (max_bits - bits)
  end

  defp pick_discovery_job([]), do: nil

  defp pick_discovery_job(jobs) do
    Enum.max_by(jobs, &mapper_job_sort_key/1, fn -> nil end)
  end

  defp mapper_job_sort_key(%{last_run_at: %DateTime{} = dt}), do: dt

  defp mapper_job_sort_key(%{last_run_at: %NaiveDateTime{} = dt}) do
    DateTime.from_naive!(dt, "Etc/UTC")
  end

  defp mapper_job_sort_key(_), do: DateTime.from_unix!(0)

  defp load_sweep_results(_scope, nil), do: nil

  defp load_sweep_results(scope, ip) when is_binary(ip) do
    require Ash.Query

    actor = build_sweep_actor(scope)

    query =
      SweepHostResult
      |> Ash.Query.for_read(:by_ip, %{ip: ip}, actor: actor)
      |> Ash.Query.load(:execution)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(10)

    case Ash.read(query, authorize?: true) do
      {:ok, results} when results != [] ->
        %{results: results, total: length(results)}

      _ ->
        nil
    end
  end

  defp load_sweep_results(_scope, _), do: nil

  defp load_camera_sources(scope, device_uid, device_row) do
    case CameraSource.list_for_device(device_uid, load: [:stream_profiles], scope: scope) do
      {:ok, []} ->
        load_camera_sources_by_fallback(scope, device_row)

      {:ok, sources} ->
        {sources, nil}

      {:error, error} ->
        {[], "Failed to load camera inventory: #{format_ash_error(error)}"}
    end
  end

  defp load_camera_sources_by_fallback(scope, device_row) do
    fallback_ids = camera_source_fallback_ids(device_row)

    if fallback_ids == [] do
      {[], nil}
    else
      query =
        CameraSource
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(device_uid in ^fallback_ids)
        |> Ash.Query.load(:stream_profiles)
        |> Ash.Query.sort(inserted_at: :asc)

      case read_camera_sources(query, scope) do
        {:ok, sources} -> {sources, nil}
        {:error, error} -> {[], "Failed to load camera inventory: #{format_ash_error(error)}"}
      end
    end
  end

  defp read_camera_sources(query, nil), do: Ash.read(query)
  defp read_camera_sources(query, scope), do: Ash.read(query, scope: scope)

  defp camera_source_fallback_ids(device_row) do
    mac =
      case device_row do
        %{} = row -> Map.get(row, :mac) || Map.get(row, "mac")
        _ -> nil
      end

    mac
    |> List.wrap()
    |> Enum.flat_map(fn value ->
      trimmed = value |> to_string() |> String.trim()
      normalized = trimmed |> String.replace(":", "") |> String.upcase()

      [
        trimmed,
        String.upcase(trimmed),
        String.downcase(trimmed),
        normalized,
        String.downcase(normalized)
      ]
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp build_sweep_actor(scope) do
    case scope do
      %{user: user} when not is_nil(user) ->
        %{
          id: user.id,
          email: user.email,
          role: user.role
        }

      _ ->
        %{
          id: "system",
          email: "system@serviceradar",
          role: :admin
        }
    end
  end

  # ---------------------------------------------------------------------------
  # Sysmon Profile Loading
  # ---------------------------------------------------------------------------

  # Extract the user from scope to use as actor for Ash operations
  defp get_profile_actor(%{user: user}) when not is_nil(user), do: user
  defp get_profile_actor(_), do: nil

  defp load_sysmon_profile_info(scope, device_uid) do
    actor = get_profile_actor(scope)

    # Load available profiles (for reference)
    available_profiles = load_available_profiles(actor)

    # Resolve the effective profile via SRQL targeting
    profile = SysmonCompiler.resolve_profile(device_uid, actor)

    # Determine source based on profile type
    source =
      cond do
        is_nil(profile) -> "unassigned"
        not is_nil(profile.target_query) -> "srql"
        true -> "unassigned"
      end

    profile_info = %{
      profile: profile,
      source: source
    }

    {profile_info, available_profiles}
  rescue
    e ->
      require Logger

      Logger.warning("Failed to load sysmon profile info: #{inspect(e)}")
      {nil, []}
  end

  defp load_available_profiles(actor) do
    case Ash.read(SysmonProfile, action: :list_available, actor: actor) do
      {:ok, profiles} -> profiles
      {:error, _} -> []
    end
  end

  # RBAC helper - check if user can edit devices
  defp can_view_device?(scope), do: RBAC.can?(scope, "devices.view")

  defp can_view_active_fingerprint?(scope), do: RBAC.can?(scope, "networks.sweeps.banner_grab")

  defp can_edit_device?(scope), do: RBAC.can?(scope, "devices.update")

  defp can_manage_device?(scope), do: RBAC.can?(scope, "devices.update")

  defp can_console_device?(scope), do: RBAC.can?(scope, "devices.console.open")

  defp can_remote_access_device?(scope, device_row) do
    FeatureFlags.remote_access_ssh_enabled?() and ssh_capable_device?(device_row) and
      RBAC.can?(scope, "devices.remote_access.ssh.open")
  end

  defp can_remote_access_app?(scope) do
    FeatureFlags.remote_access_app_enabled?() and
      RBAC.can?(scope, "devices.remote_access.app.open")
  end

  defp can_manage_rdp_targets?(scope, device_row) do
    FeatureFlags.remote_access_desktop_rdp_enabled?() and windows_device?(device_row) and
      RBAC.can?(scope, "settings.edge.manage")
  end

  defp can_run_ansible?(scope), do: RBAC.can?(scope, "ansible.runs.launch")

  defp rdp_target_new_path(device_uid, device_row) do
    params =
      %{
        device_uid: device_uid,
        target_host: rdp_target_host(device_row),
        name: rdp_target_name(device_row),
        target_tls_server_name: rdp_target_server_name(device_row)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new()

    ~p"/settings/networks/desktop-targets/new?#{params}"
  end

  defp rdp_target_host(row) when is_map(row) do
    first_present([Map.get(row, "ip"), Map.get(row, "hostname"), Map.get(row, "name")])
  end

  defp rdp_target_host(_row), do: nil

  defp rdp_target_name(row) when is_map(row) do
    case device_display_name(row) do
      "Device" -> nil
      label -> "#{label} RDP"
    end
  end

  defp rdp_target_name(_row), do: nil

  defp rdp_target_server_name(row) when is_map(row) do
    first_present([Map.get(row, "hostname"), Map.get(row, "name")])
  end

  defp rdp_target_server_name(_row), do: nil

  defp ssh_capable_device?(nil), do: false

  defp ssh_capable_device?(device_row) when is_map(device_row) do
    values =
      device_row
      |> device_identity_values()
      |> Enum.map(&String.downcase/1)

    cond do
      Enum.any?(values, &String.contains?(&1, "windows")) ->
        false

      Enum.any?(values, &String.contains?(&1, "linux")) ->
        true

      Enum.any?(values, &String.contains?(&1, "unix")) ->
        true

      Enum.any?(values, &String.contains?(&1, "bsd")) ->
        true

      Enum.any?(values, &String.contains?(&1, "routeros")) ->
        true

      Enum.any?(values, &String.contains?(&1, "junos")) ->
        true

      Enum.any?(values, &String.contains?(&1, "ios xe")) ->
        true

      Enum.any?(values, &String.contains?(&1, "nx-os")) ->
        true

      Enum.any?(values, &String.contains?(&1, "proxmox")) ->
        true

      Enum.any?(values, &String.contains?(&1, "server")) ->
        true

      true ->
        false
    end
  end

  defp ssh_capable_device?(_device_row), do: false

  defp windows_device?(nil), do: false

  defp windows_device?(device_row) when is_map(device_row) do
    device_row
    |> device_identity_values()
    |> Enum.map(&String.downcase/1)
    |> Enum.any?(&String.contains?(&1, "windows"))
  end

  defp windows_device?(_device_row), do: false

  defp device_identity_values(device_row) when is_map(device_row) do
    Enum.flat_map(
      [
        Map.get(device_row, "type"),
        Map.get(device_row, "device_type"),
        Map.get(device_row, "os_info"),
        Map.get(device_row, "os"),
        metadata_value(device_row, "operating_system"),
        metadata_value(device_row, "os_name"),
        metadata_value(device_row, "os_type"),
        metadata_value(device_row, "platform"),
        metadata_value(device_row, "platform_name"),
        metadata_value(device_row, "sys_descr"),
        metadata_value(device_row, "snmp_description")
      ],
      &ssh_capability_strings/1
    )
  end

  defp device_identity_values(_device_row), do: []

  defp ssh_capability_strings(nil), do: []
  defp ssh_capability_strings(""), do: []
  defp ssh_capability_strings(value) when is_binary(value), do: [value]

  defp ssh_capability_strings(value) when is_map(value) do
    string_values =
      value
      |> Map.take(["name", "type", "version", "kernel_release", "edition"])
      |> Map.values()

    atom_values =
      value
      |> Map.take([:name, :type, :version, :kernel_release, :edition])
      |> Map.values()

    Enum.flat_map(string_values ++ atom_values, &ssh_capability_strings/1)
  end

  defp ssh_capability_strings(value), do: [to_string(value)]

  defp ansible_managed?(%{ansible_managed: true}), do: true
  defp ansible_managed?(%{"ansible_managed" => true}), do: true
  defp ansible_managed?(_), do: false

  defp proxmox_console_target?(%{kind: :host, host: %{provider: "proxmox"}}), do: true

  defp proxmox_console_target?(_summary), do: false

  defp proxmox_console_action_label(%{kind: :host}), do: "Open PVE shell"

  defp proxmox_console_action_label(_summary), do: "Open console"

  defp proxmox_console_path(device_uid, %{kind: :host}) do
    ~p"/devices/#{device_uid}/proxmox-console?#{[target_kind: "pve_host", console_mode: "proxmox_termproxy"]}"
  end

  defp proxmox_console_path(device_uid, _summary), do: ~p"/devices/#{device_uid}/proxmox-console"

  defp deleted_device?(row) when is_map(row) do
    value = Map.get(row, "deleted_at")
    not is_nil(value) and value != ""
  end

  defp deleted_device?(_), do: false

  defp preserve_camera_relay_session(socket, device_uid) do
    if socket.assigns.device_uid == device_uid do
      socket.assigns.active_camera_relay_session
    end
  end

  defp preserve_last_camera_relay_session(socket, device_uid) do
    if socket.assigns.device_uid == device_uid do
      socket.assigns.last_camera_relay_session
    end
  end

  defp load_device(scope, device_uid) do
    case Device.get_by_uid(device_uid, true, scope: scope) do
      {:ok, nil} -> {:error, :not_found}
      other -> other
    end
  end

  defp device_show_path(socket, device_uid) do
    tab =
      case socket.assigns.active_tab do
        :details -> nil
        "details" -> nil
        other -> to_string(other)
      end

    params =
      %{"limit" => socket.assigns.limit}
      |> maybe_put_param("q", Map.get(socket.assigns.srql || %{}, :query))
      |> maybe_put_param("tab", tab)

    ~p"/devices/#{device_uid}?#{params}"
  end

  defp maybe_put_param(params, _key, value) when value in [nil, ""], do: params
  defp maybe_put_param(params, key, value), do: Map.put(params, key, value)

  defp fetch_camera_relay_session(scope, relay_session_id) do
    fetcher =
      Application.get_env(
        :serviceradar_web_ng,
        :camera_relay_session_fetcher,
        fn session_id, ash_opts -> RelaySession.get_by_id(session_id, ash_opts) end
      )

    fetcher.(relay_session_id, scope: scope)
  end

  defp apply_camera_relay_session_update(socket, session) do
    current_session =
      socket.assigns.active_camera_relay_session || socket.assigns.last_camera_relay_session

    session = prefer_camera_relay_session(current_session, session)

    if relay_session_terminal?(session) do
      socket
      |> assign(:active_camera_relay_session, nil)
      |> assign(:last_camera_relay_session, session)
    else
      schedule_camera_relay_refresh(session.id)

      socket
      |> assign(:active_camera_relay_session, session)
      |> assign(:last_camera_relay_session, nil)
    end
  end

  defp clear_active_camera_relay_session(socket) do
    assign(socket, :active_camera_relay_session, nil)
  end

  defp prefer_camera_relay_session(current_session, incoming_session) do
    if relay_session_regresses?(current_session, incoming_session) do
      current_session
    else
      incoming_session
    end
  end

  defp relay_session_regresses?(%{id: current_id} = current_session, %{id: incoming_id} = incoming_session)
       when is_binary(current_id) and current_id == incoming_id do
    relay_status_rank(incoming_session) < relay_status_rank(current_session)
  end

  defp relay_session_regresses?(_current_session, _incoming_session), do: false

  defp relay_status_rank(%{status: status}) do
    case status do
      value when value in [:requested, "requested"] -> 0
      value when value in [:opening, "opening"] -> 1
      value when value in [:active, "active"] -> 2
      value when value in [:closing, "closing"] -> 3
      value when value in [:closed, "closed"] -> 4
      value when value in [:failed, "failed"] -> 4
      _other -> 0
    end
  end

  defp schedule_camera_relay_refresh(relay_session_id) when is_binary(relay_session_id) do
    Process.send_after(
      self(),
      {:refresh_camera_relay_session, relay_session_id},
      camera_relay_poll_interval_ms()
    )
  end

  defp schedule_camera_relay_refresh(_relay_session_id), do: :ok

  defp camera_relay_poll_interval_ms do
    case Application.get_env(
           :serviceradar_web_ng,
           :camera_relay_poll_interval_ms,
           @camera_relay_poll_interval_ms
         ) do
      value when is_integer(value) and value >= 0 -> value
      _other -> @camera_relay_poll_interval_ms
    end
  end

  defp relay_session_manager do
    Application.get_env(
      :serviceradar_web_ng,
      :camera_relay_session_manager,
      ServiceRadar.Camera.RelaySessionManager
    )
  end

  defp normalize_uuid_param(value) when is_binary(value) do
    case Ecto.UUID.cast(String.trim(value)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_uuid}
    end
  end

  defp normalize_uuid_param(_value), do: {:error, :invalid_uuid}

  defp format_camera_relay_error({:agent_offline, _agent_id}), do: "Assigned agent is offline for this camera source"

  defp format_camera_relay_error(:invalid_uuid), do: "Invalid camera relay request"
  defp format_camera_relay_error(reason) when is_binary(reason), do: reason
  defp format_camera_relay_error(reason), do: format_ash_error(reason)

  # Update device via Ash
  defp update_device(scope, device_uid, params) do
    # Parse tags from newline-separated string to map
    attrs =
      %{
        hostname: params["hostname"],
        ip: params["ip"],
        vendor_name: params["vendor_name"],
        model: params["model"],
        is_managed: parse_bool_param(params["is_managed"]),
        is_trusted: parse_bool_param(params["is_trusted"]),
        tags: parse_tags_input(params["tags"])
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    # First get the device, then update it
    case Device.get_by_uid(device_uid, false, scope: scope) do
      {:ok, device} ->
        device
        |> Ash.Changeset.for_update(:update, attrs)
        |> Ash.update(scope: scope)

      {:error, _} = error ->
        error
    end
  end

  defp parse_tags_input(nil), do: %{}
  defp parse_tags_input(""), do: %{}

  defp parse_tags_input(tags_string) when is_binary(tags_string) do
    tags_string
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
        [key] -> Map.put(acc, String.trim(key), nil)
      end
    end)
  end

  defp parse_bool_param(value) when value in [true, false], do: value
  defp parse_bool_param("true"), do: true
  defp parse_bool_param("false"), do: false
  defp parse_bool_param("on"), do: true
  defp parse_bool_param("1"), do: true
  defp parse_bool_param("0"), do: false
  defp parse_bool_param(_), do: nil

  defp agent_device?(row) when is_map(row) do
    row
    |> linked_agent_list()
    |> Enum.any?()
  end

  defp agent_device?(_), do: false

  defp linked_agent_list(row) when is_map(row) do
    row
    |> agent_list()
    |> List.wrap()
    |> Enum.filter(&is_map/1)
  end

  defp linked_agent_list(_), do: []

  defp agent_list(row) when is_map(row), do: Map.get(row, "agent_list") || Map.get(row, :agent_list) || []

  defp device_display_name(nil), do: "Device"

  defp device_display_name(row) when is_map(row) do
    hostname = Map.get(row, "hostname")
    ip = Map.get(row, "ip")

    cond do
      is_binary(hostname) and hostname != "" -> hostname
      is_binary(ip) and ip != "" -> ip
      true -> "Device"
    end
  end

  defp device_display_name(_), do: "Device"

  defp format_ash_error(%Invalid{errors: errors}) do
    Enum.map_join(errors, ", ", &format_single_ash_error/1)
  end

  defp format_ash_error(error), do: inspect(error)

  defp format_single_ash_error(%Ash.Error.Changes.InvalidAttribute{field: field, message: msg}), do: "#{field}: #{msg}"

  defp format_single_ash_error(%Ash.Error.Changes.Required{field: field}), do: "#{field} is required"

  defp format_single_ash_error(%{message: msg}) when is_binary(msg), do: msg

  defp format_single_ash_error(err), do: inspect(err)

  defp deleted_by_from_scope(%{user: user}) when is_map(user) do
    Map.get(user, :email) || Map.get(user, :id)
  end

  defp deleted_by_from_scope(_), do: nil

  defp stale_record_error?(%Invalid{errors: errors}) when is_list(errors) do
    Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
  end

  defp stale_record_error?(_), do: false

  defp restore_device(scope, device_uid) do
    with {:ok, device} <- load_device(scope, device_uid),
         {:ok, _} <- Device.restore(device, scope: scope) do
      :ok
    else
      {:error, %Invalid{} = error} ->
        if stale_record_error?(error) do
          case force_restore_device(scope, device_uid) do
            :ok -> :ok
            {:error, reason} -> {:error, reason}
          end
        else
          {:error, error}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp force_restore_device(scope, device_uid) do
    query =
      Device
      |> Ash.Query.for_read(:read, %{include_deleted: true})
      |> Ash.Query.filter(uid == ^device_uid)

    case Ash.bulk_update(query, :restore, %{},
           scope: scope,
           return_errors?: true,
           return_records?: false
         ) do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{status: :partial_success, errors: errors} ->
        {:error, List.first(errors) || :partial_failure}

      %Ash.BulkResult{status: :error, errors: errors} ->
        {:error, List.first(errors) || :bulk_update_failed}
    end
  end

  defp update_device_active_state(socket, active?) do
    scope = socket.assigns.current_scope
    device_uid = socket.assigns.device_uid

    with {:ok, device} <- load_device(scope, device_uid),
         {:ok, _updated} <- set_device_active_state(device, active?, scope) do
      message = if active?, do: "Device returned to service", else: "Device marked out of service"

      {:noreply,
       socket
       |> put_flash(:info, message)
       |> push_patch(to: device_show_path(socket, device_uid))}
    else
      {:error, reason} ->
        action = if active?, do: "return device to service", else: "mark device out of service"

        Logger.error("Device active lifecycle update failed for #{device_uid}: #{inspect(reason)}")

        {:noreply, put_flash(socket, :error, "Failed to #{action}: #{format_ash_error(reason)}")}
    end
  end

  defp set_device_active_state(device, true, scope), do: Device.mark_active(device, scope: scope)

  defp set_device_active_state(device, false, scope), do: Device.mark_inactive(device, scope: scope)
end
