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
        control_repo_child(),

        # Supervise asynchronous config dependency notifications so shutdown and
        # database ownership boundaries can drain them deterministically.
        dependency_dispatcher_task_supervisor_child(),

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

        # Runtime publications for agent-gateway-served auxiliary artifacts
        ServiceRadar.Edge.AgentArtifacts,

        # Owns the Store source-name ETS registry. Start it before Oban so due
        # materializer jobs cannot race the supervised owner during boot.
        prefix_tags_registry_child(),

        # Oban job processor (can be disabled for standalone tests)
        oban_child(),
        oban_failure_event_reporter_child(),

        # AshOban schedulers for Ash resource triggers
        ash_oban_scheduler_children(),

        # NOTE: grpc 1.0 starts the GRPC.Client.Supervisor DynamicSupervisor
        # automatically via GRPC.Client.Application (mod: in grpc's mix.exs), so
        # no manual client-supervisor child is required here anymore.
        datasvc_client_child(),

        # NATS JetStream connection supervisor (fault-tolerant with auto-reconnect)
        nats_connection_child(),

        # Event batcher for high-frequency NATS events
        event_batcher_child(),

        # Task supervisor for sync ingestion work
        sync_ingestor_task_supervisor_child(),

        # Sync ingestion queue/coalescer
        sync_ingestor_queue_child(),

        # Holds partial discovery snapshots and the per-scope supersession
        # watermarks. Bounded three ways (TTL, set count, part count); a
        # producer cannot grow it.
        ServiceRadar.Inventory.Discovery.Buffer,

        # Bounded endpoint inventory ingestion admission queue
        endpoint_inventory_ingestor_task_supervisor_child(),
        endpoint_inventory_ingestor_queue_child(),

        # Bounded async stateful alert evaluation for bursty event sources
        stateful_alert_evaluation_task_supervisor_child(),
        stateful_alert_evaluation_queue_child(),

        # Out-of-band, report-only anomaly disposition reporter. AnalyticsSignals
        # casts persisted class-2004 anomaly findings here; it drives
        # AnomalyDisposition.report_finding/2 (telemetry only) OFF the alert hot path.
        anomaly_disposition_reporter_child(),

        # Short-TTL ETS cache for event-writer device correlation (one DB
        # lookup per device instead of per event under load)
        device_correlation_cache_child(),

        # Per-node prefix-tag LPM trie loader (core-elx + web-ng when repo is on;
        # agent-gateway excluded via repo_enabled? false). Hosting-provider LPM
        # uses the `provider` trie (ProviderSource) — no cross-batch ETS cache.
        prefix_tags_loader_child(),

        # Horde registries (always started for registration support)
        registry_children(),

        # Cluster-aware rate limiter (per-node ETS + Horde-discovered
        # peer broadcast). Must start after ProcessRegistry so it can
        # register {:rate_limiter, node()} on init.
        ServiceRadar.Security.RateLimiter,

        # Non-blocking SecurityEvent recorder (per-node bounded queue with one
        # supervised persistence batch in flight).
        security_events_task_supervisor_child(),
        ServiceRadar.Security.Events,

        # Service heartbeat (self-reporting for Elixir services)
        service_heartbeat_child(),

        # Per-pod MMDB fetch for emptyDir volumes (Oban only runs on one replica)
        geoip_bootstrap_child(),

        # SPIFFE certificate expiry monitoring
        cert_monitor_child(),

        # Cluster infrastructure (only if clustering is enabled)
        cluster_children(),

        # Coordinator-only duties for core-elx candidates
        coordinator_children()
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

  defp control_repo_child do
    if control_repo_enabled?() do
      ServiceRadar.ControlRepo
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
      # CAStore, and no SERVICERADAR_EGRESS_PROXY hop: the pool connects
      # directly, and hosts outside the deployment go through
      # ServiceRadar.HTTP.EgressClient (ServiceRadar.HTTP.EgressProxy says why).
      # Release images are intentionally minimal and may not include OS CA
      # bundles.
      #
      # Call sites opt in with `finch: [name: ServiceRadar.Finch]` (see
      # ServiceRadar.HTTP.EgressProxy.req_opts/1). Do not set
      # Req.default_options(finch: ...): Req 0.7 raises if a request also
      # passes :connect_options, and several clients do that on purpose
      # (SNI-to-IP, verify_none, connect timeouts).
      opts = [name: ServiceRadar.Finch]

      opts =
        case ServiceRadar.HTTP.EgressProxy.finch_pools() do
          nil -> opts
          pools -> Keyword.put(opts, :pools, pools)
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

  defp oban_failure_event_reporter_child do
    enabled =
      repo_enabled?() &&
        Application.get_env(:serviceradar_core, :oban_enabled, true) &&
        Application.get_env(:serviceradar_core, :oban_failure_events_enabled, true)

    if enabled do
      ServiceRadar.Observability.ObanFailureEventReporter
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

  defp dependency_dispatcher_task_supervisor_child do
    {Task.Supervisor, name: ServiceRadar.AgentConfig.DependencyDispatcher.TaskSupervisor}
  end

  defp sync_ingestor_queue_child do
    ServiceRadar.Inventory.SyncIngestorQueue
  end

  defp endpoint_inventory_ingestor_task_supervisor_child do
    {Task.Supervisor, name: ServiceRadar.EndpointInventoryIngestor.TaskSupervisor}
  end

  defp endpoint_inventory_ingestor_queue_child do
    ServiceRadar.Inventory.EndpointInventoryIngestorQueue
  end

  defp stateful_alert_evaluation_task_supervisor_child do
    if repo_enabled?() do
      {Task.Supervisor, name: ServiceRadar.StatefulAlertEvaluation.TaskSupervisor}
    end
  end

  defp stateful_alert_evaluation_queue_child do
    if repo_enabled?() do
      ServiceRadar.Observability.StatefulAlertEvaluationQueue
    end
  end

  defp security_events_task_supervisor_child do
    {Task.Supervisor, name: ServiceRadar.Security.Events.TaskSupervisor}
  end

  defp anomaly_disposition_reporter_child do
    if repo_enabled?() do
      ServiceRadar.Observability.AnomalyDispositionReporter
    end
  end

  defp device_correlation_cache_child do
    if repo_enabled?() do
      ServiceRadar.EventWriter.DeviceCorrelationCache
    end
  end

  defp prefix_tags_registry_child do
    # Always start when repo is on — independent of Loader — so Store.sources/0
    # keeps a stable ETS owner even with SERVICERADAR_PREFIX_TAGS_LOADER_ENABLED=false.
    if repo_enabled?() do
      ServiceRadar.PrefixTags.Registry
    end
  end

  defp prefix_tags_loader_child do
    if repo_enabled?() and
         Application.get_env(:serviceradar_core, :prefix_tags_loader_enabled, true) do
      ServiceRadar.PrefixTags.Loader
    end
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
          # Recent catalog-driven agent config diagnostics
          ServiceRadar.AgentConfig.DependencyDiagnostics,
          # Agent config server (compilation orchestration)
          ServiceRadar.AgentConfig.ConfigServer
        ]
    else
      []
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

  defp control_repo_enabled? do
    repo_enabled?() &&
      Application.get_env(:serviceradar_core, :control_repo_enabled, false) != false
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

  defp geoip_bootstrap_child do
    geolite? = env_flag_enabled?("GEOLITE_MMDB_DOWNLOAD_ENABLED")
    ipinfo? = env_flag_enabled?("IPINFO_MMDB_DOWNLOAD_ENABLED")

    if geolite? or ipinfo? do
      {Task,
       fn ->
         try do
           if geolite? do
             _ = ServiceRadar.Observability.GeoLiteMmdbDownloadWorker.sync_missing_files()
           end

           if ipinfo? do
             _ = ServiceRadar.Observability.IpinfoMmdbDownloadWorker.sync_missing_files()
           end
         rescue
           error ->
             Logger.warning("GeoIP MMDB bootstrap failed: #{Exception.message(error)}")
         end
       end}
    end
  end

  defp env_flag_enabled?(name) do
    name
    |> System.get_env("false")
    |> String.downcase()
    |> Kernel.in(["1", "true", "yes", "on"])
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
