# Design: Ash Framework Integration

## Context

ServiceRadar is a distributed network monitoring and observability platform. The current architecture consists of:

- **serviceradar-core (Go)**: Control plane API, device identity, poller coordination
- **serviceradar-poller (Go)**: Executes service checks, talks to agents
- **serviceradar-agent (Go)**: Runs on monitored hosts, proxies to checkers
- **web-ng (Elixir/Phoenix)**: New web UI with LiveView, basic Oban scheduling
- **CNPG/TimescaleDB**: Telemetry storage with OCSF-aligned schemas
- **NATS JetStream**: KV configuration, message broker

The goal is to migrate control plane functionality from Go to Elixir, eventually replacing serviceradar-core entirely. The Ash Framework provides the scaffolding for this migration with its declarative resource model.

### Stakeholders
- Platform engineers building ServiceRadar
- Customers deploying agents in their networks
- SaaS operations team managing multi-tenant infrastructure

### Constraints
- Backward compatibility with existing Go agents (gRPC must remain)
- OCSF schema alignment for device inventory
- Zero-downtime migration path
- Existing pollers must continue functioning during transition

## Goals / Non-Goals

### Goals
1. Implement multi-tenant architecture with strong isolation
2. Replace phoenix.gen.auth with AshAuthentication (magic link + OAuth2)
3. Convert Ecto schemas to Ash resources with AshPostgres
4. Implement RBAC using Ash.Policy.Authorizer
5. Replace custom Oban scheduler with AshOban
6. Generate JSON:API endpoints from Ash resources
7. Create state machines for alert and device lifecycle
8. Enable distributed polling coordination via ERTS clustering

### Non-Goals
- Rewriting Go agents in Elixir (keep gRPC interface)
- Replacing NATS JetStream (keep for agent config delivery)
- Full GraphQL API (JSON:API sufficient for initial release)
- Real-time streaming protocols (WebSocket via LiveView is sufficient)

## Decisions

### Decision 1: Ash 3.x with AshPostgres as Data Layer

**What**: Use Ash 3.x framework with AshPostgres for all database operations.

**Why**:
- Native multi-tenancy support via attribute strategy
- Authorization enforced at resource level, not controller
- OCSF columns map directly to Ash attributes with `source:` option
- Calculated fields handle device type mappings cleanly

**Alternatives considered**:
- Pure Ecto with manual contexts (current state) - Too much boilerplate, authorization gaps
- Commanded/EventStore - Too complex for current needs, can add later
- Raw SQL/Repo - Loses all framework benefits

### Decision 2: Attribute-Based Multi-Tenancy

**What**: Use Ash's attribute-based multi-tenancy with `tenant_id` column.

**Why**:
- Single database, simpler operations
- Works with TimescaleDB hypertables
- Existing OCSF tables can add tenant_id column
- Query scoping automatic via Ash

**Alternatives considered**:
- Schema-based (PostgreSQL schemas per tenant) - Complex migrations, harder backup/restore
- Database-per-tenant - Operational overhead too high

**Implementation**:
```elixir
multitenancy do
  strategy :attribute
  attribute :tenant_id
  global? true  # Allow global reads for super-admins
end
```

### Decision 3: AshAuthentication with Multiple Strategies

**What**: Implement authentication using AshAuthentication supporting:
- Magic link email (default)
- Password authentication (migration from existing)
- OAuth2 (Google, GitHub, enterprise IdPs)
- API tokens (for CLI/automation)

**Why**:
- Declarative strategy configuration
- Token management built-in
- Guardian integration for JWT
- Phoenix LiveView components included

**Alternatives considered**:
- Keep phoenix.gen.auth - No OAuth2, limited magic link support
- Custom Guardian implementation - More code to maintain
- Auth0/External IdP only - Vendor lock-in, cost

### Decision 4: Role-Based Authorization with Policies

**What**: Implement RBAC using Ash.Policy.Authorizer with roles: `admin`, `operator`, `viewer`, and a super-user bypass.

**Why**:
- Policies evaluated at resource level, cannot be bypassed
- Field-level policies for sensitive data
- Audit-friendly policy definitions
- Bypass for super-admin emergencies

**Example policy structure**:
```elixir
policies do
  bypass actor_attribute_equals(:super_user, true) do
    authorize_if always()
  end

  policy action_type(:read) do
    # Tenant isolation
    authorize_if expr(tenant_id == ^actor(:tenant_id))
  end

  policy action_type(:create) do
    authorize_if actor_attribute_equals(:role, :admin)
    authorize_if actor_attribute_equals(:role, :operator)
  end

  policy action_type(:destroy) do
    authorize_if actor_attribute_equals(:role, :admin)
  end
end
```

### Decision 5: AshOban for Declarative Job Scheduling

**What**: Replace custom `ServiceRadarWebNG.Jobs.Scheduler` with AshOban triggers.

**Why**:
- Jobs defined as resource actions
- Scheduling is declarative, not imperative
- State machine integration for lifecycle jobs
- Distributed coordination via Oban.Peer

**Migration path**:
1. Keep existing Oban config for backward compat
2. Add AshOban triggers alongside
3. Migrate job catalog entries one-by-one
4. Remove custom scheduler once migrated

### Decision 6: AshStateMachine for Lifecycle Management

**What**: Implement state machines for:
- **Alert lifecycle**: `pending` -> `acknowledged` -> `resolved` | `escalated`
- **Device onboarding**: `discovered` -> `identified` -> `managed` -> `decommissioned`
- **Edge package**: `created` -> `downloaded` -> `installed` -> `expired` | `revoked`

**Why**:
- State transitions enforced at framework level
- Invalid transitions prevented
- Integrates with AshOban for timed transitions
- Audit trail via state change history

### Decision 7: Phased Migration with Feature Flags

**What**: Migrate domain-by-domain with feature flags controlling old vs new code paths.

**Why**:
- Zero-downtime migration
- Rollback capability per-feature
- A/B testing of new implementations
- Gradual team learning curve

**Migration order**:
1. Identity domain (users, tenants, auth) - Foundational
2. Inventory domain (devices) - High traffic, validates performance
3. Infrastructure domain (pollers, agents) - Validates multi-tenancy
4. Monitoring domain (checks, alerts) - Validates state machines
5. Collection domain (flows, logs) - High volume, validates scale

### Decision 8: API Versioning Strategy

**What**: Introduce `/api/v2/` for Ash-powered JSON:API endpoints while keeping `/api/` for backward compatibility.

**Why**:
- Existing CLI tools continue working
- JSON:API compliance for v2
- Clear migration path for clients
- Can deprecate v1 on timeline

### Decision 9: ERTS Clustering with Horde + Oban for Distributed Polling

**What**: Use libcluster + Horde for distributed process coordination across separate poller microservices, with Oban (AshOban) for job scheduling and persistence.

**Why**:
- Pollers as separate BEAM nodes/microservices (can run at edge)
- Horde.DynamicSupervisor for process distribution across nodes
- Horde.Registry for finding available pollers by partition/domain
- Oban for persistent job scheduling (AshOban for Ash integration)
- Separation of concerns: Oban schedules "what", Horde coordinates "where"

**Architecture**:
```
┌─────────────────────────────────────────────────────────────────────────┐
│                    ERTS Cluster (libcluster)                            │
│                                                                         │
│  ┌─────────────────────┐                                                │
│  │ Core Node (Phoenix) │                                                │
│  │                     │                                                │
│  │ ┌─────────────────┐ │                                                │
│  │ │ AshOban         │ │  "Schedule job: collect metrics from          │
│  │ │ Job Scheduler   │ │   endpoint domain X every 5 minutes"          │
│  │ └────────┬────────┘ │                                                │
│  │          │          │                                                │
│  │ ┌────────▼────────┐ │                                                │
│  │ │ Horde.Registry  │ │  "Find available poller for partition P1"     │
│  │ │ (Poller Lookup) │ │                                                │
│  │ └────────┬────────┘ │                                                │
│  └──────────┼──────────┘                                                │
│             │                                                           │
│             │ ERTS distribution (Erlang native)                         │
│             ▼                                                           │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                    Poller Nodes (Microservices)                   │  │
│  │                                                                   │  │
│  │  ┌──────────────────┐  ┌──────────────────┐  ┌────────────────┐  │  │
│  │  │ Poller Node 1    │  │ Poller Node 2    │  │ Poller Node N  │  │  │
│  │  │ (Edge Site A)    │  │ (Edge Site B)    │  │ (Cloud)        │  │  │
│  │  │                  │  │                  │  │                │  │  │
│  │  │ ┌──────────────┐ │  │ ┌──────────────┐ │  │ ┌────────────┐ │  │  │
│  │  │ │ Horde.Dyn    │ │  │ │ Horde.Dyn    │ │  │ │ Horde.Dyn  │ │  │  │
│  │  │ │ Supervisor   │ │  │ │ Supervisor   │ │  │ │ Supervisor │ │  │  │
│  │  │ └──────────────┘ │  │ └──────────────┘ │  │ └────────────┘ │  │  │
│  │  │                  │  │                  │  │                │  │  │
│  │  │ Partition: P1    │  │ Partition: P2    │  │ Partition: *   │  │  │
│  │  │ Domain: site-a   │  │ Domain: site-b   │  │ Domain: cloud  │  │  │
│  │  └────────┬─────────┘  └────────┬─────────┘  └───────┬────────┘  │  │
│  └───────────┼─────────────────────┼────────────────────┼───────────┘  │
└──────────────┼─────────────────────┼────────────────────┼──────────────┘
               │                     │                    │
               │ gRPC                │ gRPC               │ gRPC
               ▼                     ▼                    ▼
        ┌────────────┐        ┌────────────┐       ┌────────────┐
        │ Go Agent 1 │        │ Go Agent 2 │       │ Go Agent N │
        │ (site-a)   │        │ (site-b)   │       │ (cloud)    │
        └────────────┘        └────────────┘       └────────────┘
```

**Job Flow Example**:
1. AshOban schedules job: "Poll SNMP metrics from device X"
2. Job includes target partition and endpoint domain
3. Oban worker queries Horde.Registry: "Find available poller for partition P1"
4. Horde returns reference to Poller Node at edge site
5. Worker dispatches task to poller via ERTS distribution
6. Poller executes gRPC call to local Go Agent
7. Results flow back through ERTS to Core for persistence

**Horde Configuration**:
```elixir
# In Poller application supervision tree
children = [
  {Horde.Registry, [name: ServiceRadar.PollerRegistry, keys: :unique]},
  {Horde.DynamicSupervisor, [
    name: ServiceRadar.PollerSupervisor,
    strategy: :one_for_one,
    members: :auto  # Auto-join cluster
  ]},
  {ServiceRadar.Poller.RegistrationWorker, [
    partition_id: partition_id(),
    domain: domain_name(),
    capabilities: [:snmp, :grpc, :sweep]
  ]}
]
```

**Registry Lookup**:
```elixir
def find_poller_for_partition(partition_id) do
  case Horde.Registry.select(ServiceRadar.PollerRegistry, [
    {{:"$1", :"$2", %{partition_id: partition_id, status: :available}}, [], [:"$2"]}
  ]) do
    [poller_pid | _] -> {:ok, poller_pid}
    [] -> {:error, :no_available_poller}
  end
end
```

**Auto-Registration Flow**:
```
Poller/Agent Node Startup
         │
         ▼
┌─────────────────────────────┐
│ 1. libcluster joins ERTS    │
│    cluster (auto-discover)  │
└──────────────┬──────────────┘
               │
               ▼
┌─────────────────────────────┐
│ 2. Horde.Registry auto-sync │
│    (CRDT-based, eventually  │
│     consistent)             │
└──────────────┬──────────────┘
               │
               ▼
┌─────────────────────────────┐
│ 3. RegistrationWorker       │
│    registers with metadata: │
│    - partition_id           │
│    - domain                 │
│    - capabilities           │
│    - node_name              │
│    - status: :available     │
└──────────────┬──────────────┘
               │
               ▼
┌─────────────────────────────┐
│ 4. Core Node sees new       │
│    poller in registry,      │
│    persists to DB           │
└──────────────┬──────────────┘
               │
               ▼
┌─────────────────────────────┐
│ 5. Poller starts heartbeat  │
│    GenServer, updates       │
│    status periodically      │
└─────────────────────────────┘
```

**Auto-Registration Implementation**:
```elixir
defmodule ServiceRadar.Poller.RegistrationWorker do
  use GenServer

  @heartbeat_interval :timer.seconds(30)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    # Register with Horde on startup
    metadata = %{
      partition_id: opts[:partition_id],
      domain: opts[:domain],
      capabilities: opts[:capabilities] || [],
      node: Node.self(),
      status: :available,
      registered_at: DateTime.utc_now()
    }

    # Unique key per node
    key = {opts[:partition_id], Node.self()}

    {:ok, _} = Horde.Registry.register(
      ServiceRadar.PollerRegistry,
      key,
      metadata
    )

    # Notify Core of new registration
    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "poller:registrations",
      {:poller_registered, metadata}
    )

    # Start heartbeat
    schedule_heartbeat()

    {:ok, %{metadata: metadata, key: key}}
  end

  def handle_info(:heartbeat, state) do
    # Update status in registry
    Horde.Registry.update_value(
      ServiceRadar.PollerRegistry,
      state.key,
      fn meta -> %{meta | last_heartbeat: DateTime.utc_now()} end
    )

    schedule_heartbeat()
    {:noreply, state}
  end

  defp schedule_heartbeat do
    Process.send_after(self(), :heartbeat, @heartbeat_interval)
  end
end
```

**Agent Auto-Registration (via Poller)**:
Agents don't join the ERTS cluster directly (they're Go processes). Instead:
1. Agent connects to Poller via gRPC
2. Poller registers agent in local Horde process
3. Agent info propagates through Horde to Core
4. Core persists agent record with poller relationship

```elixir
defmodule ServiceRadar.Poller.AgentRegistry do
  # Called when Go agent connects via gRPC
  def register_agent(agent_id, agent_info) do
    metadata = %{
      agent_id: agent_id,
      poller_node: Node.self(),
      capabilities: agent_info.capabilities,
      spiffe_identity: agent_info.spiffe_id,
      status: :connected,
      connected_at: DateTime.utc_now()
    }

    {:ok, _} = Horde.Registry.register(
      ServiceRadar.AgentRegistry,
      agent_id,
      metadata
    )

    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "agent:registrations",
      {:agent_registered, metadata}
    )
  end

  def unregister_agent(agent_id) do
    Horde.Registry.unregister(ServiceRadar.AgentRegistry, agent_id)

    Phoenix.PubSub.broadcast(
      ServiceRadar.PubSub,
      "agent:registrations",
      {:agent_disconnected, agent_id}
    )
  end
end
```

### Decision 10: Keep gRPC for Agent Communication

**What**: Maintain gRPC protocol for agent communication; don't migrate agents to ERTS.

**Why**:
- Go agents are performant for ICMP/TCP sweeps
- Existing deployments continue working
- gRPC-elixir handles interop
- Agents are lightweight, no need for BEAM

### Decision 12: libcluster with Multiple Cluster Strategies

**What**: Use libcluster for ERTS cluster formation with support for multiple strategies:
- **Kubernetes strategy** (production): Auto-discover pods via K8s API
- **EPMD strategy** (development/bare metal): Static node list or DNS-based discovery
- **mTLS security**: Mutual TLS for all inter-node communication
- **Dynamic cluster membership**: Module-based supervisor for runtime node changes
- **Gossip protocol** (future enhancement): For large-scale deployments

**Why**:
- Horde requires ERTS cluster for CRDT-based registry synchronization
- Different environments need different discovery mechanisms
- Security is critical for distributed systems (mTLS)
- Dynamic membership allows adding/removing pollers without redeployment
- Gossip will enable more resilient discovery in large deployments

**libcluster Configuration**:
```elixir
# config/runtime.exs
config :libcluster,
  topologies: [
    serviceradar: [
      strategy: cluster_strategy(),
      config: cluster_config()
    ]
  ]

defp cluster_strategy do
  case System.get_env("CLUSTER_STRATEGY", "epmd") do
    "kubernetes" -> Cluster.Strategy.Kubernetes
    "epmd" -> Cluster.Strategy.Epmd
    "gossip" -> Cluster.Strategy.Gossip  # Future enhancement
    _ -> Cluster.Strategy.Epmd
  end
end
```

**Kubernetes Strategy Configuration**:
```elixir
# For production Kubernetes deployments
config :libcluster,
  topologies: [
    serviceradar: [
      strategy: Cluster.Strategy.Kubernetes,
      config: [
        mode: :dns,
        kubernetes_node_basename: "serviceradar",
        kubernetes_selector: "app=serviceradar",
        kubernetes_namespace: System.get_env("NAMESPACE", "serviceradar"),
        polling_interval: 5_000
      ]
    ]
  ]
```

**EPMD Strategy Configuration**:
```elixir
# For development and bare metal deployments
config :libcluster,
  topologies: [
    serviceradar: [
      strategy: Cluster.Strategy.Epmd,
      config: [
        hosts: [
          :"core@192.168.1.10",
          :"poller1@192.168.1.20",
          :"poller2@192.168.1.21"
        ]
      ]
    ]
  ]

# Or DNS-based for bare metal with service discovery
config :libcluster,
  topologies: [
    serviceradar: [
      strategy: Cluster.Strategy.DNSPoll,
      config: [
        polling_interval: 5_000,
        query: "serviceradar.local",
        node_basename: "serviceradar"
      ]
    ]
  ]
```

**Dynamic Cluster Membership**:
For environments where nodes are added/removed frequently, implement a module-based supervisor pattern that allows runtime cluster reconfiguration:

```elixir
defmodule ServiceRadar.ClusterSupervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    topologies = Application.get_env(:libcluster, :topologies, [])

    children = [
      {Cluster.Supervisor, [topologies, [name: ServiceRadar.ClusterSupervisor.Cluster]]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Dynamically update cluster topology at runtime.
  Useful for adding new pollers without restarting the cluster.
  """
  def update_topology(topology_name, new_config) do
    # Stop existing topology supervisor
    Supervisor.terminate_child(__MODULE__, ServiceRadar.ClusterSupervisor.Cluster)
    Supervisor.delete_child(__MODULE__, ServiceRadar.ClusterSupervisor.Cluster)

    # Start with new config
    topologies = [{topology_name, new_config}]
    Supervisor.start_child(__MODULE__,
      {Cluster.Supervisor, [topologies, [name: ServiceRadar.ClusterSupervisor.Cluster]]}
    )
  end
end
```

**mTLS Security for ERTS Distribution**:
```elixir
# vm.args or releases.exs
# Enable TLS distribution
-proto_dist inet_tls
-ssl_dist_optfile /etc/serviceradar/ssl_dist.conf

# ssl_dist.conf
[{server, [
  {certfile, "/etc/serviceradar/certs/node.crt"},
  {keyfile, "/etc/serviceradar/certs/node.key"},
  {cacertfile, "/etc/serviceradar/certs/ca.crt"},
  {verify, verify_peer},
  {fail_if_no_peer_cert, true},
  {secure_renegotiate, true}
]},
{client, [
  {certfile, "/etc/serviceradar/certs/node.crt"},
  {keyfile, "/etc/serviceradar/certs/node.key"},
  {cacertfile, "/etc/serviceradar/certs/ca.crt"},
  {verify, verify_peer},
  {secure_renegotiate, true}
]}].
```

**Release Configuration for TLS Distribution**:
```elixir
# rel/env.sh.eex (or env.bat.eex for Windows)
export RELEASE_DISTRIBUTION=name
export RELEASE_NODE=<%= @release.name %>@${HOSTNAME}

# Enable TLS distribution
export ERL_FLAGS="-proto_dist inet_tls -ssl_dist_optfile /etc/serviceradar/ssl_dist.conf"
```

**Cluster Formation Architecture**:
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Cluster Formation (libcluster)                            │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                     Strategy Selection                                   ││
│  │                                                                          ││
│  │  Production (K8s)          Dev/Staging            Future                 ││
│  │  ┌──────────────────┐     ┌──────────────────┐   ┌──────────────────┐  ││
│  │  │ Kubernetes DNS   │     │ EPMD or DNSPoll  │   │ Gossip Protocol  │  ││
│  │  │ - Headless svc   │     │ - Static hosts   │   │ - Multicast      │  ││
│  │  │ - Pod discovery  │     │ - DNS discovery  │   │ - UDP broadcast  │  ││
│  │  │ - Label selector │     │ - Local dev      │   │ - Large scale    │  ││
│  │  └──────────────────┘     └──────────────────┘   └──────────────────┘  ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    │                                         │
│                                    ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                     mTLS Transport Layer                                 ││
│  │                                                                          ││
│  │  - inet_tls proto distribution                                          ││
│  │  - Mutual certificate verification                                       ││
│  │  - CA-signed node certificates                                           ││
│  │  - Encrypted inter-node communication                                    ││
│  └─────────────────────────────────────────────────────────────────────────┘│
│                                    │                                         │
│                                    ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐│
│  │                     ERTS Cluster                                         ││
│  │                                                                          ││
│  │  ┌───────────┐    ┌───────────┐    ┌───────────┐    ┌───────────┐      ││
│  │  │ Core Node │◄──►│ Poller 1  │◄──►│ Poller 2  │◄──►│ Poller N  │      ││
│  │  │ (Phoenix) │    │ (Edge)    │    │ (Edge)    │    │ (Cloud)   │      ││
│  │  └───────────┘    └───────────┘    └───────────┘    └───────────┘      ││
│  │                                                                          ││
│  │  Horde.Registry + Horde.DynamicSupervisor synced via CRDT               ││
│  └─────────────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────────────┘
```

**Kubernetes Deployment Example**:
```yaml
# headless-service.yaml (required for DNS-based discovery)
apiVersion: v1
kind: Service
metadata:
  name: serviceradar-headless
  namespace: serviceradar
spec:
  clusterIP: None  # Headless service
  selector:
    app: serviceradar
  ports:
    - name: epmd
      port: 4369
      targetPort: 4369
    - name: distribution
      port: 9100
      targetPort: 9100

---
# Pod spec additions
spec:
  containers:
    - name: serviceradar
      env:
        - name: CLUSTER_STRATEGY
          value: "kubernetes"
        - name: NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: RELEASE_NODE
          value: "serviceradar@$(POD_IP)"
      volumeMounts:
        - name: node-certs
          mountPath: /etc/serviceradar/certs
          readOnly: true
  volumes:
    - name: node-certs
      secret:
        secretName: serviceradar-node-tls
```

**Gossip Protocol (Future Enhancement)**:
The gossip strategy will be considered for deployments with:
- 50+ poller nodes
- High node churn (nodes joining/leaving frequently)
- Network partitions expected (edge deployments with unreliable connectivity)

```elixir
# Future: Gossip-based discovery
config :libcluster,
  topologies: [
    serviceradar: [
      strategy: Cluster.Strategy.Gossip,
      config: [
        port: 45892,
        if_addr: "0.0.0.0",
        multicast_addr: "230.1.1.1",
        multicast_ttl: 1,
        secret: System.get_env("CLUSTER_SECRET")
      ]
    ]
  ]
```

### Decision 13: Edge-to-Cloud Communication Strategy

**What**: Use a hybrid approach for Edge->Cloud communication:
1. **NATS JetStream as Backplane** (primary) - For OCSF event streaming
2. **Mesh VPN (Tailscale/Nebula)** - For distributed Erlang when network allows
3. **gRPC** - For Go Agent "last mile" communication

**Why**:
- Edge sites have firewalls, NAT, and unreliable connectivity
- NATS JetStream provides buffering during network outages
- Mesh VPN enables "one big brain" debugging experience
- gRPC maintains compatibility with existing Go agents

**Architecture - The "Big Brain" Model**:
```
┌────────────────────────────────────────────────────────────────────────────────────┐
│                         GLOBAL SERVICERADAR CLUSTER                                 │
│                                                                                     │
│  ┌─────────────────────────────────────────────────────────────────────────────┐   │
│  │                           MESH VPN LAYER (Tailscale/Nebula)                  │   │
│  │                     100.64.x.x "Flat" Network Overlay                        │   │
│  └─────────────────────────────────────────────────────────────────────────────┘   │
│                                        │                                            │
│     ┌──────────────────────────────────┼──────────────────────────────────┐        │
│     │                                  │                                   │        │
│     ▼                                  ▼                                   ▼        │
│  ┌─────────────────┐    ┌─────────────────────────┐    ┌─────────────────────┐     │
│  │ CLOUD CORE      │    │ EDGE SITE A (Partition 1)│   │ EDGE SITE B (Part 2) │    │
│  │ (Phoenix)       │    │                         │    │                      │    │
│  │                 │    │ ┌─────────────────────┐ │    │ ┌──────────────────┐ │    │
│  │ ┌─────────────┐ │    │ │ Elixir Poller Node  │ │    │ │ Elixir Poller    │ │    │
│  │ │ Ash Domain  │ │◄──►│ │ (ERTS Cluster)      │ │◄──►│ │ (ERTS Cluster)   │ │    │
│  │ │ Engine      │ │    │ │                     │ │    │ │                  │ │    │
│  │ └─────────────┘ │    │ │ ┌─────────────────┐ │ │    │ │ ┌──────────────┐ │ │    │
│  │                 │    │ │ │ Horde.Registry  │ │ │    │ │ │ Horde.Reg    │ │ │    │
│  │ ┌─────────────┐ │    │ │ │ DeviceActors    │ │ │    │ │ │ DeviceActors │ │ │    │
│  │ │ Oban        │ │    │ │ └─────────────────┘ │ │    │ │ └──────────────┘ │ │    │
│  │ │ Scheduler   │ │    │ └──────────┬──────────┘ │    │ └────────┬─────────┘ │    │
│  │ └─────────────┘ │    │            │            │    │          │           │    │
│  │                 │    │            │ gRPC       │    │          │ gRPC      │    │
│  │ ┌─────────────┐ │    │            ▼            │    │          ▼           │    │
│  │ │ TimescaleDB │ │    │ ┌─────────────────────┐ │    │ ┌──────────────────┐ │    │
│  │ │ (CNPG)      │ │    │ │ Go Agent(s)        │ │    │ │ Go Agent(s)      │ │    │
│  │ └─────────────┘ │    │ │ - ICMP Sweeper     │ │    │ │ - SNMP Poller    │ │    │
│  │                 │    │ │ - TCP Checker      │ │    │ │ - TCP Checker    │ │    │
│  └─────────────────┘    │ └─────────────────────┘ │    │ └──────────────────┘ │    │
│           ▲             └─────────────────────────┘    └──────────────────────┘    │
│           │                         │                            │                  │
│           │         NATS JetStream (Async Backhaul)              │                  │
│           └─────────────────────────┴────────────────────────────┘                  │
└────────────────────────────────────────────────────────────────────────────────────┘
```

**Communication Modes**:

| Mode | Use Case | Protocol | Reliability |
|------|----------|----------|-------------|
| Distributed Erlang | Live debugging, Observer, process management | ERTS over Mesh VPN | Real-time |
| NATS JetStream | OCSF event streaming, metrics backhaul | NATS Pub/Sub | Buffered, at-least-once |
| Horde Registry | Process location, cluster state | CRDT over ERTS | Eventually consistent |
| gRPC | Agent commands, raw packet work | gRPC over TLS | Request/Response |

### Decision 14: NATS as OCSF Event Backplane

**What**: Use NATS JetStream for reliable Edge->Cloud event streaming with OCSF-aligned subjects.

**Why**:
- Existing `serviceradar-datasvc` already provides NATS infrastructure
- JetStream provides buffering during network outages
- Subject hierarchy enables partition-aware routing
- Consumer groups enable horizontal scaling

**Subject Hierarchy**:
```
events.{partition_id}.{ocsf_class}
  └── events.partition_1.network_activity
  └── events.partition_1.device_inventory
  └── events.partition_2.network_activity

telemetry.{partition_id}.{metric_type}
  └── telemetry.partition_1.snmp
  └── telemetry.partition_1.icmp

commands.{partition_id}.{command_type}
  └── commands.partition_1.sweep_request
  └── commands.partition_1.config_update
```

**Edge Publisher Implementation**:
```elixir
defmodule ServiceRadar.Edge.NATSPublisher do
  @moduledoc "Publishes OCSF events to NATS JetStream"

  def publish_network_activity(partition_id, activity) do
    subject = "events.#{partition_id}.network_activity"

    payload =
      activity
      |> ServiceRadar.OCSF.NetworkActivity.to_ocsf_json()

    Gnat.pub(:nats, subject, payload, headers: [
      {"partition-id", partition_id},
      {"ocsf-class", "network_activity"},
      {"timestamp", DateTime.utc_now() |> DateTime.to_iso8601()}
    ])
  end
end
```

**Cloud Consumer Implementation**:
```elixir
defmodule ServiceRadar.Cloud.NATSConsumer do
  use GenServer

  def handle_info({:msg, %{body: body, headers: headers}}, state) do
    partition_id = get_header(headers, "partition-id")
    ocsf_class = get_header(headers, "ocsf-class")

    # Route to appropriate Ash resource for persistence
    case ocsf_class do
      "network_activity" ->
        ServiceRadar.Monitoring.create_network_activity(
          Jason.decode!(body),
          tenant: partition_id
        )

      "device_inventory" ->
        ServiceRadar.Inventory.upsert_device(
          Jason.decode!(body),
          tenant: partition_id
        )
    end

    {:noreply, state}
  end
end
```

### Decision 15: Horde Tenant+Partition Namespacing for Overlapping IPs

**What**: Use tuple-based namespacing in Horde.Registry with **tenant_id + partition_id** to support overlapping IP spaces across tenants and partitions while enforcing strict tenant isolation.

**Why**:
- Multiple edge sites may have identical private IP ranges (10.0.0.0/8)
- **Different tenants must NEVER see each other's devices** (critical security requirement)
- Global registry needs unique keys per device across the entire multi-tenant deployment
- Partition-scoped naming enables "Device Actors" pattern
- Tenant-scoped naming prevents cross-tenant data leakage

**The Problem**:
```
Tenant A, Partition 1: 10.0.0.1 (Core Router)
Tenant A, Partition 2: 10.0.0.1 (Core Router)  <- Same IP, different device!
Tenant B, Partition 1: 10.0.0.1 (Core Router)  <- Same IP, DIFFERENT TENANT! Must be isolated.
```

**The Solution - Tenant+Partition Tuple Keys**:
```elixir
# Instead of registering by IP alone:
{:via, Horde.Registry, {ServiceRadar.DeviceRegistry, "10.0.0.1"}}  # ❌ Collision!

# Instead of just partition scope (STILL WRONG - leaks across tenants!):
{:via, Horde.Registry, {ServiceRadar.DeviceRegistry, {partition_id, ip_address}}}  # ❌ Tenant leak!

# Register with tenant + partition scope:
{:via, Horde.Registry, {ServiceRadar.DeviceRegistry, {tenant_id, partition_id, ip_address}}}  # ✓ Unique + Isolated
```

**Key Hierarchy**:
```
{tenant_id, partition_id, device_identifier}
    │           │              │
    │           │              └── IP address, MAC, or device UUID
    │           └── Network partition (edge site)
    └── Tenant isolation (NEVER cross this boundary)
```

**Defense in Depth - Why tenant_id in the key?**

Tenant isolation is already enforced at multiple layers:
1. **Ash multitenancy** - All resources have `multitenancy: :attribute, attribute: :tenant_id`
2. **Ash policies** - Query/action authorization verifies `actor.tenant_id == resource.tenant_id`
3. **API layer** - Actor context set from authenticated JWT with tenant claim

However, Horde.Registry keys exist **outside** the Ash authorization layer. Including `tenant_id` in the key provides:
- **Defense in depth** - Even if authorization bypassed, wrong key = no actor found
- **Impossible cross-tenant references** - Can't accidentally construct a valid key for another tenant
- **Clear debugging** - Registry entries show tenant ownership explicitly
- **Audit trail** - Easier to verify tenant isolation in cluster state

**Device Actor Implementation**:
```elixir
defmodule ServiceRadar.DeviceActor do
  @moduledoc """
  GenServer representing a single device in the global cluster.

  One actor per device across the entire ServiceRadar deployment.
  Actors are distributed via Horde and located by tenant + partition + IP.

  CRITICAL: The tenant_id MUST be included in all lookups to prevent
  cross-tenant data leakage. Never expose a lookup function that
  doesn't require tenant_id.
  """

  use GenServer

  def start_link(opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    partition_id = Keyword.fetch!(opts, :partition_id)
    ip = Keyword.fetch!(opts, :ip)

    # Globally unique name via tenant + partition scoping
    name = {:via, Horde.Registry, {ServiceRadar.DeviceRegistry, {tenant_id, partition_id, ip}}}

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def init(opts) do
    state = %{
      tenant_id: opts[:tenant_id],
      partition_id: opts[:partition_id],
      ip: opts[:ip],
      last_poll: nil,
      health_status: :unknown,
      metrics: %{}
    }

    # Schedule initial health check
    schedule_health_check()

    {:ok, state}
  end

  # Call from anywhere in the cluster - REQUIRES tenant_id for isolation
  def get_status(tenant_id, partition_id, ip) do
    name = {:via, Horde.Registry, {ServiceRadar.DeviceRegistry, {tenant_id, partition_id, ip}}}
    GenServer.call(name, :get_status)
  end

  def handle_call(:get_status, _from, state) do
    {:reply, %{
      tenant_id: state.tenant_id,
      ip: state.ip,
      partition: state.partition_id,
      health: state.health_status,
      last_poll: state.last_poll
    }, state}
  end

  def handle_info(:health_check, state) do
    # This runs on the edge node closest to the device
    new_state = perform_health_check(state)
    schedule_health_check()
    {:noreply, new_state}
  end

  defp perform_health_check(state) do
    # Delegate to local Go agent for actual probe
    case ServiceRadar.Agent.ping(state.ip) do
      {:ok, latency} ->
        %{state | health_status: :healthy, last_poll: DateTime.utc_now()}

      {:error, _} ->
        %{state | health_status: :unreachable, last_poll: DateTime.utc_now()}
    end
  end
end
```

**Ash Integration - Starting Actors from Resources**:
```elixir
defmodule ServiceRadar.Inventory.Device do
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  actions do
    action :start_monitoring, :struct do
      constraints instance_of: __MODULE__
      argument :device, :struct, constraints: [instance_of: __MODULE__]

      run fn input, context ->
        device = input.arguments.device
        # tenant_id comes from Ash context (set by actor)
        tenant_id = context.tenant || device.tenant_id

        # Start the actor in the distributed cluster
        case Horde.DynamicSupervisor.start_child(
          ServiceRadar.PollerSupervisor,
          {ServiceRadar.DeviceActor, [
            tenant_id: tenant_id,
            partition_id: device.partition_id,
            ip: device.ip_address
          ]}
        ) do
          {:ok, _pid} -> {:ok, device}
          {:error, {:already_started, _pid}} -> {:ok, device}
          error -> error
        end
      end
    end
  end
end
```

### Decision 16: Oban Queue Partitioning for Edge Nodes

**What**: Partition Oban queues by edge site, so each poller node only processes jobs for its partition.

**Why**:
- Prevents cross-partition job execution
- Enables horizontal scaling per site
- Jobs stay local to the network they target

**Queue Naming Strategy**:
```
queues:
  - default (cloud-only administrative tasks)
  - partition_1 (Edge Site A jobs)
  - partition_2 (Edge Site B jobs)
  - partition_N (dynamically created)
```

**Edge Node Configuration**:
```elixir
# config/runtime.exs on Edge Poller Node
partition_id = System.get_env("POLLER_PARTITION_ID", "default")

config :serviceradar_web_ng, Oban,
  repo: ServiceRadar.Repo,
  queues: [
    # Only listen to this partition's queue
    {String.to_atom("partition_#{partition_id}"), 10}
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}
  ]
```

**Cloud Scheduling to Partitions**:
```elixir
defmodule ServiceRadar.Monitoring.Jobs.ScheduleSweep do
  use Oban.Worker,
    queue: :default  # Cloud schedules, edge executes

  @impl true
  def perform(%Oban.Job{args: %{"partition_id" => partition_id, "target" => target}}) do
    # Insert job into partition-specific queue
    %{partition_id: partition_id, target: target, scheduled_at: DateTime.utc_now()}
    |> ServiceRadar.Monitoring.Jobs.ExecuteSweep.new(queue: :"partition_#{partition_id}")
    |> Oban.insert!()

    :ok
  end
end

defmodule ServiceRadar.Monitoring.Jobs.ExecuteSweep do
  use Oban.Worker
  # Queue is dynamically set based on partition

  @impl true
  def perform(%Oban.Job{args: %{"partition_id" => partition_id, "target" => target}}) do
    # This runs on the edge node listening to this partition's queue
    result = ServiceRadar.Agent.sweep(target)

    # Publish result via NATS for cloud persistence
    ServiceRadar.Edge.NATSPublisher.publish_sweep_result(partition_id, result)

    :ok
  end
end
```

### Decision 17: Mesh VPN for Distributed Erlang

**What**: Use Tailscale or Nebula mesh VPN to enable full distributed Erlang capabilities across edge sites.

**Why**:
- Enables `Node.connect/1` and `:observer.start()` across the internet
- Provides flat network for Horde CRDT synchronization
- Enables remote shell (`IEx.remsh`) for debugging
- Process visibility across entire deployment

**Network Topology with Mesh VPN**:
```
┌─────────────────────────────────────────────────────────────────┐
│                    TAILSCALE MESH (100.x.x.x)                   │
│                                                                  │
│   ┌─────────────────┐     ┌─────────────────┐                   │
│   │ Cloud Core      │     │ Your Laptop     │                   │
│   │ 100.64.0.1      │     │ 100.64.0.100    │                   │
│   │                 │     │                 │                   │
│   │ :observer.start │◄───►│ IEx.remsh       │                   │
│   │ See all nodes!  │     │ Debug anywhere! │                   │
│   └─────────────────┘     └─────────────────┘                   │
│          ▲                                                       │
│          │ Node.connect(:"poller@100.64.0.10")                  │
│          │                                                       │
│   ┌──────┴────────┐       ┌─────────────────┐                   │
│   │ Edge Poller 1 │       │ Edge Poller 2   │                   │
│   │ 100.64.0.10   │◄─────►│ 100.64.0.20     │                   │
│   │ (London)      │       │ (Tokyo)         │                   │
│   └───────────────┘       └─────────────────┘                   │
│                                                                  │
│   All nodes visible in :observer process tree                    │
│   Kill a process in Tokyo from your laptop in NYC               │
│   Horde automatically restarts it on another node               │
└─────────────────────────────────────────────────────────────────┘
```

**Tailscale ACL for ServiceRadar**:
```json
{
  "acls": [
    {
      "action": "accept",
      "src": ["tag:serviceradar-core"],
      "dst": ["tag:serviceradar-poller:4369,9100-9155"]
    },
    {
      "action": "accept",
      "src": ["tag:serviceradar-poller"],
      "dst": ["tag:serviceradar-poller:4369,9100-9155"]
    },
    {
      "action": "accept",
      "src": ["group:serviceradar-admins"],
      "dst": ["tag:serviceradar-*:*"]
    }
  ],
  "tagOwners": {
    "tag:serviceradar-core": ["autogroup:admin"],
    "tag:serviceradar-poller": ["autogroup:admin"]
  }
}
```

**libcluster Configuration for Tailscale**:
```elixir
# When using Tailscale, nodes have stable 100.x.x.x IPs
config :libcluster,
  topologies: [
    serviceradar: [
      strategy: Cluster.Strategy.Epmd,
      config: [
        hosts: [
          :"core@100.64.0.1",
          :"poller_london@100.64.0.10",
          :"poller_tokyo@100.64.0.20"
        ]
      ]
    ]
  ]

# Or use Tailscale's DNS for dynamic discovery
config :libcluster,
  topologies: [
    serviceradar: [
      strategy: Cluster.Strategy.DNSPoll,
      config: [
        polling_interval: 5_000,
        query: "serviceradar.tailnet-name.ts.net",
        node_basename: "serviceradar"
      ]
    ]
  ]
```

**The Debugging Experience**:
```elixir
# From your laptop, connect to cloud core
$ iex --sname debug --cookie $COOKIE --remsh core@100.64.0.1

# List all nodes in the cluster
iex> Node.list()
[:"poller_london@100.64.0.10", :"poller_tokyo@100.64.0.20"]

# Start observer - see processes on ALL nodes
iex> :observer.start()
# Switch to "Nodes" tab, select poller_tokyo
# See exact memory usage of DeviceActor for 10.0.0.1 in Tokyo!

# Inspect a device actor running in London (must include tenant_id for isolation)
iex> ServiceRadar.DeviceActor.get_status("tenant_abc", "partition_1", "10.0.0.1")
%{tenant_id: "tenant_abc", ip: "10.0.0.1", partition: "partition_1", health: :healthy, last_poll: ~U[...]}

# The call transparently routes to London via ERTS distribution!
```

### Decision 18: tenant_id Immutability as Security Control

**What**: Make `tenant_id` immutable after user creation - it cannot be changed by any user, including super_admins.

**Why**:
- **Prevents tenant hopping attacks** - Malicious users cannot move themselves to other tenants
- **Data integrity** - User audit trails remain consistent with their original tenant
- **Defense in depth** - Even if authorization is bypassed, tenant assignment cannot change
- **Simplifies security reasoning** - No need to audit tenant change flows

**Implementation (3 layers of protection)**:

1. **Action Accept Lists** - Update actions only accept specific fields (never tenant_id):
   ```elixir
   update :update do
     accept [:display_name]  # tenant_id not included
   end
   ```

2. **Resource-Level Change Hook** - Blocks all tenant_id modifications including `force_change_attribute`:
   ```elixir
   changes do
     change before_action(fn changeset, _context ->
       if changeset.action_type == :update do
         case Map.get(changeset.attributes, :tenant_id) do
           nil -> changeset
           _new_value ->
             Ash.Changeset.add_error(changeset,
               field: :tenant_id,
               message: "cannot be changed - tenant assignment is permanent"
             )
         end
       else
         changeset
       end
     end)
   end
   ```

3. **Policy Tests** - Comprehensive test suite verifying immutability:
   - Test: Regular users cannot change their tenant_id
   - Test: Admins cannot change user tenant_id
   - Test: Super_admins cannot change tenant_id (defense in depth)
   - Test: `force_change_attribute` is blocked

**Why super_admins cannot change tenant_id**:
- Tenant transfers should be a separate, audited process (not a simple update)
- Prevents accidental data leakage via admin UI
- Moving a user between tenants has complex implications (permissions, data access)
- If needed, create a separate audited action with explicit business justification

## Risks / Trade-offs

| Risk | Impact | Mitigation |
|------|--------|------------|
| Ash learning curve | Medium | Team training, incremental adoption |
| Performance regression | High | Benchmark critical paths, keep Ecto for hot paths if needed |
| Migration complexity | High | Phased approach, feature flags, extensive testing |
| Dependency on Ash ecosystem | Medium | Ash is well-maintained, can fall back to raw Ecto |
| Multi-tenancy data leakage | Critical | Policy tests, security audit, penetration testing |
| Mesh VPN dependency | Medium | NATS backhaul works without VPN, degraded debugging only |
| NATS JetStream complexity | Medium | Existing datasvc team expertise, proven technology |
| Overlapping IP confusion | High | Strict partition_id enforcement at all levels |

## Migration Plan

### Phase 1: Foundation (Weeks 1-4)
1. Add Ash dependencies to mix.exs
2. Create `ServiceRadar.Identity` domain with User resource
3. Implement AshAuthentication with magic link + password
4. Add tenant_id to users table, create Tenant resource
5. Deploy behind feature flag

### Phase 2: Core Resources (Weeks 5-8)
1. Create `ServiceRadar.Inventory` domain
2. Convert Device Ecto schema to Ash resource
3. Map OCSF columns with `source:` option
4. Add device policies for tenant isolation
5. Create AshJsonApi routes at `/api/v2/devices`

### Phase 3: Infrastructure (Weeks 9-12)
1. Create `ServiceRadar.Infrastructure` domain
2. Convert Poller, Agent resources
3. Implement partition-aware policies
4. Add state machines for agent lifecycle
5. Begin AshOban migration for infrastructure jobs

### Phase 4: Monitoring & Events (Weeks 13-16)
1. Create `ServiceRadar.Monitoring` domain
2. Implement Alert state machine
3. Add AshOban triggers for check scheduling
4. Convert event publishing to Ash notifiers
5. Integrate AshStateMachine for alert lifecycle

### Phase 5: Full Cutover (Weeks 17-20)
1. Migrate remaining custom Oban jobs to AshOban
2. Deprecate `/api/` v1 endpoints
3. Remove feature flags, old code paths
4. Performance optimization
5. Security audit

### Rollback Procedure
Each phase includes:
1. Feature flag to disable new implementation
2. Database migration reversibility
3. API version fallback
4. Monitoring for error rate spikes

### Decision 11: SRQL Integration with Ash Query System

**What**: Create an SRQL-to-Ash adapter that translates SRQL queries into Ash.Query operations, while keeping the Rust NIF for complex TimescaleDB operations.

**Why**:
- SRQL is already used extensively in dashboards and LiveViews
- Ash.Query provides type-safe filtering, sorting, pagination
- Ash policies automatically apply to all queries (tenant isolation)
- Can validate SRQL fields against Ash resource attributes
- Gradual migration: SRQL can route through Ash or direct SQL based on entity

**Architecture**:
```
┌─────────────────────────────────────────────────────────────────┐
│                    SRQL Query Flow                               │
│                                                                  │
│  ┌──────────┐    ┌───────────────┐    ┌──────────────────────┐ │
│  │  SRQL    │───▶│ SRQL Parser   │───▶│ Route Decision       │ │
│  │  Query   │    │ (Builder.ex)  │    │                      │ │
│  └──────────┘    └───────────────┘    └──────────┬───────────┘ │
│                                                   │             │
│                          ┌────────────────────────┴───────┐    │
│                          ▼                                ▼    │
│               ┌──────────────────┐            ┌───────────────┐│
│               │ Ash Query Path   │            │ SQL Path      ││
│               │ (Standard CRUD)  │            │ (TimescaleDB) ││
│               │                  │            │               ││
│               │ - Devices        │            │ - Metrics     ││
│               │ - Pollers        │            │ - Flows       ││
│               │ - Agents         │            │ - Traces      ││
│               │ - Events         │            │ - Logs        ││
│               └────────┬─────────┘            └───────┬───────┘│
│                        │                              │        │
│                        ▼                              ▼        │
│               ┌──────────────────┐            ┌───────────────┐│
│               │ Ash.Policy       │            │ Rust NIF      ││
│               │ Authorization    │            │ + Raw SQL     ││
│               └────────┬─────────┘            └───────┬───────┘│
│                        │                              │        │
│                        └──────────────┬───────────────┘        │
│                                       ▼                        │
│                              ┌──────────────────┐              │
│                              │    CNPG/         │              │
│                              │    TimescaleDB   │              │
│                              └──────────────────┘              │
└─────────────────────────────────────────────────────────────────┘
```

**Implementation Strategy**:

1. **SRQL Entity to Ash Resource Mapping**:
   ```elixir
   @srql_ash_mapping %{
     "devices" => ServiceRadar.Inventory.Device,
     "pollers" => ServiceRadar.Infrastructure.Poller,
     "agents" => ServiceRadar.Infrastructure.Agent,
     "events" => ServiceRadar.Monitoring.Event,
     # Keep in SQL path (complex time operations)
     "metrics" => :sql_path,
     "flows" => :sql_path,
     "traces" => :sql_path
   }
   ```

2. **SRQL Filter to Ash Filter Translation**:
   ```elixir
   def srql_filter_to_ash(%{"field" => field, "op" => "contains", "value" => value}) do
     Ash.Query.filter(contains(^ref(field), ^value))
   end

   def srql_filter_to_ash(%{"field" => field, "op" => "equals", "value" => value}) do
     Ash.Query.filter(^ref(field) == ^value)
   end
   ```

3. **Automatic Policy Application**:
   ```elixir
   def execute_srql(query, actor) do
     case parse_and_route(query) do
       {:ash, resource, filters, opts} ->
         resource
         |> Ash.Query.new()
         |> apply_srql_filters(filters)
         |> apply_srql_sort(opts)
         |> apply_srql_pagination(opts)
         |> Ash.read!(actor: actor)  # Policies enforced automatically

       {:sql, parsed} ->
         # Existing Rust NIF path with manual tenant filtering
         execute_sql_with_tenant(parsed, actor)
     end
   end
   ```

4. **Ash Calculations for SRQL Computed Fields**:
   ```elixir
   # In Device resource
   calculations do
     calculate :display_name, :string, expr(
       coalesce(hostname, name, ip, uid)
     )

     calculate :status_color, :string, expr(
       cond do
         is_available == true -> "green"
         last_seen_time > ago(1, :hour) -> "yellow"
         true -> "red"
       end
     )
   end
   ```

5. **Pagination Alignment**:
   - SRQL uses cursor-based pagination
   - Ash supports keyset pagination natively
   - Map SRQL cursors to Ash keyset format

**Benefits**:
- Tenant isolation enforced via Ash policies (no manual `tenant_id` filtering)
- Type validation of filter fields against resource attributes
- Consistent pagination behavior
- Can deprecate SRQL entities one-by-one as Ash resources mature
- Keep Rust NIF for performance-critical time-series queries

**Migration Path**:
1. Create `ServiceRadarWebNG.SRQL.AshAdapter` module
2. Route simple entities (devices, pollers) through Ash
3. Keep complex entities (metrics, traces) on SQL path
4. Monitor performance, migrate more entities as confidence grows
5. Eventually: Generate SRQL syntax from Ash Query DSL

## Open Questions

1. **Horde vs Oban for distributed job coordination?**
   - Horde for process distribution, Oban for job persistence
   - May need both for different use cases

2. **TimescaleDB compatibility with Ash aggregates?**
   - Need to test time_bucket calculations as Ash calculations
   - May need raw SQL for complex timeseries queries

3. **OAuth2 provider configuration per-tenant?**
   - Should tenants configure their own IdPs?
   - Enterprise feature for future consideration

4. **GraphQL in addition to JSON:API?**
   - AshGraphql available but JSON:API sufficient for v1
   - Can add GraphQL later based on demand

5. **Event sourcing via AshEvents?**
   - Consider for audit-critical domains (identity changes)
   - Full event sourcing may be overkill initially
