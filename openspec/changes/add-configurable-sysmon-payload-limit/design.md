## Context
Sysmon metrics arrive via the gRPC status update pipeline and are larger than other status messages. The agent gateway currently enforces a fixed maximum payload size, which cannot be tuned per tenant and is not discoverable via configuration documentation.

## Goals / Non-Goals
- Goals:
  - Support a per-tenant sysmon payload limit with a safe default.
  - Keep enforcement centralized in the agent gateway.
  - Document the configuration key and default clearly.
- Non-Goals:
  - Introduce a new metrics ingestion endpoint.
  - Change the sysmon payload format or ingestion path.

## Decisions
- Decision: Store the sysmon payload limit in tenant configuration with a documented default of 15MB.
- Decision: Enforce the limit in the agent gateway when accepting sysmon payloads.
- Alternatives considered: global-only limit (rejected, no per-tenant tuning), separate metrics endpoint (out of scope).

## Risks / Trade-offs
- Large limits increase memory pressure; mitigate with documented defaults and explicit rejection on overflow.
- Per-tenant overrides require correct config propagation; add tests for fallback behavior.

## Migration Plan
- Ship config key with default fallback.
- Roll out gateway changes to honor the limit.

## Open Questions
- Where should the tenant config key live (existing tenant config table vs. gateway-specific config namespace)?
