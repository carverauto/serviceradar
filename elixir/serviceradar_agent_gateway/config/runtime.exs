import Config

# This file is executed at runtime before the application starts.
# It is executed in both release and dev/test modes.

alias Cluster.Strategy.DNSPoll
alias ServiceRadar.NATS.Connection

parse_int_env = fn env_name, default ->
  case System.get_env(env_name) do
    nil ->
      default

    "" ->
      default

    value ->
      case Integer.parse(value) do
        {int, ""} when int > 0 -> int
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

edge_crypto_secret =
  read_secret_env.("SERVICERADAR_EDGE_CRYPTO_SECRET", "SERVICERADAR_EDGE_CRYPTO_SECRET_FILE") ||
    read_secret_env.("EDGE_ONBOARDING_ENCRYPTION_KEY", "EDGE_ONBOARDING_ENCRYPTION_KEY_FILE")

if is_binary(edge_crypto_secret) and String.trim(edge_crypto_secret) != "" do
  config :serviceradar_core, :crypto_secret, String.trim(edge_crypto_secret)
end

plugin_storage_defaults = Application.get_env(:serviceradar_core, :plugin_storage, [])

plugin_storage_overrides =
  []
  |> then(fn acc ->
    case System.get_env("PLUGIN_STORAGE_PUBLIC_URL") do
      nil -> acc
      "" -> acc
      value -> Keyword.put(acc, :public_url, String.trim(value))
    end
  end)
  |> then(fn acc ->
    case read_secret_env.("PLUGIN_STORAGE_SIGNING_SECRET", "PLUGIN_STORAGE_SIGNING_SECRET_FILE") do
      nil -> acc
      "" -> acc
      value -> Keyword.put(acc, :signing_secret, String.trim(value))
    end
  end)
  |> then(fn acc ->
    case System.get_env("PLUGIN_STORAGE_DOWNLOAD_TTL_SECONDS") do
      nil ->
        acc

      "" ->
        acc

      _value ->
        Keyword.put(
          acc,
          :download_ttl_seconds,
          parse_int_env.("PLUGIN_STORAGE_DOWNLOAD_TTL_SECONDS", 86_400)
        )
    end
  end)

if plugin_storage_overrides != [] do
  config :serviceradar_core,
         :plugin_storage,
         Keyword.merge(plugin_storage_defaults, plugin_storage_overrides)
end

# =============================================================================
# OpenTelemetry Configuration
# =============================================================================
# All OTEL exporter config MUST live here — runtime.exs runs before OTP apps
# start, so the opentelemetry SDK picks up these values at boot.
otel_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")

if otel_endpoint do
  ssl_opts = ServiceRadar.Telemetry.OtelSetup.ssl_options()
  otel_rpc_timeout_ms = parse_int_env.("OTEL_EXPORTER_OTLP_TIMEOUT_MS", 30_000)
  otel_retry_max_attempts = parse_int_env.("OTEL_EXPORTER_OTLP_RETRY_MAX_ATTEMPTS", 3)
  otel_retry_base_delay_ms = parse_int_env.("OTEL_EXPORTER_OTLP_RETRY_BASE_DELAY_MS", 500)
  otel_retry_max_delay_ms = parse_int_env.("OTEL_EXPORTER_OTLP_RETRY_MAX_DELAY_MS", 10_000)

  config :opentelemetry,
    span_processor: :batch,
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
    otlp_endpoint: otel_endpoint,
    ssl_options: ssl_opts
else
  config :opentelemetry,
    traces_exporter: :none
end

# =============================================================================
# Cluster Configuration
# =============================================================================
# All Elixir nodes (agent gateway, web/core) join the same ERTS cluster for:
# - Distributed process management (Horde)
# - Remote debugging and observer
# - Telemetry aggregation
# - Direct Erlang messaging between components
#
# The agent gateway connects to:
# - serviceradar-core-elx (Elixir core/web service)
# - Other gateways in the same partition
# - Agents connected to this gateway

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
        # Kubernetes DNS-based discovery (production)
        # Connects to both core and other gateways via headless services
        namespace = System.get_env("NAMESPACE", "serviceradar")
        kubernetes_selector = System.get_env("KUBERNETES_SELECTOR", "app=serviceradar")

        kubernetes_node_basename =
          System.get_env("KUBERNETES_NODE_BASENAME", "serviceradar_agent_gateway")

        # Core service discovery (serviceradar-core-elx)
        core_service = System.get_env("CLUSTER_CORE_SERVICE", "serviceradar-core-elx-headless")
        core_node_basename = System.get_env("CLUSTER_CORE_NODE_BASENAME", "serviceradar_core")

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
          ],
          # Separate topology for core service (if different from main selector)
          serviceradar_core: [
            strategy: Cluster.Strategy.Kubernetes.DNS,
            config: [
              service: core_service,
              application_name: core_node_basename,
              namespace: namespace,
              polling_interval: 5_000
            ]
          ]
        ]

      "dns" ->
        # DNSPoll strategy for bare metal with service discovery
        dns_query =
          get_in(hosted_cluster_contract, ["gateway", "dns_query"]) ||
            System.get_env("CLUSTER_DNS_QUERY", "serviceradar.local")

        node_basename =
          get_in(hosted_cluster_contract, ["gateway", "node_basename"]) ||
            System.get_env("CLUSTER_NODE_BASENAME", "serviceradar_agent_gateway")

        # Core DNS name (e.g., serviceradar-core.serviceradar.local)
        core_dns_query =
          get_in(hosted_cluster_contract, ["gateway", "core_dns_query"]) ||
            System.get_env("CLUSTER_CORE_DNS_QUERY", dns_query)

        core_node_basename =
          get_in(hosted_cluster_contract, ["gateway", "core_node_basename"]) ||
            System.get_env("CLUSTER_CORE_NODE_BASENAME", "serviceradar_core")

        [
          serviceradar: [
            strategy: DNSPoll,
            config: [
              polling_interval: 5_000,
              query: dns_query,
              node_basename: node_basename
            ]
          ],
          serviceradar_core: [
            strategy: DNSPoll,
            config: [
              polling_interval: 5_000,
              query: core_dns_query,
              node_basename: core_node_basename
            ]
          ]
        ]

      "epmd" ->
        # EPMD strategy for development and static bare metal
        # CLUSTER_HOSTS should include core nodes (e.g., "serviceradar@core-host")
        hosts_str = System.get_env("CLUSTER_HOSTS", "")

        hosts =
          hosts_str
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
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
        # Gossip strategy for large-scale/mesh VPN deployments
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
# TLS distribution is configured via ERL_FLAGS in rel/env.sh.eex

spiffe_mode =
  case System.get_env("SPIFFE_MODE", "filesystem") do
    "workload_api" -> :workload_api
    _ -> :filesystem
  end

sysmon_metrics_publish_enabled =
  System.get_env("AGENT_GATEWAY_SYSMON_METRICS_ENABLED", "true") in ~w(true 1 yes)

# Off by default, unlike the metrics publishers above: `edge-records:v1` is still an active
# milestone (unify-sweep-results-proto task 0.12) and must stay disabled outside a guarded
# vertical-slice target until the durable path is proven end to end.
edge_records_publish_enabled =
  System.get_env("AGENT_GATEWAY_EDGE_RECORDS_ENABLED", "false") in ~w(true 1 yes)

snmp_metrics_publish_enabled =
  System.get_env("AGENT_GATEWAY_SNMP_METRICS_ENABLED", "true") in ~w(true 1 yes)

# SNMP interface-metric allowlist (fj #3788, REC7e). Operators widen the gateway
# allowlist via the release/Helm path: "all" publishes every collected OID,
# a comma-separated list restricts to those metric names, and absent/empty keeps
# the publisher's built-in default (ifHCInOctets, ifHCOutOctets).
snmp_interface_metrics =
  case System.get_env("AGENT_GATEWAY_SNMP_INTERFACE_METRICS") do
    blank when blank in [nil, ""] ->
      nil

    value ->
      case value |> String.trim() |> String.downcase() do
        "all" -> :all
        _ -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
      end
  end

icmp_metrics_publish_enabled =
  (System.get_env("AGENT_GATEWAY_ICMP_METRICS_ENABLED") ||
     System.get_env("AGENT_GATEWAY_ICMP_METRICS_SHADOW_ENABLED", "true")) in ~w(true 1 yes)

plugin_metrics_publish_enabled =
  System.get_env("AGENT_GATEWAY_PLUGIN_METRICS_ENABLED", "true") in ~w(true 1 yes)

rperf_metrics_publish_enabled =
  System.get_env("AGENT_GATEWAY_RPERF_METRICS_ENABLED", "true") in ~w(true 1 yes)

mtr_metrics_publish_enabled =
  System.get_env("AGENT_GATEWAY_MTR_METRICS_ENABLED", "true") in ~w(true 1 yes)

sweep_metrics_publish_enabled =
  System.get_env("AGENT_GATEWAY_SWEEP_METRICS_ENABLED", "true") in ~w(true 1 yes)

otlp_relay_publish_enabled =
  System.get_env("AGENT_GATEWAY_OTLP_RELAY_PUBLISH_ENABLED", "true") in ~w(true 1 yes)

config :serviceradar_agent_gateway, :edge_records_publisher, enabled: edge_records_publish_enabled

config :serviceradar_agent_gateway, :icmp_metrics_publisher,
  enabled: icmp_metrics_publish_enabled,
  subject_prefix: System.get_env("AGENT_GATEWAY_ICMP_METRICS_SUBJECT_PREFIX", "metrics.icmp"),
  connection: Connection

config :serviceradar_agent_gateway, :metrics,
  enabled: System.get_env("GATEWAY_METRICS_ENABLED", "true") in ~w(true 1 yes),
  ip: {0, 0, 0, 0},
  port: parse_int_env.("GATEWAY_METRICS_PORT", 9090)

config :serviceradar_agent_gateway, :mtr_metrics_publisher,
  enabled: mtr_metrics_publish_enabled,
  subject_prefix: System.get_env("AGENT_GATEWAY_MTR_METRICS_SUBJECT_PREFIX", "metrics.mtr"),
  connection: Connection

config :serviceradar_agent_gateway, :otlp_relay_publisher,
  enabled: otlp_relay_publish_enabled,
  traces_subject: System.get_env("AGENT_GATEWAY_OTLP_RELAY_TRACES_SUBJECT", "otel.traces.raw"),
  logs_subject: System.get_env("AGENT_GATEWAY_OTLP_RELAY_LOGS_SUBJECT", "logs.otel"),
  metrics_subject: System.get_env("AGENT_GATEWAY_OTLP_RELAY_METRICS_SUBJECT", "otel.metrics.raw"),
  derived_metrics_subject: System.get_env("AGENT_GATEWAY_OTLP_RELAY_DERIVED_METRICS_SUBJECT", "otel.metrics.derived"),
  connection: Connection

config :serviceradar_agent_gateway, :plugin_metrics_publisher,
  enabled: plugin_metrics_publish_enabled,
  subject_prefix: System.get_env("AGENT_GATEWAY_PLUGIN_METRICS_SUBJECT_PREFIX", "metrics.timeseries"),
  connection: Connection

config :serviceradar_agent_gateway, :rperf_metrics_publisher,
  enabled: rperf_metrics_publish_enabled,
  subject_prefix: System.get_env("AGENT_GATEWAY_RPERF_METRICS_SUBJECT_PREFIX", "metrics.rperf"),
  connection: Connection

config :serviceradar_agent_gateway, :snmp_metrics_publisher,
  enabled: snmp_metrics_publish_enabled,
  subject_prefix: System.get_env("AGENT_GATEWAY_SNMP_METRICS_SUBJECT_PREFIX", "metrics.snmp"),
  interface_metrics: snmp_interface_metrics,
  connection: Connection

config :serviceradar_agent_gateway, :sweep_metrics_publisher,
  enabled: sweep_metrics_publish_enabled,
  subject_prefix: System.get_env("AGENT_GATEWAY_SWEEP_METRICS_SUBJECT_PREFIX", "metrics.sweep"),
  connection: Connection

config :serviceradar_agent_gateway, :sysmon_metrics_publisher,
  enabled: sysmon_metrics_publish_enabled,
  subject_prefix: System.get_env("AGENT_GATEWAY_SYSMON_METRICS_SUBJECT_PREFIX", "metrics.sysmon"),
  connection: Connection

if sysmon_metrics_publish_enabled or snmp_metrics_publish_enabled or
     icmp_metrics_publish_enabled or
     plugin_metrics_publish_enabled or
     rperf_metrics_publish_enabled or
     mtr_metrics_publish_enabled or
     sweep_metrics_publish_enabled or
     otlp_relay_publish_enabled or
     edge_records_publish_enabled do
  nats_url =
    System.get_env("AGENT_GATEWAY_NATS_URL") ||
      System.get_env("NATS_URL", "nats://localhost:4222")

  nats_uri = URI.parse(nats_url)
  nats_tls_enabled = System.get_env("AGENT_GATEWAY_NATS_TLS", "false") in ~w(true 1 yes)
  nats_server_name = System.get_env("AGENT_GATEWAY_NATS_SERVER_NAME", "nats.serviceradar")
  cert_dir = System.get_env("SPIFFE_CERT_DIR", "/etc/serviceradar/certs")
  cert_name = System.get_env("AGENT_GATEWAY_NATS_CERT_NAME", "gateway")

  nats_tls_config =
    if nats_tls_enabled do
      [
        verify: :verify_peer,
        cacertfile: Path.join(cert_dir, "root.pem"),
        certfile: Path.join(cert_dir, "#{cert_name}.pem"),
        keyfile: Path.join(cert_dir, "#{cert_name}-key.pem"),
        server_name_indication: String.to_charlist(nats_server_name)
      ]
    else
      false
    end

  config :serviceradar_core, Connection,
    host: nats_uri.host || "localhost",
    port: nats_uri.port || 4222,
    user: System.get_env("AGENT_GATEWAY_NATS_USER"),
    password: {:system, "AGENT_GATEWAY_NATS_PASSWORD"},
    creds_file: System.get_env("AGENT_GATEWAY_NATS_CREDS_FILE"),
    tls: nats_tls_config
end

config :serviceradar_agent_gateway,
  camera_relay_max_sessions_per_agent: parse_int_env.("CAMERA_RELAY_MAX_SESSIONS_PER_AGENT", 16),
  camera_relay_max_sessions_per_gateway: parse_int_env.("CAMERA_RELAY_MAX_SESSIONS_PER_GATEWAY", 32),
  camera_relay_sweep_interval_ms: parse_int_env.("CAMERA_RELAY_SWEEP_INTERVAL_MS", 5_000)

config :serviceradar_core, Oban, false
config :serviceradar_core, ServiceRadar.Mailer, adapter: Swoosh.Adapters.Test

config :serviceradar_core, ServiceRadar.PubSub,
  name: ServiceRadar.PubSub,
  adapter: Phoenix.PubSub.PG2

# Ensure the gateway never starts the log promotion consumer.
config :serviceradar_core, :log_promotion_consumer_enabled, false

config :serviceradar_core, :spiffe,
  mode: spiffe_mode,
  trust_domain: System.get_env("SPIFFE_TRUST_DOMAIN", "serviceradar.local"),
  cert_dir: System.get_env("SPIFFE_CERT_DIR", "/etc/serviceradar/certs"),
  workload_api_socket: System.get_env("SPIFFE_WORKLOAD_API_SOCKET", "unix:///run/spire/sockets/agent.sock")

# =============================================================================
# serviceradar_core Dependencies
# =============================================================================
# Agent gateway does not start the core database or Oban.
# Cluster coordination is handled by core-elx; the gateway only joins.

# Each deployment runs its own gateway; isolation is handled by infrastructure.
config :serviceradar_core,
  repo_enabled: System.get_env("SERVICERADAR_CORE_REPO_ENABLED", "false") in ~w(true 1 yes),
  vault_enabled: false,
  datasvc_enabled: System.get_env("DATASVC_ENABLED", "false") in ~w(true 1 yes),
  cluster_enabled: System.get_env("CLUSTER_ENABLED", "true") in ~w(true 1 yes),
  # =============================================================================
  # PubSub Configuration
  # =============================================================================
  # Uses the shared PubSub from serviceradar_core
  cluster_coordinator: false

# =============================================================================

# Disable Swoosh API client (agent gateway does not send email).
# Telemetry Configuration
# =============================================================================
# Attach default handlers for logging cluster events

config :swoosh, :api_client, false
config :swoosh, local: false

if config_env() == :prod do
  config :logger, :console,
    format: "$time $metadata[$level] $message\n",
    metadata: [
      :request_id,
      :gateway_id,
      :partition_id,
      :node,
      :agent_id,
      :partition,
      :subject,
      :reason,
      :service_name,
      :message_size,
      :payload_kind,
      :event_id,
      :command_id,
      :expected_command_type,
      :reported_command_type,
      :phase,
      :desktop_session_id,
      :command_type,
      :success,
      :payload_field_count,
      :progress_percent,
      :config_version,
      :section_count
    ]

  config :logger,
    level: :info
end
