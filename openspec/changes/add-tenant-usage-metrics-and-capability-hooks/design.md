## Context
Hosted ServiceRadar tenants need plan-aware limits such as managed-device caps, collector entitlements, and retention defaults. The SaaS control plane can own policy, but it cannot authoritatively count tenant devices from outside the product. The runtime already knows how many devices and collectors exist, and it is the right place to export that information.

At the same time, ServiceRadar OSS should not become a SaaS billing engine. The right compromise is:
- export neutral runtime metrics
- accept neutral capability flags
- leave commercial policy resolution to the external control plane

## Goals
- Export trustworthy runtime usage metrics for external plan visibility.
- Let deployment environments disable or hide selected feature surfaces through generic capability flags.
- Minimize SaaS-specific branching inside OSS.
- Preserve self-hosted usefulness of the same metrics and capability flags.

## Non-Goals
- Implement pricing, subscriptions, or billing logic in OSS.
- Make OSS depend on a hosted control plane.
- Add opaque platform-operator backdoors into tenant identity.

## Decisions

### Usage Metrics
The runtime should export Prometheus metrics for plan-relevant usage, including:
- current managed-device count
- current collector inventory count by collector type where practical
- current enabled collector deployments where practical

These metrics should be tenant-runtime-local facts. They do not need to know about plan names.

### Capability Flags
The runtime should accept an externally supplied capability set, such as:
- `collectors_enabled`
- `leaf_nodes_enabled`
- `device_limit_enforcement_enabled`

The exact transport may be environment variables, runtime config, or another configuration channel already used by hosted deployments. The important part is that the capability contract is generic and deployment-owned.

### Feature Gating
Collector-related UI and API paths should honor the capability set when present:
- if collector onboarding is disabled, the UI should hide or disable those entry points
- the backend should also reject disallowed actions

This prevents free-tier tenants from using collector onboarding while keeping the OSS implementation generic.

### Enforcement Posture
The first OSS change should support:
- trustworthy usage visibility
- capability-driven feature gating
- optional hard device-limit enforcement hooks later

Managed-device caps may start as a reported metric and warning path before they become a strict in-product block. That lets the hosted platform observe real usage before turning on harder enforcement.

## Risks / Trade-offs
- Device counts can be defined differently across product areas.
  - Mitigation: document a single canonical "managed device count" metric in the spec.

- Capability flags can drift if different services interpret them differently.
  - Mitigation: define a single shared capability vocabulary and require UI and backend parity for gated actions.

- Self-hosted users may ignore the capability inputs.
  - Mitigation: keep sane defaults that preserve current OSS behavior when no external capability set is supplied.

## Migration Plan
1. Define the metric and capability requirements in OpenSpec.
2. Add runtime metrics for managed devices and collectors.
3. Add configuration loading for capability flags.
4. Gate collector-related UI and API paths on those capabilities.
5. Leave billing and plan resolution outside OSS.

## Open Questions
- Should the first managed-device metric count only active devices, or all inventory devices known to the tenant?
- Do we need separate capabilities for each collector type, or is one shared collector entitlement sufficient for the first pass?
