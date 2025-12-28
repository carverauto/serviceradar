# Change: Add NATS Tenant Isolation

## Why

ServiceRadar is evolving into a multi-tenant SaaS platform. While database-level isolation uses Ash multitenancy with `tenant_id` filtering, the NATS messaging layer currently has no tenant isolation:

- All events publish to shared channels like `events.poller.health`, `events.syslog.*`
- Consumers process all tenants' messages in a single stream
- Customers deploying collectors (flowgger, OTEL, syslog) would need NATS leaf nodes that can see other tenants' traffic

This creates data leakage risks and prevents offering isolated collector deployments to enterprise customers.

## What Changes

### 1. Channel Prefixing (All Tenants)

All NATS subjects get prefixed with tenant slug:

```
# Before
events.poller.health
events.syslog.processed
events.otel.logs

# After
<tenant-slug>.events.poller.health
<tenant-slug>.events.syslog.processed
<tenant-slug>.events.otel.logs
```

### 2. NATS Accounts (Enterprise Customers with Collectors)

For customers deploying their own collectors (syslog, OTEL, NetFlow):

- Each tenant gets a dedicated NATS account
- Tenant account can only publish/subscribe to their prefixed channels
- NATS leaf nodes in customer networks connect with tenant-scoped credentials
- Account limits (connections, data, subscriptions) per tenant

### 3. JetStream Configuration

- Tenant-scoped streams: `<tenant-slug>-events`
- Tenant-scoped consumers: `<tenant-slug>-db-event-writer`
- Stream subject filters limit to tenant's prefix

## Impact

- Affected specs: NEW `nats-tenant-isolation` capability
- Affected code:
  - `pkg/natsutil/events.go` - Add tenant prefix to publish
  - `pkg/consumers/*/` - Update consumer subject patterns
  - `rust/crates/*/` - Update Rust consumers for prefixed channels
  - `cmd/core/` - Tenant context in event publishing
  - `docker/compose/nats/` - Account configuration templates
  - Helm charts - NATS account provisioning

## Sequencing

1. **Phase 1**: Channel prefixing in Go/Rust publishers and consumers
2. **Phase 2**: NATS accounts and leaf node configuration
3. **Phase 3**: Customer-facing collector onboarding with tenant credentials
