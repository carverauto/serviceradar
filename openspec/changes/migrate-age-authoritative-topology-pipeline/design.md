## Context
Live troubleshooting indicates two concurrent failures:
- Evidence quality problems (missing LLDP adjacency, UniFi payload drift, SNMP high-fanout false links).
- Pipeline authority problems (identity normalization and edge shaping spread across layers).

This allows bad or partial evidence to become persistent graph structure and makes restarts/redeploys ineffective because polluted evidence remains in storage.

## Goals / Non-Goals
- Goals:
  - Make AGE the definitive topology read model.
  - Keep mapper as evidence producer, not canonical graph authority.
  - Remove UI-layer identity reconciliation/guessing for topology edges.
  - Provide deterministic reset/rebuild path for polluted graph state.
- Non-Goals:
  - Replacing Apache AGE.
  - Replacing Ash/DIRE identity systems.
  - Introducing a new graph database or new multitenancy model.

## Decisions
- Decision: Evidence-first mapper contract (versioned envelope)
  - Mapper publishes typed observations with `observation_type`, `source_protocol`, `source_uid`, `target_uid`, confidence, and supporting raw attributes.
  - Each observation includes a contract version so API shape drift is detected, not silently coerced.

- Decision: Source UID immutability
  - Mapper-generated endpoint IDs are immutable per observation.
  - Downstream layers may resolve canonical device identity, but must not rewrite source observation IDs in-place.
  - Unresolved endpoints remain explicit unresolved nodes/records.

- Decision: Core reconciler as canonical topology builder
  - Core ingests observations, applies identity reconciliation, then derives canonical edges.
  - Canonical edge projection to AGE is idempotent and includes freshness/last_seen.
  - Stale inferred edges expire when observation evidence ages out.

- Decision: AGE-authoritative rendering
  - Web topology consumes canonical AGE adjacency only.
  - UI does not perform greedy hostname/IP matching to merge nodes.
  - Unknown endpoints render as unresolved rather than guessed matches.

- Decision: Controlled reset/rebuild
  - Provide an operator runbook + command path to clear topology evidence/derived edges and replay from fresh discovery.
  - Rebuild must be deterministic and observable (counts before/after, drift reports).

## Migration Plan
1. Contract + telemetry phase
- Add observation envelope v2 behind feature flag.
- Emit both v1 and v2 in shadow mode; compare counts and parse failures.
- Add telemetry for direct/inferred edges, unresolved endpoints, and edge churn.

2. Reconciler authority phase
- Switch core ingestor to consume v2 observations as source of truth.
- Enable trunk/flood suppression in SNMP-derived L2 links.
- Enable stale-edge lifecycle handling.

3. AGE-authoritative render phase
- Remove UI-layer topology identifier resolver from edge construction path.
- Render unresolved nodes explicitly.
- Gate rollout on regression metrics.

4. Reset/rebuild phase
- Run one-time cleanup of polluted topology evidence and stale derived edges.
- Trigger fresh discovery jobs and replay.
- Verify expected direct adjacency coverage before fully enabling inferred overlays.

## Rollback Plan
- Feature-flag rollback at each phase:
  - disable v2 contract consumption,
  - restore previous ingestor path,
  - re-enable prior UI path temporarily if necessary.
- Keep raw observations so rebuild can be retried after fixes.

## Risks / Trade-offs
- Initial unresolved node count may increase after removing UI guessing.
  - Mitigation: expose unresolved evidence and reconciliation diagnostics.
- Temporary drop in displayed edge count during cleanup.
  - Mitigation: phased rollout with acceptance thresholds.

## Open Questions
- Final threshold for SNMP trunk suppression (`macs_per_ifindex` cutoff).
  - Resolved for current rollout: `maxSNMPFDBMacsPerPort=8` with dense-port unknown neighbor cap `2` per `ifIndex`.
  - Rationale: preserves single-seed adjacency recovery while preventing trunk fan-out explosions.
- Whether to maintain dual-write v1/v2 contracts for one release or two.
