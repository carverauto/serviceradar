defmodule ServiceRadar.Cluster.CoordinatorChildren do
  @moduledoc """
  Supervisor for coordinator-only children.

  These processes must have a single active owner even when multiple `core`
  replicas are connected to the same ERTS cluster.
  """

  use Supervisor

  alias ServiceRadar.Admission.FlowLeaseSupervisor
  alias ServiceRadar.Admission.FlowSupervisor
  alias ServiceRadar.Admission.RetainedPluginLeaseSupervisor
  alias ServiceRadar.Admission.RetainedPluginSupervisor
  alias ServiceRadar.Observability.LogPromotionConsumer

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(_opts) do
    Supervisor.init(children(), strategy: :one_for_one)
  end

  @spec children() :: [Supervisor.child_spec()]
  def children do
    Enum.reject(
      [
        cluster_health_child(),
        state_monitor_child(),
        flow_admission_lease_supervisor_child(),
        retained_plugin_admission_lease_supervisor_child(),
        flow_admission_supervisor_child(),
        retained_plugin_admission_supervisor_child(),
        status_handler_child(),
        command_result_coordination_supervisor_child(),
        command_status_handler_child(),
        results_router_child(),
        health_check_runner_supervisor_child(),
        health_check_registrar_child(),
        template_seeder_child(),
        zen_rule_seeder_child(),
        zen_rule_sync_child(),
        rule_seeder_child(),
        notification_provider_seeder_child(),
        notification_template_seeder_child(),
        job_schedule_seeder_child(),
        device_cleanup_settings_seeder_child(),
        device_hostname_rdns_settings_seeder_child(),
        role_profile_seeder_child(),
        mtr_settings_seeder_child(),
        anomaly_config_seeder_child(),
        anomaly_config_runtime_child(),
        bumblebee_catalog_source_seeder_child(),
        bumblebee_addon_package_seeder_child(),
        netprobe_addon_package_seeder_child(),
        otel_collector_addon_package_seeder_child(),
        workload_identity_addon_package_seeder_child(),
        endpoint_inventory_addon_package_seeder_child(),
        anomaly_addon_profile_seeder_child(),
        advisory_feed_definition_seeder_child(),
        retired_producer_schedule_cleaner_child(),
        advisory_feed_scheduler_child(),
        sweep_schedule_reconciler_child(),
        ip_enrichment_scheduler_child(),
        geolite_mmdb_scheduler_child(),
        ipinfo_mmdb_scheduler_child(),
        netflow_enrichment_dataset_scheduler_child(),
        netflow_security_scheduler_child(),
        netflow_cache_scheduler_child(),
        endpoint_vulnerability_match_scheduler_child(),
        device_risk_assessment_scheduler_child(),
        armis_northbound_scheduler_child(),
        mtr_baseline_scheduler_child(),
        mtr_state_trigger_worker_child(),
        mtr_consensus_worker_child(),
        topology_state_scheduler_child(),
        identity_maintenance_scheduler_child(),
        ansible_lifecycle_scheduler_child(),
        ansible_callback_command_recovery_scheduler_child(),
        ansible_secure_execution_recovery_scheduler_child(),
        plugin_target_policy_scheduler_child(),
        bumblebee_catalog_scheduler_child(),
        cli_auth_scheduler_child(),
        log_promotion_consumer_child(),
        event_writer_child()
      ],
      &is_nil/1
    )
  end

  defp cluster_health_child do
    ServiceRadar.ClusterHealth
  end

  # Infrastructure staleness + config-wedge evaluator. Historically referenced as a
  # coordinator singleton (EnsureStateMonitor warns when it is absent) but never
  # actually supervised anywhere; config-apply wedge detection (#4382) depends on it
  # running, so start it here on the coordinator.
  defp state_monitor_child do
    if enabled?("STATE_MONITOR_ENABLED", :state_monitor_enabled, true) do
      {ServiceRadar.Infrastructure.StateMonitor, []}
    end
  end

  defp status_handler_child do
    if Application.get_env(:serviceradar_core, :status_handler_enabled, false) do
      ServiceRadar.StatusHandler
    end
  end

  defp flow_admission_lease_supervisor_child do
    if Application.get_env(:serviceradar_core, :status_handler_enabled, false) do
      Supervisor.child_spec(
        {Task.Supervisor, name: FlowLeaseSupervisor},
        id: FlowLeaseSupervisor
      )
    end
  end

  defp retained_plugin_admission_lease_supervisor_child do
    if Application.get_env(:serviceradar_core, :status_handler_enabled, false) do
      Supervisor.child_spec(
        {Task.Supervisor, name: RetainedPluginLeaseSupervisor},
        id: RetainedPluginLeaseSupervisor
      )
    end
  end

  defp flow_admission_supervisor_child do
    if Application.get_env(:serviceradar_core, :status_handler_enabled, false) do
      FlowSupervisor
    end
  end

  defp retained_plugin_admission_supervisor_child do
    if Application.get_env(:serviceradar_core, :status_handler_enabled, false) do
      RetainedPluginSupervisor
    end
  end

  defp command_status_handler_child do
    if Application.get_env(:serviceradar_core, :status_handler_enabled, false) do
      ServiceRadar.AgentCommands.StatusHandler
    end
  end

  defp command_result_coordination_supervisor_child do
    if Application.get_env(:serviceradar_core, :status_handler_enabled, false) do
      {Task.Supervisor,
       name: ServiceRadar.AgentCommands.ResultCoordinationTaskSupervisor, max_children: 32}
    end
  end

  defp results_router_child do
    if Application.get_env(:serviceradar_core, :status_handler_enabled, false) do
      ServiceRadar.ResultsRouter
    end
  end

  defp health_check_runner_supervisor_child do
    if enabled?("HEALTH_CHECK_RUNNER_ENABLED", :health_check_runner_enabled, true) do
      {DynamicSupervisor,
       name: ServiceRadar.Infrastructure.HealthCheckRunnerSupervisor, strategy: :one_for_one}
    end
  end

  defp health_check_registrar_child do
    if enabled?("HEALTH_CHECK_REGISTRAR_ENABLED", :health_check_registrar_enabled, true) do
      ServiceRadar.Infrastructure.HealthCheckRegistrar
    end
  end

  defp template_seeder_child do
    if enabled?(:seeders_enabled, true) do
      ServiceRadar.Observability.TemplateSeeder
    end
  end

  defp zen_rule_seeder_child do
    if enabled?(:seeders_enabled, true) do
      ServiceRadar.Observability.ZenRuleSeeder
    end
  end

  defp zen_rule_sync_child do
    ServiceRadar.Observability.ZenRuleSync
  end

  defp rule_seeder_child do
    if enabled?(:seeders_enabled, true) do
      ServiceRadar.Observability.RuleSeeder
    end
  end

  # The first-party notification provider catalog. Without it the platform ships
  # with nothing to bind a NotificationChannel to and cannot page anyone.
  defp notification_provider_seeder_child do
    if enabled?(:seeders_enabled, true) do
      ServiceRadar.Notifications.ProviderSeeder
    end
  end

  # The managed notification templates. `Notifications.Renderer` fails a dispatch
  # outright when no body template resolves for the negotiated payload format.
  defp notification_template_seeder_child do
    if enabled?(:seeders_enabled, true) do
      ServiceRadar.Notifications.TemplateSeeder
    end
  end

  defp job_schedule_seeder_child do
    if enabled?(:seeders_enabled, true) do
      ServiceRadar.Jobs.JobScheduleSeeder
    end
  end

  defp device_cleanup_settings_seeder_child do
    if enabled?(:seeders_enabled, true) do
      ServiceRadar.Inventory.DeviceCleanupSettingsSeeder
    end
  end

  defp device_hostname_rdns_settings_seeder_child do
    if enabled?(:seeders_enabled, true) do
      ServiceRadar.Inventory.DeviceHostnameRdnsSettingsSeeder
    end
  end

  defp role_profile_seeder_child do
    if enabled?(:seeders_enabled, true) do
      ServiceRadar.Identity.RoleProfileSeeder
    end
  end

  defp mtr_settings_seeder_child do
    if enabled?(:seeders_enabled, true) do
      ServiceRadar.Observability.MtrSettingsSeeder
    end
  end

  defp anomaly_config_seeder_child do
    if enabled?(:seeders_enabled, true) do
      ServiceRadar.Observability.AnomalyConfigSeeder
    end
  end

  defp anomaly_config_runtime_child do
    if enabled?(:anomaly_config_runtime_enabled, true) do
      ServiceRadar.Observability.AnomalyConfigRuntime
    end
  end

  defp bumblebee_catalog_source_seeder_child do
    if enabled?(:seeders_enabled, true) do
      ServiceRadar.Inventory.BumblebeeCatalogSourceSeeder
    end
  end

  defp bumblebee_addon_package_seeder_child do
    if enabled?(:seeders_enabled, true) do
      ServiceRadar.Plugins.BumblebeeAddonPackageSeeder
    end
  end

  defp netprobe_addon_package_seeder_child do
    if enabled?(:seeders_enabled, true) do
      ServiceRadar.Plugins.NetprobeAddonPackageSeeder
    end
  end

  defp otel_collector_addon_package_seeder_child do
    if enabled?(:seeders_enabled, true) do
      ServiceRadar.Plugins.OtelCollectorAddonPackageSeeder
    end
  end

  defp workload_identity_addon_package_seeder_child do
    if enabled?(:seeders_enabled, true) do
      ServiceRadar.Plugins.WorkloadIdentityAddonPackageSeeder
    end
  end

  defp endpoint_inventory_addon_package_seeder_child do
    if enabled?(:seeders_enabled, true) do
      ServiceRadar.Plugins.EndpointInventoryAddonPackageSeeder
    end
  end

  defp anomaly_addon_profile_seeder_child do
    if enabled?(:seeders_enabled, true) do
      ServiceRadar.Plugins.AnomalyAddonProfileSeeder
    end
  end

  defp advisory_feed_definition_seeder_child do
    if enabled?(:seeders_enabled, true) do
      ServiceRadar.Inventory.AdvisoryFeeds.FeedDefinitionSeeder
    end
  end

  defp retired_producer_schedule_cleaner_child do
    if enabled?(:seeders_enabled, true) do
      ServiceRadar.Plugins.RetiredProducerScheduleCleaner
    end
  end

  defp advisory_feed_scheduler_child do
    if enabled?("ADVISORY_FEED_SCHEDULER_ENABLED", :advisory_feed_scheduler_enabled, true) do
      ServiceRadar.Inventory.AdvisoryFeeds.FeedScheduler
    end
  end

  defp sweep_schedule_reconciler_child do
    ServiceRadar.SweepJobs.SweepScheduleReconciler
  end

  defp ip_enrichment_scheduler_child do
    if enabled?("IP_ENRICHMENT_SCHEDULER_ENABLED", :ip_enrichment_scheduler_enabled, true) do
      ServiceRadar.Observability.IpEnrichmentScheduler
    end
  end

  defp geolite_mmdb_scheduler_child do
    if enabled?("GEOLITE_MMDB_SCHEDULER_ENABLED", :geolite_mmdb_scheduler_enabled, true) do
      ServiceRadar.Observability.GeoLiteMmdbScheduler
    end
  end

  defp ipinfo_mmdb_scheduler_child do
    if enabled?("IPINFO_MMDB_SCHEDULER_ENABLED", :ipinfo_mmdb_scheduler_enabled, true) do
      ServiceRadar.Observability.IpinfoMmdbScheduler
    end
  end

  defp netflow_enrichment_dataset_scheduler_child do
    if enabled?(
         "NETFLOW_ENRICHMENT_DATASET_SCHEDULER_ENABLED",
         :netflow_enrichment_dataset_scheduler_enabled,
         true
       ) do
      ServiceRadar.Observability.NetflowEnrichmentDatasetScheduler
    end
  end

  defp netflow_security_scheduler_child do
    if enabled?("NETFLOW_SECURITY_SCHEDULER_ENABLED", :netflow_security_scheduler_enabled, true) do
      ServiceRadar.Observability.NetflowSecurityScheduler
    end
  end

  defp netflow_cache_scheduler_child do
    if enabled?("NETFLOW_CACHE_SCHEDULER_ENABLED", :netflow_cache_scheduler_enabled, true) do
      ServiceRadar.Observability.NetflowCacheScheduler
    end
  end

  defp endpoint_vulnerability_match_scheduler_child do
    if enabled?(
         "ENDPOINT_VULNERABILITY_MATCH_SCHEDULER_ENABLED",
         :endpoint_vulnerability_match_scheduler_enabled,
         true
       ) do
      ServiceRadar.Inventory.EndpointVulnerabilityMatchScheduler
    end
  end

  defp device_risk_assessment_scheduler_child do
    if enabled?(
         "DEVICE_RISK_ASSESSMENT_SCHEDULER_ENABLED",
         :device_risk_assessment_scheduler_enabled,
         true
       ) do
      ServiceRadar.Inventory.DeviceRiskAssessmentScheduler
    end
  end

  defp armis_northbound_scheduler_child do
    if enabled?("ARMIS_NORTHBOUND_SCHEDULER_ENABLED", :armis_northbound_scheduler_enabled, true) do
      ServiceRadar.Integrations.ArmisNorthboundScheduler
    end
  end

  defp mtr_baseline_scheduler_child do
    if enabled?("MTR_AUTOMATION_BASELINE_ENABLED", :mtr_automation_baseline_enabled, false) do
      ServiceRadar.Observability.MtrBaselineScheduler
    end
  end

  defp mtr_state_trigger_worker_child do
    if enabled?("MTR_AUTOMATION_TRIGGER_ENABLED", :mtr_automation_trigger_enabled, false) do
      ServiceRadar.Observability.MtrStateTriggerWorker
    end
  end

  defp mtr_consensus_worker_child do
    if enabled?("MTR_AUTOMATION_CONSENSUS_ENABLED", :mtr_automation_consensus_enabled, false) do
      ServiceRadar.Observability.MtrConsensusWorker
    end
  end

  defp topology_state_scheduler_child do
    if enabled?("TOPOLOGY_STATE_SCHEDULER_ENABLED", :topology_state_scheduler_enabled, true) do
      ServiceRadar.NetworkDiscovery.TopologyStateScheduler
    end
  end

  defp identity_maintenance_scheduler_child do
    if enabled?(
         "IDENTITY_MAINTENANCE_SCHEDULER_ENABLED",
         :identity_maintenance_scheduler_enabled,
         true
       ) do
      ServiceRadar.Inventory.IdentityMaintenanceScheduler
    end
  end

  defp ansible_lifecycle_scheduler_child do
    if enabled?("ANSIBLE_LIFECYCLE_SCHEDULER_ENABLED", :ansible_lifecycle_scheduler_enabled, true) do
      ServiceRadar.Automation.Ansible.LifecycleScheduler
    end
  end

  defp ansible_callback_command_recovery_scheduler_child do
    if enabled?(
         "ANSIBLE_CALLBACK_COMMAND_RECOVERY_ENABLED",
         :ansible_callback_command_recovery_enabled,
         true
       ) do
      ServiceRadar.Automation.Ansible.CallbackCommandRecoveryScheduler
    end
  end

  defp ansible_secure_execution_recovery_scheduler_child do
    if enabled?(
         "ANSIBLE_SECURE_EXECUTION_RECOVERY_ENABLED",
         :ansible_secure_execution_recovery_enabled,
         true
       ) do
      ServiceRadar.Automation.Ansible.SecureExecutionCommandRecoveryScheduler
    end
  end

  defp plugin_target_policy_scheduler_child do
    if enabled?(
         "PLUGIN_TARGET_POLICY_SCHEDULER_ENABLED",
         :plugin_target_policy_scheduler_enabled,
         true
       ) do
      ServiceRadar.Plugins.PluginTargetPolicyScheduler
    end
  end

  defp bumblebee_catalog_scheduler_child do
    if enabled?("BUMBLEBEE_CATALOG_REFRESH_ENABLED", :bumblebee_catalog_refresh_enabled, false) do
      ServiceRadar.Inventory.BumblebeeCatalogScheduler
    end
  end

  defp cli_auth_scheduler_child do
    if enabled?("CLI_AUTH_SCHEDULER_ENABLED", :cli_auth_scheduler_enabled, true) do
      ServiceRadar.Identity.CliAuthScheduler
    end
  end

  defp log_promotion_consumer_child do
    if LogPromotionConsumer.enabled?() do
      LogPromotionConsumer
    end
  end

  defp event_writer_child do
    if enabled?("EVENT_WRITER_ENABLED", :event_writer_enabled, false) do
      Supervisor.child_spec(ServiceRadar.EventWriter.Supervisor, restart: :temporary)
    end
  end

  defp enabled?(env_name, app_key, default) do
    case System.get_env(env_name) do
      nil -> Application.get_env(:serviceradar_core, app_key, default)
      value when is_binary(value) -> truthy_env_value?(value)
    end
  end

  defp enabled?(app_key, default) do
    Application.get_env(:serviceradar_core, app_key, default)
  end

  defp truthy_env_value?(value) when is_binary(value) do
    String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]
  end
end
