defmodule ServiceRadar.Application do
  @moduledoc """
  ServiceRadar Core Application.

  Starts the core supervision tree including:
  - Database connection pool (Repo)
  - Oban job processor
  - Cluster supervisor (libcluster + Horde)
  - ProcessRegistry (singleton Horde registry + DynamicSupervisor)

  ## Instance Isolation

  Each instance runs its own ERTS cluster with isolated resources.
  Isolation is handled by infrastructure (separate deployments, databases,
  NATS credentials).

  ProcessRegistry provides a singleton Horde registry for cross-node
  process discovery within a single instance.

  This application can run standalone or as a dependency of
  serviceradar_web or serviceradar_agent_gateway.

  ## Configuration

  - `:repo_enabled` - Whether to start the database connection pool (default: true)
    - core-elx: true (central coordinator with DB access)
    - web-ng: true (web frontend with DB access)
    - agent-gateway: false (edge component, no direct DB access)
  - `:oban_enabled` - Whether to start Oban job processor (default: true)
  - `:cluster_enabled` - Whether ERTS distribution is enabled (default: false)
  - `:cluster_coordinator` - Whether to run ClusterSupervisor/ClusterHealth (default: same as cluster_enabled)
    - core-elx: true (it's the coordinator)
    - web-ng, agent-gateway: false (they join cluster but don't coordinate)
  - `:registries_enabled` - Whether to start ProcessRegistry (default: true)
  - `:start_ash_oban_scheduler` - Whether to start AshOban schedulers (default: false)
    - Only core-elx should set this to true
  - `:status_handler_enabled` - Whether to start StatusHandler for agent push results (default: false)
    - core-elx: true (handles agent-gateway status updates)
    - web-ng: false (doesn't process agent updates)

  ## DB Access Boundaries

  Only core-elx and web-ng have direct database access. Edge components (gateways, agents)
  communicate with the database via:
  1. Horde registries for process discovery (synced via ERTS)
  2. gRPC calls to core-elx for data operations
  3. NATS JetStream for event streaming

  This ensures edge components remain stateless and can be deployed in untrusted networks.
  """
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    ensure_started(:telemetry)
    ensure_started(:ash_state_machine)
    ensure_started(:ssl)

    children =
      [
        # Encryption vault for AshCloak (must start before repo for encrypted field access)
        vault_child(),

        # Database (can be disabled for standalone tests)
        repo_child(),

        # Startup migrations (core-elx only, after repo)
        startup_migrations_child(),

        # PubSub for cluster events (always needed)
        {Phoenix.PubSub, name: ServiceRadar.PubSub},

        # Local registry for process lookups (gateways, agents)
        {Registry, keys: :unique, name: ServiceRadar.LocalRegistry},

        # Oban job processor (can be disabled for standalone tests)
        oban_child(),

        # Sweep scheduling reconciliation (safe when Oban is unavailable)
        sweep_schedule_reconciler_child(),

        # AshOban schedulers for Ash resource triggers
        ash_oban_scheduler_children(),

        # GRPC client supervisor (required for DataService.Client)
        grpc_client_supervisor_child(),
        datasvc_client_child(),

        # NATS JetStream connection supervisor (fault-tolerant with auto-reconnect)
        nats_connection_child(),

        # Event batcher for high-frequency NATS events
        event_batcher_child(),

        # Task supervisor for sync ingestion work
        sync_ingestor_task_supervisor_child(),

        # Sync ingestion queue/coalescer
        sync_ingestor_queue_child(),

        # Results router for agent-gateway push results
        results_router_child(),

        # Status handler (legacy) for agent-gateway push results
        status_handler_child(),

        # Agent command status handler (persists command lifecycle updates)
        command_status_handler_child(),

        # Health check runner supervisor (high-frequency gRPC checks)
        health_check_runner_supervisor_child(),

        # Health check registrar (subscribes to agent events, auto-registers services)
        health_check_registrar_child(),

        # Horde registries (always started for registration support)
        registry_children(),

        # Template seeding for rule builder defaults
        template_seeder_child(),

        # Zen rule defaults for deployment onboarding
        zen_rule_seeder_child(),

        # Zen rule reconciliation to datasvc KV
        zen_rule_sync_child(),

        # Log promotion and stateful alert rule defaults
        rule_seeder_child(),

        # Job schedule defaults
        job_schedule_seeder_child(),

        # Device cleanup settings defaults
        device_cleanup_settings_seeder_child(),

        # Default SNMP profile seed
        snmp_profile_seeder_child(),

        # Default RBAC role profiles seed
        role_profile_seeder_child(),

        # Service heartbeat (self-reporting for Elixir services)
        service_heartbeat_child(),

        # SPIFFE certificate expiry monitoring
        cert_monitor_child(),

        # Cluster infrastructure (only if clustering is enabled)
        cluster_children(),

        # Log promotion consumer for processed logs
        log_promotion_consumer_child(),

        # EventWriter for NATS JetStream → CNPG consumption (optional)
        event_writer_child()
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: ServiceRadar.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp ensure_started(app) do
    case Application.ensure_all_started(app) do
      {:ok, _} ->
        :ok

      {:error, {^app, reason}} ->
        Logger.error("Failed to start #{app}: #{inspect(reason)}")
        :error

      {:error, reason} ->
        Logger.error("Failed to start #{app}: #{inspect(reason)}")
        :error
    end
  end

  defp vault_child do
    if Application.get_env(:serviceradar_core, :vault_enabled, true) do
      ServiceRadar.Vault
    else
      nil
    end
  end

  defp repo_child do
    if Application.get_env(:serviceradar_core, :repo_enabled, true) do
      ServiceRadar.Repo
    else
      nil
    end
  end

  defp oban_child do
    oban_enabled = Application.get_env(:serviceradar_core, :oban_enabled, true)

    if oban_enabled do
      case Application.get_env(:serviceradar_core, Oban) do
        false -> nil
        nil -> nil
        oban_config when is_list(oban_config) -> {Oban, oban_config}
      end
    else
      nil
    end
  end

  defp sweep_schedule_reconciler_child do
    if Application.get_env(:serviceradar_core, :repo_enabled, true) do
      ServiceRadar.SweepJobs.SweepScheduleReconciler
    else
      nil
    end
  end

  defp startup_migrations_child do
    if Application.get_env(:serviceradar_core, :run_startup_migrations, false) do
      ServiceRadar.Cluster.StartupMigrations
    else
      nil
    end
  end

  defp ash_oban_scheduler_children do
    # Only start AshOban schedulers if explicitly enabled
    # web-ng should set :start_ash_oban_scheduler to false (core-elx handles scheduling)
    oban_enabled =
      Application.get_env(:serviceradar_core, :oban_enabled, true) &&
        Application.get_env(:serviceradar_core, Oban)

    scheduler_enabled = Application.get_env(:serviceradar_core, :start_ash_oban_scheduler, false)

    if oban_enabled && scheduler_enabled do
      # AshOban schedules via Oban.Plugins.Cron; no additional children needed.
      []
    else
      []
    end
  end

  defp sync_ingestor_task_supervisor_child do
    {Task.Supervisor, name: ServiceRadar.SyncIngestor.TaskSupervisor}
  end

  defp sync_ingestor_queue_child do
    ServiceRadar.Inventory.SyncIngestorQueue
  end

  defp registry_children do
    if Application.get_env(:serviceradar_core, :registries_enabled, true) do
      # ProcessRegistry provides Horde registry + DynamicSupervisor as child_specs
      process_registry_specs =
        if Process.whereis(ServiceRadar.ProcessRegistry.registry_name()) ||
             Process.whereis(ServiceRadar.ProcessRegistry.supervisor_name()) do
          []
        else
          ServiceRadar.ProcessRegistry.child_specs()
        end

      process_registry_specs ++
        [
          # Gateway tracker (ETS-based)
          ServiceRadar.GatewayTracker,
          # Agent tracker for Go agents that push status to gateways
          ServiceRadar.AgentTracker,
          # Identity cache for device lookups (ETS-based with TTL)
          ServiceRadar.Identity.IdentityCache,
          # Agent config cache (ETS-based)
          ServiceRadar.AgentConfig.ConfigCache,
          # Agent config server (compilation orchestration)
          ServiceRadar.AgentConfig.ConfigServer
        ]
    else
      []
    end
  end

  defp status_handler_child do
    if Application.get_env(:serviceradar_core, :status_handler_enabled, false) do
      ServiceRadar.StatusHandler
    else
      nil
    end
  end

  defp command_status_handler_child do
    if Application.get_env(:serviceradar_core, :status_handler_enabled, false) do
      ServiceRadar.AgentCommands.StatusHandler
    else
      nil
    end
  end

  defp results_router_child do
    if Application.get_env(:serviceradar_core, :status_handler_enabled, false) do
      ServiceRadar.ResultsRouter
    else
      nil
    end
  end

  defp grpc_client_supervisor_child do
    if datasvc_enabled?() or spiffe_workload_api?() do
      {GRPC.Client.Supervisor, []}
    else
      nil
    end
  end

  defp datasvc_client_child do
    if datasvc_enabled?() do
      ServiceRadar.DataService.Client
    else
      nil
    end
  end

  defp template_seeder_child do
    if Application.get_env(:serviceradar_core, :repo_enabled, true) do
      ServiceRadar.Observability.TemplateSeeder
    else
      nil
    end
  end

  defp zen_rule_seeder_child do
    if Application.get_env(:serviceradar_core, :repo_enabled, true) do
      ServiceRadar.Observability.ZenRuleSeeder
    else
      nil
    end
  end

  defp zen_rule_sync_child do
    if Application.get_env(:serviceradar_core, :repo_enabled, true) do
      ServiceRadar.Observability.ZenRuleSync
    else
      nil
    end
  end

  defp rule_seeder_child do
    if Application.get_env(:serviceradar_core, :repo_enabled, true) do
      ServiceRadar.Observability.RuleSeeder
    else
      nil
    end
  end

  defp job_schedule_seeder_child do
    if Application.get_env(:serviceradar_core, :repo_enabled, true) do
      ServiceRadar.Jobs.JobScheduleSeeder
    else
      nil
    end
  end

  defp device_cleanup_settings_seeder_child do
    if Application.get_env(:serviceradar_core, :repo_enabled, true) do
      ServiceRadar.Inventory.DeviceCleanupSettingsSeeder
    else
      nil
    end
  end

  defp snmp_profile_seeder_child do
    if Application.get_env(:serviceradar_core, :repo_enabled, true) do
      ServiceRadar.SNMPProfiles.SNMPProfileSeeder
    else
      nil
    end
  end

  defp role_profile_seeder_child do
    if Application.get_env(:serviceradar_core, :repo_enabled, true) do
      ServiceRadar.Identity.RoleProfileSeeder
    else
      nil
    end
  end

  defp datasvc_enabled? do
    # Check env var first, then app config
    case System.get_env("DATASVC_ENABLED") do
      nil -> Application.get_env(:serviceradar_core, :datasvc_enabled, true)
      value when value in ["true", "1", "yes"] -> true
      _ -> false
    end
  end

  defp spiffe_workload_api? do
    Application.get_env(:serviceradar_core, :spiffe, [])
    |> Keyword.get(:mode, :filesystem)
    |> Kernel.==(:workload_api)
  end

  defp cluster_children do
    cluster_enabled = Application.get_env(:serviceradar_core, :cluster_enabled, false)

    # cluster_coordinator controls whether this node runs ClusterHealth
    # - core-elx sets this to true (it's the coordinator)
    # - web-ng/agent-gateway should have it false (they join cluster but don't coordinate)
    # Defaults to cluster_enabled for backwards compatibility
    cluster_coordinator =
      Application.get_env(:serviceradar_core, :cluster_coordinator, cluster_enabled)

    if cluster_enabled do
      # All cluster-enabled nodes should start ClusterSupervisor for libcluster
      base = [ServiceRadar.ClusterSupervisor]

      # Only coordinator nodes run ClusterHealth
      if cluster_coordinator do
        base ++ [ServiceRadar.ClusterHealth]
      else
        base
      end
    else
      []
    end
  end

  defp nats_connection_child do
    if nats_enabled?() do
      ServiceRadar.NATS.Supervisor
    else
      nil
    end
  end

  defp nats_enabled? do
    case System.get_env("NATS_ENABLED") do
      nil -> Application.get_env(:serviceradar_core, :nats_enabled, false)
      value when value in ["true", "1", "yes"] -> true
      _ -> false
    end
  end

  defp event_batcher_child do
    if event_batcher_enabled?() do
      ServiceRadar.Infrastructure.EventBatcher
    else
      nil
    end
  end

  defp event_batcher_enabled? do
    case System.get_env("EVENT_BATCHER_ENABLED") do
      nil -> Application.get_env(:serviceradar_core, :event_batcher_enabled, true)
      value when value in ["true", "1", "yes"] -> true
      _ -> false
    end
  end

  defp health_check_runner_supervisor_child do
    if health_check_runner_enabled?() do
      {DynamicSupervisor,
       name: ServiceRadar.Infrastructure.HealthCheckRunnerSupervisor, strategy: :one_for_one}
    else
      nil
    end
  end

  defp health_check_runner_enabled? do
    case System.get_env("HEALTH_CHECK_RUNNER_ENABLED") do
      nil -> Application.get_env(:serviceradar_core, :health_check_runner_enabled, true)
      value when value in ["true", "1", "yes"] -> true
      _ -> false
    end
  end

  defp health_check_registrar_child do
    if health_check_registrar_enabled?() do
      ServiceRadar.Infrastructure.HealthCheckRegistrar
    else
      nil
    end
  end

  defp health_check_registrar_enabled? do
    case System.get_env("HEALTH_CHECK_REGISTRAR_ENABLED") do
      nil -> Application.get_env(:serviceradar_core, :health_check_registrar_enabled, true)
      value when value in ["true", "1", "yes"] -> true
      _ -> false
    end
  end

  defp service_heartbeat_child do
    if service_heartbeat_enabled?() do
      ServiceRadar.Infrastructure.ServiceHeartbeat
    else
      nil
    end
  end

  defp service_heartbeat_enabled? do
    case System.get_env("SERVICE_HEARTBEAT_ENABLED") do
      nil -> Application.get_env(:serviceradar_core, :service_heartbeat_enabled, true)
      value when value in ["true", "1", "yes"] -> true
      _ -> false
    end
  end

  defp cert_monitor_child do
    enabled =
      case System.get_env("SPIFFE_CERT_MONITOR_ENABLED") do
        nil -> Application.get_env(:serviceradar_core, :spiffe_cert_monitor_enabled, true)
        value -> value in ~w(true 1 yes)
      end

    if enabled and ServiceRadar.SPIFFE.certs_available?() do
      ServiceRadar.SPIFFE.CertMonitor
    else
      nil
    end
  end

  defp log_promotion_consumer_child do
    if ServiceRadar.Observability.LogPromotionConsumer.enabled?() do
      ServiceRadar.Observability.LogPromotionConsumer
    else
      nil
    end
  end

  defp event_writer_child do
    if event_writer_enabled?() do
      Supervisor.child_spec(ServiceRadar.EventWriter.Supervisor, restart: :temporary)
    else
      nil
    end
  end

  defp event_writer_enabled? do
    case System.get_env("EVENT_WRITER_ENABLED") do
      nil -> Application.get_env(:serviceradar_core, :event_writer_enabled, false)
      value when value in ["true", "1", "yes"] -> true
      _ -> false
    end
  end
end
