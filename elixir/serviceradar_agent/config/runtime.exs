import Config

# This file is executed at runtime before the application starts.
# It is executed in both release and dev/test modes.

# =============================================================================
# Cluster Configuration
# =============================================================================
# The agent joins the same ERTS cluster as pollers and the core for:
# - Distributed process management (Horde)
# - Remote debugging and observer
# - Telemetry aggregation
# - Direct Erlang messaging to pollers
#
# The agent connects to:
# - serviceradar-core-elx (Elixir core/web service)
# - Pollers in the same partition
# - Other agents

cluster_strategy =
  System.get_env("CLUSTER_STRATEGY", "epmd")
  |> String.downcase()

cluster_enabled = System.get_env("CLUSTER_ENABLED", "true") in ~w(true 1 yes)

topologies =
  if cluster_enabled do
    case cluster_strategy do
      "kubernetes" ->
        # Kubernetes DNS-based discovery (production)
        namespace = System.get_env("NAMESPACE", "serviceradar")
        kubernetes_selector = System.get_env("KUBERNETES_SELECTOR", "app=serviceradar")
        kubernetes_node_basename = System.get_env("KUBERNETES_NODE_BASENAME", "serviceradar")

        # Core service discovery
        core_service = System.get_env("CLUSTER_CORE_SERVICE", "serviceradar-core-elx-headless")

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
          serviceradar_core: [
            strategy: Cluster.Strategy.Kubernetes.DNS,
            config: [
              service: core_service,
              application_name: "serviceradar",
              namespace: namespace,
              polling_interval: 5_000
            ]
          ]
        ]

      "dns" ->
        # DNSPoll strategy for bare metal with service discovery
        dns_query = System.get_env("CLUSTER_DNS_QUERY", "serviceradar.local")
        node_basename = System.get_env("CLUSTER_NODE_BASENAME", "serviceradar")
        core_dns_query = System.get_env("CLUSTER_CORE_DNS_QUERY", dns_query)

        [
          serviceradar: [
            strategy: Cluster.Strategy.DNSPoll,
            config: [
              polling_interval: 5_000,
              query: dns_query,
              node_basename: node_basename
            ]
          ],
          serviceradar_core: [
            strategy: Cluster.Strategy.DNSPoll,
            config: [
              polling_interval: 5_000,
              query: core_dns_query,
              node_basename: "serviceradar"
            ]
          ]
        ]

      "epmd" ->
        # EPMD strategy for development and static bare metal
        # CLUSTER_HOSTS should include core and poller nodes
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

# =============================================================================
# PubSub Configuration
# =============================================================================

config :serviceradar_core, ServiceRadar.PubSub,
  name: ServiceRadar.PubSub,
  adapter: Phoenix.PubSub.PG2

# =============================================================================
# Checker Configuration
# =============================================================================
# External checkers (Go/Rust processes) that this agent can talk to via gRPC

config :serviceradar_agent, :checkers,
  snmp: System.get_env("CHECKER_SNMP_ADDR", "localhost:50052"),
  wmi: System.get_env("CHECKER_WMI_ADDR", "localhost:50053"),
  sweep: System.get_env("CHECKER_SWEEP_ADDR", "localhost:50054")

# =============================================================================
# Telemetry Configuration
# =============================================================================

if config_env() == :prod do
  config :logger,
    backends: [:console],
    level: :info

  config :logger, :console,
    format: "$time $metadata[$level] $message\n",
    metadata: [:request_id, :agent_id, :partition_id, :node]
end
