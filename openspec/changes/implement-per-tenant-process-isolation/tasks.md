# Tasks: Per-Tenant Process Isolation

## 1. Certificate Infrastructure

- [ ] 1.1 Update `generate-certs.sh` to support per-tenant intermediate CA generation
- [ ] 1.2 Create `generate-tenant-ca.sh` script for new tenant CA creation
- [ ] 1.3 Add tenant CA storage in Kubernetes secrets (or Vault integration)
- [x] 1.4 Create certificate CN format: `<component>.<partition>.<tenant-slug>.serviceradar`
- [x] 1.5 Add certificate generation for edge components using tenant CA
- [ ] 1.6 Document certificate hierarchy and rotation procedures

## 2. Tenant Creation Flow

- [x] 2.1 Add `generate_ca` action to Tenant resource
- [x] 2.2 Create TenantCA resource to store tenant CA cert/key
- [x] 2.3 Generate tenant CA on tenant creation (or first onboarding)
- [ ] 2.4 Add UI for viewing/regenerating tenant CA

## 3. Onboarding Package Updates

- [x] 3.1 Update `OnboardingPackage` to include tenant CA cert
- [x] 3.2 Generate component certificate signed by tenant CA (not platform CA)
- [x] 3.3 Include tenant ID in certificate CN
- [x] 3.4 Add NATS channel prefix configuration to package
- [ ] 3.5 Update download endpoint to serve tenant-specific bundles
- [ ] 3.6 Update agent/poller/checker config templates with tenant prefix

## 4. Go Edge Components (agent/poller)

- [ ] 4.1 Add certificate CN parsing to extract tenant ID
- [ ] 4.2 Update mTLS validation to check tenant CA chain
- [ ] 4.3 Add tenant ID to gRPC metadata for core-elx calls
- [ ] 4.4 Update NATS channel names to use tenant prefix
- [ ] 4.5 Add configuration option for tenant ID (from cert or config)
- [ ] 4.6 Log tenant ID in all operations for debugging

## 5. Elixir Poller/Agent Updates

- [x] 5.1 Add tenant_id/tenant_slug awareness to Config
- [x] 5.2 Add certificate CN parsing to extract tenant slug
- [x] 5.3 Add NATS channel prefixing helper
- [x] ~~5.4 Add tenant-specific EPMD cookie derivation~~ (REMOVED: using shared cluster with per-tenant Horde registries instead)
- [x] 5.5 Add Horde registry key namespacing with tenant scope
- [x] 5.6 Remove EPMD cookie isolation in favor of shared cluster

## 5b. Per-Tenant Process Isolation (Option D - Hybrid)

- [x] 5b.1 Create TenantRegistry module for dynamic per-tenant Horde registries
- [x] 5b.2 Create TenantGuard module for process-level tenant validation
- [x] 5b.3 Update PollerRegistry to delegate to TenantRegistry
- [x] 5b.4 Update AgentRegistry to delegate to TenantRegistry
- [x] 5b.5 Add per-tenant DynamicSupervisors for process management
- [x] 5b.6 Add slug -> UUID alias lookup via ETS table
- [x] 5b.7 Create TenantSchemas module for SOC2 PostgreSQL schema isolation
- [x] 5b.8 Add Ash lifecycle hook to create registry on tenant creation
- [x] 5b.9 Add tests for cross-tenant process isolation

## 6. Core-Elx Updates

- [x] 6.1 Add TenantResolver for certificate CN parsing
- [x] 6.2 Extract tenant from connecting client certificate
- [x] 6.3 Validate tenant from certificate CN format
- [ ] 6.4 Use extracted tenant ID for Ash actor context
- [ ] 6.5 Add platform admin certificate bypass for cross-tenant access
- [ ] 6.6 Log tenant extraction for audit trail

## 7. NATS Channel Prefixing

- [x] 7.1 Define tenant channel prefix format: `<tenant-slug>.<channel>`
- [x] 7.2 Create ServiceRadar.NATS.Channels module
- [ ] 7.3 Update Rust crates to use prefixed channels
- [ ] 7.4 Update Go services to use prefixed channels
- [x] 7.5 Update Elixir services to use prefixed channels (Config module)
- [ ] 7.6 Add JetStream stream configuration for tenant streams

## 8. Testing

- [ ] 8.1 Unit tests for certificate CN parsing
- [ ] 8.2 Integration tests for same-tenant connection success
- [ ] 8.3 Integration tests for cross-tenant connection rejection
- [ ] 8.4 Integration tests for onboarding package generation
- [ ] 8.5 End-to-end test with multi-tenant Docker Compose setup
- [ ] 8.6 Test platform admin cross-tenant access

## 9. Docker Compose Development

- [ ] 9.1 Add per-tenant profile for edge components
- [ ] 9.2 Generate tenant-specific certs in compose setup
- [ ] 9.3 Add example multi-tenant docker-compose.override.yml
- [ ] 9.4 Document local development with multiple tenants

## 10. Kubernetes/Helm Updates

- [ ] 10.1 Add Helm values for tenant CA secret reference
- [ ] 10.2 Update edge component deployments for tenant-specific certs
- [ ] 10.3 Add tenant-specific ConfigMaps for NATS channel config
- [ ] 10.4 Document per-tenant Kubernetes deployment pattern

## 11. Documentation

- [ ] 11.1 Update architecture docs with hybrid isolation model
- [ ] 11.2 Document certificate hierarchy and management
- [ ] 11.3 Update onboarding docs for tenant-scoped packages
- [ ] 11.4 Add runbook for tenant CA rotation
- [ ] 11.5 Add troubleshooting guide for certificate issues
