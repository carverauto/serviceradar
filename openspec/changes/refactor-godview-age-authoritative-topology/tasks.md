## 1. Canonical Contract and Data Shape
- [x] 1.1 Define the canonical GodView edge payload schema in code comments/docs with required fields: `source`, `target`, `if_index_ab`, `if_name_ab`, `if_index_ba`, `if_name_ba`, `flow_pps`, `flow_bps`, `flow_pps_ab`, `flow_pps_ba`, `flow_bps_ab`, `flow_bps_ba`, `capacity_bps`, `telemetry_eligible`, `protocol`, `evidence_class`, `confidence_tier`, `confidence_reason`.
- [ ] 1.2 Add/confirm backend validation for canonical edge schema before payload encoding.
- [x] 1.3 Ensure canonical edge schema is represented in AGE projection query output and GodView snapshot payload.
- [x] 1.4 Document field semantics for directional attribution (`ab` = `source->target`, `ba` = `target->source`).

## 2. Mapper Evidence Completeness
- [ ] 2.1 Ensure mapper emits topology evidence with stable endpoint IDs and source metadata for LLDP/CDP/SNMP-L2/UniFi.
- [ ] 2.2 Ensure mapper emits usable interface hints for both directions where available (`local_if_index`, `local_if_name`, neighbor port hints).
- [ ] 2.3 Keep SNMP-L2 evidence generation for L2-only switches when LLDP is unavailable.
- [ ] 2.4 Verify SNMP-L2 bridge/FDB fallback paths for devices missing `dot1dBasePortIfIndex`.
- [ ] 2.5 Add/extend mapper tests for FDB-only uplink attribution and AP/switch attachment scenarios.

## 3. Backend Reconciler Ownership
- [x] 3.1 Move/centralize protocol ranking and pair-candidate arbitration to backend reconciler layer.
- [x] 3.2 Make backend arbitration deterministic and idempotent for repeated ingestion runs.
- [x] 3.3 Persist arbitration reason metadata for diagnostics on accepted/rejected edge candidates.
- [x] 3.4 Ensure unresolved endpoint/interface attribution is represented explicitly, not guessed.
- [ ] 3.5 Add integration tests for competing evidence mixes (LLDP vs CDP vs SNMP-L2 vs UniFi).

## 4. AGE Projection and Query
- [x] 4.1 Update AGE edge projection to upsert canonical edge only (no duplicate structural variants per pair).
- [ ] 4.2 Include directional telemetry and attribution fields in AGE-backed read model.
- [x] 4.3 Add freshness handling for stale edges/telemetry in AGE projection.
- [x] 4.4 Add query-level checks so GodView reads only canonical AGE edges.
- [x] 4.5 Add query tests to assert complete canonical edge shape is returned.

## 5. GodView Backend Stream
- [x] 5.1 Update `god_view_stream` to consume backend-canonical edges without re-arbitrating pair candidates.
- [x] 5.2 Remove or gate legacy edge-selection fallback paths that change topology structure in web-ng.
- [x] 5.3 Keep bounded telemetry fallback only as a temporary compatibility mode and tag it in diagnostics.
- [x] 5.4 Emit per-snapshot telemetry counters: canonical edges, fallback edges, unresolved directional attributions.

## 6. Frontend De-scope (No Topology Inference)
- [x] 6.1 Remove frontend pair-candidate selection and protocol arbitration from topology data build path.
- [x] 6.2 Remove frontend interface-attribution inference for directional telemetry.
- [x] 6.3 Keep frontend clustering/layout/rendering concerns only.
- [x] 6.4 Ensure directional particle generation uses backend-provided directional fields as-is.
- [x] 6.5 Add frontend regression tests that fail if topology structure is altered client-side.

## 7. Parity and Regression Tests
- [x] 7.1 Add backend-to-frontend parity test asserting AGE query edge count equals streamed canonical edge count (within expected filters).
- [ ] 7.2 Add regression tests for known problematic links: `tonka01<->aruba`, `farm01<->uswaggregation`, `uswlite8poe<->u6mesh/u6lr`.
- [x] 7.3 Add directional parity checks ensuring `ab/ba` values survive AGE -> stream -> Arrow -> JS decode.
- [x] 7.4 Add tests for duplicate interface-name cases (for example multiple `wgsts1000` ifIndexes) selecting metric-backed attribution.

## 8. Rollout, Gates, and Rollback
- [ ] 8.1 Add feature flag for backend-authoritative GodView topology consumption.
- [ ] 8.2 Define rollout SLO gates: edge parity, unresolved edge ceiling, animated-edge parity, directional parity.
- [ ] 8.3 Add rollback toggle path to restore previous topology path if SLO gates fail.
- [ ] 8.4 Produce operator runbook for post-deploy verification queries and troubleshooting.

## 9. Validation
- [x] 9.1 Run unit/integration suites for mapper, core reconciliation, and web-ng GodView paths.
- [x] 9.2 Validate demo environment behavior for target links under live telemetry.
- [x] 9.3 Run `openspec validate refactor-godview-age-authoritative-topology --strict`.

## 10. Remaining Blockers (Current)
- [ ] 10.1 Stabilize canonical rebuild trigger so `CANONICAL_TOPOLOGY` does not drop to zero between runs in `demo`.
- [ ] 10.2 Add explicit observability for canonical rebuild success/failure and edge counts (`before/after`) in core logs/telemetry.
- [ ] 10.3 Add an automated recovery path (scheduled job/worker) that re-materializes canonical edges from current mapper evidence when canonical count is below threshold.
