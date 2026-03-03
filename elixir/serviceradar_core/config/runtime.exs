import Config

# Runtime configuration for production deployments.
# This file is executed at runtime, not compile time.

# GeoLite2 MMDB configuration (all environments)
geolite_dir = System.get_env("GEOLITE_MMDB_DIR", "/var/lib/serviceradar/geoip")

geolite_city_enabled =
  System.get_env("GEOLITE_CITY_ENABLED", "false")
  |> String.downcase()
  |> then(&(&1 in ["1", "true", "yes", "on"]))

config :serviceradar_core,
  geolite_mmdb_dir: geolite_dir

base_geolite_dbs = [
  %{
    id: :geolite2_asn,
    adapter: Geolix.Adapter.MMDB2,
    source: Path.join(geolite_dir, "GeoLite2-ASN.mmdb")
  },
  %{
    id: :geolite2_country,
    adapter: Geolix.Adapter.MMDB2,
    source: Path.join(geolite_dir, "GeoLite2-Country.mmdb")
  }
]

city_geolite_dbs =
  (geolite_city_enabled &&
     [
       %{
         id: :geolite2_city,
         adapter: Geolix.Adapter.MMDB2,
         source: Path.join(geolite_dir, "GeoLite2-City.mmdb")
       }
     ]) || []

ipinfo_dbs = [
  %{
    id: :ipinfo_lite,
    adapter: Geolix.Adapter.MMDB2,
    source: Path.join(geolite_dir, "ipinfo_lite.mmdb")
  }
]

config :geolix, databases: base_geolite_dbs ++ city_geolite_dbs ++ ipinfo_dbs

if config_env() == :prod do
  # AshCloak encryption key (required for PII encryption)
  cloak_key =
    case System.get_env("CLOAK_KEY") do
      nil -> nil
      "" -> nil
      value -> value
    end ||
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

  spiffe_mode =
    case System.get_env("SPIFFE_MODE", "filesystem") do
      "workload_api" -> :workload_api
      _ -> :filesystem
    end

  spiffe_socket =
    System.get_env("SPIFFE_WORKLOAD_API_SOCKET") ||
      System.get_env("SPIFFE_ENDPOINT_SOCKET") ||
      "unix:///run/spire/sockets/agent.sock"

  spiffe_bundle_path = System.get_env("SPIFFE_TRUST_BUNDLE_PATH")

  config :serviceradar_core, :spiffe,
    mode: spiffe_mode,
    trust_domain: System.get_env("SPIFFE_TRUST_DOMAIN", "serviceradar.local"),
    cert_dir: System.get_env("SPIFFE_CERT_DIR", "/etc/serviceradar/certs"),
    workload_api_socket: spiffe_socket,
    trust_bundle_path: spiffe_bundle_path

  platform_sync_component_id =
    System.get_env("SERVICERADAR_PLATFORM_SYNC_COMPONENT_ID") || "platform-sync"

  config :serviceradar_core, :platform_sync_component_id, platform_sync_component_id

  age_graph_name =
    System.get_env("SERVICERADAR_AGE_GRAPH_NAME") ||
      System.get_env("AGE_GRAPH_NAME") ||
      "platform_graph"

  config :serviceradar_core, :age_graph_name, age_graph_name

  topology_v2_contract_consumption_enabled =
    System.get_env("SERVICERADAR_TOPOLOGY_V2_CONSUMPTION_ENABLED", "true")
    |> String.downcase()
    |> then(&(&1 in ["1", "true", "yes", "on"]))

  config :serviceradar_core,
    topology_v2_contract_consumption_enabled: topology_v2_contract_consumption_enabled

  parse_bool = fn env_name, default ->
    case System.get_env(env_name) do
      nil -> default
      value -> String.downcase(value) in ["1", "true", "yes", "on"]
    end
  end

  mtr_automation_enabled = parse_bool.("MTR_AUTOMATION_ENABLED", false)

  config :serviceradar_core,
    mtr_automation_enabled: mtr_automation_enabled,
    mtr_automation_baseline_enabled:
      parse_bool.("MTR_AUTOMATION_BASELINE_ENABLED", mtr_automation_enabled),
    mtr_automation_trigger_enabled:
      parse_bool.("MTR_AUTOMATION_TRIGGER_ENABLED", mtr_automation_enabled),
    mtr_automation_consensus_enabled:
      parse_bool.("MTR_AUTOMATION_CONSENSUS_ENABLED", mtr_automation_enabled)

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
  search_path = System.get_env("CNPG_SEARCH_PATH", "platform, public, ag_catalog")

  database_timeout =
    System.get_env("DATABASE_TIMEOUT_MS")
    |> case do
      nil -> nil
      "" -> nil
      value -> parse_int.(value)
    end

  database_pool_timeout =
    System.get_env("DATABASE_POOL_TIMEOUT_MS")
    |> case do
      nil -> nil
      "" -> nil
      value -> parse_int.(value)
    end

  repo_opts = [
    url: database_url,
    ssl: ssl_opts,
    socket_options: maybe_ipv6,
    pool_size: pool_size,
    parameters: [search_path: search_path],
    types: ServiceRadar.PostgresTypes
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
    |> then(fn opts ->
      if database_timeout, do: Keyword.put(opts, :timeout, database_timeout), else: opts
    end)
    |> then(fn opts ->
      if database_pool_timeout,
        do: Keyword.put(opts, :pool_timeout, database_pool_timeout),
        else: opts
    end)

  config :serviceradar_core, ServiceRadar.Repo, repo_opts

  # Cluster configuration
  config :serviceradar_core,
    cluster_enabled: System.get_env("CLUSTER_ENABLED", "true") == "true"

  # Status handler for agent-gateway push results (core-elx only)
  config :serviceradar_core,
    status_handler_enabled: System.get_env("STATUS_HANDLER_ENABLED", "true") in ~w(true 1 yes)

  config :serviceradar_core,
    run_startup_migrations:
      System.get_env("SERVICERADAR_CORE_RUN_MIGRATIONS", "false") in ~w(true 1 yes)

  sweep_srql_page_limit =
    System.get_env("SWEEP_SRQL_PAGE_LIMIT")
    |> case do
      nil -> nil
      "" -> nil
      value -> parse_int.(value)
    end

  config :serviceradar_core,
    sweep_srql_page_limit: sweep_srql_page_limit || 500

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

  config :serviceradar_core,
    device_enrichment_rules_dir:
      System.get_env(
        "DEVICE_ENRICHMENT_RULES_DIR",
        "/var/lib/serviceradar/rules/device-enrichment"
      )

  plugin_storage_defaults = Application.get_env(:serviceradar_core, :plugin_storage, [])

  plugin_storage_overrides =
    []
    |> then(fn acc ->
      case System.get_env("PLUGIN_STORAGE_PUBLIC_URL") do
        nil -> acc
        "" -> acc
        value -> Keyword.put(acc, :public_url, value)
      end
    end)
    |> then(fn acc ->
      case System.get_env("PLUGIN_STORAGE_SIGNING_SECRET") do
        nil -> acc
        "" -> acc
        value -> Keyword.put(acc, :signing_secret, value)
      end
    end)
    |> then(fn acc ->
      case System.get_env("PLUGIN_STORAGE_DOWNLOAD_TTL_SECONDS") do
        nil ->
          acc

        "" ->
          acc

        value ->
          case Integer.parse(value) do
            {parsed, ""} -> Keyword.put(acc, :download_ttl_seconds, parsed)
            _ -> acc
          end
      end
    end)

  if plugin_storage_overrides != [] do
    config :serviceradar_core,
           :plugin_storage,
           Keyword.merge(plugin_storage_defaults, plugin_storage_overrides)
  end

  # Oban configuration
  config :serviceradar_core, Oban,
    engine: Oban.Engines.Basic,
    repo: ServiceRadar.Repo,
    prefix: System.get_env("OBAN_SCHEMA", "platform"),
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
  nats_enabled = System.get_env("NATS_ENABLED", "false") in ~w(true 1 yes)
  nats_url = System.get_env("NATS_URL", "nats://localhost:4222")
  nats_uri = URI.parse(nats_url)
  nats_tls_enabled = System.get_env("NATS_TLS", "false") in ~w(true 1 yes)
  nats_server_name = System.get_env("NATS_SERVER_NAME", "nats.serviceradar")
  cert_dir = System.get_env("SPIFFE_CERT_DIR", "/etc/serviceradar/certs")
  nats_creds_file = System.get_env("NATS_CREDS_FILE")

  if nats_enabled && nats_creds_file in [nil, ""] do
    raise """
    NATS_CREDS_FILE is required for NATS JWT auth.
    Generate or provision JWT credentials and set NATS_CREDS_FILE.
    """
  end

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
    creds_file: nats_creds_file,
    tls: nats_tls_config

  log_promotion_enabled =
    System.get_env("LOG_PROMOTION_CONSUMER_ENABLED", "true") in ~w(true 1 yes)

  config :serviceradar_core, :log_promotion_consumer_enabled, log_promotion_enabled

  # EventWriter configuration (NATS JetStream → CNPG consumer)
  # Enable with EVENT_WRITER_ENABLED=true
  event_writer_enabled = System.get_env("EVENT_WRITER_ENABLED", "false") in ~w(true 1 yes)

  if event_writer_enabled do
    event_writer_creds = System.get_env("EVENT_WRITER_NATS_CREDS_FILE")

    if event_writer_creds in [nil, ""] do
      raise """
      EVENT_WRITER_NATS_CREDS_FILE is required when EVENT_WRITER_ENABLED=true.
      Generate or provision JWT credentials and set EVENT_WRITER_NATS_CREDS_FILE.
      """
    end

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
        creds_file: event_writer_creds,
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
          name: "FALCO",
          stream_name: "falco_events",
          subject: "falco.>",
          processor: ServiceRadar.EventWriter.Processors.FalcoEvents,
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
          name: "BMP_CAUSAL",
          subject: "bmp.events.>",
          processor: ServiceRadar.EventWriter.Processors.CausalSignals,
          batch_size: 100,
          batch_timeout: 1_000
        },
        %{
          name: "ARANCINI_CAUSAL",
          subject: "arancini.updates.>",
          processor: ServiceRadar.EventWriter.Processors.CausalSignals,
          batch_size: 100,
          batch_timeout: 1_000
        },
        %{
          name: "SIEM_CAUSAL",
          subject: "siem.events.>",
          processor: ServiceRadar.EventWriter.Processors.CausalSignals,
          batch_size: 100,
          batch_timeout: 1_000
        },
        %{
          name: "SFLOW_RAW",
          subject: "flows.raw.sflow",
          processor: ServiceRadar.EventWriter.Processors.Flows,
          batch_size: 50,
          batch_timeout: 500
        },
        %{
          name: "NETFLOW_RAW",
          subject: "flows.raw.netflow",
          processor: ServiceRadar.EventWriter.Processors.Flows,
          batch_size: 50,
          batch_timeout: 500
        }
      ]
  end
end
