# Tasks: NATS Tenant Isolation

## Phase 1: EventWriter Tenant Extraction (DONE)

### 1.1 Elixir Integration (core-elx EventWriter)

- [x] 1.1.1 `ServiceRadar.NATS.Channels` module already has tenant prefix helpers
- [x] 1.1.2 Update `EventWriter.Config` with `*.events.>` wildcard patterns for all streams
- [x] 1.1.3 Update `EventWriter.Pipeline.handle_message` to extract tenant from subject prefix
- [x] 1.1.4 Update `EventWriter.Pipeline.handle_batch` to set tenant context from message metadata
- [x] 1.1.5 Add backward compatibility for non-prefixed subjects (legacy streams)

### 1.2 Go Publisher Updates (DEPRECATED)

> **Note**: These changes apply to the Go core service which is being deprecated.
> With NATS account-based isolation, publishers don't need tenant_slug - NATS handles it.

- [x] 1.2.1 Update `pkg/natsutil/events.go` to accept tenant slug parameter
- [x] 1.2.2 Add tenant prefix utilities to `pkg/tenant/tenant.go`
- [~] **No longer needed** - NATS accounts handle subject mapping server-side

## Phase 2: NATS Accounts Infrastructure via datasvc (PRIORITY)

> **Key Design (Updated - Stateless Architecture)**:
> - Tenant identity comes from NATS account credentials, NOT collector config
> - NATS subject mapping automatically prefixes subjects based on the authenticated account
> - **datasvc (Go) is STATELESS** - only holds operator key for JWT signing operations
> - **Elixir stores account data** in CNPG with AshCloak encryption for sensitive fields
> - Elixir calls datasvc via gRPC; tenant admins never access operator keys directly
> - Account seeds are returned to Elixir for encrypted storage, then passed back for signing

### 2.1 gRPC Proto Definition

- [x] 2.1.1 Create `proto/nats_account.proto` with NATSAccountService definition
- [x] 2.1.2 Define `CreateTenantAccountRequest/Response` messages (returns account_seed for Elixir storage)
- [x] 2.1.3 Define `GenerateUserCredentialsRequest/Response` messages (takes account_seed as input)
- [x] 2.1.4 Define `SignAccountJWTRequest/Response` messages (for re-signing with updated claims)
- [~] ~~2.1.5 Define `GetAccountStatusRequest/Response` messages~~ (moved to Elixir - stateless)
- [x] 2.1.6 Define `AccountLimits` message (connections, data, payload)
- [x] 2.1.7 Generate Go code from proto

### 2.2 datasvc NATS Account Signer (Go) - Stateless

- [x] 2.2.1 Add `nats-io/jwt/v2` and `nats-io/nkeys` dependencies to go.mod
- [x] 2.2.2 Create `pkg/nats/accounts/operator.go` - operator key management
  - Load operator NKeys from secure storage (env var, file, or Vault)
  - Provide key generation utilities
- [x] 2.2.3 Create `pkg/nats/accounts/account_manager.go` - **stateless** signing operations
  - `CreateTenantAccount()` - generate NKeys, sign JWT, return seed to caller
  - `SignAccountJWT()` - re-sign with updated claims (revocations, limits)
  - ~~`GetAccountJWT()`~~ - removed (state in Elixir)
  - ~~`DeleteTenantAccount()`~~ - removed (revocation via SignAccountJWT)
- [x] 2.2.4 Create `pkg/nats/accounts/user_manager.go` - **stateless** user credential operations
  - `GenerateUserCredentials()` - takes account_seed, creates user NKeys, signs JWT
  - `formatCredsFile()` - format .creds file content
  - ~~`RevokeUserCredentials()`~~ - moved to SignAccountJWT revocation list
- [x] 2.2.5 Subject mapping implemented in account_manager.go
  - Generate subject mappings for tenant account
  - Standard mappings: `logs.snmp` → `<tenant>.logs.snmp`, etc.
- [~] ~~2.2.6 Implement account key storage~~ - **No longer needed**
  - Account seeds stored by Elixir in CNPG with AshCloak encryption

### 2.3 datasvc gRPC Service Implementation

- [x] 2.3.1 Create `pkg/datasvc/nats_account_service.go` (stateless)
- [x] 2.3.2 Implement `CreateTenantAccount` RPC (returns account_seed)
- [x] 2.3.3 Implement `GenerateUserCredentials` RPC (takes account_seed)
- [x] 2.3.4 Implement `SignAccountJWT` RPC (for revocations/limit updates)
- [~] ~~2.3.5 Implement `GetAccountStatus` RPC~~ - state in Elixir
- [x] 2.3.6 Register service in `cmd/data-services/main.go`
- [x] 2.3.7 Add mTLS client verification (only allow Elixir core)

### 2.4 NATS Server JWT Resolver Configuration

- [x] 2.4.1 Update NATS server config for operator/resolver mode
- [x] 2.4.2 Configure full resolver (NATS-based) for dynamic account updates
- [x] 2.4.3 Push account JWTs via `$SYS.REQ.CLAIMS.UPDATE`
- [x] 2.4.4 Create system account user for datasvc to push updates
- [ ] 2.4.5 Test dynamic account creation and credential validation

### 2.5 Operator Bootstrap

- [x] 2.5.1 Create operator bootstrap script/container
- [x] 2.5.2 Generate operator NKeys on first deployment
- [x] 2.5.3 Create system account for internal operations
- [x] 2.5.4 Create PLATFORM account for EventWriter, datasvc
- [ ] 2.5.5 Store operator keys securely (K8s secret, Vault, etc.)
- [ ] 2.5.6 Document operator key backup/recovery procedures

## Phase 3: Elixir Integration (DONE)

> **Note**: Elixir handles user authentication/authorization via Ash.
> Elixir **stores account data** in CNPG with AshCloak encryption.
> It calls datasvc for NATS JWT signing operations using platform mTLS credentials.

### 3.1 Tenant Account Storage (Ash/AshCloak) - DONE

- [x] 3.1.1 Add `nats_account_seed_ciphertext` field to Tenant resource (AshCloak encrypted)
- [x] 3.1.2 Add `nats_account_public_key` field to Tenant resource
- [x] 3.1.3 Add `nats_account_jwt` field to Tenant resource
- [x] 3.1.4 Add `nats_account_status` field (`:pending`, `:ready`, `:error`)
- [x] 3.1.5 Configure AshCloak for `nats_account_seed_ciphertext` encryption
- [x] 3.1.6 Add `nats_account_error` field for error messages
- [x] 3.1.7 Add `nats_account_provisioned_at` timestamp

### 3.2 gRPC Client for datasvc - DONE

- [x] 3.2.1 Generate Elixir code from `nats_account.proto`
- [x] 3.2.2 Create `ServiceRadar.NATS.AccountClient` module
- [x] 3.2.3 Implement `create_tenant_account/2` - calls datasvc RPC, stores result
- [x] 3.2.4 Implement `generate_user_credentials/5` - decrypts seed, calls datasvc RPC
- [x] 3.2.5 Implement `sign_account_jwt/3` - for revocations/limit updates
- [x] 3.2.6 Implement `push_account_jwt/3` - push JWT to NATS resolver
- [x] 3.2.7 Implement `bootstrap_operator/1` - bootstrap operator keys
- [x] 3.2.8 Implement `get_operator_info/1` - get operator status
- [x] 3.2.9 Configure gRPC client with mTLS (core.pem credentials)

### 3.3 Tenant Creation Integration - DONE

- [x] 3.3.1 Create Oban worker `CreateAccountWorker` for async account creation
- [x] 3.3.2 Trigger worker on tenant creation (via `InitializeTenantInfrastructure` change)
- [x] 3.3.3 Update tenant status on success/failure (`set_nats_account`, `set_nats_account_error`)
- [x] 3.3.4 Add retry logic with exponential backoff (max 5 attempts)
- [x] 3.3.5 Push JWT to NATS resolver after successful creation

### 3.4 Tenant Account Actions - DONE

- [x] 3.4.1 Add `set_nats_account` action for storing credentials
- [x] 3.4.2 Add `set_nats_account_pending` action for marking in-progress
- [x] 3.4.3 Add `set_nats_account_error` action for recording failures
- [x] 3.4.4 Add `update_nats_account_jwt` action for re-signing
- [x] 3.4.5 Add `clear_nats_account` action for revoking/clearing credentials

### 3.5 Infrastructure Resources - DONE

- [x] 3.5.1 Create `ServiceRadar.Infrastructure` domain
- [x] 3.5.2 Create `NatsOperator` resource for platform operator
- [x] 3.5.3 Create `NatsPlatformToken` resource for bootstrap tokens
- [x] 3.5.4 Add `bootstrap` action to NatsOperator
- [x] 3.5.5 Add policies for super_admin access control

## Phase 4: Collector Onboarding Packages (DONE)

> **Note**: Collectors don't need tenant_slug - they authenticate with NATS account credentials.
> NATS handles subject prefixing via server-side subject mapping.
>
> **Implementation Note**: Instead of extending OnboardingPackage, a separate `CollectorPackage`
> resource was created specifically for collector deployments with NATS credentials.

### 4.1 CollectorPackage Resource (DONE)

- [x] 4.1.1 Create `ServiceRadar.Edge.CollectorPackage` Ash resource
  - Collector types: `:flowgger`, `:trapd`, `:netflow`, `:otel`
  - State machine: pending → provisioning → ready → downloaded → installed
  - Multi-tenancy via `tenant_id` attribute
- [x] 4.1.2 Add `nats_credential_id` relationship to track issued credentials
- [x] 4.1.3 Add `nats_creds_ciphertext` for encrypted NATS credentials (AshCloak)
- [x] 4.1.4 Create `ServiceRadar.Edge.NatsCredential` resource for credential tracking

### 4.2 Credential Provisioning (DONE)

- [x] 4.2.1 Create `ProvisionCollectorWorker` Oban job for async provisioning
- [x] 4.2.2 Verify tenant NATS account is ready before provisioning
- [x] 4.2.3 Call datasvc `GenerateUserCredentials` for NATS creds
- [x] 4.2.4 Store encrypted credentials in CollectorPackage via AshCloak
- [x] 4.2.5 Create NatsCredential record for tracking/revocation

### 4.3 API Endpoints (DONE)

- [x] 4.3.1 Create `CollectorController` for REST API access
- [x] 4.3.2 POST `/api/admin/collectors` - Create collector package
- [x] 4.3.3 GET `/api/admin/collectors/:id` - Get package status
- [x] 4.3.4 GET `/api/admin/collectors/:id/download` - Download with token
- [x] 4.3.5 POST `/api/admin/collectors/:id/revoke` - Revoke package

### 4.4 Package Download (DONE)

- [x] 4.4.1 Decrypt NATS credentials from AshCloak storage
- [x] 4.4.2 Generate collector config (with nats_creds_file path)
- [x] 4.4.3 Generate install script template
- [x] 4.4.4 Generate tarball bundle with all artifacts (`CollectorBundleGenerator`)
- [x] 4.4.5 Add bundle download endpoint (`GET /api/collectors/:id/bundle?token=...`)
- [ ] 4.4.6 Add mTLS certificate generation (optional, for collectors needing gRPC)

### 4.5 Package Contents (Target Structure)

```
serviceradar-collector-<id>.tar.gz/
├── certs/
│   ├── collector.pem      # mTLS cert
│   ├── collector-key.pem  # mTLS key
│   └── ca.pem             # Platform CA
├── nats.creds             # NATS account credentials
├── config.json            # Collector config
└── install.sh             # Installation script
```

### 4.6 CLI Enrollment Flow (DONE)

> **Enrollment Flow**:
> 1. Customer creates collector package in Web UI
> 2. UI shows CLI command: `serviceradar-cli enroll --token <token>`
> 3. Customer installs collector from apt/dnf package repo
> 4. Customer runs the enrollment command
> 5. CLI decodes token, calls API, writes files, starts service

- [x] 4.6.1 Create `EnrollmentToken` module for self-contained tokens
  - Base64-encoded JSON with: API URL, package ID, secret, expiry
  - SHA256 hashing for secure storage in DB
  - Token format: `{u: url, p: package_id, t: secret, e: expiry_unix}`
- [x] 4.6.2 Create `EnrollController` for enrollment API
  - `GET /api/enroll/:package_id?token=<secret>`
  - Validates token, returns NATS creds and config as JSON
  - Generates YAML config with collector-specific defaults
- [x] 4.6.3 Update `CollectorPackage` create action for enrollment tokens
  - Accept external token hash and expiry
  - Store token hash in `download_token_hash` field
- [x] 4.6.4 Update LiveView UI for enrollment command display
  - Show CLI command with copy button
  - Show package repo install instructions
- [x] 4.6.5 Update `ProvisionCollectorWorker` permissions
  - Collectors publish to simple subjects (no tenant prefix)
  - NATS account subject mapping handles tenant prefixing
- [x] 4.6.6 Update NATS account default subject mappings
  - Added: `syslog.>`, `snmp.>`, `otel.>`, `netflow.>`

## Phase 4: JetStream Configuration

### 4.1 Stream Configuration

- [ ] 4.1.1 Update `events` stream subjects to `*.events.>`
- [ ] 4.1.2 Update `snmp_traps` stream subjects to `*.logs.snmp`
- [ ] 4.1.3 Update other streams for tenant-prefixed patterns
- [ ] 4.1.4 Create migration script for existing stream data
- [ ] 4.1.5 Document stream subject pattern changes
- [ ] 4.1.6 Test streams with multi-tenant message flow

### 4.2 Consumer Configuration

- [ ] 4.2.1 Update durable consumer subject filters
- [ ] 4.2.2 Document consumer configuration for operators
- [ ] 4.2.3 Add health checks for consumer lag per tenant

## Phase 5: Collector NATS Credentials Support

> **Note**: Collectors need to support NATS credentials file authentication.
> No tenant_slug needed - NATS accounts handle subject mapping.

### 5.1 Rust Collectors (flowgger, trapd)

- [x] 5.1.1 Add `nats_creds_file` config option to flowgger
- [x] 5.1.2 Add `nats_creds_file` config option to trapd
- [x] 5.1.3 Update NATS connection to use credentials file when provided
- [ ] 5.1.4 Test collectors with NATS account authentication
- [ ] 5.1.5 Document collector configuration for operators

### 5.2 Config Examples

flowgger.toml:
```toml
[output]
type = "nats"
nats_url = "tls://nats.serviceradar.cloud:4222"
nats_subject = "logs.syslog"  # NATS maps to: <tenant>.logs.syslog
nats_creds_file = "/etc/serviceradar/nats.creds"

[security]
cert_file = "/etc/serviceradar/certs/collector.pem"
key_file = "/etc/serviceradar/certs/collector-key.pem"
ca_file = "/etc/serviceradar/certs/ca.pem"
```

trapd.json:
```json
{
  "listen_addr": "0.0.0.0:162",
  "nats_url": "tls://nats.serviceradar.cloud:4222",
  "subject": "logs.snmp",
  "nats_creds_file": "/etc/serviceradar/nats.creds",
  "nats_security": {
    "mode": "mtls",
    "cert_file": "/etc/serviceradar/certs/collector.pem",
    "key_file": "/etc/serviceradar/certs/collector-key.pem",
    "ca_file": "/etc/serviceradar/certs/ca.pem"
  }
}
```

## Phase 6: Per-Tenant EventWriter Pipelines (Optional)

> **Note**: Current EventWriter extracts tenant from subject prefix.
> Per-tenant pipelines are an optimization for high-volume deployments.

### 6.1 Core-elx Pipeline Orchestration

- [ ] 6.1.1 Start one EventWriter pipeline per tenant under `TenantRegistry`
- [ ] 6.1.2 Ensure pipeline processes set tenant context in process dictionary
- [ ] 6.1.3 Subscribe each pipeline to `<tenant-slug>.events.*` and related subjects
- [ ] 6.1.4 Add startup reconciliation to create pipelines for existing tenants
- [ ] 6.1.5 Update health checks to report per-tenant pipeline status

## Phase 7: Leaf Node Support

> **Note**: For customers deploying collectors in their own network.

### 7.1 Leaf Node Configuration

- [ ] 7.1.1 Create leaf node configuration template for customers
- [ ] 7.1.2 Document leaf node firewall requirements (outbound 4222/TLS)
- [ ] 7.1.3 Add leaf node credentials to collector onboarding package
- [ ] 7.1.4 Test leaf node connectivity and message routing
- [ ] 7.1.5 Create troubleshooting runbook for leaf node issues

### 7.2 Leaf Node Package Generation

- [ ] 7.2.1 Generate leaf node configuration for customer-network deployments
- [ ] 7.2.2 Include hub cluster connection URL and credentials
- [ ] 7.2.3 Add leaf node health check endpoint
- [ ] 7.2.4 Document leaf node deployment process

## Phase 8: Docker Compose / Helm

### 8.1 Docker Compose

- [x] 8.1.1 Add NATS operator/account configuration to compose setup
- [ ] 8.1.2 Create multi-tenant compose profile for testing
- [ ] 8.1.3 Add sample tenant accounts for local development
- [ ] 8.1.4 Document local development with NATS accounts

### 8.2 Helm Charts

- [ ] 8.2.1 Add NATS operator values to Helm chart
- [ ] 8.2.2 Create account provisioning Job/init container
- [ ] 8.2.3 Add nsc tooling to account management
- [ ] 8.2.4 Add leaf node configuration to edge deployment chart
- [ ] 8.2.5 Document Helm values for NATS tenant configuration

## Phase 8.5: Admin UI for NATS Management (DONE)

> **Note**: Super admin and tenant admin UI for managing NATS accounts.

### 8.5.1 Super Admin NATS Dashboard - DONE

- [x] 8.5.1.1 Create `Admin.NatsLive.Index` at `/admin/nats`
- [x] 8.5.1.2 Operator status card (public key, bootstrap status, errors)
- [x] 8.5.1.3 System account status card
- [x] 8.5.1.4 Tenant NATS accounts table with status filtering
- [x] 8.5.1.5 Reprovision action for failed tenant accounts
- [x] 8.5.1.6 Add "NATS" tab to admin navigation

### 8.5.2 Tenant NATS Account Detail Page - DONE

- [x] 8.5.2.1 Create `Admin.NatsLive.Show` at `/admin/nats/tenants/:id`
- [x] 8.5.2.2 Tenant info card (name, slug, status, plan)
- [x] 8.5.2.3 NATS account status card with provisioning details
- [x] 8.5.2.4 NATS credentials panel (public key, JWT - collapsible)
- [x] 8.5.2.5 Actions panel with reprovision and clear buttons
- [x] 8.5.2.6 Confirmation modal for destructive actions
- [x] 8.5.2.7 Clear NATS account action (revoke all credentials)

### 8.5.3 API Endpoints for NATS Management - DONE

- [x] 8.5.3.1 Create `NatsController` for API access
- [x] 8.5.3.2 POST `/api/admin/nats/bootstrap` endpoint
- [x] 8.5.3.3 GET `/api/admin/nats/status` endpoint
- [x] 8.5.3.4 GET `/api/admin/nats/tenants` endpoint
- [x] 8.5.3.5 POST `/api/admin/nats/tenants/:id/reprovision` endpoint

### 8.5.4 Router Updates - DONE

- [x] 8.5.4.1 Add `/admin/nats` route to admin live_session
- [x] 8.5.4.2 Add `/admin/nats/tenants/:id` route for detail page
- [x] 8.5.4.3 Add NATS API routes under `/api/admin/nats`

## Phase 9: Testing & Documentation

### 9.1 Testing

- [ ] 9.1.1 Unit tests for NATS AccountManager
- [ ] 9.1.2 Integration tests for account-based authentication
- [ ] 9.1.3 Integration tests for subject mapping
- [ ] 9.1.4 Integration tests for NATS account isolation (tenant A can't access tenant B)
- [ ] 9.1.5 End-to-end test with multi-tenant Docker Compose
- [ ] 9.1.6 Security test: verify collectors cannot publish to other tenants' subjects

### 9.2 Documentation

- [ ] 9.2.1 Update architecture docs with NATS account model
- [ ] 9.2.2 Document NATS account management for operators
- [ ] 9.2.3 Document collector deployment with NATS credentials
- [ ] 9.2.4 Add troubleshooting guide for tenant isolation issues
- [ ] 9.2.5 Document security model and threat mitigations

## Phase 10: Self-Hosted Considerations

> **Note**: Self-hosted customers may not need NATS accounts or leaf nodes.

### 10.1 Deployment Modes

- [ ] 10.1.1 Document "direct mode" for self-hosted (collectors connect directly to NATS)
- [ ] 10.1.2 Document "account mode" for SaaS (collectors use NATS accounts)
- [ ] 10.1.3 Simplify onboarding for self-hosted (optional NATS accounts)
- [ ] 10.1.4 Single-tenant mode: skip subject prefixing entirely

### 10.2 Configuration Templates

- [ ] 10.2.1 Create self-hosted collector config templates (no NATS creds needed)
- [ ] 10.2.2 Create SaaS collector config templates with NATS credentials
- [ ] 10.2.3 Document config differences between modes
