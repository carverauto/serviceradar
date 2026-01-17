# Change: Per-tenant agent gateway pools

## Why
The current multi-tenant agent gateway shares process space across tenants, which complicates hard isolation, per-tenant billing/visibility, and failure containment. We want a design that can scale to thousands of tenants without major refactors and enforces tenant boundaries at the gateway layer.

## What Changes
- Introduce per-tenant gateway pools (one or more gateway instances per tenant) that join the shared ERTS cluster.
- Require tenant-scoped gateway certificates and mTLS validation so gateways only accept agents from the same tenant.
- Provide tenant-specific gateway endpoints (DNS/LB) for agent connectivity and onboarding.
- Add a provisioning workflow (Kubernetes-first) to create, scale, and route gateway pools per tenant.

## Impact
- Affected specs: edge-architecture, agent-connectivity, tenant-isolation, ash-jobs, tenant-gateway-fleet (new).
- Affected services: serviceradar_agent_gateway, serviceradar_core, web-ng, edge onboarding.
- Deployment: Kubernetes operator/CRD, per-tenant gateway service/DNS, optional Helm updates.
