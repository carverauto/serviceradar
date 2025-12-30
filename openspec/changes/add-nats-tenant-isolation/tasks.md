# Tasks: NATS Tenant Isolation

## Phase 1: Channel Prefixing

### 1.1 Go Publisher Updates (pkg/natsutil, pkg/tenant, pkg/grpc)

> **Note**: These changes apply to the Go core service which is being deprecated in favor
> of the Elixir core (serviceradar-core-elx). Changes are complete but may not be actively used.

- [x] 1.1.1 Update `pkg/natsutil/events.go` to accept tenant slug parameter
- [x] 1.1.2 Add tenant prefix utilities to `pkg/tenant/tenant.go`
- [x] 1.1.3 Update `EventPublisher` to extract tenant from context
- [x] 1.1.4 Add feature flag `NATS_TENANT_PREFIX_ENABLED` (default: false)
- [x] 1.1.5 Add `TenantInterceptor` to gRPC server to inject tenant context from mTLS certs
- [x] 1.1.6 Tenant context now flows through to poller health event publishing
- [x] 1.1.7 Add unit tests for prefixed publishing

### 1.2 Go Consumer Updates (DEPRECATED - use Elixir EventWriter instead)

> **Note**: The Go db-event-writer is deprecated. Event consumption is handled by
> the Elixir EventWriter in serviceradar-core-elx. See section 1.4 for active work.

- [~] 1.2.1 ~~Update db-event-writer consumer config~~ → Use Elixir EventWriter
- [~] 1.2.2 ~~Add tenant extraction from subject prefix~~ → Done in Elixir
- [~] 1.2.3 ~~Update netflow consumer config~~ → Use Elixir EventWriter
- [~] 1.2.4 ~~Add backward compatibility~~ → Done in Elixir
- [~] 1.2.5 ~~Add integration tests~~ → Test Elixir EventWriter

### 1.3 Rust Consumer Updates

- [ ] 1.3.1 Update zen-consumer config for prefixed subjects
- [ ] 1.3.2 Add tenant extraction to Rust consumer processing
- [ ] 1.3.3 Update decision group subject patterns
- [ ] 1.3.4 Add config option for prefix mode (prefixed/legacy/both)
- [ ] 1.3.5 Test Rust consumers with prefixed messages

### 1.4 Elixir Integration (core-elx EventWriter)

- [x] 1.4.1 `ServiceRadar.NATS.Channels` module already has tenant prefix helpers
- [x] 1.4.2 Update `EventWriter.Config` with `*.events.>` wildcard patterns for all streams
- [x] 1.4.3 Update `EventWriter.Pipeline.handle_message` to extract tenant from subject prefix
- [x] 1.4.4 Update `EventWriter.Pipeline.handle_batch` to set tenant context from message metadata
- [x] 1.4.5 Add backward compatibility for non-prefixed subjects (legacy streams)

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

## Phase 7: Rust Collector Tenant Context

> **Note**: Flowgger and trapd are Rust-based collectors that need tenant prefix support.

### 7.1 Config Updates

- [ ] 7.1.1 Add `tenant_slug` field to flowgger TOML config
- [ ] 7.1.2 Add `tenant_slug` field to trapd JSON config
- [ ] 7.1.3 Update `config-bootstrap` crate to parse tenant_slug
- [ ] 7.1.4 Validate tenant_slug against mTLS certificate CN/SAN

### 7.2 Subject Prefixing

- [ ] 7.2.1 Update flowgger NATS output to prefix subject with tenant_slug
- [ ] 7.2.2 Update trapd NATS output to prefix subject with tenant_slug
- [ ] 7.2.3 Add environment variable override for tenant_slug
- [ ] 7.2.4 Add logging for tenant-prefixed subject publishing

### 7.3 Testing

- [ ] 7.3.1 Unit tests for tenant prefix in flowgger
- [ ] 7.3.2 Unit tests for tenant prefix in trapd
- [ ] 7.3.3 Integration tests with prefixed NATS subjects

## Phase 8: Collector Onboarding Packages

> **Note**: Extend OnboardingPackage to support collector types and generate tenant-aware configs.

### 8.1 OnboardingPackage Extensions

- [ ] 8.1.1 Add collector component types: `:flowgger`, `:trapd`, `:netflow`, `:otel`
- [ ] 8.1.2 Add `nats_account_user` attribute for NATS account credentials
- [ ] 8.1.3 Add `nats_account_creds_ciphertext` for encrypted NATS credentials
- [ ] 8.1.4 Add `collector_config_json` for pre-generated collector config

### 8.2 Package Generation

- [ ] 8.2.1 Generate collector config with `tenant_slug` from tenant context
- [ ] 8.2.2 Generate NATS user credentials for tenant account
- [ ] 8.2.3 Include mTLS certificates signed by tenant CA
- [ ] 8.2.4 Create install script template (`install-collector.sh`)
- [ ] 8.2.5 Package all artifacts into downloadable tarball

### 8.3 NATS Account Provisioning

- [ ] 8.3.1 Create NATS account for tenant on first collector package
- [ ] 8.3.2 Generate NATS user credentials with tenant-scoped permissions
- [ ] 8.3.3 Store NATS credentials in Vault or encrypt in database
- [ ] 8.3.4 Add account limits (connections, data, payload) per tenant

### 8.4 Leaf Node Support

- [ ] 8.4.1 Generate leaf node configuration for customer-network deployments
- [ ] 8.4.2 Include hub cluster connection URL and credentials
- [ ] 8.4.3 Document firewall requirements (outbound 4222/TLS)
- [ ] 8.4.4 Add leaf node health check endpoint

## Phase 9: Self-Hosted Considerations

> **Note**: Self-hosted customers may not need edge NATS leaf nodes.

### 9.1 Deployment Modes

- [ ] 9.1.1 Document "direct mode" for self-hosted (collectors connect directly to NATS)
- [ ] 9.1.2 Document "leaf mode" for SaaS (collectors use leaf node)
- [ ] 9.1.3 Add deployment mode flag to collector config
- [ ] 9.1.4 Simplify onboarding for self-hosted (no NATS accounts needed)

### 9.2 Configuration Templates

- [ ] 9.2.1 Create self-hosted collector config templates
- [ ] 9.2.2 Create SaaS collector config templates with leaf node
- [ ] 9.2.3 Document config differences between modes
