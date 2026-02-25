## 1. Spec and Contract
- [ ] 1.1 Add `age-graph` requirement defining canonical topology edge telemetry fields as backend-owned read model data.
- [ ] 1.2 Add `network-discovery` requirement defining backend reconciliation ownership for edge telemetry attribution.
- [ ] 1.3 Validate with `openspec validate add-backend-canonical-edge-telemetry-projection --strict`.

## 2. Backend Canonical Projection
- [ ] 2.1 Extend canonical topology rebuild/upsert to persist directional and aggregate telemetry fields on `CANONICAL_TOPOLOGY` edges.
- [ ] 2.2 Define freshness/staleness semantics for telemetry fields and persist timestamps used for attribution.
- [ ] 2.3 Ensure deterministic backend arbitration when multiple interface signals exist for one canonical pair.
- [ ] 2.4 Add backend diagnostics counters for attribution completeness (`both_sides`, `one_side`, `none`), fallback usage, and stale telemetry.

## 3. Runtime Graph Read Path
- [ ] 3.1 Update runtime graph Cypher query to return backend telemetry fields directly with canonical edge identity.
- [ ] 3.2 Ensure runtime graph NIF structs preserve returned telemetry fields unchanged.
- [ ] 3.3 Add regression tests that runtime graph rows include directional telemetry and no UI-side computed fields are required.

## 4. Web-NG De-scope of Enrichment
- [ ] 4.1 Remove edge telemetry computation queries from `GodViewStream` (`timeseries_metrics` joins/aggregation for edges).
- [ ] 4.2 Keep only rendering-safe normalization in `GodViewStream` (type coercion, defaults for absent optional fields).
- [ ] 4.3 Add tests proving GodView edge telemetry values are pass-through from backend/runtime graph.

## 5. Validation
- [ ] 5.1 Add integration test coverage for canonical telemetry projection from mapper evidence to runtime graph read output.
- [ ] 5.2 Validate in `demo` that GodView edge telemetry counts match backend canonical projection counters.
- [ ] 5.3 Document follow-up hook points for SRQL/API to consume identical canonical edge telemetry shape (implementation out of scope).
