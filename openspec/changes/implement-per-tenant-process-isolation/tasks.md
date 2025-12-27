# Tasks: Per-Tenant Process Isolation

## 1. Certificate Infrastructure

- [ ] 1.1 Update `generate-certs.sh` to support per-tenant intermediate CA generation
- [ ] 1.2 Create `generate-tenant-ca.sh` script for new tenant CA creation
- [ ] 1.3 Add tenant CA storage in Kubernetes secrets (or Vault integration)
- [ ] 1.4 Create certificate CN format: `<component>.<tenant-id>.serviceradar`
- [ ] 1.5 Add certificate generation for edge components using tenant CA
- [ ] 1.6 Document certificate hierarchy and rotation procedures

## 2. Tenant Creation Flow

- [ ] 2.1 Add `create_tenant_ca` action to Tenant resource
- [ ] 2.2 Store tenant CA cert/key references in tenant record
- [ ] 2.3 Generate tenant CA on tenant creation (or first onboarding)
- [ ] 2.4 Add UI for viewing/regenerating tenant CA

## 3. Onboarding Package Updates

- [ ] 3.1 Update `OnboardingPackage` resource to include tenant CA cert
- [ ] 3.2 Generate component certificate signed by tenant CA (not platform CA)
- [ ] 3.3 Include tenant ID in certificate CN
- [ ] 3.4 Add NATS channel prefix configuration to package
- [ ] 3.5 Update download endpoint to serve tenant-specific bundles
- [ ] 3.6 Update agent/poller/checker config templates with tenant prefix

## 4. Go Edge Components (agent/poller)

- [ ] 4.1 Add certificate CN parsing to extract tenant ID
- [ ] 4.2 Update mTLS validation to check tenant CA chain
- [ ] 4.3 Add tenant ID to gRPC metadata for core-elx calls
- [ ] 4.4 Update NATS channel names to use tenant prefix
- [ ] 4.5 Add configuration option for tenant ID (from cert or config)
- [ ] 4.6 Log tenant ID in all operations for debugging

## 5. Core-Elx Updates

- [ ] 5.1 Add certificate CN parsing in gRPC interceptor
- [ ] 5.2 Extract tenant ID from connecting client certificate
- [ ] 5.3 Validate tenant ID matches expected format
- [ ] 5.4 Use extracted tenant ID for Ash actor context
- [ ] 5.5 Add platform admin certificate bypass for cross-tenant access
- [ ] 5.6 Log tenant extraction for audit trail

## 6. NATS Channel Prefixing

- [ ] 6.1 Define tenant channel prefix format: `<tenant-id>.<channel>`
- [ ] 6.2 Update Rust crates to use prefixed channels
- [ ] 6.3 Update Go services to use prefixed channels
- [ ] 6.4 Update Elixir services to use prefixed channels
- [ ] 6.5 Add JetStream stream configuration for tenant streams

## 7. Testing

- [ ] 7.1 Unit tests for certificate CN parsing
- [ ] 7.2 Integration tests for same-tenant connection success
- [ ] 7.3 Integration tests for cross-tenant connection rejection
- [ ] 7.4 Integration tests for onboarding package generation
- [ ] 7.5 End-to-end test with multi-tenant Docker Compose setup
- [ ] 7.6 Test platform admin cross-tenant access

## 8. Docker Compose Development

- [ ] 8.1 Add per-tenant profile for edge components
- [ ] 8.2 Generate tenant-specific certs in compose setup
- [ ] 8.3 Add example multi-tenant docker-compose.override.yml
- [ ] 8.4 Document local development with multiple tenants

## 9. Kubernetes/Helm Updates

- [ ] 9.1 Add Helm values for tenant CA secret reference
- [ ] 9.2 Update edge component deployments for tenant-specific certs
- [ ] 9.3 Add tenant-specific ConfigMaps for NATS channel config
- [ ] 9.4 Document per-tenant Kubernetes deployment pattern

## 10. Documentation

- [ ] 10.1 Update architecture docs with hybrid isolation model
- [ ] 10.2 Document certificate hierarchy and management
- [ ] 10.3 Update onboarding docs for tenant-scoped packages
- [ ] 10.4 Add runbook for tenant CA rotation
- [ ] 10.5 Add troubleshooting guide for certificate issues
