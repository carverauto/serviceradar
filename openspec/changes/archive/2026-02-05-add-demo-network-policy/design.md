## Context
The demo namespace exposes an admin account and supports network discovery features. Without egress controls, a compromised account could be used for recon or exfiltration. Calico is installed and can enforce Kubernetes NetworkPolicy plus provide deny logging.

## Goals / Non-Goals
- Goals:
  - Provide opt-in egress controls for Helm installs.
  - Enable demo defaults that block outbound traffic except cluster/DNS paths.
  - Provide Calico deny logging for visibility into blocked egress.
- Non-Goals:
  - Implement RBAC or fine-grained per-user authorization.
  - Enforce ingress restrictions beyond existing routing.

## Decisions
- Use a Kubernetes NetworkPolicy for enforcement (portable across CNIs).
- Add an optional Calico NetworkPolicy that mirrors the allow list and logs denied egress.
- Keep policies opt-in via Helm values and enable them in demo values only.

## Risks / Trade-offs
- Duplicate allow lists between K8s and Calico policies can drift if modified separately; mitigate by templating from the same values.
- Overly restrictive defaults could break integrations; keep allow list configurable.

## Migration Plan
- Default chart behavior unchanged (policies disabled).
- Demo values enable policy; operators can disable if required.

## Open Questions
- Confirm which external CIDRs (if any) should be allowed for demo integrations.
