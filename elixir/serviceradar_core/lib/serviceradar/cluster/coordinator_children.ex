defmodule ServiceRadar.Cluster.CoordinatorChildren do
  @moduledoc """
  Supervisor for coordinator-only children.

  These processes must have a single active owner even when multiple `core`
  replicas are connected to the same ERTS cluster.
  """

  use Supervisor

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
        status_handler_child(),
        command_status_handler_child(),
        results_router_child(),
        health_check_runner_supervisor_child(),
        health_check_registrar_child(),
        template_seeder_child(),
        zen_rule_seeder_child(),
        zen_rule_sync_child(),
        rule_seeder_child(),
        job_schedule_seeder_child(),
        device_cleanup_settings_seeder_child(),
        snmp_profile_seeder_child(),
        role_profile_seeder_child(),
        sweep_schedule_reconciler_child(),
        ip_enrichment_scheduler_child(),
        geolite_mmdb_scheduler_child(),
        ipinfo_mmdb_scheduler_child(),
        netflow_enrichment_dataset_scheduler_child(),
        netflow_security_scheduler_child(),
        netflow_cache_scheduler_child(),
        armis_northbound_scheduler_child(),
        mtr_baseline_scheduler_child(),
        mtr_state_trigger_worker_child(),
        mtr_consensus_worker_child(),
        topology_state_scheduler_child(),
        plugin_target_policy_scheduler_child(),
        log_promotion_consumer_child(),
        event_writer_child()
      ],
      &is_nil/1
    )
  end

  defp cluster_health_child do
    ServiceRadar.ClusterHealth
  end

  defp status_handler_child do
    if Application.get_env(:serviceradar_core, :status_handler_enabled, false) do
      ServiceRadar.StatusHandler
    end
  end

  defp command_status_handler_child do
    if Application.get_env(:serviceradar_core, :status_handler_enabled, false) do
      ServiceRadar.AgentCommands.StatusHandler
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

  defp snmp_profile_seeder_child do
    if enabled?(:seeders_enabled, true) do
      ServiceRadar.SNMPProfiles.SNMPProfileSeeder
    end
  end

  defp role_profile_seeder_child do
    if enabled?(:seeders_enabled, true) do
      ServiceRadar.Identity.RoleProfileSeeder
    end
  end

  defp sweep_schedule_reconciler_child do
    ServiceRadar.SweepJobs.SweepScheduleReconciler
  end

  defp ip_enrichment_scheduler_child do
    ServiceRadar.Observability.IpEnrichmentScheduler
  end

  defp geolite_mmdb_scheduler_child do
    ServiceRadar.Observability.GeoLiteMmdbScheduler
  end

  defp ipinfo_mmdb_scheduler_child do
    ServiceRadar.Observability.IpinfoMmdbScheduler
  end

  defp netflow_enrichment_dataset_scheduler_child do
    ServiceRadar.Observability.NetflowEnrichmentDatasetScheduler
  end

  defp netflow_security_scheduler_child do
    ServiceRadar.Observability.NetflowSecurityScheduler
  end

  defp netflow_cache_scheduler_child do
    ServiceRadar.Observability.NetflowCacheScheduler
  end

  defp armis_northbound_scheduler_child do
    ServiceRadar.Integrations.ArmisNorthboundScheduler
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
    ServiceRadar.NetworkDiscovery.TopologyStateScheduler
  end

  defp plugin_target_policy_scheduler_child do
    ServiceRadar.Plugins.PluginTargetPolicyScheduler
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
