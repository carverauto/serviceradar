## Context
We currently run a shared multi-tenant agent gateway. This makes hard isolation and per-tenant accounting difficult and creates shared failure domains. We want per-tenant gateway pools that still participate in the shared ERTS cluster with core and web-ng.

## Goals / Non-Goals
- Goals:
  - Hard tenant isolation at the gateway layer (tenant-scoped certs + routing).
  - Support multiple gateways per tenant for HA and scale.
  - Kubernetes-first provisioning with tenant-scoped DNS endpoints.
  - Keep core/web-ng shared across tenants.
- Non-Goals:
  - Perfect Docker support for multi-tenant gateway orchestration.
  - Replacing gRPC or the existing onboarding flow.

## Decisions
- Decision: Introduce per-tenant gateway pools with tenant-scoped mTLS identities and tenant-specific DNS endpoints.
- Decision: Gateways remain in the shared ERTS cluster; selection/routing is tenant-scoped.
- Decision: Provision via Kubernetes CRD/operator (first-class path); Helm can provide a single-tenant default.

## Risks / Trade-offs
- Increased operational overhead (one or more gateway pools per tenant) -> mitigate with operator automation and defaults.
- Routing complexity (tenant DNS/LB) -> mitigate with consistent naming conventions and shared templates.
- Migration from shared gateways -> mitigate with phased rollout and dual-routing during transition.

## Migration Plan
1) Introduce tenant gateway pool registration and routing metadata.
2) Add tenant-scoped gateway endpoints in onboarding/config.
3) Roll out CRD/operator and per-tenant services.
4) Migrate tenants from shared gateway to tenant pools.
5) Remove shared gateway path once stable.

## Open Questions
- DNS format: <tenant>.gw.serviceradar.cloud vs <tenant>-gw.serviceradar.cloud?
- CRD schema: what fields define pool size, region, and endpoint?
- How should tenant gateways be discovered by core when multiple pools exist?
- How to handle single-tenant on-prem installs (default gateway pool)?
