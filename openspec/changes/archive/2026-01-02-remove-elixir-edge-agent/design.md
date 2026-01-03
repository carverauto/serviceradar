## Context

ServiceRadar has two agent implementations:
1. **Go Agent** (`cmd/agent/`) - gRPC-based, lightweight, production-ready
2. **Elixir Agent** (`elixir/serviceradar_agent/`) - ERTS cluster member, integrates with Horde

The Elixir agent was designed to leverage ERTS distribution for:
- Direct process registration in Horde registries
- Phoenix PubSub for real-time events
- Remote debugging via Observer

However, this creates a fundamental security flaw: edge nodes in customer networks become full cluster members with ability to execute arbitrary code on core nodes.

## Goals / Non-Goals

**Goals:**
- Eliminate ERTS distribution from edge deployments
- Maintain full monitoring functionality via gRPC
- Keep ERTS cluster benefits for internal services (core, pollers, web)
- Simplify customer firewall requirements
- Enable secure multi-tenant edge deployments

**Non-Goals:**
- Changing the Go agent's existing gRPC interface (already works)
- Removing ERTS from internal cluster (core-poller-web)
- Re-implementing Horde or distributed scheduling

## Decisions

### Decision 1: Remove Elixir Agent Entirely

**What:** Delete `elixir/serviceradar_agent/` and all references.

**Why:**
- Go agent already provides full functionality via gRPC
- Maintaining two agent implementations is unnecessary
- ERTS cluster membership from edge is a security liability

**Alternatives considered:**
- Disable ERTS in Elixir agent: Complex, breaks Horde integration
- Firewall ERTS ports: Doesn't prevent RPC from compromised node
- Keep both: Maintenance burden, confusing deployment options

### Decision 2: Pollers Initiate Connections to Agents

**What:** Pollers (in our Kubernetes) make outbound gRPC calls to agents (in customer network).

**Why:**
- Communication flows from trusted to untrusted network
- Agent cannot initiate requests to core services
- Standard "phone home" security pattern

**Trade-offs:**
- Requires agents to have reachable gRPC endpoint
- NAT traversal may require additional infrastructure (VPN, Tailscale, Cloudflare Tunnel)
- Real-time events require polling or long-lived connections

### Decision 3: ERTS Cluster Remains Internal

**What:** Only `core-elx`, `poller`, and `web-ng` join the Erlang cluster.

**Why:**
- These run in our Kubernetes with network policies
- Horde distributed registry still works for poller scheduling
- Ash Oban job scheduling works across nodes
- Observer/debugging available for ops

**Architecture:**
```
Kubernetes Cluster (Trusted)          Customer Network (Untrusted)
+----------------------------+        +-------------------+
|  core-elx <-ERTS-> poller  |--gRPC->|  Go Agent         |
|      ^                     |        +-------------------+
|      |                     |        +-------------------+
|   web-ng                   |--gRPC->|  Go Agent         |
|      ^                     |        +-------------------+
|      |                     |
|  (Horde, Oban, PubSub)     |
+----------------------------+
```

### Decision 4: Per-Tenant mTLS for Agent Authentication

**What:** Each tenant's agents get certificates signed by tenant-specific CA.

**Why:**
- Agents authenticate via client certificate
- Pollers verify certificate belongs to expected tenant
- Cross-tenant agent access prevented at TLS layer

**Integration with existing work:**
- TenantResolver already extracts tenant from client cert CN
- TenantCA already generates per-tenant intermediate CAs
- SPIFFE identities encode tenant in workload path

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Loss of real-time Horde events | Pollers poll agents on schedule; gRPC streaming for live data |
| NAT traversal complexity | Document VPN/tunnel options; most enterprise networks have DMZ |
| Migration disruption | Elixir agent not widely deployed yet; clean break is easier |
| Observer not available for edge | Edge debugging via gRPC health endpoints and logs |

## Migration Plan

1. **Announce deprecation** - Elixir agent marked deprecated in docs
2. **Remove from Helm charts** - Default deployments use Go agent only
3. **Delete source code** - Remove `elixir/serviceradar_agent/`
4. **Update documentation** - Architecture diagrams show Go agent only
5. **Update onboarding** - Edge onboarding generates Go agent configs

**Rollback:** If issues discovered, re-add Elixir agent from git history. However, security concerns mean we should not rollback without fixing ERTS distribution exposure.

## Open Questions

1. **gRPC streaming for events?** - Should agents stream events to pollers, or should pollers poll?
   - Recommendation: Pollers poll on schedule; streaming optional for real-time use cases

2. **Agent discovery?** - How do pollers know which agents to contact?
   - Recommendation: Agent registration via core API; pollers query core for assigned agents

3. **Health monitoring?** - How to detect agent is down?
   - Recommendation: gRPC health checks + heartbeat timeout in core
