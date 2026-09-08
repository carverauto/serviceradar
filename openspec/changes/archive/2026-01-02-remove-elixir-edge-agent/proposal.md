# Change: Remove Elixir Edge Agent - Use Go Agent over gRPC Only

## Why

The current architecture has a critical security flaw: Elixir agents (`serviceradar_agent`) deployed in customer networks join the ERTS cluster alongside core services. This means:

1. **Full RPC access** - Edge nodes can execute `:rpc.call(core_node, Module, :function, [args])` to run arbitrary code on core nodes
2. **Horde cluster membership** - Edge can enumerate and message any process in the cluster
3. **Observer/debugging access** - ERTS distribution enables remote introspection
4. **Attack surface** - Compromised edge = compromised core

Even with per-tenant process isolation (TenantGuard, TenantRegistry), an attacker with code execution on an edge node bypasses all tenant boundaries via ERTS distribution primitives.

## What Changes

### **BREAKING**: Remove `serviceradar_agent` (Elixir)

The Elixir agent application is removed from edge deployments. Edge components use the existing Go-based `serviceradar-agent` which communicates via gRPC only.

### Architecture: Secure Network Boundary

```
Customer Network              Our Network (Kubernetes)
+------------------+         +--------------------------------+
|  Go Agent        |<--------|  Pollers <--> Core <--> Web    |
|  (gRPC server)   |  gRPC   |  (ERTS cluster, Horde, Ash)    |
|                  |  mTLS   |                                 |
+------------------+         +--------------------------------+
                              ^
                              | Communication flows DOWN
                              | (Pollers initiate to agents)
```

### Key Changes

1. **Remove `elixir/serviceradar_agent/`** - Delete the Elixir agent application
2. **Pollers initiate connections** - Pollers (in our network) call agents (in customer network) via gRPC, not reverse
3. **ERTS cluster is internal** - Only core, pollers, and web-ng join the Erlang cluster
4. **Go agent is passive** - Exposes gRPC endpoint, responds to poller requests
5. **Firewall simplified** - Customers only open gRPC port (50051), no ERTS distribution ports

### Security Properties

| Threat | Before | After |
|--------|--------|-------|
| Edge runs `:rpc.call` on core | Possible | Impossible (no ERTS) |
| Edge enumerates Horde processes | Possible | Impossible (no cluster membership) |
| Edge accesses other tenants | Requires TenantGuard bypass | Impossible (network isolated) |
| Compromised edge affects core | Full cluster access | Limited to gRPC responses |

## Impact

- Affected specs: NEW `edge-architecture` capability
- Affected code:
  - `elixir/serviceradar_agent/` - **DELETED**
  - `cmd/agent/` - Already exists, becomes sole edge agent
  - `elixir/serviceradar_poller/` - Must initiate gRPC connections to agents
  - `elixir/serviceradar_core/lib/serviceradar/cluster/` - Remove agent ERTS integration
  - Helm charts - Remove Elixir agent deployment, update agent to Go-only
  - Documentation - Update architecture diagrams
