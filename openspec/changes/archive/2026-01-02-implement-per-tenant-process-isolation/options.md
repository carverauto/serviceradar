# Multi-Tenant Clustering Options

## The Problem

Currently, the `PollerRegistry` has tenant-scoped lookups, but **that's only enforcement at query time**, not at the network level.

The security issue:
1. All nodes join the same ERTS cluster via libcluster (`:auto` members)
2. All pollers register in the same `Horde.Registry`
3. An attacker on Tenant A's poller can `iex --remsh` and:
   - `Horde.Registry.select(ServiceRadar.PollerRegistry, ...)` to find ALL pollers
   - Send messages directly to Tenant B's poller PIDs
   - `:observer.start()` and see everything
   - Execute arbitrary code on any node in the cluster

## Option A: Per-Tenant libcluster Topologies

Each tenant has its own libcluster topology. Core participates in all.

```elixir
# Core runs multiple cluster supervisors
defmodule ServiceRadar.TenantClusterManager do
  def start_tenant_topology(tenant_slug) do
    topology = {
      String.to_atom("tenant_#{tenant_slug}"),
      [
        strategy: Cluster.Strategy.Epmd,
        config: [hosts: []],  # Dynamically populated
        connect: {__MODULE__, :tenant_connect_filter, [tenant_slug]},
        disconnect: {__MODULE__, :tenant_disconnect, [tenant_slug]}
      ]
    }

    Cluster.Supervisor.start_link([topology], name: :"ClusterSup.#{tenant_slug}")
  end

  # Only allow connections from nodes with matching tenant cert
  def tenant_connect_filter(node, tenant_slug) do
    case validate_node_tenant(node, tenant_slug) do
      :ok -> true
      _ -> false
    end
  end
end
```

**Pros:**
- Strong network-level isolation
- Nodes literally can't see each other across tenants
- Core can selectively participate in each tenant's cluster

**Cons:**
- Complex: core needs N cluster supervisors for N tenants
- libcluster doesn't natively support dynamic topology creation
- Node discovery becomes tenant-specific (separate DNS/K8s selectors per tenant)
- May hit scalability limits with many tenants

---

## Option B: Per-Tenant Horde Registries (Dynamic)

Single ERTS cluster, but separate Horde registries per tenant.

```elixir
defmodule ServiceRadar.TenantRegistry do
  @moduledoc """
  Manages per-tenant Horde registries for process isolation.
  """

  # Get or create a tenant's registry
  def registry_for(tenant_slug) do
    name = registry_name(tenant_slug)

    case Process.whereis(name) do
      nil -> start_tenant_registry(tenant_slug)
      pid -> {:ok, pid}
    end
  end

  def registry_name(tenant_slug) do
    Module.concat([ServiceRadar.PollerRegistry, Macro.camelize(tenant_slug)])
    # e.g., ServiceRadar.PollerRegistry.AcmeCorp
  end

  def start_tenant_registry(tenant_slug) do
    name = registry_name(tenant_slug)

    Horde.Registry.start_link(
      name,
      keys: :unique,
      members: :auto,
      delta_crdt_options: [sync_interval: 100]
    )
  end

  # Poller registers in its tenant's registry
  def register_poller(tenant_slug, poller_id, metadata) do
    {:ok, registry} = registry_for(tenant_slug)
    Horde.Registry.register(registry, poller_id, metadata)
  end

  # Lookup only searches tenant's registry
  def find_pollers(tenant_slug) do
    name = registry_name(tenant_slug)
    Horde.Registry.select(name, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
  end
end
```

**Pros:**
- Single ERTS cluster (simpler ops)
- Natural isolation - edge nodes can't find other tenant's registry names
- Dynamic creation on tenant onboarding
- Scales well - just more GenServers

**Cons:**
- Nodes ARE still in same cluster - can still discover each other via `Node.list()`
- Attacker could try to brute-force registry names
- Doesn't prevent direct PID messaging if attacker knows a PID

**Mitigation for Cons:**
- Registry names use tenant UUID, not slug: `ServiceRadar.PollerRegistry.T_a1b2c3d4`
- Process-level validation as additional layer (see Option C)

---

## Option C: Process-Level Authorization (Defense in Depth)

All nodes in same cluster, but every operation validates tenant.

```elixir
defmodule ServiceRadar.TenantGuard do
  @moduledoc """
  Validates tenant authorization for inter-process communication.
  """

  # Called in handle_call/handle_cast of every tenant-aware GenServer
  defmacro validate_tenant!(expected_tenant) do
    quote do
      caller_tenant = ServiceRadar.TenantGuard.get_caller_tenant()

      unless caller_tenant == unquote(expected_tenant) or caller_tenant == :platform_admin do
        raise ServiceRadar.TenantViolation,
          message: "Cross-tenant access denied",
          expected: unquote(expected_tenant),
          actual: caller_tenant
      end
    end
  end

  # Get tenant from calling process's certificate/context
  def get_caller_tenant do
    case Process.get(:serviceradar_tenant) do
      nil ->
        # Try to extract from caller's node certificate
        extract_tenant_from_node(node())
      tenant ->
        tenant
    end
  end

  # Extract tenant from node's certificate CN
  def extract_tenant_from_node(node_name) do
    # Node name format: poller-001@partition-1.acme-corp.serviceradar
    # Or use :ssl.peercert to get actual cert
    case parse_node_name(node_name) do
      {:ok, %{tenant_slug: slug}} -> slug
      _ -> nil
    end
  end
end

# Usage in a GenServer
defmodule ServiceRadar.Poller.TaskExecutor do
  use GenServer
  import ServiceRadar.TenantGuard

  def handle_call({:execute_task, task}, _from, state) do
    validate_tenant!(state.tenant_slug)  # Raises if mismatch

    # ... execute task
    {:reply, :ok, state}
  end
end
```

**Pros:**
- Defense in depth - even if attacker finds a PID, calls are rejected
- Works with any clustering approach
- Audit trail of attempted violations

**Cons:**
- Doesn't prevent discovery (attacker can still enumerate)
- Requires discipline - every GenServer must validate
- Performance overhead on every call

---

## Option D: Hybrid Approach (Recommended)

Combine Options B + C for layered security:

1. **Per-tenant Horde registries** (Option B) - Isolation by default
2. **Process-level validation** (Option C) - Defense in depth
3. **Certificate-based tenant identity** - Already implemented

```
┌─────────────────────────────────────────────────────────────────┐
│                         ERTS Cluster                             │
│                                                                  │
│  ┌──────────────────────┐    ┌──────────────────────┐           │
│  │ Tenant: acme-corp    │    │ Tenant: xyz-inc      │           │
│  │                      │    │                      │           │
│  │ Registry: Horde.Acme │    │ Registry: Horde.Xyz  │           │
│  │ ┌────────┐ ┌───────┐ │    │ ┌────────┐ ┌───────┐ │           │
│  │ │Poller-1│ │Agent-1│ │    │ │Poller-1│ │Agent-1│ │           │
│  │ └────────┘ └───────┘ │    │ └────────┘ └───────┘ │           │
│  │                      │    │                      │           │
│  │ Certificate:         │    │ Certificate:         │           │
│  │ *.acme-corp.svcradar │    │ *.xyz-inc.svcradar   │           │
│  └──────────────────────┘    └──────────────────────┘           │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    Core (all tenants)                     │   │
│  │  - Participates in all tenant registries                 │   │
│  │  - Certificate: core.platform.serviceradar               │   │
│  │  - TenantResolver extracts tenant from client certs      │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

**Security Layers:**
1. Certificate CN contains tenant → Can't be spoofed
2. Poller only knows its own registry name → Can't query other tenants
3. Every GenServer validates caller tenant → Defense in depth
4. NATS channels prefixed with tenant → Message isolation

---

## Recommendation

**Start with Option B (Per-Tenant Horde Registries)** because:
- Simplest to implement
- Doesn't require libcluster changes
- Natural isolation model
- Can add Option C validation later as defense in depth

**Implementation Steps:**
1. Create `ServiceRadar.TenantRegistry` module for dynamic registry management
2. Update `PollerRegistry` to use tenant-specific registries
3. Update poller/agent to register in tenant-scoped registry
4. Update core lookups to query correct tenant registry
5. Add `TenantGuard` for defense in depth (future phase)

---

---

## Option E: PostgreSQL Schema-Based Isolation (SOC2 Compliance)

For enterprise tenants requiring SOC2 compliance, use PostgreSQL schemas for physical data isolation.

### Ash Configuration

```elixir
# For schema-isolated resources
defmodule ServiceRadar.Inventory.Device do
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "devices"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :context
    # Schema name derived from tenant
    # e.g., tenant "acme-corp" -> schema "tenant_acme_corp"
  end
end
```

### Schema Management

```elixir
defmodule ServiceRadar.TenantSchemas do
  @moduledoc """
  Manages PostgreSQL schemas for tenant isolation.
  """

  def create_tenant_schema(tenant_slug) do
    schema_name = schema_for(tenant_slug)

    # Create schema
    Ecto.Adapters.SQL.query!(
      ServiceRadar.Repo,
      "CREATE SCHEMA IF NOT EXISTS #{schema_name}"
    )

    # Run migrations for this schema
    Ecto.Migrator.run(
      ServiceRadar.Repo,
      migrations_path(),
      :up,
      prefix: schema_name
    )
  end

  def schema_for(tenant_slug) do
    # Sanitize slug for schema name
    safe_slug = String.replace(tenant_slug, ~r/[^a-z0-9_]/, "_")
    "tenant_#{safe_slug}"
  end
end
```

### Dynamic Schema Switching

```elixir
# In Repo
defmodule ServiceRadar.Repo do
  use Ecto.Repo, otp_app: :serviceradar_core

  # Called on every query
  def default_options(_opts) do
    case get_tenant() do
      nil -> []
      tenant -> [prefix: TenantSchemas.schema_for(tenant)]
    end
  end

  def set_tenant(tenant_slug) do
    Process.put(:serviceradar_tenant, tenant_slug)
  end

  def get_tenant do
    Process.get(:serviceradar_tenant)
  end
end
```

### Hybrid Approach: Attribute + Schema

For flexibility, use BOTH strategies:

```elixir
# Tenant table in public schema (cross-tenant lookups)
defmodule ServiceRadar.Identity.Tenant do
  multitenancy do
    strategy :attribute  # In public schema
    attribute :id
    global? true
  end
end

# Device data in tenant-specific schemas
defmodule ServiceRadar.Inventory.Device do
  multitenancy do
    strategy :context  # Uses tenant_<slug> schema
  end
end
```

**Pros:**
- Physical data isolation at database level
- Native PostgreSQL schema permissions
- Clearer SOC2 audit boundaries
- Easy per-tenant backup/restore
- Can combine with Row-Level Security (RLS)

**Cons:**
- More complex migrations (run per schema)
- Schema creation overhead on tenant signup
- Need to manage schema lifecycle (delete on tenant removal)
- Connection pool considerations

---

## SOC2 Compliance Layers

For full SOC2 compliance, implement ALL layers:

| Layer | Isolation Type | Implementation |
|-------|----------------|----------------|
| **Network** | mTLS + Tenant CA | Per-tenant intermediate CAs |
| **Process** | Horde Registry | Per-tenant registries (Option B) |
| **Application** | GenServer Guard | TenantGuard validation (Option C) |
| **Data** | Ash Multitenancy | Attribute or Context strategy |
| **Database** | PostgreSQL Schema | `strategy :context` (Option E) |
| **Messaging** | NATS Prefix | Tenant-prefixed channels |

### Tiered Isolation by Plan

```elixir
defmodule ServiceRadar.TenantIsolation do
  @doc """
  Returns isolation level based on tenant plan.
  """
  def isolation_level(tenant) do
    case tenant.plan do
      :enterprise -> :schema    # Full schema isolation
      :pro -> :attribute        # Attribute-based with extra auditing
      :free -> :attribute       # Basic attribute-based
    end
  end
end
```

---

## Questions to Resolve

1. **Registry Naming:** UUID-based (secure) or slug-based (debuggable)?
2. **Registry Lifecycle:** Create on first poller connect? Or on tenant creation?
3. **Core Access:** Does core join all registries, or query on-demand?
4. **Supervisor Trees:** Per-tenant DynamicSupervisors too, or just registries?
5. **Schema Strategy:** All tenants use schemas, or only enterprise tier?
6. **Migration Tooling:** Use Triplex library or custom schema migration?
