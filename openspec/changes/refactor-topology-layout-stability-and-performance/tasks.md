## 0. Scope and Completion Gates
- [x] 0.1 Map each in-scope deferred item (`P2-034`, `P2-036`, `P2-038`, `P2-039`, `P2-040`, `P2-041`, `P2-045`) to implementation artifacts in this change.
- [x] 0.2 Add explicit acceptance evidence for each mapped item (test, benchmark, or code-path assertion).
- [x] 0.3 Do not mark this change complete until every mapped item has evidence or explicit re-disposition rationale.

## 1. Layout Algorithm Refactor
- [x] 1.1 Replace degree-only root selection with deterministic role/weight-informed anchor selection.
- [x] 1.2 Replace concentric-ring BFS geometry with layered/hierarchical coordinate placement suitable for high-fanout topologies.
- [x] 1.3 Ensure layout output remains deterministic for identical topology inputs.

## 2. Hot-Path Performance Refactor
- [x] 2.1 Remove per-snapshot betweenness computation from coordinate layout decisions.
- [x] 2.2 Refactor layout path for ordinary binary links to avoid hypergraph conversion as the primary geometry path.
- [x] 2.3 Introduce/confirm bounded compute budgets and fallback behavior for layout refresh paths.

## 3. Telemetry Contract Cleanup
- [x] 3.1 Add typed edge telemetry contract for `flow_pps`, `flow_bps`, and `capacity_bps` into Rust layout/encoding inputs.
- [x] 3.2 Enforce typed telemetry as mandatory in runtime hot path (no JSON fallback parsing).
- [x] 3.3 Minimize/remove per-edge JSON parsing in Rust hot loops.

## 4. Verification
- [x] 4.1 Add regression tests for stable coordinates across overlay-only updates under high-fanout topology.
- [x] 4.2 Add tests that assert deterministic anchor behavior (infrastructure-rooted layout).
- [x] 4.3 Add performance baseline checks for high-node-count snapshots and enforce budget thresholds.
- [x] 4.4 Run `openspec validate refactor-topology-layout-stability-and-performance --strict`.
