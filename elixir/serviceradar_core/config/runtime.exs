import Config

# Runtime configuration for production deployments.
# This file is executed at runtime, not compile time.

if config_env() == :prod do
  # AshCloak encryption key (required for PII encryption)
  cloak_key =
    System.get_env("CLOAK_KEY") ||
      case System.get_env("CLOAK_KEY_FILE") do
        nil ->
          nil

        "" ->
          nil

        path ->
          case File.read(path) do
            {:ok, contents} -> String.trim(contents)
            {:error, reason} -> raise "failed to read CLOAK_KEY_FILE #{path}: #{inspect(reason)}"
          end
      end ||
      raise """
      environment variable CLOAK_KEY (or CLOAK_KEY_FILE) is missing.
      This key is required for encrypting sensitive fields like email addresses.

      Generate a 32-byte key with:
        :crypto.strong_rand_bytes(32) |> Base.encode64()
      """

  config :serviceradar_core,
    env: :prod,
    cloak_key: cloak_key

  default_tenant_id =
    System.get_env("SERVICERADAR_DEFAULT_TENANT_ID") ||
      "00000000-0000-0000-0000-000000000000"

  config :serviceradar_core, :default_tenant_id, default_tenant_id

  platform_tenant_id =
    System.get_env("SERVICERADAR_PLATFORM_TENANT_ID") ||
      System.get_env("PLATFORM_TENANT_ID")

  config :serviceradar_core, :platform_tenant_id, platform_tenant_id

  platform_tenant_slug =
    System.get_env("SERVICERADAR_PLATFORM_TENANT_SLUG") ||
      System.get_env("PLATFORM_TENANT_SLUG") ||
      "platform"

  config :serviceradar_core, :platform_tenant_slug, platform_tenant_slug

  platform_sync_component_id =
    System.get_env("SERVICERADAR_PLATFORM_SYNC_COMPONENT_ID") || "platform-sync"

  config :serviceradar_core, :platform_sync_component_id, platform_sync_component_id

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  ssl_mode = System.get_env("CNPG_SSL_MODE", "require")

  ssl_opts =
    case ssl_mode do
      "disable" -> false
      _ -> [verify: :verify_none]
    end

  parse_int = fn value ->
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  pool_size = parse_int.(System.get_env("POOL_SIZE") || "10") || 10

  repo_opts = [
    url: database_url,
    ssl: ssl_opts,
    socket_options: maybe_ipv6,
    pool_size: pool_size
  ]

  queue_target =
    System.get_env("DATABASE_QUEUE_TARGET_MS")
    |> case do
      nil -> nil
      "" -> nil
      value -> parse_int.(value)
    end

  queue_interval =
    System.get_env("DATABASE_QUEUE_INTERVAL_MS")
    |> case do
      nil -> nil
      "" -> nil
      value -> parse_int.(value)
    end

  repo_opts =
    repo_opts
    |> then(fn opts ->
      if queue_target, do: Keyword.put(opts, :queue_target, queue_target), else: opts
    end)
    |> then(fn opts ->
      if queue_interval, do: Keyword.put(opts, :queue_interval, queue_interval), else: opts
    end)

  config :serviceradar_core, ServiceRadar.Repo, repo_opts

  # Cluster configuration
  config :serviceradar_core,
    cluster_enabled: System.get_env("CLUSTER_ENABLED", "true") == "true"

  # Status handler for agent-gateway push results (core-elx only)
  config :serviceradar_core,
    status_handler_enabled: System.get_env("STATUS_HANDLER_ENABLED", "true") in ~w(true 1 yes)

  config :serviceradar_core,
    run_startup_migrations: System.get_env("SERVICERADAR_CORE_RUN_MIGRATIONS", "false") in ~w(true 1 yes)

  config :serviceradar_core,
    reset_tenant_schemas: System.get_env("SERVICERADAR_RESET_TENANT_SCHEMAS", "false") in ~w(true 1 yes)

  sync_ingestor_batch_concurrency =
    System.get_env("SYNC_INGESTOR_BATCH_CONCURRENCY")
    |> case do
      nil -> nil
      "" -> nil
      value -> parse_int.(value)
    end

  config :serviceradar_core,
    sync_ingestor_batch_concurrency: sync_ingestor_batch_concurrency || 2

  config :serviceradar_core,
    sync_ingestor_async: System.get_env("SYNC_INGESTOR_ASYNC", "true") in ~w(true 1 yes)

  sync_ingestor_coalesce_ms =
    System.get_env("SYNC_INGESTOR_COALESCE_MS")
    |> case do
      nil -> nil
      "" -> nil
      value -> parse_int.(value)
    end

  config :serviceradar_core,
    sync_ingestor_coalesce_ms: sync_ingestor_coalesce_ms || 250

  sync_ingestor_max_inflight =
    System.get_env("SYNC_INGESTOR_MAX_INFLIGHT")
    |> case do
      nil -> nil
      "" -> nil
      value -> parse_int.(value)
    end

  config :serviceradar_core,
    sync_ingestor_max_inflight: sync_ingestor_max_inflight || 2

  sync_ingestor_queue_max_chunks =
    System.get_env("SYNC_INGESTOR_QUEUE_MAX_CHUNKS")
    |> case do
      nil -> nil
      "" -> nil
      value -> parse_int.(value)
    end

  config :serviceradar_core,
    sync_ingestor_queue_max_chunks: sync_ingestor_queue_max_chunks || 10

  # Oban configuration
  config :serviceradar_core, Oban,
    engine: Oban.Engines.Basic,
    repo: ServiceRadar.Repo,
    queues: [
      default: String.to_integer(System.get_env("OBAN_QUEUE_DEFAULT") || "10"),
      alerts: String.to_integer(System.get_env("OBAN_QUEUE_ALERTS") || "5"),
      service_checks: String.to_integer(System.get_env("OBAN_QUEUE_SERVICE_CHECKS") || "10"),
      notifications: String.to_integer(System.get_env("OBAN_QUEUE_NOTIFICATIONS") || "5"),
      onboarding: String.to_integer(System.get_env("OBAN_QUEUE_ONBOARDING") || "3"),
      events: String.to_integer(System.get_env("OBAN_QUEUE_EVENTS") || "10"),
      sweeps: String.to_integer(System.get_env("OBAN_QUEUE_SWEEPS") || "20"),
      edge: String.to_integer(System.get_env("OBAN_QUEUE_EDGE") || "10"),
      integrations: String.to_integer(System.get_env("OBAN_QUEUE_INTEGRATIONS") || "5"),
      nats_accounts: String.to_integer(System.get_env("OBAN_QUEUE_NATS_ACCOUNTS") || "3")
    ],
    plugins: [
      Oban.Plugins.Pruner,
      {Oban.Plugins.Cron, crontab: []}
    ],
    peer: Oban.Peers.Database

  # Core NATS connection configuration
  nats_url = System.get_env("NATS_URL", "nats://localhost:4222")
  nats_uri = URI.parse(nats_url)
  nats_tls_enabled = System.get_env("NATS_TLS", "false") in ~w(true 1 yes)
  nats_server_name = System.get_env("NATS_SERVER_NAME", "nats.serviceradar")
  cert_dir = System.get_env("SPIFFE_CERT_DIR", "/etc/serviceradar/certs")

  nats_tls_config =
    if nats_tls_enabled do
      [
        verify: :verify_peer,
        cacertfile: Path.join(cert_dir, "root.pem"),
        certfile: Path.join(cert_dir, "core.pem"),
        keyfile: Path.join(cert_dir, "core-key.pem"),
        server_name_indication: String.to_charlist(nats_server_name)
      ]
    else
      false
    end

  config :serviceradar_core, ServiceRadar.NATS.Connection,
    host: nats_uri.host || "localhost",
    port: nats_uri.port || 4222,
    user: System.get_env("NATS_USER"),
    password: {:system, "NATS_PASSWORD"},
    creds_file: System.get_env("NATS_CREDS_FILE"),
    tls: nats_tls_config

  # EventWriter configuration (NATS JetStream → CNPG consumer)
  # Enable with EVENT_WRITER_ENABLED=true
  event_writer_enabled = System.get_env("EVENT_WRITER_ENABLED", "false") in ~w(true 1 yes)

  if event_writer_enabled do
    nats_url = System.get_env("EVENT_WRITER_NATS_URL", "nats://localhost:4222")
    nats_uri = URI.parse(nats_url)

    # Build TLS configuration for mTLS
    nats_tls_enabled = System.get_env("EVENT_WRITER_NATS_TLS", "false") in ~w(true 1 yes)
    cert_dir = System.get_env("SPIFFE_CERT_DIR", "/etc/serviceradar/certs")

    nats_tls_config =
      if nats_tls_enabled do
        [
          verify: :verify_peer,
          cacertfile: Path.join(cert_dir, "root.pem"),
          certfile: Path.join(cert_dir, "core.pem"),
          keyfile: Path.join(cert_dir, "core-key.pem"),
          server_name_indication: ~c"nats.serviceradar"
        ]
      else
        false
      end

    config :serviceradar_core, :event_writer_enabled, true

    config :serviceradar_core, ServiceRadar.EventWriter,
      enabled: true,
      nats: [
        host: nats_uri.host || "localhost",
        port: nats_uri.port || 4222,
        user: System.get_env("EVENT_WRITER_NATS_USER"),
        password: {:system, "EVENT_WRITER_NATS_PASSWORD"},
        creds_file: System.get_env("EVENT_WRITER_NATS_CREDS_FILE"),
        tls: nats_tls_config
      ],
      batch_size: String.to_integer(System.get_env("EVENT_WRITER_BATCH_SIZE") || "100"),
      batch_timeout: String.to_integer(System.get_env("EVENT_WRITER_BATCH_TIMEOUT") || "1000"),
      consumer_name: System.get_env("EVENT_WRITER_CONSUMER_NAME", "serviceradar-event-writer"),
      streams: [
        %{
          name: "EVENTS",
          subject: "events.>",
          processor: ServiceRadar.EventWriter.Processors.Events,
          batch_size: 100,
          batch_timeout: 1_000
        },
        %{
          name: "SNMP_TRAPS",
          subject: "snmp.traps",
          processor: ServiceRadar.EventWriter.Processors.Events,
          batch_size: 100,
          batch_timeout: 1_000
        },
        %{
          name: "OTEL_METRICS",
          subject: "otel.metrics.>",
          processor: ServiceRadar.EventWriter.Processors.OtelMetrics,
          batch_size: 100,
          batch_timeout: 1_000
        },
        %{
          name: "OTEL_TRACES",
          subject: "otel.traces.>",
          processor: ServiceRadar.EventWriter.Processors.OtelTraces,
          batch_size: 100,
          batch_timeout: 1_000
        },
        %{
          name: "LOGS",
          subject: "logs.>",
          processor: ServiceRadar.EventWriter.Processors.Logs,
          batch_size: 100,
          batch_timeout: 1_000
        }
      ]
  end
end
