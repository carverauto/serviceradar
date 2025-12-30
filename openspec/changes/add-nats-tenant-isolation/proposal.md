# Change: Add NATS Tenant Isolation

## Why

ServiceRadar is evolving into a multi-tenant SaaS platform. While database-level isolation uses Ash multitenancy with `tenant_id` filtering, the NATS messaging layer currently has no tenant isolation:

- All events publish to shared channels like `events.poller.health`, `events.syslog.*`
- Consumers process all tenants' messages in a single stream
- Customers deploying collectors (flowgger, OTEL, syslog) would need NATS leaf nodes that can see other tenants' traffic

This creates data leakage risks and prevents offering isolated collector deployments to enterprise customers.

**Critical SaaS Requirement**: SaaS customers cannot simply send us syslog/netflow/SNMP data directly. They MUST run their own edge collectors in their network so we can inject tenant context and secure connections via mTLS. This ensures proper isolation and authentication.

## Current Architecture

### Edge Collectors (Rust)

The following collectors are Rust-based and use the `config-bootstrap` crate for configuration:

| Collector | Language | NATS Subject | Purpose |
|-----------|----------|--------------|---------|
| flowgger | Rust | `events.syslog` | Syslog ingestion |
| trapd | Rust | `snmp.traps` | SNMP trap reception |
| netflow | Rust (future) | `netflow.*` | NetFlow/IPFIX collection |
| otel | Go | `otel.metrics.>`, `otel.traces.>` | OpenTelemetry collector |

### Configuration Flow

```
┌────────────────────────┐
│ Elixir IntegrationSource │
│ (Ash resource)          │
└───────────┬────────────┘
            │ Oban job syncs config
            ▼
┌────────────────────────┐
│ DataSvc KV Store        │
│ (Go gRPC service)       │
└───────────┬────────────┘
            │ Rust/Go collectors poll
            ▼
┌────────────────────────┐
│ Edge Collectors         │
│ (flowgger, trapd, etc)  │
└───────────┬────────────┘
            │ Publish to NATS JetStream
            ▼
┌────────────────────────┐
│ NATS JetStream          │
│ (events stream)         │
└───────────┬────────────┘
            │
            ▼
┌────────────────────────┐
│ Elixir EventWriter      │
│ (Broadway pipeline)     │
└────────────────────────┘
```

### Edge Onboarding Flow

The existing `OnboardingPackage` Ash resource manages edge component lifecycle:

1. Admin creates package in UI (specifies component type, site, security mode)
2. Package generates SPIRE join token or mTLS certificates
3. Customer downloads package via one-time download token
4. Edge component activates using join token/certs
5. Package status: `issued` → `delivered` → `activated`

Current component types: `:poller`, `:agent`, `:checker`

**Need to extend for collectors**: `:flowgger`, `:trapd`, `:netflow`, `:otel`

## What Changes

### 1. Channel Prefixing (All Tenants)

All NATS subjects get prefixed with tenant slug:

```
# Before
events.poller.health
events.syslog.processed
snmp.traps
otel.metrics.gauge

# After
<tenant-slug>.events.poller.health
<tenant-slug>.events.syslog
<tenant-slug>.snmp.traps
<tenant-slug>.otel.metrics.gauge
```

### 2. Collector Config Tenant Context

Add `tenant_slug` to collector configurations:

```toml
# flowgger.toml
[output]
type = "nats"
tenant_slug = "acme-corp"  # NEW - injected from onboarding package
nats_subject = "events.syslog"  # Becomes: acme-corp.events.syslog

[security]
# mTLS certs from onboarding package
cert_file = "/etc/serviceradar/certs/collector.pem"
key_file = "/etc/serviceradar/certs/collector-key.pem"
ca_file = "/etc/serviceradar/certs/root.pem"
```

Collectors extract tenant from:
1. Config file `tenant_slug` field (primary)
2. mTLS certificate CN/SAN (fallback/validation)

### 3. NATS Accounts (Enterprise Customers with Collectors)

For customers deploying their own collectors:

- **Tenant NATS Account**: Created during tenant onboarding
- **Account Permissions**: Publish/subscribe only to `<tenant-slug>.*`
- **Leaf Node Configuration**: For customer-network collectors
- **Account Limits**: Connections, data rate, message size per tenant

```
# NATS Account structure
accounts {
  PLATFORM {
    # Core services (EventWriter, datasvc, etc)
    users: [{ user: "platform", permissions: { pub: ">", sub: ">" } }]
  }

  TENANT_acme_corp {
    users: [{ user: "acme-collector", permissions: {
      pub: ["acme-corp.>"],
      sub: ["acme-corp.>"]
    }}]
    limits: {
      conn: 100,
      data: 1GB,
      payload: 1MB
    }
  }
}
```

### 4. Edge Collector Onboarding

Extend `OnboardingPackage` for collectors:

```elixir
# New component types
constraints one_of: [:poller, :agent, :checker, :flowgger, :trapd, :netflow, :otel]

# Additional fields for collectors
attribute :nats_account_user, :string
attribute :nats_account_creds_ciphertext, :string, sensitive?: true
attribute :collector_config_json, :map  # Pre-generated collector config with tenant context
```

Onboarding flow for collectors:
1. Create NATS account/user for tenant (if not exists)
2. Generate mTLS certs signed by tenant CA
3. Generate collector config with `tenant_slug` and NATS credentials
4. Package includes: certs, config, NATS creds, setup script
5. Customer runs: `./install-collector.sh --token <download-token>`

### 5. Edge NATS Leaf Nodes

For customers with network-deployed collectors:

```
Customer Network          │          ServiceRadar Cloud
                          │
┌───────────────────┐     │     ┌───────────────────────┐
│ Customer Firewall │     │     │ NATS Hub Cluster      │
│                   │     │     │                       │
│ ┌───────────────┐ │     │     │ ┌───────────────────┐ │
│ │ Leaf NATS     │─┼─────┼─────┼▶│ Hub NATS          │ │
│ │ (per tenant)  │ │ TLS │     │ │ (account: TENANT) │ │
│ └───────┬───────┘ │     │     │ └───────────────────┘ │
│         │         │     │     │                       │
│ ┌───────┴───────┐ │     │     └───────────────────────┘
│ │ flowgger      │ │     │
│ │ trapd         │ │     │
│ │ netflow       │ │     │
│ └───────────────┘ │     │
└───────────────────┘     │
```

- Leaf connects to hub with tenant account credentials
- All messages automatically scoped to tenant's subjects
- Firewall only needs outbound 4222/TLS to ServiceRadar hub

### 6. JetStream Configuration

Update stream subjects for tenant wildcards:

```
streams {
  EVENTS {
    subjects: ["*.events.>"]  # Captures all tenant-prefixed events
    storage: file
    retention: limits
    max_age: 7d
  }

  SNMP_TRAPS {
    subjects: ["*.snmp.traps"]
  }

  NETFLOW {
    subjects: ["*.netflow.>"]
  }
}
```

### 7. EventWriter Per-Tenant Pipelines (Elixir)

**Completed in Phase 1.4**:
- `EventWriter.Config` uses `*.events.>` wildcard patterns
- `EventWriter.Pipeline.handle_message` extracts tenant from subject prefix
- Backward compatibility with legacy non-prefixed subjects

**Remaining (Phase 6.1)**:
- Start one Broadway pipeline per tenant under `TenantRegistry`
- Each pipeline subscribes to `<tenant-slug>.events.*`
- Process dictionary tenant context for all database operations

## Impact

- Affected specs: NEW `nats-tenant-isolation` capability
- Affected code:
  - `cmd/flowgger/` - Add tenant prefix to NATS subject (Rust)
  - `cmd/trapd/` - Add tenant prefix to NATS subject (Rust)
  - `rust/config-bootstrap/` - Add tenant_slug parsing
  - `elixir/serviceradar_core/lib/serviceradar/edge/onboarding_package.ex` - Collector types
  - `elixir/serviceradar_core/lib/serviceradar/event_writer/` - Per-tenant pipelines
  - `docker/compose/nats*.conf` - Account configuration templates
  - Helm charts - NATS account provisioning

## Sequencing

1. **Phase 1**: Channel prefixing (✅ Go publisher, ✅ Elixir EventWriter consumer)
2. **Phase 2**: JetStream stream subject updates
3. **Phase 3**: NATS accounts infrastructure
4. **Phase 4**: Rust collector updates (flowgger, trapd)
5. **Phase 5**: Collector onboarding packages
6. **Phase 6**: Per-tenant EventWriter pipelines
7. **Phase 7**: Documentation and testing

## Status / Notes

- ✅ Phase 1.4: Elixir EventWriter updated with tenant prefix extraction
- ✅ Go publisher has tenant prefix support (deprecated Go core)
- ⏳ Rust collectors need tenant_slug config field and subject prefixing
- ⏳ NATS accounts infrastructure not yet implemented
- ⏳ OnboardingPackage needs collector component types

**Key Architectural Decision**: SaaS customers MUST deploy edge collectors (flowgger, trapd, etc.) in their own network. We cannot accept raw syslog/netflow/SNMP directly because:
1. No way to inject tenant context into raw protocol data
2. mTLS provides authentication and RBAC
3. Leaf NATS provides message routing and isolation

> **Note**: Edge collectors forward raw data with tenant context. ETL/transformation to OCSF happens upstream in the Elixir EventWriter.
