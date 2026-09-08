defmodule ServiceRadarWebNGWeb.DeviceLive.ShowTemplate do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.DeviceLive.AgentComponents
  import ServiceRadarWebNGWeb.DeviceLive.AllMetadataComponents
  import ServiceRadarWebNGWeb.DeviceLive.AnomalyCapacityComponents
  import ServiceRadarWebNGWeb.DeviceLive.AnsiblePanelComponents
  import ServiceRadarWebNGWeb.DeviceLive.AvailabilityComponents
  import ServiceRadarWebNGWeb.DeviceLive.BumblebeeComponents
  import ServiceRadarWebNGWeb.DeviceLive.CameraComponents
  import ServiceRadarWebNGWeb.DeviceLive.CompositeVerdictComponents
  import ServiceRadarWebNGWeb.DeviceLive.DeviceEditComponents
  import ServiceRadarWebNGWeb.DeviceLive.DeviceHeaderComponents
  import ServiceRadarWebNGWeb.DeviceLive.DevicePropertiesComponents
  import ServiceRadarWebNGWeb.DeviceLive.DeviceSummaryComponents
  import ServiceRadarWebNGWeb.DeviceLive.DeviceTabsComponents
  import ServiceRadarWebNGWeb.DeviceLive.DiscoverySourcesComponents
  import ServiceRadarWebNGWeb.DeviceLive.EndpointInventoryComponents
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

  alias ServiceRadarWebNG.RBAC
  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Table, as: TablePlugin
  alias ServiceRadarWebNGWeb.DeviceLive.DeviceStateData
  alias ServiceRadarWebNGWeb.DeviceLive.DeviceTabRuntime
  alias ServiceRadarWebNGWeb.DeviceLive.MetadataData
  alias ServiceRadarWebNGWeb.DeviceLive.QueryData
  alias ServiceRadarWebNGWeb.DeviceLive.RemoteAccessData

  def render(assigns) do
    device_row = List.first(Enum.filter(assigns.results, &is_map/1))
    rdp_desktop_target = Map.get(assigns, :rdp_desktop_target)

    assigns =
      assigns
      |> assign(:device_row, device_row)
      |> assign(:rdp_desktop_target, rdp_desktop_target)
      |> assign(:can_edit, can_edit_device?(assigns.current_scope))
      |> assign(:can_manage, can_manage_device?(assigns.current_scope))
      |> assign(:can_console, can_console_device?(assigns.current_scope))
      |> assign(:can_remote_access, RemoteAccessData.can_ssh?(assigns.current_scope, device_row))
      |> assign(:can_remote_access_app, RemoteAccessData.can_app?(assigns.current_scope))
      |> assign(
        :can_manage_rdp_targets,
        RemoteAccessData.can_manage_rdp_targets?(assigns.current_scope, device_row)
      )
      |> assign(:can_run_ansible, can_run_ansible?(assigns.current_scope))
      |> assign(
        :can_view_northbound_history,
        RBAC.can?(assigns.current_scope, "northbound.actions.view")
      )
      |> assign(:device_ansible_managed, DeviceStateData.ansible_managed?(device_row))
      |> assign(:device_deleted, DeviceStateData.deleted?(device_row))
      |> assign(
        :device_active,
        device_active_state(device_row, MetadataData.row_metadata(device_row))
      )
      |> assign(:device_display_name, DeviceStateData.display_name(device_row))
      |> assign(:agent_device, DeviceStateData.agent?(device_row))
      |> assign(
        :proxmox_console_target,
        DeviceStateData.proxmox_console_target?(Map.get(assigns, :virtualization_summary))
      )
      |> assign(
        :proxmox_console_path,
        DeviceStateData.proxmox_console_path(
          assigns.device_uid,
          Map.get(assigns, :virtualization_summary)
        )
      )
      |> assign(
        :proxmox_console_action_label,
        DeviceStateData.proxmox_console_action_label(Map.get(assigns, :virtualization_summary))
      )
      |> assign(
        :rdp_enable_path,
        RemoteAccessData.rdp_target_new_path(assigns.device_uid, device_row)
      )
      |> assign(
        :rdp_launch_path,
        if(is_map(rdp_desktop_target),
          do: RemoteAccessData.rdp_launch_path(assigns.device_uid)
        )
      )
      |> assign(
        :active_fingerprint_tab_visible,
        active_fingerprint_tab_visible?(device_row, assigns.current_scope)
      )
      |> assign(:process_listeners_tab_visible, process_listeners_tab_visible?(device_row))
      |> assign(:software_tab_visible, software_tab_visible?(device_row, assigns))
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
          rdp_launch_path={@rdp_launch_path}
          rdp_enable_path={@rdp_enable_path}
          devices_return_path={@devices_return_path}
        />

        <div class="grid grid-cols-1 gap-4">
          <div :if={is_nil(@device_row)} class="text-sm text-sr-muted p-4">
            No device row returned for this query.
          </div>

          <.device_summary_section
            :if={is_map(@device_row) and not @editing}
            device_row={@device_row}
            device_deleted={@device_deleted}
            editing={@editing}
            snmp_polling_source={@snmp_polling_source}
            timezone={@current_scope.user.timezone || "Etc/UTC"}
          />

          <.device_edit_section
            :if={is_map(@device_row) and @editing}
            device_row={@device_row}
            device_form={@device_form}
            device_snmp_credential={@device_snmp_credential}
            snmp_credential_form={@snmp_credential_form}
          />

          <.device_tabs
            :if={is_map(@device_row)}
            device_row={@device_row}
            active_tab={@active_tab}
            software_tab_visible={@software_tab_visible}
            has_virtualization_guests={@has_virtualization_guests}
            has_ifaces={@has_ifaces}
            has_flows={@has_flows}
            details_loading={@details_loading}
            interface_availability={@interface_availability}
            flow_availability={@flow_availability}
            has_logs={@has_logs}
            sysmon_presence={@sysmon_presence}
            active_fingerprint_tab_visible={@active_fingerprint_tab_visible}
            process_listeners_tab_visible={@process_listeners_tab_visible}
            has_mtr={@has_mtr}
          />

          <div :if={@active_tab == "details"}>
            <div class="grid grid-cols-1 gap-4">
              <.ocsf_info_section
                :if={is_map(@device_row)}
                device_row={@device_row}
                vulnerability_assessments={@endpoint_inventory_vulnerability_assessments}
              />

              <.discovery_sources_section
                :if={is_map(@device_row)}
                device_row={@device_row}
                source_observations={@source_observations}
                timezone={@current_scope.user.timezone || "Etc/UTC"}
              />

              <.metadata_summary_section
                :if={is_map(@device_row)}
                device_row={@device_row}
                timezone={@current_scope.user.timezone || "Etc/UTC"}
              />

              <.all_metadata_section :if={is_map(@device_row)} device_row={@device_row} />

              <.network_visibility_section
                :if={is_map(@device_row)}
                device_row={@device_row}
                timezone={@current_scope.user.timezone || "Etc/UTC"}
              />

              <.agents_section :if={is_map(@device_row)} device_row={@device_row} />

              <.ansible_operations_section
                :if={is_map(@device_row) and @device_awx_managed}
                device_uid={@device_uid}
                device_awx_managed={@device_awx_managed}
                can_view_ansible_operations={@can_view_ansible_operations}
                can_run_ansible={@can_run_ansible}
                device_deleted={@device_deleted}
                ansible_controller_id={@ansible_controller_id}
                operation_history={@ansible_operation_history}
                playbooks={@ansible_playbooks}
                launch_open={@ansible_launch_open}
                selected_playbook_id={@ansible_selected_playbook_id}
                vars={@ansible_vars}
                var_values={@ansible_var_values}
                launch_notice={@ansible_launch_notice}
                launch_ready={@ansible_launch_ready}
                launch_resolution={@ansible_launch_resolution}
                launch_readiness={@ansible_launch_readiness}
                launch_form={@ansible_launch_form}
                timezone={@current_scope.user.timezone || "Etc/UTC"}
              />

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
                timezone={@current_scope.user.timezone || "Etc/UTC"}
              />

              <.composite_verdict_section entries={@composite_verdicts} />

              <.healthcheck_section
                :if={is_map(@healthcheck_summary)}
                summary={@healthcheck_summary}
                timezone={@current_scope.user.timezone || "Etc/UTC"}
              />

              <.bumblebee_section
                :if={@has_bumblebee_exposure or is_binary(@bumblebee_error)}
                postures={@bumblebee_postures}
                findings={@bumblebee_findings}
                error={@bumblebee_error}
                has_exposure={@has_bumblebee_exposure}
                timezone={@current_scope.user.timezone || "Etc/UTC"}
              />

              <.virtualization_section
                :if={is_map(@virtualization_summary)}
                summary={@virtualization_summary}
                timezone={@current_scope.user.timezone || "Etc/UTC"}
              />

              <.sweep_status_section
                :if={is_map(@sweep_results)}
                sweep_results={@sweep_results}
                timezone={@current_scope.user.timezone || "Etc/UTC"}
              />

              <.ip_aliases_section
                :if={is_list(@ip_aliases)}
                aliases={@ip_aliases}
                show_stale={@show_stale_aliases}
                error={@ip_alias_error}
                timezone={@current_scope.user.timezone || "Etc/UTC"}
              />

              <.northbound_action_history
                :if={@can_view_northbound_history}
                title="Action History"
                subtitle="Recent actions for this device and its interfaces"
                entries={@northbound_device_history}
                error={@northbound_device_history_error}
                notice={@northbound_launch_notice}
                empty_message="No action invocations have been recorded for this device yet."
                timezone={@current_scope.user.timezone || "Etc/UTC"}
              />

              <.metric_sections_content
                sections={@metric_sections_to_render}
                device_uid={@device_uid}
                time_range={@sysmon_time_range}
                timezone={@current_scope.user.timezone}
              />

              <.process_metrics_section
                :if={@sysmon_metrics_visible and is_list(@process_metrics)}
                metrics={@process_metrics}
                search={@process_metrics_search}
                page={@process_metrics_page}
                timezone={@current_scope.user.timezone || "Etc/UTC"}
              />

              <.anomaly_capacity_section
                :if={@can_view_anomaly_capacity}
                overview={@anomaly_capacity}
                anomaly_page={@anomaly_capacity_page}
                anomaly_filters={@anomaly_capacity_filters}
                detail={@anomaly_capacity_detail}
                device_uid={@device_uid}
                device_display_name={@device_display_name}
                metric_sections={@anomaly_capacity_detail_metric_sections}
                timezone={@current_scope.user.timezone}
              />

              <%= for panel <- @panels do %>
                <%= if panel.plugin == TablePlugin and length(@results) == 1 and is_map(@device_row) do %>
                  <.device_properties_card row={@device_row} />
                <% else %>
                  <.live_component
                    module={panel.plugin}
                    id={"device-#{panel.id}"}
                    title={panel.title}
                    panel_assigns={Map.put(panel.assigns, :timezone, @current_scope.user.timezone)}
                  />
                <% end %>
              <% end %>
            </div>
          </div>

          <div :if={@active_tab == "software" and @software_tab_visible}>
            <.endpoint_inventory_section
              scan={@endpoint_inventory_scan}
              scans={@endpoint_inventory_scans}
              packages={@endpoint_inventory_packages}
              package_total={@endpoint_inventory_package_total}
              package_page={@endpoint_inventory_package_page}
              package_page_size={@endpoint_inventory_package_page_size}
              stored_package_count={@endpoint_inventory_stored_package_count}
              artifacts={@endpoint_inventory_artifacts}
              vulnerability_assessments={@endpoint_inventory_vulnerability_assessments}
              cpe_catalog_current={@endpoint_inventory_cpe_catalog_current}
              error={@endpoint_inventory_error}
              loading={@endpoint_inventory_loading}
              has_inventory={@has_software_inventory}
              show_controls={device_has_agent?(@device_row)}
              device_row={@device_row}
              query_form={@endpoint_inventory_query_form}
              cohort_form={@endpoint_inventory_cohort_form}
              package_filter_form={@endpoint_inventory_package_filter_form}
              live_query_result={@endpoint_inventory_live_query_result}
              cohort_query_result={@endpoint_inventory_cohort_query_result}
              command_notice={@endpoint_inventory_command_notice}
              command_error={@endpoint_inventory_command_error}
              query_running={@endpoint_inventory_query_running}
              force_refresh_running={@endpoint_inventory_force_refresh_running}
              cohort_running={@endpoint_inventory_cohort_running}
              timezone={@current_scope.user.timezone || "Etc/UTC"}
            />
          </div>

          <div :if={@active_tab == "guests" and @has_virtualization_guests}>
            <.virtualization_guests_tab
              summary={@virtualization_summary}
              timezone={@current_scope.user.timezone || "Etc/UTC"}
            />
          </div>

          <div :if={@active_tab == "interfaces" and (@has_ifaces or @details_loading)}>
            <.interfaces_tab_content
              interfaces={@network_interfaces}
              error={@interfaces_error}
              selected_interfaces={@selected_interfaces}
              favorited_interfaces={@favorited_interfaces}
              device_uid={@device_uid}
              timezone={@current_scope.user.timezone}
              interface_metrics={@interface_metrics}
              loading={
                DeviceTabRuntime.tab_content_loading?(
                  @interfaces_loading,
                  @details_loading,
                  @network_interfaces
                )
              }
              metrics_loading={@interface_metrics_loading}
              discovery_job={@discovery_job}
              northbound_actions={@northbound_interface_actions}
              northbound_actions_loading={@northbound_interface_actions_loading}
              can_launch_northbound={can_launch_northbound_actions?(@current_scope)}
              snmp_polling_source={@snmp_polling_source}
            />
          </div>

          <div :if={@active_tab == "flows" and (@has_flows or @details_loading)}>
            <.flows_tab_content
              timezone={@current_scope.user.timezone}
              flows={@device_flows}
              error={@flows_error}
              pagination={@flows_pagination}
              pagination_page={Map.get(assigns, :pagination_page, 1)}
              rdns_map={@rdns_map}
              geo_iso2_map={@geo_iso2_map}
              device_uid={@device_uid}
              query={QueryData.default_flows_query(@device_uid)}
              limit={@flows_limit}
              flow_stats={@flow_stats}
              loading={
                DeviceTabRuntime.tab_content_loading?(
                  @flows_loading,
                  @details_loading,
                  @device_flows
                )
              }
              flow_stats_loading={@flow_stats_loading}
              sparkline_json={@flow_sparkline_json}
              proto_json={@flow_proto_json}
              flow_chart_keys_json={@flow_chart_keys_json}
              flow_chart_points_json={@flow_chart_points_json}
              top_talkers_json={@flow_top_talkers_json}
              top_destinations_json={@flow_top_destinations_json}
              top_peers_json={@flow_top_peers_json}
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
              pagination_page={Map.get(assigns, :pagination_page, 1)}
              device_uid={@device_uid}
              query={QueryData.default_logs_query(@device_uid)}
              limit={@logs_limit}
              timezone={@current_scope.user.timezone || "Etc/UTC"}
            />
          </div>

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

          <div :if={
            @active_tab == "active-fingerprint" and can_view_active_fingerprint?(@current_scope)
          }>
            <.active_fingerprint_tab_content
              device_row={@device_row}
              timezone={@current_scope.user.timezone || "Etc/UTC"}
            />
          </div>

          <div :if={@active_tab == "process-listeners"}>
            <.process_listeners_tab_content
              device_row={@device_row}
              search={@process_listeners_search}
              page={@process_listeners_page}
              timezone={@current_scope.user.timezone || "Etc/UTC"}
            />
          </div>

          <.mtr_tab_content
            :if={@active_tab == "mtr"}
            device_uid={@device_uid}
            fallback_target={get_device_ip(@results)}
            traces={@mtr_traces}
            recent_traces={@mtr_recent_traces}
            pending_jobs={@mtr_pending_jobs}
            trends={@mtr_trends}
            total_count={@mtr_total_count}
            coverage={@mtr_coverage}
            retention_status={@mtr_retention_status}
            page={@mtr_page}
            page_size={@mtr_page_size}
            timezone={@current_scope.user.timezone || "Etc/UTC"}
          />
        </div>
      </div>

      <.mtr_trace_modal
        show={@show_mtr_trace_modal}
        trace={@selected_mtr_trace}
        hops={@selected_mtr_hops}
        timezone={@current_scope.user.timezone || "Etc/UTC"}
      />

      <.endpoint_inventory_package_modal
        show={@show_endpoint_inventory_package_modal}
        package={@endpoint_inventory_selected_package}
        assessment_details={@endpoint_inventory_selected_package_assessment_details}
        cpe_catalog_current={@endpoint_inventory_cpe_catalog_current}
        timezone={@current_scope.user.timezone || "Etc/UTC"}
      />

      <.endpoint_inventory_match_modal
        show={@show_endpoint_inventory_match_modal}
        group={@endpoint_inventory_selected_match_group}
        timezone={@current_scope.user.timezone || "Etc/UTC"}
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
        title="Run Interface Action"
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
      <span class="shrink-0 text-sr-muted">{@label}:</span>
      <span class={[
        "min-w-0 flex-1 break-words whitespace-normal text-sr-ink",
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

  defp can_edit_device?(scope), do: RBAC.can?(scope, "devices.update")
  defp can_manage_device?(scope), do: RBAC.can?(scope, "devices.update")

  defp can_console_device?(scope) do
    RBAC.can?(scope, "devices.console.open") and
      RBAC.can?(scope, "devices.console.credentials.use")
  end

  defp can_run_ansible?(scope), do: RBAC.can?(scope, "ansible.runs.launch")
  defp can_view_active_fingerprint?(scope), do: RBAC.can?(scope, "networks.sweeps.banner_grab")
  defp can_launch_northbound_actions?(scope), do: RBAC.can?(scope, "northbound.actions.launch")

  defp device_has_agent?(%{} = row) do
    case Map.get(row, "agent_id") || Map.get(row, :agent_id) do
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end
  end

  defp device_has_agent?(_row), do: false

  defp software_tab_visible?(device_row, assigns) do
    # Show the agent-only Software tab when the device actually hosts an agent (the
    # ocsf_agents linkage flag, same signal as the bolt badge) or when there is real
    # software-inventory data / an inventory error for it — never just because a device
    # row loaded (the old `is_map(device_row)` clause made this true for every device,
    # so routers like farm01/tonka01 wrongly showed the tab).
    DeviceStateData.agent?(device_row) or
      Map.get(assigns, :has_software_inventory, false) or
      is_binary(Map.get(assigns, :endpoint_inventory_error))
  end

  defp sysmon_metrics_visible?(assigns) do
    Map.get(assigns, :sysmon_presence, false)
  end

  defp get_device_ip(results) do
    case List.first(Enum.filter(results, &is_map/1)) do
      nil -> nil
      row -> Map.get(row, "ip")
    end
  end
end
