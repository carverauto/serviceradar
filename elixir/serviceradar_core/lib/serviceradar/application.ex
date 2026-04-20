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

        # RBAC permission cache (shared ETS, must start after PubSub)
        ServiceRadar.Identity.RBAC.Cache,

        # AS Lookup cache for BGP routing (queries GeoIP/ipinfo enrichment caches)
        as_lookup_child(),

        # Minimal HTTP client for background jobs (GeoLite downloads, optional ipinfo refresh)
        finch_child(),

        # Local registry for process lookups (gateways, agents)
        {Registry, keys: :unique, name: ServiceRadar.LocalRegistry},

        # Oban job processor (can be disabled for standalone tests)
        oban_child(),

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

        # Horde registries (always started for registration support)
        registry_children(),

        # Service heartbeat (self-reporting for Elixir services)
        service_heartbeat_child(),

        # SPIFFE certificate expiry monitoring
        cert_monitor_child(),

        # Cluster infrastructure (only if clustering is enabled)
        cluster_children(),

        # Coordinator-only duties for core-elx candidates
        coordinator_children(),

        # NATS ingest notification → PubSub bridge (lightweight, no ack needed)
        nats_ingest_notifier_child()
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
    end
  end

  defp repo_child do
    if repo_enabled?() do
      ServiceRadar.Repo
    end
  end

  defp as_lookup_child do
    # Start AS lookup cache when repo is available (always enabled)
    if Application.get_env(:serviceradar_core, :repo_enabled, true) do
      ServiceRadar.BGP.ASLookup
    end
  end

  defp finch_child do
    if Application.get_env(:serviceradar_core, :http_client_enabled, true) do
      base = [name: ServiceRadar.Finch]

      # Our release images are intentionally minimal and may not include OS CA bundles.
      # Configure Finch with CAStore so background HTTPS fetches (GeoLite, threat intel, ipinfo)
      # work reliably in Kubernetes.
      opts =
        if Code.ensure_loaded?(CAStore) and function_exported?(CAStore, :file_path, 0) do
          Keyword.put(base, :pools, %{
            default: [
              conn_opts: [
                transport_opts: [
                  cacertfile: CAStore.file_path()
                ]
              ]
            ]
          })
        else
          base
        end

      {Finch, opts}
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
    end
  end

  defp startup_migrations_child do
    if Application.get_env(:serviceradar_core, :run_startup_migrations, false) do
      ServiceRadar.Cluster.StartupMigrations
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

  defp grpc_client_supervisor_child do
    if datasvc_enabled?() or spiffe_workload_api?() do
      {GRPC.Client.Supervisor, []}
    end
  end

  defp datasvc_client_child do
    if datasvc_enabled?() do
      ServiceRadar.DataService.Client
    end
  end

  defp repo_enabled? do
    Application.get_env(:serviceradar_core, :repo_enabled, true) != false
  end

  defp datasvc_enabled? do
    case System.get_env("DATASVC_ENABLED") do
      nil ->
        datasvc_connectivity_configured?() or
          Application.get_env(:serviceradar_core, :datasvc_enabled, true)

      "" ->
        datasvc_connectivity_configured?() or
          Application.get_env(:serviceradar_core, :datasvc_enabled, true)

      value when value in ["true", "1", "yes"] ->
        true

      _ ->
        false
    end
  end

  defp datasvc_connectivity_configured? do
    Enum.any?(["DATASVC_ADDRESS", "DATASVC_HOST", "DATASVC_PORT"], fn env_name ->
      case System.get_env(env_name) do
        value when is_binary(value) -> String.trim(value) != ""
        _ -> false
      end
    end)
  end

  defp spiffe_workload_api? do
    :serviceradar_core
    |> Application.get_env(:spiffe, [])
    |> Keyword.get(:mode, :filesystem)
    |> Kernel.==(:workload_api)
  end

  defp cluster_children do
    cluster_enabled = Application.get_env(:serviceradar_core, :cluster_enabled, false)

    if cluster_enabled do
      [ServiceRadar.ClusterSupervisor]
    else
      []
    end
  end

  defp nats_connection_child do
    if nats_enabled?() do
      ServiceRadar.NATS.Supervisor
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
    end
  end

  defp event_batcher_enabled? do
    case System.get_env("EVENT_BATCHER_ENABLED") do
      nil -> Application.get_env(:serviceradar_core, :event_batcher_enabled, true)
      value when value in ["true", "1", "yes"] -> true
      _ -> false
    end
  end

  defp service_heartbeat_child do
    if service_heartbeat_enabled?() do
      ServiceRadar.Infrastructure.ServiceHeartbeat
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
    end
  end

  defp nats_ingest_notifier_child do
    if nats_enabled?() do
      ServiceRadar.Observability.NatsIngestNotifier
    end
  end

  defp coordinator_children do
    cluster_enabled = Application.get_env(:serviceradar_core, :cluster_enabled, false)
    coordinator_candidate = Application.get_env(:serviceradar_core, :cluster_coordinator, false)

    cond do
      not repo_enabled?() or not coordinator_candidate ->
        []

      cluster_enabled ->
        [
          {DynamicSupervisor,
           name: ServiceRadar.Cluster.CoordinatorRuntimeSupervisor, strategy: :one_for_one},
          ServiceRadar.Cluster.CoordinatorManager
        ]

      true ->
        ServiceRadar.Cluster.CoordinatorChildren.children()
    end
  end
end
