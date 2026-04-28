import Config

# This file is executed at runtime before the application starts.
# It is executed in both release and dev/test modes.

alias Cluster.Strategy.DNSPoll

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

config :serviceradar_agent_gateway, :metrics,
  enabled: System.get_env("GATEWAY_METRICS_ENABLED", "true") in ~w(true 1 yes),
  ip: {0, 0, 0, 0},
  port: parse_int_env.("GATEWAY_METRICS_PORT", 9090)

config :serviceradar_agent_gateway,
  camera_relay_max_sessions_per_agent: parse_int_env.("CAMERA_RELAY_MAX_SESSIONS_PER_AGENT", 16),
  camera_relay_max_sessions_per_gateway: parse_int_env.("CAMERA_RELAY_MAX_SESSIONS_PER_GATEWAY", 32)

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
    metadata: [:request_id, :gateway_id, :partition_id, :node]

  config :logger,
    level: :info
end
