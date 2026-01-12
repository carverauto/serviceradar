## 1. Specification Updates
- [ ] 1.1 Update edge-architecture for per-tenant gateway pools
- [ ] 1.2 Update agent-connectivity for tenant gateway endpoints
- [ ] 1.3 Update tenant-isolation for tenant-scoped gateway certs
- [ ] 1.4 Update ash-jobs for tenant-aware gateway selection
- [ ] 1.5 Add tenant-gateway-fleet spec for provisioning + routing

## 2. Control Plane & Registry
- [ ] 2.1 Add tenant gateway pool registration metadata (tenant, pool, endpoint)
- [ ] 2.2 Ensure gateway selection is tenant-scoped in scheduling/dispatch
- [ ] 2.3 Emit per-tenant gateway metrics for billing/sizing

## 3. Gateway Service Changes
- [ ] 3.1 Enforce tenant-scoped mTLS validation at gateway
- [ ] 3.2 Require tenant identity on gateway startup (no shared tenant state)
- [ ] 3.3 Support multiple gateway instances per tenant (HA)

## 4. Provisioning & Routing
- [ ] 4.1 Define Kubernetes CRD/operator workflow for gateway pools
- [ ] 4.2 Create per-tenant Service/Ingress/LB and DNS conventions
- [ ] 4.3 Add platform defaults for single-tenant (on-prem) installs

## 5. Onboarding & Config
- [ ] 5.1 Update onboarding packages to emit tenant gateway endpoint
- [ ] 5.2 Ensure agent bootstrap config uses tenant gateway endpoint

## 6. Tests & Docs
- [ ] 6.1 Add tests for tenant gateway selection and mTLS enforcement
- [ ] 6.2 Add deployment docs for per-tenant gateway pools
