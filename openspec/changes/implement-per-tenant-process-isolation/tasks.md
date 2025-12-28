# Tasks: Per-Tenant Process Isolation

## Status Update (2025-12)

**Scope Simplified**: With removal of `serviceradar-agent-elx`, ERTS-enabled nodes are no longer deployed in customer environments. Sections 5, 5b (ERTS-level isolation) are now **OBSOLETE** - the code can be removed.

Focus areas:
- Certificate infrastructure (tenant CAs)
- Onboarding packages with tenant certs
- Go agent/poller tenant awareness
- NATS channel prefixing

---

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
- [ ] 3.6 Update Go agent config templates with tenant prefix

## 4. Go Edge Components (agent)

- [ ] 4.1 Add certificate CN parsing to extract tenant ID
- [ ] 4.2 Update mTLS validation to check tenant CA chain
- [ ] 4.3 Add tenant ID to gRPC metadata
- [ ] 4.4 Update NATS channel names to use tenant prefix
- [ ] 4.5 Add configuration option for tenant ID (from cert or config)
- [ ] 4.6 Log tenant ID in all operations for debugging

## ~~5. Elixir Poller/Agent Updates~~ (OBSOLETE)

> **REMOVED**: No Elixir agents in customer networks. Pollers are internal.

- [x] ~~5.1 Add tenant_id/tenant_slug awareness to Config~~
- [x] ~~5.2 Add certificate CN parsing to extract tenant slug~~
- [x] ~~5.3 Add NATS channel prefixing helper~~
- [x] ~~5.4 Add tenant-specific EPMD cookie derivation~~
- [x] ~~5.5 Add Horde registry key namespacing with tenant scope~~
- [x] ~~5.6 Remove EPMD cookie isolation in favor of shared cluster~~

## ~~5b. Per-Tenant Process Isolation (Option D - Hybrid)~~ (OBSOLETE)

> **REMOVED**: ERTS cluster is internal/trusted. No need for per-tenant Horde registries or TenantGuard.

- [x] ~~5b.1 Create TenantRegistry module for dynamic per-tenant Horde registries~~
- [x] ~~5b.2 Create TenantGuard module for process-level tenant validation~~
- [x] ~~5b.3 Update PollerRegistry to delegate to TenantRegistry~~
- [x] ~~5b.4 Update AgentRegistry to delegate to TenantRegistry~~
- [x] ~~5b.5 Add per-tenant DynamicSupervisors for process management~~
- [x] ~~5b.6 Add slug -> UUID alias lookup via ETS table~~
- [x] ~~5b.7 Create TenantSchemas module for SOC2 PostgreSQL schema isolation~~
- [x] ~~5b.8 Add Ash lifecycle hook to create registry on tenant creation~~
- [x] ~~5b.9 Add tests for cross-tenant process isolation~~

**ACTION**: Remove TenantRegistry, TenantGuard, TenantSchemas if implemented. Simplify to shared registries.

## 6. Poller Tenant Validation (Simplified)

- [x] 6.1 Add TenantResolver for certificate CN parsing
- [x] 6.2 Extract tenant from connecting client certificate
- [x] 6.3 Validate tenant from certificate CN format
- [ ] 6.4 Poller validates agent cert matches expected tenant
- [ ] 6.5 Log tenant for audit trail

## 7. NATS Channel Prefixing

- [x] 7.1 Define tenant channel prefix format: `<tenant-slug>.<channel>`
- [x] 7.2 Create ServiceRadar.NATS.Channels module
- [ ] 7.3 Update Rust crates to use prefixed channels
- [ ] 7.4 Update Go services to use prefixed channels
- [x] 7.5 Update Elixir services to use prefixed channels (Config module)
- [ ] 7.6 Add JetStream stream configuration for tenant streams

## 8. Testing

- [ ] 8.1 Unit tests for certificate CN parsing (Go agent)
- [ ] 8.2 Integration tests for tenant cert validation
- [ ] 8.3 Integration tests for onboarding package generation
- [ ] 8.4 End-to-end test with multi-tenant setup

## 9. Docker Compose Development

- [ ] 9.1 Generate tenant-specific certs in compose setup
- [ ] 9.2 Add example multi-tenant docker-compose.override.yml
- [ ] 9.3 Document local development with multiple tenants

## 10. Kubernetes/Helm Updates

- [ ] 10.1 Add Helm values for tenant CA secret reference
- [ ] 10.2 Update Go agent deployments for tenant-specific certs
- [ ] 10.3 Document per-tenant Kubernetes deployment pattern

## 11. Documentation

- [ ] 11.1 Update architecture docs with simplified isolation model
- [ ] 11.2 Document certificate hierarchy and management
- [ ] 11.3 Update onboarding docs for tenant-scoped packages
