## Context

`demo` currently runs CNPG with `pg_stat_statements` enabled and telemetry ingestion via `serviceradar-log-collector`. Slow-query investigations are ad hoc, with inconsistent thresholds and evidence collection across incidents.

## Goals / Non-Goals

- Goals:
  - Establish reliable slow-query observability in demo immediately.
  - Make slow-query triage reproducible with clear runbooks and queries.
  - Expose low-cardinality slow-query metrics suitable for alerting and trend analysis.
- Non-Goals:
  - Cluster-wide rollout outside `demo` in this change.
  - Replacing existing SRQL/CNPG query optimizations with observability-only work.
  - Introducing multitenancy-specific routing or tenant-specific CNPG topologies.

## Decisions

- Decision: Focus on proven CNPG observability primitives already supported in the stack.
  - `pg_stat_statements` for top-query visibility.
  - Query-duration logging thresholds for actionable slow-query evidence.
  - Standardized triage query set and incident runbook.

- Decision: Derive slow-query metrics with low-cardinality labels.
  - Emit slow-query count and duration distribution metrics keyed by normalized query signature and service context.
  - Avoid raw SQL text and bind values in metric labels.

### Alternatives considered

- Wait for a future extension-based tracing rollout.
  - Rejected: does not address current issue #2994 urgency in demo.
- Depend on manual ad hoc SQL investigation only.
  - Rejected: too inconsistent and slow for repeat incidents.

## Risks / Trade-offs

- Logging-volume risk from aggressive duration thresholds.
  - Mitigation: start conservative and tune with observed volume.
- Metrics cardinality risk from query identity dimensions.
  - Mitigation: normalized signatures and fixed label budget.

## Migration Plan

1. Confirm and tune baseline CNPG slow-query instrumentation in demo.
2. Publish and validate repeatable triage queries/runbook.
3. Wire slow-query metric derivation from existing telemetry/log data.
4. Add alert thresholds and dashboards for ongoing monitoring.

## Open Questions

- Initial query-duration threshold target for demo (e.g., 200ms vs 500ms).
- Initial alert threshold for sustained degradation (e.g., p95 > 500ms for 10m).
