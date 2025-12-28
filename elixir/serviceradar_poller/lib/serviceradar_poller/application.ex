defmodule ServiceRadarPoller.Application do
  @moduledoc """
  ServiceRadar Poller Application.

  This is a standalone Elixir release that runs in our infrastructure
  (Kubernetes) and joins the ServiceRadar ERTS cluster. It initiates
  gRPC connections to Go agents deployed in customer networks.

  The poller is responsible for:
  - Joining the distributed ERTS cluster via mTLS
  - Registering itself in the Horde distributed registry
  - Executing local polling tasks (ICMP, TCP, HTTP, DNS)
  - Initiating gRPC connections to Go agents for delegated checks
  - Forwarding monitoring data to the core cluster

  ## Agent Communication

  The poller initiates all connections to Go agents via gRPC:
  - Agents expose a gRPC endpoint (default port 50051)
  - Pollers discover agents via AgentRegistry
  - Communication flows DOWN only (poller → agent)
  - Agents never connect back to pollers

  This architecture ensures:
  - Minimal firewall exposure: only gRPC port open inbound to agent
  - No ERTS distribution in customer networks
  - Secure communication via mTLS

  ## Environment Variables

  - `POLLER_PARTITION_ID` - The partition this poller belongs to
  - `POLLER_ID` - Unique identifier for this poller
  - `POLLER_DOMAIN` - The domain this poller monitors
  - `POLLER_CAPABILITIES` - Comma-separated list of capabilities (e.g., "icmp,tcp,http")
  - `POLLER_TENANT_ID` - Tenant UUID for multi-tenant deployments
  - `POLLER_TENANT_SLUG` - Tenant slug for multi-tenant deployments
  - `CLUSTER_HOSTS` - Comma-separated list of cluster nodes to join

  ## Multi-Tenant Isolation

  For multi-tenant deployments, each tenant's pollers are isolated via:

  1. **Per-Tenant Horde Registries**: Each tenant has isolated registry state
  2. **TenantGuard**: Defense-in-depth process-level validation
  3. **Certificate-based Identity**: Certificate CN includes tenant slug

  All pollers join the same ERTS cluster but register in tenant-specific
  Horde registries, preventing cross-tenant process discovery.

  The tenant info is resolved from:
  1. Environment variables (POLLER_TENANT_ID/POLLER_TENANT_SLUG)
  2. Certificate CN format: `<poller_id>.<partition_id>.<tenant_slug>.serviceradar`

  ## Architecture

  ```
  ┌─────────────────────────────────────────────────────────┐
  │                    ServiceRadar Core (K8s)               │
  │  ┌─────────────┐  ┌──────────────┐  ┌───────────────┐   │
  │  │ Horde       │  │ libcluster   │  │ Task          │   │
  │  │ Registry    │  │              │  │ Orchestrator  │   │
  │  └──────┬──────┘  └──────┬───────┘  └───────┬───────┘   │
  └─────────┼────────────────┼──────────────────┼───────────┘
            │ mTLS/ERTS      │                  │
            │                │                  │
  ┌─────────┼────────────────┼──────────────────┼───────────┐
  │         ▼                ▼                  ▼           │
  │  ┌─────────────┐  ┌──────────────┐  ┌───────────────┐   │
  │  │ Registration│  │ Cluster      │  │ Task          │   │
  │  │ Worker      │  │ Membership   │  │ Executor      │   │
  │  └─────────────┘  └──────────────┘  └───────┬───────┘   │
  │                    ServiceRadar Poller (K8s) │          │
  └─────────────────────────────────────────────┼──────────┘
                                                │ gRPC/mTLS
                                                │
  ┌─────────────────────────────────────────────┼──────────┐
  │                                             ▼          │
  │                                    ┌───────────────┐   │
  │                                    │  Go Agent     │   │
  │                                    │  (gRPC Server)│   │
  │                                    └───────────────┘   │
  │                    Customer Network (Edge)             │
  └────────────────────────────────────────────────────────┘
  ```

  ERTS cluster stays within our infrastructure (K8s).
  Customer network only needs gRPC port open for agent communication.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    partition_id = System.get_env("POLLER_PARTITION_ID", "default")
    poller_id = System.get_env("POLLER_ID", generate_poller_id())
    domain = System.get_env("POLLER_DOMAIN", "default")
    tenant_id = System.get_env("POLLER_TENANT_ID")
    tenant_slug = System.get_env("POLLER_TENANT_SLUG")

    capabilities = parse_capabilities(System.get_env("POLLER_CAPABILITIES", ""))

    if tenant_slug do
      Logger.info(
        "Starting ServiceRadar Poller: #{poller_id} in partition: #{partition_id} for tenant: #{tenant_slug}"
      )
    else
      Logger.info("Starting ServiceRadar Poller: #{poller_id} in partition: #{partition_id}")
    end

    children = [
      # Poller-specific configuration store
      {ServiceRadarPoller.Config,
       partition_id: partition_id,
       poller_id: poller_id,
       domain: domain,
       capabilities: capabilities,
       tenant_id: tenant_id,
       tenant_slug: tenant_slug},

      # Registration worker - registers this poller in the distributed registry
      {ServiceRadar.Poller.RegistrationWorker,
       partition_id: partition_id,
       poller_id: poller_id,
       domain: domain,
       capabilities: capabilities},

      # gRPC client for communicating with Go agents
      ServiceRadarPoller.AgentClient,

      # Task executor - executes polling tasks from the core
      ServiceRadarPoller.TaskExecutor
    ]

    opts = [strategy: :one_for_one, name: ServiceRadarPoller.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp parse_capabilities(capabilities_str) do
    capabilities_str
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_atom/1)
  end

  defp generate_poller_id do
    hostname =
      case :inet.gethostname() do
        {:ok, name} -> List.to_string(name)
        _ -> "unknown"
      end

    "poller-#{hostname}-#{:rand.uniform(9999)}"
  end
end
