## Context
Interface metrics are enabled per interface and flow into UI charts and SRQL-backed queries. Disabling metrics today leaves UI charts visible and likely leaves collection running because config artifacts (including composite groups) are not cleaned up.

## Goals / Non-Goals
- Goals:
  - Disable interface metric collection immediately on config refresh.
  - Remove composite groups when the last metric is removed for an interface.
  - Ensure UI hides metrics charts and indicators for disabled interfaces.
- Non-Goals:
  - Retroactively deleting historical metrics data already stored in CNPG.
  - Redesigning the interface metrics schema or SRQL query shapes.

## Decisions
- Decision: Treat an empty metrics selection as "metrics disabled" for the interface.
  - Rationale: It provides a clear, deterministic state and avoids ambiguous partial configuration.
- Decision: UI hides charts for disabled interfaces regardless of historical data.
  - Rationale: The UI reflects current collection state; historical data can remain for retention purposes.
- Decision: Composite groups tied to interface metrics are deleted when metrics are disabled.
  - Rationale: Prevents stale config and accidental collection of removed metrics.

## Risks / Trade-offs
- Risk: Users may still expect to see historical charts after disabling.
  - Mitigation: Consider a future UI toggle for "show historical data" if needed; not part of this change.
- Risk: Multiple services must agree on the disabled state.
  - Mitigation: Make disablement explicit in config output and update UI to rely on config state rather than query presence.

## Migration Plan
- No schema migration expected.
- Deploy UI + core config changes first so disablement is reflected immediately.
- SNMP checker applies new config on next refresh cycle.

## Open Questions
- Should disabling metrics also clear any interface-specific thresholds tied to those metrics?
- Do we need an audit trail entry for composite group deletion events?
