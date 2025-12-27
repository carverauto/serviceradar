# Design: Per-Tenant Process Isolation

## Context

ServiceRadar is evolving from a single-tenant monitoring platform to a multi-tenant SaaS. The architecture must provide:
- Strong tenant isolation for compliance and security
- Cost-effective shared infrastructure where safe
- Practical deployment for customer-managed edge components

### Stakeholders
- **Platform operators**: Need simple management of shared infrastructure
- **Tenant admins**: Need confidence their data is isolated
- **Edge deployments**: Customer sites run tenant-specific agents/pollers

## Goals / Non-Goals

### Goals
- **Process isolation** for edge components (agents, pollers, collectors, checkers)
- **Per-tenant mTLS certificates** - edge components authenticate to control plane using tenant-scoped certs
- **Onboarding flow** generates tenant-specific certificate bundles
- **Network-level RBAC** - tenant A's agents cannot connect to tenant B's pollers

### Non-Goals (out of scope for this change)
- Per-tenant databases (shared CNPG with tenant_id filtering is acceptable)
- Per-tenant web-ng instances (shared Phoenix app with session-based tenant context)
- Per-tenant core-elx instances (shared control plane)
- Per-tenant NATS clusters (shared JetStream with tenant channel prefixes)

## Decisions

### Decision 1: Hybrid Architecture

**What**: Shared control plane, isolated edge components

```
┌─────────────────────────────────────────────────────────────┐
│                    SHARED CONTROL PLANE                     │
│  ┌─────────┐    ┌───────────┐    ┌────────┐    ┌─────────┐  │
│  │ web-ng  │    │ core-elx  │    │  CNPG  │    │  NATS   │  │
│  │ (multi- │    │ (multi-   │    │(shared │    │(shared, │  │
│  │ tenant) │    │  tenant)  │    │   DB)  │    │prefixed)│  │
│  └─────────┘    └───────────┘    └────────┘    └─────────┘  │
│       │              │                                       │
│       │    mTLS (tenant-scoped certs)                       │
│       ▼              ▼                                       │
└─────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│   TENANT A      │  │   TENANT B      │  │   TENANT C      │
│  ┌──────────┐   │  │  ┌──────────┐   │  │  ┌──────────┐   │
│  │ poller-a │   │  │  │ poller-b │   │  │  │ poller-c │   │
│  └──────────┘   │  │  └──────────┘   │  │  └──────────┘   │
│  ┌──────────┐   │  │  ┌──────────┐   │  │  ┌──────────┐   │
│  │ agent-a1 │   │  │  │ agent-b1 │   │  │  │ agent-c1 │   │
│  │ agent-a2 │   │  │  │ agent-b2 │   │  │  │ agent-c2 │   │
│  └──────────┘   │  │  └──────────┘   │  │  └──────────┘   │
│  mTLS: CA-A     │  │  mTLS: CA-B     │  │  mTLS: CA-C     │
└─────────────────┘  └─────────────────┘  └─────────────────┘
```

**Why**:
- Shared infrastructure (web-ng, core, DB) is cost-effective and simple
- Edge isolation provides security where customers deploy agents
- Existing Ash multitenancy works well for DB-backed resources

### Decision 2: Per-Tenant Certificate Authority (or Intermediate CA)

**What**: Each tenant gets a dedicated CA (or intermediate CA signed by root)

```
Root CA (ServiceRadar Platform)
├── Tenant-A Intermediate CA
│   ├── poller-a.tenant-a.serviceradar (server cert)
│   ├── agent-a1.tenant-a.serviceradar (client cert)
│   └── agent-a2.tenant-a.serviceradar (client cert)
├── Tenant-B Intermediate CA
│   ├── poller-b.tenant-b.serviceradar (server cert)
│   └── agent-b1.tenant-b.serviceradar (client cert)
└── Platform Services CA (shared infrastructure)
    ├── core-elx.serviceradar (server cert)
    ├── web-ng.serviceradar (server cert)
    └── nats.serviceradar (server cert)
```

**Why**:
- mTLS validation at edge components ensures only same-tenant connections
- Compromised tenant cert cannot impersonate another tenant
- Revocation is tenant-scoped (revoke one tenant's CA without affecting others)

**Alternatives considered**:
- Shared CA with CN-based filtering: Simpler but less isolated - rejected
- SPIFFE with per-tenant SPIRE servers: More complex - future consideration

### Decision 3: Tenant-Aware Edge Onboarding

**What**: Onboarding packages include tenant-scoped certificates

When admin (in tenant context) generates onboarding package:
1. System generates certificate signed by tenant's CA
2. Package includes: agent binary, tenant CA cert, agent cert/key, config
3. Config includes tenant-specific endpoints and identifiers
4. EPMD cookie is tenant-scoped (prevents cross-tenant Erlang clustering)

**Why**:
- Prevents misconfiguration where agent connects to wrong tenant
- Self-contained packages for customer deployments
- Enables "download and run" experience

### Decision 4: Core-Elx Validates Tenant from Certificate

**What**: When edge component connects to core-elx, core extracts tenant ID from certificate

```elixir
# Certificate CN format: <component>.<tenant-id>.serviceradar
# Example: agent-001.tenant-12345.serviceradar

# In gRPC/Phoenix handler:
def extract_tenant_from_cert(conn) do
  cert = get_peer_cert(conn)
  cn = get_common_name(cert)
  # Parse tenant ID from CN
  tenant_id = parse_tenant_from_cn(cn)
  # Validate tenant exists and is active
  {:ok, tenant_id}
end
```

**Why**:
- Cryptographic proof of tenant identity (cannot be spoofed)
- No reliance on headers or parameters that could be forged
- Consistent with existing mTLS architecture

### Decision 5: NATS Channel Prefixing

**What**: Each tenant's messages go to prefixed channels

```
# Tenant A channels
tenant-a.pollers.heartbeat
tenant-a.agents.status
tenant-a.jobs.dispatch

# Tenant B channels
tenant-b.pollers.heartbeat
tenant-b.agents.status
tenant-b.jobs.dispatch
```

**Why**:
- Simple isolation without per-tenant NATS clusters
- JetStream streams can be tenant-scoped
- Existing NATS infrastructure reused

**Alternatives considered**:
- Per-tenant NATS clusters: More isolation but significant resource overhead
- NATS accounts: Good isolation but requires NATS configuration per tenant

## Risks / Trade-offs

| Risk | Impact | Mitigation |
|------|--------|------------|
| Certificate management complexity | Medium | Automate CA generation, store in Vault/secrets manager |
| Edge components need CA updates on cert rotation | Low | Include CA refresh endpoint in edge onboarding |
| Shared core-elx is single point of failure | Medium | Kubernetes HA deployment, circuit breakers |
| DB tenant_id filtering still possible to misconfigure | Low | Ash policies + integration tests for isolation |

## Migration Plan

### Phase 1: Certificate Infrastructure
1. Update generate-certs.sh to support tenant-scoped CAs
2. Add tenant CA generation to tenant creation workflow
3. Store tenant CA certs/keys in secrets (Vault or K8s secrets)

### Phase 2: Edge Onboarding Updates
1. Update onboarding package generation to use tenant CA
2. Include tenant ID in certificate CN
3. Update agent/poller config to include tenant endpoints

### Phase 3: Core Validation
1. Add certificate CN parsing to core-elx gRPC handlers
2. Validate tenant ID matches authenticated tenant
3. Reject cross-tenant connection attempts

### Phase 4: NATS Channel Migration
1. Add tenant prefix to channel names in publishers
2. Update subscribers to use tenant-prefixed channels
3. Migrate existing messages (or accept message loss during transition)

### Rollback
- Keep shared certificate chain as fallback
- Feature flag to toggle tenant-aware validation
- Database migrations are additive (no destructive changes)

## Open Questions

1. **Certificate storage**: Vault vs Kubernetes secrets vs database blob?
   - Recommendation: Start with K8s secrets, add Vault integration later

2. **Tenant CA rotation**: How often to rotate intermediate CAs?
   - Recommendation: Annual rotation with 30-day overlap

3. **Cross-tenant visibility for super_admin**: Should platform admins see all tenants?
   - Recommendation: Yes, via special platform certificate that bypasses tenant validation

4. **Existing installations**: How to migrate edge components to new certs?
   - Recommendation: Provide migration script that re-onboards with new tenant cert
