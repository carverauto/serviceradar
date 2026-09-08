defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceMountAssigns do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3, to_form: 2]

  alias ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityData
  alias ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryData
  alias ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryRuntime
  alias ServiceRadarWebNGWeb.DeviceLive.MtrRuntime

  def assign_defaults(socket, opts) when is_list(opts) do
    socket
    |> assign(:page_title, "Device")
    |> assign(:devices_return_path, "/devices")
    |> assign(:device_uid, nil)
    |> assign(:device_details_request_ref, nil)
    |> assign(:details_loading, false)
    |> assign(:device_load_mode, :full)
    |> assign(:device_refresh_last_at, nil)
    |> assign(:device_refresh_timer, nil)
    |> assign(:results, [])
    |> assign(:source_observations, [])
    |> assign(:panels, [])
    |> assign(:metric_sections, [])
    |> assign(:sysmon_presence, false)
    |> assign(:sysmon_profile_info, nil)
    |> assign(:snmp_polling_source, ServiceRadarWebNGWeb.DeviceLive.SNMPPollingSource.empty())
    |> assign(:available_profiles, [])
    |> assign(:availability, nil)
    |> assign(:agent_availability, [])
    |> assign(:composite_verdicts, [])
    |> assign(:healthcheck_summary, nil)
    |> assign(:endpoint_inventory_scan, nil)
    |> assign(:endpoint_inventory_scans, [])
    |> assign(:endpoint_inventory_packages, [])
    |> assign(:endpoint_inventory_package_total, 0)
    |> assign(:endpoint_inventory_package_page, 1)
    |> assign(:endpoint_inventory_package_page_size, EndpointInventoryData.default_page_size())
    |> assign(:endpoint_inventory_stored_package_count, 0)
    |> assign(:endpoint_inventory_artifacts, [])
    |> assign(:endpoint_inventory_vulnerability_assessments, EndpointInventoryData.empty_assessment_pages())
    |> assign(:endpoint_inventory_cpe_catalog_current, true)
    |> assign(:show_endpoint_inventory_package_modal, false)
    |> assign(:endpoint_inventory_selected_package, nil)
    |> assign(:endpoint_inventory_selected_package_assessment_details, %{
      assessments: [],
      supporting_matches: [],
      supporting_matches_total: 0,
      supporting_matches_truncated?: false
    })
    |> assign(:show_endpoint_inventory_match_modal, false)
    |> assign(:endpoint_inventory_selected_match_group, nil)
    |> assign(:endpoint_inventory_error, nil)
    |> assign(:has_software_inventory, false)
    |> assign(:endpoint_inventory_loading, false)
    |> assign(:endpoint_inventory_request_ref, nil)
    |> assign(:bumblebee_postures, [])
    |> assign(:bumblebee_findings, [])
    |> assign(:bumblebee_error, nil)
    |> assign(:has_bumblebee_exposure, false)
    |> assign(:virtualization_summary, nil)
    |> assign(:has_virtualization_guests, false)
    |> assign(:rdp_desktop_target, nil)
    |> assign(:sweep_results, nil)
    |> assign(:process_metrics, nil)
    |> assign(:process_metrics_search, "")
    |> assign(:process_metrics_page, 1)
    |> assign(:process_listeners_search, "")
    |> assign(:process_listeners_page, 1)
    |> assign(:can_view_anomaly_capacity, false)
    |> assign(:anomaly_capacity, AnomalyCapacityData.empty())
    |> assign(:anomaly_capacity_page, 1)
    |> assign(:anomaly_capacity_filters, %{"severity" => "all", "status" => "all", "sort" => "newest"})
    |> assign(:selected_anomaly_capacity_detail, nil)
    |> assign(:anomaly_capacity_detail, nil)
    |> assign(:anomaly_capacity_detail_metric_sections, [])
    |> assign(:limit, Keyword.fetch!(opts, :default_limit))
    |> assign(:flows_limit, Keyword.fetch!(opts, :flows_limit))
    |> assign(:srql, default_srql())
    |> assign(:editing, false)
    |> assign(:device_form, to_form(%{}, as: :device))
    |> assign(:device_snmp_credential, nil)
    |> assign(:snmp_credential_form, to_form(%{}, as: :snmp))
    |> assign(:network_interfaces, [])
    |> assign(:interfaces_error, nil)
    |> assign(:has_ifaces, false)
    |> assign(:interface_availability, :checking)
    |> assign(:interfaces_loading, false)
    |> assign(:interfaces_request_ref, nil)
    |> assign(:discovery_job, nil)
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
    |> assign(:interface_metrics, nil)
    |> assign(:interface_metrics_loading, false)
    |> assign(:interface_metrics_request_ref, nil)
    |> assign(:metrics_enabled_interfaces, MapSet.new())
    |> assign(:device_flows, [])
    |> assign(:flows_error, nil)
    |> assign(:rdns_map, %{})
    |> assign(:geo_iso2_map, %{})
    |> assign(:flows_pagination, %{})
    |> assign(:has_flows, false)
    |> assign(:flow_availability, :checking)
    |> assign(:flows_loading, false)
    |> assign(:flows_request_ref, nil)
    |> assign(:pagination_page, 1)
    |> assign(:device_logs, [])
    |> assign(:logs_error, nil)
    |> assign(:logs_pagination, %{})
    |> assign(:logs_loading, false)
    |> assign(:logs_request_ref, nil)
    |> assign(:logs_cursor, nil)
    |> assign(:has_logs, false)
    |> assign(:logs_limit, Keyword.fetch!(opts, :logs_limit))
    |> assign(:flow_stats, %{})
    |> assign(:flow_stats_loading, true)
    |> assign(:flow_sparkline_json, "[]")
    |> assign(:flow_proto_json, "[]")
    |> assign(:flow_chart_keys_json, "[]")
    |> assign(:flow_chart_points_json, "[]")
    |> assign(:flow_top_talkers_json, "[]")
    |> assign(:flow_top_destinations_json, "[]")
    |> assign(:flow_top_peers_json, "[]")
    |> assign(:flow_top_ports_json, "[]")
    |> assign(:flow_top_protocols_json, "[]")
    |> assign(:flow_facets, %{protocols: [], directions: [], services: []})
    |> assign(:flow_stats_request_ref, nil)
    |> assign(:flow_ip_request_ref, nil)
    |> assign(:device_metrics_request_ref, nil)
    |> assign(:metrics_loading, false)
    |> assign(:sysmon_time_range, "last_24h")
    |> assign(:sysmon_identity, nil)
    |> assign(:flow_active_facets, %{})
    |> assign(:flow_active_topn, nil)
    |> assign(:flow_zoom_range, nil)
    |> assign(:ip_aliases, [])
    |> assign(:ip_alias_error, nil)
    |> assign(:show_stale_aliases, false)
    |> assign(:mtr_traces, [])
    |> assign(:mtr_recent_traces, [])
    |> assign(:mtr_pending_jobs, [])
    |> assign(:mtr_trends, %{hops: [], latency: []})
    |> assign(:mtr_page, 1)
    |> assign(:mtr_page_size, MtrRuntime.default_page_size())
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
    |> assign(:active_tab, "details")
    |> EndpointInventoryRuntime.assign_defaults()
  end

  defp default_srql do
    %{
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
  end
end
