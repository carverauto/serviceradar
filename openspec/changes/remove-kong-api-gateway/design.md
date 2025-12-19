## Context
Kong is no longer required as an API gateway. We want the default deployment stacks to route user/API traffic directly to web-ng and SRQL endpoints while keeping TLS termination at the edge proxy (Caddy/Nginx).

## Goals / Non-Goals
- Goals:
  - Remove Kong from all default deployment manifests and packaging.
  - Maintain HTTPS termination and WebSocket support through the edge proxy.
  - Preserve existing UI/API behavior by routing to web-ng/SRQL directly.
- Non-Goals:
  - Redesigning auth/JWT flows beyond removing Kong.
  - Changing core or SRQL API semantics.

## Decisions
- Decision: Use the edge proxy (Caddy/Nginx) as the only ingress layer and route `/api` and `/auth` paths directly to web-ng.
- Alternatives considered: Keeping Kong as optional in compose/Helm. Rejected to avoid maintenance and confusion.

## Risks / Trade-offs
- Removing Kong removes centralized JWT enforcement; ensure web-ng enforces auth consistently.

## Migration Plan
1. Remove Kong services/config from compose/Helm/K8s manifests.
2. Update edge proxy routing rules for `/api` (web-ng handles SRQL endpoints too).
3. Remove Kong packaging/config artifacts.
4. Update docs and validate compose + Bazel workflows.

## Open Questions
- Should `/api/query` be routed directly to SRQL or stay within web-ng?
- Do any deployments still rely on Kong-specific JWT enforcement that needs to be replicated elsewhere?
