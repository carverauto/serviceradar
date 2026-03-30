## Context
`go/pkg/grpc` is the shared transport/security package used by multiple internal services. Because it is reusable infrastructure, any fail-open default here propagates widely across clients and servers that do not override the defaults correctly.

The review found two concrete issues:
- `NewClient` and `NewSecurityProvider` silently downgrade to `NoSecurityProvider` when callers omit a provider or pass nil/empty config
- the SPIFFE provider authorizes too broadly when `server_spiffe_id` or trust-domain configuration is omitted, weakening workload identity binding

## Goals / Non-Goals
- Goals:
  - fail closed when security configuration is absent or incomplete
  - keep explicit `none` mode available only where deliberately requested
  - require meaningful SPIFFE peer identity constraints instead of `AuthorizeAny`
- Non-Goals:
  - redesign all service-specific security configuration loading
  - remove explicit insecure mode from every caller in this change

## Decisions
- Decision: shared constructors should never choose insecure transport implicitly.
  - Alternatives considered:
    - keeping current fallback with stronger logging: rejected because logs do not restore the trust boundary
    - allowing nil provider only in tests: rejected because the package cannot distinguish test from production safely

- Decision: SPIFFE credentials must require explicit peer constraints.
  - Alternatives considered:
    - trust-domain-wide membership by default: rejected because it broadens caller/callee authorization to every workload in that trust domain
    - `AuthorizeAny` by default: rejected because it removes workload identity binding entirely

## Risks / Trade-offs
- Existing callers that relied on nil security config or missing SPIFFE identity settings will start failing until they are configured explicitly.
- Some dev/test helpers may need small follow-up adjustments to request `none` mode intentionally instead of inheriting it accidentally.

## Migration Plan
1. Make `NewClient` and `NewSecurityProvider` return errors on nil/empty security configuration instead of selecting `NoSecurityProvider`.
2. Require SPIFFE client/server constructors to reject missing identity constraints.
3. Update tests to cover the fail-closed behavior.
