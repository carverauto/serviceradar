# Change: Refactor topology layout stability and performance

## Why
`prop2.md` identifies deferred layout concerns that can cause hairball rendering and unstable node placement under high fanout. We need a dedicated change to stabilize layout computation and control expensive per-snapshot work.

## What Changes
- Replace degree-root concentric-ring layout behavior with deterministic role/weight-informed layered placement for topology rendering.
- Remove unnecessary hot-path computations (especially per-snapshot betweenness work for layout decisions) that do not materially improve operator outcomes.
- Refactor layout computation away from hypergraph-heavy machinery for ordinary binary topology links.
- Tighten edge telemetry contract so the Rust layout/encoding path consumes typed values and minimizes JSON parsing in the hot path.
- Add explicit verification gates so completion is objective and auditable.

## Impact
- Affected specs:
  - `build-web-ui`
- Expected code areas:
  - `web-ng/lib/serviceradar_web_ng/topology/*`
  - Rust NIF layout paths used by web-ng topology snapshots

## In-Scope Deferred Items (prop2 Traceability)
- `P2-034` GodView ranking/anchoring strategy
- `P2-036` Rust weighted/hierarchical layout
- `P2-038` Root selection strategy shift
- `P2-039` Remove/reduce betweenness from layout hot path
- `P2-040` Reduce hypergraph overuse for basic topology geometry
- `P2-041` Remove hot-path JSON parsing for edge telemetry
- `P2-045` Snapshot layering/performance contract updates (non-breaking only)

## Out of Scope
- Risotto BMP publication wiring (`2.1` in `add-causal-topology-signal-pipeline`)
- Advanced causal/security hypergraph model expansion (covered by `add-advanced-causal-hypergraph-overlays`)
- Mapper discovery pipeline decomposition (covered by `refactor-mapper-discovery-pipeline-boundaries`)

## Definition of Done
- All in-scope `P2-*` items above are implemented or explicitly re-dispositioned with rationale in this change.
- Topology layout for unchanged structure remains stable across overlay-only updates and across repeated snapshot builds.
- Layout algorithm no longer selects root solely by raw degree for infrastructure-heavy graphs.
- Layout hot path avoids per-snapshot betweenness computation for coordinate placement.
- Layout computation for ordinary binary links does not require hypergraph transformation.
- Edge telemetry in the Rust hot path is sourced from typed numeric fields only; per-edge JSON parsing fallback is removed from runtime layout/encoding hot loops.
- Verification includes both:
  - Functional regression tests (stable coordinates + anchor behavior)
  - Performance baseline checks for high-node-count snapshots

## Implementation Traceability (P2 -> Artifact -> Evidence)
| P2 ID | Disposition | Implementation Artifacts | Evidence |
|---|---|---|---|
| `P2-034` | implemented | `web-ng/lib/serviceradar_web_ng/topology/god_view_stream.ex`, `web-ng/native/god_view_nif/src/lib.rs` | Weighted node anchor inputs + layered placement logic |
| `P2-036` | implemented | `web-ng/native/god_view_nif/src/lib.rs` | Replaced ring geometry with deterministic layered layout function |
| `P2-038` | implemented | `web-ng/native/god_view_nif/src/lib.rs` | Root/anchor selection now weight+degree deterministic ordering |
| `P2-039` | implemented | `web-ng/native/god_view_nif/src/lib.rs` | Removed snapshot betweenness computation from `encode_snapshot_impl` metadata path |
| `P2-040` | implemented | `web-ng/native/god_view_nif/src/lib.rs` | Layout geometry now builds adjacency directly from binary edges (no hypergraph conversion in layout path) |
| `P2-041` | implemented | `web-ng/native/god_view_nif/src/lib.rs`, `web-ng/lib/serviceradar_web_ng/topology/god_view_stream.ex` | Typed telemetry-only runtime contract; JSON fallback parsing removed from enrichment hot path |
| `P2-045` | re-dispositioned (partial implement + defer) | non-breaking perf updates in `web-ng/native/god_view_nif/src/lib.rs`; no snapshot schema break | Non-breaking performance contract improvements completed; structural layered snapshot schema evolution deferred to `add-advanced-causal-hypergraph-overlays` to avoid payload breakage |

## Verification Evidence
- Rust unit tests:
  - `layout_nodes_layered_is_deterministic_for_identical_inputs`
  - `layout_nodes_layered_uses_weights_for_anchor_selection`
  - `layout_nodes_layered_meets_high_node_count_baseline`
  - `enrich_edges_telemetry_prefers_typed_values`
  - `enrich_edges_telemetry_uses_metric_and_speed_fallback_when_typed_missing`
- God-View integration tests:
  - `web-ng/test/serviceradar_web_ng/topology/god_view_stream_test.exs` includes causal-only coordinate stability and high-fanout stability regression cases.
