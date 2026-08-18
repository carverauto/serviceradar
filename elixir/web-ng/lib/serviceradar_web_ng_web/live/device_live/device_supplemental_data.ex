defmodule ServiceRadarWebNGWeb.DeviceLive.DeviceSupplementalData do
  @moduledoc false

  import ServiceRadarWebNGWeb.DeviceLive.VirtualizationComponents,
    only: [virtualization_guests?: 1]

  alias ServiceRadarWebNGWeb.DeviceLive.AvailabilityData
  alias ServiceRadarWebNGWeb.DeviceLive.BumblebeeData
  alias ServiceRadarWebNGWeb.DeviceLive.CompositeVerdictData
  alias ServiceRadarWebNGWeb.DeviceLive.DeviceTaskData
  alias ServiceRadarWebNGWeb.DeviceLive.DiscoveryData
  alias ServiceRadarWebNGWeb.DeviceLive.FlowData
  alias ServiceRadarWebNGWeb.DeviceLive.InterfaceData
  alias ServiceRadarWebNGWeb.DeviceLive.IpAliasData
  alias ServiceRadarWebNGWeb.DeviceLive.MtrRuntime
  alias ServiceRadarWebNGWeb.DeviceLive.NorthboundHistoryData
  alias ServiceRadarWebNGWeb.DeviceLive.QueryData
  alias ServiceRadarWebNGWeb.DeviceLive.SNMPPollingSource
  alias ServiceRadarWebNGWeb.DeviceLive.SourceObservationData
  alias ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics
  alias ServiceRadarWebNGWeb.DeviceLive.SysmonProfileData

  def load(context, opts) when is_map(context) and is_list(opts) do
    # current_scope drives the sweep-results lookup. It is passed explicitly so
    # this batch can run inside an off-process async task without capturing the
    # whole socket struct.
    current_scope = Map.fetch!(context, :current_scope)
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
    slow_device_task_ms = Keyword.fetch!(opts, :slow_device_task_ms)
    flows_limit = Keyword.fetch!(opts, :flows_limit)
    logs_limit = Keyword.fetch!(opts, :logs_limit)

    supplemental_timeout_ms =
      Map.get(context, :supplemental_timeout_ms, Keyword.fetch!(opts, :supplemental_timeout_ms))

    camera_sources = Map.get(context, :camera_sources, [])
    camera_inventory_error = Map.get(context, :camera_inventory_error)

    load_interfaces_data? = requested_tab == "interfaces"
    load_flows_data? = requested_tab == "flows"
    load_logs_data? = load_logs_synchronously?(requested_tab)
    sysmon_identity = SysmonMetrics.sysmon_identity(device_row, uid)

    parallel_tasks =
      build_parallel_tasks(%{
        current_scope: current_scope,
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
        load_logs_data?: load_logs_data?,
        slow_device_task_ms: slow_device_task_ms,
        flows_limit: flows_limit,
        logs_limit: logs_limit
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
          DeviceTaskData.timed(slow_device_task_ms, :metrics, fn ->
            SysmonMetrics.load_metric_sections(srql_module, sysmon_filters, scope)
          end),
          DeviceTaskData.timed(slow_device_task_ms, :process, fn ->
            SysmonMetrics.load_process_metrics(srql_module, sysmon_filters, scope)
          end)
        ]
      else
        []
      end

    parallel_results =
      DeviceTaskData.yield_many(parallel_tasks ++ metric_tasks, supplemental_timeout_ms)

    {network_interfaces, interfaces_error} =
      extract_interface_results(parallel_results, load_interfaces_data?)

    {device_flows, flows_pagination, flows_error} =
      extract_flow_results(parallel_results, load_flows_data?)

    {device_logs, logs_pagination, logs_error} =
      extract_log_results(parallel_results, load_logs_data?)

    discovery_jobs = Map.get(parallel_results, :mapper, [])
    discovery_job = DiscoveryData.pick_discovery_job(discovery_jobs)
    has_discovery_job = not is_nil(discovery_job)

    network_interfaces =
      InterfaceData.filter_interfaces_for_display(network_interfaces, device_row)

    interface_settings = extract_interface_settings(parallel_results, load_interfaces_data?)
    favorited_interfaces = interface_settings.favorited
    metrics_enabled_interfaces = interface_settings.metrics_enabled

    network_interfaces =
      InterfaceData.apply_interface_settings(network_interfaces, interface_settings.by_uid)

    interface_availability =
      determine_interface_availability(
        parallel_results,
        load_interfaces_data?,
        interfaces_error,
        network_interfaces,
        has_discovery_job
      )

    flow_availability =
      determine_flow_availability(
        parallel_results,
        load_flows_data?,
        flows_error,
        device_flows
      )

    interfaces_error =
      inconclusive_error(
        interfaces_error,
        interface_availability,
        load_interfaces_data?,
        "Interface inventory timed out. Retry this tab."
      )

    flows_error =
      inconclusive_error(
        flows_error,
        flow_availability,
        load_flows_data?,
        "Recent flow inventory timed out. Retry this tab."
      )

    has_logs =
      determine_has_logs(
        load_logs_data?,
        logs_error,
        device_logs,
        Map.get(parallel_results, :has_logs, false)
      )

    # Detection ran inside the concurrent task batch above (key :has_mtr); if the
    # task timed out we conservatively report no MTR availability.
    has_mtr = Map.get(parallel_results, :has_mtr, false)

    {sysmon_profile_info, available_profiles} = Map.get(parallel_results, :profile, {nil, []})
    {ip_aliases, ip_alias_error} = Map.get(parallel_results, :aliases, {[], nil})

    {northbound_device_history, northbound_device_history_error} =
      Map.get(parallel_results, :northbound_history, {[], nil})

    bumblebee = Map.get(parallel_results, :bumblebee, %{})

    base_assigns = %{
      availability: Map.get(parallel_results, :availability, %{}),
      agent_availability: Map.get(parallel_results, :agent_availability, []),
      composite_verdicts: Map.get(parallel_results, :composite_verdicts, []),
      healthcheck_summary: Map.get(parallel_results, :healthcheck, %{}),
      bumblebee_postures: Map.get(bumblebee, :postures, []),
      bumblebee_findings: Map.get(bumblebee, :findings, []),
      bumblebee_error: Map.get(bumblebee, :error),
      has_bumblebee_exposure: Map.get(bumblebee, :has_exposure, false),
      virtualization_summary: virtualization_summary,
      has_virtualization_guests: virtualization_guests?(virtualization_summary),
      sweep_results: Map.get(parallel_results, :sweep, []),
      source_observations: Map.get(parallel_results, :source_observations, []),
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
      metrics_enabled_interfaces: metrics_enabled_interfaces,
      ip_aliases: ip_aliases,
      ip_alias_error: ip_alias_error,
      northbound_device_history: northbound_device_history,
      northbound_device_history_error: northbound_device_history_error,
      interface_availability: interface_availability,
      flow_availability: flow_availability,
      has_ifaces: interface_availability != :unavailable,
      has_flows: flow_availability != :unavailable,
      has_logs: has_logs,
      has_mtr: has_mtr,
      snmp_polling_source: Map.get(parallel_results, :snmp_polling, SNMPPollingSource.empty())
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

  defp build_parallel_tasks(%{
         current_scope: current_scope,
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
         load_logs_data?: load_logs_data?,
         slow_device_task_ms: slow_device_task_ms,
         flows_limit: flows_limit,
         logs_limit: logs_limit
       }) do
    base_tasks = [
      DeviceTaskData.timed(slow_device_task_ms, :availability, fn ->
        AvailabilityData.load_availability(srql_module, uid, scope)
      end),
      DeviceTaskData.timed(slow_device_task_ms, :agent_availability, fn ->
        AvailabilityData.load_agent_availability(scope, uid)
      end),
      DeviceTaskData.timed(slow_device_task_ms, :composite_verdicts, fn ->
        CompositeVerdictData.load(uid, scope: scope)
      end),
      DeviceTaskData.timed(slow_device_task_ms, :healthcheck, fn ->
        AvailabilityData.load_healthcheck_summary(srql_module, uid, scope)
      end),
      DeviceTaskData.timed(slow_device_task_ms, :sweep, fn ->
        DiscoveryData.load_sweep_results(current_scope, device_ip)
      end),
      DeviceTaskData.timed(slow_device_task_ms, :source_observations, fn ->
        SourceObservationData.load(current_scope, uid)
      end),
      DeviceTaskData.timed(slow_device_task_ms, :mapper, fn ->
        DiscoveryData.load_mapper_jobs_for_device(scope, device_row)
      end),
      DeviceTaskData.timed(slow_device_task_ms, :aliases, fn ->
        IpAliasData.load(scope, uid, show_stale)
      end),
      DeviceTaskData.timed(slow_device_task_ms, :northbound_history, fn ->
        NorthboundHistoryData.load(scope, uid)
      end),
      # Endpoint inventory (packages + vulnerability matches) is started from
      # DeviceLive.Show as its own start_async. Folding it into this yield_many
      # made Software wait on has_ifaces/has_flows SRQL probes.
      DeviceTaskData.timed(slow_device_task_ms, :bumblebee, fn ->
        BumblebeeData.load(scope, uid)
      end),
      # Folded into the concurrent batch so it overlaps the other supplemental
      # loads instead of running serially after Task.yield_many.
      DeviceTaskData.timed(slow_device_task_ms, :has_mtr, fn ->
        MtrRuntime.detect_available(scope, uid, device_ip)
      end),
      DeviceTaskData.timed(slow_device_task_ms, :snmp_polling, fn ->
        SNMPPollingSource.load(scope, uid)
      end)
    ]

    base_tasks
    |> maybe_add_profile_task(requested_tab, uid, scope, slow_device_task_ms)
    |> maybe_add_interface_tasks(
      load_interfaces_data?,
      srql_module,
      uid,
      scope,
      slow_device_task_ms
    )
    |> maybe_add_flow_tasks(
      load_flows_data?,
      srql_module,
      uid,
      scope,
      params,
      slow_device_task_ms,
      flows_limit
    )
    |> maybe_add_log_tasks(
      load_logs_data?,
      srql_module,
      uid,
      scope,
      params,
      slow_device_task_ms,
      logs_limit
    )
  end

  defp maybe_add_profile_task(tasks, "profiles", uid, scope, slow_device_task_ms) do
    tasks ++
      [
        DeviceTaskData.timed(slow_device_task_ms, :profile, fn ->
          SysmonProfileData.load_profile_info(scope, uid)
        end)
      ]
  end

  defp maybe_add_profile_task(tasks, _active_tab, _uid, _scope, _slow_device_task_ms), do: tasks

  defp maybe_add_interface_tasks(tasks, true, srql_module, uid, scope, slow_device_task_ms) do
    tasks ++
      [
        DeviceTaskData.timed(slow_device_task_ms, :interfaces, fn ->
          InterfaceData.load_interfaces(srql_module, uid, scope)
        end),
        DeviceTaskData.timed(slow_device_task_ms, :iface_settings, fn ->
          InterfaceData.load_interface_settings(scope, uid)
        end)
      ]
  end

  defp maybe_add_interface_tasks(tasks, false, srql_module, uid, scope, slow_device_task_ms) do
    tasks ++
      [
        DeviceTaskData.timed(slow_device_task_ms, :has_ifaces, fn ->
          InterfaceData.has_interfaces?(srql_module, uid, scope)
        end)
      ]
  end

  defp maybe_add_flow_tasks(tasks, true, srql_module, uid, scope, params, slow_device_task_ms, flows_limit) do
    tasks ++
      [
        DeviceTaskData.timed(slow_device_task_ms, :flows, fn ->
          FlowData.load_flows(
            srql_module,
            uid,
            scope,
            QueryData.normalize_cursor(Map.get(params, "cursor")),
            flows_limit
          )
        end)
      ]
  end

  defp maybe_add_flow_tasks(tasks, false, srql_module, uid, scope, _params, slow_device_task_ms, _flows_limit) do
    tasks ++
      [
        DeviceTaskData.timed(slow_device_task_ms, :has_flows, fn ->
          detect_has_flows(srql_module, uid, scope)
        end)
      ]
  end

  defp maybe_add_log_tasks(tasks, true, srql_module, uid, scope, params, slow_device_task_ms, logs_limit) do
    tasks ++
      [
        DeviceTaskData.timed(slow_device_task_ms, :logs, fn ->
          QueryData.load_logs(
            srql_module,
            uid,
            scope,
            QueryData.normalize_cursor(Map.get(params, "cursor")),
            logs_limit
          )
        end)
      ]
  end

  defp maybe_add_log_tasks(tasks, false, _srql_module, _uid, _scope, _params, _slow_device_task_ms, _logs_limit),
    do: tasks

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
    InterfaceData.empty_interface_settings()
  end

  defp determine_interface_availability(parallel_results, true, interfaces_error, network_interfaces, has_discovery_job) do
    cond do
      has_discovery_job -> :available
      not Map.has_key?(parallel_results, :interfaces) -> :unknown
      is_binary(interfaces_error) -> :unknown
      is_list(network_interfaces) and network_interfaces != [] -> :available
      not Map.has_key?(parallel_results, :mapper) -> :unknown
      true -> :unavailable
    end
  end

  defp determine_interface_availability(
         parallel_results,
         false,
         _interfaces_error,
         _network_interfaces,
         has_discovery_job
       ) do
    cond do
      has_discovery_job -> :available
      not Map.has_key?(parallel_results, :has_ifaces) -> :unknown
      Map.get(parallel_results, :has_ifaces) -> :available
      not Map.has_key?(parallel_results, :mapper) -> :unknown
      true -> :unavailable
    end
  end

  defp determine_flow_availability(parallel_results, true, flows_error, device_flows) do
    cond do
      not Map.has_key?(parallel_results, :flows) -> :unknown
      is_binary(flows_error) -> :unknown
      is_list(device_flows) and device_flows != [] -> :available
      true -> :unavailable
    end
  end

  defp determine_flow_availability(parallel_results, false, _flows_error, _device_flows) do
    cond do
      not Map.has_key?(parallel_results, :has_flows) -> :unknown
      Map.get(parallel_results, :has_flows) -> :available
      true -> :unavailable
    end
  end

  defp inconclusive_error(nil, :unknown, true, message), do: message
  defp inconclusive_error(error, _availability, _loaded?, _message), do: error

  defp determine_has_logs(true, logs_error, device_logs, _probe) do
    is_binary(logs_error) or is_list(device_logs)
  end

  defp determine_has_logs(false, _logs_error, _device_logs, _probe), do: true

  defp detect_has_flows(srql_module, device_uid, scope) do
    query = QueryData.default_flows_query(device_uid) <> " limit:1"

    case srql_module.query(query, %{scope: scope}) do
      {:ok, %{"results" => [_ | _]}} -> true
      _ -> false
    end
  end
end
