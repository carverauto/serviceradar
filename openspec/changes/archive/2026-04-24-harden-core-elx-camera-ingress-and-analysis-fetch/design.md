## Context
`serviceradar_core_elx` is the core-side landing point for camera relay media and the runtime that dispatches bounded relay samples to external analysis workers. It sits directly on the trust boundary between authenticated edge/gateway traffic and internal platform resources.

The current implementation still allows two fail-open paths:
- camera media ingress can start without TLS if certificates are absent, and the TLS path does not require a client certificate
- analysis worker dispatch and probing use raw `Req` calls against configured worker URLs, with no public-host validation or DNS-rebinding-safe connection binding

## Goals / Non-Goals
- Goals:
  - fail closed on core-elx camera media ingress when mTLS material is missing
  - require mutual authentication on the core-elx media gRPC listener
  - reuse the existing outbound fetch validation pattern for analysis worker HTTP requests
  - reject unsafe analysis worker URLs before dispatch
- Non-Goals:
  - redesign analysis worker selection or relay scheduling
  - change the external HTTP worker protocol payload format
  - remove operator-configurable analysis workers entirely

## Decisions
- Decision: treat the core-elx media gRPC server as an edge-facing trust boundary and require mTLS unconditionally.
  - Alternatives considered:
    - retaining an `ALLOW_INSECURE` escape hatch: rejected because it recreates the same fail-open boundary we removed in agent-gateway
    - server-auth TLS only: rejected because the caller identity must remain cryptographically bound

- Decision: validate analysis worker URLs with the same public-host / DNS-rebinding-safe outbound fetch pattern already used elsewhere in the platform.
  - Alternatives considered:
    - control-plane validation only on create/update: helpful but insufficient, because stored worker state can still be stale or injected through non-controller paths
    - hostname allowlists only: too rigid for current deployment expectations and weaker than existing reusable policy code

## Risks / Trade-offs
- Existing dev or ad-hoc deployments that relied on insecure core-elx media ingress will fail to start until proper certs are configured.
- Analysis workers pointed at private/internal addresses will stop working; this is intentional because those URLs cross the SSRF boundary.

## Migration Plan
1. Make core-elx media ingress require valid server and client trust material at startup.
2. Introduce a bounded outbound fetch helper for analysis-worker delivery and health probing.
3. Reject unsafe worker URLs in worker resolution and control-plane create/update paths.
4. Add focused tests for fail-closed startup and unsafe worker URL rejection.
