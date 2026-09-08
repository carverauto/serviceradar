## Context
Current BMP ingestion can decode and persist routing updates to `platform.bmp_routing_events`, while OCSF-oriented event workflows depend on `platform.ocsf_events`. During production-like traffic, raw BMP update volume can exceed what is appropriate for generalized OCSF event search and dashboards.

The system needs:
- high-rate routing telemetry durability and queryability,
- cross-domain curated incident/event workflows,
- stable causal correlation between both layers.

## Goals / Non-Goals
- Goals:
  - Keep raw BMP telemetry in a dedicated high-volume store (`bmp_routing_events`).
  - Keep `ocsf_events` as curated/high-signal event corpus.
  - Expose first-class BMP query/UI workflows without overloading generic events UX.
  - Preserve deterministic correlation IDs/keys across raw and promoted paths.
- Non-Goals:
  - Replace OCSF event workflows.
  - Change existing non-BMP entities in SRQL.
  - Introduce multi-tenant routing behavior.

## Decisions
- Decision: Adopt dual-path model as product default.
  - Raw path: all BMP route-level churn lands in `platform.bmp_routing_events`.
  - Curated path: only promoted BMP signals (peer state transitions, threshold/anomaly events, explicit high severity) land in `platform.ocsf_events`.

- Decision: Add `in:bmp_events` SRQL entity.
  - Rationale: avoids forcing users into raw SQL and prevents misuse of `in:events` for routing firehose data.

- Decision: Add dedicated Observability BMP UI surface.
  - Rationale: users need routing-centric filters (router, peer, prefix, event_type, severity, time) and drill-through to promoted events.

- Decision: Correlation contract remains mandatory.
  - Raw and promoted rows must keep stable event identity and routing/topology keys for replay and causality overlays.

## Risks / Trade-offs
- Risk: Divergence between raw and promoted semantics.
  - Mitigation: explicit promotion criteria and regression tests validating promoted subset behavior.

- Risk: Query cost on high-cardinality columns (peer/prefix).
  - Mitigation: add/verify focused indexes and retention policy adherence for `bmp_routing_events`.

- Risk: User confusion between BMP page and Events page.
  - Mitigation: clear UI language: BMP page = raw routing telemetry, Events page = curated cross-domain events.

## Migration Plan
1. Add SRQL `bmp_events` entity and query implementation.
2. Add/verify DB indexes for BMP investigative filters and time windows.
3. Add Observability BMP page and route wired to SRQL `bmp_events`.
4. Keep existing OCSF promotion thresholds, then iteratively refine promotion rules with metrics.
5. Validate in demo namespace with active BMP feed and compare raw vs promoted counts.

## Open Questions
- Should initial BMP UI live as a dedicated route (`/observability/bmp`) or as an Observability tab?
- Do we require a configurable promotion profile per deployment for BMP->OCSF criteria beyond severity threshold?
