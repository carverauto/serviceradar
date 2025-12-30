# Design: NATS Tenant Isolation

## Context

ServiceRadar uses NATS JetStream for:
1. **Event streaming** - Poller health, syslog, SNMP traps, OTEL telemetry
2. **KV configuration** - Component config distribution via datasvc
3. **Object storage** - Large config blobs (sweep configs, etc.)

Current architecture has no tenant awareness in NATS - all messages flow through shared subjects and streams.

### Stakeholders
- **Platform operators**: Need simple tenant provisioning
- **Enterprise customers**: Need isolated collector deployments
- **Security/compliance**: Require provable tenant data separation

## Goals / Non-Goals

### Goals
- **Channel prefixing** for all event subjects
- **NATS accounts** for enterprise customers with collectors
- **Leaf node configuration** for customer-deployed collectors
- **Backward compatibility** during migration

### Non-Goals
- Per-tenant NATS clusters (too expensive, shared cluster sufficient)
- Encryption at rest per tenant (NATS doesn't support this natively)
- Real-time tenant provisioning (batch/admin workflow acceptable)

## Decisions

### Decision 1: Tenant Prefix Format

**What**: All subjects prefixed with tenant slug.

```
Format: <tenant-slug>.<original-subject>

Examples:
  acme-corp.events.poller.health
  acme-corp.events.syslog.processed
  xyz-inc.events.otel.logs
```

**Why**:
- Slug is human-readable (better than UUID for debugging)
- Consistent with certificate CN format already in use
- Simple wildcard filtering: `acme-corp.>` captures all tenant traffic

**Alternatives considered**:
- UUID prefix: More unique but harder to debug
- Hierarchical (`tenants/<slug>/events/*`): More verbose, no benefit

### Decision 2: Go Publisher Changes

**What**: Update `pkg/natsutil/events.go` to accept tenant context.

```go
// Before
publisher.Publish(ctx, "events.poller.health", data)

// After
publisher.Publish(ctx, tenant.PrefixChannel("events.poller.health"), data)
// Or with tenant from context:
publisher.PublishWithTenant(ctx, "events.poller.health", data)
```

**Why**:
- Minimal API change
- `pkg/tenant` package already provides `PrefixChannel()` helper
- Tenant context flows from gRPC metadata or config

### Decision 3: Rust Consumer Changes

**What**: Update consumer configurations to use tenant-aware subjects.

```json
{
  "stream_name": "events",
  "consumer_name": "db-event-writer",
  "subjects": [
    "*.events.poller.health",
    "*.events.syslog.processed"
  ]
}
```

**Why**:
- Wildcard `*` at start captures all tenants
- Single consumer processes all tenants (efficient)
- Consumer extracts tenant from subject prefix for routing

### Decision 3.1: Elixir EventWriter Per-Tenant Pipelines

**What**: Run a dedicated Broadway pipeline per tenant in core-elx.

- Each pipeline starts under the tenant's DynamicSupervisor
- Each pipeline subscribes only to `<tenant-slug>.events.*` (and related) subjects
- Pipeline process dictionary sets the tenant context for all processing

**Why**:
- Enforces tenant isolation without relying on payload metadata
- Aligns with Ash process/Ash context expectations
- Simplifies per-tenant back-pressure and rate limits

**Alternatives considered**:
- Single pipeline with subject parsing → rejected (tenant context must not come from metadata)

### Decision 4: NATS Accounts for Collectors

**What**: Enterprise customers with collectors get dedicated NATS accounts.

```
Account: acme-corp
  - User: collector-syslog (publish: acme-corp.events.syslog.>)
  - User: collector-otel (publish: acme-corp.events.otel.>)
  - Imports: none (isolated)

Account: platform
  - Users: core, pollers, consumers
  - Exports: *.events.> (to process all tenants)
```

**Why**:
- NATS accounts provide native isolation
- Leaf nodes authenticate with account credentials
- No code changes needed in collectors - just configuration

### Decision 5: Leaf Node Configuration

**What**: Customer-deployed collectors connect via NATS leaf nodes.

```
# Customer site
nats-leaf-node (acme-corp account)
  └── flowgger (publishes to acme-corp.events.syslog.>)
  └── otel-collector (publishes to acme-corp.events.otel.>)

# Platform cluster
nats-cluster (receives leaf connections)
  └── Routes messages to JetStream
```

**Why**:
- Leaf nodes handle network topology (NAT, firewalls)
- Account isolation prevents cross-tenant access
- Standard NATS pattern for distributed deployments

## Risks / Trade-offs

| Risk | Impact | Mitigation |
|------|--------|------------|
| Migration breaks existing consumers | High | Feature flag for prefix, gradual rollout |
| Account management overhead | Medium | Automate in tenant onboarding flow |
| Wildcard subjects performance | Low | NATS handles wildcards efficiently |
| Leaf node connectivity | Medium | Document firewall requirements |

## Migration Plan

### Phase 1: Channel Prefixing (Non-Breaking)

1. Add tenant prefix to all publishers (Go, Rust)
2. Update consumers to handle both prefixed and non-prefixed subjects
3. Deploy to staging, verify event flow
4. Enable prefixing via feature flag in production

### Phase 2: Consumer Migration

1. Update consumer configs to use `*.events.*` patterns
2. Remove non-prefixed subject handling
3. Update JetStream stream subjects

### Phase 3: NATS Accounts (Enterprise Only)

1. Create account provisioning in tenant onboarding
2. Generate account credentials during collector onboarding
3. Document leaf node setup for customers
4. Test end-to-end with customer pilot

## Open Questions

1. **Default tenant for legacy messages**: Use `default` or `platform` prefix?
   - Recommendation: `default` for backward compatibility

2. **Account credential rotation**: How often? Automated or manual?
   - Recommendation: Annual, manual with documented runbook

3. **Rate limiting per account**: Should we enforce limits?
   - Recommendation: Start without limits, add if abuse detected
