## Context
The `k8s/demo` tree is presented as a runnable deployment path with `base/` plus `prod/` and `staging/` overlays. The README now states that SPIFFE/SPIRE is optional and not part of the default install path, but several default base manifests still mount `/run/spire/sockets` from the node via `hostPath` and wire workloads to the SPIRE Workload API socket. The prod and staging overlays also expose datasvc gRPC externally by default.

## Goals / Non-Goals
- Goals:
  - make the default demo install path align with the documented non-SPIRE runtime model
  - remove hostPath SPIRE socket mounts from the default base
  - keep datasvc internal-only by default in the demo overlays
- Non-Goals:
  - redesign the entire demo topology
  - remove optional SPIRE support from the repository
  - remove all externally reachable demo services

## Decisions
- Decision: SPIRE socket mounts and SPIRE-specific env wiring move out of the default base and into an explicit SPIRE opt-in path.
  - Why: the base should not rely on host filesystem mounts for an optional identity system.
- Decision: datasvc external `LoadBalancer` services are removed from the default overlays.
  - Why: datasvc is an internal platform service and should require an explicit operator decision before exposure.

## Risks / Trade-offs
- Some existing demo workflows may currently depend on externally reachable datasvc.
  - Mitigation: preserve the manifest as an optional add-on or document the operator patch required to restore it intentionally.
- Moving SPIRE wiring out of base may require per-workload overlay patches.
  - Mitigation: keep the SPIRE opt-in structure explicit and minimal, and validate the default base without those mounts.

## Migration Plan
1. Strip hostPath SPIRE socket mounts and SPIRE workload-socket env vars from the default base manifests.
2. Move those mounts/settings into an explicit SPIRE-specific overlay or optional resource path.
3. Remove datasvc external `LoadBalancer` manifests from default prod/staging overlays.
4. Update demo docs to reflect internal-only datasvc and explicit SPIRE opt-in behavior.
