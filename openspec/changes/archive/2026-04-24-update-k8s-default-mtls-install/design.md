# Design: Kubernetes Default Secret-backed mTLS Install

## Context

ServiceRadar's Docker Compose deployments already run with non-SPIFFE mTLS. Kubernetes, however, still defaults to SPIFFE/SPIRE-oriented settings such as `spire.enabled: true`, `secMode: spiffe`, and workload socket assumptions across multiple services. The default demo manifests also live under `k8s/demo/base/spire`, which makes SPIRE look mandatory for all Kubernetes installs.

That default is too heavy for clusters where operators cannot create CRDs or other cluster-scoped resources. The issue is not whether ServiceRadar should use mTLS by default; it should. The issue is that the default Kubernetes path should not require a full SPIFFE/SPIRE identity plane.

## Goals / Non-Goals

- Goals:
  - Keep internal mTLS enabled by default for Kubernetes installs.
  - Make the default install work without SPIRE CRDs, SPIRE agents, or SPIRE controller resources.
  - Deliver runtime certificates through Kubernetes `Secret`s mounted into workloads.
  - Preserve SPIFFE/SPIRE as an explicit optional install mode.
  - Provide a clear cleanup and upgrade path for existing demo namespaces and existing SPIRE-based installs.

- Non-Goals:
  - Removing SPIFFE/SPIRE support entirely.
  - Changing edge-agent-to-gateway mTLS behavior.
  - Redesigning certificate rotation beyond what is needed for the default Kubernetes path.

## Decisions

### Decision 1: Default Kubernetes identity is Secret-backed mTLS

The default Helm and raw Kubernetes install paths will use deployment-managed certificates stored in Kubernetes `Secret`s and mounted into pods as files. Applications will read certificate, key, and CA paths from the mounted files.

This preserves the existing runtime contract for services that already know how to consume file paths, while removing the requirement for the SPIRE Workload API socket in the default case.

### Decision 2: SPIFFE/SPIRE becomes an explicit profile

SPIFFE/SPIRE support remains in the repository, but it will no longer be part of the default render or default manifest path. Operators who want workload identities issued by SPIRE must opt in through explicit Helm values and/or a dedicated Kubernetes overlay/profile.

This keeps advanced identity-plane support available without forcing it on all clusters.

### Decision 3: Default demo manifests stop implying SPIRE is mandatory

The default `k8s/demo` install path will no longer be anchored around `base/spire`. If SPIRE-specific resources remain in-tree, they will move behind an explicit optional path so the default demo deployment reflects the supported default product behavior.

### Decision 4: Existing installs need an explicit migration story

Changing the default from SPIFFE/SPIRE to Secret-backed mTLS is behaviorally significant. Existing installs that depend on the current defaults must be able to pin or explicitly enable SPIFFE/SPIRE during upgrade. Demo cleanup steps must also cover stale SPIRE workloads, CRs, RBAC, and Secrets so operators do not end up with a mixed security model.

## Risks / Trade-offs

- Secret-backed certificates provide less dynamic identity plumbing than SPIRE.
  - Mitigation: keep SPIFFE/SPIRE available as the opt-in advanced mode.
- Moving from a shared cert PVC to Secret-backed runtime mounts may require broader chart refactoring.
  - Mitigation: treat this as part of the intended change rather than preserving the current shared-PVC pattern by accident.
- Existing environments may silently change behavior on upgrade if defaults move without guidance.
  - Mitigation: document the breaking default change and provide explicit upgrade instructions.

## Migration Plan

1. Introduce the new default values and workload mounts for Secret-backed mTLS.
2. Gate SPIRE resources so they render only when explicitly enabled.
3. Move or refactor demo manifests so the default path no longer includes SPIRE-specific resources.
4. Document upgrade steps for current SPIRE-based installs:
   - explicitly enable SPIFFE/SPIRE before upgrade if operators want to keep it
   - or clean up SPIRE resources and adopt the new Secret-backed default path
5. Validate both render paths:
   - default install without SPIRE resources
   - optional SPIFFE/SPIRE install with explicit enablement

## Open Questions

- Should the default chart generate one shared Secret bundle or per-workload Secrets for runtime certs?
- Should optional SPIFFE/SPIRE live under the existing chart with flags, or move to a dedicated overlay/subchart for cleaner separation?
