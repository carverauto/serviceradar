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
  for multi-tenant process isolation. Edge components (pollers, agents) can only
  discover processes within their tenant, preventing cross-tenant enumeration.

  PollerRegistry and AgentRegistry delegate to TenantRegistry for all operations.

  This application can run standalone or as a dependency of
  serviceradar_web or serviceradar_poller.

  ## Configuration

  - `:repo_enabled` - Whether to start the database connection pool (default: true)
  - `:oban_enabled` - Whether to start Oban job processor (default: true)
  - `:cluster_enabled` - Whether to start cluster infrastructure (default: false)
  - `:registries_enabled` - Whether to start TenantRegistry (default: true)
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

        # PubSub for cluster events (always needed)
        {Phoenix.PubSub, name: ServiceRadar.PubSub},

        # Local registry for process lookups (pollers, agents)
        {Registry, keys: :unique, name: ServiceRadar.LocalRegistry},

        # Oban job processor (can be disabled for standalone tests)
        oban_child(),

        # AshOban schedulers for Ash resource triggers
        ash_oban_scheduler_children(),

        # Per-tenant Oban queue management (after Oban, before registries)
        tenant_queues_child(),

        # GRPC client supervisor (required for DataService.Client)
        grpc_client_supervisor_child(),

        # NATS JetStream connection for event publishing
        nats_connection_child(),

        # Event batcher for high-frequency NATS events
        event_batcher_child(),

        # Infrastructure state monitor (heartbeat timeouts, health checks)
        state_monitor_child(),

        # Health check runner supervisor (high-frequency gRPC checks)
        health_check_runner_supervisor_child(),

        # Health check registrar (subscribes to agent events, auto-registers services)
        health_check_registrar_child(),

        # Service heartbeat (self-reporting for Elixir services)
        service_heartbeat_child(),

        # Horde registries (always started for registration support)
        registry_children(),

        # SPIFFE certificate expiry monitoring
        cert_monitor_child(),

        # Cluster infrastructure (only if clustering is enabled)
        cluster_children()
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
    case Application.get_env(:serviceradar_core, Oban) do
      false -> nil
      nil -> nil
      oban_config when is_list(oban_config) -> {Oban, oban_config}
    end
  end

  defp ash_oban_scheduler_children do
    # Only start AshOban schedulers if explicitly enabled
    # web-ng should set :start_ash_oban_scheduler to false (core-elx handles scheduling)
    oban_enabled = Application.get_env(:serviceradar_core, Oban)
    scheduler_enabled = Application.get_env(:serviceradar_core, :start_ash_oban_scheduler, false)

    if oban_enabled && scheduler_enabled do
      # Start all AshOban schedulers for the configured domains
      domains = Application.get_env(:serviceradar_core, :ash_domains, [])

      if Enum.any?(domains) do
        [{AshOban.Scheduler, domains: domains}]
      else
        []
      end
    else
      []
    end
  end

  defp tenant_queues_child do
    # Only start TenantQueues if Oban is enabled
    if Application.get_env(:serviceradar_core, Oban) do
      ServiceRadar.Oban.TenantQueues
    else
      nil
    end
  end

  defp registry_children do
    if Application.get_env(:serviceradar_core, :registries_enabled, true) do
      [
        # Per-tenant Horde registries and DynamicSupervisors
        # TenantRegistry manages per-tenant process isolation (Option D hybrid approach)
        # PollerRegistry and AgentRegistry now delegate to TenantRegistry
        ServiceRadar.Cluster.TenantRegistry,
        # Identity cache for device lookups (ETS-based with TTL)
        ServiceRadar.Identity.IdentityCache,
        # DataService client for KV operations (used to push config to Go/Rust services)
        datasvc_client_child()
      ]
    else
      []
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
    if Application.get_env(:serviceradar_core, :cluster_enabled, false) do
      [
        # Cluster supervisor manages libcluster + Horde
        ServiceRadar.ClusterSupervisor,
        ServiceRadar.ClusterHealth
      ]
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
end
