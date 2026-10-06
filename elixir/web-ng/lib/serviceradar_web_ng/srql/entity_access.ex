defmodule ServiceRadarWebNG.SRQL.EntityAccess do
  @moduledoc """
  Maps SRQL `in:<entity>` to the RBAC catalog key for that UI surface.

  This is a permission-catalog gate, not Ash.Query translation and not
  row-level isolation. An entity name this map does not know is forbidden.
  Dashboards pass through to the existing Ash/scope search.
  """

  use Boundary,
    top_level?: true,
    check: [apps: [:serviceradar_core]],
    deps: [ServiceRadar],
    exports: :all

  alias ServiceRadar.Analytics.StarRocks.Readers
  alias ServiceRadar.Identity.RBAC, as: CoreRBAC

  @dashboards MapSet.new(~w(
    dashboards dashboard authored_dashboards authored_dashboard
  ))

  # Parser aliases from rust/srql/src/parser/entity.rs plus catalog ids.
  @permission_entities %{
    "plugins.view" => ~w(plugin_fleet plugin_fleets),
    "settings.audit.view" => ~w(security_events),
    "devices.view" => ~w(
      devices device device_inventory
      agents agent ocsf_agents
      addon_fleet addon_fleets addon_statuses addon_status
      gateways gateway
      interfaces interface discovered_interfaces interface_settings
      public_endpoints public_endpoint k8s_public_endpoints k8s_endpoints vip_inventory
      camera_sources camera_source cameras camera
      endpoint_inventory_scans endpoint_inventory_scan endpoint_inventory_status
      endpoint_inventory_statuses endpoint_inventory_freshness
      endpoint_packages endpoint_package endpoint_inventory_packages endpoint_inventory packages
      endpoint_package_catalog endpoint_package_catalogs endpoint_software_packages
      endpoint_software_package package_catalog package_catalogs
      vulnerability_advisories vulnerability_advisory advisories cves
      advisory_coordinates advisory_cpes cpe_coordinates
      endpoint_vulnerability_assessments endpoint_vulnerability_assessment
      package_vulnerabilities endpoint_vulnerability_matches vulnerability_matches
      cve_matches advisory_matches
      device_graph devicegraph graph graph_dql graph_cypher graphcypher cypher
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
      merge_audit device_merges merges
      device_revival_audit device_revivals revivals
      device_identifiers identifiers device_identity
      source_fact_disagreements source_fact_disagreement fact_disagreements
      identity_reconciliation_runs reconciliation_runs dire_runs
      identity_evidence_edges identity_evidence evidence_edges
      identity_decisions identity_decision dire_decisions
      deduplication_tasks deduplication_task dedup_tasks identity_deduplication_tasks
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
      timeseries_metric_disk_hourly timeseries_metrics_disk_hourly
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
      mtr_hops mtr_hop_stats
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
    "observability.alerts.view" => ~w(alerts alert),
    "networks.sweeps.view" => ~w(
      sweep_groups sweep_group sweeps
      sweep_profiles sweep_profile scanner_profiles scanner_profile
      sweep_executions sweep_execution sweep_group_executions
      sweep_results sweep_result sweep_host_results
      sweep_coverage sweep_coverage_daily
      device_sweep_overlap sweep_overlap
    )
  }

  @entity_permissions (for {permission, entities} <- @permission_entities,
                           entity <- entities,
                           into: %{} do
                         {entity, permission}
                       end)

  # `in:otel_services` reads one catalog that covers three signals, so it is
  # the one entity gated by an ANY-of set instead of a single permission. The
  # caller must hold at least one; the signals it holds become the permitted
  # set that SRQL intersects `signal:` with. The gate never edits the query
  # string: the SRQL planner is the only parser of `signal:` (it lowercases
  # keys and accepts list forms, which a second parser here could disagree on).
  @signal_scoped_entities %{
    "otel_services" => [
      {"logs", "observability.logs.view"},
      {"traces", "observability.traces.view"},
      {"metrics", "observability.metrics.view"}
    ]
  }

  @typedoc """
  Signals a signal-scoped entity may read, as passed to
  `ServiceRadarWebNG.SRQL.Native.translate/6`. `nil` means "no set": the
  entity is not signal-scoped, or the caller has no scope at all -- and SRQL
  fails a signal-scoped query closed when it receives `nil`.
  """
  @type permitted_signals :: nil | [String.t()]

  @doc """
  Returns `:ok` or `{:error, :forbidden}`.

  A pure gate for callers that only need a yes/no answer. Callers that go on
  to translate the query MUST use `authorize_signals/3` instead and hand its
  permitted set to translate; the set cannot be recovered from `:ok`.

  Dashboards are `:ok` so the Ash search remains the source of those
  errors. An entity name this catalog does not know is forbidden on the
  UI, HTTP, and MCP paths.

  A missing scope on a mapped entity is forbidden by default. LiveView,
  HTTP, and MCP execution paths use this default and pass the principal
  explicitly. The helper's `optional_scope: true` option permits a nil
  scope, but is not used by those execution paths.
  """
  @spec authorize(term(), term(), keyword()) :: :ok | {:error, :forbidden}
  def authorize(query, scope, opts \\ []) do
    case authorize_signals(query, scope, opts) do
      {:ok, _permitted_signals} -> :ok
      {:error, :forbidden} = denied -> denied
    end
  end

  @doc """
  Like `authorize/3`, but also returns the permitted signal set.

  `{:ok, nil}` for every entity that is not signal-scoped. For
  `otel_services` it is `{:ok, signals}` with the subset of `logs`, `traces`,
  `metrics` the caller may view, or `{:error, :forbidden}` when the caller
  holds none of them. A nil scope admitted by `optional_scope: true` gets
  `{:ok, nil}` -- no set -- so SRQL rejects an `otel_services` query from it.
  """
  @spec authorize_signals(term(), term(), keyword()) ::
          {:ok, permitted_signals()} | {:error, :forbidden}
  def authorize_signals(query, scope, opts \\ [])

  def authorize_signals(query, scope, opts) when is_binary(query) do
    optional_nil_scope? = Keyword.get(opts, :optional_scope, false) and is_nil(scope)

    case permission_for_query(query) do
      :passthrough ->
        {:ok, nil}

      :unknown ->
        {:error, :forbidden}

      {:ok, permission} ->
        cond do
          CoreRBAC.Catalog.holds?(permission_set(scope), permission) -> {:ok, nil}
          optional_nil_scope? -> {:ok, nil}
          true -> {:error, :forbidden}
        end

      {:any_of, signal_permissions} ->
        case held_signals(signal_permissions, permission_set(scope)) do
          [] when optional_nil_scope? -> {:ok, nil}
          [] -> {:error, :forbidden}
          signals -> {:ok, signals}
        end
    end
  end

  def authorize_signals(_query, _scope, _opts), do: {:ok, nil}

  defp held_signals(signal_permissions, held) do
    for {signal, permission} <- signal_permissions,
        CoreRBAC.Catalog.holds?(held, permission),
        do: signal
  end

  defp permission_set(%{permissions: %MapSet{} = permissions}), do: permissions

  defp permission_set(%{user: user}) when not is_nil(user) do
    CoreRBAC.permissions_for_user(user)
  end

  defp permission_set(_), do: MapSet.new()

  @typedoc "An entity's gate: one permission, an any-of signal set, or none."
  @type entity_permission ::
          {:ok, String.t()} | {:any_of, [{String.t(), String.t()}]} | :passthrough | :unknown

  @spec permission_for_query(String.t()) :: entity_permission()
  def permission_for_query(query) when is_binary(query) do
    query
    |> extract_entity()
    |> permission_for_entity()
  end

  @spec permission_for_entity(String.t()) :: entity_permission()
  def permission_for_entity(entity) when is_binary(entity) do
    cond do
      MapSet.member?(@dashboards, entity) ->
        :passthrough

      signal_permissions = Map.get(@signal_scoped_entities, entity) ->
        {:any_of, signal_permissions}

      permission = Map.get(@entity_permissions, entity) ->
        {:ok, permission}

      true ->
        :unknown
    end
  end

  # Mirrors rust/srql/src/parser.rs, which tokenizes on whitespace, lowercases
  # each token's key before matching it against "in", and assigns
  # `entity = Some(parse_entity(...))` unconditionally on every `in` token it
  # sees -- so the LAST `in:` token in the raw string is what the compiler
  # actually executes, regardless of case. The gate must resolve the same
  # token or it authorizes an entity different from the one that runs.
  @spec extract_entity(String.t()) :: String.t()
  def extract_entity(query) when is_binary(query) do
    case Readers.entity_for_query(query) do
      nil -> fallback_entity(query)
      entity -> entity
    end
  end

  defp fallback_entity(query) do
    query
    |> String.trim()
    |> String.split(~r/[\s|]/, parts: 2)
    |> List.first()
    |> to_string()
    |> String.downcase()
  end
end
