import Config

alias Geolix.Adapter.MMDB2
alias Oban.Plugins.Cron
alias ServiceRadar.Automation.Ansible.FileCallbackResponsePolicyProvider
alias ServiceRadar.Automation.CallbackGrants.RuntimeConfig
alias ServiceRadar.EventWriter.Processors.AnalyticsSignals
alias ServiceRadar.EventWriter.Processors.Flows
alias ServiceRadar.Jobs.AlertsRetentionWorker
alias ServiceRadar.Jobs.RefreshTraceSummariesWorker
alias ServiceRadar.Observability.CapacityForecasting.Worker, as: CapacityForecastingWorker
alias ServiceRadar.Observability.DataRetentionWorker
alias ServiceRadar.Observability.ProductionSchedule
alias ServiceRadar.Observability.SeasonalDisposition.Worker, as: SeasonalDispositionWorker

callback_deployment =
  RuntimeConfig.callback_deployment_config!(%{
    enabled: System.get_env("SERVICERADAR_AUTOMATION_CALLBACKS_ENABLED", "false"),
    credential_type_id: System.get_env("SERVICERADAR_AUTOMATION_CALLBACK_AWX_CREDENTIAL_TYPE_ID"),
    organization_id: System.get_env("SERVICERADAR_AUTOMATION_CALLBACK_AWX_ORGANIZATION_ID"),
    injector_digest: System.get_env("SERVICERADAR_AUTOMATION_CALLBACK_AWX_INJECTOR_DIGEST"),
    response_policy_file: System.get_env("SERVICERADAR_AUTOMATION_CALLBACK_RESPONSE_POLICY_FILE")
  })

# This release hosts callback result coordination and recovery from
# serviceradar_core. Those internal continuations use persisted authority and
# must never receive the web tier's bearer HMAC keyring.
config :serviceradar_core, :automation_callback_grants, []

if is_map(callback_deployment) do
  envelope_key =
    "SERVICERADAR_AUTOMATION_CALLBACK_ENVELOPE_KEY_FILE"
    |> System.get_env()
    |> RuntimeConfig.load_envelope_key_file!()

  config :serviceradar_core,
         FileCallbackResponsePolicyProvider,
         callback_deployment.response_policy_provider_config

  config :serviceradar_core,
         :automation_callback_awx_credential_contract,
         callback_deployment.credential_contract

  config :serviceradar_core,
         :automation_callback_response_policy_provider,
         callback_deployment.response_policy_provider

  config :serviceradar_core,
    automation_launch_envelope_key: envelope_key,
    automation_launch_envelope_key_id: System.get_env("SERVICERADAR_AUTOMATION_CALLBACK_ENVELOPE_KEY_ID", "current")
end

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

read_secret_env = fn env_name, file_env_name ->
  case System.get_env(env_name) do
    nil ->
      case System.get_env(file_env_name) do
        nil -> nil
        "" -> nil
        path -> path |> File.read!() |> String.trim()
      end

    "" ->
      nil

    value ->
      value
  end
end

# =============================================================================
# Logger level override
# =============================================================================
# Production defaults to :info (see prod.exs); the hot-path per-message logs are
# Logger.debug, so :info keeps useful breadcrumbs without the self-telemetry
# storm. Operators tune verbosity at runtime via SERVICERADAR_LOG_LEVEL — e.g.
# =debug to surface the hot-path traces, =warning to quiet it. Invalid values
# fall back to :info rather than crashing boot.
if config_env() == :prod do
  log_level =
    case System.get_env("SERVICERADAR_LOG_LEVEL") do
      value when is_binary(value) and value != "" ->
        case String.downcase(value) do
          level when level in ~w(emergency alert critical error warning notice info debug) ->
            String.to_existing_atom(level)

          _ ->
            :info
        end

      _ ->
        :info
    end

  config :logger, level: log_level
end

edge_crypto_secret =
  read_secret_env.("SERVICERADAR_EDGE_CRYPTO_SECRET", "SERVICERADAR_EDGE_CRYPTO_SECRET_FILE") ||
    read_secret_env.("EDGE_ONBOARDING_ENCRYPTION_KEY", "EDGE_ONBOARDING_ENCRYPTION_KEY_FILE")

if is_binary(edge_crypto_secret) and String.trim(edge_crypto_secret) != "" do
  config :serviceradar_core, :crypto_secret, String.trim(edge_crypto_secret)
end

netflow_security_refresh_reschedule_seconds =
  "NETFLOW_SECURITY_REFRESH_INTERVAL_SECONDS"
  |> System.get_env()
  |> case do
    nil -> 86_400
    "" -> 86_400
    _ -> max(parse_int_env.("NETFLOW_SECURITY_REFRESH_INTERVAL_SECONDS", 86_400), 86_400)
  end

netflow_security_refresh_cache_ttl_seconds =
  "NETFLOW_SECURITY_REFRESH_CACHE_TTL_SECONDS"
  |> System.get_env()
  |> case do
    nil ->
      netflow_security_refresh_reschedule_seconds

    "" ->
      netflow_security_refresh_reschedule_seconds

    _ ->
      parse_int_env.(
        "NETFLOW_SECURITY_REFRESH_CACHE_TTL_SECONDS",
        netflow_security_refresh_reschedule_seconds
      )
  end

# =============================================================================
# OpenTelemetry Configuration
# =============================================================================
# All OTEL exporter config MUST live here — runtime.exs runs before OTP apps
# start, so the opentelemetry SDK picks up these values at boot.
otel_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")

config :serviceradar_core, ServiceRadar.Observability.NetflowSecurityRefreshWorker,
  reschedule_seconds: netflow_security_refresh_reschedule_seconds,
  cache_ttl_seconds: netflow_security_refresh_cache_ttl_seconds

if otel_endpoint do
  ssl_opts = ServiceRadar.Telemetry.OtelSetup.ssl_options()
  otel_rpc_timeout_ms = parse_int_env.("OTEL_EXPORTER_OTLP_TIMEOUT_MS", 30_000)
  otel_retry_max_attempts = parse_int_env.("OTEL_EXPORTER_OTLP_RETRY_MAX_ATTEMPTS", 3)
  otel_retry_base_delay_ms = parse_int_env.("OTEL_EXPORTER_OTLP_RETRY_BASE_DELAY_MS", 500)
  otel_retry_max_delay_ms = parse_int_env.("OTEL_EXPORTER_OTLP_RETRY_MAX_DELAY_MS", 10_000)

  # Root sampling ratio for internally-rooted spans (Ecto self-writes, Oban
  # housekeeping, EventWriter batches, re-ingested self-telemetry). The SDK
  # default sampler is parent_based{root: always_on}, which exports 100% of
  # these and drives a self-ingestion feedback loop (export -> collector ->
  # NATS -> EventWriter -> CNPG -> fresh Ecto spans -> export ...). Sampling
  # the root decision down to ~5% breaks that amplifier while remote-parented
  # spans (real cross-service traffic) are always kept. Tunable via
  # OTEL_TRACES_SAMPLER_ARG without a rebuild; bad values fall back to 0.05.
  otel_root_sample_ratio =
    case System.get_env("OTEL_TRACES_SAMPLER_ARG") do
      value when is_binary(value) and value != "" ->
        case Float.parse(value) do
          {ratio, _rest} when ratio >= 0.0 and ratio <= 1.0 -> ratio
          _ -> 0.05
        end

      _ ->
        0.05
    end

  config :opentelemetry,
    span_processor: :batch,
    # Keep real cross-service traces (remote-parented) while thinning
    # internally-rooted self-telemetry spans to OTEL_TRACES_SAMPLER_ARG.
    sampler:
      {:parent_based,
       %{
         root: {:trace_id_ratio_based, otel_root_sample_ratio},
         remote_parent_sampled: :always_on,
         remote_parent_not_sampled: :always_off,
         local_parent_sampled: :always_on,
         local_parent_not_sampled: :always_off
       }},
    traces_exporter:
      {:serviceradar_otel_exporter_traces_otlp,
       %{
         rpc_timeout_ms: otel_rpc_timeout_ms,
         retry_max_attempts: otel_retry_max_attempts,
         retry_base_delay_ms: otel_retry_base_delay_ms,
         retry_max_delay_ms: otel_retry_max_delay_ms
       }}

  # Log exporter uses the same endpoint/protocol/TLS as traces
  config :opentelemetry_experimental,
    otlp_protocol: :grpc,
    otlp_endpoint: otel_endpoint,
    ssl_options: ssl_opts

  config :opentelemetry_exporter,
    otlp_protocol: :grpc,
    # No endpoint configured — disable export to avoid connection errors
    otlp_endpoint: otel_endpoint,
    ssl_options: ssl_opts
else
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
  "GEOLITE_CITY_ENABLED"
  |> System.get_env("false")
  |> String.downcase()
  |> Kernel.in(["1", "true", "yes", "on"])

base_geolite_dbs = [
  %{
    id: :geolite2_asn,
    adapter: MMDB2,
    source: Path.join(geolite_dir, "GeoLite2-ASN.mmdb")
  },
  %{
    id: :geolite2_country,
    adapter: MMDB2,
    source: Path.join(geolite_dir, "GeoLite2-Country.mmdb")
  }
]

city_geolite_dbs =
  (geolite_city_enabled &&
     [
       %{
         id: :geolite2_city,
         adapter: MMDB2,
         source: Path.join(geolite_dir, "GeoLite2-City.mmdb")
       }
     ]) || []

ipinfo_dbs = [
  %{
    id: :ipinfo_lite,
    adapter: MMDB2,
    source: Path.join(geolite_dir, "ipinfo_lite.mmdb")
  }
]

# =============================================================================
# Cluster Configuration
# =============================================================================
hosted_cluster_contract =
  case System.get_env("SERVICERADAR_HOSTED_CLUSTER_CONTRACT") do
    nil ->
      %{}

    raw ->
      case Jason.decode(raw) do
        {:ok, contract} when is_map(contract) -> contract
        _ -> %{}
      end
  end

cluster_strategy =
  get_in(hosted_cluster_contract, ["strategy"]) ||
    "CLUSTER_STRATEGY"
    |> System.get_env("epmd")
    |> String.downcase()

cluster_enabled =
  case get_in(hosted_cluster_contract, ["enabled"]) do
    value when is_boolean(value) -> value
    _ -> System.get_env("CLUSTER_ENABLED", "true") in ~w(true 1 yes)
  end

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
        dns_query =
          get_in(hosted_cluster_contract, ["core", "dns_query"]) ||
            System.get_env("CLUSTER_DNS_QUERY", "serviceradar.local")

        node_basename =
          get_in(hosted_cluster_contract, ["core", "node_basename"]) ||
            System.get_env("CLUSTER_NODE_BASENAME", "serviceradar")

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

        # libcluster's Epmd strategy requires node-NAME atoms, and deployment-specific
        # hostnames have no pre-known whitelist, so `String.to_existing_atom` is not an
        # option here. CLUSTER_HOSTS is trusted operator config, but bound the atom
        # creation regardless: drop blanks/dupes and cap the count so a malformed env var
        # can never grow the atom table without bound.
        hosts =
          hosts_str
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()
          |> Enum.take(256)
          |> Enum.map(&String.to_atom/1)

        if hosts == [] do
          []
        else
          [
            serviceradar: [
              strategy: Cluster.Strategy.Epmd,
              config: [hosts: hosts]
            ]
          ]
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

config :geolix, databases: base_geolite_dbs ++ city_geolite_dbs ++ ipinfo_dbs

config :serviceradar_core,
  geolite_mmdb_dir: geolite_dir

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
  workload_api_socket: System.get_env("SPIFFE_WORKLOAD_API_SOCKET", "unix:///run/spire/sockets/agent.sock")

config :serviceradar_core,
  mapper_topology_edge_stale_minutes: parse_int_env.("SERVICERADAR_MAPPER_TOPOLOGY_EDGE_STALE_MINUTES", 180)

# Keep authenticated desktop viewers and ingress actors bounded. These are
# deliberately runtime-tunable so operators can size the media plane without
# weakening owner-bound authorization.
config :serviceradar_core_elx,
  remote_desktop_webrtc_max_viewers_per_session:
    max(parse_int_env.("SERVICERADAR_REMOTE_ACCESS_DESKTOP_WEBRTC_MAX_VIEWERS_PER_SESSION", 2), 1),
  remote_desktop_webrtc_max_viewers_per_actor:
    max(parse_int_env.("SERVICERADAR_REMOTE_ACCESS_DESKTOP_WEBRTC_MAX_VIEWERS_PER_ACTOR", 4), 1),
  remote_desktop_webrtc_max_viewers_global:
    max(parse_int_env.("SERVICERADAR_REMOTE_ACCESS_DESKTOP_WEBRTC_MAX_VIEWERS_GLOBAL", 64), 1),
  remote_desktop_media_ingress_idle_timeout_ms:
    max(parse_int_env.("SERVICERADAR_REMOTE_ACCESS_DESKTOP_INGRESS_IDLE_TIMEOUT_MS", 60_000), 1_000)

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
      case read_secret_env.("PLUGIN_STORAGE_SIGNING_SECRET", "PLUGIN_STORAGE_SIGNING_SECRET_FILE") do
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

  config :serviceradar_core,
    env: :prod,
    cloak_key: cloak_key,
    repo_enabled: System.get_env("SERVICERADAR_CORE_REPO_ENABLED", "true") in ~w(true 1 yes),
    control_repo_enabled: System.get_env("CONTROL_REPO_ENABLED", "true") in ~w(true 1 yes),
    vault_enabled: System.get_env("SERVICERADAR_CORE_VAULT_ENABLED", "true") in ~w(true 1 yes),
    registries_enabled: System.get_env("SERVICERADAR_CORE_REGISTRIES_ENABLED", "true") in ~w(true 1 yes),
    run_startup_migrations: System.get_env("SERVICERADAR_CORE_RUN_MIGRATIONS", "false") in ~w(true 1 yes),
    cluster_enabled: cluster_enabled,
    cluster_coordinator: cluster_coordinator,
    # StatusHandler processes agent-gateway push results (sync ingestor, DIRE)
    status_handler_enabled: System.get_env("STATUS_HANDLER_ENABLED", "true") in ~w(true 1 yes)

  config :serviceradar_core_elx, :metrics,
    enabled: System.get_env("SERVICERADAR_CORE_METRICS_ENABLED", "true") in ~w(true 1 yes),
    ip: {0, 0, 0, 0},
    port: parse_int_env.("SERVICERADAR_CORE_METRICS_PORT", 9090)

  if plugin_storage_overrides != [] do
    config :serviceradar_core,
           :plugin_storage,
           Keyword.merge(plugin_storage_defaults, plugin_storage_overrides)
  end

  platform_sync_component_id =
    System.get_env("SERVICERADAR_PLATFORM_SYNC_COMPONENT_ID") || "platform-sync"

  age_graph_name =
    System.get_env("SERVICERADAR_AGE_GRAPH_NAME") ||
      System.get_env("AGE_GRAPH_NAME") ||
      "platform_graph"

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
      if(cnpg_cert_dir == "", do: "", else: Path.join(cnpg_cert_dir, "root.pem"))
    )

  cnpg_cert_file =
    System.get_env(
      "CNPG_CERT_FILE",
      if(cnpg_cert_dir == "", do: "", else: Path.join(cnpg_cert_dir, "workstation.pem"))
    )

  cnpg_key_file =
    System.get_env(
      "CNPG_KEY_FILE",
      if(cnpg_cert_dir == "", do: "", else: Path.join(cnpg_cert_dir, "workstation-key.pem"))
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

  parse_optional_int_env = fn env_name ->
    case System.get_env(env_name) do
      nil ->
        nil

      "" ->
        nil

      value ->
        case Integer.parse(value) do
          {int, ""} -> int
          _ -> raise "invalid integer for #{env_name}: #{inspect(value)}"
        end
    end
  end

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

  pool_size = parse_int_env.("POOL_SIZE", 10)
  search_path = System.get_env("CNPG_SEARCH_PATH", "platform, public, ag_catalog")

  database_timeout = parse_optional_int_env.("DATABASE_TIMEOUT_MS")
  database_pool_timeout = parse_optional_int_env.("DATABASE_POOL_TIMEOUT_MS")
  queue_target = parse_optional_int_env.("DATABASE_QUEUE_TARGET_MS")
  queue_interval = parse_optional_int_env.("DATABASE_QUEUE_INTERVAL_MS")

  database_prepare =
    case System.get_env("DATABASE_PREPARE", "") do
      "unnamed" -> :unnamed
      "named" -> :named
      _ -> nil
    end

  repo_opts =
    [
      url: repo_url,
      ssl: if(cnpg_ssl_enabled, do: cnpg_ssl_opts, else: false),
      pool_size: pool_size,
      socket_options: maybe_ipv6,
      parameters: [search_path: search_path],
      types: ServiceRadar.PostgresTypes
    ]
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
    |> then(fn opts ->
      if database_prepare, do: Keyword.put(opts, :prepare, database_prepare), else: opts
    end)

  control_repo_pool_size = parse_int_env.("CONTROL_REPO_POOL_SIZE", 5)

  control_repo_queue_target =
    parse_optional_int_env.("CONTROL_DATABASE_QUEUE_TARGET_MS") || queue_target

  control_repo_queue_interval =
    parse_optional_int_env.("CONTROL_DATABASE_QUEUE_INTERVAL_MS") || queue_interval

  control_repo_timeout =
    parse_optional_int_env.("CONTROL_DATABASE_TIMEOUT_MS") || database_timeout

  control_repo_pool_timeout =
    parse_optional_int_env.("CONTROL_DATABASE_POOL_TIMEOUT_MS") || database_pool_timeout

  control_repo_opts =
    repo_opts
    |> Keyword.put(:pool_size, control_repo_pool_size)
    |> then(fn opts ->
      if control_repo_queue_target,
        do: Keyword.put(opts, :queue_target, control_repo_queue_target),
        else: opts
    end)
    |> then(fn opts ->
      if control_repo_queue_interval,
        do: Keyword.put(opts, :queue_interval, control_repo_queue_interval),
        else: opts
    end)
    |> then(fn opts ->
      if control_repo_timeout, do: Keyword.put(opts, :timeout, control_repo_timeout), else: opts
    end)
    |> then(fn opts ->
      if control_repo_pool_timeout,
        do: Keyword.put(opts, :pool_timeout, control_repo_pool_timeout),
        else: opts
    end)

  oban_enabled = System.get_env("SERVICERADAR_CORE_OBAN_ENABLED", "true") in ~w(true 1 yes)
  oban_node = System.get_env("OBAN_NODE")

  oban_notifier =
    case "OBAN_NOTIFIER" |> System.get_env("postgres") |> String.downcase() do
      value when value in ["pg", "process_group", "process-groups"] -> Oban.Notifiers.PG
      _ -> Oban.Notifiers.Postgres
    end

  periodic_job_stale_threshold_minutes =
    parse_int_env.("OBAN_PERIODIC_JOB_STALE_MINUTES", 240)

  alerts_retention_days = parse_int_env.("ALERT_RETENTION_DAYS", 3)
  alerts_retention_batch_size = parse_int_env.("ALERT_RETENTION_BATCH_SIZE", 10_000)
  alerts_retention_max_batches = parse_int_env.("ALERT_RETENTION_MAX_BATCHES", 100)

  observability_retention_batch_size =
    "SERVICERADAR_OBSERVABILITY_RETENTION_BATCH_SIZE" |> parse_int_env.(50_000) |> max(1)

  trace_summary_retention_days =
    "SERVICERADAR_TRACE_SUMMARY_RETENTION_DAYS" |> parse_int_env.(3) |> max(1)

  otel_traces_retention_days =
    "SERVICERADAR_OTEL_TRACES_RETENTION_DAYS" |> parse_int_env.(3) |> max(1)

  logs_retention_days = "SERVICERADAR_LOGS_RETENTION_DAYS" |> parse_int_env.(30) |> max(1)

  ocsf_network_activity_retention_days =
    "SERVICERADAR_OCSF_NETWORK_ACTIVITY_RETENTION_DAYS" |> parse_int_env.(90) |> max(1)

  otel_traces_chunk_interval_hours =
    "SERVICERADAR_OTEL_TRACES_CHUNK_INTERVAL_HOURS" |> parse_int_env.(6) |> max(1)

  logs_chunk_interval_hours =
    "SERVICERADAR_LOGS_CHUNK_INTERVAL_HOURS" |> parse_int_env.(24) |> max(1)

  ocsf_network_activity_chunk_interval_hours =
    "SERVICERADAR_OCSF_NETWORK_ACTIVITY_CHUNK_INTERVAL_HOURS" |> parse_int_env.(24) |> max(1)

  flow_attribution_retention_minutes =
    "SERVICERADAR_FLOW_ATTRIBUTION_RETENTION_MINUTES" |> parse_int_env.(60) |> max(15)

  # Enable AshOban scheduler - core-elx is the only service that should run schedulers
  ash_oban_scheduler_enabled =
    System.get_env("SERVICERADAR_ASH_OBAN_SCHEDULER_ENABLED", "true") in ~w(true 1 yes)

  capacity_forecasting_enabled =
    "SERVICERADAR_CAPACITY_FORECASTING_ENABLED"
    |> System.get_env("true")
    |> String.downcase()
    |> Kernel.in(["1", "true", "yes", "on"])

  capacity_forecasting_cron =
    System.get_env("SERVICERADAR_CAPACITY_FORECASTING_CRON", "41 * * * *")

  capacity_forecasting_horizon_seconds =
    "SERVICERADAR_CAPACITY_FORECASTING_HORIZON_SECONDS"
    |> System.get_env("7776000")
    |> String.to_integer()

  capacity_forecasting_warning_horizon_seconds =
    "SERVICERADAR_CAPACITY_FORECASTING_WARNING_HORIZON_SECONDS"
    |> System.get_env(Integer.to_string(capacity_forecasting_horizon_seconds))
    |> String.to_integer()

  capacity_forecasting_emit_verdicts =
    "SERVICERADAR_CAPACITY_FORECASTING_EMIT_VERDICTS"
    |> System.get_env("true")
    |> String.downcase()
    |> Kernel.in(["1", "true", "yes", "on"])

  capacity_forecasting_crontab =
    if capacity_forecasting_enabled do
      [
        {capacity_forecasting_cron, CapacityForecastingWorker, args: %{"trigger" => "cron"}, queue: :maintenance}
      ]
    else
      []
    end

  oban_config = [
    engine: Oban.Engines.Basic,
    repo: ServiceRadar.Repo,
    prefix: "platform",
    notifier: oban_notifier,
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
      nats_accounts: String.to_integer(System.get_env("OBAN_QUEUE_NATS_ACCOUNTS") || "3"),
      # Ansible automation queues: catalog sync (AWX job templates + git
      # playbook repositories), run pulse/health/watchdog, and retention. The
      # workers declared these queues but no release configured them, so every
      # ansible job sat `available` forever and runs never advanced.
      ansible_catalog: String.to_integer(System.get_env("OBAN_QUEUE_ANSIBLE_CATALOG") || "4"),
      ansible_pulse: String.to_integer(System.get_env("OBAN_QUEUE_ANSIBLE_PULSE") || "4"),
      ansible_retention: String.to_integer(System.get_env("OBAN_QUEUE_ANSIBLE_RETENTION") || "1")
    ],
    plugins: [
      Oban.Plugins.Pruner,
      {Cron, crontab: []}
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

  extra_cron_entries =
    [
      {"*/2 * * * *", ServiceRadar.Jobs.ReapStalePeriodicJobsWorker, queue: :maintenance},
      {System.get_env("TRACE_SUMMARIES_REFRESH_CRON") || "*/2 * * * *", RefreshTraceSummariesWorker, queue: :maintenance},
      {"*/2 * * * *", ServiceRadar.Jobs.RefreshLogsSeverityStatsWorker, queue: :maintenance},
      {System.get_env("SERVICERADAR_OBSERVABILITY_RETENTION_CRON") || "17 3 * * *", DataRetentionWorker,
       queue: :maintenance},
      {System.get_env("ALERT_RETENTION_CRON") || "15 * * * *", AlertsRetentionWorker, queue: :maintenance}
    ] ++ capacity_forecasting_crontab ++ ProductionSchedule.cron_entries()

  add_cron_entries = fn config, entries ->
    plugins =
      config
      |> Keyword.get(:plugins, [])
      |> Enum.map(fn
        {Cron, opts} ->
          crontab = Keyword.get(opts, :crontab, [])
          {Cron, Keyword.put(opts, :crontab, crontab ++ entries)}

        other ->
          other
      end)

    Keyword.put(config, :plugins, plugins)
  end

  oban_config = add_cron_entries.(oban_config, extra_cron_entries)

  local_mailer =
    case System.get_env("SERVICERADAR_LOCAL_MAILER") do
      "true" -> true
      "1" -> true
      "yes" -> true
      _ -> false
    end

  config :serviceradar_core, AlertsRetentionWorker,
    retention_days: alerts_retention_days,
    batch_size: alerts_retention_batch_size,
    max_batches: alerts_retention_max_batches

  config :serviceradar_core, CapacityForecastingWorker,
    enabled: capacity_forecasting_enabled,
    horizon_seconds: capacity_forecasting_horizon_seconds,
    warning_horizon_seconds: capacity_forecasting_warning_horizon_seconds,
    emit_verdicts?: capacity_forecasting_emit_verdicts,
    min_points: "SERVICERADAR_CAPACITY_FORECASTING_MIN_POINTS" |> parse_int_env.(24) |> max(1),
    seasonal_period: "SERVICERADAR_CAPACITY_FORECASTING_SEASONAL_PERIOD" |> parse_int_env.(24) |> max(1),
    # Comma-separated source names; the worker validates against the known
    # source list at run time. A non-empty Settings value overrides this.
    default_source_opt_ins: ProductionSchedule.capacity_source_opt_ins()

  config :serviceradar_core, DataRetentionWorker,
    batch_size: observability_retention_batch_size,
    trace_summary_retention_days: trace_summary_retention_days,
    otel_traces_retention_days: otel_traces_retention_days,
    logs_retention_days: logs_retention_days,
    ocsf_network_activity_retention_days: ocsf_network_activity_retention_days,
    otel_traces_chunk_interval_hours: otel_traces_chunk_interval_hours,
    logs_chunk_interval_hours: logs_chunk_interval_hours,
    ocsf_network_activity_chunk_interval_hours: ocsf_network_activity_chunk_interval_hours,
    sweep_host_result_retention_days: "SERVICERADAR_SWEEP_HOST_RESULT_RETENTION_DAYS" |> parse_int_env.(7) |> max(1),
    sweep_execution_retention_days: "SERVICERADAR_SWEEP_EXECUTION_RETENTION_DAYS" |> parse_int_env.(30) |> max(1),
    trivy_retention_days: "SERVICERADAR_TRIVY_RETENTION_DAYS" |> parse_int_env.(30) |> max(1),
    endpoint_inventory_retention_days: "SERVICERADAR_ENDPOINT_INVENTORY_RETENTION_DAYS" |> parse_int_env.(30) |> max(1),
    dataset_snapshot_retention_days: "SERVICERADAR_DATASET_SNAPSHOT_RETENTION_DAYS" |> parse_int_env.(14) |> max(1),
    topology_link_retention_days: "SERVICERADAR_TOPOLOGY_LINK_RETENTION_DAYS" |> parse_int_env.(30) |> max(1)

  config :serviceradar_core, Oban, if(oban_enabled, do: oban_config, else: false)
  config :serviceradar_core, RefreshTraceSummariesWorker, retention_days: trace_summary_retention_days
  config :serviceradar_core, SeasonalDispositionWorker, ProductionSchedule.seasonal_disposition_worker_config()
  config :serviceradar_core, ServiceRadar.ControlRepo, control_repo_opts
  config :serviceradar_core, ServiceRadar.FlowAttribution, retention_minutes: flow_attribution_retention_minutes
  config :serviceradar_core, ServiceRadar.Repo, repo_opts
  config :serviceradar_core, :age_graph_name, age_graph_name
  config :serviceradar_core, :oban_enabled, oban_enabled

  config :serviceradar_core,
         :periodic_job_stale_threshold_minutes,
         periodic_job_stale_threshold_minutes

  config :serviceradar_core, :platform_sync_component_id, platform_sync_component_id
  config :serviceradar_core, :start_ash_oban_scheduler, ash_oban_scheduler_enabled

  # Operator-set stale thresholds for the scheduled anomaly workers; the
  # worker modules' own defaults apply when unset.
  for {key, value} <- ProductionSchedule.app_env() do
    config :serviceradar_core, key, value
  end

  if local_mailer do
    config :serviceradar_core, ServiceRadar.Mailer, adapter: Swoosh.Adapters.Local

    config :swoosh, local: true
  else
    config :serviceradar_core, ServiceRadar.Mailer, adapter: Swoosh.Adapters.Test

    config :swoosh, :api_client, false

    # NATS connection configuration (core publisher)
    config :swoosh, local: false
  end

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

  host_slice_subscriber_enabled =
    System.get_env("EVENT_WRITER_HOST_SLICE_SUBSCRIBER_ENABLED", "false") in ~w(true 1 yes)

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
      consumer_pull_batch_size: String.to_integer(System.get_env("EVENT_WRITER_CONSUMER_PULL_BATCH_SIZE") || "16"),
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
          name: "PDNS_OCSF",
          stream_name: "events",
          subject: "pdns.ocsf",
          processor: ServiceRadar.EventWriter.Processors.PowerDNS,
          batch_size: 100,
          batch_timeout: 1_000
        },
        %{
          name: "FALCO",
          # Align with the serviceradar_core tree + Config.default_streams/0:
          # no deployment provisions a `falco_events` stream / `falco.>`
          # subject (the mismatch produced constant 404 polls on demo); the
          # working definition rides the shared `events` stream.
          stream_name: "events",
          subject: "falco.logs",
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
          name: "LOGS",
          stream_name: "events",
          subject: "logs.>",
          processor: ServiceRadar.EventWriter.Processors.Logs,
          batch_size: 100,
          batch_timeout: 1_000
        },
        %{
          name: "METRICS",
          stream_name: "metrics",
          subject: "metrics.>",
          processor: ServiceRadar.EventWriter.Processors.Metrics,
          batch_size: 500,
          batch_timeout: 500,
          stream_retention: "limits",
          stream_storage: "file",
          stream_discard: "old",
          stream_max_bytes: 1_073_741_824,
          stream_max_age: 1_800_000_000_000,
          consumer_pull_batch_size: 4,
          consumer_max_deliver: -1
        },
        %{
          name: "BMP_CAUSAL",
          stream_name: "events",
          subject: "bmp.events.>",
          processor: AnalyticsSignals,
          batch_size: 100,
          batch_timeout: 1_000
        },
        %{
          name: "ARANCINI_CAUSAL",
          stream_name: "ARANCINI_CAUSAL",
          subject: "arancini.updates.>",
          processor: AnalyticsSignals,
          batch_size: 100,
          batch_timeout: 1_000
        },
        %{
          name: "SIEM_CAUSAL",
          stream_name: "events",
          subject: "siem.events.>",
          processor: AnalyticsSignals,
          batch_size: 100,
          batch_timeout: 1_000
        },
        # Dedicated anomaly/capacity verdict stream (restore-anomaly-alerting
        # design D9); definition shared with Config.default_streams/0 so the
        # retention stanza cannot drift.
        ServiceRadar.EventWriter.Config.analytics_predictions_stream(),
        %{
          name: "SFLOW_RAW",
          subject: "flows.raw.sflow",
          processor: Flows,
          batch_size: 50,
          batch_timeout: 500
        },
        %{
          name: "NETFLOW_RAW",
          subject: "flows.raw.netflow",
          processor: Flows,
          batch_size: 50,
          batch_timeout: 500
        },
        %{
          name: "ATTRIBUTED_FLOW",
          subject: "flow.attributed.>",
          processor: Flows,
          batch_size: 50,
          batch_timeout: 500
        }
      ]

    config :serviceradar_core, :event_writer_enabled, true
    config :serviceradar_core, :host_slice_subscriber_enabled, host_slice_subscriber_enabled
  end
end
