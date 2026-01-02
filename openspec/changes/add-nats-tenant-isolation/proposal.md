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

## Tenant Hierarchy & Authorization

### Deployment Models

ServiceRadar supports two deployment models with the same multi-tenant architecture:

1. **ServiceRadar SaaS** (commercial hosted)
   - Carver Automation is the platform operator
   - Controls NATS operator keys and platform infrastructure
   - Tenants are paying customers

2. **Self-Hosted** (on-premises / private cloud)
   - Customer is their own platform operator
   - May want multi-tenancy (MSPs, enterprises with divisions)
   - Same architecture, customer controls operator keys

### Authority Hierarchy

```
Platform Operator (infrastructure level)
│   - Has NATS operator keys
│   - Can create/delete tenants
│   - Manages platform infrastructure
│
└── Tenant (organizational boundary)
    │
    ├── Tenant Admin (first user / superuser)
    │   - Can approve users joining tenant
    │   - Can create collector onboarding packages
    │   - Can manage tenant resources (sites, integrations)
    │   - CANNOT access other tenants
    │
    └── Tenant User (regular user)
        - Limited permissions within tenant
        - Defined by Ash policies
```

### Authorization Flow for NATS Account Management

**Key Principle**: Tenant admins trigger operations through Elixir; they never directly access NATS operator keys or datasvc.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Authorization Flow                                │
│                                                                          │
│  Tenant Admin (browser)                                                  │
│       │                                                                  │
│       │ 1. "Create collector onboarding package"                        │
│       ▼                                                                  │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │ Elixir Core (serviceradar-core-elx)                             │    │
│  │                                                                  │    │
│  │  2. Ash Authentication: Verify user session                     │    │
│  │  3. Ash Policy: Is user tenant_admin for this tenant?           │    │
│  │  4. If authorized: Call datasvc with platform mTLS credentials  │    │
│  │                                                                  │    │
│  └──────────────────────────┬──────────────────────────────────────┘    │
│                             │                                            │
│                             │ gRPC + mTLS (core.pem)                    │
│                             │ + tenant_id in request metadata           │
│                             ▼                                            │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │ datasvc (Go gRPC service)                                       │    │
│  │                                                                  │    │
│  │  5. Verify mTLS cert (trusts Elixir core)                       │    │
│  │  6. Extract tenant_id from request metadata                      │    │
│  │  7. Create/manage NATS account using operator keys              │    │
│  │  8. Generate user credentials for tenant account                 │    │
│  │  9. Return credentials to Elixir                                 │    │
│  │                                                                  │    │
│  │  ** NATS operator keys stored here, never exposed to tenants ** │    │
│  │                                                                  │    │
│  └──────────────────────────┬──────────────────────────────────────┘    │
│                             │                                            │
│                             │ NATS JWT/NKeys operations                 │
│                             ▼                                            │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │ NATS Server (JWT resolver mode)                                 │    │
│  │                                                                  │    │
│  │  - Operator JWT loaded at startup                               │    │
│  │  - Account JWTs pushed via $SYS.REQ.CLAIMS.UPDATE               │    │
│  │  - User credentials validated against account                    │    │
│  │                                                                  │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### datasvc NATS Account Management API

New gRPC service in datasvc for NATS account operations:

```protobuf
service NATSAccountService {
  // Create a new tenant account (called when tenant is created)
  rpc CreateTenantAccount(CreateTenantAccountRequest) returns (CreateTenantAccountResponse);

  // Generate user credentials for a tenant account (called during collector onboarding)
  rpc GenerateUserCredentials(GenerateUserCredentialsRequest) returns (GenerateUserCredentialsResponse);

  // Revoke user credentials (called when onboarding package is revoked)
  rpc RevokeUserCredentials(RevokeUserCredentialsRequest) returns (RevokeUserCredentialsResponse);

  // Get account status/limits
  rpc GetAccountStatus(GetAccountStatusRequest) returns (GetAccountStatusResponse);
}

message CreateTenantAccountRequest {
  string tenant_id = 1;
  string tenant_slug = 2;
  AccountLimits limits = 3;
}

message GenerateUserCredentialsRequest {
  string tenant_id = 1;
  string user_name = 2;  // e.g., "flowgger-site-1"
  repeated string allowed_subjects = 3;  // Optional: further restrict within tenant
}

message GenerateUserCredentialsResponse {
  string credentials = 1;  // .creds file content
  string user_public_key = 2;  // For tracking/revocation
}
```

### Security Boundaries

| Component | Has Access To | Trust Level |
|-----------|--------------|-------------|
| Tenant Admin | Elixir API (authenticated) | Tenant-scoped |
| Elixir Core | datasvc (mTLS), tenant context | Platform service |
| datasvc | NATS operator keys, all tenant accounts | Platform privileged |
| NATS Server | All messages (via accounts) | Infrastructure |
| Collectors | Own tenant's NATS account only | Tenant-scoped |

### Tenant Creation Flow

When a new tenant is created (self-service signup or admin creation):

1. **Elixir**: Create tenant record in database (Ash resource)
2. **Elixir**: Call datasvc `CreateTenantAccount` with tenant_id and slug
3. **datasvc**: Generate NKeys for tenant account
4. **datasvc**: Create account JWT with subject mappings and limits
5. **datasvc**: Push account JWT to NATS via `$SYS.REQ.CLAIMS.UPDATE`
6. **datasvc**: Store account keys securely (encrypted in DB or Vault)
7. **Elixir**: Mark tenant as "nats_account_ready"

### Collector Onboarding Flow

When a tenant admin creates a collector onboarding package:

1. **Elixir**: Verify user is tenant admin (Ash policy)
2. **Elixir**: Call datasvc `GenerateUserCredentials` with tenant_id
3. **datasvc**: Generate NKeys for user within tenant account
4. **datasvc**: Create user JWT signed by account key
5. **datasvc**: Return .creds file content
6. **Elixir**: Generate mTLS certificates
7. **Elixir**: Package credentials, certs, and config
8. **Elixir**: Store package for one-time download

## What Changes

### 1. NATS Account-Based Tenant Isolation (Primary Mechanism)

**Security Principle**: Tenant identity MUST be derived from mTLS credentials on the server side, NOT self-reported by collectors. This prevents malicious collectors from claiming to be other tenants.

Each tenant gets a dedicated NATS account with:
- **Subject Mapping**: Collector publishes to `snmp.traps` → NATS rewrites to `<tenant>.snmp.traps`
- **Scoped Permissions**: Account can only access tenant-prefixed subjects
- **Account Limits**: Connections, data rate, message size per tenant
- **mTLS Binding**: Account credentials tied to tenant's mTLS certificates

```
# NATS Server Configuration with Accounts and Subject Mapping
accounts {
  # Platform account for internal services (EventWriter, datasvc, etc)
  PLATFORM {
    users: [{ user: "platform", password: "$PLATFORM_PASSWORD" }]
    # Full access to all subjects
    exports: [
      { stream: ">" }
    ]
    imports: [
      # Import all tenant streams for EventWriter consumption
      { stream: { account: TENANT_*, subject: ">" } }
    ]
  }

  # Per-tenant account template (created during onboarding)
  TENANT_acme_corp {
    users: [{
      user: "acme-collector",
      password: "$ACME_NATS_PASSWORD"  # Or use NKey/JWT auth
    }]

    # Subject mapping: collector publishes to base subject,
    # NATS automatically prefixes with tenant slug
    mappings: {
      "snmp.traps": "acme-corp.snmp.traps"
      "events.>": "acme-corp.events.>"
      "logs.>": "acme-corp.logs.>"
      "netflow.>": "acme-corp.netflow.>"
      "otel.>": "acme-corp.otel.>"
    }

    # Permissions enforce tenant can only access their prefixed subjects
    permissions: {
      publish: ["acme-corp.>"]
      subscribe: ["acme-corp.>"]
    }

    limits: {
      conn: 100        # Max connections
      data: 1073741824 # 1GB data limit
      payload: 1048576 # 1MB max message size
    }
  }
}
```

### 2. Collector Configuration (No Tenant Context Required)

Collectors do NOT need tenant_slug in their config. They simply publish to base subjects:

```toml
# flowgger.toml - no tenant_slug needed!
[output]
type = "nats"
nats_url = "tls://nats.serviceradar.cloud:4222"
nats_subject = "events.syslog"  # NATS maps to: <tenant>.events.syslog

[security]
# mTLS certs from onboarding package - these bind to NATS account
cert_file = "/etc/serviceradar/certs/collector.pem"
key_file = "/etc/serviceradar/certs/collector-key.pem"
ca_file = "/etc/serviceradar/certs/root.pem"

# NATS credentials (from onboarding package)
nats_creds_file = "/etc/serviceradar/certs/nats.creds"
```

**Why this is secure**:
1. Collector authenticates with NATS account credentials (from onboarding package)
2. NATS account is bound to specific tenant via subject mappings
3. Even if collector tries to publish to `other-tenant.snmp.traps`, permissions deny it
4. Subject mapping automatically rewrites base subjects to tenant-prefixed subjects

### 3. Subject Flow with NATS Accounts

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        Customer Network                                  │
│                                                                          │
│  ┌──────────────┐     publishes to:                                     │
│  │ trapd        │────► "snmp.traps"                                     │
│  │ (no tenant   │                                                        │
│  │  config)     │     authenticates with:                               │
│  └──────────────┘     NATS account "TENANT_acme_corp"                   │
│                                                                          │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │ mTLS + NATS credentials
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        ServiceRadar Cloud NATS                           │
│                                                                          │
│  1. Authenticate: TENANT_acme_corp account                              │
│  2. Subject mapping: "snmp.traps" → "acme-corp.snmp.traps"              │
│  3. Permission check: ✓ "acme-corp.>" allowed                           │
│  4. Publish to JetStream: "acme-corp.snmp.traps"                        │
│                                                                          │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        Elixir EventWriter                                │
│                                                                          │
│  Subscribes to: "*.snmp.traps"                                          │
│  Extracts tenant from subject prefix: "acme-corp"                       │
│  Processes with tenant context                                          │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### 4. Edge Collector Onboarding

Extend `OnboardingPackage` for collectors:

```elixir
# New component types
constraints one_of: [:poller, :agent, :checker, :flowgger, :trapd, :netflow, :otel]

# Additional fields for collectors
attribute :nats_account_name, :string      # e.g., "TENANT_acme_corp"
attribute :nats_creds_ciphertext, :string, sensitive?: true  # Encrypted .creds file content
```

Onboarding flow for collectors:
1. Ensure NATS account exists for tenant (create if first collector)
2. Generate NATS user credentials (.creds file) for the tenant account
3. Generate mTLS certs signed by platform CA
4. Generate collector config (no tenant_slug - just NATS creds path)
5. Package includes: mTLS certs, NATS creds, collector config, setup script
6. Customer runs: `./install-collector.sh --token <download-token>`

**Package contents**:
```
serviceradar-collector-acme-corp.tar.gz/
├── certs/
│   ├── collector.pem      # mTLS cert
│   ├── collector-key.pem  # mTLS key
│   └── ca.pem             # Platform CA
├── nats.creds             # NATS account credentials
├── config.json            # Collector config (no tenant info)
└── install.sh             # Installation script
```

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
  - **datasvc (Go)**:
    - `proto/nats_account.proto` - ✅ gRPC service definition
    - `pkg/nats/accounts/account_manager.go` - ✅ NATS JWT/NKeys management
    - `pkg/nats/accounts/user_manager.go` - ✅ User credential operations
    - `pkg/nats/accounts/operator.go` - ✅ Operator key management
    - `pkg/datasvc/nats_account_service.go` - ✅ gRPC service implementation
    - `cmd/data-services/main.go` - ✅ Register NATSAccountService
  - **Elixir Core (serviceradar_core)**:
    - `lib/serviceradar/nats/account_client.ex` - ✅ gRPC client for datasvc
    - `lib/serviceradar/nats/workers/create_account_worker.ex` - ✅ Async provisioning
    - `lib/serviceradar/nats/operator_bootstrap.ex` - ✅ Operator bootstrap logic
    - `lib/serviceradar/infrastructure.ex` - ✅ New domain
    - `lib/serviceradar/infrastructure/nats_operator.ex` - ✅ Operator resource
    - `lib/serviceradar/infrastructure/nats_platform_token.ex` - ✅ Token resource
    - `lib/serviceradar/identity/tenant.ex` - ✅ NATS account fields + actions
    - `lib/serviceradar/identity/changes/initialize_tenant_infrastructure.ex` - ✅ Trigger provisioning
    - `lib/serviceradar/edge/workers/provision_collector_worker.ex` - ✅ Collector provisioning
  - **Web NG (Phoenix)**:
    - `lib/serviceradar_web_ng_web/live/admin/nats_live/index.ex` - ✅ NATS admin dashboard
    - `lib/serviceradar_web_ng_web/live/admin/nats_live/show.ex` - ✅ Tenant detail page
    - `lib/serviceradar_web_ng_web/controllers/api/nats_controller.ex` - ✅ API endpoints
    - `lib/serviceradar_web_ng_web/router.ex` - ✅ Route updates
  - **Infrastructure** (TODO):
    - `docker/compose/nats*.conf` - JWT resolver mode configuration
    - Helm charts - NATS operator bootstrap, datasvc secrets
  - **Collectors** (Rust) (TODO):
    - `cmd/flowgger/`, `cmd/trapd/` - Add NATS credentials file support

**NOT affected** (by design):
- Collector configs do NOT need tenant_slug - NATS handles subject mapping
- No changes to collector business logic - they just publish to base subjects

## Sequencing

1. **Phase 1**: ✅ EventWriter tenant extraction from subject prefix (DONE)
2. **Phase 2**: ✅ NATS accounts infrastructure (datasvc) (DONE)
   - gRPC proto for NATSAccountService
   - NATS JWT/NKeys management in Go (using nats-io/jwt, nats-io/nkeys)
   - Bootstrap operator support (generate or import existing)
   - System account generation
3. **Phase 3**: ✅ Elixir integration (DONE)
   - gRPC client `ServiceRadar.NATS.AccountClient`
   - `CreateAccountWorker` Oban job for async provisioning
   - Tenant resource with AshCloak encrypted NATS fields
   - `NatsOperator` and `NatsPlatformToken` infrastructure resources
   - Tenant account lifecycle actions (create, pending, error, clear)
4. **Phase 4**: Collector onboarding packages (next priority)
   - Extend OnboardingPackage with NATS creds generation
   - Package generation with NATS credentials
5. **Phase 5**: JetStream stream subject updates for `*.<subject>` patterns
6. **Phase 6**: Collector NATS credentials support
   - Add nats_creds_file to flowgger, trapd configs
   - Test with account-based auth
7. **Phase 7**: Per-tenant EventWriter pipelines (optional optimization)
8. **Phase 8**: Leaf node support for customer-network deployments
9. **Phase 8.5**: ✅ Admin UI for NATS management (DONE)
   - Super admin NATS dashboard
   - Tenant account detail page
   - Reprovision and clear actions
   - API endpoints for programmatic access
10. **Phase 9**: Documentation and testing

## Status / Notes

- ✅ Phase 1: Elixir EventWriter extracts tenant from subject prefix (`*.events.>` patterns)
- ✅ Authorization architecture documented (Elixir → datasvc flow)
- ✅ Phase 2: datasvc NATS account management (Go gRPC service with NKeys/JWT signing)
- ✅ Phase 3: Elixir integration complete
  - `ServiceRadar.NATS.AccountClient` gRPC client
  - `CreateAccountWorker` Oban job for async provisioning
  - Tenant resource with encrypted NATS account fields (AshCloak)
  - `NatsOperator` and `NatsPlatformToken` infrastructure resources
- ✅ Phase 8.5: Admin UI for NATS management
  - Super admin dashboard at `/admin/nats`
  - Tenant detail page at `/admin/nats/tenants/:id`
  - Reprovision and clear NATS account actions
  - API endpoints for programmatic access
- ✅ Phase 4: Collector onboarding packages (DONE - using CollectorPackage resource)
  - `CollectorPackage` Ash resource with state machine (pending → ready → downloaded)
  - `NatsCredential` resource for tracking issued credentials
  - `ProvisionCollectorWorker` Oban job for async NATS credential provisioning
  - `CollectorController` REST API (create, download, revoke, bundle)
  - `CollectorBundleGenerator` for tarball generation with install scripts
  - Encrypted credential storage via AshCloak (`nats_creds_ciphertext`)
  - Bundle endpoint: `GET /api/collectors/:id/bundle?token=...` for curl downloads
- ✅ Phase 5: Collector NATS credentials support (nats_creds_file config in flowgger/trapd)
- ⏳ Phase 4b: JetStream stream configuration for tenant-prefixed subjects
- ⏳ Phase 6: Per-tenant EventWriter pipelines (optimization)
- ⏳ Phase 7: Leaf node support for customer-network deployments

**Key Architectural Decisions**:

1. **Server-side tenant enforcement**: Tenant identity comes from NATS account credentials, NOT collector config. This prevents malicious collectors from spoofing tenant identity.

2. **NATS subject mapping**: Collectors publish to base subjects (`snmp.traps`), NATS automatically maps to tenant-prefixed subjects (`acme-corp.snmp.traps`). This is enforced by NATS, not trusted from collectors.

3. **Authorization via Elixir**: Tenant admins never directly access NATS operator keys. Elixir handles authentication/authorization via Ash policies, then calls datasvc with platform credentials. datasvc holds operator keys and performs privileged operations.

4. **Edge deployment requirement**: SaaS customers MUST deploy edge collectors in their network because:
   - Raw syslog/netflow/SNMP has no tenant context
   - mTLS + NATS accounts provide authentication and RBAC
   - Leaf NATS provides message routing and isolation

5. **Automatic operator bootstrap**: Platform bootstrap happens automatically during initial installation, not via manual token generation in the UI. This simplifies the admin experience.

> **Note**: Edge collectors forward raw data. ETL/transformation to OCSF happens upstream in the Elixir EventWriter.
