defmodule ServiceRadar.Application do
  @moduledoc """
  ServiceRadar Core Application.

  Starts the core supervision tree including:
  - Database connection pool (Repo)
  - Oban job processor
  - Cluster supervisor (libcluster + Horde)
  - Per-tenant TenantRegistry (Horde registries + DynamicSupervisors)

  ## Multi-Tenant Process Isolation

  The TenantRegistry provides per-tenant Horde registries and DynamicSupervisors
  for multi-tenant process isolation. Edge components (gateways, agents) can only
  discover processes within their tenant, preventing cross-tenant enumeration.

  GatewayRegistry and AgentRegistry delegate to TenantRegistry for all operations.

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
  - `:registries_enabled` - Whether to start TenantRegistry (default: true)
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

  @impl true
  def start(_type, _args) do
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

        # Per-tenant Oban supervisors (after Oban)
        tenant_oban_supervisor_child(),

        # AshOban schedulers for Ash resource triggers
        ash_oban_scheduler_children(),

        # Per-tenant Oban queue management (after Oban, before registries)
        tenant_queues_child(),

        # GRPC client supervisor (required for DataService.Client)
        grpc_client_supervisor_child(),

        # NATS JetStream connection for event publishing
        nats_connection_child(),

        # NATS operator auto-bootstrap (runs once at startup)
        nats_operator_bootstrap_child(),

        # Event batcher for high-frequency NATS events
        event_batcher_child(),

        # Status handler for agent-gateway push results
        status_handler_child(),

        # Infrastructure state monitor (heartbeat timeouts, health checks)
        state_monitor_child(),

        # Health check runner supervisor (high-frequency gRPC checks)
        health_check_runner_supervisor_child(),

        # Health check registrar (subscribes to agent events, auto-registers services)
        health_check_registrar_child(),

        # Horde registries (always started for registration support)
        registry_children(),

        # Platform tenant bootstrap (requires repo + Ash + TenantRegistry ETS)
        ServiceRadar.Identity.PlatformTenantBootstrap,

        # Service heartbeat (self-reporting for Elixir services)
        service_heartbeat_child(),

        # SPIFFE certificate expiry monitoring
        cert_monitor_child(),

        # Cluster infrastructure (only if clustering is enabled)
        cluster_children(),

        # EventWriter for NATS JetStream → CNPG consumption (optional)
        event_writer_child()
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: ServiceRadar.Supervisor]
    Supervisor.start_link(children, opts)
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

  defp tenant_queues_child do
    # Only start TenantQueues if Oban is enabled
    if Application.get_env(:serviceradar_core, :oban_enabled, true) &&
         Application.get_env(:serviceradar_core, Oban) do
      ServiceRadar.Oban.TenantQueues
    else
      nil
    end
  end

  defp tenant_oban_supervisor_child do
    if Application.get_env(:serviceradar_core, :oban_enabled, true) &&
         Application.get_env(:serviceradar_core, Oban) do
      ServiceRadar.Oban.TenantSupervisor
    else
      nil
    end
  end

  defp registry_children do
    if Application.get_env(:serviceradar_core, :registries_enabled, true) do
      [
        # Per-tenant Horde registries and DynamicSupervisors
        # TenantRegistry manages per-tenant process isolation (Option D hybrid approach)
        # GatewayRegistry and AgentRegistry now delegate to TenantRegistry
        ServiceRadar.Cluster.TenantRegistry,
        # Platform-level gateway tracker (gateways serve all tenants)
        ServiceRadar.GatewayTracker,
        # Agent tracker for Go agents that push status to gateways
        ServiceRadar.AgentTracker,
        # Identity cache for device lookups (ETS-based with TTL)
        ServiceRadar.Identity.IdentityCache,
        # Preload tenant slug mappings for edge resolution
        ServiceRadar.Cluster.TenantRegistryLoader,
        # DataService client for KV operations (used to push config to Go/Rust services)
        datasvc_client_child()
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

  defp grpc_client_supervisor_child do
    if datasvc_enabled?() do
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

  defp datasvc_enabled? do
    # Check env var first, then app config
    case System.get_env("DATASVC_ENABLED") do
      nil -> Application.get_env(:serviceradar_core, :datasvc_enabled, true)
      value when value in ["true", "1", "yes"] -> true
      _ -> false
    end
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
      ServiceRadar.NATS.Connection
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

  defp nats_operator_bootstrap_child do
    # Only run auto-bootstrap if datasvc is enabled (we need it to bootstrap)
    # and if repo is enabled (we need to store the operator record)
    if datasvc_enabled?() and Application.get_env(:serviceradar_core, :repo_enabled, true) do
      ServiceRadar.NATS.OperatorBootstrap
    else
      nil
    end
  end

  defp state_monitor_child do
    if state_monitor_enabled?() do
      ServiceRadar.Infrastructure.StateMonitor
    else
      nil
    end
  end

  defp state_monitor_enabled? do
    case System.get_env("STATE_MONITOR_ENABLED") do
      nil -> Application.get_env(:serviceradar_core, :state_monitor_enabled, true)
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
       name: ServiceRadar.Infrastructure.HealthCheckRunnerSupervisor,
       strategy: :one_for_one}
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
