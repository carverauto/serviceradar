defmodule ServiceRadarWebNG.SRQL.EntityAccess do
  @moduledoc """
  Maps SRQL `in:<entity>` to the RBAC catalog key for that UI surface.

  This is a permission-catalog gate, not Ash.Query translation and not
  row-level isolation. Unknown entities pass through to the SRQL compiler.
  Dashboards pass through to the existing Ash/scope search.
  """

  alias ServiceRadar.Identity.RBAC, as: CoreRBAC

  @dashboards MapSet.new(~w(
    dashboards dashboard authored_dashboards authored_dashboard
  ))

  # Parser aliases from rust/srql/src/parser/entity.rs plus catalog ids.
  @permission_entities %{
    "devices.view" => ~w(
      devices device device_inventory
      agents agent ocsf_agents
      addon_fleet addon_fleets addon_statuses addon_status
      gateways gateway
      interfaces interface discovered_interfaces interface_settings
      public_endpoints public_endpoint k8s_public_endpoints k8s_endpoints vip_inventory
      endpoint_inventory_scans endpoint_inventory_scan endpoint_inventory_status
      endpoint_inventory_statuses endpoint_inventory_freshness
      endpoint_packages endpoint_package endpoint_inventory_packages endpoint_inventory packages
      endpoint_package_catalog endpoint_package_catalogs endpoint_software_packages
      endpoint_software_package package_catalog package_catalogs
      device_graph devicegraph graph graph_cypher graphcypher cypher
      field_survey_sessions fieldsurvey_sessions survey_sessions
      field_survey_rasters fieldsurvey_rasters survey_coverage_rasters survey_rasters
      field_survey_artifacts fieldsurvey_artifacts survey_room_artifacts survey_artifacts
      field_survey_rf_observations fieldsurvey_rf_observations survey_rf_observations
      field_survey_pose_samples fieldsurvey_pose_samples survey_pose_samples
      field_survey_rf_pose_matches fieldsurvey_rf_pose_matches survey_rf_pose_matches
      field_survey_spectrum_observations fieldsurvey_spectrum_observations
      survey_spectrum_observations
      wifi_sites wifi_site_map wifi_map_sites
      wifi_site_snapshots wifi_snapshots
      wifi_aps wifi_access_points wifi_ap_observations
      wifi_controllers wifi_wlcs wifi_controller_observations
      wifi_radius_groups wifi_radius_group_observations
      wifi_fleet_history wifi_history
      wifi_site_references wifi_airport_references wifi_references
      virtualization_clusters virtualization_cluster hypervisor_clusters
      virtualization_hosts virtualization_host hypervisors hypervisor_hosts
      virtualization_guests virtualization_guest vms vm containers
      virtualization_datastores virtualization_datastore datastores
      virtualization_host_disks virtualization_disks host_disks
      virtualization_network_interfaces virtualization_nics hypervisor_nics
      virtualization_storage_systems storage_systems ceph
    ),
    "services.view" => ~w(
      services service
      service_availability service_availability_latest availability_services
      monitored_services monitored_service service_inventory
      slo_evaluations slo_evaluation service_slos slo
      composite_results composite_check_results composite_verdicts
    ),
    "observability.logs.view" => ~w(logs),
    "observability.metrics.view" => ~w(
      timeseries_metrics timeseries
      timeseries_metric_interface_hourly timeseries_metrics_interface_hourly
      interface_timeseries_metrics_hourly interface_metrics_hourly
      snmp_metrics snmp
      rperf_metrics rperf
      cpu_metrics cpu
      memory_metrics memory
      disk_metrics disk
      process_metrics processes
      otel_metrics metrics
      otel_metric_points metric_points
      capacity_forecasts capacity_forecast forecasts forecast
    ),
    "observability.traces.view" => ~w(
      otel_traces traces trace_spans
      otel_trace_summaries trace_summaries traces_summaries
      mtr_traces
    ),
    "observability.events.view" => ~w(
      events activity
      security_findings security_finding findings finding
      scan_activity scan_activities security_scans scanner_activity
      dns_activity dns_activities dns_security_activity powerdns pdns
      bmp_events bmp_event bmp_routing_events
    ),
    "observability.netflow.view" => ~w(
      flows flow network_activity
      attributed_flows attributed_flow flow_attributions flow_attribution
      threat_intel_matches threat_intel_match ioc_matches ioc_match
    ),
    "observability.alerts.view" => ~w(alerts alert)
  }

  @entity_permissions (for {permission, entities} <- @permission_entities,
                           entity <- entities,
                           into: %{} do
                         {entity, permission}
                       end)

  @doc """
  Returns `:ok` or `{:error, :forbidden}`.

  Unknown entities and dashboards are `:ok` so the compiler / Ash search
  remain the source of those errors.

  Pass `optional_scope: true` from `SRQL.query/2` so existing detail
  loaders that still omit scope keep working. `Api.Access` does not pass
  that option: a missing scope on the HTTP/MCP path is forbidden.
  """
  @spec authorize(term(), term(), keyword()) :: :ok | {:error, :forbidden}
  def authorize(query, scope, opts \\ [])

  def authorize(query, scope, opts) when is_binary(query) do
    case permission_for_query(query) do
      :passthrough ->
        :ok

      {:ok, permission} ->
        cond do
          CoreRBAC.Catalog.holds?(permission_set(scope), permission) -> :ok
          Keyword.get(opts, :optional_scope, false) and is_nil(scope) -> :ok
          true -> {:error, :forbidden}
        end
    end
  end

  def authorize(_query, _scope, _opts), do: :ok

  defp permission_set(%{permissions: %MapSet{} = permissions}), do: permissions

  defp permission_set(%{user: user}) when not is_nil(user) do
    CoreRBAC.permissions_for_user(user)
  end

  defp permission_set(_), do: MapSet.new()

  @spec permission_for_query(String.t()) :: {:ok, String.t()} | :passthrough
  def permission_for_query(query) when is_binary(query) do
    query
    |> extract_entity()
    |> permission_for_entity()
  end

  @spec permission_for_entity(String.t()) :: {:ok, String.t()} | :passthrough
  def permission_for_entity(entity) when is_binary(entity) do
    cond do
      MapSet.member?(@dashboards, entity) -> :passthrough
      permission = Map.get(@entity_permissions, entity) -> {:ok, permission}
      true -> :passthrough
    end
  end

  @spec extract_entity(String.t()) :: String.t()
  def extract_entity(query) when is_binary(query) do
    query = String.trim(query)

    case Regex.run(~r/^in:(\S+)/, query) do
      [_, entity] ->
        entity
        |> String.trim("\"")
        |> String.trim("'")
        |> String.downcase()

      nil ->
        query
        |> String.split(~r/[\s|]/, parts: 2)
        |> List.first()
        |> to_string()
        |> String.downcase()
    end
  end
end
