# Tasks: Per-Tenant Process Isolation

## Status Update (2025-12)

**Scope Simplified**: With removal of `serviceradar-agent-elx`, ERTS-enabled nodes are no longer deployed in customer environments.

**Changes**:
- Sections 5, 5b (ERTS-level isolation) removed - code exists but no longer needed for security
- NATS channel prefixing moved to new proposal: `add-nats-tenant-isolation`

**Remaining Focus**:
- Certificate infrastructure (tenant CAs)
- Onboarding packages with tenant certs
- Poller validation of agent certificates

---

## 1. Certificate Infrastructure

- [x] 1.1 Update `generate-certs.sh` to support per-tenant intermediate CA generation
- [x] 1.2 Create `generate-tenant-ca.sh` script for new tenant CA creation
- [x] 1.3 Add tenant CA storage in Kubernetes secrets (or Vault integration)
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

## 4. Poller Tenant Validation

- [x] 4.1 Add TenantResolver for certificate CN parsing
- [x] 4.2 Extract tenant from connecting client certificate
- [x] 4.3 Validate tenant from certificate CN format
- [x] 4.4 Integrate mTLS into poller AgentClient
- [x] 4.5 Add custom TLS verify_fun for tenant validation
- [ ] 4.6 Log tenant for audit trail

## 5. Go Tenant Utilities

- [x] 5.1 Create `pkg/tenant` package with CN parsing
- [x] 5.2 Add `ParseCN()` function for tenant extraction
- [x] 5.3 Add `PrefixChannel()` helper for NATS subjects
- [ ] 5.4 Add tenant extraction from gRPC peer certificate

## 6. Testing

- [ ] 6.1 Unit tests for certificate CN parsing (Go - pkg/tenant)
- [ ] 6.2 Integration tests for tenant cert validation (Elixir poller)
- [ ] 6.3 Integration tests for onboarding package generation
- [ ] 6.4 End-to-end test with multi-tenant setup

## 7. Docker Compose Development

- [x] 7.1 Generate tenant-specific certs in compose setup
- [ ] 7.2 Add example multi-tenant docker-compose.override.yml
- [ ] 7.3 Document local development with multiple tenants

## 8. Kubernetes/Helm Updates

- [x] 8.1 Add Helm values for tenant CA secret reference
- [ ] 8.2 Update Go agent deployments for tenant-specific certs
- [ ] 8.3 Document per-tenant Kubernetes deployment pattern

## 9. Documentation

- [ ] 9.1 Update architecture docs with simplified isolation model
- [ ] 9.2 Document certificate hierarchy and management
- [ ] 9.3 Update onboarding docs for tenant-scoped packages
