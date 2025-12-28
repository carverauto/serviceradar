# Change: Per-Tenant Process Isolation Architecture

## Status Update (2025-12)

**Scope Simplified**: With the removal of `serviceradar-agent-elx` (see `remove-elixir-edge-agent` proposal), ERTS-enabled nodes will no longer be deployed in customer environments. The ERTS cluster is now entirely internal (core-elx, pollers, web-ng). This eliminates the primary threat vector (ERTS distribution primitives bypassing tenant isolation) and simplifies this proposal significantly.

**Obsolete concerns** (no longer needed):
- Per-tenant Horde registries
- TenantGuard process-level validation
- EPMD cookie isolation
- Complex ERTS cluster topology options

**Still relevant**:
- Per-tenant mTLS certificates (gRPC auth for Go agents)
- NATS channel prefixing (message isolation)
- Certificate CN tenant extraction (identifying tenant at API boundary)

## Why

Multi-tenancy requires isolation at multiple layers. With Go-only edge agents communicating over gRPC, the security boundary is now the gRPC API rather than ERTS distribution. Key remaining concerns:

1. **mTLS Identity** - Edge components (Go agents) need tenant-scoped certificates so the control plane can identify which tenant they belong to
2. **Message Isolation** - NATS channels should be tenant-prefixed to prevent cross-tenant message routing
3. **API-Level Authorization** - gRPC handlers extract tenant from certificate CN and enforce Ash policies

## What Changes

### Architecture: Simplified Model

```
Customer Network                 Our Network (Kubernetes)
+------------------+            +----------------------------------+
|  Go Agent        |<-----------|  Pollers <--> Core <--> Web      |
|  (gRPC server)   |   gRPC     |  (Internal ERTS cluster)         |
|  Tenant-scoped   |   mTLS     |  - Shared Horde registries       |
|  certificate     |            |  - Ash policies for data access  |
+------------------+            +----------------------------------+
```

**Control Plane** (internal, trusted):
- `web-ng` - Phoenix app with session-based tenant context
- `core-elx` - Elixir core with Ash policies
- `pollers` - Connect to Go agents via gRPC (tenant cert validation)
- `CNPG` - Shared database with tenant_id filtering
- `NATS` - Shared JetStream with tenant channel prefixes

**Edge Components** (customer network, gRPC only):
- Go agents - Tenant-scoped mTLS certificates
- Checkers (snmp-checker, etc.) - Run alongside agents

### Key Changes

1. **Per-Tenant mTLS Certificate Chains** - Each tenant has:
   - Unique intermediate CA (signed by platform root CA)
   - Tenant-specific edge component certificates
   - Certificate CN encodes tenant ID (e.g., `agent-001.partition-1.acme-corp.serviceradar`)

2. **gRPC Tenant Extraction** - When pollers connect to agents:
   - Validate agent certificate is signed by expected tenant CA
   - Extract tenant from certificate CN
   - Use tenant context for Ash policy enforcement

3. **Onboarding Flow** - When admin onboards agent/checker:
   - System generates certificate signed by tenant's intermediate CA
   - Download package includes tenant CA, component cert/key, config
   - Config includes tenant-specific identifiers

4. **NATS Channel Prefixing** - Tenant-scoped message routing:
   - `<tenant-slug>.<channel>` format
   - Prevents cross-tenant message leakage

## Impact

- Affected specs: `tenant-isolation` capability
- Affected code:
  - `docker/compose/generate-certs.sh` - Per-tenant CA generation
  - `cmd/agent/` - Certificate includes tenant identity
  - `elixir/serviceradar_core/lib/serviceradar/edge/` - Onboarding package with tenant certs
  - `elixir/serviceradar_poller/` - Validate tenant cert when connecting to agents
  - `rust/crates/` - NATS channel prefixing
