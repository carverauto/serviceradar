# Design: Per-Tenant Process Isolation

## Status Update (2025-12)

**Simplified Scope**: With the removal of `serviceradar-agent-elx`, ERTS-enabled nodes are no longer deployed in customer environments. The ERTS cluster (core-elx, pollers, web-ng) is entirely internal and trusted. This eliminates the need for ERTS-level isolation (per-tenant Horde registries, TenantGuard, EPMD cookies).

The focus is now on:
1. Per-tenant mTLS certificates for gRPC authentication
2. NATS channel prefixing for message isolation
3. Ash policies for data access control

## Context

ServiceRadar is a multi-tenant SaaS monitoring platform. The architecture provides:
- Strong tenant isolation at the API boundary (gRPC + mTLS)
- Cost-effective shared infrastructure for the control plane
- Simple deployment for customer-managed edge components (Go agents)

### Stakeholders
- **Platform operators**: Manage shared control plane infrastructure
- **Tenant admins**: Confident their data is isolated
- **Edge deployments**: Customer sites run Go agents with tenant-scoped certificates

## Goals / Non-Goals

### Goals
- **Per-tenant mTLS certificates** - Go agents authenticate using tenant-scoped certs
- **Onboarding flow** generates tenant-specific certificate bundles
- **NATS channel prefixing** - tenant-scoped message routing
- **gRPC tenant extraction** - control plane identifies tenant from certificate CN

### Non-Goals (out of scope)
- Per-tenant databases (shared CNPG with tenant_id filtering is sufficient)
- Per-tenant control plane instances (shared core-elx, web-ng)
- Per-tenant NATS clusters (shared JetStream with prefixed channels)
- ERTS-level isolation (not needed - cluster is internal)

## Decisions

### Decision 1: Shared Control Plane with gRPC Boundary

**What**: All control plane components run in a shared, trusted ERTS cluster. Edge components (Go agents) communicate via gRPC only.

```
Customer Network                    Our Network (Kubernetes)
+-------------------+              +----------------------------------+
|                   |              |     SHARED CONTROL PLANE         |
|  Go Agent         |              |  ┌─────────┐  ┌───────────┐     |
|  (gRPC server)    |<-------------|  │ Pollers │  │ core-elx  │     |
|                   |    gRPC      |  └─────────┘  └───────────┘     |
|  Tenant-scoped    |    mTLS      |  ┌─────────┐  ┌───────────┐     |
|  certificate      |              |  │ web-ng  │  │   CNPG    │     |
|                   |              |  └─────────┘  └───────────┘     |
+-------------------+              |       (Internal ERTS cluster)    |
                                   +----------------------------------+
```

**Why**:
- ERTS cluster is entirely internal and trusted
- No need for ERTS-level tenant isolation
- Security boundary is the gRPC API with mTLS
- Simpler operations and debugging

### Decision 2: Per-Tenant Certificate Authority

**What**: Each tenant gets a dedicated intermediate CA signed by platform root.

```
Root CA (ServiceRadar Platform)
├── Tenant-A Intermediate CA
│   ├── agent-a1.partition-1.acme-corp.serviceradar
│   └── agent-a2.partition-1.acme-corp.serviceradar
├── Tenant-B Intermediate CA
│   └── agent-b1.partition-1.xyz-inc.serviceradar
└── Platform Services CA
    ├── core-elx.serviceradar
    ├── poller-1.serviceradar
    └── nats.serviceradar
```

**Why**:
- Pollers validate agent certs are from expected tenant CA
- Compromised tenant cert cannot impersonate another tenant
- Revocation is tenant-scoped

### Decision 3: Tenant-Aware Edge Onboarding

**What**: Onboarding packages include tenant-scoped certificates.

When admin generates onboarding package:
1. System generates certificate signed by tenant's CA
2. Package includes: agent binary, tenant CA cert, agent cert/key, config
3. Config includes tenant-specific identifiers

**Why**:
- Self-contained packages for customer deployments
- Enables "download and run" experience
- Tenant identity is cryptographically bound

### Decision 4: gRPC Tenant Extraction

**What**: Pollers extract tenant from agent certificate CN when connecting.

```elixir
# Certificate CN format: <component>.<partition>.<tenant-slug>.serviceradar
# Example: agent-001.partition-1.acme-corp.serviceradar

def extract_tenant_from_cert(peer_cert) do
  cn = get_common_name(peer_cert)
  case parse_cn(cn) do
    {:ok, %{tenant_slug: slug}} -> {:ok, slug}
    _ -> {:error, :invalid_cert_format}
  end
end
```

**Why**:
- Cryptographic proof of tenant identity
- No reliance on headers that could be forged
- Consistent with existing mTLS architecture

### Decision 5: NATS Channel Prefixing

**What**: Each tenant's messages go to prefixed channels.

```
# Format: <tenant-slug>.<channel>
acme-corp.pollers.heartbeat
acme-corp.agents.status

xyz-inc.pollers.heartbeat
xyz-inc.agents.status
```

**Why**:
- Simple isolation without per-tenant NATS clusters
- Existing NATS infrastructure reused
- Easy to audit and debug

## Risks / Trade-offs

| Risk | Impact | Mitigation |
|------|--------|------------|
| Certificate management complexity | Medium | Automate CA generation in onboarding flow |
| DB tenant_id filtering misconfiguration | Low | Ash policies + integration tests |

## Remaining Work

### Phase 1: Certificate Infrastructure
1. Update generate-certs.sh to support tenant-scoped CAs
2. Add tenant CA generation to tenant creation workflow
3. Store tenant CA certs/keys in secrets

### Phase 2: Onboarding Updates
1. Update onboarding package to use tenant CA
2. Include tenant ID in certificate CN
3. Update Go agent config templates

### Phase 3: Poller Validation
1. Pollers validate agent certificate tenant matches expected
2. Extract tenant from certificate CN for context

### Phase 4: NATS Channel Prefixing
1. Update Rust crates to use prefixed channels
2. Update Go services to use prefixed channels

## Open Questions

1. **Certificate storage**: Vault vs Kubernetes secrets?
   - Recommendation: K8s secrets initially, Vault later

2. **Tenant CA rotation**: How often?
   - Recommendation: Annual with 30-day overlap
