# Tasks: NATS Tenant Isolation

## Phase 1: Channel Prefixing

### 1.1 Go Publisher Updates

- [ ] 1.1.1 Update `pkg/natsutil/events.go` to accept tenant slug parameter
- [ ] 1.1.2 Add `PublishWithTenant(ctx, tenant, subject, data)` helper
- [ ] 1.1.3 Update `EventPublisher` to extract tenant from context
- [ ] 1.1.4 Add feature flag `NATS_TENANT_PREFIX_ENABLED` (default: false)
- [ ] 1.1.5 Update core service event publishing to include tenant context
- [ ] 1.1.6 Update poller health event publishing with tenant
- [ ] 1.1.7 Add unit tests for prefixed publishing

### 1.2 Go Consumer Updates

- [ ] 1.2.1 Update db-event-writer consumer config to use `*.events.*` patterns
- [ ] 1.2.2 Add tenant extraction from subject prefix in message processor
- [ ] 1.2.3 Update netflow consumer config for prefixed subjects
- [ ] 1.2.4 Add backward compatibility for non-prefixed subjects (migration period)
- [ ] 1.2.5 Add integration tests for prefixed message consumption

### 1.3 Rust Consumer Updates

- [ ] 1.3.1 Update zen-consumer config for prefixed subjects
- [ ] 1.3.2 Add tenant extraction to Rust consumer processing
- [ ] 1.3.3 Update decision group subject patterns
- [ ] 1.3.4 Add config option for prefix mode (prefixed/legacy/both)
- [ ] 1.3.5 Test Rust consumers with prefixed messages

### 1.4 Elixir Integration (if applicable)

- [ ] 1.4.1 Review if Elixir services publish to NATS directly
- [ ] 1.4.2 Add tenant prefix to any NATS publishers in Elixir
- [ ] 1.4.3 Update `ServiceRadar.NATS.Channels` module with prefix helpers

## Phase 2: JetStream Configuration

### 2.1 Stream Configuration

- [ ] 2.1.1 Update `events` stream subjects to `*.events.>`
- [ ] 2.1.2 Create migration script for existing stream data
- [ ] 2.1.3 Document stream subject pattern changes
- [ ] 2.1.4 Test stream with multi-tenant message flow

### 2.2 Consumer Configuration

- [ ] 2.2.1 Update durable consumer subject filters
- [ ] 2.2.2 Document consumer configuration for operators
- [ ] 2.2.3 Add health checks for consumer lag per tenant

## Phase 3: NATS Accounts

### 3.1 Account Infrastructure

- [ ] 3.1.1 Create NATS account configuration template
- [ ] 3.1.2 Add account generation to tenant onboarding flow
- [ ] 3.1.3 Create `platform` account for internal services
- [ ] 3.1.4 Configure account-level permissions (publish/subscribe)
- [ ] 3.1.5 Add account credential storage (Vault or K8s secrets)

### 3.2 Leaf Node Configuration

- [ ] 3.2.1 Create leaf node configuration template for customers
- [ ] 3.2.2 Document leaf node firewall requirements
- [ ] 3.2.3 Add leaf node credentials to collector onboarding package
- [ ] 3.2.4 Test leaf node connectivity and message routing
- [ ] 3.2.5 Create troubleshooting runbook for leaf node issues

### 3.3 Collector Integration

- [ ] 3.3.1 Update flowgger config template with NATS account credentials
- [ ] 3.3.2 Update OTEL collector config template
- [ ] 3.3.3 Update syslog collector config template
- [ ] 3.3.4 Add NATS credentials to onboarding package generation
- [ ] 3.3.5 Test end-to-end collector → NATS → consumer flow

## Phase 4: Docker Compose / Helm

### 4.1 Docker Compose

- [ ] 4.1.1 Add NATS account configuration to compose setup
- [ ] 4.1.2 Create multi-tenant compose profile for testing
- [ ] 4.1.3 Document local development with tenant prefixes

### 4.2 Helm Charts

- [ ] 4.2.1 Add NATS account values to Helm chart
- [ ] 4.2.2 Create account provisioning Job/CronJob
- [ ] 4.2.3 Add leaf node configuration to edge deployment chart
- [ ] 4.2.4 Document Helm values for NATS tenant configuration

## Phase 5: Testing & Documentation

### 5.1 Testing

- [ ] 5.1.1 Unit tests for tenant prefix utilities (Go)
- [ ] 5.1.2 Unit tests for tenant prefix utilities (Rust)
- [ ] 5.1.3 Integration tests for prefixed event flow
- [ ] 5.1.4 Integration tests for NATS account isolation
- [ ] 5.1.5 End-to-end test with multi-tenant Docker Compose

### 5.2 Documentation

- [ ] 5.2.1 Update architecture docs with NATS tenant model
- [ ] 5.2.2 Document NATS account management for operators
- [ ] 5.2.3 Document collector deployment with NATS credentials
- [ ] 5.2.4 Add troubleshooting guide for tenant isolation issues

## Phase 6: Per-Tenant EventWriter Pipelines

### 6.1 Core-elx Pipeline Orchestration

- [ ] 6.1.1 Start one EventWriter pipeline per tenant under `TenantRegistry`
- [ ] 6.1.2 Ensure pipeline processes set tenant context in process dictionary
- [ ] 6.1.3 Subscribe each pipeline to `<tenant-slug>.events.*` and related subjects
- [ ] 6.1.4 Add startup reconciliation to create pipelines for existing tenants
- [ ] 6.1.5 Update health checks to report per-tenant pipeline status
