## Context
Sweep ingestion currently updates inventory and availability, while mapper discovery is driven only by scheduled mapper jobs or explicit run-now actions. Operators expect subnet sweeps to act as a discovery front door for newly reachable devices and then promote eligible hosts into richer SNMP discovery.

## Goals / Non-Goals
- Goals:
  - Promote eligible live sweep hits into mapper discovery automatically.
  - Reuse existing mapper job assignment and command bus delivery.
  - Prevent repeated sweep hits from causing duplicate mapper runs.
  - Make promotion decisions inspectable.
- Non-Goals:
  - Replacing scheduled mapper jobs.
  - Promoting every sweep hit regardless of protocol eligibility.
  - Building a brand-new discovery execution service.

## Decisions
- Decision: Promotion will happen from sweep result ingestion after a live host has been matched or created in inventory.
  - Alternatives considered: agent-side promotion from the sweeper. Rejected because mapper job selection and auditability already live in core.
- Decision: Promotion must select an existing mapper job in the same partition/agent scope instead of creating ad hoc mapper jobs.
  - Alternatives considered: generate transient mapper jobs. Rejected because it complicates lifecycle, visibility, and command-bus semantics.
- Decision: Promotion must be idempotent with cooldown / recent-success suppression.
  - Alternatives considered: always trigger on every live sweep hit. Rejected because it would spam mapper runs on stable hosts.

## Risks / Trade-offs
- Mapper jobs might be selected too broadly or too narrowly.
  - Mitigation: require deterministic selection rules and log suppression reasons.
- Extra on-demand mapper runs could increase agent load.
  - Mitigation: bound promotions with cooldowns and only promote SNMP-eligible candidates.
- Some hosts found by sweep will still not promote if there is no eligible mapper job.
  - Mitigation: record explicit reason codes for operators.

## Migration Plan
1. Add promotion orchestration in core.
2. Add promotion state tracking needed for dedupe / cooldown.
3. Roll out to demo.
4. Verify sweep-discovered live hosts trigger mapper discovery through the expected job.

## Open Questions
- What exact cooldown window should suppress repeated promotions for the same host?
- Should eligibility require an active SNMP profile match before dispatch, or is mapper job scope alone enough?
