# Tasks: Platform Bootstrap

## Phase 1: Core Bootstrap Implementation

### 1.1 Platform Bootstrap GenServer

- [ ] 1.1.1 Create `lib/serviceradar/platform/bootstrap.ex` GenServer module
- [ ] 1.1.2 Implement `init/1` with async bootstrap trigger (5s delay for dependencies)
- [ ] 1.1.3 Implement `check_and_bootstrap/0` for first-install detection
- [ ] 1.1.4 Implement `ensure_default_tenant/0` - create if not exists
- [ ] 1.1.5 Implement `ensure_admin_user/1` - create with random password if not exists
- [ ] 1.1.6 Implement `ensure_tenant_membership/2` - owner role for admin
- [ ] 1.1.7 Add `status/0` public API for health checks
- [ ] 1.1.8 Add structured logging with `[PLATFORM BOOTSTRAP]` prefix
- [ ] 1.1.9 Ensure the first user created is a platform owner with `:super_admin` role

### 1.2 Credential Storage Module

- [ ] 1.2.1 Create `lib/serviceradar/platform/credential_storage.ex` module
- [ ] 1.2.2 Implement `deployment_mode/0` - detect Docker Compose vs Kubernetes
- [ ] 1.2.3 Implement `store_credentials/2` - dispatch to appropriate backend
- [ ] 1.2.4 Implement `store_file/2` - JSON file with `0600` permissions
- [ ] 1.2.5 Implement `store_kubernetes_secret/2` - K8s API call
- [ ] 1.2.6 Implement `credentials_exist?/0` - check if already stored
- [ ] 1.2.7 Add error handling with graceful fallback

### 1.3 Password Generation

- [ ] 1.3.1 Create `lib/serviceradar/platform/password.ex` module
- [ ] 1.3.2 Implement `generate/1` - cryptographically secure random password
- [ ] 1.3.3 Use `:crypto.strong_rand_bytes/1` for entropy source
- [ ] 1.3.4 Support configurable length (default 24 characters)
- [ ] 1.3.5 Include uppercase, lowercase, digits, and symbols

### 1.4 Application Integration

- [ ] 1.4.1 Add `Platform.Bootstrap` to supervision tree in `application.ex`
- [ ] 1.4.2 Position before `NATS.OperatorBootstrap` in startup order
- [ ] 1.4.3 Use `transient` restart strategy (don't restart on normal exit)
- [ ] 1.4.4 Add `PLATFORM_ADMIN_EMAIL` to `runtime.exs` config

### 1.5 Console Output

- [ ] 1.5.1 Log credentials to console on first install only
- [ ] 1.5.2 Use clear banner format for visibility
- [ ] 1.5.3 Include instructions for first login
- [ ] 1.5.4 Never log password on subsequent restarts

## Phase 2: Docker Compose Support

### 2.1 Volume Configuration

- [ ] 2.1.1 Add `platform_data` named volume to docker-compose.yml
- [ ] 2.1.2 Mount to `/data/platform` in core-elx service
- [ ] 2.1.3 Document credential retrieval in compose comments

### 2.2 Environment Variables

- [ ] 2.2.1 Add `PLATFORM_ADMIN_EMAIL` environment variable support
- [ ] 2.2.2 Document override in docker-compose.yml comments
- [ ] 2.2.3 Add example to docker-compose.override.yml.example

### 2.3 Testing

- [ ] 2.3.1 Test fresh install (no volumes)
- [ ] 2.3.2 Test restart with existing tenant/admin
- [ ] 2.3.3 Test credential file creation and permissions
- [ ] 2.3.4 Verify NATS account creation after bootstrap

## Phase 3: Kubernetes Support

### 3.1 Secret Management

- [ ] 3.1.1 Add K8s API client to dependencies (`:k8s` or HTTP client)
- [ ] 3.1.2 Implement Secret creation in namespace
- [ ] 3.1.3 Handle Secret update if exists but different
- [ ] 3.1.4 Add fallback to file if Secret creation fails

### 3.2 RBAC Configuration

- [ ] 3.2.1 Add Role with secrets create/update/get permissions
- [ ] 3.2.2 Add RoleBinding for core-elx ServiceAccount
- [ ] 3.2.3 Update Helm chart values.yaml with RBAC options
- [ ] 3.2.4 Test with RBAC enabled and disabled

### 3.3 Helm Chart Updates

- [ ] 3.3.1 Add RBAC templates to helm/serviceradar/templates/
- [ ] 3.3.2 Add `bootstrap.enabled` values option
- [ ] 3.3.3 Add `bootstrap.adminEmail` values option
- [ ] 3.3.4 Document in values.yaml comments

## Phase 4: Integration Testing

### 4.1 Unit Tests

- [ ] 4.1.1 Test `Password.generate/1` entropy and character set
- [ ] 4.1.2 Test `CredentialStorage.deployment_mode/0` detection
- [ ] 4.1.3 Test `Bootstrap.check_and_bootstrap/0` idempotency

### 4.2 Integration Tests

- [ ] 4.2.1 Test full bootstrap flow with clean database
- [ ] 4.2.2 Test bootstrap with existing tenant (skip creation)
- [ ] 4.2.3 Test bootstrap with existing admin (skip password gen)
- [ ] 4.2.4 Test NATS account creation triggered after bootstrap

### 4.3 End-to-End Tests

- [ ] 4.3.1 Test Docker Compose fresh install → first login
- [ ] 4.3.2 Test Kubernetes fresh install → first login
- [ ] 4.3.3 Test credential retrieval methods documented correctly

## Phase 5: Documentation

### 5.1 Installation Guide Updates

- [ ] 5.1.1 Update Docker Compose quick start with bootstrap info
- [ ] 5.1.2 Update Kubernetes installation with RBAC requirements
- [ ] 5.1.3 Add "First Login" section with credential retrieval

### 5.2 Operations Guide

- [ ] 5.2.1 Document credential retrieval for Docker Compose
- [ ] 5.2.2 Document credential retrieval for Kubernetes
- [ ] 5.2.3 Document password change procedure after first login
- [ ] 5.2.4 Document bootstrap troubleshooting

## Phase 6: Seeds.exs Cleanup (Optional)

### 6.1 Development-Only Seeds

- [ ] 6.1.1 Add comment that seeds.exs is for development only
- [ ] 6.1.2 Remove hardcoded passwords (use bootstrap flow in dev too)
- [ ] 6.1.3 Or keep as-is for backwards compatibility
