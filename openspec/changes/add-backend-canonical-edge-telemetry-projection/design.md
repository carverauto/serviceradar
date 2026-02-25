## Context
The current GodView pipeline still enriches topology edge telemetry in `web-ng` by querying interface metrics (`timeseries_metrics`) and computing directional flow fields at render time. This violates the canonical graph contract because telemetry semantics become view-specific and are not guaranteed for other consumers.

Recent topology refactors moved edge shape arbitration to backend AGE projection, but telemetry enrichment ownership is still split. This proposal closes that gap by making canonical telemetry part of backend projection output.

## Goals / Non-Goals
- Goals:
  - Backend owns canonical edge telemetry enrichment for `CANONICAL_TOPOLOGY`.
  - Runtime graph read path returns topology + telemetry in one authoritative shape.
  - GodView consumes backend telemetry values without recomputing from raw metrics.
  - Telemetry attribution quality is observable from backend counters.
- Non-Goals:
  - SRQL/API endpoint implementation in this change.
  - New telemetry collectors or polling protocols.
  - Frontend visual tuning changes.

## Decisions
- Decision: Persist canonical edge telemetry fields on `CANONICAL_TOPOLOGY` relationships.
  - Required fields: `flow_pps`, `flow_bps`, `capacity_bps`, `flow_pps_ab`, `flow_pps_ba`, `flow_bps_ab`, `flow_bps_ba`, `telemetry_source`, `telemetry_observed_at`.
- Decision: Directionality semantics remain fixed to canonical edge orientation.
  - `ab` = `source -> target`, `ba` = `target -> source`.
- Decision: GodView stream path becomes pass-through for telemetry values.
  - `GodViewStream` MAY normalize null/invalid values to schema-safe defaults but MUST NOT compute edge telemetry from interface metrics.
- Decision: Backend reconciliation emits attribution diagnostics.
  - Counters include: both-sided attribution, one-sided attribution, unattributed canonical edges, telemetry fallback usage, stale telemetry edges.

## Risks / Trade-offs
- Risk: Backend projection may lag interface metric freshness.
  - Mitigation: include `telemetry_observed_at` and staleness gates in canonical projection.
- Risk: Removing UI-side enrichment may initially reduce animated edges where backend attribution is incomplete.
  - Mitigation: ship diagnostics first and validate attribution coverage before hard cutover.
- Risk: Canonical edge storage bloat from telemetry updates.
  - Mitigation: update only changed values and bound rebuild cadence.

## Migration Plan
1. Add canonical telemetry fields to backend projection writes.
2. Update runtime graph read contract and NIF decode to include these fields.
3. Add pass-through behavior in `GodViewStream`, remove `timeseries_metrics` edge enrichment queries.
4. Validate parity in demo using backend counters and GodView rendered edge telemetry.
5. Document SRQL/API follow-up consumption path.

## Open Questions
- Should canonical projection write telemetry on every rebuild cycle or only when value deltas exceed a threshold?
- Should stale telemetry edges retain last value with staleness flag, or zero out directional fields?
