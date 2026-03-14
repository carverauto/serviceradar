import Config

parse_int_env = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    "" ->
      default

    value ->
      case Integer.parse(value) do
        {int, ""} -> int
        _ -> default
      end
  end
end

# =============================================================================
# OpenTelemetry Configuration
# =============================================================================
# All OTEL exporter config MUST live here — runtime.exs runs before OTP apps
# start, so the opentelemetry SDK picks up these values at boot.
otel_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")

if otel_endpoint do
  ssl_opts = ServiceRadar.Telemetry.OtelSetup.ssl_options()

  config :opentelemetry,
    span_processor: :batch,
    traces_exporter:
      {:serviceradar_otel_exporter_traces_otlp,
       %{
         rpc_timeout_ms: 10_000,
         retry_max_attempts: 5,
         retry_base_delay_ms: 200,
         retry_max_delay_ms: 5_000
       }}

  config :opentelemetry_exporter,
    otlp_protocol: :grpc,
    otlp_endpoint: otel_endpoint,
    ssl_options: ssl_opts

  # Log exporter uses the same endpoint/protocol/TLS as traces
  config :opentelemetry_experimental,
    otlp_protocol: :grpc,
    otlp_endpoint: otel_endpoint,
    ssl_options: ssl_opts
else
  # No endpoint configured — disable export to avoid connection errors
  config :opentelemetry,
    traces_exporter: :none
end

# =============================================================================
# GeoLite2 MMDB / GeoIP Configuration
# =============================================================================
# The core release must configure Geolix itself at runtime so enrichment workers
# can perform local GeoIP/ASN lookups (no external calls at query time).
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

# =============================================================================
# Cluster Configuration
# =============================================================================
cluster_strategy =
  System.get_env("CLUSTER_STRATEGY", "epmd")
  |> String.downcase()

cluster_enabled = System.get_env("CLUSTER_ENABLED", "true") in ~w(true 1 yes)

topologies =
  if cluster_enabled do
    case cluster_strategy do
      "kubernetes" ->
        namespace = System.get_env("NAMESPACE", "serviceradar")
        kubernetes_selector = System.get_env("KUBERNETES_SELECTOR", "app=serviceradar")
        kubernetes_node_basename = System.get_env("KUBERNETES_NODE_BASENAME", "serviceradar")

        [
          serviceradar: [
            strategy: Cluster.Strategy.Kubernetes,
            config: [
              mode: :dns,
              kubernetes_node_basename: kubernetes_node_basename,
              kubernetes_selector: kubernetes_selector,
              kubernetes_namespace: namespace,
              polling_interval: 5_000
            ]
          ]
        ]

      "dns" ->
        dns_query = System.get_env("CLUSTER_DNS_QUERY", "serviceradar.local")
        node_basename = System.get_env("CLUSTER_NODE_BASENAME", "serviceradar")

        [
          serviceradar: [
            strategy: Cluster.Strategy.DNSPoll,
            config: [
              polling_interval: 5_000,
              query: dns_query,
              node_basename: node_basename
            ]
          ]
        ]

      "epmd" ->
        hosts_str = System.get_env("CLUSTER_HOSTS", "")

        hosts =
          hosts_str
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.map(&String.to_atom/1)

        if hosts != [] do
          [
            serviceradar: [
              strategy: Cluster.Strategy.Epmd,
              config: [hosts: hosts]
            ]
          ]
        else
          []
        end

      "gossip" ->
        gossip_port = String.to_integer(System.get_env("CLUSTER_GOSSIP_PORT", "45892"))
        gossip_secret = System.get_env("CLUSTER_GOSSIP_SECRET")

        if gossip_secret do
          [
            serviceradar: [
              strategy: Cluster.Strategy.Gossip,
              config: [
                port: gossip_port,
                if_addr: "0.0.0.0",
                multicast_addr: "230.1.1.1",
                multicast_ttl: 1,
                secret: gossip_secret
              ]
            ]
          ]
        else
          []
        end

      _ ->
        []
    end
  else
    []
  end

if topologies != [] do
  config :libcluster, topologies: topologies
end

# =============================================================================
# SPIFFE/mTLS Configuration
# =============================================================================
spiffe_mode =
  case System.get_env("SPIFFE_MODE", "filesystem") do
    "workload_api" -> :workload_api
    _ -> :filesystem
  end

config :serviceradar_core, :spiffe,
  mode: spiffe_mode,
  trust_domain: System.get_env("SPIFFE_TRUST_DOMAIN", "serviceradar.local"),
  cert_dir: System.get_env("SPIFFE_CERT_DIR", "/etc/serviceradar/certs"),
  workload_api_socket:
    System.get_env("SPIFFE_WORKLOAD_API_SOCKET", "unix:///run/spire/sockets/agent.sock")

config :serviceradar_core,
  mapper_topology_edge_stale_minutes:
    parse_int_env.("SERVICERADAR_MAPPER_TOPOLOGY_EDGE_STALE_MINUTES", 180)

if config_env() == :prod do
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

  # Core-elx is the cluster coordinator - it runs ClusterSupervisor and ClusterHealth
  cluster_coordinator =
    System.get_env("SERVICERADAR_CLUSTER_COORDINATOR", "true") in ~w(true 1 yes)

  config :serviceradar_core,
    env: :prod,
    cloak_key: cloak_key,
    repo_enabled: System.get_env("SERVICERADAR_CORE_REPO_ENABLED", "true") in ~w(true 1 yes),
    vault_enabled: System.get_env("SERVICERADAR_CORE_VAULT_ENABLED", "true") in ~w(true 1 yes),
    registries_enabled:
      System.get_env("SERVICERADAR_CORE_REGISTRIES_ENABLED", "true") in ~w(true 1 yes),
    run_startup_migrations:
      System.get_env("SERVICERADAR_CORE_RUN_MIGRATIONS", "false") in ~w(true 1 yes),
    cluster_enabled: cluster_enabled,
    cluster_coordinator: cluster_coordinator,
    # StatusHandler processes agent-gateway push results (sync ingestor, DIRE)
    status_handler_enabled: System.get_env("STATUS_HANDLER_ENABLED", "true") in ~w(true 1 yes)

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

  platform_sync_component_id =
    System.get_env("SERVICERADAR_PLATFORM_SYNC_COMPONENT_ID") || "platform-sync"

  config :serviceradar_core, :platform_sync_component_id, platform_sync_component_id

  age_graph_name =
    System.get_env("SERVICERADAR_AGE_GRAPH_NAME") ||
      System.get_env("AGE_GRAPH_NAME") ||
      "platform_graph"

  config :serviceradar_core, :age_graph_name, age_graph_name

  database_url = System.get_env("DATABASE_URL")

  cnpg_host = System.get_env("CNPG_HOST")
  cnpg_port = String.to_integer(System.get_env("CNPG_PORT", "5432"))
  cnpg_database = System.get_env("CNPG_DATABASE", "serviceradar")
  cnpg_username = System.get_env("CNPG_USERNAME", "serviceradar")

  cnpg_password =
    case System.get_env("CNPG_PASSWORD_FILE") do
      nil ->
        System.get_env("CNPG_PASSWORD", "serviceradar")

      path ->
        case File.read(path) do
          {:ok, value} ->
            value = String.trim(value)
            if value == "", do: System.get_env("CNPG_PASSWORD", "serviceradar"), else: value

          {:error, _} ->
            System.get_env("CNPG_PASSWORD", "serviceradar")
        end
    end

  cnpg_ssl_mode = System.get_env("CNPG_SSL_MODE", "disable")
  cnpg_ssl_enabled = cnpg_ssl_mode != "disable"
  cnpg_tls_server_name = System.get_env("CNPG_TLS_SERVER_NAME", cnpg_host || "")

  cnpg_cert_dir = System.get_env("CNPG_CERT_DIR", "")

  cnpg_ca_file =
    System.get_env(
      "CNPG_CA_FILE",
      if(cnpg_cert_dir != "", do: Path.join(cnpg_cert_dir, "root.pem"), else: "")
    )

  cnpg_cert_file =
    System.get_env(
      "CNPG_CERT_FILE",
      if(cnpg_cert_dir != "", do: Path.join(cnpg_cert_dir, "workstation.pem"), else: "")
    )

  cnpg_key_file =
    System.get_env(
      "CNPG_KEY_FILE",
      if(cnpg_cert_dir != "", do: Path.join(cnpg_cert_dir, "workstation-key.pem"), else: "")
    )

  cnpg_verify_peer = cnpg_ssl_mode in ~w(verify-ca verify-full)

  cnpg_ssl_opts =
    [verify: if(cnpg_verify_peer, do: :verify_peer, else: :verify_none)]
    |> then(fn opts ->
      if cnpg_verify_peer and cnpg_ca_file != "" do
        Keyword.put(opts, :cacertfile, cnpg_ca_file)
      else
        opts
      end
    end)
    |> then(fn opts ->
      if cnpg_cert_file != "" and cnpg_key_file != "" do
        opts
        |> Keyword.put(:certfile, cnpg_cert_file)
        |> Keyword.put(:keyfile, cnpg_key_file)
      else
        opts
      end
    end)
    |> then(fn opts ->
      if cnpg_ssl_mode == "verify-full" and cnpg_tls_server_name != "" do
        opts
        |> Keyword.put(:server_name_indication, String.to_charlist(cnpg_tls_server_name))
        |> Keyword.put(:customize_hostname_check,
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        )
      else
        opts
      end
    end)

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  repo_url =
    cond do
      database_url ->
        database_url

      cnpg_host ->
        "ecto://#{URI.encode_www_form(cnpg_username)}:#{URI.encode_www_form(cnpg_password)}@#{cnpg_host}:#{cnpg_port}/#{cnpg_database}"

      true ->
        raise """
        environment variable DATABASE_URL is missing.
        For example: ecto://USER:PASS@HOST/DATABASE
        """
    end

  config :serviceradar_core, ServiceRadar.Repo,
    url: repo_url,
    ssl: if(cnpg_ssl_enabled, do: cnpg_ssl_opts, else: false),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  oban_enabled = System.get_env("SERVICERADAR_CORE_OBAN_ENABLED", "true") in ~w(true 1 yes)
  oban_node = System.get_env("OBAN_NODE")

  periodic_job_stale_threshold_minutes =
    parse_int_env.("OBAN_PERIODIC_JOB_STALE_MINUTES", 240)

  alerts_retention_days = parse_int_env.("ALERT_RETENTION_DAYS", 3)
  alerts_retention_batch_size = parse_int_env.("ALERT_RETENTION_BATCH_SIZE", 10_000)
  alerts_retention_max_batches = parse_int_env.("ALERT_RETENTION_MAX_BATCHES", 100)

  config :serviceradar_core, ServiceRadar.Jobs.AlertsRetentionWorker,
    retention_days: alerts_retention_days,
    batch_size: alerts_retention_batch_size,
    max_batches: alerts_retention_max_batches

  # Enable AshOban scheduler - core-elx is the only service that should run schedulers
  ash_oban_scheduler_enabled =
    System.get_env("SERVICERADAR_ASH_OBAN_SCHEDULER_ENABLED", "true") in ~w(true 1 yes)

  oban_config = [
    engine: Oban.Engines.Basic,
    repo: ServiceRadar.Repo,
    prefix: "platform",
    queues: [
      default: String.to_integer(System.get_env("OBAN_QUEUE_DEFAULT") || "10"),
      maintenance: String.to_integer(System.get_env("OBAN_QUEUE_MAINTENANCE") || "2"),
      alerts: String.to_integer(System.get_env("OBAN_QUEUE_ALERTS") || "5"),
      monitoring: String.to_integer(System.get_env("OBAN_QUEUE_MONITORING") || "5"),
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
  ]

  oban_config =
    if oban_node do
      Keyword.put(oban_config, :node, oban_node)
    else
      oban_config
    end

  oban_config =
    if ash_oban_scheduler_enabled do
      domains = Application.get_env(:serviceradar_core, :ash_domains, [])
      AshOban.config(domains, oban_config)
    else
      oban_config
    end

  extra_cron_entries = [
    {"*/2 * * * *", ServiceRadar.Jobs.ReapStalePeriodicJobsWorker, queue: :maintenance},
    {"*/2 * * * *", ServiceRadar.Jobs.RefreshTraceSummariesWorker, queue: :maintenance},
    {"*/2 * * * *", ServiceRadar.Jobs.RefreshLogsSeverityStatsWorker, queue: :maintenance},
    {System.get_env("ALERT_RETENTION_CRON") || "15 * * * *",
     ServiceRadar.Jobs.AlertsRetentionWorker, queue: :maintenance}
  ]

  add_cron_entries = fn config, entries ->
    plugins =
      config
      |> Keyword.get(:plugins, [])
      |> Enum.map(fn
        {Oban.Plugins.Cron, opts} ->
          crontab = Keyword.get(opts, :crontab, [])
          {Oban.Plugins.Cron, Keyword.put(opts, :crontab, crontab ++ entries)}

        other ->
          other
      end)

    Keyword.put(config, :plugins, plugins)
  end

  oban_config = add_cron_entries.(oban_config, extra_cron_entries)

  config :serviceradar_core, :oban_enabled, oban_enabled

  config :serviceradar_core,
         :periodic_job_stale_threshold_minutes,
         periodic_job_stale_threshold_minutes

  config :serviceradar_core, Oban, if(oban_enabled, do: oban_config, else: false)

  config :serviceradar_core, :start_ash_oban_scheduler, ash_oban_scheduler_enabled

  local_mailer =
    case System.get_env("SERVICERADAR_LOCAL_MAILER") do
      "true" -> true
      "1" -> true
      "yes" -> true
      _ -> false
    end

  if local_mailer do
    config :swoosh, local: true
    config :serviceradar_core, ServiceRadar.Mailer, adapter: Swoosh.Adapters.Local
  else
    config :swoosh, :api_client, false
    config :swoosh, local: false
    config :serviceradar_core, ServiceRadar.Mailer, adapter: Swoosh.Adapters.Test
  end

  # NATS connection configuration (core publisher)
  nats_enabled = System.get_env("NATS_ENABLED", "false") in ~w(true 1 yes)

  if nats_enabled do
    nats_creds_file = System.get_env("NATS_CREDS_FILE")

    if nats_creds_file in [nil, ""] do
      raise """
      NATS_CREDS_FILE is required when NATS_ENABLED=true.
      Generate or provision JWT credentials and set NATS_CREDS_FILE.
      """
    end

    nats_url = System.get_env("NATS_URL", "nats://localhost:4222")
    nats_uri = URI.parse(nats_url)

    nats_tls_enabled = System.get_env("NATS_TLS", "false") in ~w(true 1 yes)
    cert_dir = System.get_env("SPIFFE_CERT_DIR", "/etc/serviceradar/certs")
    nats_server_name = System.get_env("NATS_SERVER_NAME", "nats.serviceradar")

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
  end

  # EventWriter configuration (NATS JetStream → CNPG consumer)
  event_writer_enabled = System.get_env("EVENT_WRITER_ENABLED", "false") in ~w(true 1 yes)

  if event_writer_enabled do
    event_writer_creds = System.get_env("EVENT_WRITER_NATS_CREDS_FILE")

    if event_writer_creds in [nil, ""] do
      IO.puts("[EventWriter] No NATS creds file set; connecting without JWT auth")
    end

    nats_url = System.get_env("EVENT_WRITER_NATS_URL", "nats://localhost:4222")
    nats_uri = URI.parse(nats_url)

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
          stream_name: "events",
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
          name: "TRIVY",
          stream_name: "trivy_reports",
          subject: "trivy.report.>",
          processor: ServiceRadar.EventWriter.Processors.TrivyReports,
          batch_size: 100,
          batch_timeout: 1_000
        },
        %{
          name: "OTEL_METRICS",
          stream_name: "events",
          subject: "otel.metrics.>",
          processor: ServiceRadar.EventWriter.Processors.OtelMetrics,
          batch_size: 100,
          batch_timeout: 1_000
        },
        %{
          name: "OTEL_TRACES",
          stream_name: "events",
          subject: "otel.traces.>",
          processor: ServiceRadar.EventWriter.Processors.OtelTraces,
          batch_size: 100,
          batch_timeout: 1_000
        },
        %{
          name: "BMP_CAUSAL",
          stream_name: "events",
          subject: "bmp.events.>",
          processor: ServiceRadar.EventWriter.Processors.CausalSignals,
          batch_size: 100,
          batch_timeout: 1_000
        },
        %{
          name: "ARANCINI_CAUSAL",
          stream_name: "ARANCINI_CAUSAL",
          subject: "arancini.updates.>",
          processor: ServiceRadar.EventWriter.Processors.CausalSignals,
          batch_size: 100,
          batch_timeout: 1_000
        },
        %{
          name: "SIEM_CAUSAL",
          stream_name: "events",
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
