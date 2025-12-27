# Change: Per-Tenant Process Isolation Architecture

## Why

The current multi-tenancy implementation uses application-layer filtering where all tenants share the same service instances and database. While Ash policies can restrict data access, edge components (agents, pollers, collectors, checkers) still share:
- The same mTLS certificate chain (network-level access)
- The same Horde registries (agent/poller discovery)
- The same NATS channels (message routing)

This means tenant A's agents could potentially connect to tenant B's pollers if misconfigured. True edge isolation requires per-tenant certificates and network-level RBAC.

## What Changes

### Architecture: Hybrid Model

**Shared Control Plane** (multi-tenant via application layer):
- `web-ng` - Phoenix app with session-based tenant context
- `core-elx` - Elixir core service with Ash policies
- `CNPG` - Shared database with tenant_id filtering
- `NATS` - Shared JetStream with tenant channel prefixes

**Isolated Edge Components** (per-tenant process isolation):
- Pollers - tenant-specific instances with tenant-scoped certs
- Agents - tenant-specific instances with tenant-scoped certs
- Collectors (flowgger, otel) - tenant-specific instances
- Checkers (snmp-checker, etc.) - tenant-specific instances

### Key Changes

1. **Per-Tenant mTLS Certificate Chains** - Each tenant has:
   - Unique intermediate CA (signed by platform root CA)
   - Tenant-specific edge component certificates
   - Certificate CN encodes tenant ID (e.g., `agent-001.tenant-12345.serviceradar`)

2. **Network-Level RBAC** - Edge components validate certificates:
   - Pollers only accept agents with same tenant CA
   - Core-elx extracts tenant ID from certificate CN
   - Cross-tenant connection attempts are rejected

3. **Onboarding Flow Changes** - When admin onboards agent/poller/checker:
   - System generates certificate signed by tenant's intermediate CA
   - Download package includes tenant CA, component cert/key, config
   - Config includes tenant-specific NATS channel prefixes

4. **NATS Channel Prefixing** - Tenant-scoped message routing:
   - `tenant-a.pollers.heartbeat` vs `tenant-b.pollers.heartbeat`
   - JetStream streams can be tenant-scoped

## Impact

- Affected specs: NEW `tenant-isolation` capability
- Affected code:
  - `docker/compose/generate-certs.sh` - Per-tenant CA generation
  - `cmd/agent/` and `cmd/poller/` - Certificate tenant validation
  - `elixir/serviceradar_core/lib/serviceradar/edge/` - Onboarding package with tenant certs
  - `web-ng/lib/serviceradar_web_ng_web/live/edge_live/` - Onboarding UI tenant context
  - `rust/crates/` - NATS channel prefixing
  - Kubernetes Helm charts - Per-tenant edge deployments
