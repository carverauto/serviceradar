## Context
SPIFFE/SPIRE is optional in the chart, but when operators enable it they should not inherit insecure or overly broad exposure defaults. Right now the chart does two risky things:
- publishes the SPIRE server via `LoadBalancer` and includes the health port in that service
- disables kubelet verification in the SPIRE agent workload attestor

Those are both trust-boundary decisions and should require explicit opt-in, not happen silently through default values.

## Goals
- Keep SPIRE server traffic internal by default.
- Keep the SPIRE health endpoint internal by default.
- Require verified kubelet attestation by default.
- Preserve an explicit override path for operators who intentionally need different behavior.

## Non-Goals
- Changing the overall SPIFFE/SPIRE architecture.
- Removing optional external publication entirely.
- Reworking SPIRE RBAC or storage topology.

## Decisions
### Internal-by-default SPIRE service
The SPIRE server service should default to `ClusterIP`, not `LoadBalancer`. External publication, if needed, must be an explicit operator decision.

### Health endpoint not published externally
The published SPIRE service should carry only the required SPIRE gRPC port by default. Health remains reachable inside the pod for probes.

### Verified kubelet attestation by default
The chart should not set `skip_kubelet_verification = true` unless an operator explicitly requests that insecure mode.

## Verification
- `helm template` with `spire.enabled=true` renders an internal SPIRE server service by default.
- The rendered SPIRE service no longer exposes the health port externally by default.
- The rendered SPIRE agent config does not set `skip_kubelet_verification = true` unless explicitly requested.
- OpenSpec validation and diff checks remain clean.
